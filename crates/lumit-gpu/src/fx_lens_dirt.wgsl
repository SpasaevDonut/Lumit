// Lens dirt (docs/08-EFFECTS.md §3.28, K-314). Mirrors
// `lumit_core::fx::cpu::lens_dirt` op-for-op (§1.6: the CPU is the oracle).
//
// **In plain terms, and this is the whole effect.** A clean lens is invisible.
// A dirty one is *also* invisible — right up until a bright light shines
// through it, and then the muck lights up. Dirt does not emit; it
// forward-scatters whatever passes through it. So the dirt field is generated
// once and then MULTIPLIED by a blurred, thresholded copy of the picture's own
// highlights (binding 1, produced by two pre-passes this effect shares with
// Glow), which is why it appears around a street lamp and disappears in a dark
// shot. Adding dirt unconditionally is the one thing that makes a lens-dirt
// effect look painted on.
//
// Bindings: 0 the source (also the original — this is the last pass, so the two
// are the same texture), 1 the blurred highlight pass, 2 the optional dirt
// plate (a photographed smeared filter; when bound it REPLACES the procedural
// field), 3 the storage output, 4 the uniform. The shared three-sampled-input
// shape it borrows from Motion blur.

struct Params {
    tint: vec4<f32>,
    intensity: f32,
    response: f32,
    density: f32,
    scale: f32,
    roughness: f32,
    defocus: f32,
    smudge: f32,
    specks: f32,
    scratches: f32,
    scratch_scale: f32,
    scratch_var: f32,
    colour_var: f32,
    chromatic: f32,
    vignette: f32,
    mix_amt: f32,
    blend_mode: u32,
    plate_bound: u32,
    plate_channel: u32,
    seed: u32,
    easter_egg: u32,
    // To a whole number of 16-byte rows: WGSL rounds a struct's size up to its
    // alignment and `repr(C)` does not, so the host side pads to match or the
    // dispatch is rejected for a 108-vs-112-byte buffer.
    _pad0: u32,
    _pad1: u32,
    _pad2: u32,
    _pad3: u32,
};

@group(0) @binding(0) var src: texture_2d<f32>;
@group(0) @binding(1) var light: texture_2d<f32>;
@group(0) @binding(2) var plate: texture_2d<f32>;
@group(0) @binding(3) var dst: texture_storage_2d<rgba16float, write>;
@group(0) @binding(4) var<uniform> p: Params;

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

// Mirrors `lumit_core::fx::block_hash01`.
fn block_hash01(seed: u32, channel: u32, bx: i32, by: i32, tick: i32) -> f32 {
    var h = seed;
    h = splitmix32(h ^ channel);
    h = splitmix32(h ^ bitcast<u32>(bx));
    h = splitmix32(h ^ bitcast<u32>(by));
    h = splitmix32(h ^ bitcast<u32>(tick));
    return f32(h >> 8u) / 16777216.0;
}

// One channel of an auxiliary picture, by the shared CHANNEL_OPTIONS index.
// Mirrors `lumit_core::fx::cpu::channel_of`.
fn channel_of(c: vec4<f32>) -> f32 {
    switch (p.plate_channel) {
        case 1u: { return c.a; }
        case 2u: { return c.r; }
        case 3u: { return c.g; }
        case 4u: { return c.b; }
        // 0 and anything unknown: Rec.709 luminance.
        default: { return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b; }
    }
}

// Value noise in 0..1, bilinear over four cell hashes. Cheap on purpose: the
// dirt field wants irregularity, not a good spectrum.
fn dirt_noise(x: f32, y: f32, channel: u32) -> f32 {
    let xi = floor(x);
    let yi = floor(y);
    let tx = x - xi;
    let ty = y - yi;
    let sx = tx * tx * (3.0 - 2.0 * tx);
    let sy = ty * ty * (3.0 - 2.0 * ty);
    let cx = i32(xi);
    let cy = i32(yi);
    let a = block_hash01(p.seed, channel, cx, cy, 0);
    let b = block_hash01(p.seed, channel, cx + 1, cy, 0);
    let c = block_hash01(p.seed, channel, cx, cy + 1, 0);
    let d = block_hash01(p.seed, channel, cx + 1, cy + 1, 0);
    let top = a + (b - a) * sx;
    let bot = c + (d - c) * sx;
    return top + (bot - top) * sy;
}

fn dirt_fbm(x: f32, y: f32, channel: u32) -> f32 {
    let a = dirt_noise(x, y, channel);
    let b = dirt_noise(x * 4.0 + 11.3, y * 4.0 - 7.1, channel ^ 0x9e37u);
    return clamp(a * 0.75 + b * 0.25, 0.0, 1.0);
}

