// Lens flare additive raster (docs/08 §3.27, K-261): vertex pulling from
// the built quad buffer, plain additive blend into the fp16 flare buffer.
// The colour is fully computed in build_verts (energy × Fresnel × mask ×
// wavelength × light), so the fragment is a passthrough — the ghost SHAPE
// is the warped grid itself, not a texture.

struct Vertex {
    ndc_x: f32,
    ndc_y: f32,
    r: f32,
    g: f32,
    b: f32,
    _pad0: f32,
    _pad1: f32,
    _pad2: f32,
};

@group(0) @binding(0) var<storage, read> verts: array<Vertex>;

struct VsOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) rgb: vec3<f32>,
};

@vertex
fn vs_flare(@builtin(vertex_index) vi: u32) -> VsOut {
    let v = verts[vi];
    var out: VsOut;
    out.pos = vec4<f32>(v.ndc_x, v.ndc_y, 0.0, 1.0);
    out.rgb = vec3<f32>(v.r, v.g, v.b);
    return out;
}

@fragment
fn fs_flare(in: VsOut) -> @location(0) vec4<f32> {
    let luma = 0.2126 * in.rgb.x + 0.7152 * in.rgb.y + 0.0722 * in.rgb.z;
    return vec4<f32>(in.rgb, luma);
}
