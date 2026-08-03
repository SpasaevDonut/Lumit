// Lens flare (docs/08-EFFECTS.md §3.27, docs/impl/lens-flare.md, K-261).
// Three compute entry points of the per-frame ghost pipeline:
//   trace       — one thread per pupil-grid corner: refract the ray through
//                 the prescription with the FlareSim three-phase walk
//                 (reflecting at the pair's two surfaces), weight by the
//                 per-surface Fresnel/coating product and the iris mask,
//                 land on the sensor. Mirrors lumit_core's `trace_splat`
//                 op-for-op; the dead sentinel is weight −1 (the CPU
//                 returns None).
//   quad_energy — one thread per grid cell: launch cell area ÷ landed area
//                 in raster px² (energy conservation), dead-corner cells 0.
//   build_verts — one thread per cell: emits the cell's two triangles with
//                 per-corner weighted colour; sub-pixel fold quads inflate
//                 about their centroid with flux conserved (K-261) so the
//                 hardware raster cannot drop caustic flux; culled cells
//                 park off-screen.
// The additive raster lives in fx_lens_flare_draw.wgsl, the box blur in
// fx_lens_flare_blur.wgsl, detection in fx_lens_flare_detect.wgsl and the
// final combine in fx_lens_flare_combine.wgsl.

struct Surface {
    radius_mm: f32,     // 0 = flat
    z_mm: f32,          // vertex z (front vertex at 0, +z toward sensor)
    semi_ap_mm: f32,    // clear semi-aperture (the stop's scales by fstop)
    cauchy_a: f32,      // medium AFTER this surface (1.0 = air)
    cauchy_b: f32,
    coating_layers: f32,
    is_stop: f32,
    _pad: f32,
};

// One (pair × wavelength) combo: the two bounce surfaces, the traced
// wavelength, and the wavelength's RGB weight already multiplied by the
// exposure gain and Ghost intensity.
struct Combo {
    bounce_a: u32,
    bounce_b: u32,
    lambda_nm: f32,
    _pad: f32,
    rgb_r: f32,
    rgb_g: f32,
    rgb_b: f32,
    _pad2: f32,
};

// One traced corner: raster position (flare-buffer px) and the ray's
// Fresnel × iris-mask weight; weight < 0 = dead.
struct Ray {
    pos_x: f32,
    pos_y: f32,
    weight: f32,
    _pad: f32,
};

struct Vertex {
    ndc_x: f32,
    ndc_y: f32,
    r: f32,
    g: f32,
    b: f32,
    _pad0: f32,
    _pad1: f32,
    _pad2: f32,
};

// One flare source (see fx_lens_flare_detect.wgsl): position as a raster
// fraction, colour already multiplied by its gate weight. All-zero rgb is a
// dead slot the passes skip.
struct Light {
    pos_x: f32,
    pos_y: f32,
    r: f32,
    g: f32,
    b: f32,
    _pad0: f32,
    _pad1: f32,
    _pad2: f32,
};

struct TraceParams {
    surface_count: u32,
    combo_count: u32,
    grid: u32,          // pupil corners per axis
    combo_offset: u32,  // first combo of this batch
    coating: f32,       // 0..1 Coating dial
    aspect: f32,        // frame h/w for the light direction
    focal_mm: f32,
    screen_transform: f32, // flare-buffer px per sensor mm
    raster_w: f32,
    raster_h: f32,
    light_count: u32,
    sensor_shift_mm: f32,  // focus shift (K-260)
    pupil_mm: f32,         // spray radius, already × the f-stop scale
    start_z_mm: f32,
    sensor_z_mm: f32,
    stop_scale: f32,       // scales the stop surface's semi-aperture
    cell_area_px: f32,     // launch cell area in flare-buffer px²
    blades: u32,
    rot_rad: f32,
    roundness: f32,        // effective (wide-open blended)
    softness: f32,
    _pad0: f32,
    _pad1: f32,
    _pad2: f32,
};

@group(0) @binding(0) var<storage, read> surfaces: array<Surface>;
@group(0) @binding(1) var<storage, read> combos: array<Combo>;
@group(0) @binding(2) var<storage, read_write> rays: array<Ray>;
@group(0) @binding(3) var<storage, read_write> energies: array<f32>;
@group(0) @binding(4) var<storage, read_write> verts: array<Vertex>;
@group(0) @binding(5) var<uniform> tp: TraceParams;
@group(0) @binding(6) var<storage, read> lights: array<Light>;

