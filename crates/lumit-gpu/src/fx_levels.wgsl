// Levels (AE-style transfer function, with channel select): remaps
// [in_black, in_white] to [0, 1], clamps to [0, 1], applies gamma
// (pow(p, 1/gamma)), then remaps to [out_black, out_white] with optional
// clip-to-output checkboxes. The Channel picker (0 Rgb, 1 Red, 2 Green,
// 3 Blue, 4 Alpha) restricts the transform to one channel. RGB and
// single-colour modes (§2.2, the wrap fused into the kernel): unpremultiply
// → level → re-premultiply. Alpha mode modifies alpha directly. Mirrors
// lumit_core::fx::cpu::levels op-for-op (§1.6: the CPU is the oracle).

struct Params {
    in_black: f32,
    in_white: f32,
    gamma: f32,
    out_black: f32,
    out_white: f32,
    clip_flags: u32,  // bit 0 = clip_black, bit 1 = clip_white
    mix_amt: f32,
    channel: u32,     // 0 Rgb, 1 Red, 2 Green, 3 Blue, 4 Alpha
};

@group(0) @binding(0) var src: texture_2d<f32>;
@group(0) @binding(1) var orig: texture_2d<f32>;
@group(0) @binding(2) var dst: texture_storage_2d<rgba16float, write>;
@group(0) @binding(3) var<uniform> p: Params;

fn unpremult(c: vec4<f32>) -> vec3<f32> {
    if (c.a > 0.0) {
        return c.rgb / c.a;
    }
    return vec3<f32>(0.0);
}

// One value through the levels curve: remap → clamp → gamma → remap → clip.
fn level(v: f32) -> f32 {
    let in_range = p.in_white - p.in_black;
    let out_range = p.out_white - p.out_black;
    var r: f32 = v;
    if (in_range != 0.0) {
        r = (r - p.in_black) / in_range;
    } else {
        r = 0.0;
    }
    r = clamp(r, 0.0, 1.0);
    if (p.gamma != 1.0) {
        let inv = 1.0 / p.gamma;
        r = pow(max(r, 0.0), inv);
    }
    r = r * out_range + p.out_black;
    if ((p.clip_flags & 1u) != 0u) {
        r = max(r, p.out_black);
    }
    if ((p.clip_flags & 2u) != 0u) {
        r = min(r, p.out_white);
    }
    return r;
}

@compute @workgroup_size(8, 8)
fn levels_fx(@builtin(global_invocation_id) gid: vec3<u32>) {
    let size = vec2<i32>(textureDimensions(src));
    let xy = vec2<i32>(gid.xy);
    if (xy.x >= size.x || xy.y >= size.y) {
        return;
    }
    let o = textureLoad(src, xy, 0);
    // Neutral short-circuit: at defaults the transform is the identity.
    if (p.in_black == 0.0
        && p.in_white == 1.0
        && p.gamma == 1.0
        && p.out_black == 0.0
        && p.out_white == 1.0
        && p.clip_flags == 0u)
    {
        textureStore(dst, xy, o);
        return;
    }
    if (p.channel == 1u) {
        // Red only
        let u = unpremult(o);
        let v = level(u.r);
        let graded = v * o.a;
        let outv = o.r * (1.0 - p.mix_amt) + graded * p.mix_amt;
        textureStore(dst, xy, vec4<f32>(outv, o.g, o.b, o.a));
    } else if (p.channel == 2u) {
        // Green only
        let u = unpremult(o);
        let v = level(u.g);
        let graded = v * o.a;
        let outv = o.g * (1.0 - p.mix_amt) + graded * p.mix_amt;
        textureStore(dst, xy, vec4<f32>(o.r, outv, o.b, o.a));
    } else if (p.channel == 3u) {
        // Blue only
        let u = unpremult(o);
        let v = level(u.b);
        let graded = v * o.a;
        let outv = o.b * (1.0 - p.mix_amt) + graded * p.mix_amt;
        textureStore(dst, xy, vec4<f32>(o.r, o.g, outv, o.a));
    } else if (p.channel == 4u) {
        // Alpha only (no unpremultiply needed)
        let v = level(o.a);
        textureStore(dst, xy, vec4<f32>(o.rgb, o.a * (1.0 - p.mix_amt) + v * p.mix_amt));
    } else {
        // Rgb (default) — all three channels
        let u = unpremult(o);
        let r = level(u.r) * o.a;
        let g = level(u.g) * o.a;
        let b = level(u.b) * o.a;
        let outv = o.rgb * (1.0 - p.mix_amt) + vec3<f32>(r, g, b) * p.mix_amt;
        textureStore(dst, xy, vec4<f32>(outv, o.a));
    }
}
