//! The Lens flare GPU pipeline (docs/08 §3.27, docs/impl/lens-flare.md,
//! K-256): per-frame ray-trace compute, quad-energy and vertex-build
//! compute, an additive hardware raster of the warped ghost grids, and the
//! combine kernel. The engine-pure maths and the bake live in
//! `lumit_core::fx::lens_flare`; this module consumes pre-baked data through
//! [`FlareBakeData`] (the caller converts, keeping this crate
//! lumit-core-free in production, exactly as the effect op structs do).
//!
//! In plain terms: every frame, a few hundred thousand tiny ray programs
//! push light through the chosen lens on the graphics card, and the landing
//! grid of each ghost is drawn as warped triangles that add their light into
//! a flare image; one last pass lays that (plus the baked starburst sprite)
//! over the picture. The slow maths — the Fourier transforms — never runs
//! here; it arrives as textures baked on the CPU and cached by parameter
//! hash.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use crate::{GpuContext, WORKING_FORMAT};

use super::{work_texture, FxEngine};

/// The resolved Lens flare op in lumit-gpu's own terms: plain numbers plus
/// the per-frame wavelength table, all derived by the caller (lumit-render)
/// from `lumit_core::fx::lens_flare` so the formulas live in one place.
#[derive(Debug, Clone)]
pub struct LensFlareOp {
    /// Unit light direction (lumit_core `light_direction`).
    pub dir: [f32; 3],
    /// Light position as a fraction of the raster (x right, y down).
    pub light_frac: [f32; 2],
    /// Master gain; 0 short-circuits to the identity.
    pub intensity: f32,
    /// Traced wavelengths with their RGB weights, already multiplied by the
    /// ghost energy scale × Ghost intensity (lumit_core `lambda_weights`).
    pub lambdas: Vec<(f32, [f32; 3])>,
    /// How many ranked ghosts render.
    pub max_ghosts: u32,
    /// 0..1 coating blend.
    pub coating: f32,
    /// Ghost-disc UV scale (lumit_core `ghost_disc_scale`).
    pub disc_scale: f32,
    /// Ray-grid side for this quality.
    pub grid: u32,
    /// Flare-buffer divisor (2 on Draft, else 1).
    pub flare_div: u32,
    /// Raster px per sensor mm at the FULL raster width (lumit_core
    /// `screen_transform(w)`); the flare buffer's own transform scales by
    /// its divisor.
    pub screen_transform: f32,
    /// Starburst gain, sprite scale, rotation (degrees).
    pub starburst_intensity: f32,
    /// See above.
    pub starburst_scale: f32,
    /// See above.
    pub starburst_rotation_deg: f32,
    /// Horizontal squeeze about the frame centre.
    pub anamorphic: f32,
    /// 0..1.
    pub mix: f32,
    /// `lumit_core::fx::lens_flare::bake_key` of the op — the bake cache key.
    pub bake_key: u64,
}

/// The bake handed across the crate seam: plain buffers, no lumit-core
/// types. Produced by the caller from `lumit_core::fx::lens_flare::bake`
/// only when the cache misses (the `bake` argument of
/// [`FxEngine::lens_flare`] is lazy).
#[derive(Debug, Clone)]
pub struct FlareBakeData {
    /// Surface rows: radius, center_z, height, cauchy_a, cauchy_b,
    /// coating_nm, is_iris, is_sensor — the WGSL `Surface` layout.
    pub surfaces: Vec<[f32; 8]>,
    /// Ranked ghost pairs, brightest first.
    pub ghosts: Vec<[u32; 2]>,
    /// Launch-square side, mm.
    pub launch_mm: f32,
    /// The bake's auto-exposure gain, multiplied into every ghost's energy.
    pub energy_gain: f32,
    /// Ghost-disc texture, `disc_res`² luminance.
    pub disc: Vec<f32>,
    /// See `disc`.
    pub disc_res: u32,
    /// Starburst sprite, `sb_res`² RGB triplets.
    pub starburst: Vec<f32>,
    /// See `starburst`.
    pub sb_res: u32,
}

