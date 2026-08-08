//! Stylise and geometry kernels (docs/08 §3.5, §3.12, §3.14, §3.21): the matte
//! key, vignette, affine transform, block glitch and scanlines.

use crate::GpuContext;

use super::{upload_linear_f32, work_texture, BlurParams, FxEngine, GlowParams};

/// One resolved matte key (docs/08 §3.21, K-121/K-154): a Keylight-style
/// colour-difference keyer on straight (unpremultiplied) colour. Mirrors
/// `lumit_core::fx::MatteKeyParams` field-for-field so the kernel and the CPU
/// oracle consume the identical numbers (K-031). The kernel derives the screen's
/// primary channel and reference from `key`, exactly as the CPU reference does.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MatteKeyOp {
    /// Output view wire code: 0 Final, 1 Screen matte, 2 Status.
    pub view: u32,
    /// Scene-linear RGBA screen (key) colour; alpha ignored.
    pub key: [f32; 4],
    /// Screen gain (matte fall-off strength), `≥ 0`.
    pub gain: f32,
    /// Screen balance, 0..1 (secondary-channel weighting).
    pub balance: f32,
    /// Despill bias (scene-linear RGBA, alpha ignored).
    pub despill_bias: [f32; 4],
    /// Alpha bias (scene-linear RGBA, alpha ignored).
    pub alpha_bias: [f32; 4],
    /// Despill amount, 0..1.
    pub spill: f32,
    /// Clip black, 0..1.
    pub clip_black: f32,
    /// Clip white, 0..1.
    pub clip_white: f32,
    /// Clip rollback, 0..1.
    pub clip_rollback: f32,
    /// Replace method wire code: 0 Source, 1 Hard, 2 Soft, 3 None.
    pub replace_method: u32,
    /// Scene-linear RGBA replace colour.
    pub replace_colour: [f32; 4],
    /// 0..1, blended against the unprocessed input.
    pub mix: f32,
}

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct MatteKeyParams {
    // Four vec4 colours first (each 16-byte aligned for the WGSL uniform).
    key: [f32; 4],
    despill_bias: [f32; 4],
    alpha_bias: [f32; 4],
    replace_colour: [f32; 4],
    // Then the scalars, packed to a 16-byte multiple with three pad floats.
    gain: f32,
    balance: f32,
    spill: f32,
    clip_black: f32,
    clip_white: f32,
    clip_rollback: f32,
    view: u32,
    replace_method: u32,
    mix_amt: f32,
    _pad0: f32,
    _pad1: f32,
    _pad2: f32,
}

/// One resolved vignette (docs/08 §3.14): darkens toward black away from
/// the frame centre. Radius/Softness/Roundness are already-clamped
/// fractions; the kernel derives the distance metric from its own
/// `textureDimensions`, exactly like the CPU reference derives it from
/// `w`/`h` — no raster conversion happens host-side.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct VignetteOp {
    /// 0..1: darkening strength; 0 is the neutral point.
    pub amount: f32,
    /// 0..1: the clear centre's reach.
    pub radius: f32,
    /// 0..1: feather width beyond radius.
    pub softness: f32,
    /// 0..1: 1 = circular, 0 = follows the frame's aspect.
    pub roundness: f32,
    /// Gamma on the falloff (T16): 1 = plain smoothstep.
    pub ramp: f32,
    /// 0..1, blended against the unprocessed input.
    pub mix: f32,
}

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct VignetteParams {
    amount: f32,
    radius: f32,
    softness: f32,
    roundness: f32,
    ramp: f32,
    mix_amt: f32,
    _pad1: f32,
    _pad2: f32,
}

/// One resolved transform (docs/08 §3.5, K-090): the inverse affine arrives
/// host-computed (`lumit_core::fx::transform_op`) so the kernel never runs
/// its own trigonometry and the CPU reference consumes bit-identical
/// numbers. A degenerate (zero-scale) transform arrives as opacity 0 with
/// an identity matrix — fully transparent, exactly like the reference.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TransformOp {
    /// Row-major inverse linear 2×2: (m00, m01, m10, m11).
    pub m: [f32; 4],
    /// Inverse translation: sample q = m·p + off.
    pub off: [f32; 2],
    /// 0..1, multiplied into premultiplied RGBA.
    pub opacity: f32,
    /// 0..1, blended against the unprocessed input.
    pub mix: f32,
    /// The revealed border's edge policy (P3, K-145): 0 Transparent, 1 Repeat,
    /// 2 Mirror. The Transform effect passes 0; Shake threads its Edges control.
    pub edge: u32,
}

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct TransformParams {
    m: [f32; 4],
    off: [f32; 2],
    opacity: f32,
    mix_amt: f32,
    edge: u32,
    _pad0: f32,
    _pad1: f32,
    _pad2: f32,
}

