// CC Image Wipe (AE-style gradient-driven transition): reads a gradient layer,
// extracts the chosen property (Luminance, R/G/B or Alpha) per pixel, and
// applies a smoothstep wipe driven by Completion and Border Softness. The wipe
// alpha is multiplied into the source RGB, fading toward transparent where
// gradient < completion. An optional pre-blur on the gradient is handled
// host-side before this kernel runs; the gradient texture passed here is
// already the (possibly blurred) gradient resampled to the working raster.
//
// Mirrors lumit_core::fx::cpu::cc_image_wipe_reference op-for-op (§1.6: the
// CPU is the oracle). Uses the 3-input layout (mb_layout): binding 0 = src,
// binding 1 = orig-for-mix, binding 2 = gradient texture.

struct Params {
    completion: f32,
    softness: f32,     // 0..1, Border Softness
    auto_soft: u32,    // 0/1
    property: u32,     // 0 Luma, 1 Red, 2 Green, 3 Blue, 4 Alpha
    inverse: u32,      // 0/1
    mix_amt: f32,
    _pad0: f32,
    _pad1: f32,
};

@group(0) @binding(0) var src: texture_2d<f32>;
@group(0) @binding(1) var orig: texture_2d<f32>;
@group(0) @binding(2) var grad: texture_2d<f32>;
@group(0) @binding(3) var dst: texture_storage_2d<rgba16float, write>;
@group(0) @binding(4) var<uniform> p: Params;

fn read_gradient(xy: vec2<i32>) -> f32 {
    let c = textureLoad(grad, xy, 0);
    if (p.property == 1u) { return c.r; }
    if (p.property == 2u) { return c.g; }
    if (p.property == 3u) { return c.b; }
    if (p.property == 4u) { return c.a; }
    // Luminance (default)
    return c.r * 0.299 + c.g * 0.587 + c.b * 0.114;
}

fn smoothstep_at(completion: f32, softness: f32, auto_soft: u32, gv: f32) -> f32 {
    let eff_soft = select(softness, completion * (1.0 - completion) * 2.0, auto_soft != 0u);
    let lo = clamp(completion - eff_soft * 0.5, 0.0, 1.0);
    let hi = clamp(completion + eff_soft * 0.5, 0.0, 1.0);
    var raw: f32;
    if (hi - lo <= 0.0) {
        raw = select(1.0, 0.0, gv <= completion);
    } else {
        raw = (gv - lo) / (hi - lo);
    }
    let t = clamp(raw, 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t); // smoothstep
}

@compute @workgroup_size(8, 8)
fn cc_image_wipe(@builtin(global_invocation_id) gid: vec3<u32>) {
    let size = vec2<i32>(textureDimensions(src));
    let xy = vec2<i32>(gid.xy);
    if (xy.x >= size.x || xy.y >= size.y) {
        return;
    }
    let o = textureLoad(src, xy, 0);
    // At completion 0 the wipe has not started — identity passthrough.
    // At completion 1 with full mix the wipe is complete — fully transparent.
    if (p.completion <= 0.0) {
        textureStore(dst, xy, o);
        return;
    }
    if (p.completion >= 1.0 && p.mix_amt >= 1.0) {
        textureStore(dst, xy, vec4<f32>(0.0, 0.0, 0.0, 0.0));
        return;
    }
    let raw_gv = read_gradient(xy);
    // Inverse: flip the gradient value so the bright/dark sides swap roles,
    // rather than flipping alpha after smoothstep (which would swap the
    // completion direction too).
    let gv = select(raw_gv, 1.0 - raw_gv, p.inverse != 0u);
    let alpha = smoothstep_at(p.completion, p.softness, p.auto_soft, gv);
    let weight = alpha * p.mix_amt + (1.0 - p.mix_amt);
    // Scale both RGB and alpha so the pixel becomes transparent in premultiplied
    // space (not black with unchanged alpha, which would composite as opaque
    // black).
    textureStore(dst, xy, o * weight);
}
