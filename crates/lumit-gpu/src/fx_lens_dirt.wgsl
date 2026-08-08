// Lens Dirt Overlay Generator (docs/08-EFFECTS.md §3.28).
// Mirrors lumit_core::fx::cpu::lens_dirt op-for-op (§1.6 oracle).

struct Params {
    tint: vec4<f32>,
    bg_colour: vec4<f32>,
    scratch_tint: vec4<f32>,
    dirt_tint: vec4<f32>,
    sun_pos: vec2<f32>,
    intensity: f32,
    density: f32,
    scale: f32,
    scale_var_x: f32,
    scale_var_y: f32,
    rotation_var: f32,
    scratch_scale: f32,
    defocus: f32,
    defocus_var: f32,
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
    color_var: f32,
    scratch_var: f32,
    dirt: f32,
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

    if (p.seed == 1337u) {
        let u_x = (f32(xy.x) + 0.5) / wf;
        let u_y = (f32(xy.y) + 0.5) / hf;
        let ee_size = vec2<f32>(textureDimensions(orig));
        let ee_coord = vec2<i32>(i32(u_x * (ee_size.x - 1.0)), i32(u_y * (ee_size.y - 1.0)));
        let ee_col = textureLoad(orig, ee_coord, 0);
        textureStore(dst, xy, vec4<f32>(ee_col.rgb, 1.0));
        return;
    }

    let diag = max(sqrt(wf * wf + hf * hf), 1.0);
    let px = f32(xy.x) + 0.5;
    let py = f32(xy.y) + 0.5;
    let nx = (px / wf - 0.5) * 2.0;
    let ny = (py / hf - 0.5) * 2.0;

    let num_layers = clamp(p.bokeh_layers, 1u, 10u);
    let density_scale = clamp(p.density / 50.0, 0.0, 40.0);
    let particle_size_base = p.scale * (diag * 0.035);
    let scale_jitter_max = max(p.scale_var_x, p.scale_var_y);

    var dirt_r: f32 = 0.0;
    var dirt_g: f32 = 0.0;
    var dirt_b: f32 = 0.0;

    // 1. Bokeh particle highlights
    for (var layer_idx = 0u; layer_idx < num_layers; layer_idx++) {
        let layer_seed = p.seed + layer_idx * 0x9e3779b9u;
        let particle_size_layer = particle_size_base * (0.7 + 0.4 * f32(layer_idx));
        let cell_size = clamp(particle_size_layer * 3.5 * (1.0 + scale_jitter_max), 24.0, 2048.0);
        let max_p = clamp(0.20 * density_scale / sqrt(f32(num_layers)), 0.05, 0.95);

        let gx = i32(floor(px / cell_size));
        let gy = i32(floor(py / cell_size));

        for (var dy = -1; dy <= 1; dy++) {
            for (var dx = -1; dx <= 1; dx++) {
                let cx = gx + dx;
                let cy = gy + dy;

                if (block_hash01(layer_seed, 0u, cx, cy, 0) > max_p) {
                    continue;
                }

                let center_x = (f32(cx) + block_hash01(layer_seed, 1u, cx, cy, 0)) * cell_size;
                let center_y = (f32(cy) + block_hash01(layer_seed, 2u, cx, cy, 0)) * cell_size;
                let radius_base = particle_size_layer * (0.3 + 1.2 * block_hash01(layer_seed, 3u, cx, cy, 0));
                let p_intensity = 0.2 + 0.8 * block_hash01(layer_seed, 4u, cx, cy, 0);

                let rad_x = max(radius_base * (1.0 + (block_hash01(layer_seed, 5u, cx, cy, 0) - 0.5) * 2.0 * p.scale_var_x), 0.1);
                let rad_y = max(radius_base * (1.0 + (block_hash01(layer_seed, 6u, cx, cy, 0) - 0.5) * 2.0 * p.scale_var_y), 0.1);

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

                let p_defocus = select(p.defocus, clamp(p.defocus + (block_hash01(layer_seed, 8u, cx, cy, 0) - 0.5) * p.defocus_var, 0.0, 1.0), p.defocus_var > 0.0);

                if (norm_d <= 1.3) {
                    var col_mult_r: f32 = 1.0;
                    var col_mult_g: f32 = 1.0;
                    var col_mult_b: f32 = 1.0;
                    if (p.color_var > 0.0) {
                        col_mult_r = max(1.0 + (block_hash01(layer_seed, 9u, cx, cy, 0) - 0.5) * p.color_var * 0.8, 0.0);
                        col_mult_g = max(1.0 + (block_hash01(layer_seed, 10u, cx, cy, 0) - 0.5) * p.color_var * 0.8, 0.0);
                        col_mult_b = max(1.0 + (block_hash01(layer_seed, 11u, cx, cy, 0) - 0.5) * p.color_var * 0.8, 0.0);
                    }

                    if (p.chromatic > 0.0) {
                        let c_scale = p.chromatic * 0.15;
                        dirt_r += bokeh_profile(norm_d / (1.0 + c_scale), p_defocus) * p_intensity * col_mult_r;
                        dirt_g += bokeh_profile(norm_d, p_defocus) * p_intensity * col_mult_g;
                        dirt_b += bokeh_profile(norm_d / max(1.0 - c_scale, 0.01), p_defocus) * p_intensity * col_mult_b;
                    } else {
                        let base_val = bokeh_profile(norm_d, p_defocus) * p_intensity;
                        dirt_r += base_val * col_mult_r;
                        dirt_g += base_val * col_mult_g;
                        dirt_b += base_val * col_mult_b;
                    }
                }
            }
        }
    }

