// Lens flare (docs/08-EFFECTS.md §3.27, docs/impl/lens-flare.md, K-256).
// Five entry points, one frame pipeline:
//   trace         — one thread per ray: refract/reflect the launch grid
//                   through the lens for one (ghost × wavelength) combo.
//                   Mirrors lumit_core::fx::lens_flare::trace_ray op-for-op
//                   (the §1.6 staged oracle holds it to ≤ 2 f32 ULP); the
//                   one deliberate difference is the dead-ray sentinel:
//                   reflectance −1 here, NaN on the CPU (WGSL does not
//                   guarantee NaN propagation).
//   quad_energy   — one thread per grid cell: launch area / landed area
//                   (energy conservation), dead-corner cells culled to 0.
//   build_verts   — one thread per cell: emits the cell's two triangles (six
//                   duplicated vertices) with corner-averaged energies;
//                   culled cells park off-screen at zero intensity.
//   vs_flare / fs_flare — the render pass: vertex pulling from the built
//                   buffer, additive blend into the fp16 flare buffer;
//                   fragment = disc(uv) · housing feather · rgb intensity.
//   combine       — out = orig + intensity · (flare(squeezed) + starburst);
//                   alpha saturates toward 1; Mix lerps against the input.
//                   Mirrors lens_flare::cpu_combine (manual bilinear taps so
//                   the CPU reference and this kernel read the same maths).

struct Surface {
    radius_mm: f32,
    center_z_mm: f32,
    height_mm: f32,
    cauchy_a: f32,
    cauchy_b: f32,
    coating_nm: f32,
    is_iris: f32,
    is_sensor: f32,
};

// One (ghost × wavelength) combo: the two bounce surfaces, the traced
// wavelength, and the wavelength's normalised linear-RGB weight already
// multiplied by the ghost-energy gain.
struct Combo {
    bounce1: u32,
    bounce2: u32,
    lambda_nm: f32,
    _pad: f32,
    rgb_r: f32,
    rgb_g: f32,
    rgb_b: f32,
    _pad2: f32,
};

struct Ray {
    pos_x: f32,
    pos_y: f32,
    uv_x: f32,
    uv_y: f32,
    rrel: f32,
    reflectance: f32, // −1 = dead (the GPU's NaN stand-in)
};

struct Vertex {
    ndc_x: f32,
    ndc_y: f32,
    uv_x: f32,
    uv_y: f32,
    r: f32,
    g: f32,
    b: f32,
    rrel: f32,
};

struct TraceParams {
    surface_count: u32,
    combo_count: u32,
    grid: u32,
    combo_offset: u32, // first combo of this batch
    launch_mm: f32,
    coating: f32,
    dir_x: f32,
    dir_y: f32,
    dir_z: f32,
    // Projection for build_verts.
    screen_transform: f32, // raster px per sensor mm
    raster_w: f32,
    raster_h: f32,
};

@group(0) @binding(0) var<storage, read> surfaces: array<Surface>;
@group(0) @binding(1) var<storage, read> combos: array<Combo>;
@group(0) @binding(2) var<storage, read_write> rays: array<Ray>;
@group(0) @binding(3) var<storage, read_write> energies: array<f32>;
@group(0) @binding(4) var<storage, read_write> verts: array<Vertex>;
@group(0) @binding(5) var<uniform> tp: TraceParams;

fn cauchy_ior(a: f32, b: f32, lambda_nm: f32) -> f32 {
    let um = lambda_nm * 1e-3;
    return a + b / (um * um);
}

fn fresnel_plain(theta0: f32, n1: f32, n2: f32) -> f32 {
    let s = clamp(sin(theta0) * n1 / n2, -1.0, 1.0);
    let theta1 = asin(s);
    let ci = cos(theta0);
    let ct = cos(theta1);
    let rs = (n1 * ci - n2 * ct) / (n1 * ci + n2 * ct);
    let rp = (n1 * ct - n2 * ci) / (n1 * ct + n2 * ci);
    return (rs * rs + rp * rp) / 2.0;
}

