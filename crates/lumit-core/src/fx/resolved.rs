use std::sync::Arc;

use super::markers::flash_nth;
use super::*;
use crate::{
    expression::ExpressionContext,
    model::{EffectInstance, EffectNamespace, EffectValue},
};
use uuid::Uuid;

/// The Fast motion blur output view (docs/08 §3.2, FX-19): the finished blurred
/// picture, or a diagnostic look at the motion field or the confidence that
/// tapers the streak length. A per-pixel choice the kernel branches on last.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MbView {
    /// The blurred picture (the default).
    Rendered,
    /// The per-pixel flow vectors, colour-coded (red = +x, green = +y, grey =
    /// still) — for checking the motion the smear follows.
    MotionVectors,
    /// The per-pixel confidence as greyscale (white = trusted, black = suspect)
    /// — for seeing where the streak fades out.
    Confidence,
}

impl MbView {
    /// The kernel's integer code for this view (0 Rendered, 1 Motion vectors, 2
    /// Confidence), so the CPU oracle and the WGSL uniform agree.
    pub fn code(self) -> i32 {
        match self {
            MbView::Rendered => 0,
            MbView::MotionVectors => 1,
            MbView::Confidence => 2,
        }
    }
}

/// The Matte key output view (docs/08 §3.21, K-154): the finished keyed picture,
/// or a diagnostic look at the screen matte the key derives. A per-op choice the
/// kernel and CPU reference branch on (identically) at the end. The integer codes
/// are the wire form the WGSL uniform reads: 0 Final, 1 Screen matte, 2 Status.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MatteKeyView {
    /// The keyed, despilled, matte-applied picture (the default).
    Final,
    /// The screen matte itself as greyscale (white kept, black keyed) — for
    /// seeing exactly what the key is holding out.
    ScreenMatte,
    /// A continuous heat view of the matte: greyscale, with the uncertain
    /// mid-tones tinted so at-risk edges and holes stand out.
    Status,
}

impl MatteKeyView {
    /// The kernel's integer code (0 Final, 1 Screen matte, 2 Status), so the CPU
    /// oracle and the WGSL uniform agree.
    pub fn code(self) -> u32 {
        match self {
            MatteKeyView::Final => 0,
            MatteKeyView::ScreenMatte => 1,
            MatteKeyView::Status => 2,
        }
    }

    /// The view for a stored Choice index, clamped to the known set (unknown
    /// codes fall back to Final — a safe, non-diagnostic default).
    pub fn from_code(code: u32) -> Self {
        match code {
            1 => MatteKeyView::ScreenMatte,
            2 => MatteKeyView::Status,
            _ => MatteKeyView::Final,
        }
    }
}

/// How the Matte key recolours pixels where despill removed screen tint (docs/08
/// §3.21, K-154, Keylight's Replace method). Codes are the WGSL wire form: 0
/// Source, 1 Hard colour, 2 Soft colour, 3 None.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReplaceMethod {
    /// Keep the original source colour (no colour replacement; alpha still keys).
    Source,
    /// Blend in the flat replace colour where spill was removed.
    HardColour,
    /// Blend in the replace colour scaled by the pixel's own brightness (the
    /// default — it settles into shading rather than reading as a flat patch).
    SoftColour,
    /// Leave the despilled colour untouched.
    None,
}

impl ReplaceMethod {
    /// The kernel's integer code (0 Source, 1 Hard colour, 2 Soft colour, 3 None).
    pub fn code(self) -> u32 {
        match self {
            ReplaceMethod::Source => 0,
            ReplaceMethod::HardColour => 1,
            ReplaceMethod::SoftColour => 2,
            ReplaceMethod::None => 3,
        }
    }

    /// The method for a stored Choice index, clamped to the known set (unknown
    /// codes fall back to Soft colour, the tasteful default).
    pub fn from_code(code: u32) -> Self {
        match code {
            0 => ReplaceMethod::Source,
            1 => ReplaceMethod::HardColour,
            3 => ReplaceMethod::None,
            _ => ReplaceMethod::SoftColour,
        }
    }
}

/// The Matte key's full resolved parameter bundle (docs/08 §3.21, K-154): the
/// Keylight-style colour-difference keyer, flattened to plain numbers that the CPU
/// reference ([`cpu::matte_key`](crate::fx::cpu::matte_key)) and the WGSL kernel
/// both read, so preview and export match op-for-op (K-031). Every field is
/// already unit-normalised by the resolve step; the maths derive the screen's
/// primary channel and reference from `key` identically on both paths.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MatteKeyParams {
    /// Which picture to output (Final / Screen matte / Status), as a wire code.
    pub view: u32,
    /// Scene-linear RGBA screen (key) colour; alpha ignored. Its largest channel
    /// picks the primary screen axis.
    pub key: [f32; 4],
    /// Screen gain (Keylight's Screen strength): scales the matte's fall-off. 1.0
    /// keys the exact screen to zero; > 1 keys more aggressively. `≥ 0`.
    pub gain: f32,
    /// Screen balance, 0..1: how the two non-screen channels are weighted into the
    /// reference the primary is measured against (0 = their min, 1 = their max,
    /// 0.5 = their average, the default).
    pub balance: f32,
    /// Despill bias (scene-linear RGBA, alpha ignored): shifts the reference the
    /// unspill clamps the primary down to. A neutral grey is a no-op.
    pub despill_bias: [f32; 4],
    /// Alpha bias (scene-linear RGBA, alpha ignored): shifts what colour counts as
    /// neutral for the matte. A neutral grey is a no-op.
    pub alpha_bias: [f32; 4],
    /// Despill amount, 0..1: fraction of the primary's screen excess pulled out of
    /// kept pixels (Keylight's screen despill).
    pub spill: f32,
    /// Clip black, 0..1: screen-matte values at/below this map to 0 (fully keyed).
    pub clip_black: f32,
    /// Clip white, 0..1: screen-matte values at/above this map to 1 (fully kept).
    pub clip_white: f32,
    /// Clip rollback, 0..1: pulls the clipped matte back toward the un-clipped
    /// matte, recovering fine edge detail the clips would erode (0 = full clip).
    pub clip_rollback: f32,
    /// Replace method wire code (0 Source, 1 Hard, 2 Soft, 3 None).
    pub replace_method: u32,
    /// Scene-linear RGBA replace colour used by the Hard/Soft replace methods.
    pub replace_colour: [f32; 4],
    /// 0..1, blended against the untouched premultiplied input; 0 is the identity.
    pub mix: f32,
}

/// One sub-frame state of a shake's own motion blur (T18, K-165): the wobble
/// sampled at one point in the shutter, in the same `(offset_px, rotation_deg,
/// zoom)` form the frame-time shake carries. The dispatch turns each into an
/// affine through [`shake_affine`] and averages the resamples.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ShakeSample {
    /// Wobble offset at this sub-frame, raster pixels.
    pub offset_px: [f32; 2],
    /// Rotation wobble at this sub-frame, degrees.
    pub rotation_deg: f32,
    /// Zoom factor at this sub-frame; 1 = no depth (z) shake.
    pub zoom: f32,
}

impl ShakeSample {
    /// The neutral (identity) sample — the fixed-size array's initialiser.
    pub const IDENTITY: Self = Self {
        offset_px: [0.0, 0.0],
        rotation_deg: 0.0,
        zoom: 1.0,
    };
}

