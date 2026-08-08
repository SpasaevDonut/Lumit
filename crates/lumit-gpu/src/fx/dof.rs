//! The passes that carry their own bespoke bind-group layout rather than the
//! shared two-input one: depth-of-field lens blur (docs/08 DoF foundation),
//! the 3-D LUT lookup (docs/08 §3.11) and the adjustment-layer blend.

use crate::GpuContext;

use super::{work_texture, FxEngine};

/// The most aperture blades Bokeh's polygon test carries. Bounds the
/// kernel's per-tap loop and the uniform's normal array.
///
/// Declared here rather than imported: `lumit-core` is only a dev-dependency of
/// this crate (the kernels take plain numbers and know nothing of the document
/// model), so `lumit_core::fx::MAX_BLADES` is out of reach in production code.
/// `max_blades_matches_the_core_constant` in `fx::tests` — where lumit-core IS
/// available — pins the two together so they cannot drift.
pub const MAX_BLADES: usize = 8;

/// One resolved depth-of-field pass (foundation for the planned DoF effects).
/// The per-pixel depth arrives as its own single-channel texture (see
/// [`upload_depth_map`] and [`FxEngine::dof`]); this uniform carries only the
/// scalars the kernel turns a depth into a circle-of-confusion radius with,
/// plus the host Mix. The near side (`d < focus`) uses `near_aperture`, the far
/// side `far_aperture`; both zero (or every pixel inside the sharp band) is a
/// bit-exact passthrough. `depth_invert` and `display` are u32 flags (to match
/// the WGSL uniform's scalar packing). 32 bytes: seven scalars plus one word of
/// tail padding to the 16-byte uniform stride.
#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct DofParams {
    focus: f32,
    range: f32,
    /// Near-side max CoC radius (depths in front of focus), raster px.
    near_aperture: f32,
    /// Far-side max CoC radius (depths behind focus), raster px.
    far_aperture: f32,
    mix_amt: f32,
    /// 0 = read the depth as-is, 1 = invert it (`d' = 1 - d`) before the CoC.
    depth_invert: u32,
    /// Diagnostic view: 0 = Rendered, 1 = Depth map, 2 = Focus map.
    display: u32,
    _pad: f32,
}

/// One resolved Bokeh (docs/08 §3.27) — the advanced lens blur. The depth pass
/// arrives as its own texture exactly as [`FxEngine::dof`]'s does; everything
/// else the kernel needs is here.
///
/// Field for field this is `lumit_core::fx::cpu::BokehParams`, which is what
/// lets the §1.6 oracle set both paths up from one value, and makes a field
/// added to one side an obvious omission on the other.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct BokehOp {
    /// Maximum circle-of-confusion radius, raster px.
    pub blur_radius: f32,
    /// Outward unit edge normals, the first `blade_count` live. Computed by the
    /// caller — the kernel calls no trig, so the oracle reproduces it exactly.
    pub blade_normals: [[f32; 2]; MAX_BLADES],
    /// 3..=[`MAX_BLADES`]. Never 0: Roundness 1 *is* the circle.
    pub blade_count: u32,
    /// `cos²(π/N)`.
    pub apothem2: f32,
    /// −1 star … 0 polygon … 1 circle.
    pub roundness: f32,
    /// −1 centre-weighted … 0 flat disc … 1 rim-weighted.
    pub concentration: f32,
    /// Tap-offset multipliers, both ≥ 1 and exactly one > 1, so the aperture can
    /// only shrink on one axis and never reaches outside the circle.
    pub deform_scale: [f32; 2],
    /// The tonal split level and the power its excess is raised to.
    pub threshold: f32,
    pub bokeh_power: f32,
    /// Clamp the gather to the frame edge instead of pulling in transparency.
    pub repeat_edge: bool,
    /// False = no depth layer: the whole frame defocuses at `blur_radius` and
    /// `depth` is never sampled, so the caller may bind any same-size texture.
    pub depth_bound: bool,
    /// Which channel of `depth` is read, by `lumit_core::fx::CHANNEL_OPTIONS`.
    pub depth_channel: u32,
    pub depth_invert: bool,
    /// How many bands the defocus ramp quantises into (Resolution).
    pub depth_bands: f32,
    pub focal_distance: f32,
    /// When set, focus is the depth under `focus_point` and `focal_distance` is
    /// ignored — the greyed row in the panel.
    pub use_focus_point: bool,
    /// Raster px.
    pub focus_point: [f32; 2],
    /// Multiplier on the depth distance before the ramp (the Profile control,
    /// resolved). 1 is the plain full-range falloff.
    pub focus_falloff: f32,
    /// 0 Normal, 1 Add, 2 Screen, 3 Lighten, 4 Darken.
    pub composite_mode: u32,
    pub remove_edge_leak: f32,
    pub detect_edge_threshold: f32,
    /// Diagnostic view: 0 = Rendered, 1 = Depth map, 2 = Focus map.
    pub display: u32,
    /// 0..1, blended against the unprocessed input.
    pub mix: f32,
}