/// The number of Shake motion-blur sub-frame taps (T18/K-165): the fixed-size
/// end of the uniform array and the WGSL kernel's `array<Tap, 9>` / `MAX_TAPS`.
/// Must equal `lumit_core::fx::SHAKE_MB_SAMPLES` — the GPU crate can't name that
/// const (lumit-core is a dev-dependency only), so the oracle tests assert the
/// two agree, and the WGSL literal is kept in step by the same tests.
pub const SHAKE_MB_SAMPLES: usize = 9;

/// One resolved Shake motion blur (docs/08 §3.4, T18/K-165): the shake's own
/// inter-frame smear. Each tap is a host-computed inverse affine (the same
/// `shake_affine` → `transform_op` construction the plain Shake uses, one per
/// motion-blur sub-frame); the kernel resamples the input through the first
/// `count` taps and averages them in premultiplied linear space. `count` is
/// always ≥ 1 (the host only builds this when motion blur is on). Mirrors
/// `lumit_core::fx::cpu::transform_average`.
#[derive(Debug, Clone, Copy)]
pub struct ShakeMbOp {
    /// Up to [`SHAKE_MB_SAMPLES`] inverse affines `(m, off)`.
    pub taps: [ShakeMbTap; SHAKE_MB_SAMPLES],
    /// Active taps, `1..=SHAKE_MB_SAMPLES`.
    pub count: u32,
    /// The revealed border's edge policy (P3, K-145): 0 Transparent, 1 Repeat,
    /// 2 Mirror.
    pub edge: u32,
    /// 0..1, blended against the unprocessed input.
    pub mix: f32,
}

/// One motion-blur sub-frame's inverse affine `(m, off)` (T18): row-major
/// inverse linear 2×2 and the inverse translation, exactly as [`TransformOp`].
#[derive(Debug, Clone, Copy)]
pub struct ShakeMbTap {
    pub m: [f32; 4],
    pub off: [f32; 2],
}

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct ShakeMbTapUniform {
    m: [f32; 4],
    off: [f32; 4], // .xy used; .zw pad to the uniform's 16-byte stride
}

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct ShakeMbParams {
    taps: [ShakeMbTapUniform; SHAKE_MB_SAMPLES],
    count: u32,
    edge: u32,
    mix_amt: f32,
    _pad: f32,
}

/// One resolved Block glitch (docs/08 §3.12, split out of the old combined
/// Glitch effect by K-107). `tick` arrives already computed from local time
/// (`lumit_core::fx::GLITCH_TICK_HZ`), so the kernel never sees raw time or
/// does its own time maths.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct BlockGlitchOp {
    /// The master 0..1 dial; scales every hashed quantity.
    pub intensity: f32,
    pub seed: u32,
    pub tick: i32,
    /// Raster pixels (px@comp × the §2.3 preview factor).
    pub block_size_px: f32,
    /// 0..1, fraction of block_size_px.
    pub jitter_frac: f32,
    /// Peak per-block displacement, raster pixels.
    pub amount_px: f32,
    /// Peak per-block R/B split, raster pixels.
    pub chan_px: f32,
    /// 0..1: odds (before the Intensity scale) a block slice-repeats.
    pub slice_frac: f32,
    /// 0..1, blended against the unprocessed input.
    pub mix: f32,
}

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct BlockGlitchParams {
    intensity: f32,
    seed: u32,
    tick: i32,
    block_size: f32,
    jitter_frac: f32,
    amount: f32,
    chan: f32,
    slice_frac: f32,
    mix_amt: f32,
    _pad0: f32,
    _pad1: f32,
    _pad2: f32,
}