/// One effect, resolved to plain numbers at a frame — the flat form both the
/// WGSL kernels (lumit-gpu) and the CPU references below consume.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Resolved {
    Blur {
        /// Kernel half-width in *pixels of the target raster* (the caller
        /// converts from % diagonal using the raster it renders at, §2.3).
        radius_px: f32,
        /// 0 = Transparent, 1 = Repeat, 2 = Mirror.
        edge: u32,
        /// 0..1.
        mix: f32,
    },
    DirBlur {
        /// Full streak length in raster pixels.
        length_px: f32,
        /// Streak direction, degrees (0° = +x, y-down raster).
        angle_deg: f32,
        /// 0 = Transparent, 1 = Repeat, 2 = Mirror.
        edge: u32,
        /// 0..1.
        mix: f32,
    },
    /// Blur's Radial mode (docs/08 §3.8): rays from, or a tangent to the
    /// arc about, a centre — see the schema's status note for why both
    /// reduce to a pure linear scale of (position − centre) with no
    /// division or runtime trig.
    RadialBlur {
        /// Centre as a *fraction* of the raster (not raster pixels):
        /// resolve_stack carries only diag_px, not separate width/height,
        /// so the CPU/GPU function scales this by its own w/h — exactly
        /// how RGB split's radial mode already derives the frame centre.
        centre_frac: [f32; 2],
        /// Peak tap spread in raster pixels, reached at the frame's
        /// farthest corner from Centre (half the raster diagonal away).
        amount_px: f32,
        /// True = Spin (tangent direction), false = Zoom (radial direction).
        spin: bool,
        /// 0 = Transparent, 1 = Repeat, 2 = Mirror.
        edge: u32,
        /// 0..1.
        mix: f32,
    },
    Sharpen {
        /// Fraction of the detail signal added back (0..3 = 0–300%).
        amount: f32,
        /// The internal gaussian's half-width, in raster pixels.
        radius_px: f32,
        /// Linear-light detail magnitude below which nothing is added.
        threshold: f32,
        /// True: sharpen the Rec. 709 luma only (no chroma fringing).
        luma_only: bool,
        /// 0..1.
        mix: f32,
    },
    /// Sharpen (docs/08 §3.9, K-138): a plain 3×3 high-pass convolution scaled
    /// by `amount`, on unpremultiplied colour (§2.2), alpha untouched — the
    /// radius-free sibling of [`Resolved::Sharpen`] (the Unsharp mask). `out =
    /// u + amount·(4·u − up − down − left − right)` per RGB channel with
    /// clamp-addressed neighbours, clamped ≥ 0 and re-premultiplied. `amount`
    /// 0 (or `mix` 0) is the bit-exact passthrough.
    SharpenSimple {
        /// High-pass strength; 0 is the neutral point (1 = the classic 5/−1
        /// kernel).
        amount: f32,
        /// Neighbour distance in raster pixels (T15): 1 = a 3×3 kernel.
        radius: f32,
        /// 0..1.
        mix: f32,
    },
    RgbSplit {
        /// Peak tap offset in raster pixels.
        amount_px: f32,
        /// Shift direction, degrees (0° = +x, y-down raster).
        angle_deg: f32,
        /// Per-tap displacement scale (FX-9), `[t0, t1, t2]`: each tap shifts
        /// by `amount_px · scale[t]` — taps 0/1 along −offset, tap 2 along
        /// +offset. `[1, 0, 1]` is the classic split (the neutral default).
        scale: [f32; 3],
        /// The three taps' tints (T17), `[[r,g,b]; 3]`: each tap is sampled in
        /// full colour and multiplied by its tint, then summed. Defaults red /
        /// green / blue reproduce the classic channel-separated split bit-for-bit.
        tints: [[f32; 3]; 3],
        /// 0..1.
        mix: f32,
    },
    /// The RGB split's Wavelength mode (docs/08 §3.6, K-090): its own
    /// variant, exactly as Blur's Directional mode is — so the classic
    /// mode's path stays byte-identical. Chromatic aberration's own
    /// Wavelength mode (K-144) reuses this variant with `radial: true`.
    SpectralSplit {
        /// Peak spectral offset in raster pixels.
        amount_px: f32,
        /// Linear-mode shift direction, degrees (0° = +x, y-down raster).
        angle_deg: f32,
        /// True: offsets grow from the frame centre instead.
        radial: bool,
        /// The number of spectral taps (FX-9/K-144), clamped 3..=64. The taps
        /// (weight + offset fraction) are rebuilt from this by
        /// [`super::spectral_taps`] on both the CPU and GPU paths, so the enum
        /// stays `Copy` and both consume identical numbers.
        samples: i32,
        /// The three-colour picker driving the dispersion gradient (A1/K-163):
        /// `tints[0]` at the −offset end, `tints[1]` at centre, `tints[2]` at
        /// +offset. `spectral_taps` builds the per-tap colours from these, so
        /// the picker now controls the Wavelength fringe (default red/green/blue).
        tints: [[f32; 3]; 3],
        /// 0..1.
        mix: f32,
    },
    /// Chromatic aberration (docs/08 §3.15): a dedicated, always-radial
    /// sibling of RGB split's own Radial mode — always centred on the
    /// frame, no angle or linear mode of its own.
    ChromaticAberration {
        /// Peak channel offset in raster pixels, reached at the corner
        /// distance from the frame centre.
        amount_px: f32,
        /// The three radial taps' tints (P2/K-143), `[[r,g,b]; 3]` at
        /// fractions −1 / 0 / +1. Defaults red / green / blue reproduce the
        /// classic R-outward / B-inward / G-anchor split bit-for-bit (each
        /// tint keeps only its own channel of its tap).
        tints: [[f32; 3]; 3],
        /// 0..1.
        mix: f32,
    },
    Flash {
        /// The evaluated envelope × intensity, 0..1 (0 = no flash).
        strength: f32,
        /// Scene-linear RGBA flash colour (alpha unused: the flash respects
        /// the layer's own footprint).
        colour: [f32; 4],
        /// 0..1.
        mix: f32,
    },
    ColourBalance {
        /// Added per channel after gain (raises or crushes the blacks).
        lift: [f32; 3],
        /// Per-channel mid-tone exponent's base; 1 is neutral, > 0.
        gamma: [f32; 3],
        /// Per-channel linear multiplier; 1 is neutral.
        gain: [f32; 3],
        /// 0..1.
        mix: f32,
    },
    Saturation {
        /// Factor about Rec. 709 luma: 0 = greyscale, 1 = neutral, 2 =
        /// doubled, and open above (K-135) — the maths extrapolates.
        saturation: f32,
        /// 0..1.
        mix: f32,
    },
    Vibrancy {
        /// Per-pixel saturation-boost weight (K-152): 0 = neutral, higher lifts
        /// less-saturated pixels more. Open above (K-135), floored at 0.
        amount: f32,
        /// 0..1.
        mix: f32,
    },
    /// Matte key (docs/08 §3.21, K-121/K-154): a Keylight-style colour-difference
    /// keyer. The op carries its full parameter bundle ([`MatteKeyParams`]) so the
    /// CPU reference and the WGSL kernel consume the identical numbers (K-031). The
    /// maths are continuous everywhere (no hard step), so the §1.6 oracle holds; the
    /// default green screen colour keys out of the box, and Mix 0 is the identity.
    MatteKey(MatteKeyParams),
    /// Vignette (docs/08 §3.14): darkens toward black away from the frame
    /// centre. `radius`/`softness` are read against the Roundness-blended
    /// distance metric [`cpu::vignette`] computes from `w`/`h` — no raster
    /// conversion happens here, unlike the %-diag family, because the
    /// metric is already resolution-relative by construction.
    Vignette {
        /// 0..1: darkening strength; 0 is the neutral point.
        amount: f32,
        /// 0..1: the clear centre's reach.
        radius: f32,
        /// ≥ 0: feather width beyond radius, open above (K-135).
        softness: f32,
        /// 0..1: 1 = circular, 0 = follows the frame's aspect.
        roundness: f32,
        /// Gamma on the falloff (T16): 1 = plain smoothstep, ≠ 1 curves it.
        ramp: f32,
        /// 0..1.
        mix: f32,
    },
    /// Exposure (docs/08 §3.16): RGB × `factor` (= 2^stops), alpha untouched.
    /// `factor` 1.0 is the neutral point.
    Exposure {
        /// Linear gain, 2^stops.
        factor: f32,
        /// 0..1.
        mix: f32,
    },
    /// Hue shift (docs/08 §3.17, K-136): a row-major linear 3×3 colour matrix,
    /// computed host-side — either the constant-luminance rotation (Preserve
    /// luminance on) or the plain-RGB spin (off). The kernel is matrix-general,
    /// so both modes share one op. Identity is the neutral point.
    HueShift {
        /// Row-major 3×3: `[m00,m01,m02, m10,m11,m12, m20,m21,m22]`.
        m: [f32; 9],
        /// 0..1.
        mix: f32,
    },
    /// Contrast (docs/08 §3.18): the affine grade `(in − 0.5) × k + 0.5` per
    /// RGB channel on unpremultiplied colour, alpha untouched. `k` 1.0
    /// (Contrast 100 %) is the neutral point.
    Contrast {
        /// Contrast factor, `contrast_percent / 100`; 1.0 is neutral.
        k: f32,
        /// 0..1.
        mix: f32,
    },
    /// Gamma (docs/08 §3.19): the per-channel power curve
    /// `out = pow(max(in, 0), 1/gamma)` on unpremultiplied colour, alpha
    /// untouched. `gamma` 1.0 is the neutral point.
    Gamma {
        /// Gamma value; the curve raises to `1/gamma`. 1.0 is neutral,
        /// clamped ≥ 0.01 so the reciprocal stays finite.
        gamma: f32,
        /// 0..1.
        mix: f32,
    },
    /// Temperature (docs/08 §3.20): a warm/cool white balance as a per-channel
    /// R/B gain in scene-linear light, computed host-side, alpha untouched.
    /// Gains `(1.0, 1.0)` (Temperature 0) are the neutral point.
    Temperature {
        /// Scene-linear red gain, `max(0, 1 + 0.75·(temperature/100))`.
        gain_r: f32,
        /// Scene-linear blue gain, `max(0, 1 − 0.75·(temperature/100))`.
        gain_b: f32,
        /// 0..1.
        mix: f32,
    },
    /// Invert (docs/08 §3.23): the colour inverse `out.rgb = 1 − in.rgb` per RGB
    /// channel on unpremultiplied colour, alpha untouched. No neutral value —
    /// invert always inverts — so only Mix 0 is the identity.
    Invert {
        /// 0..1.
        mix: f32,
    },
    /// Tint (docs/08 §3.24): a luminance duotone. `out.rgb = black + (white −
    /// black)·luma(in)` with Rec.709 luma on the unpremultiplied colour, alpha
    /// untouched. The two mapped colours resolve to scene-linear RGB at frame
    /// time; Mix 0 is the identity.
    Tint {
        /// Scene-linear RGB the darkest input maps to.
        black: [f32; 3],
        /// Scene-linear RGB the brightest input maps to.
        white: [f32; 3],
        /// 0..1.
        mix: f32,
    },
    Transform {
        /// Anchor point, raster pixels (converted from px@comp, §2.3).
        anchor: [f32; 2],
        /// Where the anchor lands, raster pixels.
        position: [f32; 2],
        /// Per-axis factor; 1 is natural size, negative flips.
        scale: [f32; 2],
        /// Degrees about the anchor (0° = none; y-down raster, so positive
        /// turns clockwise on screen, matching the layer transform).
        rotation_deg: f32,
        /// 0..1, multiplied into the premultiplied output.
        opacity: f32,
        /// 0..1.
        mix: f32,
    },
    Glow {
        /// The halo gaussian's half-width in raster pixels.
        radius_px: f32,
        /// Linear-light bright threshold, ≥ 0 (unbounded above, K-090).
        threshold: f32,
        /// Soft-knee width around the threshold, 0..1.
        knee: f32,
        /// Gain on the added halo; 0 is the neutral point.
        intensity: f32,
        /// Scene-linear RGBA halo tint (alpha unused: the halo's own alpha
        /// is untinted coverage).
        tint: [f32; 4],
        /// 0..1.
        mix: f32,
    },
    /// A shake, already sampled at this frame (the noise runs at resolve
    /// time, host-side): the current wobble, dispatched through the Transform
    /// kernel via [`shake_affine`] — no kernel of its own. `edge` (P3, K-145)
    /// governs the border the resample reveals; there is no Auto-scale cover
    /// any more (FX-11/K-146 replaced it with this Edges control).
    Shake {
        /// This frame's wobble offset, raster pixels.
        offset_px: [f32; 2],
        /// This frame's rotation wobble, degrees.
        rotation_deg: f32,
        /// This frame's zoom factor; 1 = no depth (z) shake.
        zoom: f32,
        /// Edge policy for the revealed border: 0 Transparent, 1 Repeat,
        /// 2 Mirror ([`EdgesMode`]).
        edge: u32,
        /// 0..1.
        mix: f32,
        /// The shake's own motion blur (T18, K-165): `Some` when the toggle is
        /// on and the amount is non-zero — the wobble sampled at
        /// [`SHAKE_MB_SAMPLES`] sub-frame placements across the shutter, which
        /// the dispatch resamples and averages in premultiplied linear space
        /// (the accumulation-motion-blur philosophy, applied to this effect
        /// alone). `None` is the plain single resample, the bit-exact
        /// passthrough. The centre sample equals the frame-time wobble above.
        /// Sampled host-side because the noise lattice needs 64-bit integers
        /// the GPU has not got (docs/08 §3.12).
        mb: Option<[ShakeSample; SHAKE_MB_SAMPLES]>,
    },
    /// Block glitch (docs/08 §3.12, split out by K-107). `tick` is the
    /// local time already discretised at [`GLITCH_TICK_HZ`] (host-side, so
    /// the kernel never sees raw time or does its own time maths).
    /// Intensity 0 is the bit-exact passthrough (pinned by test) — see the
    /// schema's status note for why every hashed quantity here is scaled by
    /// it.
    BlockGlitch {
        /// The master 0..1 dial; scales every hashed quantity.
        intensity: f32,
        seed: u32,
        /// Local time discretised at [`GLITCH_TICK_HZ`] (§3.12 status
        /// note): per-block hashing reads this, not raw time.
        tick: i32,
        /// Raster pixels (px@comp × the §2.3 preview factor).
        block_size_px: f32,
        /// 0..1, fraction of block_size_px (the "Rows/columns jitter").
        jitter_frac: f32,
        /// Peak per-block displacement, raster pixels (% diag).
        amount_px: f32,
        /// Peak per-block R/B split, raster pixels (% diag).
        chan_px: f32,
        /// 0..1: odds (before the Intensity scale) a block slice-repeats.
        slice_frac: f32,
        /// 0..1.
        mix: f32,
    },
    /// Scanlines (docs/08 §3.12, split by K-107; single Intensity since
    /// FX-13/K-147). `roll_px` is the scanline pattern's already-computed
    /// pixel offset (roll speed × local time × period), host-computed so the
    /// kernel never sees raw time. Intensity 0 is the bit-exact passthrough
    /// (pinned by test).
    Scanlines {
        /// The single 0..1 dial: how dark the dark lines get (1 = black).
        /// An old project's separate Darkness folds into this at resolve.
        intensity: f32,
        /// Raster pixels (px@comp × the §2.3 preview factor).
        period_px: f32,
        /// The scanline pattern's pixel offset at this frame (roll speed ×
        /// local time × period_px, host-computed).
        roll_px: f32,
        interlace: bool,
        /// 0..1.
        mix: f32,
    },
    /// Datamosh (docs/08 §3.12, K-104, its own effect since K-107; reworked to
    /// a flow-driven melt by K-164/T19): follow the current→previous flow field
    /// out of the -1 source neighbour in a short streamline walk, accumulating
    /// the samples along it into a melting prediction blended over the current
    /// frame. The neighbour frame and its flow field are not carried here —
    /// like Echo's neighbour frames and Motion blur's flow field, they travel
    /// beside the resolved op, supplied only when the layer is footage and the
    /// decode fetched them; a missing pair degrades this to a no-op, never a
    /// fault. The periodic Reset (docs/08 §3.12) is already folded into
    /// `intensity`/`displacement` here — it is a pure function of layer time,
    /// so the kernel stays time-agnostic and the oracle tests the melt directly.
    Datamosh {
        /// Blend against the current frame; 0 the passthrough, > 1
        /// extrapolates past the moshed frame (open ceiling, K-135/FX-14).
        /// Already scaled by the reset ramp (0 at each simulated I-frame).
        intensity: f32,
        /// Total reach of the streamline walk in frames of predicted motion
        /// (K-161): `steps` samples span it, so each step advances ~1 frame of
        /// flow. Already scaled by the reset ramp.
        displacement: f32,
        /// How much of the reach accumulates (0..1): 0 keeps the nearest step
        /// (a short trail), 1 averages the whole walk (a long melting bloom).
        bloom: f32,
        /// Bilinear taps along the streamline (2..64, or 1), derived from
        /// `displacement` so each step is ~one frame of motion. Carried
        /// explicitly so the CPU oracle and WGSL kernel loop the same count.
        steps: i32,
        /// 0..1, the host Mix. Composes with `intensity` by multiplication
        /// before reaching the kernel (mixing the same two inputs twice
        /// collapses to one mix by the product), so the existing GPU/CPU
        /// maths need not carry a second blend knob.
        mix: f32,
    },
    /// Echo / trails (docs/08 §3.13). `weights[i]` is the intensity of the
    /// echo at frame offset `-(i+1)` (0 = no echo there); the render supplies
    /// the neighbour frame at each live offset. `mode` is the combine blend
    /// (FX-17/K-149): 0 = Add, 1 = Behind, 2 = Max, 3 = Screen, 4 = Normal,
    /// 5 = Multiply, 6 = Overlay, 7 = Soft light, 8 = Hard light, 9 = Darken.
    /// Up to 16 echoes (the raised static window).
    Echo {
        weights: [f32; 16],
        mode: u32,
        /// 0..1.
        mix: f32,
    },
    /// Flow motion blur (docs/08 §3.2). The per-pixel motion vectors are not
    /// carried here — they are a whole flow field, computed in the decode
    /// worker and passed to the kernel as a separate texture (the same way
    /// Echo's neighbour *frames* travel beside the resolved op, not inside
    /// it). This variant carries only the scalars the kernel needs to turn a
    /// vector into a streak.
    MotionBlur {
        /// Shutter ÷ 360: the streak length as a fraction of the inter-frame
        /// motion (0 = no blur; 0.5 at the 180° default).
        shutter_frac: f32,
        /// Evenly spaced bilinear taps along the streak (already rounded and
        /// clamped from the Samples parameter).
        samples: i32,
        /// 0..1.
        mix: f32,
        /// Which view to output (docs/08 §3.2, FX-19): the blurred picture, or a
        /// diagnostic look at the flow field or the confidence.
        view: MbView,
    },
    /// LUT (docs/08 §3.11, docs/impl/lut.md, K-114): a 3D `.cube` colour
    /// lookup. Only the host Mix is `Copy`-carried here; the parsed-and-
    /// uploaded cube is a whole 3D texture, so — like Echo's neighbour frames
    /// and Motion blur's flow field — it travels beside the resolved op (the
    /// caller's LUT cache fills a parallel `luts` slot), not inside it. An
    /// unset/1D/unreadable file leaves that slot empty and the op is a
    /// passthrough. `mix == 0` is the bit-exact input.
    Lut {
        /// 0..1.
        mix: f32,
    },
    /// Depth of field (docs/08 §3.22, docs/impl/layer-input.md): a lens blur
    /// whose per-pixel circle-of-confusion comes from a depth pass. Only the
    /// scalars are `Copy`-carried here; the depth is a whole texture — the
    /// referenced layer rendered alone at comp size — so (like the LUT's cube
    /// and Motion blur's flow field) it travels beside the resolved op (the
    /// caller fills a parallel `layer_inputs` slot), not inside it. An unset,
    /// missing or cyclic depth reference leaves that slot empty and the op is
    /// a passthrough. `aperture == 0`, an all-in-band depth, or `mix == 0` are
    /// bit-exact passthroughs.
    Dof {
        /// The in-focus depth, 0..1.
        focus: f32,
        /// Half-width of the sharp band around `focus`, 0..1.
        range: f32,
        /// Maximum circle-of-confusion radius for the **near** side (depths in
        /// front of focus, `d < focus`), raster pixels — the per-side Near blur
        /// already scaled by the Aperture master and the §2.3 preview factor.
        near_aperture: f32,
        /// Maximum circle-of-confusion radius for the **far** side (depths
        /// behind focus, `d >= focus`), raster pixels — the Far blur already
        /// scaled by the master and the preview factor.
        far_aperture: f32,
        /// When set, the per-pixel depth is inverted (`d' = 1 - d`) before the
        /// circle-of-confusion, swapping near and far. A `Copy` scalar, so the
        /// enum stays `Copy` and threads beside the depth texture unchanged.
        depth_invert: bool,
        /// Diagnostic view: 0 = Rendered (the blurred output), 1 = Depth map
        /// (post-invert greyscale), 2 = Focus map (the smooth in-focus mask).
        /// Modes 1/2 ignore the blur and Mix and write the view directly.
        display: u32,
        /// 0..1.
        mix: f32,
    },
    /// Lens flare (docs/08 §3.27, docs/impl/lens-flare.md, K-256): traced
    /// ghosts and the Fourier starburst. The op carries its full parameter
    /// bundle ([`LensFlareParams`], all plain numbers); the baked resources
    /// (disc/starburst textures, ghost ranking) derive from those numbers
    /// through `lens_flare::bake`, cached GPU-side by [`lens_flare::bake_key`]
    /// — so nothing travels beside the op. GPU-only: the CPU degradation rung
    /// renders it as a labelled no-op (the K-114 LUT precedent).
    /// Lens flare (docs/08 §3.27, docs/impl/lens-flare.md, K-256): traced
    /// ghosts and the Fourier starburst. The op carries its full parameter
    /// bundle ([`LensFlareParams`], all plain numbers); the baked resources
    /// (disc/starburst textures, ghost ranking) derive from those numbers
    /// through `lens_flare::bake`, cached GPU-side by [`lens_flare::bake_key`]
    /// — so nothing travels beside the op. GPU-only: the CPU degradation rung
    /// renders it as a labelled no-op (the K-114 LUT precedent).
    LensFlare(crate::fx::lens_flare::LensFlareParams),
    /// Lens dirt generator (docs/08 §3.28): procedurally generates out-of-focus
    /// aperture bokeh disks, micro dust specks, hairline scratches, smudges,
    /// and optical vignetting overlay.
    LensDirt(LensDirtParams),
}

