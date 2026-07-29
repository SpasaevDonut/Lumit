// CC Line Sweep (AE-style strip cascade): each stripe does a fragment-by-
// fragment horizontal sweep with configurable stagger (Line Delay). Mirrors
// cpu::cc_line_sweep_cascade (§1.6).

struct Params {
    completion: f32,
    dir_cos: f32,
    dir_sin: f32,
    line_cos: f32,
    line_sin: f32,
    line_count: i32,
    fragment_count: i32,
    line_delay: i32,
    flip: u32,
    mix_amt: f32,
};

@group(0) @binding(0) var src: texture_2d<f32>;
@group(0) @binding(1) var orig: texture_2d<f32>;
@group(0) @binding(2) var dst: texture_storage_2d<rgba16float, write>;
@group(0) @binding(3) var<uniform> p: Params;

@compute @workgroup_size(8, 8)
fn cc_line_sweep(@builtin(global_invocation_id) gid: vec3<u32>) {
    let size = vec2<i32>(textureDimensions(src));
    let xy = vec2<i32>(gid.xy);
    if (xy.x >= size.x || xy.y >= size.y) { return; }
    let o = textureLoad(src, xy, 0);
    if (p.completion <= 0.0) { textureStore(dst, xy, o); return; }
    if (p.completion >= 1.0 && p.mix_amt >= 1.0) {
        textureStore(dst, xy, vec4<f32>(0.0, 0.0, 0.0, 0.0)); return;
    }
    let w = f32(textureDimensions(src).x);
    let h = f32(textureDimensions(src).y);
    let u = (f32(xy.x) + 0.5) / w;
    let v = (f32(xy.y) + 0.5) / h;
    let p_stripe = clamp(u * p.dir_cos + v * p.dir_sin, 0.0, 1.0);
    let p_line = clamp(u * p.line_cos + v * p.line_sin, 0.0, 1.0);
    let nf = f32(max(p.line_count, 1));
    let frag_n = f32(max(p.fragment_count, 1));
    let delay = f32(max(p.line_delay, 0));
    let nf_minus_1 = nf - 1.0;
    let stripe_id_f = min(floor(p_stripe * nf), nf_minus_1);
    let frag_id_f = min(floor(p_line * frag_n), frag_n - 1.0);
    // Cascade: flip=true reverses stripe ordering (near edge first instead
    // of far edge first) rather than flipping alpha, so both endpoints
    // stay correct: 0% = fully visible, 100% = fully transparent.
    let start_first = select(nf_minus_1 - stripe_id_f, stripe_id_f, p.flip != 0u);
    let step = start_first * (frag_n + delay) + frag_id_f;
    let total_steps = nf_minus_1 * (frag_n + delay) + frag_n;
    let frag_limit = step / total_steps;
    let alpha = select(1.0, 0.0, p.completion >= frag_limit);
    let reveal = alpha;
    let weight = reveal * p.mix_amt + (1.0 - p.mix_amt);
    textureStore(dst, xy, o * weight);
}
