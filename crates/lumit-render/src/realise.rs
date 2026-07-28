//! Turning a draw list into pixels on the graphics card.
//!
//! # In plain terms
//!
//! [`crate::draw`] describes a frame; this module *makes* it. [`Realiser`]
//! borrows the GPU primitives from whoever owns them — the egui Viewer, the
//! headless renderer the Flutter frontend drives, or the exporter — and walks a
//! draw list: upload each layer's pixels, convert them to the linear working
//! space, run its effect stack, apply its matte and masks, place it with its
//! transform, and blend it onto the accumulating frame. Nested comps recurse;
//! adjustment layers split the walk in two so the stack below can be
//! composited, processed, and blended back by coverage.
//!
//! Because every caller drives this one walk, a comp looks the same in the
//! viewport, in Flutter, and in the exported file (K-031).

use crate::draw::{AccumulationBelow, CompLayerDraw, DofInputDraw, DrawSource};
use crate::fxops::LoadedLut;

/// The GPU primitives that turn a comp draw list into a linear texture,
/// borrowed from whichever owner is compositing — a frontend's viewer, the
/// headless renderer, or the export renderer. Factoring the realise logic behind
/// one borrowed handle is what lets preview and export share a single re-render
/// path (`render_below_at`, docs/impl/temporal-rerender.md): all of them drive
/// the identical compositor, so a comp realises the same in the viewport and
/// the file (K-031).
pub struct Realiser<'a> {
    /// Owned handle (a cheap Arc-backed clone via [`lumit_gpu::GpuContext::
    /// from_parts`]) so the realise code can keep passing `&self.ctx`; the
    /// engines below cannot be cloned, so they stay borrowed.
    pub ctx: lumit_gpu::GpuContext,
    pub engine: &'a lumit_gpu::ColourEngine,
    pub compositor: &'a lumit_gpu::Compositor,
    pub fx: &'a lumit_gpu::fx::FxEngine,
    pub lut_cache: &'a std::cell::RefCell<std::collections::HashMap<String, LoadedLut>>,
    /// The preview render scale (the K-185 follow-up): every composite this
    /// walk performs allocates its target at [`lumit_gpu::scaled_size`] of the
    /// comp dims while all geometry stays in logical comp pixels. A field
    /// rather than a parameter so the nested/below/adjustment recursions
    /// inherit it with no signature ripple. Export always builds with 1.0, so
    /// the K-031 preview == export identity is untouched at full scale.
    pub render_scale: f32,
}