    // 2. Hairline scratches
    if (p.scratches > 0.0) {
        let scratch_cell_size = clamp(48.0 * p.scratch_scale, 12.0, 1024.0);
        let sgx = i32(floor(px / scratch_cell_size));
        let sgy = i32(floor(py / scratch_cell_size));

        for (var sdy = -1; sdy <= 1; sdy++) {
            for (var sdx = -1; sdx <= 1; sdx++) {
                let cx = sgx + sdx;
                let cy = sgy + sdy;
                if (block_hash01(p.seed, 10u, cx, cy, 0) < min(0.25 * p.scratches, 0.8)) {
                    let p1x = (f32(cx) + block_hash01(p.seed, 11u, cx, cy, 0)) * scratch_cell_size;
                    let p1y = (f32(cy) + block_hash01(p.seed, 12u, cx, cy, 0)) * scratch_cell_size;
                    let line_len_mult = select(1.0, 1.0 + (block_hash01(p.seed, 13u, cx, cy, 0) - 0.5) * p.scratch_var * 1.6, p.scratch_var > 0.0);
                    let seg_len = max(20.0 + 30.0 * line_len_mult, 2.0) * p.scratch_scale;
                    let angle_var = select(0.0, (block_hash01(p.seed, 16u, cx, cy, 0) - 0.5) * p.scratch_var * 3.14159265359, p.scratch_var > 0.0);
                    let angle = block_hash01(p.seed, 14u, cx, cy, 0) * 6.28318530718 + angle_var;

                    let vx = cos(angle) * seg_len;
                    let vy = sin(angle) * seg_len;
                    let t_seg = clamp(((px - p1x) * vx + (py - p1y) * vy) / max(vx * vx + vy * vy, 1e-4), 0.0, 1.0);
                    let s_dist = length(vec2<f32>(px - (p1x + t_seg * vx), py - (p1y + t_seg * vy)));

                    let scratch_width = (0.75 + 0.5 * block_hash01(p.seed, 15u, cx, cy, 0)) * p.scratch_scale;
                    if (s_dist < scratch_width) {
                        let line_val = (1.0 - s_dist / scratch_width) * p.scratches * 0.7;
                        dirt_r += line_val * p.scratch_tint.r;
                        dirt_g += line_val * p.scratch_tint.g;
                        dirt_b += line_val * p.scratch_tint.b;
                    }
                }
            }
        }
    }

    dirt_r *= p.tint.r;
    dirt_g *= p.tint.g;
    dirt_b *= p.tint.b;