/// One resolved Scanlines (docs/08 §3.12, split out of the old combined
/// Glitch effect by K-107; single Intensity since FX-13/K-147). `roll_px`
/// arrives already computed from local time (roll speed × time × period), so
/// the kernel never sees raw time.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ScanlinesOp {
    /// The single 0..1 dial: how dark the dark lines get (1 = black).
    pub intensity: f32,
    /// Raster pixels (px@comp × the §2.3 preview factor).
    pub period_px: f32,
    /// The scanline pattern's pixel offset at this frame, host-computed.
    pub roll_px: f32,
    pub interlace: bool,
    /// 0..1, blended against the unprocessed input.
    pub mix: f32,
}

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct ScanlinesParams {
    intensity: f32,
    period: f32,
    roll_px: f32,
    interlace: u32,
    mix_amt: f32,
    _pad0: f32,
    _pad1: f32,
    _pad2: f32,
}

impl FxEngine {
    /// Apply one matte key (docs/08 §3.21, K-121/K-154) to a linear working
    /// texture, returning a new texture of the same size. One pointwise pass; the
    /// §2.2 unpremultiply wrap is fused into the kernel, which derives the screen's
    /// primary channel and reference from `key` exactly as the CPU reference does.
    /// There is no neutral short-circuit (the default keys); Mix 0 is the identity.
    pub fn matte_key(
        &self,
        ctx: &GpuContext,
        src: &wgpu::Texture,
        w: u32,
        h: u32,
        op: &MatteKeyOp,
    ) -> wgpu::Texture {
        let out = work_texture(ctx, w, h, "fx-matte-key-out");
        self.dispatch(
            ctx,
            &self.matte_key,
            src,
            src,
            &out,
            w,
            h,
            bytemuck::bytes_of(&MatteKeyParams {
                key: op.key,
                despill_bias: op.despill_bias,
                alpha_bias: op.alpha_bias,
                replace_colour: op.replace_colour,
                gain: op.gain,
                balance: op.balance,
                spill: op.spill,
                clip_black: op.clip_black,
                clip_white: op.clip_white,
                clip_rollback: op.clip_rollback,
                view: op.view,
                replace_method: op.replace_method,
                mix_amt: op.mix,
                _pad0: 0.0,
                _pad1: 0.0,
                _pad2: 0.0,
            }),
        );
        out
    }

    /// Apply one vignette (docs/08 §3.14) to a linear working texture,
    /// returning a new texture of the same size. One pointwise pass; the
    /// kernel derives the distance metric from its own texture size, and
    /// Amount 0 short-circuits inside it.
    pub fn vignette(
        &self,
        ctx: &GpuContext,
        src: &wgpu::Texture,
        w: u32,
        h: u32,
        op: &VignetteOp,
    ) -> wgpu::Texture {
        let out = work_texture(ctx, w, h, "fx-vignette-out");
        self.dispatch(
            ctx,
            &self.vignette,
            src,
            src,
            &out,
            w,
            h,
            bytemuck::bytes_of(&VignetteParams {
                amount: op.amount,
                radius: op.radius,
                softness: op.softness,
                roundness: op.roundness,
                ramp: op.ramp,
                mix_amt: op.mix,
                _pad1: 0.0,
                _pad2: 0.0,
            }),
        );
        out
    }

    /// Apply one transform (docs/08 §3.5, K-090) to a linear working
    /// texture, returning a new texture of the same size. One pass: each
    /// output pixel takes a single bilinear tap through the host-computed
    /// inverse affine, transparent outside the frame, opacity folded in.
    /// Identity parameters reproduce the input bit-exactly.
    pub fn transform(
        &self,
        ctx: &GpuContext,
        src: &wgpu::Texture,
        w: u32,
        h: u32,
        op: &TransformOp,
    ) -> wgpu::Texture {
        let out = work_texture(ctx, w, h, "fx-transform-out");
        self.dispatch(
            ctx,
            &self.transform,
            src,
            src,
            &out,
            w,
            h,
            bytemuck::bytes_of(&TransformParams {
                m: op.m,
                off: op.off,
                opacity: op.opacity,
                mix_amt: op.mix,
                edge: op.edge,
                _pad0: 0.0,
                _pad1: 0.0,
                _pad2: 0.0,
            }),
        );
        out
    }

