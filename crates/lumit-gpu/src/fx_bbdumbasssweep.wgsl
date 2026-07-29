// BB Dumbass Sweep (AE-style sequential wave wipe, copy of CC Line Sweep):
// stripes disappear one by one as a sweep front moves across the screen.
// Fragment Count sub-divides each stripe into rectangular cells that cascade.
// Mirrors cpu::cc_line_sweep_seq (§1.6).

struct Params {
    completion: f32,
    dir_cos: f32,
    dir_sin: f32,
    line_cos: f32,
    line_sin: f32,
    line_count: i32,
    fragment_count: i32,
    flip: u32,
    mix_amt: f32,
};

@group(0) @binding(0) var src: texture_2d<f32>;
@group(0) @binding(1) var orig: texture_2d<f32>;
@group(0) @binding(2) var dst: texture_storage_2d<rgba16float, write>;
@group(0) @binding(3) var<uniform> p: Params;

@compute @workgroup_size(8, 8)
fn bb_dumbass_sweep(@builtin(global_invocation_id) gid: vec3<u32>) {
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
    let nf = f32(p.line_count);
    let stripe_id = i32(floor(p_stripe * nf));
    let line_phase = (p_line * nf) - floor(p_line * nf);
    let stripe_start = f32(stripe_id) / nf;
    let stripe_dur = 1.0 / nf;

    var alpha: f32;
    if (p.completion <= stripe_start) {
        alpha = 1.0;
    } else {
        let frag_n = f32(max(p.fragment_count, 1));
        var frag_id = u32(floor(line_phase * frag_n));
        frag_id = min(frag_id, u32(frag_n - 1.0));
        let frag_duration = stripe_dur / frag_n;
        let frag_end = stripe_start + f32(frag_id + 1u) * frag_duration;
        if (p.completion >= frag_end) { alpha = 0.0; } else { alpha = 1.0; }
    }
    let reveal = select(alpha, 1.0 - alpha, p.flip != 0u);
    let weight = reveal * p.mix_amt + (1.0 - p.mix_amt);
    textureStore(dst, xy, o * weight);
}