// One speck's radial profile. **Defocus is what makes it a lens speck rather
// than a dot**: dirt on the front element sits far outside the focal plane, so
// it images as the aperture itself — a soft disc with a brighter rim.
fn speck_profile(norm_d: f32, defocus: f32) -> f32 {
    if (norm_d >= 1.0) {
        return 0.0;
    }
    let core = 1.0 - norm_d * norm_d;
    if (defocus <= 0.05) {
        return core;
    }
    let rim_pos = clamp(1.0 - defocus * 0.45, 0.1, 0.95);
    var ring: f32;
    if (norm_d >= rim_pos) {
        let t = (norm_d - rim_pos) / (1.0 - rim_pos);
        ring = 0.5 + t * t;
    } else {
        let t = norm_d / rim_pos;
        ring = 0.5 + 0.5 * t * t;
    }
    return core * ring;
}

// The dirt field at one pixel: the greasy veil, the specks and the scratches,
// summed. See the CPU reference for why each is shaped the way it is — in
// short: the veil does more work than the specks, the specks follow a power law
// within ONE plane of glass with noise-warped outlines, and the scratches fade
// along their own length.
fn dirt_field(cx_px: f32, cy_px: f32, diag: f32) -> vec3<f32> {
    var out = vec3<f32>(0.0);
    // **Everything below is measured from the frame's centre.** Gridded from the
    // top-left corner instead, Size scales the whole lattice about (0, 0) rather
    // than growing the specks, so the field slides off toward the corner as you
    // turn it up. The centre is the fixed point a lens actually has.
    let px = cx_px;
    let py = cy_px;

    if (p.smudge > 0.0) {
        let n = dirt_fbm(px / (diag * 0.35), py / (diag * 0.35), 40u);
        out += vec3<f32>((n * n) * p.smudge * 0.5);
    }

    if (p.specks > 0.0 && p.density > 0.0) {
        let base_r = p.scale * diag * 0.012;
        let cell = clamp(base_r * 4.0, 16.0, 2048.0);
        let occupancy = clamp(p.density / 100.0, 0.0, 20.0);
        let gx = i32(floor(px / cell));
        let gy = i32(floor(py / cell));

        for (var dy = -1; dy <= 1; dy++) {
            for (var dx = -1; dx <= 1; dx++) {
                let cx = gx + dx;
                let cy = gy + dy;
                // Up to three specks per cell, so they CLUSTER: one per cell is
                // a lattice however it is jittered.
                for (var k = 0u; k < 3u; k++) {
                    let ch = k * 16u;
                    let keep = occupancy * 0.30 / (1.0 + f32(k));
                    if (block_hash01(p.seed, ch, cx, cy, 0) > min(keep, 0.95)) {
                        continue;
                    }
                    let sx = (f32(cx) + block_hash01(p.seed, ch + 1u, cx, cy, 0)) * cell;
                    let sy = (f32(cy) + block_hash01(p.seed, ch + 2u, cx, cy, 0)) * cell;
                    // Power law, not uniform: muck is overwhelmingly small with
                    // the occasional big smear.
                    let u = block_hash01(p.seed, ch + 3u, cx, cy, 0);
                    let radius = max(base_r * (0.12 + 1.6 * u * u * u * u), 0.5);

                    let ox = px - sx;
                    let oy = py - sy;
                    let dist = sqrt(ox * ox + oy * oy);
                    if (dist > radius * 1.35) {
                        continue;
                    }
                    var warp = 1.0;
                    if (p.roughness > 0.0) {
                        let n = dirt_fbm(
                            sx * 0.05 + ox / max(radius, 0.5),
                            sy * 0.05 + oy / max(radius, 0.5),
                            ch + 4u,
                        );
                        warp = 1.0 + (n - 0.5) * p.roughness * 0.9;
                    }
                    let effective = max(radius * warp, 0.25);
                    let norm = dist / effective;
                    let base = speck_profile(norm, p.defocus);
                    if (base <= 0.0) {
                        continue;
                    }
                    var interior = 1.0;
                    if (p.roughness > 0.0) {
                        let n = dirt_fbm(px * 0.08, py * 0.08, ch + 5u);
                        interior = 1.0 - p.roughness * 0.5 * (1.0 - n);
                    }
                    let amount = base * interior * p.specks;

                    var rgb = vec3<f32>(amount);
                    if (p.colour_var > 0.0) {
                        rgb.r *= max(1.0 + (block_hash01(p.seed, ch + 6u, cx, cy, 0) - 0.5) * p.colour_var * 0.8, 0.0);
                        rgb.g *= max(1.0 + (block_hash01(p.seed, ch + 7u, cx, cy, 0) - 0.5) * p.colour_var * 0.8, 0.0);
                        rgb.b *= max(1.0 + (block_hash01(p.seed, ch + 8u, cx, cy, 0) - 0.5) * p.colour_var * 0.8, 0.0);
                    }
                    // The fringe lives at the EDGE. A per-channel radius scale
                    // draws clean concentric rings — a diffraction pattern, not
                    // what a smear of grease does.
                    if (p.chromatic > 0.0) {
                        let edge = clamp((norm - 0.75) / 0.25, 0.0, 1.0);
                        let f = edge * edge * p.chromatic * 0.6;
                        rgb.r *= 1.0 + f;
                        rgb.b *= 1.0 - f * 0.5;
                    }
                    out += rgb;
                }
            }
        }
    }

    if (p.scratches > 0.0) {
        let cell = clamp(48.0 * p.scratch_scale, 12.0, 1024.0);
        let gx = i32(floor(px / cell));
        let gy = i32(floor(py / cell));
        for (var dy = -1; dy <= 1; dy++) {
            for (var dx = -1; dx <= 1; dx++) {
                let cx = gx + dx;
                let cy = gy + dy;
                if (block_hash01(p.seed, 80u, cx, cy, 0) >= min(0.25 * p.scratches, 0.8)) {
                    continue;
                }
                let ax = (f32(cx) + block_hash01(p.seed, 81u, cx, cy, 0)) * cell;
                let ay = (f32(cy) + block_hash01(p.seed, 82u, cx, cy, 0)) * cell;
                let len_mult = 1.0 + (block_hash01(p.seed, 83u, cx, cy, 0) - 0.5) * p.scratch_var * 1.6;
                let seg = max(20.0 + 30.0 * len_mult, 2.0) * p.scratch_scale;
                let angle_var = (block_hash01(p.seed, 86u, cx, cy, 0) - 0.5) * p.scratch_var * 3.14159265359;
                let angle = block_hash01(p.seed, 84u, cx, cy, 0) * 6.28318530718 + angle_var;
                let vx = cos(angle) * seg;
                let vy = sin(angle) * seg;
                let t = clamp(((px - ax) * vx + (py - ay) * vy) / max(vx * vx + vy * vy, 1e-4), 0.0, 1.0);
                let d = length(vec2<f32>(px - (ax + t * vx), py - (ay + t * vy)));
                let width = (0.75 + 0.5 * block_hash01(p.seed, 85u, cx, cy, 0)) * p.scratch_scale;
                if (d < width) {
                    // A cloth does not press evenly, so a scratch fades along
                    // its own length.
                    let along = 1.0 - abs(2.0 * t - 1.0) * 0.6;
                    out += vec3<f32>((1.0 - d / width) * along * p.scratches * 0.7);
                }
            }
        }
    }

    return out;
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
    let px = f32(xy.x) + 0.5;
    let py = f32(xy.y) + 0.5;

    var eff: vec3<f32>;
    if (p.easter_egg != 0u || p.plate_bound != 0u) {
        // A bound plate — or the plate the easter egg substitutes — REPLACES the
        // procedural field. Sampled by normalised position so a plate of any
        // size fills the layer, whatever its own aspect.
        let plate_size = vec2<f32>(textureDimensions(plate));
        let uv = vec2<f32>(px / wf, py / hf);
        let coord = vec2<i32>(
            clamp(i32(uv.x * plate_size.x), 0, i32(plate_size.x) - 1),
            clamp(i32(uv.y * plate_size.y), 0, i32(plate_size.y) - 1),
        );
        let c = textureLoad(plate, coord, 0);
        // The easter egg is the picture, not a density map: it keeps its own
        // colour and every dirt-generation control is ignored (K-314).
        eff = select(vec3<f32>(channel_of(c)), c.rgb, p.easter_egg != 0u);
    } else {
        let diag = max(sqrt(wf * wf + hf * hf), 1.0);
        eff = dirt_field(px - wf * 0.5, py - hf * 0.5, diag);
    }

    // **The light response.** 1 is the physical reading — muck is visible only
    // where light passes through it. 0 leaves the field uniform, which is what a
    // generator on an empty layer needs. The easter egg answers to no light: it
    // is a photograph, not a density map.
    if (p.response > 0.0 && p.easter_egg == 0u) {
        let lit = max(textureLoad(light, xy, 0).r, 0.0);
        eff *= 1.0 - p.response + p.response * lit;
    }

    // Optical vignette on the DIRT, not the picture: less light reaches the edge
    // of the element, so less muck lights up there.
    if (p.vignette > 0.0 && p.easter_egg == 0u) {
        let nx = (px / wf - 0.5) * 2.0;
        let ny = (py / hf - 0.5) * 2.0;
        eff *= clamp(1.0 - p.vignette * 0.5 * (nx * nx + ny * ny), 0.0, 1.0);
    }

    eff = max(eff * p.intensity * p.tint.rgb, vec3<f32>(0.0));

    // What the dirt sits over. Normal puts it on opaque black, replacing the
    // picture — the dirt element on its own, and the only mode that produces
    // anything on an empty layer.
    let base = select(original, vec4<f32>(0.0, 0.0, 0.0, 1.0), p.blend_mode == 2u);

    // **The dirt carries its own coverage.** Adding light to RGB while leaving
    // alpha alone breaks the premultiplied invariant and, on a transparent
    // layer, produces colour nothing can ever see.
    let eff_a = clamp(max(eff.r, max(eff.g, eff.b)), 0.0, 1.0);
    var out: vec4<f32>;
    if (p.blend_mode >= 1u) {
        out = vec4<f32>(base.rgb + eff, min(base.a + eff_a, 1.0));
    } else {
        out = vec4<f32>(
            base.rgb + eff - base.rgb * eff,
            base.a + eff_a - base.a * eff_a,
        );
    }

    textureStore(dst, xy, mix(original, out, p.mix_amt));
}