// The light direction for a source at raster fraction (px, py) — the exact
// WGSL twin of lumit_core's `light_direction` (sensor y up, so the y
// fraction flips sign; half the 36 mm sensor width is 18; z toward the
// sensor is positive).
fn dir_of(px: f32, py: f32) -> vec3<f32> {
    let half_w = 18.0;
    let x = (px * 2.0 - 1.0) * half_w;
    let y = -(py * 2.0 - 1.0) * tp.aspect * half_w;
    return normalize(vec3<f32>(-x, -y, tp.focal_mm));
}

fn light_dead(l: Light) -> bool {
    return l.r <= 0.0 && l.g <= 0.0 && l.b <= 0.0;
}

fn cauchy_ior(a: f32, b: f32, lambda_nm: f32) -> f32 {
    let um = lambda_nm * 1e-3;
    return a + b / (um * um);
}

// The iris mask (lumit_core `pupil_mask`): polygon bound blended toward the
// circle by roundness, feathered by softness.
fn pupil_mask(u: f32, v: f32) -> f32 {
    let r = sqrt(u * u + v * v);
    let blades = f32(clamp(tp.blades, 3u, 16u));
    let tau = 6.283185307179586;
    let sector = tau / blades;
    let apothem = cos(3.141592653589793 / blades);
    let angle = atan2(v, u) - tp.rot_rad;
    var a = angle % sector;
    if (a < 0.0) {
        a = a + sector;
    }
    let poly_bound = apothem / cos(a - sector * 0.5);
    let bound = poly_bound + (1.0 - poly_bound) * clamp(tp.roundness, 0.0, 1.0);
    let soft = max(clamp(tp.softness, 0.0, 1.0) * bound, 1e-4);
    let t = clamp((r - (bound - soft)) / soft, 0.0, 1.0);
    return 1.0 - t * t * (3.0 - 2.0 * t);
}

// Unpolarised Fresnel by incidence cosine (lumit_core `fresnel_cos`).
fn fresnel_cos(cos_i_in: f32, n1: f32, n2: f32) -> f32 {
    let cos_i = abs(cos_i_in);
    let eta = n1 / n2;
    let sin2_t = eta * eta * (1.0 - cos_i * cos_i);
    if (sin2_t >= 1.0) {
        return 1.0;
    }
    let cos_t = sqrt(1.0 - sin2_t);
    let rs = (n1 * cos_i - n2 * cos_t) / (n1 * cos_i + n2 * cos_t);
    let rp = (n2 * cos_i - n1 * cos_t) / (n2 * cos_i + n1 * cos_t);
    return 0.5 * (rs * rs + rp * rp);
}

// Single-layer thin-film reflectance (lumit_core `coating_reflectance`).
fn coating_refl(cos_i_in: f32, n1: f32, n2: f32, coating_n: f32, d_nm: f32, lambda_nm: f32) -> f32 {
    let cos_i = abs(cos_i_in);
    let sin2_c = (n1 / coating_n) * (n1 / coating_n) * (1.0 - cos_i * cos_i);
    if (sin2_c >= 1.0) {
        return fresnel_cos(cos_i, n1, n2);
    }
    let cos_c = sqrt(1.0 - sin2_c);
    let delta = 2.0 * 3.141592653589793 * coating_n * d_nm * cos_c / lambda_nm;
    let r01 = (n1 * cos_i - coating_n * cos_c) / (n1 * cos_i + coating_n * cos_c);
    let sin2_2 = (coating_n / n2) * (coating_n / n2) * (1.0 - cos_c * cos_c);
    if (sin2_2 >= 1.0) {
        return fresnel_cos(cos_i, n1, n2);
    }
    let cos_2 = sqrt(1.0 - sin2_2);
    let r12 = (coating_n * cos_c - n2 * cos_2) / (coating_n * cos_c + n2 * cos_2);
    let cos_2d = cos(2.0 * delta);
    let num = r01 * r01 + r12 * r12 + 2.0 * r01 * r12 * cos_2d;
    let den = 1.0 + r01 * r01 * r12 * r12 + 2.0 * r01 * r12 * cos_2d;
    return clamp(num / den, 0.0, 1.0);
}