/// One cached GPU-side bake: uploaded textures and the surface buffer.
struct GpuBaked {
    surfaces: wgpu::Buffer,
    surface_count: u32,
    ghosts: Vec<[u32; 2]>,
    launch_mm: f32,
    energy_gain: f32,
    disc: wgpu::Texture,
    starburst: wgpu::Texture,
}

/// The lens flare's pipelines and its bake cache, one field on [`FxEngine`].
pub struct LensFlareFx {
    trace: wgpu::ComputePipeline,
    quad_energy: wgpu::ComputePipeline,
    build_verts: wgpu::ComputePipeline,
    draw: wgpu::RenderPipeline,
    combine: wgpu::ComputePipeline,
    trace_layout: wgpu::BindGroupLayout,
    draw_layout: wgpu::BindGroupLayout,
    combine_layout: wgpu::BindGroupLayout,
    /// Baked resources keyed by `bake_key`. Small and bluntly bounded:
    /// animating a bake-relevant parameter (blades…) creates one entry per
    /// distinct value seen, so on overflow past [`Self::CACHE_CAP`] the map
    /// clears (eviction story per docs/14 §5: a full rebake is one
    /// parameter-change cost, ~tens of ms, and correctness never depends on
    /// the cache). The mutex is held only for get/insert — never across an
    /// upload or submit.
    cache: Mutex<HashMap<u64, Arc<GpuBaked>>>,
}

/// Ghost × wavelength combos processed per batch: bounds the ray / vertex
/// buffer sizes whatever Max ghosts × Quality asks for (the batches loop
/// inside one submit).
const BATCH_COMBOS: u32 = 16;

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct TraceParams {
    surface_count: u32,
    combo_count: u32,
    grid: u32,
    combo_offset: u32,
    launch_mm: f32,
    coating: f32,
    dir_x: f32,
    dir_y: f32,
    dir_z: f32,
    screen_transform: f32,
    raster_w: f32,
    raster_h: f32,
}

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct DrawParams {
    disc_scale: f32,
    _pad: [f32; 3],
}

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct CombineParams {
    w: f32,
    h: f32,
    fw: f32,
    fh: f32,
    light_px_x: f32,
    light_px_y: f32,
    intensity: f32,
    sb_intensity: f32,
    sb_half: f32,
    sb_cos: f32,
    sb_sin: f32,
    squeeze: f32,
    mix_amt: f32,
    _pad: [f32; 3],
}

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct GpuCombo {
    bounce1: u32,
    bounce2: u32,
    lambda_nm: f32,
    _pad: f32,
    rgb: [f32; 3],
    _pad2: f32,
}

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct GpuSurface {
    row: [f32; 8],
}

impl LensFlareFx {
    /// See [`Self::cache`].
    const CACHE_CAP: usize = 8;

    pub(super) fn new(ctx: &GpuContext) -> Self {
        let device = &ctx.device;
        let storage_entry =
            |binding: u32, read_only: bool, vis: wgpu::ShaderStages| wgpu::BindGroupLayoutEntry {
                binding,
                visibility: vis,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Storage { read_only },
                    has_dynamic_offset: false,
                    min_binding_size: None,
                },
                count: None,
            };
        let uniform_entry = |binding: u32, vis: wgpu::ShaderStages| wgpu::BindGroupLayoutEntry {
            binding,
            visibility: vis,
            ty: wgpu::BindingType::Buffer {
                ty: wgpu::BufferBindingType::Uniform,
                has_dynamic_offset: false,
                min_binding_size: None,
            },
            count: None,
        };
        let texture_entry = |binding: u32, vis: wgpu::ShaderStages| wgpu::BindGroupLayoutEntry {
            binding,
            visibility: vis,
            ty: wgpu::BindingType::Texture {
                sample_type: wgpu::TextureSampleType::Float { filterable: false },
                view_dimension: wgpu::TextureViewDimension::D2,
                multisampled: false,
            },
            count: None,
        };