/// The `bokeh` kernel's uniform. Layout mirrors `fx_bokeh.wgsl`'s `Params` field
/// for field: sixteen floats, nine `u32`s and three words of padding — 28 words,
/// a whole number of 16-byte rows — then the normals as an
/// `array<vec4<f32>, 8>`. 240 bytes. The padding is not tidiness; see `_pad`.
#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct BokehParams {
    blur_radius: f32,
    apothem2: f32,
    roundness: f32,
    concentration: f32,
    deform_x: f32,
    deform_y: f32,
    threshold: f32,
    bokeh_power: f32,
    focal_distance: f32,
    focus_x: f32,
    focus_y: f32,
    focus_falloff: f32,
    depth_bands: f32,
    remove_edge_leak: f32,
    detect_edge_threshold: f32,
    mix_amt: f32,
    blade_count: u32,
    depth_bound: u32,
    depth_channel: u32,
    depth_invert: u32,
    use_focus_point: u32,
    repeat_edge: u32,
    composite_mode: u32,
    /// Diagnostic view: 0 Rendered, 1 Depth map, 2 Focus map.
    display: u32,
    /// Whether the gather weights its taps at all. Decided host-side and once,
    /// because a weighted gather computes `Σ(c·w)/Σw`, which is not an IEEE
    /// identity even when every `w` is 1 — so the neutral settings must take a
    /// genuinely different path, not multiply by one.
    weighted: u32,
    /// Padding to a 16-byte boundary, and **load-bearing**: an
    /// `array<vec4<f32>, N>` is 16-byte aligned in WGSL, so without this the
    /// shader places `blade_normals` at the next multiple of 16 while `repr(C)`
    /// places it at the next multiple of 4, and every normal is read from the
    /// wrong offset. Adding one scalar above without adjusting this is how that
    /// happens — it costs no arithmetic and fails loudly in the §1.6 oracle
    /// (measured at 17 920 fp16 ULP when it did).
    _pad: [u32; 3],
    /// Only `.xy` of each element is read.
    blade_normals: [[f32; 4]; MAX_BLADES],
}

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct AdjustParams {
    opacity: f32,
    _pad: [f32; 3],
}

/// One resolved 3D-LUT lookup (docs/08 §3.11; docs/impl/lut.md). The cube
/// itself arrives as its own 3D texture (see [`upload_lut_3d`] and
/// [`FxEngine::lut`]); this uniform carries the edge length the shader needs to
/// turn a colour into grid coordinates, the host Mix, and the cube's input
/// domain (K-271 — the shader remaps through it exactly as the CPU reference
/// does; before that it assumed 0..1 and a cube saying otherwise rendered
/// silently wrong).
#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct LutParams {
    /// LUT edge length N (the cube holds `N³` samples).
    size: u32,
    /// 0..1, blended against the unprocessed input.
    mix: f32,
    _pad: [f32; 2],
    /// `DOMAIN_MIN`, per channel; the fourth lane is padding (a uniform vec3
    /// is 16-byte aligned regardless, so it costs nothing).
    domain_min: [f32; 4],
    /// `DOMAIN_MAX`, per channel, same padding.
    domain_max: [f32; 4],
}

