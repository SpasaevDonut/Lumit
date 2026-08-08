// Bokeh (docs/08-EFFECTS.md §3.27): the advanced lens blur — Lens blur's
// aperture and tonal gather with every dial out on the surface, plus a depth
// model you focus by clicking rather than by hunting for a number.
//
// It shares `fx_dof.wgsl`'s shape and every one of its disciplines: the same
// scatter-as-gather over an integer scan box, the same host-computed blade
// normals (WGSL's transcendentals carry no guarantee of matching Rust's, which
// is exactly what the §1.6 oracle measures), the same longhand smoothstep, the
// same split-at-threshold power mean, the same denormal floor. Read that file
// first; this comment covers only what is new here.
//
// **Roundness reaches below zero.** Lens blur's curvature bows the blades
// outward toward the circle over 0..1. Here the same test runs with a negative
// coefficient too, and that is a star: at a vertex the tap has m = k·r, so the
// two terms cancel to r ≤ coc whatever the coefficient — the vertices stay
// exactly on the circle — while at an edge midpoint m = r, so a negative
// coefficient pulls the midpoint in. No new maths, no branch, and the region
// stays INSCRIBED in the circle at every setting, which is what keeps
// `ceil(radius)` a correct bound on the taps.
//
// **Deform squeezes one axis only.** The multipliers are always ≥ 1 and exactly
// one is > 1, so multiplying the tap offset before the inside test can only
// shrink the aperture on that axis — it can never reach outside the circle, so
// the scan box is untouched. The reciprocal is taken host-side (K-137's
// precedent), so there is no per-tap division.
//
// **Concentration and Remove edge leak weight the taps — and are branched
// around at their neutrals.** A weighted gather computes Σ(c·w)/Σw, which is not
// an identity in IEEE 754 even when every w is 1. So `weighted` is decided once
// per dispatch and the unweighted path is Lens blur's accumulation unchanged —
// which is what makes each added control contribute *nothing* at its neutral
// rather than an ULP of drift. It does not make a neutral Bokeh equal to Lens
// blur: Resolution always quantises the ramp, and this effect has no separate
// focus range and one radius rather than a near/far pair.
//
// The depth is read through `channel_of` rather than as plain red, because which
// channel carries depth is this effect's own control. Every branch of it is
// arithmetic — no atan2 for hue, no pow — and every divide is guarded: a grey
// pixel has no hue, and zero chroma must not become a NaN in the middle of a
// depth read.

const MAX_BLADES: u32 = 8u;

// Matches `lumit_core::fx::cpu::TONAL_FLOOR` and `fx_dof.wgsl`'s. See either for
// why an averaged excess this small must be treated as nothing on both paths.
const TONAL_FLOOR: f32 = 1e-30;

struct Params {
    blur_radius: f32,       // max circle-of-confusion radius, raster px
    apothem2: f32,          // cos²(π/N)
    roundness: f32,         // -1 star … 0 polygon … 1 circle
    concentration: f32,     // -1 centre-weighted … 0 flat … 1 rim-weighted
    deform_x: f32,          // tap-offset multipliers, both >= 1, one == 1
    deform_y: f32,
    threshold: f32,         // linear level each tap is split at
    bokeh_power: f32,       // 2^(Exposure/6); 1 = the plain arithmetic mean
    focal_distance: f32,    // in-focus depth, when use_focus_point is 0
    focus_x: f32,           // where to read focus depth, raster px
    focus_y: f32,
    focus_falloff: f32,     // multiplier on the depth distance before the ramp
    depth_bands: f32,       // Resolution: how many bands the ramp quantises to
    remove_edge_leak: f32,  // 0..1
    detect_edge_threshold: f32,
    mix_amt: f32,           // 0..1, blended against the unprocessed input
    blade_count: u32,       // 3..=MAX_BLADES; Roundness 1 is the circle
    depth_bound: u32,       // 0 = no depth layer: defocus uniformly
    depth_channel: u32,     // index into lumit_core::fx::CHANNEL_OPTIONS
    depth_invert: u32,      // 1 = d' = 1 - d before the CoC
    use_focus_point: u32,   // 1 = focus is the depth under (focus_x, focus_y)
    repeat_edge: u32,       // 1 = clamp the gather to the frame edge
    composite_mode: u32,    // 0 Normal, 1 Add, 2 Screen, 3 Lighten, 4 Darken
    display: u32,           // 0 Rendered, 1 Depth map, 2 Focus map
    weighted: u32,          // 1 = the tap-weighted path (host decides once)
    // Padding to a 16-byte boundary, matching DofParams/BokehParams on the host
    // side. Load-bearing: the array below is 16-byte aligned here but only
    // 4-byte aligned under repr(C), so without this every normal is read from
    // the wrong offset.
    _pad0: u32,
    _pad1: u32,
    _pad2: u32,
    // One normal per vec4 (only .xy read); a uniform array's element stride is
    // 16 bytes whatever the element type, so packing would save nothing.
    blade_normals: array<vec4<f32>, 8>,
};