        let c = wgpu::ShaderStages::COMPUTE;
        let trace_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("fx-lens-flare-trace-layout"),
            entries: &[
                storage_entry(0, true, c),
                storage_entry(1, true, c),
                storage_entry(2, false, c),
                storage_entry(3, false, c),
                storage_entry(4, false, c),
                uniform_entry(5, c),
            ],
        });
        let draw_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("fx-lens-flare-draw-layout"),
            entries: &[
                storage_entry(0, true, wgpu::ShaderStages::VERTEX),
                texture_entry(1, wgpu::ShaderStages::FRAGMENT),
                uniform_entry(2, wgpu::ShaderStages::FRAGMENT),
            ],
        });
        let combine_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("fx-lens-flare-combine-layout"),
            entries: &[
                texture_entry(0, c),
                texture_entry(1, c),
                texture_entry(2, c),
                wgpu::BindGroupLayoutEntry {
                    binding: 3,
                    visibility: c,
                    ty: wgpu::BindingType::StorageTexture {
                        access: wgpu::StorageTextureAccess::WriteOnly,
                        format: WORKING_FORMAT,
                        view_dimension: wgpu::TextureViewDimension::D2,
                    },
                    count: None,
                },
                uniform_entry(4, c),
            ],
        });

        let trace_mod = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("fx-lens-flare-trace"),
            source: wgpu::ShaderSource::Wgsl(include_str!("../fx_lens_flare_trace.wgsl").into()),
        });
        let draw_mod = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("fx-lens-flare-draw"),
            source: wgpu::ShaderSource::Wgsl(include_str!("../fx_lens_flare_draw.wgsl").into()),
        });
        let combine_mod = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("fx-lens-flare-combine"),
            source: wgpu::ShaderSource::Wgsl(include_str!("../fx_lens_flare_combine.wgsl").into()),
        });

        let trace_pl = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("fx-lens-flare-trace-pl"),
            bind_group_layouts: &[&trace_layout],
            push_constant_ranges: &[],
        });
        let compute = |entry: &str, label: &str| {
            device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
                label: Some(label),
                layout: Some(&trace_pl),
                module: &trace_mod,
                entry_point: Some(entry),
                compilation_options: Default::default(),
                cache: None,
            })
        };
        let trace = compute("trace", "fx-lens-flare-trace");
        let quad_energy = compute("quad_energy", "fx-lens-flare-quad");
        let build_verts = compute("build_verts", "fx-lens-flare-verts");

        let draw_pl = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("fx-lens-flare-draw-pl"),
            bind_group_layouts: &[&draw_layout],
            push_constant_ranges: &[],
        });
        let draw = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("fx-lens-flare-draw"),
            layout: Some(&draw_pl),
            vertex: wgpu::VertexState {
                module: &draw_mod,
                entry_point: Some("vs_flare"),
                compilation_options: Default::default(),
                buffers: &[],
            },
            primitive: wgpu::PrimitiveState {
                topology: wgpu::PrimitiveTopology::TriangleList,
                cull_mode: None,
                ..Default::default()
            },
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            fragment: Some(wgpu::FragmentState {
                module: &draw_mod,
                entry_point: Some("fs_flare"),
                compilation_options: Default::default(),
                targets: &[Some(wgpu::ColorTargetState {
                    format: WORKING_FORMAT,
                    // Plain additive: the ghost grids accumulate light.
                    blend: Some(wgpu::BlendState {
                        color: wgpu::BlendComponent {
                            src_factor: wgpu::BlendFactor::One,
                            dst_factor: wgpu::BlendFactor::One,
                            operation: wgpu::BlendOperation::Add,
                        },
                        alpha: wgpu::BlendComponent {
                            src_factor: wgpu::BlendFactor::One,
                            dst_factor: wgpu::BlendFactor::One,
                            operation: wgpu::BlendOperation::Add,
                        },
                    }),
                    write_mask: wgpu::ColorWrites::ALL,
                })],
            }),
            multiview: None,
            cache: None,
        });

        let combine_pl = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("fx-lens-flare-combine-pl"),
            bind_group_layouts: &[&combine_layout],
            push_constant_ranges: &[],
        });
        let combine = device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
            label: Some("fx-lens-flare-combine"),
            layout: Some(&combine_pl),
            module: &combine_mod,
            entry_point: Some("combine"),
            compilation_options: Default::default(),
            cache: None,
        });

        Self {
            trace,
            quad_energy,
            build_verts,
            draw,
            combine,
            trace_layout,
            draw_layout,
            combine_layout,
            cache: Mutex::new(HashMap::new()),
        }
    }

    /// The cached GPU bake for `op.bake_key`, building (outside the lock)
    /// from the caller's lazy `bake` on a miss. A racing double-build is
    /// harmless — the bake is a pure function — and the insert keeps
    /// whichever landed first.
    fn baked(
        &self,
        ctx: &GpuContext,
        op: &LensFlareOp,
        bake: &dyn Fn() -> FlareBakeData,
    ) -> Arc<GpuBaked> {
        if let Ok(cache) = self.cache.lock() {
            if let Some(hit) = cache.get(&op.bake_key) {
                return hit.clone();
            }
        }
        let data = bake();
        let built = Arc::new(upload_bake(ctx, &data));
        if let Ok(mut cache) = self.cache.lock() {
            if cache.len() >= Self::CACHE_CAP {
                cache.clear();
            }
            return cache
                .entry(op.bake_key)
                .or_insert_with(|| built.clone())
                .clone();
        }
        built
    }
}