impl FxEngine {
    #[allow(clippy::too_many_arguments)]
    pub fn dof(
        &self,
        ctx: &GpuContext,
        src: &wgpu::Texture,
        w: u32,
        h: u32,
        depth: &wgpu::Texture,
        focus: f32,
        range: f32,
        near_aperture: f32,
        far_aperture: f32,
        depth_invert: bool,
        display: u32,
        mix: f32,
    ) -> wgpu::Texture {
        use wgpu::util::DeviceExt;
        let out = work_texture(ctx, w, h, "fx-dof-out");
        let ubuf = ctx
            .device
            .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("fx-dof-params"),
                contents: bytemuck::bytes_of(&DofParams {
                    focus,
                    range,
                    near_aperture,
                    far_aperture,
                    mix_amt: mix,
                    depth_invert: u32::from(depth_invert),
                    display,
                    _pad: 0.0,
                }),
                usage: wgpu::BufferUsages::UNIFORM,
            });
        let view = |t: &wgpu::Texture| t.create_view(&Default::default());
        let bind = ctx.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("fx-dof-bind"),
            layout: &self.mb_layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::TextureView(&view(src)),
                },
                // orig-for-mix: a single pass, so the unprocessed original is
                // the source itself.
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::TextureView(&view(src)),
                },
                wgpu::BindGroupEntry {
                    binding: 2,
                    resource: wgpu::BindingResource::TextureView(&view(depth)),
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
        let mut enc = ctx.encoder("fx-dof-enc");
        {
            let mut cpass = enc.begin_compute_pass(&wgpu::ComputePassDescriptor {
                label: Some("fx-dof-pass"),
                timestamp_writes: None,
            });
            cpass.set_pipeline(&self.dof);
            cpass.set_bind_group(0, &bind, &[]);
            cpass.dispatch_workgroups(w.div_ceil(8), h.div_ceil(8), 1);
        }
        drop(enc);
        out
    }

    /// Apply one Bokeh (docs/08 §3.27) to a linear working texture, returning a
    /// new texture of the same size — the advanced lens blur beside
    /// [`Self::dof`], sharing its gather, its aperture and its tonal maths.
    ///
    /// What it adds over Lens blur, and the invariant each one keeps: the
    /// aperture's **Roundness reaches below zero** into star shapes, and
    /// **Deform** squeezes it on one axis — both leave it inscribed in the
    /// circle of radius `blur_radius`, so `ceil(radius)` stays a correct bound
    /// on the taps. **Concentration** weights the taps radially and **Remove
    /// edge leak** pulls back taps sitting across a depth discontinuity — both
    /// are branched around at their neutral values, so a Bokeh with neither asked
    /// for gathers exactly as Lens blur does. **Profile** biases the defocus ramp
    /// with a polynomial and **Resolution** quantises it into bands, both
    /// identically on the CPU path. **Focus point** reads the focus depth from
    /// one texel of `depth` rather than taking a number, and **Channel** chooses
    /// which channel of `depth` is depth at all.
    ///
    /// `depth` must be the same size as `src`. With `op.depth_bound` clear it is
    /// never sampled and the whole frame defocuses at `blur_radius`, so the
    /// caller may bind any same-size float texture in that slot. Shares
    /// [`Self::mb_layout`] with Motion blur and Lens blur — the depth field is
    /// the one extra sampled input over the two-input convention. A zero radius,
    /// a depth everywhere in focus, or a Mix of 0 are bit-exact passthroughs.
    pub fn bokeh(
        &self,
        ctx: &GpuContext,
        src: &wgpu::Texture,
        w: u32,
        h: u32,
        depth: &wgpu::Texture,
        op: &BokehOp,
    ) -> wgpu::Texture {
        use wgpu::util::DeviceExt;
        let out = work_texture(ctx, w, h, "fx-bokeh-out");
        let mut blade_normals = [[0.0f32; 4]; MAX_BLADES];
        for (dst, n) in blade_normals.iter_mut().zip(op.blade_normals.iter()) {
            dst[0] = n[0];
            dst[1] = n[1];
        }
        // Decided here, once, rather than per tap: see `BokehParams::weighted`.
        let weighted = op.concentration != 0.0 || (op.remove_edge_leak > 0.0 && op.depth_bound);
        let ubuf = ctx
            .device
            .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("fx-bokeh-params"),
                contents: bytemuck::bytes_of(&BokehParams {
                    blur_radius: op.blur_radius,
                    apothem2: op.apothem2,
                    roundness: op.roundness,
                    concentration: op.concentration,
                    deform_x: op.deform_scale[0],
                    deform_y: op.deform_scale[1],
                    threshold: op.threshold,
                    bokeh_power: op.bokeh_power,
                    focal_distance: op.focal_distance,
                    focus_x: op.focus_point[0],
                    focus_y: op.focus_point[1],
                    focus_falloff: op.focus_falloff,
                    depth_bands: op.depth_bands,
                    remove_edge_leak: op.remove_edge_leak,
                    detect_edge_threshold: op.detect_edge_threshold,
                    mix_amt: op.mix,
                    blade_count: op.blade_count,
                    depth_bound: u32::from(op.depth_bound),
                    depth_channel: op.depth_channel,
                    depth_invert: u32::from(op.depth_invert),
                    use_focus_point: u32::from(op.use_focus_point),
                    repeat_edge: u32::from(op.repeat_edge),
                    composite_mode: op.composite_mode,
                    display: op.display,
                    weighted: u32::from(weighted),
                    _pad: [0; 3],
                    blade_normals,
                }),
                usage: wgpu::BufferUsages::UNIFORM,
            });
        let view = |t: &wgpu::Texture| t.create_view(&Default::default());
        let bind = ctx.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("fx-bokeh-bind"),
            layout: &self.mb_layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::TextureView(&view(src)),
                },
                // orig-for-mix: a single pass, so the unprocessed original is
                // the source itself.
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::TextureView(&view(src)),
                },
                wgpu::BindGroupEntry {
                    binding: 2,
                    resource: wgpu::BindingResource::TextureView(&view(depth)),
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
        let mut enc = ctx
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("fx-bokeh-enc"),
            });
        {
            let mut cpass = enc.begin_compute_pass(&wgpu::ComputePassDescriptor {
                label: Some("fx-bokeh-pass"),
                timestamp_writes: None,
            });
            cpass.set_pipeline(&self.bokeh);
            cpass.set_bind_group(0, &bind, &[]);
            cpass.dispatch_workgroups(w.div_ceil(8), h.div_ceil(8), 1);
        }
        ctx.queue.submit([enc.finish()]);
        out
    }

    /// Apply one 3D-LUT lookup (docs/08 §3.11; docs/impl/lut.md) to a linear
    /// working texture, returning a new texture of the same size. One pass on
    /// **unpremultiplied** colour (§2.2 — a LUT is an arbitrary colour map):
    /// per output pixel, unpremultiply, map each channel through
    /// `[domain_min, domain_max]` to a grid coordinate in `[0, size-1]`
    /// (clamped, and a zero span reading as 0), `textureLoad` the eight
    /// integer corners of `lut_tex` and trilinearly interpolate in f32 — **not**
    /// the hardware sampler, whose precision is not guaranteed bit-for-bit
    /// across GPUs (docs/impl/lut.md §3) — re-premultiply, then blend against
    /// the input by the host Mix. The cube is consumed exactly as
    /// `lumit_core::lut::Lut3d::sample` reads its red-fastest data, so the two
    /// agree (§1.6). Its own bind group (the cube is a 3D texture, the one
    /// binding no other kernel has). `mix == 0` is the bit-exact input.
    #[allow(clippy::too_many_arguments)]
    pub fn lut(
        &self,
        ctx: &GpuContext,
        src: &wgpu::Texture,
        w: u32,
        h: u32,
        lut_tex: &wgpu::Texture,
        size: u32,
        mix: f32,
        domain_min: [f32; 3],
        domain_max: [f32; 3],
    ) -> wgpu::Texture {
        use wgpu::util::DeviceExt;
        let out = work_texture(ctx, w, h, "fx-lut-out");
        let ubuf = ctx
            .device
            .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("fx-lut-params"),
                contents: bytemuck::bytes_of(&LutParams {
                    size,
                    mix,
                    _pad: [0.0; 2],
                    domain_min: [domain_min[0], domain_min[1], domain_min[2], 0.0],
                    domain_max: [domain_max[0], domain_max[1], domain_max[2], 0.0],
                }),
                usage: wgpu::BufferUsages::UNIFORM,
            });
        let view = |t: &wgpu::Texture| t.create_view(&Default::default());
        // The cube is a 3D texture; name its view dimension explicitly so the
        // binding matches the layout's `D3` regardless of the default.
        let lut_view = lut_tex.create_view(&wgpu::TextureViewDescriptor {
            dimension: Some(wgpu::TextureViewDimension::D3),
            ..Default::default()
        });
        let bind = ctx.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("fx-lut-bind"),
            layout: &self.lut_layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::TextureView(&view(src)),
                },
                // orig-for-mix: a single pass, so the unprocessed original is
                // the source itself.
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::TextureView(&view(src)),
                },
                wgpu::BindGroupEntry {
                    binding: 2,
                    resource: wgpu::BindingResource::TextureView(&view(&out)),
                },
                wgpu::BindGroupEntry {
                    binding: 3,
                    resource: ubuf.as_entire_binding(),
                },
                wgpu::BindGroupEntry {
                    binding: 4,
                    resource: wgpu::BindingResource::TextureView(&lut_view),
                },
            ],
        });
        let mut enc = ctx.encoder("fx-lut-enc");
        {
            let mut cpass = enc.begin_compute_pass(&wgpu::ComputePassDescriptor {
                label: Some("fx-lut-pass"),
                timestamp_writes: None,
            });
            cpass.set_pipeline(&self.lut);
            cpass.set_bind_group(0, &bind, &[]);
            cpass.dispatch_workgroups(w.div_ceil(8), h.div_ceil(8), 1);
        }
        drop(enc);
        out
    }

    /// The adjustment-layer blend (docs/06 §1.5): per-channel lerp between
    /// the accumulated composite `below` and its effected copy `processed`,
    /// by `coverage`'s alpha (the layer's comp-space mask raster) times
    /// `opacity` (the layer opacity, 0..1). All three textures are comp
    /// sized; returns a new comp-sized working texture.
    #[allow(clippy::too_many_arguments)]
    pub fn adjust_blend(
        &self,
        ctx: &GpuContext,
        below: &wgpu::Texture,
        processed: &wgpu::Texture,
        coverage: &wgpu::Texture,
        w: u32,
        h: u32,
        opacity: f32,
    ) -> wgpu::Texture {
        use wgpu::util::DeviceExt;
        let out = work_texture(ctx, w, h, "fx-adjust-out");
        let ubuf = ctx
            .device
            .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("fx-adjust-params"),
                contents: bytemuck::bytes_of(&AdjustParams {
                    opacity,
                    _pad: [0.0; 3],
                }),
                usage: wgpu::BufferUsages::UNIFORM,
            });
        let bind = ctx.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("fx-adjust-bind"),
            layout: &self.adjust_layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::TextureView(
                        &below.create_view(&Default::default()),
                    ),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::TextureView(
                        &processed.create_view(&Default::default()),
                    ),
                },
                wgpu::BindGroupEntry {
                    binding: 2,
                    resource: wgpu::BindingResource::TextureView(
                        &coverage.create_view(&Default::default()),
                    ),
                },
                wgpu::BindGroupEntry {
                    binding: 3,
                    resource: wgpu::BindingResource::TextureView(
                        &out.create_view(&Default::default()),
                    ),
                },
                wgpu::BindGroupEntry {
                    binding: 4,
                    resource: ubuf.as_entire_binding(),
                },
            ],
        });
        let mut enc = ctx.encoder("fx-adjust-enc");
        {
            let mut cpass = enc.begin_compute_pass(&wgpu::ComputePassDescriptor {
                label: Some("fx-adjust-pass"),
                timestamp_writes: None,
            });
            cpass.set_pipeline(&self.adjust);
            cpass.set_bind_group(0, &bind, &[]);
            cpass.dispatch_workgroups(w.div_ceil(8), h.div_ceil(8), 1);
        }
        drop(enc);
        out
    }
}