/// Resolved parameters for the procedural Lens Dirt generator (docs/08 §3.28).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LensDirtParams {
    pub intensity: f32,
    pub density: f32,
    pub bokeh_layers: u32,
    pub scale: f32,
    pub scale_var_x: f32,
    pub scale_var_y: f32,
    pub rotation_var: f32,
    pub scratch_scale: f32,
    pub defocus: f32,
    pub defocus_var: f32,
    pub color_var: f32,
    pub chromatic: f32,

    pub scratches: f32,
    pub scratch_var: f32,
    pub scratch_tint: [f32; 4],
    pub dirt: f32,
    pub dirt_tint: [f32; 4],
    pub tint: [f32; 4],
    pub vignette: f32,
    /// Blend mode wire code: 0 = Screen, 1 = Add, 2 = Overlay, 3 = Solo (dirt map only).
    pub blend_mode: u32,
    /// Background mode wire code: 0 = Transparent, 1 = Color fill, 2 = Sun / Light source.
    pub bg_mode: u32,
    pub bg_colour: [f32; 4],
    pub sun_pos: [f32; 2],
    pub sun_intensity: f32,
    pub sun_radius: f32,
    pub seed: u32,
    pub mix: f32,
}






/// Resolve a layer's live stack at layer time `lt` for a raster whose
/// diagonal is `diag_px` pixels; `px_scale` is raster pixels per comp pixel
/// (the §2.3 preview-resolution factor — 1.0 at full resolution), which
/// converts px@comp parameters exactly as `diag_px` converts % diag ones.
/// `markers` is the layer's §1.4 marker context ([`MarkerContext::for_layer`],
/// or [`MarkerContext::NONE`] where no comp is in play), consumed by the
/// marker-driven modes (Flash's Trigger and Strobe, §3.7). Placeholders,
/// unknown names and bypassed effects resolve to nothing (they render as
/// identity, docs/03 §8).
/// Rescale every pixel-dimensioned field of already-resolved ops by `f` —
/// the repair for a stack resolved against one raster and run on another
/// (K-266). The Adjust arm of the draw builder resolves with `px_scale` 1
/// because its stack runs on "the comp-sized intermediate" — which is only
/// true at full preview resolution. Under reduced-resolution preview the
/// intermediate is the preview raster, and every px@comp parameter (the
/// flare's light, DoF apertures, blur radii) landed too far right and too
/// big by exactly the preview factor; the owner measured the flare's light
/// hitting the frame edge at 1500 of a 1920 comp. The realise walk calls
/// this with `render_width / comp_width` before running an adjustment
/// stack.
///
/// Exhaustive on purpose: a new op must decide here whether it owns pixel
/// fields, so the bug cannot quietly return with the next effect.
pub fn rescale_px(ops: &mut [Resolved], f: f32) {
    if (f - 1.0).abs() < 1e-6 {
        return;
    }
    for op in ops {
        match op {
            Resolved::Blur { radius_px, .. } => *radius_px *= f,
            Resolved::DirBlur { length_px, .. } => *length_px *= f,
            // Radial blur's centre is a frame fraction; only the legacy
            // strength is per-frame-relative too. Nothing in pixels.
            Resolved::RadialBlur { .. } => {}
            Resolved::Sharpen { radius_px, .. } => *radius_px *= f,
            // SharpenSimple's radius is a fixed 3x3 kernel scale, not px.
            Resolved::SharpenSimple { .. } => {}
            Resolved::RgbSplit { amount_px, .. } => *amount_px *= f,
            Resolved::SpectralSplit { amount_px, .. } => *amount_px *= f,
            Resolved::ChromaticAberration { amount_px, .. } => *amount_px *= f,
            Resolved::Flash { .. }
            | Resolved::ColourBalance { .. }
            | Resolved::Saturation { .. }
            | Resolved::Vibrancy { .. }
            | Resolved::MatteKey(_)
            | Resolved::Vignette { .. }
            | Resolved::Exposure { .. }
            | Resolved::HueShift { .. }
            | Resolved::Contrast { .. }
            | Resolved::Gamma { .. }
            | Resolved::Temperature { .. }
            | Resolved::Invert { .. }
            | Resolved::Tint { .. }
            | Resolved::Lut { .. } => {}
            Resolved::Transform {
                anchor, position, ..
            } => {
                anchor[0] *= f;
                anchor[1] *= f;
                position[0] *= f;
                position[1] *= f;
            }
            Resolved::Glow { radius_px, .. } => *radius_px *= f,
            Resolved::Shake { offset_px, mb, .. } => {
                offset_px[0] *= f;
                offset_px[1] *= f;
                if let Some(samples) = mb {
                    for s in samples.iter_mut() {
                        s.offset_px[0] *= f;
                        s.offset_px[1] *= f;
                    }
                }
            }
            Resolved::BlockGlitch {
                block_size_px,
                amount_px,
                chan_px,
                ..
            } => {
                *block_size_px *= f;
                *amount_px *= f;
                *chan_px *= f;
            }
            // Scanlines' period and Datamosh's blocks follow their own
            // texture-relative conventions (docs/08); Echo and MotionBlur
            // carry times and flow scales, not pixels.
            Resolved::Scanlines { .. }
            | Resolved::Datamosh { .. }
            | Resolved::Echo { .. }
            | Resolved::MotionBlur { .. } => {}
            Resolved::Dof {
                near_aperture,
                far_aperture,
                ..
            } => {
                *near_aperture *= f;
                *far_aperture *= f;
            }
            Resolved::LensFlare(p) => {
                p.light[0] *= f;
                p.light[1] *= f;
            }
            Resolved::LensDirt(_) => {}
        }
    }
}