/// Upload one bake's buffers as GPU resources.
fn upload_bake(ctx: &GpuContext, data: &FlareBakeData) -> GpuBaked {
    use wgpu::util::DeviceExt;
    let rows: Vec<GpuSurface> = data
        .surfaces
        .iter()
        .map(|&row| GpuSurface { row })
        .collect();
    let surfaces = ctx
        .device
        .create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("fx-lens-flare-surfaces"),
            contents: bytemuck::cast_slice(&rows),
            usage: wgpu::BufferUsages::STORAGE,
        });
    let float_texture = |label: &str, w: u32, h: u32, format: wgpu::TextureFormat, bytes: &[u8]| {
        ctx.device.create_texture_with_data(
            &ctx.queue,
            &wgpu::TextureDescriptor {
                label: Some(label),
                size: wgpu::Extent3d {
                    width: w,
                    height: h,
                    depth_or_array_layers: 1,
                },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format,
                usage: wgpu::TextureUsages::TEXTURE_BINDING,
                view_formats: &[],
            },
            wgpu::util::TextureDataOrder::LayerMajor,
            bytes,
        )
    };
    let disc = float_texture(
        "fx-lens-flare-disc",
        data.disc_res,
        data.disc_res,
        wgpu::TextureFormat::R32Float,
        bytemuck::cast_slice(&data.disc),
    );
    // The starburst's RGB triplets pad to rgba32float rows (alpha unused);
    // f32 keeps the CPU/GPU oracle tight.
    let mut rgba = Vec::with_capacity(data.starburst.len() / 3 * 4);
    for rgb in data.starburst.chunks_exact(3) {
        rgba.extend_from_slice(rgb);
        rgba.push(0.0f32);
    }
    let starburst = float_texture(
        "fx-lens-flare-starburst",
        data.sb_res,
        data.sb_res,
        wgpu::TextureFormat::Rgba32Float,
        bytemuck::cast_slice(&rgba),
    );
    GpuBaked {
        surfaces,
        surface_count: data.surfaces.len() as u32,
        ghosts: data.ghosts.clone(),
        launch_mm: data.launch_mm,
        energy_gain: data.energy_gain,
        disc,
        starburst,
    }
}