    /// Apply one Shake motion blur (docs/08 §3.4, T18/K-165): resample the input
    /// through the op's sub-frame inverse affines and average them, then blend
    /// by mix — the shake's own inter-frame smear, on this effect alone. One
    /// pass with up to [`SHAKE_MB_SAMPLES`] bilinear taps.
    pub fn shake_mb(
        &self,
        ctx: &GpuContext,
        src: &wgpu::Texture,
        w: u32,
        h: u32,
        op: &ShakeMbOp,
    ) -> wgpu::Texture {
        let out = work_texture(ctx, w, h, "fx-shake-mb-out");
        let mut taps = [ShakeMbTapUniform {
            m: [1.0, 0.0, 0.0, 1.0],
            off: [0.0; 4],
        }; SHAKE_MB_SAMPLES];
        for (dst, s) in taps.iter_mut().zip(op.taps.iter()) {
            dst.m = s.m;
            dst.off = [s.off[0], s.off[1], 0.0, 0.0];
        }
        self.dispatch(
            ctx,
            &self.shake_mb,
            src,
            src,
            &out,
            w,
            h,
            bytemuck::bytes_of(&ShakeMbParams {
                taps,
                count: op.count.clamp(1, SHAKE_MB_SAMPLES as u32),
                edge: op.edge,
                mix_amt: op.mix,
                _pad: 0.0,
            }),
        );
        out
    }

    /// Apply one Block glitch (docs/08 §3.12, split out by K-107) to a
    /// linear working texture, returning a new texture of the same size.
    /// One pointwise-with-taps pass: block UV displacement and channel
    /// offset.
    pub fn block_glitch(
        &self,
        ctx: &GpuContext,
        src: &wgpu::Texture,
        w: u32,
        h: u32,
        op: &BlockGlitchOp,
    ) -> wgpu::Texture {
        let out = work_texture(ctx, w, h, "fx-block-glitch-out");
        self.dispatch(
            ctx,
            &self.block_glitch,
            src,
            src,
            &out,
            w,
            h,
            bytemuck::bytes_of(&BlockGlitchParams {
                intensity: op.intensity,
                seed: op.seed,
                tick: op.tick,
                block_size: op.block_size_px,
                jitter_frac: op.jitter_frac,
                amount: op.amount_px,
                chan: op.chan_px,
                slice_frac: op.slice_frac,
                mix_amt: op.mix,
                _pad0: 0.0,
                _pad1: 0.0,
                _pad2: 0.0,
            }),
        );
        out
    }

    /// Apply one Scanlines (docs/08 §3.12, split out by K-107) to a linear
    /// working texture, returning a new texture of the same size. One
    /// pointwise pass: periodic darkening in raster Y, no neighbour taps.
    pub fn scanlines(
        &self,
        ctx: &GpuContext,
        src: &wgpu::Texture,
        w: u32,
        h: u32,
        op: &ScanlinesOp,
    ) -> wgpu::Texture {
        let out = work_texture(ctx, w, h, "fx-scanlines-out");
        self.dispatch(
            ctx,
            &self.scanlines,
            src,
            src,
            &out,
            w,
            h,
            bytemuck::bytes_of(&ScanlinesParams {
                intensity: op.intensity,
                period: op.period_px,
                roll_px: op.roll_px,
                interlace: u32::from(op.interlace),
                mix_amt: op.mix,
                _pad0: 0.0,
                _pad1: 0.0,
                _pad2: 0.0,
            }),
        );
        out
    }