pub fn resolve_stack(
    effects: &[EffectInstance],
    lt: f64,
    diag_px: f32,
    px_scale: f32,
    markers: &MarkerContext,
    context: Arc<ExpressionContext>,
) -> Vec<Resolved> {
    effects
        .iter()
        .filter(|e| e.enabled && e.effect.namespace == EffectNamespace::Builtin)
        .filter_map(|e| resolve_one(e, lt, diag_px, px_scale, markers, context.clone()))
        .collect()
}

/// Resolve a layer's live stack for a held/sub-frame re-render (docs/impl/
/// temporal-rerender.md §5): an effect flagged `sample_temporally == false`
/// resolves at the true frame time `frame_lt` (so a particle system or other
/// costly/stochastic effect is not re-run per held sample), while every other
/// effect resolves at the held/sample time `sample_lt`. When `sample_lt ==
/// frame_lt` this is byte-identical to [`resolve_stack`], so an ordinary
/// (non-temporal) render is unchanged — the two share [`resolve_one`], differing
/// only in which layer time each effect is handed.
pub fn resolve_stack_temporal(
    effects: &[EffectInstance],
    sample_lt: f64,
    frame_lt: f64,
    diag_px: f32,
    px_scale: f32,
    markers: &MarkerContext,
    context: Arc<ExpressionContext>,
) -> Vec<Resolved> {
    resolve_stack_temporal_named(
        effects, sample_lt, frame_lt, diag_px, px_scale, markers, context,
    )
    .into_iter()
    .map(|(_, op)| op)
    .collect()
}

/// [`resolve_stack_temporal`] with each op paired with the id of the effect
/// instance it came from.
///
/// **Why the ids matter.** A [`Resolved`] op is a flat bag of numbers: by
/// design it has forgotten which effect wrote it, because the kernels do not
/// care. The render-time indicator does care — a measured millisecond has to
/// land on the right row of the effect stack — and the mapping cannot be
/// reconstructed afterwards by filtering the effect list, because
/// [`resolve_one`] also drops placeholders, unknown names and the
/// orchestration-only effects. So the one walk that knows both answers reports
/// both, and everything else stays 1:1 by construction.
#[allow(clippy::too_many_arguments)]
pub fn resolve_stack_temporal_named(
    effects: &[EffectInstance],
    sample_lt: f64,
    frame_lt: f64,
    diag_px: f32,
    px_scale: f32,
    markers: &MarkerContext,
    context: Arc<ExpressionContext>,
) -> Vec<(Uuid, Resolved)> {
    effects
        .iter()
        .filter(|e| e.enabled && e.effect.namespace == EffectNamespace::Builtin)
        .filter_map(|e| {
            let lt = if e.sample_temporally {
                sample_lt
            } else {
                frame_lt
            };
            resolve_one(e, lt, diag_px, px_scale, markers, context.clone()).map(|op| (e.id, op))
        })
        .collect()
}

