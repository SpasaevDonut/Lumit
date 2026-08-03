// Lens flare (docs/08-EFFECTS.md §3.27, docs/impl/lens-flare.md, K-256).
// See fx_lens_flare_trace.wgsl for the pass map; this file is split from it
// because each stage binds a different resource set.

// The render pass: vertex pulling + additive fragment.

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


struct DrawParams {
    disc_scale: f32, // ghost_disc_scale(fstop)
    _pad0: f32,
    _pad1: f32,
    _pad2: f32,
};

@group(0) @binding(0) var<storage, read> draw_verts: array<Vertex>;
@group(0) @binding(1) var disc_tex: texture_2d<f32>;
@group(0) @binding(2) var<uniform> dp: DrawParams;

struct VsOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) rgb: vec3<f32>,
    @location(2) rrel: f32,
};

@vertex
fn vs_flare(@builtin(vertex_index) vi: u32) -> VsOut {
    let v = draw_verts[vi];
    var out: VsOut;
    out.pos = vec4<f32>(v.ndc_x, v.ndc_y, 0.0, 1.0);
    out.uv = vec2<f32>(v.uv_x, v.uv_y);
    out.rgb = vec3<f32>(v.r, v.g, v.b);
    out.rrel = v.rrel;
    return out;
}

// Manual bilinear tap of the disc texture, 0 outside [0, 1]² — the CPU
// reference's `disc_sample` shape (no sampler, so both paths read the same
// maths).
fn disc_bilinear(u: f32, v: f32) -> f32 {
    if (u < 0.0 || u > 1.0 || v < 0.0 || v > 1.0) {
        return 0.0;
    }
    let dims = vec2<f32>(textureDimensions(disc_tex));
    let fx = u * (dims.x - 1.0);
    let fy = v * (dims.y - 1.0);
    let x0 = i32(floor(fx));
    let y0 = i32(floor(fy));
    let x1 = min(x0 + 1, i32(dims.x) - 1);
    let y1 = min(y0 + 1, i32(dims.y) - 1);
    let tx = fx - floor(fx);
    let ty = fy - floor(fy);
    let a = textureLoad(disc_tex, vec2<i32>(x0, y0), 0).x * (1.0 - tx)
        + textureLoad(disc_tex, vec2<i32>(x1, y0), 0).x * tx;
    let b = textureLoad(disc_tex, vec2<i32>(x0, y1), 0).x * (1.0 - tx)
        + textureLoad(disc_tex, vec2<i32>(x1, y1), 0).x * tx;
    return a * (1.0 - ty) + b * ty;
}

@fragment
fn fs_flare(in: VsOut) -> @location(0) vec4<f32> {
    let tu = (in.uv.x / dp.disc_scale + 1.0) / 2.0;
    let tv = (in.uv.y / dp.disc_scale + 1.0) / 2.0;
    let d = disc_bilinear(tu, tv);
    // Housing feather: full inside rrel 0.95, gone at 1.0 (the CPU
    // reference's exact clamp-and-smooth form).
    let t = clamp((1.0 - in.rrel) / 0.05, 0.0, 1.0);
    let clip = t * t * (3.0 - 2.0 * t);
    let c = in.rgb * d * clip;
    return vec4<f32>(c, 0.0);
}