    /// Apply one Lens dirt (docs/08 §3.28, K-314) to a linear working texture,
    /// returning a new texture of the same size.
    ///
    /// **Three passes, because the effect is a modulation and not an overlay.**
    /// Dirt does not emit; it forward-scatters whatever light passes through it,
    /// so the generated field has to be multiplied by the picture's own
    /// highlights or the muck looks painted on. Pass one keeps only the light
    /// above `threshold` (the Glow bright kernel, unchanged — it is the same
    /// question), passes two and three widen it with the shared separable
    /// gaussian at `spread` pixels, Repeat edges so the response holds along
    /// frame borders, and the dirt kernel multiplies by that.
    ///
    /// `plate` is the optional photographed dirt plate rendered at this raster;
    /// when bound it **replaces** the procedural field. With none bound the
    /// caller passes any same-size texture — the kernel never samples it.
    /// Shares [`Self::mb_layout`] with Motion blur: source, highlight pass and
    /// plate are its three sampled inputs. A zero Intensity or a Mix of 0 is a
    /// bit-exact passthrough.
    pub fn lens_dirt(
        &self,
        ctx: &GpuContext,
        src: &wgpu::Texture,
        w: u32,
        h: u32,
        plate: Option<&wgpu::Texture>,
        op: &LensDirtOp,
    ) -> wgpu::Texture {
        use wgpu::util::DeviceExt;
        let out = work_texture(ctx, w, h, "fx-lens-dirt-out");

        // Pass one and two/three: the highlight response. Skipped entirely when
        // nothing is responding — `response` 0 is the uniform generator, and the
        // kernel then never reads the light texture.
        let light = work_texture(ctx, w, h, "fx-lens-dirt-light");
        if op.response > 0.0 {
            let bright = work_texture(ctx, w, h, "fx-lens-dirt-bright");
            let tmp = work_texture(ctx, w, h, "fx-lens-dirt-tmp");
            // The Glow bright pass with a hard knee: the blur that follows is
            // what softens the mask, so a second soft edge here would only make
            // the threshold vague.
            self.dispatch(
                ctx,
                &self.glow_bright,
                src,
                src,
                &bright,
                w,
                h,
                bytemuck::bytes_of(&GlowParams {
                    tint: [1.0, 1.0, 1.0, 1.0],
                    threshold: op.threshold,
                    knee: 0.0,
                    intensity: 1.0,
                    mix_amt: 1.0,
                }),
            );
            let sigma = (op.spread * 0.5).max(1e-3);
            for (pass_src, pass_dst, dir) in
                [(&bright, &tmp, [1.0, 0.0]), (&tmp, &light, [0.0, 1.0])]
            {
                self.dispatch(
                    ctx,
                    &self.blur,
                    pass_src,
                    pass_src,
                    pass_dst,
                    w,
                    h,
                    bytemuck::bytes_of(&BlurParams {
                        dir,
                        radius: op.spread,
                        sigma,
                        edge: 1, // Repeat: the response holds along the borders
                        mix_amt: 1.0,
                        _pad: [0.0; 2],
                    }),
                );
            }
        }

        // The easter egg substitutes its own plate (K-314) and is a photograph
        // rather than a density map, so the kernel takes its colour whole.
        let egg_tex;
        let plate_tex = if op.seed == EASTER_EGG_SEED {
            let (bytes, ew, eh) = decode_qoi_1337();
            // The plate is 8-bit sRGB; the working format is linear, so it is
            // linearised here rather than bound raw — a photograph bound as if
            // it were already linear reads far too dark.
            let linear: Vec<f32> = bytes
                .iter()
                .enumerate()
                .map(|(i, b)| {
                    let v = f32::from(*b) / 255.0;
                    if i % 4 == 3 {
                        v // alpha is not gamma-encoded
                    } else if v <= 0.04045 {
                        v / 12.92
                    } else {
                        ((v + 0.055) / 1.055).powf(2.4)
                    }
                })
                .collect();
            egg_tex = upload_linear_f32(ctx, &linear, ew as u32, eh as u32);
            &egg_tex
        } else {
            plate.unwrap_or(src)
        };

        let ubuf = ctx
            .device
            .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("fx-lens-dirt-params"),
                contents: bytemuck::bytes_of(&LensDirtParams {
                    tint: op.tint,
                    intensity: op.intensity,
                    response: op.response,
                    density: op.density,
                    scale: op.scale,
                    roughness: op.roughness,
                    defocus: op.defocus,
                    smudge: op.smudge,
                    specks: op.specks,
                    scratches: op.scratches,
                    scratch_scale: op.scratch_scale,
                    scratch_var: op.scratch_var,
                    colour_var: op.colour_var,
                    chromatic: op.chromatic,
                    vignette: op.vignette,
                    mix_amt: op.mix,
                    blend_mode: op.blend_mode,
                    background: op.background,
                    plate_bound: u32::from(plate.is_some()),
                    plate_channel: op.plate_channel,
                    seed: op.seed,
                    easter_egg: u32::from(op.seed == EASTER_EGG_SEED),
                    _pad0: 0,
                    _pad1: 0,
                    _pad2: 0,
                }),
                usage: wgpu::BufferUsages::UNIFORM,
            });
        let view = |t: &wgpu::Texture| t.create_view(&Default::default());
        let bind = ctx.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("fx-lens-dirt-bind"),
            layout: &self.mb_layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::TextureView(&view(src)),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::TextureView(&view(&light)),
                },
                wgpu::BindGroupEntry {
                    binding: 2,
                    resource: wgpu::BindingResource::TextureView(&view(plate_tex)),
                },
                wgpu::BindGroupEntry {
                    binding: 3,
                    resource: wgpu::BindingResource::TextureView(&view(&out)),
                },
                wgpu::BindGroupEntry {
                    binding: 4,
                    resource: ubuf.as_entire_binding(),
                },
            ],
        });
        let mut enc = ctx.encoder("fx-lens-dirt-enc");
        {
            let mut cpass = enc.begin_compute_pass(&wgpu::ComputePassDescriptor {
                label: Some("fx-lens-dirt-pass"),
                timestamp_writes: None,
            });
            cpass.set_pipeline(&self.lens_dirt);
            cpass.set_bind_group(0, &bind, &[]);
            cpass.dispatch_workgroups(w.div_ceil(8), h.div_ceil(8), 1);
        }
        drop(enc);
        out
    }
}