// Reflectance of one surface: bare Fresnel blended toward the file's AR
// coating by the Coating dial (lumit_core `surface_reflectance`).
fn surface_refl(cos_i: f32, n1: f32, n2: f32, layers: f32, lambda_nm: f32) -> f32 {
    let plain = fresnel_cos(cos_i, n1, n2);
    if (layers < 0.5 || tp.coating <= 0.0) {
        return plain;
    }
    let mgf2_n = 1.38;
    let qw = 550.0 / (4.0 * mgf2_n);
    var coated = coating_refl(cos_i, n1, n2, mgf2_n, qw, lambda_nm);
    let extra = clamp(i32(round(layers - 1.0)), 0, 8);
    for (var i = 0; i < extra; i = i + 1) {
        coated = coated * 0.25;
    }
    return clamp(plain + (coated - plain) * clamp(tp.coating, 0.0, 1.0), 0.0, 1.0);
}

// Ray–surface intersection (lumit_core `intersect`, the FlareSim rule):
// flat plane at the vertex z, else ray–sphere picking the intersection
// closest to the vertex; the clear semi-aperture clips. ok=false = dead.
struct Isect {
    pos: vec3<f32>,
    normal: vec3<f32>,
    ok: bool,
};

fn intersect(pos: vec3<f32>, dir: vec3<f32>, radius: f32, z_mm: f32, semi_ap: f32) -> Isect {
    var out: Isect;
    out.ok = false;
    if (abs(radius) < 1e-6) {
        if (abs(dir.z) < 1e-12) {
            return out;
        }
        let t = (z_mm - pos.z) / dir.z;
        if (!(t > 1e-6)) {
            return out;
        }
        let hit = pos + dir * t;
        // 10% clip skirt (see the CPU `intersect`): boundary quads fade via
        // the housing feather instead of dying corner-by-corner.
        let skirt = semi_ap * 1.1;
        if (hit.x * hit.x + hit.y * hit.y > skirt * skirt) {
            return out;
        }
        out.pos = hit;
        out.normal = vec3<f32>(0.0, 0.0, select(1.0, -1.0, dir.z > 0.0));
        out.ok = true;
        return out;
    }
    let centre = vec3<f32>(0.0, 0.0, z_mm + radius);
    let oc = pos - centre;
    let a = dot(dir, dir);
    let b = 2.0 * dot(oc, dir);
    let c = dot(oc, oc) - radius * radius;
    let disc = b * b - 4.0 * a * c;
    if (disc < 0.0) {
        return out;
    }
    let sd = sqrt(disc);
    let inv2a = 0.5 / a;
    let t1 = (-b - sd) * inv2a;
    let t2 = (-b + sd) * inv2a;
    var t = -1.0;
    if (t1 > 1e-6 && t2 > 1e-6) {
        let z1 = pos.z + t1 * dir.z;
        let z2 = pos.z + t2 * dir.z;
        t = select(t2, t1, abs(z1 - z_mm) < abs(z2 - z_mm));
    } else if (t1 > 1e-6) {
        t = t1;
    } else if (t2 > 1e-6) {
        t = t2;
    } else {
        return out;
    }
    let hit = pos + dir * t;
    let skirt = semi_ap * 1.1;
    if (!(hit.x * hit.x + hit.y * hit.y <= skirt * skirt)) {
        return out;
    }
    var n = (hit - centre) / abs(radius);
    if (dot(n, dir) > 0.0) {
        n = -n;
    }
    out.pos = hit;
    out.normal = n;
    out.ok = true;
    return out;
}

fn refract_dir(dir: vec3<f32>, n: vec3<f32>, o: f32) -> vec4<f32> {
    // xyz = direction, w = 1 live / 0 dead (TIR or degenerate).
    let cos_i = -dot(dir, n);
    let sin2_t = o * o * (1.0 - cos_i * cos_i);
    if (sin2_t >= 1.0) {
        return vec4<f32>(0.0, 0.0, 0.0, 0.0);
    }
    let k = o * cos_i - sqrt(1.0 - sin2_t);
    let v = dir * o + n * k;
    let sq = dot(v, v);
    if (!(sq > 1e-18)) {
        return vec4<f32>(0.0, 0.0, 0.0, 0.0);
    }
    return vec4<f32>(normalize(v), 1.0);
}

