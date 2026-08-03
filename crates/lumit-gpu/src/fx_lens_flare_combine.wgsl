// Lens flare (docs/08-EFFECTS.md §3.27, docs/impl/lens-flare.md, K-256).
// See fx_lens_flare_trace.wgsl for the pass map; this file is split from it
// because each stage binds a different resource set.

// The combine stage.

struct Light {
    pos_x: f32,
    pos_y: f32,
    r: f32,
    g: f32,
    b: f32,
    _pad0: f32,
    _pad1: f32,
    _pad2: f32,
};

struct CombineParams {
    w: f32,
    h: f32,
    fw: f32,
    fh: f32,
    intensity: f32,
    sb_intensity: f32,
    sb_half: f32,
    squeeze: f32,
    fscale: f32,
    mix_amt: f32,
    light_count: u32,
    _pad0: f32,
};

@group(0) @binding(0) var src_tex: texture_2d<f32>;
@group(0) @binding(1) var flare_tex: texture_2d<f32>;
@group(0) @binding(2) var sb_tex: texture_2d<f32>;
@group(0) @binding(3) var dst_tex: texture_storage_2d<rgba16float, write>;
@group(0) @binding(4) var<uniform> cp: CombineParams;
@group(0) @binding(5) var<storage, read> lights: array<Light>;

// Clamp-addressed bilinear tap of an rgba texture's rgb.
fn tap_rgb(tex: texture_2d<f32>, fx_in: f32, fy_in: f32, dims: vec2<i32>) -> vec3<f32> {
    let fx = fx_in;
    let fy = fy_in;
    let x0 = clamp(i32(floor(fx)), 0, dims.x - 1);
    let y0 = clamp(i32(floor(fy)), 0, dims.y - 1);
    let x1 = min(x0 + 1, dims.x - 1);
    let y1 = min(y0 + 1, dims.y - 1);
    let tx = clamp(fx - floor(fx), 0.0, 1.0);
    let ty = clamp(fy - floor(fy), 0.0, 1.0);
    let a = textureLoad(tex, vec2<i32>(x0, y0), 0).rgb * (1.0 - tx)
        + textureLoad(tex, vec2<i32>(x1, y0), 0).rgb * tx;
    let b = textureLoad(tex, vec2<i32>(x0, y1), 0).rgb * (1.0 - tx)
        + textureLoad(tex, vec2<i32>(x1, y1), 0).rgb * tx;
    return a * (1.0 - ty) + b * ty;
}

@compute @workgroup_size(8, 8)
fn combine(@builtin(global_invocation_id) gid: vec3<u32>) {
    let size = vec2<i32>(textureDimensions(src_tex));
    let xy = vec2<i32>(gid.xy);
    if (xy.x >= size.x || xy.y >= size.y) {
        return;
    }
    let o = textureLoad(src_tex, xy, 0);
    if (cp.intensity <= 0.0 || cp.mix_amt <= 0.0) {
        textureStore(dst_tex, xy, o);
        return;
    }
    // Whole-flare Scale plus the anamorphic squeeze (x only), both about
    // the frame centre (== lens_flare::cpu_combine).
    let cx = cp.w / 2.0;
    let cyc = cp.h / 2.0;
    let sx = cx + (f32(xy.x) + 0.5 - cx) / (cp.squeeze * cp.fscale);
    let sy = cyc + (f32(xy.y) + 0.5 - cyc) / cp.fscale;
    // Flare buffer tap (resolution-relative: Draft renders it half-size).
    let fdims = vec2<i32>(textureDimensions(flare_tex));
    let f = tap_rgb(
        flare_tex,
        sx / cp.w * cp.fw - 0.5,
        sy / cp.h * cp.fh - 0.5,
        fdims,
    );
    // One starburst sprite per live light: anchored on its light, sized by
    // Scale, stretched by the squeeze, tinted by the light.
    var sb = vec3<f32>(0.0);
    if (cp.sb_intensity > 0.0 && cp.sb_half > 0.0) {
        let sdims = vec2<i32>(textureDimensions(sb_tex));
        for (var li = 0u; li < cp.light_count; li = li + 1u) {
            let light = lights[li];
            if (light.r <= 0.0 && light.g <= 0.0 && light.b <= 0.0) {
                continue;
            }
            let rel_x = f32(xy.x) + 0.5 - light.pos_x * cp.w;
            let rel_y = f32(xy.y) + 0.5 - light.pos_y * cp.h;
            let u = rel_x / (cp.sb_half * cp.squeeze) * 0.5 + 0.5;
            let v = rel_y / cp.sb_half * 0.5 + 0.5;
            if (u < 0.0 || u > 1.0 || v < 0.0 || v > 1.0) {
                continue;
            }
            sb = sb
                + tap_rgb(sb_tex, u * f32(sdims.x - 1), v * f32(sdims.y - 1), sdims)
                    * cp.sb_intensity
                    * vec3<f32>(light.r, light.g, light.b);
        }
    }
    let add = (f + sb) * cp.intensity;
    let luma = 0.2126 * add.r + 0.7152 * add.g + 0.0722 * add.b;
    let flared = vec4<f32>(o.rgb + add, min(o.a + luma, 1.0));
    let outv = o * (1.0 - cp.mix_amt) + flared * cp.mix_amt;
    textureStore(dst_tex, xy, outv);
}
