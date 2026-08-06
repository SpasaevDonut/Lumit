// Lens Dirt Overlay Generator (docs/08-EFFECTS.md §3.28).
// Mirrors lumit_core::fx::cpu::lens_dirt op-for-op (§1.6 oracle).

struct Params {
    tint: vec4<f32>,

    bg_colour: vec4<f32>,
    sun_pos: vec2<f32>,
    intensity: f32,
    density: f32,
    scale: f32,
    scale_var_x: f32,
    scale_var_y: f32,
    rotation_var: f32,
    scratch_scale: f32,
    defocus: f32,
    chromatic: f32,
    scratches: f32,
    vignette: f32,
    sun_intensity: f32,
    sun_radius: f32,
    blend_mode: u32,
    bg_mode: u32,
    bokeh_layers: u32,
    seed: u32,
    mix_amt: f32,
    _pad0: f32,
    _pad1: f32,
    _pad2: f32,
    _pad3: f32,
};


@group(0) @binding(0) var src: texture_2d<f32>;
@group(0) @binding(1) var orig: texture_2d<f32>;
@group(0) @binding(2) var dst: texture_storage_2d<rgba16float, write>;
@group(0) @binding(3) var<uniform> p: Params;

fn splitmix32(xin: u32) -> u32 {
    var x = xin;
    x = x + 0x9e3779b9u;
    x = x ^ (x >> 16u);
    x = x * 0x21f0aaadu;
    x = x ^ (x >> 15u);
    x = x * 0x735a2d97u;
    x = x ^ (x >> 15u);
    return x;
}


fn block_hash01(seed: u32, channel: u32, bx: i32, by: i32, tick: i32) -> f32 {
    var h = seed;
    h = splitmix32(h ^ channel);
    h = splitmix32(h ^ bitcast<u32>(bx));
    h = splitmix32(h ^ bitcast<u32>(by));
    h = splitmix32(h ^ bitcast<u32>(tick));
    return f32(h >> 8u) / 16777216.0;
}

fn bokeh_profile(norm_d: f32, defocus: f32) -> f32 {
    if (norm_d > 1.0) {
        return 0.0;
    }
    var ring: f32 = 1.0 - norm_d * norm_d;
    if (defocus > 0.05) {
        let ring_pos = clamp(1.0 - defocus * 0.45, 0.1, 0.95);
        if (norm_d >= ring_pos) {
            let t = (norm_d - ring_pos) / (1.0 - ring_pos);
            ring = 0.5 + 1.0 * t * t;
        } else {
            let t_in = norm_d / ring_pos;
            ring = 0.5 + 0.5 * t_in * t_in;
        }
    }
    return (1.0 - norm_d * norm_d) * ring;
}