fn fresnel_ar(theta0: f32, lambda_nm: f32, d_nm: f32, n0: f32, n1: f32, n2: f32) -> f32 {
    let theta1 = asin(clamp(sin(theta0) * n0 / n1, -1.0, 1.0));
    let theta2 = asin(clamp(sin(theta0) * n0 / n2, -1.0, 1.0));

    let rs01 = -sin(theta0 - theta1) / sin(theta0 + theta1);
    let rp01 = tan(theta0 - theta1) / tan(theta0 + theta1);
    let ts01 = 2.0 * sin(theta1) * cos(theta0) / sin(theta0 + theta1);
    let tp01 = ts01 * cos(theta0 - theta1);

    let rs12 = -sin(theta1 - theta2) / sin(theta1 + theta2);
    let rp12 = tan(theta1 - theta2) / tan(theta1 + theta2);

    let ris = ts01 * ts01 * rs12;
    let rip = tp01 * tp01 * rp12;

    let dy = d_nm * n1;
    let dx = tan(theta1) * dy;
    let delay = sqrt(dx * dx + dy * dy);
    let rel_phase = 4.0 * 3.14159265358979 / lambda_nm * (delay - dx * sin(theta0));

    let out_s2 = rs01 * rs01 + ris * ris + 2.0 * rs01 * ris * cos(rel_phase);
    let out_p2 = rp01 * rp01 + rip * rip + 2.0 * rp01 * rip * cos(rel_phase);
    return (out_s2 + out_p2) / 2.0;
}

fn refract3(i: vec3<f32>, n: vec3<f32>, o: f32) -> vec3<f32> {
    let cost = dot(-i, n);
    let sint2 = o * o * (1.0 - cost * cost);
    let k = o * cost - sqrt(abs(1.0 - sint2));
    return (o * i + k * n) * f32(sint2 < 1.0);
}

struct SurfHit {
    pos: vec3<f32>,
    normal: vec3<f32>,
    incident: f32,
    hit: bool,
};

fn intersect(pos: vec3<f32>, dir: vec3<f32>, s: Surface) -> SurfHit {
    var out: SurfHit;
    out.pos = vec3<f32>(0.0);
    out.normal = vec3<f32>(0.0, 0.0, 1.0);
    out.incident = 0.0;
    out.hit = false;
    if (dir.z == 0.0) {
        return out;
    }
    if (s.radius_mm == 0.0) {
        let dz = -s.center_z_mm - pos.z;
        let t = dz / dir.z;
        out.pos = pos + dir * t;
        if (dir.z < 0.0) {
            out.normal = vec3<f32>(0.0, 0.0, 1.0);
        } else {
            out.normal = vec3<f32>(0.0, 0.0, -1.0);
        }
        out.hit = true;
        return out;
    }
    let r = abs(s.radius_mm);
    let c = vec3<f32>(0.0, 0.0, -s.center_z_mm);
    let u = c - pos;
    let du = dot(u, dir);
    let u1 = dir * du;
    let perp = u - u1;
    let d = length(perp);
    if (d > r) {
        return out;
    }
    var sgn = 1.0;
    if (s.radius_mm * dir.z > 0.0) {
        sgn = -1.0;
    }
    let m = sqrt(r * r - d * d);
    let p = pos + u1 - m * dir * sgn;
    var n = p - c;
    let len = max(length(n), 1e-12);
    n = n / len * sgn;
    let cosi = clamp(dot(-dir, n), -1.0, 1.0);
    out.pos = p;
    out.normal = n;
    out.incident = acos(cosi);
    out.hit = true;
    return out;
}

