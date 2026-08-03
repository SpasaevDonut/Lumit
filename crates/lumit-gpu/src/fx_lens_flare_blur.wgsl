// Lens flare ghost blur (docs/08 §3.27, K-261): one direction of a
// separable box blur over the flare buffer — FlareSim's Ghost Blur, run
// horizontal + vertical × 3 passes to approximate a Gaussian. A touch of
// out-of-focus softness that also hides quad-grid facets at low qualities.

struct BlurParams {
    w: u32,
    h: u32,
    radius: u32,
    dir: u32, // 0 horizontal, 1 vertical
};

@group(0) @binding(0) var src: texture_2d<f32>;
@group(0) @binding(1) var dst: texture_storage_2d<rgba16float, write>;
@group(0) @binding(2) var<uniform> bp: BlurParams;

@compute @workgroup_size(8, 8)
fn blur(@builtin(global_invocation_id) gid: vec3<u32>) {
    if (gid.x >= bp.w || gid.y >= bp.h) {
        return;
    }
    let r = i32(bp.radius);
    var acc = vec4<f32>(0.0);
    for (var d = -r; d <= r; d = d + 1) {
        var x = i32(gid.x);
        var y = i32(gid.y);
        if (bp.dir == 0u) {
            x = clamp(x + d, 0, i32(bp.w) - 1);
        } else {
            y = clamp(y + d, 0, i32(bp.h) - 1);
        }
        acc = acc + textureLoad(src, vec2<i32>(x, y), 0);
    }
    let norm = 1.0 / f32(2 * r + 1);
    textureStore(dst, vec2<i32>(i32(gid.x), i32(gid.y)), acc * norm);
}