/// Resolve one effect instance to its flat [`Resolved`] op at layer time `lt`,
/// or None when it is a placeholder, an unknown name, or an orchestration-only
/// effect (Posterize time, accumulation motion blur) that has no per-pixel op.
/// The shared core of [`resolve_stack`] and [`resolve_stack_temporal`].
fn resolve_one(
    e: &EffectInstance,
    lt: f64,
    diag_px: f32,
    px_scale: f32,
    markers: &MarkerContext,
    expression_context: Arc<ExpressionContext>,
) -> Option<Resolved> {
    match e.effect.match_name.as_str() {
        "blur" => {
            // Gaussian blur (docs/08 §3.8, K-137). match_name "blur" is kept,
            // so a project saved with the old mode-driven blur — whatever mode
            // it stored — loads here as Gaussian at its Radius, byte-identically
            // (its now-unread mode/length/centre params are simply ignored).
            // Fixed Repeat edge (K-137 dropped the Gaussian Edges control; 1 was
            // its default).
            let radius_pct =
                e.float_at_with_context("radius", lt, expression_context.clone())? as f32;
            let mix = (e
                .float_at_with_context("mix", lt, expression_context.clone())
                .unwrap_or(100.0) as f32
                / 100.0)
                .clamp(0.0, 1.0);
            Some(Resolved::Blur {
                radius_px: (radius_pct / 100.0 * diag_px).max(0.0),
                edge: 1,
                mix,
            })
        }
        "directional_blur" => {
            // Directional blur (docs/08 §3.8, K-137): Length/Angle only, fixed
            // Repeat edge (the Edges control is Radial's alone now).
            let length_pct = e
                .float_at_with_context("length", lt, expression_context.clone())
                .unwrap_or(0.0) as f32;
            let angle_deg = e
                .float_at_with_context("angle", lt, expression_context.clone())
                .unwrap_or(0.0) as f32;
            let mix = (e
                .float_at_with_context("mix", lt, expression_context.clone())
                .unwrap_or(100.0) as f32
                / 100.0)
                .clamp(0.0, 1.0);
            Some(Resolved::DirBlur {
                length_px: (length_pct / 100.0 * diag_px).max(0.0),
                angle_deg,
                edge: 1,
                mix,
            })
        }
        "radial_blur" => {
            // Radial blur (docs/08 §3.8, K-137): Centre/Amount/Type, plus the
            // family's own Edges control (kept only here).
            let cx = (e
                .float_at_with_context("centre_x", lt, expression_context.clone())
                .unwrap_or(50.0)
                / 100.0) as f32;
            let cy = (e
                .float_at_with_context("centre_y", lt, expression_context.clone())
                .unwrap_or(50.0)
                / 100.0) as f32;
            let amount_pct = e
                .float_at_with_context("amount", lt, expression_context.clone())
                .unwrap_or(0.0) as f32;
            let spin = !matches!(e.param("radial_type"), Some(EffectValue::Choice(1)));
            // The reusable Edges control (P3, K-145): the stored Choice maps
            // through EdgesMode (clamped to the known set, default Repeat).
            let edge = match e.param("edge") {
                Some(EffectValue::Choice(c)) => {
                    EdgesMode::from_code((*c).min(2)).unwrap_or(EdgesMode::Repeat)
                }
                _ => EdgesMode::Repeat,
            };
            let mix = (e
                .float_at_with_context("mix", lt, expression_context.clone())
                .unwrap_or(100.0) as f32
                / 100.0)
                .clamp(0.0, 1.0);
            Some(Resolved::RadialBlur {
                centre_frac: [cx, cy],
                amount_px: (amount_pct / 100.0 * diag_px).max(0.0),
                spin,
                edge: edge.code(),
                mix,
            })
        }
        "sharpen" => {
            let amount =
                (e.float_at_with_context("amount", lt, expression_context.clone())? as f32 / 100.0)
                    .clamp(0.0, 3.0);
            let radius_pct =
                e.float_at_with_context("radius", lt, expression_context.clone())? as f32;
            let threshold = (e
                .float_at_with_context("threshold", lt, expression_context.clone())
                .unwrap_or(0.05) as f32)
                .clamp(0.0, 1.0);
            let luma_only = match e.param("luminance_only") {
                Some(EffectValue::Bool(b)) => *b,
                _ => true,
            };
            let mix = (e
                .float_at_with_context("mix", lt, expression_context.clone())
                .unwrap_or(100.0) as f32
                / 100.0)
                .clamp(0.0, 1.0);
            Some(Resolved::Sharpen {
                amount,
                radius_px: (radius_pct / 100.0 * diag_px).max(0.0),
                threshold,
                luma_only,
                mix,
            })
        }
        "sharpen_simple" => {
            // The plain 3×3 sharpen (docs/08 §3.9, K-138): Amount is a raw
            // high-pass strength (not a per-cent), clamped ≥ 0.
            let amount = (e.float_at_with_context("amount", lt, expression_context.clone())?
                as f32)
                .max(0.0);
            let radius = (e
                .float_at_with_context("radius", lt, expression_context.clone())
                .unwrap_or(1.0) as f32)
                .max(1.0);
            let mix = (e
                .float_at_with_context("mix", lt, expression_context.clone())
                .unwrap_or(100.0) as f32
                / 100.0)
                .clamp(0.0, 1.0);
            Some(Resolved::SharpenSimple {
                amount,
                radius,
                mix,
            })
        }
        "rgb_split" => {
            let amount_pct =
                e.float_at_with_context("amount", lt, expression_context.clone())? as f32;
            let angle_deg = e
                .float_at_with_context("angle", lt, expression_context.clone())
                .unwrap_or(0.0) as f32;
            // Instances saved before the Wavelength mode existed carry
            // no such parameter and resolve as the classic split.
            let wavelength = match e.param("wavelength") {
                Some(EffectValue::Bool(b)) => *b,
                _ => false,
            };
            let mix = (e
                .float_at_with_context("mix", lt, expression_context.clone())
                .unwrap_or(100.0) as f32
                / 100.0)
                .clamp(0.0, 1.0);
            let amount_px = (amount_pct / 100.0 * diag_px).max(0.0);
            // The three tap tints (T17/K-161): absent on pre-feature projects →
            // the classic red / green / blue, which reproduce the historical
            // channel-separated split and, in Wavelength mode (A1/K-163), a
            // red→green→blue dispersion.
            let tint = |id: &str, default: [f64; 4]| -> [f32; 3] {
                let c = e.colour_at(id, lt).unwrap_or(default);
                [c[0] as f32, c[1] as f32, c[2] as f32]
            };
            let tints = [
                tint("channel_colour_1", [1.0, 0.0, 0.0, 1.0]),
                tint("channel_colour_2", [0.0, 1.0, 0.0, 1.0]),
                tint("channel_colour_3", [0.0, 0.0, 1.0, 1.0]),
            ];
            Some(if wavelength {
                // Wavelength mode ignores the per-tap scales; its tap count is
                // the Samples parameter (absent on pre-feature projects → the
                // default 16, denser than the historical 9). RGB split is now
                // linear-only (T17), so the spectral sibling is never radial here.
                // The picker drives the dispersion gradient (A1/K-163).
                let samples = e
                    .float_at_with_context("samples", lt, expression_context.clone())
                    .unwrap_or(16.0)
                    .round() as i32;
                Resolved::SpectralSplit {
                    amount_px,
                    angle_deg,
                    radial: false,
                    samples,
                    tints,
                    mix,
                }
            } else {
                // Per-tap scales (FX-9): per cent → factor. Absent on
                // pre-feature projects → the classic 1 / 0 / 1 defaults.
                let scale = |id: &str, default: f64| {
                    (e.float_at_with_context(id, lt, expression_context.clone())
                        .unwrap_or(default)
                        / 100.0) as f32
                };
                Resolved::RgbSplit {
                    amount_px,
                    angle_deg,
                    scale: [
                        scale("red_amount", 100.0),
                        scale("green_amount", 0.0),
                        scale("blue_amount", 100.0),
                    ],
                    // Normalised per channel (K-167): aligned regions pass
                    // through unchanged; the picker tints only the fringes.
                    tints: super::normalise_tint_columns(tints),
                    mix,
                }
            })
        }
        "chromatic_aberration" => {
            let amount_px = (e
                .float_at_with_context("amount", lt, expression_context.clone())
                .unwrap_or(4.0) as f32
                * px_scale)
                .max(0.0);
            let mix = (e
                .float_at_with_context("mix", lt, expression_context.clone())
                .unwrap_or(100.0) as f32
                / 100.0)
                .clamp(0.0, 1.0);
            // Wavelength mode (K-144) reuses RGB split's spectral machinery as
            // a radial spectral split; off (and absent on pre-feature
            // projects) keeps the three tinted radial taps.
            let wavelength = matches!(e.param("wavelength"), Some(EffectValue::Bool(true)));
            // The three channel colours (P2/K-143): absent on pre-feature
            // projects → the classic red / green / blue, which reproduce the
            // historical R-outward / B-inward / G-anchor split and, in Wavelength
            // mode (A1/K-163), a red→green→blue dispersion.
            let tint = |id: &str, default: [f64; 4]| -> [f32; 3] {
                let c = e.colour_at(id, lt).unwrap_or(default);
                [c[0] as f32, c[1] as f32, c[2] as f32]
            };
            let tints = [
                tint("channel_colour_1", [1.0, 0.0, 0.0, 1.0]),
                tint("channel_colour_2", [0.0, 1.0, 0.0, 1.0]),
                tint("channel_colour_3", [0.0, 0.0, 1.0, 1.0]),
            ];
            Some(if wavelength {
                let samples = e
                    .float_at_with_context("samples", lt, expression_context.clone())
                    .unwrap_or(16.0)
                    .round() as i32;
                Resolved::SpectralSplit {
                    amount_px,
                    angle_deg: 0.0,
                    radial: true,
                    samples,
                    tints,
                    mix,
                }
            } else {
                Resolved::ChromaticAberration {
                    amount_px,
                    // Normalised per channel (K-167), like RGB split's classic
                    // mode: only the misaligned fringes take the colours.
                    tints: super::normalise_tint_columns(tints),
                    mix,
                }
            })
        }
        "flash" => {
            // Instances saved before the marker modes existed carry no
            // "mode" parameter and resolve as Manual — byte-identically.
            let mode = match e.param("mode") {
                Some(EffectValue::Choice(c)) => *c,
                _ => 0,
            };
            let envelope = match mode {
                // Trigger (1) and Strobe (2): the §3.7 beat envelope
                // from the §1.4 context; Strobe thins the beat list to
                // every Nth.
                1 | 2 => {
                    let duration = e
                        .float_at_with_context("duration", lt, expression_context.clone())
                        .unwrap_or(2.0)
                        .max(0.0);
                    let fade = matches!(e.param("shape"), Some(EffectValue::Choice(1)));
                    let nth = if mode == 2 { flash_nth(e, lt) } else { 1 };
                    let phase = e
                        .float_at_with_context("phase", lt, expression_context.clone())
                        .unwrap_or(0.0);
                    flash_beat_envelope(markers, lt, duration, fade, nth, phase)
                }
                // Manual: keyframed hits on Trigger, decaying over
                // Decay — the original form, untouched.
                _ => {
                    let decay_s = (e
                        .float_at_with_context("decay", lt, expression_context.clone())
                        .unwrap_or(120.0)
                        / 1000.0)
                        .max(0.0);
                    match e.param("trigger") {
                        Some(EffectValue::Float(p)) => flash_envelope(p, lt, decay_s),
                        _ => 0.0,
                    }
                }
            };
            let intensity = e
                .float_at_with_context("intensity", lt, expression_context.clone())
                .unwrap_or(100.0)
                .max(0.0)
                / 100.0;
            let colour = e.colour_at("colour", lt).unwrap_or([1.0; 4]);
            let mix = (e
                .float_at_with_context("mix", lt, expression_context.clone())
                .unwrap_or(100.0) as f32
                / 100.0)
                .clamp(0.0, 1.0);
            Some(Resolved::Flash {
                strength: (envelope * intensity).clamp(0.0, 1.0) as f32,
                colour: colour.map(|c| c as f32),
                mix,
            })
        }
        "colour_balance" => {
            let rgb = |id: &str, neutral: f64| -> [f32; 3] {
                let c = e.colour_at(id, lt).unwrap_or([neutral; 4]);
                [c[0] as f32, c[1] as f32, c[2] as f32]
            };
            let mix = (e
                .float_at_with_context("mix", lt, expression_context.clone())
                .unwrap_or(100.0) as f32
                / 100.0)
                .clamp(0.0, 1.0);
            Some(Resolved::ColourBalance {
                lift: rgb("lift", 0.0),
                gamma: rgb("gamma", 1.0).map(|g| g.max(0.01)),
                gain: rgb("gain", 1.0),
                mix,
            })
        }
        "saturation" => {
            // Floored at 0 (greyscale), open above (K-135): the luma/colour
            // mix extrapolates past 200 % cleanly, so no upper clamp.
            let saturation = (e
                .float_at_with_context("saturation", lt, expression_context.clone())
                .unwrap_or(100.0) as f32
                / 100.0)
                .max(0.0);
            let mix = (e
                .float_at_with_context("mix", lt, expression_context.clone())
                .unwrap_or(100.0) as f32
                / 100.0)
                .clamp(0.0, 1.0);
            Some(Resolved::Saturation { saturation, mix })
        }
        "vibrancy" => {
            // Floored at 0 (neutral), open above (K-135): the per-pixel factor
            // extrapolates cleanly, so no upper clamp.
            let amount = (e
                .float_at_with_context("amount", lt, expression_context.clone())
                .unwrap_or(0.0) as f32
                / 100.0)
                .max(0.0);
            let mix = (e
                .float_at_with_context("mix", lt, expression_context.clone())
                .unwrap_or(100.0) as f32
                / 100.0)
                .clamp(0.0, 1.0);
            Some(Resolved::Vibrancy { amount, mix })
        }
        "matte_key" => {
            // Keylight-style colour-difference keyer (K-154, superseding the
            // K-121 chroma-distance key). Every colour resolves to a scene-linear
            // array at frame time; the CPU reference and the WGSL kernel derive
            // the screen's primary channel and reference from `key` identically.
            // Per-cent dials become plain 0..1 fractions. A project saved before
            // K-154 keeps its stored `key` (screen colour) and `spill` (now the
            // despill amount); its old `tolerance`/`softness` are superseded by
            // gain/balance/clip and simply go unread, and the new controls take
            // their Keylight defaults — see the §3.21 migration note.
            let colour = |id: &str, def: [f64; 4]| -> [f32; 4] {
                e.colour_at(id, lt).unwrap_or(def).map(|c| c as f32)
            };
            let view = match e.param("view") {
                Some(EffectValue::Choice(c)) => *c,
                _ => 0,
            };
            let gain = (e
                .float_at_with_context("screen_gain", lt, expression_context.clone())
                .unwrap_or(100.0) as f32
                / 100.0)
                .max(0.0);
            let balance = (e
                .float_at_with_context("screen_balance", lt, expression_context.clone())
                .unwrap_or(50.0) as f32
                / 100.0)
                .clamp(0.0, 1.0);
            // Despill defaults on (Keylight-like); an older instance carrying a
            // Spill value keeps it, an even older one without the param reads 0.
            let spill = (e
                .float_at_with_context("spill", lt, expression_context.clone())
                .unwrap_or(100.0) as f32
                / 100.0)
                .clamp(0.0, 1.0);
            let clip_black = (e
                .float_at_with_context("clip_black", lt, expression_context.clone())
                .unwrap_or(0.0) as f32
                / 100.0)
                .clamp(0.0, 1.0);
            let clip_white = (e
                .float_at_with_context("clip_white", lt, expression_context.clone())
                .unwrap_or(100.0) as f32
                / 100.0)
                .clamp(0.0, 1.0);
            let clip_rollback = (e
                .float_at_with_context("clip_rollback", lt, expression_context.clone())
                .unwrap_or(0.0) as f32
                / 100.0)
                .clamp(0.0, 1.0);
            let replace_method = match e.param("replace_method") {
                Some(EffectValue::Choice(c)) => ReplaceMethod::from_code(*c).code(),
                _ => ReplaceMethod::SoftColour.code(),
            };
            let mix = (e
                .float_at_with_context("mix", lt, expression_context.clone())
                .unwrap_or(100.0) as f32
                / 100.0)
                .clamp(0.0, 1.0);
            Some(Resolved::MatteKey(MatteKeyParams {
                view: MatteKeyView::from_code(view).code(),
                key: colour("key", [0.0, 0.6, 0.0, 1.0]),
                gain,
                balance,
                despill_bias: colour("despill_bias", [0.5, 0.5, 0.5, 1.0]),
                alpha_bias: colour("alpha_bias", [0.5, 0.5, 0.5, 1.0]),
                spill,
                clip_black,
                clip_white,
                clip_rollback,
                replace_method,
                replace_colour: colour("replace_colour", [0.5, 0.5, 0.5, 1.0]),
                mix,
            }))
        }
        "vignette" => {
            let amount = (e
                .float_at_with_context("amount", lt, expression_context.clone())
                .unwrap_or(0.5) as f32)
                .clamp(0.0, 1.0);
            let radius = (e
                .float_at_with_context("radius", lt, expression_context.clone())
                .unwrap_or(0.75) as f32)
                .clamp(0.0, 1.0);
            // Floored at 0, open above (K-135): softness > 1 is a legal wider
            // feather in the normalised metric, no upper clamp.
            let softness = (e
                .float_at_with_context("softness", lt, expression_context.clone())
                .unwrap_or(0.5) as f32)
                .max(0.0);
            let roundness = (e
                .float_at_with_context("roundness", lt, expression_context.clone())
                .unwrap_or(1.0) as f32)
                .clamp(0.0, 1.0);
            let ramp = (e
                .float_at_with_context("ramp", lt, expression_context.clone())
                .unwrap_or(1.0) as f32)
                .max(0.05);
            let mix = (e
                .float_at_with_context("mix", lt, expression_context.clone())
                .unwrap_or(100.0) as f32
                / 100.0)
                .clamp(0.0, 1.0);
            Some(Resolved::Vignette {
                amount,
                radius,
                softness,
                roundness,
                ramp,
                mix,
            })
        }
        "exposure" => {
            let stops = e
                .float_at_with_context("stops", lt, expression_context.clone())
                .unwrap_or(0.0);
            let factor = 2f64.powf(stops) as f32;
            let mix = (e
                .float_at_with_context("mix", lt, expression_context.clone())
                .unwrap_or(100.0) as f32
                / 100.0)
                .clamp(0.0, 1.0);
            Some(Resolved::Exposure { factor, mix })
        }
        "hue_shift" => {
            let angle = e
                .float_at_with_context("angle", lt, expression_context.clone())
                .unwrap_or(0.0);
            // Preserve luminance (K-136): on (default, and absent on old
            // projects) → the Rec.709 constant-luminance rotation; off → the
            // plain-RGB spin about the grey axis. The bool only picks which
            // host-computed matrix is carried, so CPU and GPU stay in parity.
            let preserve = !matches!(
                e.param("preserve_luminance"),
                Some(EffectValue::Bool(false))
            );
            let m = if preserve {
                hue_matrix(angle)
            } else {
                hue_matrix_rgb(angle)
            };
            let mix = (e
                .float_at_with_context("mix", lt, expression_context.clone())
                .unwrap_or(100.0) as f32
                / 100.0)
                .clamp(0.0, 1.0);
            Some(Resolved::HueShift { m, mix })
        }
        "contrast" => {
            // k = contrast_percent / 100; hard min 0 (no inversion),
            // unbounded above — the schema's own honest shape.
            let k = (e
                .float_at_with_context("contrast", lt, expression_context.clone())
                .unwrap_or(100.0) as f32
                / 100.0)
                .max(0.0);
            let mix = (e
                .float_at_with_context("mix", lt, expression_context.clone())
                .unwrap_or(100.0) as f32
                / 100.0)
                .clamp(0.0, 1.0);
            Some(Resolved::Contrast { k, mix })
        }
        "gamma" => {
            // Hard floor 0.01 keeps 1/gamma finite; no ceiling — the
            // schema's own honest shape.
            let gamma = (e
                .float_at_with_context("gamma", lt, expression_context.clone())
                .unwrap_or(1.0) as f32)
                .max(0.01);
            let mix = (e
                .float_at_with_context("mix", lt, expression_context.clone())
                .unwrap_or(100.0) as f32
                / 100.0)
                .clamp(0.0, 1.0);
            Some(Resolved::Gamma { gamma, mix })
        }
        "temperature" => {
            // k = Temperature / 100, clamped to the ±2 hard range (±200). The
            // stronger ±0.75·k gain (K-135) makes full deflection a decisive
            // orange/blue; the gains floor at 0 so an extreme never drives a
            // channel negative. Computed here so the CPU reference and the
            // WGSL kernel multiply by byte-identical f32 factors (§1.6);
            // Temperature 0 → k 0 → gains exactly (1.0, 1.0), the neutral
            // point (the .max(0.0) leaves 1.0 untouched).
            let k = (e
                .float_at_with_context("temperature", lt, expression_context.clone())
                .unwrap_or(0.0) as f32
                / 100.0)
                .clamp(-2.0, 2.0);
            let gain_r = (1.0 + 0.75 * k).max(0.0);
            let gain_b = (1.0 - 0.75 * k).max(0.0);
            let mix = (e
                .float_at_with_context("mix", lt, expression_context.clone())
                .unwrap_or(100.0) as f32
                / 100.0)
                .clamp(0.0, 1.0);
            Some(Resolved::Temperature {
                gain_r,
                gain_b,
                mix,
            })
        }
        "invert" => {
            let mix = (e
                .float_at_with_context("mix", lt, expression_context.clone())
                .unwrap_or(100.0) as f32
                / 100.0)
                .clamp(0.0, 1.0);
            Some(Resolved::Invert { mix })
        }
        "tint" => {
            // The two mapped colours resolve to scene-linear RGB at frame
            // time (alpha ignored); the CPU reference and the WGSL kernel
            // read the identical numbers.
            let rgb = |id: &str, default: [f64; 4]| -> [f32; 3] {
                let c = e.colour_at(id, lt).unwrap_or(default);
                [c[0] as f32, c[1] as f32, c[2] as f32]
            };
            let mix = (e
                .float_at_with_context("mix", lt, expression_context.clone())
                .unwrap_or(100.0) as f32
                / 100.0)
                .clamp(0.0, 1.0);
            Some(Resolved::Tint {
                black: rgb("black", [0.0, 0.0, 0.0, 1.0]),
                white: rgb("white", [1.0, 1.0, 1.0, 1.0]),
                mix,
            })
        }
        "lut" => {
            // Only Mix is Copy-carried; the `.cube` file's parsed cube is a
            // 3D texture threaded beside the resolved op (the caller's LUT
            // cache), exactly as the flow field is for Motion blur. A `lut`
            // effect always resolves to exactly one Resolved::Lut, so the
            // ordered enabled-builtin-`lut` list stays 1:1 and in order with
            // the Resolved::Lut ops — the whole threading contract.
            let mix = (e
                .float_at_with_context("mix", lt, expression_context.clone())
                .unwrap_or(100.0) as f32
                / 100.0)
                .clamp(0.0, 1.0);
            Some(Resolved::Lut { mix })
        }
        "lens_flare" => {
            // Lens flare (docs/08 §3.27, K-256/K-257). Everything resolves to
            // plain numbers; the bake derives from them GPU-side (cached by
            // lens_flare::bake_key), so nothing travels beside the op except
            // the Matte source's rendered layer (the DoF layer-input shape).
            // Light position is a raster fraction; % keeps it
            // resolution-independent (§2.3).
            // px@comp -> raster pixels through the §2.3 preview factor, the
            // Transform-anchor convention (K-260: point params are pixels).
            let lx = e.float_at("light_x", lt).unwrap_or(640.0) as f32 * px_scale;
            let ly = e.float_at("light_y", lt).unwrap_or(360.0) as f32 * px_scale;
            let intensity = (e.float_at("intensity", lt).unwrap_or(1.0) as f32).max(0.0);
            // Library index (K-261; out-of-range clamps inside lens_entry).
            // A pre-K-264 save's index pointed into the old 1299-lens
            // table; pre-release, it simply lands on a valid curated lens.
            let lens = match e.param("lens_model") {
                Some(EffectValue::Choice(c)) => *c,
                _ => 16,
            };
            let fstop = (e.float_at("fstop", lt).unwrap_or(2.8) as f32).clamp(0.7, 32.0);
            let focus_m = (e.float_at("focus", lt).unwrap_or(100.0) as f32).max(0.2);
            let quality = match e.param("quality") {
                Some(EffectValue::Choice(c)) => (*c).min(3),
                _ => 1,
            };
            let detail = (e.float_at("detail", lt).unwrap_or(1.0) as f32).clamp(0.25, 4.0);
            // Blend menu (K-289). An index past the menu clamps to the last
            // option rather than faulting; a project saved before the menu
            // existed is migrated by `backfill_builtin_params`, so the
            // fallback here is simply the default.
            let blend = match e.param("blend") {
                Some(EffectValue::Choice(c)) => {
                    (*c).min(crate::fx::lens_flare::BLEND_OPTIONS.len() as u32 - 1)
                }
                _ => crate::fx::lens_flare::BLEND_ADD,
            };
            // Source mode (K-257): Lights resolves as Manual until light
            // layers land (the option is prepared, not wired).
            let source = match e.param("source_type") {
                Some(EffectValue::Choice(c)) => (*c).min(2),
                _ => 0,
            };
            let threshold = (e.float_at("threshold", lt).unwrap_or(1.0) as f32).max(0.0);
            let threshold_softness =
                (e.float_at("threshold_softness", lt).unwrap_or(0.25) as f32).max(0.0);
            // Light tint (K-259): scene-linear RGB, clamped at zero below and
            // open above (an HDR tint pushes the flare hotter). Alpha unused.
            let tint = e.colour_at("light_tint", lt).unwrap_or([1.0; 4]);
            let light_tint = [
                (tint[0] as f32).max(0.0),
                (tint[1] as f32).max(0.0),
                (tint[2] as f32).max(0.0),
            ];
            let use_source_colour = e.bool_of("use_source_colour").unwrap_or(true);
            let anamorphic = (e.float_at("anamorphic", lt).unwrap_or(1.0) as f32).clamp(0.5, 3.0);
            // Int-kind params arrive as Float values; the resolve rounds.
            let blades = (e.float_at("blades", lt).unwrap_or(8.0).round() as i64).clamp(3, 16);
            let aperture_rotation = e.float_at("aperture_rotation", lt).unwrap_or(0.0) as f32;
            let roundness = (e.float_at("roundness", lt).unwrap_or(0.15) as f32).clamp(0.0, 1.0);
            let aperture_softness =
                (e.float_at("aperture_softness", lt).unwrap_or(0.05) as f32).clamp(0.0, 1.0);
            let ghost_intensity =
                (e.float_at("ghost_intensity", lt).unwrap_or(1.0) as f32).max(0.0);
            let ghost_softness =
                (e.float_at("ghost_softness", lt).unwrap_or(0.02) as f32).clamp(0.0, 2.0);
            let max_ghosts =
                (e.float_at("max_ghosts", lt).unwrap_or(60.0).round() as i64).clamp(0, 200);
            let dispersion = (e.float_at("dispersion", lt).unwrap_or(1.0) as f32).max(0.0);
            let coating = (e.float_at("coating", lt).unwrap_or(0.75) as f32).clamp(0.0, 1.0);
            let sb_intensity =
                (e.float_at("starburst_intensity", lt).unwrap_or(1.0) as f32).max(0.0);
            let scale = (e.float_at("scale", lt).unwrap_or(1.0) as f32).clamp(0.05, 20.0);
            let mix = (e.float_at("mix", lt).unwrap_or(100.0) as f32 / 100.0).clamp(0.0, 1.0);
            Some(Resolved::LensFlare(
                crate::fx::lens_flare::LensFlareParams {
                    light: [lx, ly],
                    intensity,
                    lens,
                    fstop,
                    focus_m,
                    blades: blades as u32,
                    aperture_rotation_deg: aperture_rotation,
                    roundness,
                    aperture_softness,
                    ghost_intensity,
                    ghost_softness,
                    max_ghosts: max_ghosts as u32,
                    dispersion,
                    coating,
                    starburst_intensity: sb_intensity,
                    scale,
                    source,
                    threshold,
                    threshold_softness,
                    light_tint,
                    use_source_colour,
                    anamorphic,
                    quality,
                    detail,
                    blend,
                    mix,
                },
            ))
        }
        "dof" => {
            // Scalars only; the depth pass (the referenced layer's rendered
            // texture) is threaded beside the op by the caller, exactly as
            // the LUT cube is. A `dof` effect always resolves to exactly one
            // Resolved::Dof, so the ordered enabled-builtin-`dof` list stays
            // 1:1 and in order with the Dof ops — the threading contract.
            let focus = (e
                .float_at_with_context("focus", lt, expression_context.clone())
                .unwrap_or(0.5) as f32)
                .clamp(0.0, 1.0);
            let range = (e
                .float_at_with_context("range", lt, expression_context.clone())
                .unwrap_or(0.1) as f32)
                .clamp(0.0, 1.0);
            // Aperture is the px@comp master; Near/Far are the per-side
            // radii it scales about its default 8 (unity). A pre-feature
            // project has only `aperture` and lacks Near/Far, which then
            // read their default 8, so each side resolves to
            // 8·(aperture/8)·px_scale = aperture·px_scale — identical to the
            // old single-aperture behaviour. px@comp is scaled by the §2.3
            // preview factor so a Half preview blurs the same disc as Full.
            let master = e
                .float_at_with_context("aperture", lt, expression_context.clone())
                .unwrap_or(8.0) as f32
                / 8.0;
            let near = e
                .float_at_with_context("near_aperture", lt, expression_context.clone())
                .unwrap_or(8.0) as f32;
            let far = e
                .float_at_with_context("far_aperture", lt, expression_context.clone())
                .unwrap_or(8.0) as f32;
            // Budget cap (docs/13, docs/14): the disc gather is O(coc²) taps
            // per pixel, and the Aperture master MULTIPLIES the per-side radii
            // (so Aperture 150 × Near 55 becomes a ~1000 px circle of
            // confusion), which submits quadrillions of taps and hangs the
            // GPU — freezing the preview that renders on the UI thread. Cap
            // the effective per-side radius so the cost stays bounded;
            // ordinary apertures (≤ the 40 px slider) sit far below it.
            const MAX_APERTURE_PX: f32 = 128.0;
            let near_aperture = (near * master * px_scale).clamp(0.0, MAX_APERTURE_PX);
            let far_aperture = (far * master * px_scale).clamp(0.0, MAX_APERTURE_PX);
            // Depth invert (a plain Bool; absent on pre-feature projects,
            // where it reads false — the historical, unchanged behaviour).
            let depth_invert = matches!(e.param("depth_invert"), Some(EffectValue::Bool(true)));
            // Diagnostic view (clamped to the shipped modes; absent on
            // pre-feature projects → 0 Rendered, the normal output).
            let display = match e.param("display") {
                Some(EffectValue::Choice(c)) => (*c).min(2),
                _ => 0,
            };
            let mix = (e
                .float_at_with_context("mix", lt, expression_context.clone())
                .unwrap_or(100.0) as f32
                / 100.0)
                .clamp(0.0, 1.0);
            Some(Resolved::Dof {
                focus,
                range,
                near_aperture,
                far_aperture,
                depth_invert,
                display,
                mix,
            })
        }
        "glow" => {
            // Radius is px@comp (K-135), scaled by the §2.3 preview factor so
            // a Half preview blurs the same halo as Full, only softer.
            let radius = e
                .float_at_with_context("radius", lt, expression_context.clone())
                .unwrap_or(24.0) as f32;
            let threshold = (e
                .float_at_with_context("threshold", lt, expression_context.clone())
                .unwrap_or(0.8) as f32)
                .max(0.0);
            let knee = (e
                .float_at_with_context("knee", lt, expression_context.clone())
                .unwrap_or(0.5) as f32)
                .clamp(0.0, 1.0);
            let intensity = (e
                .float_at_with_context("intensity", lt, expression_context.clone())
                .unwrap_or(1.0) as f32)
                .max(0.0);
            let tint = e.colour_at("tint", lt).unwrap_or([1.0; 4]);
            let mix = (e
                .float_at_with_context("mix", lt, expression_context.clone())
                .unwrap_or(100.0) as f32
                / 100.0)
                .clamp(0.0, 1.0);
            Some(Resolved::Glow {
                radius_px: (radius * px_scale).max(0.0),
                threshold,
                knee,
                intensity,
                tint: tint.map(|c| c as f32),
                mix,
            })
        }
        "shake" => {
            let amp_pct = (e
                .float_at_with_context("amplitude", lt, expression_context.clone())
                .unwrap_or(1.5) as f32)
                .max(0.0);
            let freq = e
                .float_at_with_context("frequency", lt, expression_context.clone())
                .unwrap_or(8.0)
                .max(0.0);
            let rot_amount = (e
                .float_at_with_context("rotation", lt, expression_context.clone())
                .unwrap_or(1.0) as f32)
                .max(0.0);
            // Per-axis wobble (twirl group, K-146): amount multipliers scale
            // the master Amplitude, frequency multipliers the master rate.
            // Defaults of 1 reproduce the old uniform x/y shake exactly.
            let x_amp = (e
                .float_at_with_context("x_amp", lt, expression_context.clone())
                .unwrap_or(1.0) as f32)
                .max(0.0);
            let y_amp = (e
                .float_at_with_context("y_amp", lt, expression_context.clone())
                .unwrap_or(1.0) as f32)
                .max(0.0);
            let x_freq = e
                .float_at_with_context("x_freq", lt, expression_context.clone())
                .unwrap_or(1.0)
                .max(0.0);
            let y_freq = e
                .float_at_with_context("y_freq", lt, expression_context.clone())
                .unwrap_or(1.0)
                .max(0.0);
            let z_freq = e
                .float_at_with_context("z_freq", lt, expression_context.clone())
                .unwrap_or(1.0)
                .max(0.0);
            // z (depth/scale) amount: the new id, else the old `zoom_pump`
            // (migration — a project saved before FX-11 keeps its pump), a
            // scale-pump per cent either way.
            let z_pct = e
                .float_at_with_context("z_amp", lt, expression_context.clone())
                .or_else(|| e.float_at_with_context("zoom_pump", lt, expression_context.clone()))
                .unwrap_or(0.0) as f32;
            let z_amp = (z_pct / 100.0).clamp(0.0, 1.0);
            // Edges (P3, K-145): the new `edge` Choice, else migrate the old
            // Auto-scale bool (on → Repeat hides the border as the cover once
            // did; off → Transparent), else the schema default Repeat.
            let edge = match e.param("edge") {
                Some(EffectValue::Choice(c)) => {
                    EdgesMode::from_code((*c).min(2)).unwrap_or(EdgesMode::Repeat)
                }
                _ => match e.param("auto_scale") {
                    Some(EffectValue::Bool(false)) => EdgesMode::Transparent,
                    _ => EdgesMode::Repeat,
                },
            };
            let seed = match e.param("seed") {
                Some(EffectValue::Seed(s)) => *s,
                _ => 0,
            };
            let mix = (e
                .float_at_with_context("mix", lt, expression_context.clone())
                .unwrap_or(100.0) as f32
                / 100.0)
                .clamp(0.0, 1.0);
            // The wobble: independent noise channels sampled at local time ×
            // frequency (per axis, §3.4) — deterministic, hop-free, identical
            // on every machine (§2.4). One sampler drives the frame-time wobble
            // and the motion-blur sub-frames, so they agree bit-for-bit.
            let base = lt * freq;
            let amp_px = (amp_pct / 100.0 * diag_px).max(0.0);
            let wobble = ShakeWobble {
                seed,
                amp_px,
                x_amp,
                y_amp,
                rot_amount,
                z_amp,
                x_freq,
                y_freq,
                z_freq,
            };
            let (offset_px, rotation_deg, zoom) = wobble.at(base);
            // The shake's own motion blur (T18, K-165): when the toggle is on
            // and the amount is non-zero, sample the wobble across the shutter
            // for the dispatch to average; off is the plain single resample
            // (the bit-exact passthrough). The centre offset is 0, so the middle
            // sample equals the frame-time wobble exactly.
            let motion_blur = e.bool_of("motion_blur").unwrap_or(false);
            let mb_amount = e
                .float_at_with_context("mb_amount", lt, expression_context.clone())
                .unwrap_or(0.5);
            let mb = (motion_blur && mb_amount > 0.0).then(|| {
                let mut samples = [ShakeSample::IDENTITY; SHAKE_MB_SAMPLES];
                for (s, db) in samples.iter_mut().zip(shake_mb_offsets(mb_amount)) {
                    let (offset_px, rotation_deg, zoom) = wobble.at(base + db);
                    *s = ShakeSample {
                        offset_px,
                        rotation_deg,
                        zoom,
                    };
                }
                samples
            });
            Some(Resolved::Shake {
                offset_px,
                rotation_deg,
                zoom,
                edge: edge.code(),
                mix,
                mb,
            })
        }
        "block_glitch" => {
            let intensity = (e
                .float_at_with_context("intensity", lt, expression_context.clone())
                .unwrap_or(0.35) as f32)
                .clamp(0.0, 1.0);
            let seed = match e.param("seed") {
                Some(EffectValue::Seed(s)) => *s,
                _ => 0,
            };
            // Local time discretised at the fixed tick rate (§3.12
            // status note): block hashing reads this, never raw time.
            let tick = (lt * GLITCH_TICK_HZ).floor() as i32;
            let block_size_px = (e
                .float_at_with_context("block_size", lt, expression_context.clone())
                .unwrap_or(24.0) as f32
                * px_scale)
                .max(1.0);
            let jitter_frac = (e
                .float_at_with_context("block_jitter", lt, expression_context.clone())
                .unwrap_or(25.0) as f32
                / 100.0)
                .clamp(0.0, 1.0);
            let amount_pct = e
                .float_at_with_context("block_amount", lt, expression_context.clone())
                .unwrap_or(3.0) as f32;
            let chan_pct = e
                .float_at_with_context("channel_offset", lt, expression_context.clone())
                .unwrap_or(1.0) as f32;
            let slice_frac = (e
                .float_at_with_context("slice_repeat", lt, expression_context.clone())
                .unwrap_or(20.0) as f32
                / 100.0)
                .clamp(0.0, 1.0);
            let mix = (e
                .float_at_with_context("mix", lt, expression_context.clone())
                .unwrap_or(100.0) as f32
                / 100.0)
                .clamp(0.0, 1.0);
            Some(Resolved::BlockGlitch {
                intensity,
                seed,
                tick,
                block_size_px,
                jitter_frac,
                amount_px: (amount_pct / 100.0 * diag_px).max(0.0),
                chan_px: (chan_pct / 100.0 * diag_px).max(0.0),
                slice_frac,
                mix,
            })
        }
        "scanlines" => {
            // The single Intensity (FX-13, K-147): 0..1 = how dark the dark
            // lines get. An old project also carried a separate Darkness
            // param (0..100): fold it in, so the loaded look is the old
            // Intensity × Darkness product exactly. A new project has no
            // Darkness param, so the raw Intensity stands.
            let raw = e
                .float_at_with_context("intensity", lt, expression_context.clone())
                .unwrap_or(0.35);
            let folded = match e.float_at_with_context(
                "scanline_darkness",
                lt,
                expression_context.clone(),
            ) {
                Some(darkness_pct) => raw * (darkness_pct / 100.0),
                None => raw,
            };
            let intensity = (folded as f32).clamp(0.0, 1.0);
            let period_px = (e
                .float_at_with_context("scanline_period", lt, expression_context.clone())
                .unwrap_or(3.0) as f32
                * px_scale)
                .max(1.0);
            let roll_speed = e
                .float_at_with_context("scanline_roll", lt, expression_context.clone())
                .unwrap_or(0.0);
            // The scanline pattern's pixel offset at this frame (roll
            // speed × local time × period), so the kernel never sees
            // raw time or does its own time maths (§2.4: the CPU/GPU
            // must agree, and f32 time would round differently near a
            // tick boundary than f64 does — precomputing sidesteps it).
            let roll_px = (roll_speed * lt * f64::from(period_px)) as f32;
            let interlace = match e.param("scanline_interlace") {
                Some(EffectValue::Bool(b)) => *b,
                _ => false,
            };
            let mix = (e
                .float_at_with_context("mix", lt, expression_context.clone())
                .unwrap_or(100.0) as f32
                / 100.0)
                .clamp(0.0, 1.0);
            Some(Resolved::Scanlines {
                intensity,
                period_px,
                roll_px,
                interlace,
                mix,
            })
        }
        "datamosh" => {
            // Intensity ceiling is open (K-135/FX-14): clamp only at zero, so
            // > 1 extrapolates past the moshed frame. Displacement supersedes
            // the K-148 `streak_length` id (read as a fallback so an old
            // project keeps its reach); default 4 frames.
            let intensity = (e
                .float_at_with_context("intensity", lt, expression_context.clone())
                .unwrap_or(0.5) as f32)
                .max(0.0);
            let displacement = e
                .float_at_with_context("displacement", lt, expression_context.clone())
                .or_else(|| {
                    e.float_at_with_context("streak_length", lt, expression_context.clone())
                })
                .unwrap_or(4.0)
                .max(1.0) as f32;
            let bloom = (e
                .float_at_with_context("bloom", lt, expression_context.clone())
                .unwrap_or(0.6) as f32)
                .clamp(0.0, 1.0);
            // Periodic I-frame reset (K-164): the melt ramps from a clean frame
            // just after each reset up to full by the next. A pure function of
            // layer time `lt` (seconds), so the kernel stays time-agnostic and
            // the frame-cache key already covers it (a param+time function, the
            // K-093/K-094 reasoning). 0 = off (a constant melt); the content-
            // driven reset at stills/cuts (zero flow) fires regardless.
            let interval = (e
                .float_at_with_context("reset_interval", lt, expression_context.clone())
                .unwrap_or(0.0))
            .max(0.0);
            let ramp = if interval > 0.0 {
                (lt / interval).rem_euclid(1.0) as f32
            } else {
                1.0
            };
            let eff_intensity = intensity * ramp;
            let eff_displacement = (displacement * ramp).max(0.0);
            // Each step advances ~1 frame of flow, so the tap count tracks the
            // reach; clamped to the 2..64 Motion blur's own streak loops (or 1
            // at a sub-frame reach, where a single tap is exact).
            let steps = if eff_displacement < 1.0 {
                1
            } else {
                (eff_displacement.round() as i32).clamp(2, 64)
            };
            let mix = (e
                .float_at_with_context("mix", lt, expression_context.clone())
                .unwrap_or(100.0) as f32
                / 100.0)
                .clamp(0.0, 1.0);
            Some(Resolved::Datamosh {
                intensity: eff_intensity,
                displacement: eff_displacement,
                bloom,
                steps,
                mix,
            })
        }
        "echo" => {
            // Echoes k = 1..count sit at offset -k with intensity
            // decay^k (v1 fixed one-frame spacing); the render supplies
            // the neighbour frame at each offset. weights[i] is the echo
            // at offset -(i+1). Up to 16 echoes (FX-17/K-149).
            let count = (e
                .float_at_with_context("echoes", lt, expression_context.clone())
                .unwrap_or(4.0)
                .round() as i32)
                .clamp(1, 16);
            let decay = (e
                .float_at_with_context("decay", lt, expression_context.clone())
                .unwrap_or(0.6) as f32)
                .clamp(0.0, 1.0);
            // Combine blend mode; the default when the param is absent matches
            // the schema default (Screen, index 3). Clamped to the 0..=13 range
            // the CPU oracle and WGSL kernel branch over (T21).
            let mode = match e.param("mode") {
                Some(EffectValue::Choice(c)) => (*c).min(13),
                _ => 3,
            };
            let mix = (e
                .float_at_with_context("mix", lt, expression_context.clone())
                .unwrap_or(100.0) as f32
                / 100.0)
                .clamp(0.0, 1.0);
            let mut weights = [0.0f32; 16];
            for (i, w) in weights.iter_mut().enumerate() {
                if (i as i32) < count {
                    *w = decay.powi(i as i32 + 1);
                }
            }
            Some(Resolved::Echo { weights, mode, mix })
        }
        "motion_blur" => {
            // Streak length = motion × (shutter ÷ 360); the flow field
            // (the motion itself) is threaded to the kernel separately.
            // Samples is the spec's integer carried as a Float row —
            // rounded and clamped to the same 2..64 the kernel loops.
            let shutter_frac = (e
                .float_at_with_context("shutter_angle", lt, expression_context.clone())
                .unwrap_or(180.0) as f32
                / 360.0)
                .max(0.0);
            let samples = (e
                .float_at_with_context("samples", lt, expression_context.clone())
                .unwrap_or(16.0)
                .round() as i32)
                .clamp(2, 64);
            let mix = (e
                .float_at_with_context("mix", lt, expression_context.clone())
                .unwrap_or(100.0) as f32
                / 100.0)
                .clamp(0.0, 1.0);
            // View (FX-19): a diagnostic look at the flow or confidence, else the
            // blurred picture. An older project without the row reads Rendered.
            let view = match e.param("view") {
                Some(EffectValue::Choice(1)) => MbView::MotionVectors,
                Some(EffectValue::Choice(2)) => MbView::Confidence,
                _ => MbView::Rendered,
            };
            Some(Resolved::MotionBlur {
                shutter_frac,
                samples,
                mix,
                view,
            })
        }
        "transform" => {
            // px@comp parameters scale by the preview factor (§2.3) so
            // Half preview frames exactly like Full, only softer.
            let px = |id: &str| {
                e.float_at_with_context(id, lt, expression_context.clone())
                    .unwrap_or(0.0) as f32
                    * px_scale
            };
            let pct = |id: &str| {
                e.float_at_with_context(id, lt, expression_context.clone())
                    .unwrap_or(100.0) as f32
                    / 100.0
            };
            let opacity = (e
                .float_at_with_context("opacity", lt, expression_context.clone())
                .unwrap_or(100.0) as f32
                / 100.0)
                .clamp(0.0, 1.0);
            let mix = (e
                .float_at_with_context("mix", lt, expression_context.clone())
                .unwrap_or(100.0) as f32
                / 100.0)
                .clamp(0.0, 1.0);
            Some(Resolved::Transform {
                anchor: [px("anchor_x"), px("anchor_y")],
                position: [px("position_x"), px("position_y")],
                scale: [pct("scale_x"), pct("scale_y")],
                rotation_deg: e
                    .float_at_with_context("rotation", lt, expression_context.clone())
                    .unwrap_or(0.0) as f32,
                opacity,
                mix,
            })
        }
        "lens_dirt" => {
            let intensity = (e.float_at("intensity", lt).unwrap_or(1.0) as f32).max(0.0);
            let density = (e.float_at("density", lt).unwrap_or(100.0) as f32).clamp(0.0, 2000.0);
            let bokeh_layers = (e.float_at("bokeh_layers", lt).unwrap_or(3.0) as u32).clamp(1, 10);

            let scale = (e.float_at("scale", lt).unwrap_or(1.0) as f32).clamp(0.01, 20.0);
            let scale_var_x = (e.float_at("scale_var_x", lt).unwrap_or(0.0) as f32).clamp(0.0, 2.0);
            let scale_var_y = (e.float_at("scale_var_y", lt).unwrap_or(0.0) as f32).clamp(0.0, 2.0);
            let rotation_var = (e.float_at("rotation_var", lt).unwrap_or(0.0) as f32).clamp(0.0, 1.0);
            let scratch_scale = (e.float_at("scratch_scale", lt).unwrap_or(1.0) as f32).clamp(0.01, 20.0);
            let defocus = (e.float_at("defocus", lt).unwrap_or(0.5) as f32).clamp(0.0, 1.0);
            let defocus_var = (e.float_at("defocus_var", lt).unwrap_or(0.0) as f32).clamp(0.0, 1.0);
            let color_var = (e.float_at("color_var", lt).unwrap_or(0.0) as f32).clamp(0.0, 1.0);
            let chromatic = (e.float_at("chromatic", lt).unwrap_or(0.3) as f32).clamp(0.0, 2.0);
            let scratches = (e.float_at("scratches", lt).unwrap_or(0.4) as f32).clamp(0.0, 1.0);
            let scratch_var = (e.float_at("scratch_var", lt).unwrap_or(0.2) as f32).clamp(0.0, 1.0);
            let scratch_tint = match e.colour_at("scratch_tint", lt) {
                Some(c) => [c[0] as f32, c[1] as f32, c[2] as f32, c[3] as f32],
                None => [1.0, 1.0, 1.0, 1.0],
            };
            let dirt = (e.float_at("dirt", lt).unwrap_or(0.3) as f32).clamp(0.0, 1.0);
            let dirt_tint = match e.colour_at("dirt_tint", lt) {
                Some(c) => [c[0] as f32, c[1] as f32, c[2] as f32, c[3] as f32],
                None => [0.9, 0.85, 0.75, 1.0],
            };
            let tint = match e.colour_at("tint", lt) {
                Some(c) => [c[0] as f32, c[1] as f32, c[2] as f32, c[3] as f32],
                None => [1.0, 0.95, 0.85, 1.0],
            };

            let vignette = (e.float_at("vignette", lt).unwrap_or(0.3) as f32).clamp(0.0, 1.0);
            let blend_mode = match e.param("blend_mode") {
                Some(EffectValue::Choice(c)) => (*c).min(3),
                _ => 0,
            };
            let bg_mode = match e.param("bg_mode") {
                Some(EffectValue::Choice(c)) => (*c).min(2),
                _ => 0,
            };
            let bg_colour = match e.colour_at("bg_colour", lt) {
                Some(c) => [c[0] as f32, c[1] as f32, c[2] as f32, c[3] as f32],
                None => [0.05, 0.05, 0.08, 1.0],
            };
            let sun_pos_x = e.float_at("sun_pos_x", lt).unwrap_or(50.0) as f32 / 100.0;
            let sun_pos_y = e.float_at("sun_pos_y", lt).unwrap_or(30.0) as f32 / 100.0;

            let sun_pos = [sun_pos_x, sun_pos_y];
            let sun_intensity = (e.float_at("sun_intensity", lt).unwrap_or(1.0) as f32).max(0.0);

            let sun_radius = (e.float_at("sun_radius", lt).unwrap_or(0.4) as f32).clamp(0.01, 5.0);

            let seed = match e.param("seed") {
                Some(EffectValue::Seed(s)) => *s,
                _ => 0,
            };
            let mix = (e.float_at("mix", lt).unwrap_or(100.0) as f32 / 100.0).clamp(0.0, 1.0);
            Some(Resolved::LensDirt(LensDirtParams {
                intensity,
                density,
                bokeh_layers,
                scale,
                scale_var_x,
                scale_var_y,
                rotation_var,
                scratch_scale,
                defocus,
                defocus_var,
                color_var,
                chromatic,
                scratches,
                scratch_var,
                scratch_tint,
                dirt,
                dirt_tint,
                tint,
                vignette,
                blend_mode,
                bg_mode,
                bg_colour,
                sun_pos,
                sun_intensity,
                sun_radius,
                seed,
                mix,
            }))
        }





        _ => None,
    }
}