fn reflect_dir(dir: vec3<f32>, n: vec3<f32>) -> vec3<f32> {
    return normalize(dir - n * (2.0 * dot(dir, n)));
}

fn semi_of(s: Surface) -> f32 {
    if (s.is_stop > 0.5) {
        return s.semi_ap_mm * tp.stop_scale;
    }
    return s.semi_ap_mm;
}

@compute @workgroup_size(64)
fn trace(@builtin(global_invocation_id) gid: vec3<u32>) {
    let ray_count = tp.grid * tp.grid;
    if (gid.x >= ray_count || gid.y >= tp.combo_count || gid.z >= tp.light_count) {
        return;
    }
    let slot = (gid.z * tp.combo_count + gid.y) * ray_count + gid.x;
    var dead: Ray;
    dead.pos_x = 0.0;
    dead.pos_y = 0.0;
    dead.weight = -1.0;
    dead._pad = 0.0;

    let light = lights[gid.z];
    if (light_dead(light)) {
        rays[slot] = dead;
        return;
    }
    let combo = combos[tp.combo_offset + gid.y];
    let a_idx = combo.bounce_a;
    let b_idx = combo.bounce_b;
    if (a_idx >= b_idx || b_idx >= tp.surface_count) {
        rays[slot] = dead;
        return;
    }

    let gi = gid.x % tp.grid;
    let gj = gid.x / tp.grid;
    let g1 = f32(max(tp.grid, 2u) - 1u);
    let u = (f32(gi) / g1) * 2.0 - 1.0;
    let v = (f32(gj) / g1) * 2.0 - 1.0;
    let mask = pupil_mask(u, v);
    if (mask <= 0.0) {
        rays[slot] = dead;
        return;
    }

    var pos = vec3<f32>(u * tp.pupil_mm, v * tp.pupil_mm, tp.start_z_mm);
    var dir = dir_of(light.pos_x, light.pos_y);
    var weight = 1.0;
    var current = 1.0;
    // Worst relative aperture crossing (K-261): grazing rays fade via the
    // 0.95..1 feather below instead of the hard clip alone.
    var rrel = 0.0;
    let lambda = combo.lambda_nm;

    // Phase 1: forward through 0..=b, reflecting at b.
    for (var s_idx = 0u; s_idx <= b_idx; s_idx = s_idx + 1u) {
        let s = surfaces[s_idx];
        let hit = intersect(pos, dir, s.radius_mm, s.z_mm, semi_of(s));
        if (!hit.ok) {
            rays[slot] = dead;
            return;
        }
        pos = hit.pos;
        rrel = max(rrel, sqrt(pos.x * pos.x + pos.y * pos.y) / max(semi_of(s), 1e-6));
        let n2 = cauchy_ior(s.cauchy_a, s.cauchy_b, lambda);
        let cos_i = abs(dot(hit.normal, dir));
        let r = surface_refl(cos_i, current, n2, s.coating_layers, lambda);
        if (s_idx == b_idx) {
            dir = reflect_dir(dir, hit.normal);
            weight = weight * r;
        } else {
            let refr = refract_dir(dir, hit.normal, current / n2);
            if (refr.w < 0.5) {
                rays[slot] = dead;
                return;
            }
            dir = refr.xyz;
            weight = weight * (1.0 - r);
            current = n2;
        }
    }

    // Phase 2: backward through b-1..=a, reflecting at a.
    for (var k = b_idx; k > a_idx; k = k - 1u) {
        let s_idx = k - 1u;
        let s = surfaces[s_idx];
        let hit = intersect(pos, dir, s.radius_mm, s.z_mm, semi_of(s));
        if (!hit.ok) {
            rays[slot] = dead;
            return;
        }
        pos = hit.pos;
        rrel = max(rrel, sqrt(pos.x * pos.x + pos.y * pos.y) / max(semi_of(s), 1e-6));
        var n2 = 1.0;
        if (s_idx > 0u) {
            let before = surfaces[s_idx - 1u];
            n2 = cauchy_ior(before.cauchy_a, before.cauchy_b, lambda);
        }
        let cos_i = abs(dot(hit.normal, dir));
        let r = surface_refl(cos_i, current, n2, s.coating_layers, lambda);
        if (s_idx == a_idx) {
            dir = reflect_dir(dir, hit.normal);
            weight = weight * r;
            current = cauchy_ior(s.cauchy_a, s.cauchy_b, lambda);
        } else {
            let refr = refract_dir(dir, hit.normal, current / n2);
            if (refr.w < 0.5) {
                rays[slot] = dead;
                return;
            }
            dir = refr.xyz;
            weight = weight * (1.0 - r);
            current = n2;
        }
    }

    // Phase 3: forward through a+1..n.
    for (var s_idx = a_idx + 1u; s_idx < tp.surface_count; s_idx = s_idx + 1u) {
        let s = surfaces[s_idx];
        let hit = intersect(pos, dir, s.radius_mm, s.z_mm, semi_of(s));
        if (!hit.ok) {
            rays[slot] = dead;
            return;
        }
        pos = hit.pos;
        rrel = max(rrel, sqrt(pos.x * pos.x + pos.y * pos.y) / max(semi_of(s), 1e-6));
        let n2 = cauchy_ior(s.cauchy_a, s.cauchy_b, lambda);
        let cos_i = abs(dot(hit.normal, dir));
        let r = surface_refl(cos_i, current, n2, s.coating_layers, lambda);
        let refr = refract_dir(dir, hit.normal, current / n2);
        if (refr.w < 0.5) {
            rays[slot] = dead;
            return;
        }
        dir = refr.xyz;
        weight = weight * (1.0 - r);
        current = n2;
    }

    // Propagate to the (focus-shifted) sensor plane.
    if (abs(dir.z) < 1e-12) {
        rays[slot] = dead;
        return;
    }
    let t = (tp.sensor_z_mm + tp.sensor_shift_mm - pos.z) / dir.z;
    if (!(t > 0.0)) {
        rays[slot] = dead;
        return;
    }
    let land = pos + dir * t;
    let px = land.x * tp.screen_transform + tp.raster_w / 2.0;
    let py = tp.raster_h / 2.0 - land.y * tp.screen_transform;
    if (!(abs(px) < 1e9) || !(abs(py) < 1e9)) {
        rays[slot] = dead;
        return;
    }
    // Housing feather: full inside 0.95, gone at 1.0 (smoothstep).
    let ft = clamp((1.0 - rrel) / 0.05, 0.0, 1.0);
    weight = weight * ft * ft * (3.0 - 2.0 * ft);
    var out: Ray;
    out.pos_x = px;
    out.pos_y = py;
    out.weight = weight * mask;
    out._pad = 0.0;
    rays[slot] = out;
}