/// The seed that draws the plate instead of generating one (docs/08 §3.28).
///
/// A **deliberate easter egg**, not an accident: the owner asked for it, the
/// image is the Wikimedia Commons lens-dirt plate the effect is modelled on, and
/// the whole joke is that you would not notice unless you knew to look. Every
/// dirt-generation control is ignored at this seed — there is nothing to
/// generate — while Tint, Blend mode, Background, Intensity and Mix go on
/// working, because those are about how a picture is *composited* rather than
/// about what the dirt is.
pub const EASTER_EGG_SEED: u32 = 1337;

/// One resolved Lens dirt (docs/08 §3.28). Field for field this is
/// `lumit_core::fx::LensDirtParams`, which is what lets the §1.6 oracle set both
/// paths up from one value.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LensDirtOp {
    pub intensity: f32,
    /// 0..1: how much the dirt answers to the picture's own light. 0 is the
    /// uniform generator, 1 the physical reading.
    pub response: f32,
    /// The highlight hinge, and how far a highlight's light spreads across the
    /// glass (raster px).
    pub threshold: f32,
    pub spread: f32,
    /// Which channel of a bound plate is read as dirt.
    pub plate_channel: u32,
    pub density: f32,
    pub scale: f32,
    pub roughness: f32,
    pub defocus: f32,
    pub smudge: f32,
    pub specks: f32,
    pub scratches: f32,
    pub scratch_scale: f32,
    pub scratch_var: f32,
    pub tint: [f32; 4],
    pub colour_var: f32,
    pub chromatic: f32,
    pub vignette: f32,
    /// 0 Screen, 1 Add.
    pub blend_mode: u32,
    /// 0 Transparent, 1 Black.
    pub background: u32,
    pub seed: u32,
    pub mix: f32,
}

impl Default for LensDirtOp {
    fn default() -> Self {
        Self {
            intensity: 1.0,
            response: 1.0,
            threshold: 1.0,
            spread: 60.0,
            plate_channel: 4,
            density: 100.0,
            scale: 1.0,
            roughness: 0.7,
            defocus: 0.5,
            smudge: 0.4,
            specks: 0.3,
            scratches: 0.4,
            scratch_scale: 1.0,
            scratch_var: 0.2,
            tint: [1.0, 0.97, 0.92, 1.0],
            colour_var: 0.15,
            chromatic: 0.3,
            vignette: 0.3,
            blend_mode: 0,
            background: 0,
            seed: 42,
            mix: 1.0,
        }
    }
}

#[cfg(test)]
impl From<&LensDirtOp> for lumit_core::fx::LensDirtParams {
    fn from(op: &LensDirtOp) -> Self {
        Self {
            intensity: op.intensity,
            response: op.response,
            threshold: op.threshold,
            spread: op.spread,
            plate_bound: false,
            plate_channel: op.plate_channel,
            density: op.density,
            scale: op.scale,
            roughness: op.roughness,
            defocus: op.defocus,
            smudge: op.smudge,
            specks: op.specks,
            scratches: op.scratches,
            scratch_scale: op.scratch_scale,
            scratch_var: op.scratch_var,
            tint: op.tint,
            colour_var: op.colour_var,
            chromatic: op.chromatic,
            vignette: op.vignette,
            blend_mode: op.blend_mode,
            background: op.background,
            seed: op.seed,
            mix: op.mix,
        }
    }
}