    // 3. Glass dirt & dust specks
    if (p.dirt > 0.0) {
        let d_cell_size = clamp(64.0 * p.scratch_scale, 16.0, 512.0);
        let dgx = i32(floor(px / d_cell_size));
        let dgy = i32(floor(py / d_cell_size));

        for (var ddy = -1; ddy <= 1; ddy++) {
            for (var ddx = -1; ddx <= 1; ddx++) {
                let cx = dgx + ddx;
                let cy = dgy + ddy;
                if (block_hash01(p.seed, 20u, cx, cy, 0) < min(0.35 * p.dirt, 0.8)) {
                    let d_cx = (f32(cx) + block_hash01(p.seed, 21u, cx, cy, 0)) * d_cell_size;
                    let d_cy = (f32(cy) + block_hash01(p.seed, 22u, cx, cy, 0)) * d_cell_size;
                    let d_rad = (3.0 + 8.0 * block_hash01(p.seed, 23u, cx, cy, 0)) * p.scratch_scale;
                    let d_dist = length(vec2<f32>(px - d_cx, py - d_cy)) / max(d_rad, 0.5);
                    if (d_dist <= 1.0) {
                        let spot_val = (1.0 - d_dist * d_dist) * p.dirt * 0.5;
                        dirt_r += spot_val * p.dirt_tint.r;
                        dirt_g += spot_val * p.dirt_tint.g;
                        dirt_b += spot_val * p.dirt_tint.b;
                    }
                }
            }
        }
    }

    dirt_r *= p.intensity;
    dirt_g *= p.intensity;
    dirt_b *= p.intensity;

    if (p.vignette > 0.0) {
        let v_factor = clamp(1.0 - p.vignette * 0.5 * (nx * nx + ny * ny), 0.0, 1.0);
        dirt_r *= v_factor;
        dirt_g *= v_factor;
        dirt_b *= v_factor;
    }

    var bg_r: f32 = 0.0;
    var bg_g: f32 = 0.0;
    var bg_b: f32 = 0.0;

    if (p.bg_mode > 0u) {
        bg_r = p.bg_colour.r;
        bg_g = p.bg_colour.g;
        bg_b = p.bg_colour.b;
        if (p.bg_mode == 2u) {
            let min_dim = max(min(wf, hf), 1.0);
            let sun_dx = (px / wf - p.sun_pos.x) * (wf / min_dim);
            let sun_dy = (py / hf - p.sun_pos.y) * (hf / min_dim);
            let sun_dist = sqrt(sun_dx * sun_dx + sun_dy * sun_dy);

            let core = pow(max(1.0 - sun_dist / max(p.sun_radius * 0.2, 0.001), 0.0), 2.0) * 2.0;
            let halo = 1.0 / (1.0 + pow(sun_dist / max(p.sun_radius * 0.8, 0.001), 2.0));
            let sun_light = (core + halo) * p.sun_intensity;

            bg_r += p.tint.r * sun_light;
            bg_g += p.tint.g * sun_light;
            bg_b += p.tint.b * sun_light;
        }
    }

    let eff_r = bg_r + dirt_r;
    let eff_g = bg_g + dirt_g;
    let eff_b = bg_b + dirt_b;

    let src_r = original.r;
    let src_g = original.g;
    let src_b = original.b;
    let src_a = original.a;

    var out_r: f32;
    var out_g: f32;
    var out_b: f32;

    switch (p.blend_mode) {
        case 0u: { // Screen
            out_r = 1.0 - (1.0 - src_r) * (1.0 - eff_r);
            out_g = 1.0 - (1.0 - src_g) * (1.0 - eff_g);
            out_b = 1.0 - (1.0 - src_b) * (1.0 - eff_b);
        }
        case 1u: { // Add
            out_r = src_r + eff_r;
            out_g = src_g + eff_g;
            out_b = src_b + eff_b;
        }
        case 2u: { // Overlay
            out_r = select(1.0 - 2.0 * (1.0 - src_r) * (1.0 - (eff_r + 0.5)), 2.0 * src_r * (eff_r + 0.5), src_r < 0.5);
            out_g = select(1.0 - 2.0 * (1.0 - src_g) * (1.0 - (eff_g + 0.5)), 2.0 * src_g * (eff_g + 0.5), src_g < 0.5);
            out_b = select(1.0 - 2.0 * (1.0 - src_b) * (1.0 - (eff_b + 0.5)), 2.0 * src_b * (eff_b + 0.5), src_b < 0.5);
        }
        default: { // Solo
            out_r = eff_r;
            out_g = eff_g;
            out_b = eff_b;
        }
    }

    let final_r = mix(src_r, out_r, p.mix_amt);
    let final_g = mix(src_g, out_g, p.mix_amt);
    let final_b = mix(src_b, out_b, p.mix_amt);

    textureStore(dst, xy, vec4<f32>(final_r, final_g, final_b, src_a));
}