// Trace one ray for one combo. Returns a dead ray (reflectance −1) on any
// miss / total internal reflection, exactly where the CPU returns NaN.
fn trace_one(combo: Combo, cell: vec2<u32>) -> Ray {
    var dead: Ray;
    dead.pos_x = 0.0;
    dead.pos_y = 0.0;
    dead.uv_x = 0.0;
    dead.uv_y = 0.0;
    dead.rrel = 0.0;
    dead.reflectance = -1.0;

    let count = i32(tp.surface_count);
    let g = f32(max(tp.grid, 2u));
    let px = tp.launch_mm * (f32(cell.x) / (g - 1.0) - 0.5);
    let py = tp.launch_mm * (0.5 - f32(cell.y) / (g - 1.0));
    let dir = vec3<f32>(tp.dir_x, tp.dir_y, tp.dir_z);

    let probe = intersect(vec3<f32>(px, py, 1.0), vec3<f32>(0.0, 0.0, -1.0), surfaces[0]);
    if (!probe.hit) {
        return dead;
    }
    var pos = probe.pos - dir;
    var rdir = dir;
    var uv = vec2<f32>(0.0);
    var rrel = 0.0;
    var reflectance = 1.0;

    var step_n = 0;
    var delta = 1;
    var lens_id = 0;
    let max_iters = count * 4;
    var iters = 0;
    loop {
        if (lens_id < 0 || lens_id >= count) {
            break;
        }
        iters = iters + 1;
        if (iters > max_iters) {
            return dead;
        }
        let s = surfaces[lens_id];
        let hit = intersect(pos, rdir, s);
        if (!hit.hit) {
            return dead;
        }
        pos = hit.pos;

        if (s.is_iris > 0.5) {
            uv = vec2<f32>(pos.x / s.height_mm, pos.y / s.height_mm);
            lens_id = lens_id + delta;
            continue;
        }
        let r = length(pos.xy) / s.height_mm;
        rrel = max(rrel, r);

        if (s.is_sensor > 0.5) {
            lens_id = lens_id + delta;
            continue;
        }

        let do_reflect = (step_n == 0 && lens_id == i32(combo.bounce1))
            || (step_n == 1 && lens_id == i32(combo.bounce2));
        if (do_reflect) {
            step_n = step_n + 1;
            delta = -delta;
        }

        var n_index = lens_id + 1;
        if (rdir.z < 0.0) {
            n_index = lens_id - 1;
        }
        var n1 = 1.0;
        if (n_index >= 0 && n_index < count) {
            let ns = surfaces[n_index];
            n1 = cauchy_ior(ns.cauchy_a, ns.cauchy_b, combo.lambda_nm);
        }
        let n2 = cauchy_ior(s.cauchy_a, s.cauchy_b, combo.lambda_nm);

        if (do_reflect) {
            rdir = reflect(rdir, hit.normal);
            let theta = hit.incident + 1e-9;
            let plain = fresnel_plain(theta, n1, n2);
            var refl = plain;
            if (tp.coating > 0.0 && s.coating_nm > 0.0) {
                let nc = max(sqrt(n1 * n2), 1.38);
                let d = s.coating_nm / (4.0 * nc);
                let coated = fresnel_ar(theta, combo.lambda_nm, d, n1, nc, n2);
                refl = plain + (coated - plain) * tp.coating;
            }
            if (refl > 0.0) {
                reflectance = reflectance * refl;
            }
        } else {
            rdir = refract3(rdir, hit.normal, n1 / n2);
            if (rdir.z == 0.0) {
                return dead;
            }
        }
        lens_id = lens_id + delta;
    }
    if (lens_id < count) {
        return dead;
    }
    var out: Ray;
    out.pos_x = pos.x;
    out.pos_y = pos.y;
    out.uv_x = uv.x;
    out.uv_y = uv.y;
    out.rrel = rrel;
    out.reflectance = reflectance;
    return out;
}

@compute @workgroup_size(64)
fn trace(@builtin(global_invocation_id) gid: vec3<u32>) {
    let ray_count = tp.grid * tp.grid;
    if (gid.x >= ray_count || gid.y >= tp.combo_count) {
        return;
    }
    let combo = combos[tp.combo_offset + gid.y];
    let cell = vec2<u32>(gid.x % tp.grid, gid.x / tp.grid);
    rays[gid.y * ray_count + gid.x] = trace_one(combo, cell);
}

// Shoelace edge function on landed sensor positions (mm).
fn edge_mm(a: vec2<f32>, b: vec2<f32>, c: vec2<f32>) -> f32 {
    return (a.x - b.x) * (c.y - a.y) - (a.y - b.y) * (c.x - a.x);
}

@compute @workgroup_size(64)
fn quad_energy(@builtin(global_invocation_id) gid: vec3<u32>) {
    let side = tp.grid - 1u;
    let quad_count = side * side;
    if (gid.x >= quad_count || gid.y >= tp.combo_count) {
        return;
    }
    let ray_count = tp.grid * tp.grid;
    let qx = gid.x % side;
    let qy = gid.x / side;
    let base = gid.y * ray_count;
    let r00 = rays[base + qy * tp.grid + qx];
    let r10 = rays[base + qy * tp.grid + qx + 1u];
    let r11 = rays[base + (qy + 1u) * tp.grid + qx + 1u];
    let r01 = rays[base + (qy + 1u) * tp.grid + qx];
    var e = 0.0;
    if (r00.reflectance >= 0.0 && r10.reflectance >= 0.0
        && r11.reflectance >= 0.0 && r01.reflectance >= 0.0) {
        let p00 = vec2<f32>(r00.pos_x, r00.pos_y);
        let p10 = vec2<f32>(r10.pos_x, r10.pos_y);
        let p11 = vec2<f32>(r11.pos_x, r11.pos_y);
        let p01 = vec2<f32>(r01.pos_x, r01.pos_y);
        let cell_mm = tp.launch_mm / (f32(max(tp.grid, 2u)) - 1.0);
        let area_launch = cell_mm * cell_mm;
        let min_area = 0.01 * area_launch; // MIN_AREA_FRAC (impl note §7)
        let a0 = edge_mm(p00, p10, p11);
        let a1 = edge_mm(p00, p11, p01);
        let area = max(abs((a0 + a1) / 2.0), min_area);
        e = area_launch / area;
    }
    energies[gid.y * quad_count + gid.x] = e;
}