@group(0) @binding(0) var src: texture_2d<f32>;
@group(0) @binding(1) var orig: texture_2d<f32>;
@group(0) @binding(2) var depth: texture_2d<f32>;
@group(0) @binding(3) var dst: texture_storage_2d<rgba16float, write>;
@group(0) @binding(4) var<uniform> p: Params;

// One channel of the depth picture, by the shared CHANNEL_OPTIONS index.
// Mirrors `lumit_core::fx::cpu::channel_of` operation for operation.
fn channel_of(c: vec4<f32>) -> f32 {
    let mx = max(c.r, max(c.g, c.b));
    let mn = min(c.r, min(c.g, c.b));
    let chroma = mx - mn;
    switch (p.depth_channel) {
        case 0u: { return c.r; }
        case 1u: { return c.g; }
        case 2u: { return c.b; }
        case 3u: { return c.a; }
        case 4u: { return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b; }
        case 6u: {
            // Hue, 0..1. A grey pixel has no hue; zero is the conventional
            // answer and the only one that cannot divide by nothing.
            if (chroma <= 0.0) {
                return 0.0;
            }
            let sixth = 1.0 / 6.0;
            var hue: f32;
            if (mx == c.r) {
                hue = sixth * (((c.g - c.b) / chroma) % 6.0);
            } else if (mx == c.g) {
                hue = sixth * (((c.b - c.r) / chroma) + 2.0);
            } else {
                hue = sixth * (((c.r - c.g) / chroma) + 4.0);
            }
            return select(hue, hue + 1.0, hue < 0.0);
        }
        case 7u: {
            // Saturation (HSL): zero on grey and at either extreme of
            // lightness, where the denominator collapses.
            if (chroma <= 0.0) {
                return 0.0;
            }
            let l = 0.5 * (mx + mn);
            let denom = 1.0 - abs(2.0 * l - 1.0);
            return select(chroma / denom, 0.0, denom <= 0.0);
        }
        case 8u: { return 0.5 * (mx + mn); }
        default: { return (c.r + c.g + c.b) / 3.0; }
    }
}

fn depth_at(xy: vec2<i32>) -> f32 {
    let d = channel_of(textureLoad(depth, xy, 0));
    return select(d, 1.0 - d, p.depth_invert != 0u);
}

// The defocus ramp: distance from focus, SCALED BY THE PROFILE CONTROL, smoothed
// longhand, then quantised into Resolution bands.
//
// The scale is what stops focus being all-or-nothing. Without it the ramp
// reaches full blur only at a depth distance of the whole range, and a real
// depth pass puts nearly all its content in a narrow band with one near object
// well outside it — so focusing anywhere leaves the scene almost sharp and that
// object almost fully blurred, with nothing in between. The host computes the
// multiplier (one `exp2`, off the per-pixel path), and 1 is its neutral.
// `depth_bands` is deliberately unread — see `lumit_core::fx::cpu::bokeh_ramp`.
// Resolution was read as a band count quantising this ramp, and that guess made
// focus all-or-nothing on a real depth pass: the whole scene band landed in
// level zero and the one near object in level five, with the quantisation
// snapping any ramp shape back to those two ends. Continuous again until the
// control's real behaviour is known.
fn ramp(d: f32, focus: f32) -> f32 {
    let e = min(max(abs(d - focus) * p.focus_falloff, 0.0), 1.0);
    return e * e * (3.0 - 2.0 * e);
}