impl Realiser<'_> {
    /// Turn a layer's ordered `lut_files` into the parallel `luts` list
    /// `run_ops` binds (docs/08 §3.11): each `Some(path)` is parsed and
    /// uploaded once (cached by path), a 1D or unreadable/absent file yields a
    /// `None` slot (a labelled no-op, never a fault — docs/impl/lut.md §8). The
    /// output is 1:1 and in order with `files`, so the k-th slot lines up with
    /// the k-th `Resolved::Lut` op.
    fn load_luts(&self, files: &[Option<String>]) -> Vec<Option<LoadedLut>> {
        let mut cache = self.lut_cache.borrow_mut();
        files
            .iter()
            .map(|slot| {
                let path = slot.as_ref()?;
                if !cache.contains_key(path) {
                    // Any IO/parse error, or a 1D LUT, leaves the slot empty:
                    // the effect is a passthrough, never a panic (§3.11).
                    if let Some(loaded) = std::fs::read_to_string(path)
                        .ok()
                        .and_then(|text| lumit_core::lut::parse_cube(&text).ok())
                        .and_then(|lut| match lut {
                            lumit_core::lut::Lut::Cube3d(l) => Some(LoadedLut {
                                texture: lumit_gpu::fx::upload_lut_3d(
                                    &self.ctx,
                                    l.size as u32,
                                    &l.data,
                                ),
                                size: l.size as u32,
                            }),
                            lumit_core::lut::Lut::Cube1d(_) => None,
                        })
                    {
                        cache.insert(path.clone(), loaded);
                    }
                }
                cache.get(path).cloned()
            })
            .collect()
    }

    /// Render a layer's depth-of-field depth inputs (docs/impl/layer-input.md
    /// §2): each `DofInputDraw` (the referenced layer's source pixels) is
    /// uploaded, linearised and resampled into the effect's working raster
    /// `(w, h)` through the shared [`crate::fxops::render_layer_input`], so the
    /// parallel `layer_inputs` handed to `run_ops` is 1:1 with the stack's
    /// `Dof` ops and aligned with the layer texture the kernel blurs. Export
    /// renders these identically (K-031).
    fn render_dof_inputs(
        &self,
        inputs: &[Option<DofInputDraw>],
        w: u32,
        h: u32,
    ) -> Vec<Option<wgpu::Texture>> {
        inputs
            .iter()
            .map(|slot| {
                let d = slot.as_ref()?;
                let src = self
                    .engine
                    .upload_srgb8(&self.ctx, &d.rgba, d.tex_w, d.tex_h);
                let linear = self.engine.linearise(&self.ctx, &src);
                // Effects-and-masks depth (K-142): run the depth layer's own
                // stack on its texture before it is resampled, when the consumer's
                // depth source is Effects and masks (`d.fx` non-empty). Temporal
                // inputs stay empty in v1 (same boundary as the matte). Export
                // does the same, so the two depth passes match (K-031).
                let linear = if d.fx.is_empty() {
                    linear
                } else {
                    let luts = self.load_luts(&d.lut_files);
                    crate::fxops::run_ops(
                        self.fx,
                        &self.ctx,
                        linear,
                        d.tex_w,
                        d.tex_h,
                        &d.fx,
                        &[],
                        None,
                        &luts,
                        &[],
                    )
                };
                Some(crate::fxops::render_layer_input(
                    self.compositor,
                    &self.ctx,
                    w,
                    h,
                    &linear,
                    d.tex_w as f32,
                    d.tex_h as f32,
                ))
            })
            .collect()
    }

    /// Realise a draw list into a linear comp texture (recursive for
    /// Nested), staging at each Adjust draw (docs/06 §1.5): everything
    /// before it composites into an intermediate, the adjustment's stack
    /// runs on that, and the two blend by coverage; the draws after
    /// composite straight onto the blended result (seeded, no resample).
    pub fn realise(
        &self,
        camera: Option<lumit_core::model::CameraPose>,
        width: u32,
        height: u32,
        background: [f64; 4],
        layers: &[CompLayerDraw],
    ) -> wgpu::Texture {
        // The actual raster this comp's composites land on; all geometry
        // below stays in the logical `width`×`height` comp pixels.
        let (tw, th) = lumit_gpu::scaled_size(width, height, self.render_scale);
        let mut acc: Option<wgpu::Texture> = None;
        let mut start = 0usize;
        for (i, l) in layers.iter().enumerate() {
            if !matches!(l.source, DrawSource::Adjust) {
                continue;
            }
            let below =
                self.realise_segment(camera, width, height, background, &layers[start..i], &acc);
            // An adjustment layer processes the composite below, which has no
            // footage neighbour frames — temporal effects on an adjustment
            // layer are a later refinement, so no neighbours here. Its LUT and
            // depth-of-field effects still apply (§3.11, §3.22): load/render
            // them the same way the per-layer path does, so preview stays
            // identical to export (K-031). The adjustment stack runs on the
            // comp-sized composite, so its depth inputs resample to comp size.
            let luts = self.load_luts(&l.lut_files);
            let layer_inputs = self.render_dof_inputs(&l.dof_inputs, tw, th);
            // Posterize Time everything-below (docs/08 §3.25): the input this
            // adjustment's own effects run on is the below-stack held at the
            // posterised time, not the plain below-composite. The held draws and
            // camera were built by the shared `below_draws_at` (identical to the
            // texture export's `render_below_at` produces, K-031); the coverage
            // blend below still lays the result over the live below-at-t, so a
            // mask reveals the held region. None on an ordinary adjustment.
            // Accumulation motion blur (docs/08 §3.26) takes precedence: it
            // renders N sub-frame below-stacks and averages them; else Posterize
            // holds one below-stack; else the plain below-composite.
            let fx_input = if let Some(ab) = &l.accumulation_below {
                self.accumulate_below(width, height, background, ab, &below)
            } else if let Some(tb) = &l.temporal_below {
                self.realise(tb.camera, width, height, background, &tb.draws)
            } else {
                below.clone()
            };
            // The adjustment's own stack, coverage and blend all run on the
            // ACTUAL raster: `adjust_blend` reads its three inputs texel by
            // texel, so they must agree on their size.
            let processed = crate::fxops::run_ops(
                self.fx,
                &self.ctx,
                fx_input,
                tw,
                th,
                &l.fx,
                &[],
                None,
                &luts,
                &layer_inputs,
            );
            let coverage = self.coverage_texture(camera, width, height, l);
            acc = Some(self.fx.adjust_blend(
                &self.ctx,
                &below,
                &processed,
                &coverage,
                tw,
                th,
                (l.opacity / 100.0).clamp(0.0, 1.0),
            ));
            start = i + 1;
        }
        self.realise_segment(camera, width, height, background, &layers[start..], &acc)
    }

    /// Accumulation motion blur (docs/08 §3.26, docs/impl/temporal-rerender.md
    /// §3): render each sub-frame below-stack through the same realise path,
    /// average the N finished composites with the hardware additive-at-`1/N` pass
    /// ([`lumit_gpu::Compositor::accumulate`]), then blend that average against
    /// the frame-time below-composite `below` by `mix` (a linear interpolation
    /// the additive blend gives exactly). The result stands in for the
    /// below-composite the adjustment's own effects and coverage blend see. A
    /// still scene averages back to `below` bit-for-bit (the K-031 identity); a
    /// moving one smears. Export runs the identical combine, so the two agree.
    fn accumulate_below(
        &self,
        width: u32,
        height: u32,
        background: [f64; 4],
        ab: &AccumulationBelow,
        below: &wgpu::Texture,
    ) -> wgpu::Texture {
        let frames: Vec<wgpu::Texture> = ab
            .samples
            .iter()
            .map(|(draws, camera)| self.realise(*camera, width, height, background, draws))
            .collect();
        if frames.is_empty() {
            // No samples (N < 2) degrades to the plain below — never a panic.
            return below.clone();
        }
        // The sub-frames and `below` are all at the ACTUAL raster size; the
        // combine is a full-frame identity pass, so it runs at that size too.
        let (tw, th) = lumit_gpu::scaled_size(width, height, self.render_scale);
        // Equal weights 1/N sum to 1: the premultiplied arithmetic mean.
        let weight = 1.0 / frames.len() as f32;
        let avg_layers: Vec<(&wgpu::Texture, f32)> = frames.iter().map(|f| (f, weight)).collect();
        let average = self.compositor.accumulate(&self.ctx, tw, th, &avg_layers);
        if ab.mix >= 1.0 {
            average
        } else {
            // Mix blends the blurred average against the live below-composite.
            self.compositor.accumulate(
                &self.ctx,
                tw,
                th,
                &[(below, 1.0 - ab.mix), (&average, ab.mix)],
            )
        }
    }

    /// The adjustment layer's comp-space coverage (docs/06 §1.5): its mask
    /// raster — white where the effects apply — placed by its transform,
    /// so the transform moves the coverage map, never the picture. No
    /// masks means full coverage (a white quad over the whole comp).
    fn coverage_texture(
        &self,
        camera: Option<lumit_core::model::CameraPose>,
        width: u32,
        height: u32,
        l: &CompLayerDraw,
    ) -> wgpu::Texture {
        let white = [255u8, 255, 255, 255];
        let (rgba, w, h): (&[u8], u32, u32) = match &l.mask_cov {
            Some((rgba, w, h)) => (rgba, *w, *h),
            None => (&white, 1, 1),
        };
        let src = self.engine.upload_srgb8(&self.ctx, rgba, w, h);
        let linear = self.engine.linearise(&self.ctx, &src);
        let cam_mat = camera.map(|pose| crate::export::camera_mat(width, height, pose));
        // Rendered at the render scale: `adjust_blend` reads coverage texel by
        // texel against the below/processed rasters, so they must match.
        self.compositor.composite_seeded(
            &self.ctx,
            width,
            height,
            [0.0, 0.0, 0.0, 0.0],
            &[lumit_gpu::CompositeLayer {
                texture: &linear,
                size: l.natural_size,
                position: l.position,
                anchor: l.anchor,
                scale: l.scale,
                rotation_deg: l.rotation_deg,
                // Layer opacity is applied once, in the blend itself.
                opacity: 100.0,
                matte: None,
                blend: lumit_gpu::Blend::Normal,
                z: l.z,
                rotation_x_deg: l.rotation_x_deg,
                rotation_y_deg: l.rotation_y_deg,
                three_d: l.three_d,
                layer_mask: None,
                pre: None,
            }],
            cam_mat,
            None,
            self.render_scale,
        )
    }

    /// Composite one adjustment-free run of draws; `seed` (a previous
    /// stage's output) replaces the cleared background when present.
    fn realise_segment(
        &self,
        camera: Option<lumit_core::model::CameraPose>,
        width: u32,
        height: u32,
        background: [f64; 4],
        layers: &[CompLayerDraw],
        seed: &Option<wgpu::Texture>,
    ) -> wgpu::Texture {
        let mut linear_textures: Vec<wgpu::Texture> = Vec::with_capacity(layers.len());
        for l in layers {
            let tex = match &l.source {
                DrawSource::Pixels { rgba, tex_w, tex_h } => {
                    let src = self.engine.upload_srgb8(&self.ctx, rgba, *tex_w, *tex_h);
                    self.engine.linearise(&self.ctx, &src)
                }
                DrawSource::Nested {
                    width,
                    height,
                    background,
                    draws,
                    camera,
                } => self.realise(*camera, *width, *height, *background, draws),
                DrawSource::Adjust => {
                    // realise splits segments at every Adjust draw, so none
                    // reaches here; a transparent texel keeps the no-panic
                    // rule (and draws nothing) if that ever regresses.
                    let src = self.engine.upload_srgb8(&self.ctx, &[0, 0, 0, 0], 1, 1);
                    self.engine.linearise(&self.ctx, &src)
                }
            };
            // The effect stack runs on the linear source, after masks and
            // before the transform (docs/08 §1.5; docs/06 render order).
            let tex = if l.fx.is_empty() {
                tex
            } else {
                let (w, h) = (tex.width(), tex.height());
                // Neighbour source frames a temporal effect (echo) reads;
                // empty for a plain stack, so this uploads nothing then.
                let neighbours: Vec<(i32, wgpu::Texture)> = l
                    .neighbours
                    .iter()
                    .map(|(offset, rgba, nw, nh)| {
                        let src = self.engine.upload_srgb8(&self.ctx, rgba, *nw, *nh);
                        (*offset, self.engine.linearise(&self.ctx, &src))
                    })
                    .collect();
                // The dense motion field for Fast motion blur, uploaded as its
                // own texture (only when it matches the layer's raster). The
                // confidence rides in the .z channel (FX-19).
                let flow = l.flow_field.as_ref().and_then(|(u, v, conf, fw, fh)| {
                    (*fw == w && *fh == h)
                        .then(|| lumit_gpu::fx::upload_flow_field(&self.ctx, u, v, conf, w, h))
                });
                // The parsed-and-uploaded `.cube` LUTs, 1:1 with the stack's
                // `Resolved::Lut` ops (§3.11); the same load export uses (K-031).
                let luts = self.load_luts(&l.lut_files);
                // The depth-of-field depth inputs, resampled to this layer's
                // working raster (w, h), 1:1 with the stack's Resolved::Dof ops
                // (§3.22); the same render export runs (K-031).
                let layer_inputs = self.render_dof_inputs(&l.dof_inputs, w, h);
                crate::fxops::run_ops(
                    self.fx,
                    &self.ctx,
                    tex,
                    w,
                    h,
                    &l.fx,
                    &neighbours,
                    flow.as_ref(),
                    &luts,
                    &layer_inputs,
                )
            };
            linear_textures.push(tex);
        }
        let cam_mat = camera.map(|pose| crate::export::camera_mat(width, height, pose));
        // Per-layer motion blur (docs/06 §4, K-120): a blurring layer's
        // fx-processed texture is drawn at each sub-frame placement and
        // averaged into one comp-sized smear by the shared helper both preview
        // and export call (K-031). The layer's real blend/opacity/matte/mask
        // then apply once to the averaged image, at the 1:1 composite below.
        let mb_textures: Vec<Option<wgpu::Texture>> = linear_textures
            .iter()
            .zip(layers)
            .map(|(tex, l)| {
                (!l.mb.is_empty()).then(|| {
                    self.compositor.motion_blur_average(
                        &self.ctx,
                        width,
                        height,
                        tex,
                        l.natural_size,
                        &l.mb,
                        l.three_d,
                        l.pre,
                        cam_mat,
                        self.render_scale,
                    )
                })
            })
            .collect();
        // Layer-space mask textures (Precomp masks — GPU mask pass).
        let mask_textures: Vec<Option<wgpu::Texture>> = layers
            .iter()
            .map(|l| {
                l.mask_cov
                    .as_ref()
                    .map(|(rgba, w, h)| self.engine.upload_srgb8(&self.ctx, rgba, *w, *h))
            })
            .collect();
        // Matte layers render alone into comp space (one texture per consumer;
        // the shared-matte cache optimisation arrives with the evaluator).
        // Deliberately at FULL comp resolution whatever the render scale: the
        // fragment samples the matte by normalised comp UV, so any size is
        // correct — shrink it later if it ever shows in a profile.
        let matte_textures: Vec<Option<wgpu::Texture>> = layers
            .iter()
            .map(|l| {
                l.matte.as_ref().map(|m| {
                    let src = self
                        .engine
                        .upload_srgb8(&self.ctx, &m.rgba, m.tex_w, m.tex_h);
                    let linear = self.engine.linearise(&self.ctx, &src);
                    // After-effects matte (K-decision): run the matte source's own
                    // stack on its texture before it gates the consumer, so a keyed
                    // or blurred matte works. Temporal inputs stay empty in v1 — the
                    // matte source's echo/flow degrades to a still (documented). The
                    // same run export performs, so the two agree (K-031).
                    let linear = if m.fx.is_empty() {
                        linear
                    } else {
                        let luts = self.load_luts(&m.lut_files);
                        crate::fxops::run_ops(
                            self.fx,
                            &self.ctx,
                            linear,
                            m.tex_w,
                            m.tex_h,
                            &m.fx,
                            &[],
                            None,
                            &luts,
                            &[],
                        )
                    };
                    self.compositor.composite_with_camera(
                        &self.ctx,
                        width,
                        height,
                        [0.0, 0.0, 0.0, 0.0],
                        &[lumit_gpu::CompositeLayer {
                            texture: &linear,
                            size: m.natural_size,
                            position: m.position,
                            anchor: m.anchor,
                            scale: m.scale,
                            rotation_deg: m.rotation_deg,
                            opacity: m.opacity,
                            matte: None,
                            blend: lumit_gpu::Blend::Normal,
                            z: m.z,
                            rotation_x_deg: m.rotation_x_deg,
                            rotation_y_deg: m.rotation_y_deg,
                            three_d: m.three_d,
                            layer_mask: None,
                            pre: None,
                        }],
                        cam_mat,
                    )
                })
            })
            .collect();
        let comp_layers: Vec<lumit_gpu::CompositeLayer> = linear_textures
            .iter()
            .zip(layers)
            .zip(&matte_textures)
            .zip(&mask_textures)
            .zip(&mb_textures)
            .map(|((((texture, l), matte_tex), mask_tex), mb_tex)| {
                let matte = matte_tex.as_ref().map(|mt| lumit_gpu::MatteInput {
                    texture: mt,
                    luma: l.matte.as_ref().is_some_and(|m| m.luma),
                    inverted: l.matte.as_ref().is_some_and(|m| m.inverted),
                });
                match mb_tex {
                    // Motion-blurred: composite the averaged comp-sized smear
                    // 1:1 (identity placement), the layer's real blend, opacity,
                    // matte and mask applied once to the averaged image.
                    Some(avg) => lumit_gpu::CompositeLayer {
                        texture: avg,
                        size: (width as f32, height as f32),
                        position: (0.0, 0.0),
                        anchor: (0.0, 0.0),
                        scale: (100.0, 100.0),
                        rotation_deg: 0.0,
                        opacity: l.opacity,
                        z: 0.0,
                        rotation_x_deg: 0.0,
                        rotation_y_deg: 0.0,
                        three_d: false,
                        matte,
                        blend: l.blend,
                        layer_mask: mask_tex.as_ref(),
                        pre: None,
                    },
                    None => lumit_gpu::CompositeLayer {
                        texture,
                        size: l.natural_size,
                        position: l.position,
                        anchor: l.anchor,
                        scale: l.scale,
                        rotation_deg: l.rotation_deg,
                        opacity: l.opacity,
                        z: l.z,
                        rotation_x_deg: l.rotation_x_deg,
                        rotation_y_deg: l.rotation_y_deg,
                        three_d: l.three_d,
                        matte,
                        blend: l.blend,
                        layer_mask: mask_tex.as_ref(),
                        pre: l.pre,
                    },
                }
            })
            .collect();
        self.compositor.composite_seeded(
            &self.ctx,
            width,
            height,
            background,
            &comp_layers,
            cam_mat,
            seed.as_ref(),
            self.render_scale,
        )
    }
}