/// The `lens_dirt` kernel's uniform. Layout mirrors `fx_lens_dirt.wgsl`'s
/// `Params` field for field: one vec4 then fifteen floats and seven `u32`s,
/// padded to a whole number of 16-byte rows.
#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct LensDirtParams {
    tint: [f32; 4],
    intensity: f32,
    response: f32,
    density: f32,
    scale: f32,
    roughness: f32,
    defocus: f32,
    smudge: f32,
    specks: f32,
    scratches: f32,
    scratch_scale: f32,
    scratch_var: f32,
    colour_var: f32,
    chromatic: f32,
    vignette: f32,
    mix_amt: f32,
    blend_mode: u32,
    background: u32,
    plate_bound: u32,
    plate_channel: u32,
    seed: u32,
    easter_egg: u32,
    // Twenty-seven words is not a whole number of 16-byte rows, and WGSL rounds
    // a struct's SIZE up to its alignment while `repr(C)` does not — so without
    // this the uniform buffer is 108 bytes where the shader expects 112 and the
    // dispatch is rejected outright.
    _pad0: u32,
    _pad1: u32,
    _pad2: u32,
}

/// The embedded plate, decoded (docs/08 §3.28).
///
/// **Provenance:** a Wikimedia Commons lens-dirt photograph, free to use, stored
/// as QOI — a thirty-line lossless format that needs no dependency and keeps the
/// asset at about 120 KB rather than 1.2 MB. See `assets/README.md` for the
/// source and licence.
fn decode_qoi_1337() -> (Vec<u8>, usize, usize) {
    let bytes = include_bytes!("../../../../assets/easter_egg_1337.qoi");
    let w = u32::from_be_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]) as usize;
    let h = u32::from_be_bytes([bytes[8], bytes[9], bytes[10], bytes[11]]) as usize;
    let mut out = Vec::with_capacity(w * h * 4);
    let mut index = [(0u8, 0u8, 0u8, 0u8); 64];
    let mut prev = (0u8, 0u8, 0u8, 255u8);
    let mut p = 14;
    while p < bytes.len() - 8 {
        let b1 = bytes[p];
        p += 1;
        if b1 == 0xfe {
            prev = (bytes[p], bytes[p + 1], bytes[p + 2], prev.3);
            p += 3;
        } else if b1 == 0xff {
            prev = (bytes[p], bytes[p + 1], bytes[p + 2], bytes[p + 3]);
            p += 4;
        } else if (b1 & 0xc0) == 0x00 {
            prev = index[(b1 & 0x3f) as usize];
        } else if (b1 & 0xc0) == 0x40 {
            let dr = ((b1 >> 4) & 0x03).wrapping_sub(2);
            let dg = ((b1 >> 2) & 0x03).wrapping_sub(2);
            let db = (b1 & 0x03).wrapping_sub(2);
            prev.0 = prev.0.wrapping_add(dr);
            prev.1 = prev.1.wrapping_add(dg);
            prev.2 = prev.2.wrapping_add(db);
        } else if (b1 & 0xc0) == 0x80 {
            let b2 = bytes[p];
            p += 1;
            let dg = (b1 & 0x3f).wrapping_sub(32);
            let dr = ((b2 >> 4) & 0x0f).wrapping_sub(8).wrapping_add(dg);
            let db = (b2 & 0x0f).wrapping_sub(8).wrapping_add(dg);
            prev.0 = prev.0.wrapping_add(dr);
            prev.1 = prev.1.wrapping_add(dg);
            prev.2 = prev.2.wrapping_add(db);
        } else if (b1 & 0xc0) == 0xc0 {
            let run = (b1 & 0x3f) + 1;
            for _ in 0..run {
                out.extend_from_slice(&[prev.0, prev.1, prev.2, prev.3]);
            }
            continue;
        }
        let h_idx = (prev.0 as usize * 3
            + prev.1 as usize * 5
            + prev.2 as usize * 7
            + prev.3 as usize * 11)
            % 64;
        index[h_idx] = prev;
        out.extend_from_slice(&[prev.0, prev.1, prev.2, prev.3]);
    }
    (out, w, h)
}