// The tap's deformed r² when it is inside the aperture, else -1. See the header
// for why Roundness may be negative and why Deform can only shrink the region.
fn aperture_r2(dx: f32, dy: f32, coc2: f32) -> f32 {
    let ax = dx * p.deform_x;
    let ay = dy * p.deform_y;
    let r2 = ax * ax + ay * ay;
    var m = 0.0;
    for (var k = 0u; k < MAX_BLADES; k++) {
        if (k >= p.blade_count) {
            break;
        }
        let n = p.blade_normals[k];
        m = max(m, ax * n.x + ay * n.y);
    }
    let c = p.roundness;
    let inside = (1.0 - c) * m * m + c * p.apothem2 * r2 <= p.apothem2 * coc2;
    return select(-1.0, r2, inside);
}

// One tap's radial weight (Concentration). Multiplicative in coc2 so there is no
// division and no guard at coc = 0; the weights are only used as a ratio, so the
// common factor cancels in the mean.
fn tap_weight(r2: f32, coc2: f32) -> f32 {
    return max(coc2 + p.concentration * (2.0 * r2 - coc2), 0.0);
}

@compute @workgroup_size(8, 8)
fn bokeh(@builtin(global_invocation_id) gid: vec3<u32>) {
    let size = vec2<i32>(textureDimensions(src));
    let xy = vec2<i32>(gid.xy);
    if (xy.x >= size.x || xy.y >= size.y) {
        return;
    }

    // Focus is either the number or whatever depth sits under the point — the
    // reason Focal distance greys out in the panel. Clamped rather than wrapped:
    // a point dragged off the frame focuses on the nearest edge.
    var focus = p.focal_distance;
    if (p.depth_bound != 0u && p.use_focus_point != 0u) {
        let fx = clamp(i32(floor(p.focus_x)), 0, size.x - 1);
        let fy = clamp(i32(floor(p.focus_y)), 0, size.y - 1);
        focus = depth_at(vec2<i32>(fx, fy));
    }

    let d_centre = select(0.0, depth_at(xy), p.depth_bound != 0u);

    // The diagnostic views: written straight out, ignoring the gather, the
    // composite and Mix alike. The host forces Rendered when no depth is bound,
    // so these never draw the stand-in texture that occupies the depth slot.
    if (p.display == 1u) {
        // Depth map: what the effect is actually reading, after the channel pick
        // and the invert.
        textureStore(dst, xy, vec4<f32>(d_centre, d_centre, d_centre, 1.0));
        return;
    }
    if (p.display == 2u) {
        // Focus map: white where sharp, darkening out of focus.
        let m = 1.0 - ramp(d_centre, focus);
        textureStore(dst, xy, vec4<f32>(m, m, m, 1.0));
        return;
    }

    let coc = select(p.blur_radius * ramp(d_centre, focus), p.blur_radius, p.depth_bound == 0u);
    let o = textureLoad(orig, xy, 0);

    // In focus: the aperture is a point, so the pixel keeps itself — no gather,
    // no composite, no Mix. The only way a sharp pixel stays bit-exact (a single
    // weighted tap computes (c·w)/w, which is not an IEEE identity).
    if (coc <= 0.0) {
        textureStore(dst, xy, o);
        return;
    }

    let coc2 = coc * coc;
    let ri = i32(ceil(coc));
    let t = vec4<f32>(p.threshold);
    let weighted = p.weighted != 0u;

    // **Pass one: the brightest excess in the aperture, per channel.**
    //
    // The power mean cannot be computed as (Σ c^p / n)^(1/p) in f32. At this
    // effect's own default — Exposure 30, so p = 32 — a channel at scene-linear
    // 0.08 raises to 8e-36 and one at 0.05 to 2e-42, below the smallest normal.
    // Averaging those and rooting them back yields zero, so every channel below
    // roughly 0.116 linear collapses to black, per channel independently — black
    // holes and saturated speckle rather than a blur. A floor on the *mean*
    // cannot save it; the underflow has already happened in the taps.
    //
    // Factoring the largest excess M out first is the standard fix and an exact
    // identity:
    //
    //     (Σ w·c^p / Σw)^(1/p)  =  M · (Σ w·(c/M)^p / Σw)^(1/p)
    //
    // Every c/M is then in [0, 1], the brightest tap contributes exactly 1, and
    // the mean is bounded below by that tap's share of the weight — nothing
    // underflows and no floor is needed. It costs a second walk of the aperture,
    // which is why this is two loops. `fx_dof.wgsl` keeps its floor because its
    // Exposure defaults to 0 (power 1), where nothing is raised at all.
    var peak = vec4<f32>(0.0);
    for (var dy = -ri; dy <= ri; dy++) {
        for (var dx = -ri; dx <= ri; dx++) {
            if (aperture_r2(f32(dx), f32(dy), coc2) < 0.0) {
                continue;
            }
            let ox = xy.x + dx;
            let oy = xy.y + dy;
            var sx = ox;
            var sy = oy;
            if (p.repeat_edge != 0u) {
                sx = clamp(ox, 0, size.x - 1);
                sy = clamp(oy, 0, size.y - 1);
            } else if (ox < 0 || oy < 0 || ox >= size.x || oy >= size.y) {
                continue;
            }
            let c = textureLoad(src, vec2<i32>(sx, sy), 0);
            peak = max(peak, max(c - t, vec4<f32>(0.0)));
        }
    }

    // Pass two: the gather proper.
    var acc_lo = vec4<f32>(0.0);
    var acc_hi = vec4<f32>(0.0);
    var n = 0.0;

    for (var dy = -ri; dy <= ri; dy++) {
        for (var dx = -ri; dx <= ri; dx++) {
            let r2 = aperture_r2(f32(dx), f32(dy), coc2);
            if (r2 < 0.0) {
                continue;
            }
            var w = select(1.0, tap_weight(r2, coc2), weighted);

            let ox = xy.x + dx;
            let oy = xy.y + dy;
            var sx = ox;
            var sy = oy;
            if (p.repeat_edge != 0u) {
                sx = clamp(ox, 0, size.x - 1);
                sy = clamp(oy, 0, size.y - 1);
            } else if (ox < 0 || oy < 0 || ox >= size.x || oy >= size.y) {
                // Transparent contributes nothing AND keeps its weight, so a
                // gather running off the frame darkens toward the edge rather
                // than brightening — the reading the blur family already gives.
                n += w;
                continue;
            }

            // Edge leak: a tap across a depth discontinuity and in FRONT of this
            // pixel is sharp foreground colour bleeding into a defocused
            // background. Pull it back rather than drop it, so the suppression
            // is continuous in the slider.
            if (weighted && p.remove_edge_leak > 0.0 && p.depth_bound != 0u) {
                let dt = depth_at(vec2<i32>(sx, sy));
                if (abs(dt - d_centre) > p.detect_edge_threshold && dt < d_centre) {
                    w *= 1.0 - p.remove_edge_leak;
                }
            }

            let c = textureLoad(src, vec2<i32>(sx, sy), 0);
            acc_lo += min(c, t) * w;
            // Normalised by the brightest excess, so the ratio is in [0, 1] and
            // its power cannot underflow (see pass one). A zero peak means
            // nothing in the aperture is above the threshold; the excess term is
            // then zero and the plain average is the whole answer.
            let excess = max(c - t, vec4<f32>(0.0));
            let ratio = select(
                vec4<f32>(0.0),
                excess / max(peak, vec4<f32>(1e-30)),
                peak > vec4<f32>(0.0),
            );
            acc_hi += pow(ratio, vec4<f32>(p.bokeh_power)) * w;
            n += w;
        }
    }
    if (n <= 0.0) {
        textureStore(dst, xy, o);
        return;
    }

    // M · (mean of the normalised powers)^(1/p) — the identity pass one factored
    // out, put back together. No floor: the brightest tap contributes exactly 1
    // to the sum, so the mean is at least its share of the weight.
    let rooted = select(
        vec4<f32>(0.0),
        peak * pow(acc_hi / n, vec4<f32>(1.0 / p.bokeh_power)),
        peak > vec4<f32>(0.0),
    );
    let v = acc_lo / n + rooted;

    // Composite mode: how the defocused result returns over the original.
    // Normal is the plain replace, which is what makes mode 0 identical to Lens
    // blur's blend.
    var composited = v;
    switch (p.composite_mode) {
        case 1u: { composited = o + v; }
        case 2u: { composited = o + v - o * v; }
        case 3u: { composited = max(o, v); }
        case 4u: { composited = min(o, v); }
        default: {}
    }
    textureStore(dst, xy, mix(o, composited, p.mix_amt));
}
