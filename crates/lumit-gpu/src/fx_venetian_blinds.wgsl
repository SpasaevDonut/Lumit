// CC Line Sweep (AE-style staggered-line wipe): reveals the layer stripe by
// stripe along a sweep angle. Each stripe gets a deterministic hash-based
// timing offset (splitmix32), producing a hard-edge line-by-line reveal.
// The step function is binary — no smoothstep. Mirrors the CPU reference
// op-for-op (§1.6: the CPU is the oracle). Standard 2-input layout.

struct Params {
    completion: f32,
    dir_cos: f32,
    dir_sin: f32,
    line_count: i32,
    stagger: f32,
    flip: u32,
    mix_amt: f32,
    _pad0: f32,
};

@group(0) @binding(0) var src: texture_2d<f32>;
@group(0) @binding(1) var orig: texture_2d<f32>;
@group(0) @binding(2) var dst: texture_storage_2d<rgba16float, write>;
@group(0) @binding(3) var<uniform> p: Params;

// Deterministic 32-bit mixer (== cpu::stripe_splitmix32, identical wrapping
// u32 ops in the same order — exact on every GPU, so CPU and GPU agree on
// the integer hash bit-for-bit).
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

@compute @workgroup_size(8, 8)
fn venetian_blinds(@builtin(global_invocation_id) gid: vec3<u32>) {
    let size = vec2<i32>(textureDimensions(src));
    let xy = vec2<i32>(gid.xy);
    if (xy.x >= size.x || xy.y >= size.y) {
        return;
    }
    let o = textureLoad(src, xy, 0);
    if (p.completion <= 0.0) {
        textureStore(dst, xy, o);
        return;
    }
    if (p.completion >= 1.0 && p.mix_amt >= 1.0) {
        textureStore(dst, xy, vec4<f32>(0.0, 0.0, 0.0, 0.0));
        return;
    }
    // Normalised UV at pixel centre.
    let w = f32(textureDimensions(src).x);
    let h = f32(textureDimensions(src).y);
    let u = (f32(xy.x) + 0.5) / w;
    let v = (f32(xy.y) + 0.5) / h;
    // Project along sweep direction.
    let p_proj = clamp(u * p.dir_cos + v * p.dir_sin, 0.0, 1.0);
    // Discrete stripe indexing.
    let nf = f32(p.line_count);
    let s = p_proj * nf;
    let stripe_id = i32(floor(s));
    let phase = s - f32(stripe_id);
    // Per-stripe offset via splitmix32.
    let hash = splitmix32(u32(stripe_id));
    let offset = f32(hash) / 4294967295.0 * p.stagger;  // u32::MAX
    // Hard-edge cutoff.
    var alpha: f32;
    let cutoff = p.completion * (1.0 + p.stagger) - offset;
    if (phase >= cutoff) {
        alpha = 1.0;
    } else {
        alpha = 0.0;
    }
    let reveal = select(alpha, 1.0 - alpha, p.flip != 0u);
    let weight = reveal * p.mix_amt + (1.0 - p.mix_amt);
    textureStore(dst, xy, o * weight);
}