fn edge_px(a: vec2<f32>, b: vec2<f32>, c: vec2<f32>) -> f32 {
    return (a.x - b.x) * (c.y - a.y) - (a.y - b.y) * (c.x - a.x);
}

@compute @workgroup_size(64)
fn quad_energy(@builtin(global_invocation_id) gid: vec3<u32>) {
    let side = tp.grid - 1u;
    let quad_count = side * side;
    if (gid.x >= quad_count || gid.y >= tp.combo_count || gid.z >= tp.light_count) {
        return;
    }
    let ray_count = tp.grid * tp.grid;
    let qx = gid.x % side;
    let qy = gid.x / side;
    let base = (gid.z * tp.combo_count + gid.y) * ray_count;
    let r00 = rays[base + qy * tp.grid + qx];
    let r10 = rays[base + qy * tp.grid + qx + 1u];
    let r11 = rays[base + (qy + 1u) * tp.grid + qx + 1u];
    let r01 = rays[base + (qy + 1u) * tp.grid + qx];
    var e = 0.0;
    if (r00.weight >= 0.0 && r10.weight >= 0.0 && r11.weight >= 0.0 && r01.weight >= 0.0) {
        let p00 = vec2<f32>(r00.pos_x, r00.pos_y);
        let p10 = vec2<f32>(r10.pos_x, r10.pos_y);
        let p11 = vec2<f32>(r11.pos_x, r11.pos_y);
        let p01 = vec2<f32>(r01.pos_x, r01.pos_y);
        let a0 = edge_px(p00, p10, p11);
        let a1 = edge_px(p00, p11, p01);
        let landed = max(abs((a0 + a1) / 2.0), 1e-4 * tp.cell_area_px);
        e = tp.cell_area_px / landed;
    }
    energies[(gid.z * tp.combo_count + gid.y) * quad_count + gid.x] = e;
}