@compute @workgroup_size(8, 8)
fn lens_dirt(@builtin(global_invocation_id) gid: vec3<u32>) {
    let size = vec2<i32>(textureDimensions(src));
    let xy = vec2<i32>(gid.xy);
    if (xy.x >= size.x || xy.y >= size.y) {
        return;
    }

    let original = textureLoad(src, xy, 0);
    if (p.intensity == 0.0 || p.mix_amt == 0.0) {
        textureStore(dst, xy, original);
        return;
    }

    let wf = f32(size.x);
    let hf = f32(size.y);
    let diag = max(sqrt(wf * wf + hf * hf), 1.0);

    let seed = p.seed;
    let density_scale = clamp(p.density / 50.0, 0.0, 40.0);
    let num_layers = clamp(p.bokeh_layers, 1u, 10u);
    let particle_size_base = p.scale * (diag * 0.035);
    let scratch_amount = p.scratches;
    let defocus = p.defocus;
    let chromatic = p.chromatic;
    let vignette_strength = p.vignette;
    let blend_mode = p.blend_mode;
    let mix_amt = p.mix_amt;
    let intensity = p.intensity;
    let tint = p.tint;

    let px = f32(xy.x) + 0.5;
    let py = f32(xy.y) + 0.5;
    let nx = (px / wf - 0.5) * 2.0;
    let ny = (py / hf - 0.5) * 2.0;

    let scale_jitter_max = max(p.scale_var_x, p.scale_var_y);

    var dirt_r: f32 = 0.0;
    var dirt_g: f32 = 0.0;
    var dirt_b: f32 = 0.0;

    for (var layer_idx = 0u; layer_idx < num_layers; layer_idx++) {
        let layer_seed = seed + layer_idx * 0x9e3779b9u;
        let layer_scale_factor = 0.7 + 0.4 * f32(layer_idx);
        let particle_size_layer = particle_size_base * layer_scale_factor;
        let cell_size = clamp(particle_size_layer * 3.5 * (1.0 + scale_jitter_max), 24.0, 2048.0);

        let max_p = clamp(0.20 * density_scale / sqrt(f32(num_layers)), 0.05, 0.95);

        let gx = i32(floor(px / cell_size));
        let gy = i32(floor(py / cell_size));

        for (var dy = -1; dy <= 1; dy++) {
            for (var dx = -1; dx <= 1; dx++) {
                let cx = gx + dx;
                let cy = gy + dy;

                let prob = block_hash01(layer_seed, 0u, cx, cy, 0);
                if (prob > max_p) {
                    continue;
                }

                let center_x = (f32(cx) + block_hash01(layer_seed, 1u, cx, cy, 0)) * cell_size;
                let center_y = (f32(cy) + block_hash01(layer_seed, 2u, cx, cy, 0)) * cell_size;
                let radius_base = particle_size_layer * (0.3 + 1.2 * block_hash01(layer_seed, 3u, cx, cy, 0));
                let p_intensity = 0.2 + 0.8 * block_hash01(layer_seed, 4u, cx, cy, 0);

                let rx_mult = 1.0 + (block_hash01(layer_seed, 5u, cx, cy, 0) - 0.5) * 2.0 * p.scale_var_x;
                let ry_mult = 1.0 + (block_hash01(layer_seed, 6u, cx, cy, 0) - 0.5) * 2.0 * p.scale_var_y;
                let rad_x = max(radius_base * rx_mult, 0.1);
                let rad_y = max(radius_base * ry_mult, 0.1);

                var dx_raw = px - center_x;
                var dy_raw = py - center_y;
                if (p.rotation_var > 0.0) {
                    let angle = (block_hash01(layer_seed, 7u, cx, cy, 0) - 0.5) * 3.14159265359 * p.rotation_var;
                    let cos_a = cos(angle);
                    let sin_a = sin(angle);
                    let rx = dx_raw * cos_a + dy_raw * sin_a;
                    let ry = -dx_raw * sin_a + dy_raw * cos_a;
                    dx_raw = rx;
                    dy_raw = ry;
                }

                let dist_x = dx_raw / rad_x;
                let dist_y = dy_raw / rad_y;
                let norm_d = sqrt(dist_x * dist_x + dist_y * dist_y);

                if (norm_d <= 1.3) {
                    let base_val = bokeh_profile(norm_d, defocus) * p_intensity;
                    if (chromatic > 0.0) {
                        let fringe = chromatic * 0.15 * norm_d;
                        let r_val = bokeh_profile(norm_d + fringe, defocus) * p_intensity;
                        let b_val = bokeh_profile(norm_d - fringe, defocus) * p_intensity;
                        dirt_r += r_val;
                        dirt_g += base_val;
                        dirt_b += b_val;
                    } else {
                        dirt_r += base_val;
                        dirt_g += base_val;
                        dirt_b += base_val;
                    }
                }
            }
        }
    }

    if (scratch_amount > 0.0) {
        let scratch_scale = p.scratch_scale;
        let scratch_cell_size = clamp(48.0 * scratch_scale, 12.0, 1024.0);
        let sgx = i32(floor(px / scratch_cell_size));
        let sgy = i32(floor(py / scratch_cell_size));
        let sprob = block_hash01(seed, 10u, sgx, sgy, 0);

        let max_sprob = min(0.25 * scratch_amount, 0.8);
        if (sprob < max_sprob) {
            let p1x = (f32(sgx) + block_hash01(seed, 11u, sgx, sgy, 0)) * scratch_cell_size;
            let p1y = (f32(sgy) + block_hash01(seed, 12u, sgx, sgy, 0)) * scratch_cell_size;
            let seg_len = (20.0 + 30.0 * block_hash01(seed, 13u, sgx, sgy, 0)) * scratch_scale;
            let angle = block_hash01(seed, 14u, sgx, sgy, 0) * 6.28318530718;
            let p2x = p1x + cos(angle) * seg_len;
            let p2y = p1y + sin(angle) * seg_len;

            let vx = p2x - p1x;
            let vy = p2y - p1y;
            let len_sq = max(vx * vx + vy * vy, 1e-4);
            let t_seg = clamp(((px - p1x) * vx + (py - p1y) * vy) / len_sq, 0.0, 1.0);
            let proj_x = p1x + t_seg * vx;
            let proj_y = p1y + t_seg * vy;
            let s_dist = sqrt((px - proj_x) * (px - proj_x) + (py - proj_y) * (py - proj_y));

            let scratch_width = (0.75 + 0.5 * block_hash01(seed, 15u, sgx, sgy, 0)) * scratch_scale;
            if (s_dist < scratch_width) {
                let line_val = (1.0 - s_dist / scratch_width) * scratch_amount * 0.7;
                dirt_r += line_val;
                dirt_g += line_val;
                dirt_b += line_val;
            }
        }
    }

    dirt_r *= intensity * tint.r;
    dirt_g *= intensity * tint.g;
    dirt_b *= intensity * tint.b;

    if (vignette_strength > 0.0) {
        let r_sq = nx * nx + ny * ny;
        let v_factor = clamp(1.0 - vignette_strength * 0.5 * r_sq, 0.0, 1.0);
        dirt_r *= v_factor;
        dirt_g *= v_factor;
        dirt_b *= v_factor;
    }

    var src_r = original.r;
    var src_g = original.g;
    var src_b = original.b;
    var src_a = original.a;

    if (p.bg_mode > 0u) {
        src_r = p.bg_colour.r;
        src_g = p.bg_colour.g;
        src_b = p.bg_colour.b;
        src_a = p.bg_colour.a;
        if (p.bg_mode == 2u) {
            let min_dim = max(min(wf, hf), 1.0);
            let u = px / wf;
            let v = py / hf;
            let sun_dx = (u - p.sun_pos.x) * (wf / min_dim);
            let sun_dy = (v - p.sun_pos.y) * (hf / min_dim);
            let sun_dist = sqrt(sun_dx * sun_dx + sun_dy * sun_dy);

            let core = pow(1.0 - clamp(sun_dist / max(p.sun_radius * 0.2, 0.001), 0.0, 1.0), 2.0) * 2.0;
            let halo = 1.0 / (1.0 + pow(sun_dist / max(p.sun_radius * 0.8, 0.001), 2.0));
            let sun_light = (core + halo) * p.sun_intensity;

            src_r += tint.r * sun_light;
            src_g += tint.g * sun_light;
            src_b += tint.b * sun_light;
        }
    }

    var out_r: f32 = 0.0;

    var out_g: f32 = 0.0;
    var out_b: f32 = 0.0;

    if (blend_mode == 0u) {
        out_r = 1.0 - (1.0 - src_r) * (1.0 - dirt_r);
        out_g = 1.0 - (1.0 - src_g) * (1.0 - dirt_g);
        out_b = 1.0 - (1.0 - src_b) * (1.0 - dirt_b);
    } else if (blend_mode == 1u) {
        out_r = src_r + dirt_r;
        out_g = src_g + dirt_g;
        out_b = src_b + dirt_b;
    } else if (blend_mode == 2u) {
        if (src_r < 0.5) { out_r = 2.0 * src_r * (dirt_r + 0.5); } else { out_r = 1.0 - 2.0 * (1.0 - src_r) * (1.0 - (dirt_r + 0.5)); }
        if (src_g < 0.5) { out_g = 2.0 * src_g * (dirt_g + 0.5); } else { out_g = 1.0 - 2.0 * (1.0 - src_g) * (1.0 - (dirt_g + 0.5)); }
        if (src_b < 0.5) { out_b = 2.0 * src_b * (dirt_b + 0.5); } else { out_b = 1.0 - 2.0 * (1.0 - src_b) * (1.0 - (dirt_b + 0.5)); }
    } else {
        out_r = dirt_r;
        out_g = dirt_g;
        out_b = dirt_b;
    }

    var final_color: vec4<f32>;
    final_color.r = original.r * (1.0 - mix_amt) + out_r * mix_amt;
    final_color.g = original.g * (1.0 - mix_amt) + out_g * mix_amt;
    final_color.b = original.b * (1.0 - mix_amt) + out_b * mix_amt;
    final_color.a = src_a;

    textureStore(dst, xy, final_color);
}