// The energy averaged over the live cells sharing corner (vx, vy).
fn corner_energy(combo_id: u32, vx: i32, vy: i32) -> f32 {
    let side = i32(tp.grid - 1u);
    let quad_count = u32(side * side);
    var sum = 0.0;
    var count = 0.0;
    for (var oy = -1; oy <= 0; oy = oy + 1) {
        for (var ox = -1; ox <= 0; ox = ox + 1) {
            let nx = vx + ox;
            let ny = vy + oy;
            if (nx >= 0 && nx < side && ny >= 0 && ny < side) {
                let e = energies[combo_id * quad_count + u32(ny * side + nx)];
                if (e > 0.0) {
                    sum = sum + e;
                    count = count + 1.0;
                }
            }
        }
    }
    return sum / max(count, 1.0);
}

fn build_corner(combo: Combo, combo_id: u32, cx: u32, cy: u32) -> Vertex {
    let ray_count = tp.grid * tp.grid;
    let r = rays[combo_id * ray_count + cy * tp.grid + cx];
    let e = corner_energy(combo_id, i32(cx), i32(cy));
    let refl = max(r.reflectance, 0.0);
    let gain = e * refl;
    // Sensor mm → raster px (y flip) → NDC (y up).
    let px = r.pos_x * tp.screen_transform + tp.raster_w / 2.0;
    let py = tp.raster_h / 2.0 - r.pos_y * tp.screen_transform;
    var v: Vertex;
    v.ndc_x = px / tp.raster_w * 2.0 - 1.0;
    v.ndc_y = 1.0 - py / tp.raster_h * 2.0;
    v.uv_x = r.uv_x;
    v.uv_y = r.uv_y;
    v.r = combo.rgb_r * gain;
    v.g = combo.rgb_g * gain;
    v.b = combo.rgb_b * gain;
    v.rrel = r.rrel;
    return v;
}

@compute @workgroup_size(64)
fn build_verts(@builtin(global_invocation_id) gid: vec3<u32>) {
    let side = tp.grid - 1u;
    let quad_count = side * side;
    if (gid.x >= quad_count || gid.y >= tp.combo_count) {
        return;
    }
    let combo = combos[tp.combo_offset + gid.y];
    let qx = gid.x % side;
    let qy = gid.x / side;
    let out_base = (gid.y * quad_count + gid.x) * 6u;
    let live = energies[gid.y * quad_count + gid.x] > 0.0;
    if (!live) {
        // Park the whole cell off-screen at zero intensity.
        var park: Vertex;
        park.ndc_x = -4.0;
        park.ndc_y = -4.0;
        park.uv_x = 0.0;
        park.uv_y = 0.0;
        park.r = 0.0;
        park.g = 0.0;
        park.b = 0.0;
        park.rrel = 0.0;
        for (var i = 0u; i < 6u; i = i + 1u) {
            verts[out_base + i] = park;
        }
        return;
    }
    // Corners (x, y), (x+1, y), (x+1, y+1), (x, y+1); triangles (0,1,2) and
    // (0,2,3) — the split the CPU reference mirrors exactly.
    let c0 = build_corner(combo, gid.y, qx, qy);
    let c1 = build_corner(combo, gid.y, qx + 1u, qy);
    let c2 = build_corner(combo, gid.y, qx + 1u, qy + 1u);
    let c3 = build_corner(combo, gid.y, qx, qy + 1u);
    verts[out_base] = c0;
    verts[out_base + 1u] = c1;
    verts[out_base + 2u] = c2;
    verts[out_base + 3u] = c0;
    verts[out_base + 4u] = c2;
    verts[out_base + 5u] = c3;
}