impl FxEngine {
    /// Apply one Lens flare (docs/08 §3.27) to a linear working texture,
    /// returning a new texture of the same size. `bake` is called only when
    /// the op's bake key misses the cache (the caller wraps
    /// `lumit_core::fx::lens_flare::bake`). The whole frame — trace, energy,
    /// vertex build, the additive ghost raster in batches, and the combine —
    /// encodes into ONE encoder and submits once.
    pub fn lens_flare(
        &self,
        ctx: &GpuContext,
        src: &wgpu::Texture,
        w: u32,
        h: u32,
        op: &LensFlareOp,
        bake: &dyn Fn() -> FlareBakeData,
    ) -> wgpu::Texture {
        use wgpu::util::DeviceExt;
        let out = work_texture(ctx, w, h, "fx-lens-flare-out");
        let lf = &self.lens_flare;

        // Neutral short-circuit mirror (the combine kernel also guards, but
        // skipping the whole pipeline is the honest fast path).
        let ghost_count_max = op.max_ghosts.min(200);
        let combos_wanted = op.intensity > 0.0 && op.mix > 0.0;
        let baked = if combos_wanted {
            Some(lf.baked(ctx, op, bake))
        } else {
            None
        };

        // Flare buffer (half size on Draft).
        let div = op.flare_div.max(1);
        let (fw, fh) = ((w / div).max(1), (h / div).max(1));
        let flare_tex = work_texture(ctx, fw, fh, "fx-lens-flare-buffer");

        let mut encoder = ctx
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("fx-lens-flare-enc"),
            });

        // Always clear the flare buffer (a zero-ghost frame must not read
        // stale memory).
        {
            let view = flare_tex.create_view(&Default::default());
            let _ = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("fx-lens-flare-clear"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color::TRANSPARENT),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                ..Default::default()
            });
        }

        if let Some(baked) = &baked {
            // Build the (ghost × wavelength) combo table for this frame.
            let ghost_count = (ghost_count_max as usize).min(baked.ghosts.len());
            let mut combos: Vec<GpuCombo> = Vec::with_capacity(ghost_count * op.lambdas.len());
            let gain = baked.energy_gain;
            for ghost in baked.ghosts.iter().take(ghost_count) {
                for &(lambda_nm, rgb) in &op.lambdas {
                    combos.push(GpuCombo {
                        bounce1: ghost[0],
                        bounce2: ghost[1],
                        lambda_nm,
                        _pad: 0.0,
                        rgb: [rgb[0] * gain, rgb[1] * gain, rgb[2] * gain],
                        _pad2: 0.0,
                    });
                }
            }
            if !combos.is_empty() {
                let grid = op.grid.clamp(2, 128);
                let ray_count = grid * grid;
                let side = grid - 1;
                let quad_count = side * side;
                let combos_buf = ctx
                    .device
                    .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                        label: Some("fx-lens-flare-combos"),
                        contents: bytemuck::cast_slice(&combos),
                        usage: wgpu::BufferUsages::STORAGE,
                    });
                // Batch-sized scratch, reused across batches (pass
                // boundaries order the reuse).
                let scratch = |label: &str, size: u64| {
                    ctx.device.create_buffer(&wgpu::BufferDescriptor {
                        label: Some(label),
                        size,
                        usage: wgpu::BufferUsages::STORAGE,
                        mapped_at_creation: false,
                    })
                };
                let rays_buf = scratch(
                    "fx-lens-flare-rays",
                    u64::from(BATCH_COMBOS) * u64::from(ray_count) * 24,
                );
                let energies_buf = scratch(
                    "fx-lens-flare-energies",
                    u64::from(BATCH_COMBOS) * u64::from(quad_count) * 4,
                );
                let verts_buf = scratch(
                    "fx-lens-flare-verts",
                    u64::from(BATCH_COMBOS) * u64::from(quad_count) * 6 * 32,
                );
                let draw_params =
                    ctx.device
                        .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                            label: Some("fx-lens-flare-draw-params"),
                            contents: bytemuck::bytes_of(&DrawParams {
                                disc_scale: op.disc_scale.max(1e-3),
                                _pad: [0.0; 3],
                            }),
                            usage: wgpu::BufferUsages::UNIFORM,
                        });
                let draw_bind = ctx.device.create_bind_group(&wgpu::BindGroupDescriptor {
                    label: Some("fx-lens-flare-draw-bind"),
                    layout: &lf.draw_layout,
                    entries: &[
                        wgpu::BindGroupEntry {
                            binding: 0,
                            resource: verts_buf.as_entire_binding(),
                        },
                        wgpu::BindGroupEntry {
                            binding: 1,
                            resource: wgpu::BindingResource::TextureView(
                                &baked.disc.create_view(&Default::default()),
                            ),
                        },
                        wgpu::BindGroupEntry {
                            binding: 2,
                            resource: draw_params.as_entire_binding(),
                        },
                    ],
                });

                let flare_view = flare_tex.create_view(&Default::default());
                let mut offset = 0u32;
                while (offset as usize) < combos.len() {
                    let batch = BATCH_COMBOS.min(combos.len() as u32 - offset);
                    let params = ctx
                        .device
                        .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                            label: Some("fx-lens-flare-trace-params"),
                            contents: bytemuck::bytes_of(&TraceParams {
                                surface_count: baked.surface_count,
                                combo_count: batch,
                                grid,
                                combo_offset: offset,
                                launch_mm: baked.launch_mm,
                                coating: op.coating,
                                dir_x: op.dir[0],
                                dir_y: op.dir[1],
                                dir_z: op.dir[2],
                                // Project into the flare buffer's raster.
                                screen_transform: op.screen_transform / div as f32,
                                raster_w: fw as f32,
                                raster_h: fh as f32,
                            }),
                            usage: wgpu::BufferUsages::UNIFORM,
                        });
                    let bind = ctx.device.create_bind_group(&wgpu::BindGroupDescriptor {
                        label: Some("fx-lens-flare-trace-bind"),
                        layout: &lf.trace_layout,
                        entries: &[
                            wgpu::BindGroupEntry {
                                binding: 0,
                                resource: baked.surfaces.as_entire_binding(),
                            },
                            wgpu::BindGroupEntry {
                                binding: 1,
                                resource: combos_buf.as_entire_binding(),
                            },
                            wgpu::BindGroupEntry {
                                binding: 2,
                                resource: rays_buf.as_entire_binding(),
                            },
                            wgpu::BindGroupEntry {
                                binding: 3,
                                resource: energies_buf.as_entire_binding(),
                            },
                            wgpu::BindGroupEntry {
                                binding: 4,
                                resource: verts_buf.as_entire_binding(),
                            },
                            wgpu::BindGroupEntry {
                                binding: 5,
                                resource: params.as_entire_binding(),
                            },
                        ],
                    });
                    // Each stage in its own pass: pass boundaries are the
                    // write-then-read barriers between them.
                    let stages: [(&wgpu::ComputePipeline, u32, &str); 3] = [
                        (&lf.trace, ray_count, "fx-lens-flare-trace-pass"),
                        (&lf.quad_energy, quad_count, "fx-lens-flare-quad-pass"),
                        (&lf.build_verts, quad_count, "fx-lens-flare-verts-pass"),
                    ];
                    for (pipeline, x_items, label) in stages {
                        let mut cpass = encoder.begin_compute_pass(&wgpu::ComputePassDescriptor {
                            label: Some(label),
                            timestamp_writes: None,
                        });
                        cpass.set_pipeline(pipeline);
                        cpass.set_bind_group(0, &bind, &[]);
                        cpass.dispatch_workgroups(x_items.div_ceil(64), batch, 1);
                    }
                    {
                        let mut rpass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                            label: Some("fx-lens-flare-draw-pass"),
                            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                                view: &flare_view,
                                resolve_target: None,
                                ops: wgpu::Operations {
                                    load: wgpu::LoadOp::Load,
                                    store: wgpu::StoreOp::Store,
                                },
                            })],
                            ..Default::default()
                        });
                        rpass.set_pipeline(&lf.draw);
                        rpass.set_bind_group(0, &draw_bind, &[]);
                        rpass.draw(0..batch * quad_count * 6, 0..1);
                    }
                    offset += batch;
                }
            }
        }

        // Combine. The starburst texture must exist even when the bake was
        // skipped (identity path): bind a 1×1 black stand-in then.
        let black;
        let sb_tex = match &baked {
            Some(b) => &b.starburst,
            None => {
                black = work_texture(ctx, 1, 1, "fx-lens-flare-black");
                &black
            }
        };
        let sb_rot = op.starburst_rotation_deg.to_radians();
        let cp = CombineParams {
            w: w as f32,
            h: h as f32,
            fw: fw as f32,
            fh: fh as f32,
            light_px_x: op.light_frac[0] * w as f32,
            light_px_y: op.light_frac[1] * h as f32,
            intensity: op.intensity,
            sb_intensity: op.starburst_intensity,
            sb_half: 0.6 * op.starburst_scale.max(0.0) * w.min(h) as f32,
            sb_cos: sb_rot.cos(),
            sb_sin: sb_rot.sin(),
            squeeze: op.anamorphic.clamp(0.25, 4.0),
            mix_amt: op.mix,
            _pad: [0.0; 3],
        };
        let cp_buf = ctx
            .device
            .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("fx-lens-flare-combine-params"),
                contents: bytemuck::bytes_of(&cp),
                usage: wgpu::BufferUsages::UNIFORM,
            });
        let combine_bind = ctx.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("fx-lens-flare-combine-bind"),
            layout: &lf.combine_layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::TextureView(
                        &src.create_view(&Default::default()),
                    ),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::TextureView(
                        &flare_tex.create_view(&Default::default()),
                    ),
                },
                wgpu::BindGroupEntry {
                    binding: 2,
                    resource: wgpu::BindingResource::TextureView(
                        &sb_tex.create_view(&Default::default()),
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
                    resource: cp_buf.as_entire_binding(),
                },
            ],
        });
        {
            let mut cpass = encoder.begin_compute_pass(&wgpu::ComputePassDescriptor {
                label: Some("fx-lens-flare-combine-pass"),
                timestamp_writes: None,
            });
            cpass.set_pipeline(&lf.combine);
            cpass.set_bind_group(0, &combine_bind, &[]);
            cpass.dispatch_workgroups(w.div_ceil(8), h.div_ceil(8), 1);
        }
        ctx.queue.submit([encoder.finish()]);
        out
    }

    /// The trace-oracle hook (docs/impl/lens-flare.md §8.5): run the trace
    /// pass alone for the first `combo_limit` (ghost × wavelength) combos and
    /// read the ray buffer back — rows `[pos_x, pos_y, uv_x, uv_y, rrel,
    /// reflectance]` per ray, combo-major (reflectance −1 is the GPU's dead
    /// sentinel where the CPU returns NaN). Diagnostics and tests only; no
    /// production path calls it.
    pub fn lens_flare_trace_debug(
        &self,
        ctx: &GpuContext,
        op: &LensFlareOp,
        bake: &dyn Fn() -> FlareBakeData,
        combo_limit: u32,
    ) -> Vec<[f32; 6]> {
        use wgpu::util::DeviceExt;
        let lf = &self.lens_flare;
        let baked = lf.baked(ctx, op, bake);
        let ghost_count = (op.max_ghosts as usize).min(baked.ghosts.len());
        let mut combos: Vec<GpuCombo> = Vec::new();
        'outer: for ghost in baked.ghosts.iter().take(ghost_count) {
            for &(lambda_nm, rgb) in &op.lambdas {
                if combos.len() >= combo_limit as usize {
                    break 'outer;
                }
                combos.push(GpuCombo {
                    bounce1: ghost[0],
                    bounce2: ghost[1],
                    lambda_nm,
                    _pad: 0.0,
                    rgb,
                    _pad2: 0.0,
                });
            }
        }
        if combos.is_empty() {
            return Vec::new();
        }
        let grid = op.grid.clamp(2, 128);
        let ray_count = grid * grid;
        let combos_buf = ctx
            .device
            .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("fx-lens-flare-dbg-combos"),
                contents: bytemuck::cast_slice(&combos),
                usage: wgpu::BufferUsages::STORAGE,
            });
        let rays_size = combos.len() as u64 * u64::from(ray_count) * 24;
        let rays_buf = ctx.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("fx-lens-flare-dbg-rays"),
            size: rays_size,
            usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_SRC,
            mapped_at_creation: false,
        });
        // The layout requires every binding; the trace entry never touches
        // the energy/vertex buffers, so minimal stand-ins satisfy it.
        let dummy = |label: &str, size: u64| {
            ctx.device.create_buffer(&wgpu::BufferDescriptor {
                label: Some(label),
                size,
                usage: wgpu::BufferUsages::STORAGE,
                mapped_at_creation: false,
            })
        };
        let energies_buf = dummy("fx-lens-flare-dbg-energies", 4);
        let verts_buf = dummy("fx-lens-flare-dbg-verts", 32);
        let params = ctx
            .device
            .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("fx-lens-flare-dbg-params"),
                contents: bytemuck::bytes_of(&TraceParams {
                    surface_count: baked.surface_count,
                    combo_count: combos.len() as u32,
                    grid,
                    combo_offset: 0,
                    launch_mm: baked.launch_mm,
                    coating: op.coating,
                    dir_x: op.dir[0],
                    dir_y: op.dir[1],
                    dir_z: op.dir[2],
                    screen_transform: op.screen_transform,
                    raster_w: 1.0,
                    raster_h: 1.0,
                }),
                usage: wgpu::BufferUsages::UNIFORM,
            });
        let bind = ctx.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("fx-lens-flare-dbg-bind"),
            layout: &lf.trace_layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: baked.surfaces.as_entire_binding(),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: combos_buf.as_entire_binding(),
                },
                wgpu::BindGroupEntry {
                    binding: 2,
                    resource: rays_buf.as_entire_binding(),
                },
                wgpu::BindGroupEntry {
                    binding: 3,
                    resource: energies_buf.as_entire_binding(),
                },
                wgpu::BindGroupEntry {
                    binding: 4,
                    resource: verts_buf.as_entire_binding(),
                },
                wgpu::BindGroupEntry {
                    binding: 5,
                    resource: params.as_entire_binding(),
                },
            ],
        });
        let read_buf = ctx.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("fx-lens-flare-dbg-read"),
            size: rays_size,
            usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
            mapped_at_creation: false,
        });
        let mut enc = ctx
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("fx-lens-flare-dbg-enc"),
            });
        {
            let mut cpass = enc.begin_compute_pass(&wgpu::ComputePassDescriptor {
                label: Some("fx-lens-flare-dbg-pass"),
                timestamp_writes: None,
            });
            cpass.set_pipeline(&lf.trace);
            cpass.set_bind_group(0, &bind, &[]);
            cpass.dispatch_workgroups(ray_count.div_ceil(64), combos.len() as u32, 1);
        }
        enc.copy_buffer_to_buffer(&rays_buf, 0, &read_buf, 0, rays_size);
        ctx.queue.submit([enc.finish()]);
        let slice = read_buf.slice(..);
        let (tx, rx) = std::sync::mpsc::channel();
        slice.map_async(wgpu::MapMode::Read, move |r| {
            let _ = tx.send(r);
        });
        ctx.device.poll(wgpu::Maintain::Wait);
        if rx.recv().map(|r| r.is_err()).unwrap_or(true) {
            return Vec::new();
        }
        let data = slice.get_mapped_range();
        data.chunks_exact(24)
            .map(|row| {
                let f = |i: usize| f32::from_le_bytes([row[i], row[i + 1], row[i + 2], row[i + 3]]);
                [f(0), f(4), f(8), f(12), f(16), f(20)]
            })
            .collect()
    }
}