@compute @workgroup_size(64)
fn build_verts(@builtin(global_invocation_id) gid: vec3<u32>) {
    let side = tp.grid - 1u;
    let quad_count = side * side;
    if (gid.x >= quad_count || gid.y >= tp.combo_count || gid.z >= tp.light_count) {
        return;
    }
    let slot = gid.z * tp.combo_count + gid.y;
    let combo = combos[tp.combo_offset + gid.y];
    let light = lights[gid.z];
    let qx = gid.x % side;
    let qy = gid.x / side;
    let out_base = (slot * quad_count + gid.x) * 6u;
    let e = energies[slot * quad_count + gid.x];
    if (e <= 0.0) {
        var park: Vertex;
        park.ndc_x = -4.0;
        park.ndc_y = -4.0;
        park.r = 0.0;
        park.g = 0.0;
        park.b = 0.0;
        park._pad0 = 0.0;
        park._pad1 = 0.0;
        park._pad2 = 0.0;
        for (var i = 0u; i < 6u; i = i + 1u) {
            verts[out_base + i] = park;
        }
        return;
    }
    let ray_count = tp.grid * tp.grid;
    let base = slot * ray_count;
    let c0 = rays[base + qy * tp.grid + qx];
    let c1 = rays[base + qy * tp.grid + qx + 1u];
    let c2 = rays[base + (qy + 1u) * tp.grid + qx + 1u];
    let c3 = rays[base + (qy + 1u) * tp.grid + qx];
    var p = array<vec2<f32>, 4>(
        vec2<f32>(c0.pos_x, c0.pos_y),
        vec2<f32>(c1.pos_x, c1.pos_y),
        vec2<f32>(c2.pos_x, c2.pos_y),
        vec2<f32>(c3.pos_x, c3.pos_y),
    );
    let tint = vec3<f32>(combo.rgb_r * light.r, combo.rgb_g * light.g, combo.rgb_b * light.b);
    var col = array<vec3<f32>, 4>(
        tint * (e * max(c0.weight, 0.0)),
        tint * (e * max(c1.weight, 0.0)),
        tint * (e * max(c2.weight, 0.0)),
        tint * (e * max(c3.weight, 0.0)),
    );
    // Flux-conserving sub-pixel inflation (K-261, the CPU `inflate_quad`
    // twin): a caustic-folded quad below 4 px² would be dropped by the
    // hardware raster as a zero-coverage triangle; inflate it about its
    // centroid and scale its colour by true ÷ inflated area.
    let min_quad_px = 4.0;
    let a0 = edge_px(p[0], p[1], p[2]);
    let a1 = edge_px(p[0], p[2], p[3]);
    let area_px = abs((a0 + a1) / 2.0);
    if (area_px < min_quad_px) {
        let eps = min_quad_px * 1e-4;
        let s = sqrt(min_quad_px / max(area_px, eps));
        let scale = max(area_px, eps) / min_quad_px;
        let centre = (p[0] + p[1] + p[2] + p[3]) / 4.0;
        for (var i = 0; i < 4; i = i + 1) {
            p[i] = centre + (p[i] - centre) * s;
            col[i] = col[i] * scale;
        }
    }
    for (var i = 0; i < 4; i = i + 1) {
        var vert: Vertex;
        vert.ndc_x = p[i].x / tp.raster_w * 2.0 - 1.0;
        vert.ndc_y = 1.0 - p[i].y / tp.raster_h * 2.0;
        vert.r = col[i].x;
        vert.g = col[i].y;
        vert.b = col[i].z;
        vert._pad0 = 0.0;
        vert._pad1 = 0.0;
        vert._pad2 = 0.0;
        // Stash in a scratch slot pattern below.
        if (i == 0) {
            verts[out_base] = vert;
            verts[out_base + 3u] = vert;
        } else if (i == 1) {
            verts[out_base + 1u] = vert;
        } else if (i == 2) {
            verts[out_base + 2u] = vert;
            verts[out_base + 4u] = vert;
        } else {
            verts[out_base + 5u] = vert;
        }
    }
}
