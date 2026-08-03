//! The Lens flare GPU pipeline (docs/08 §3.27, docs/impl/lens-flare.md,
//! K-256/K-257): per-frame ray-trace compute, quad-energy and vertex-build
//! compute, an additive hardware raster of the warped ghost grids, the
//! Matte-mode source detection, and the combine kernel. The engine-pure
//! maths and the bake live in `lumit_core::fx::lens_flare`; this module
//! consumes pre-baked data through [`FlareBakeData`] (the caller converts,
//! keeping this crate lumit-core-free in production, exactly as the effect
//! op structs do).
//!
//! In plain terms: every frame, a few hundred thousand tiny ray programs
//! push light through the chosen lens on the graphics card — once per flare
//! source — and the landing grid of each ghost is drawn as warped triangles
//! that add their light into a flare image; one last pass lays that (plus a
//! baked starburst sprite per source) over the picture. In Matte mode the
//! sources themselves are found on the card first: the matte layer's
//! brightest points, detected by two small kernels. The slow maths — the
//! Fourier transforms — never runs here; it arrives as textures baked on
//! the CPU and cached by parameter hash.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use crate::{GpuContext, WORKING_FORMAT};

use super::{work_texture, FxEngine};

/// The resolved Lens flare op in lumit-gpu's own terms: plain numbers plus
/// the per-frame wavelength table, all derived by the caller (lumit-render)
/// from `lumit_core::fx::lens_flare` so the formulas live in one place.
#[derive(Debug, Clone)]
pub struct LensFlareOp {
    /// Manual light position as a fraction of the raster (x right, y down)
    /// — the caller divides its raster-pixel parameter by the raster (K-260).
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
    /// Focus distance, metres (K-260); the sensor shift derives from it and
    /// the bake's focal length inside the apply.
    pub focus_m: f32,
    /// Working f-stop (K-261): the stop-down scale derives from it and the
    /// bake's native f-number inside the apply.
    pub fstop: f32,
    /// Iris blade count for the in-shader pupil mask.
    pub blades: u32,
    /// Iris rotation, degrees.
    pub aperture_rotation_deg: f32,
    /// 0..1 iris roundness (the wide-open blend applies inside the apply).
    pub roundness: f32,
    /// 0..1 iris edge softness.
    pub aperture_softness: f32,
    /// Ghost blur radius as % of the frame diagonal (K-261).
    pub ghost_softness: f32,
    /// Pupil-grid side for this quality.
    pub grid: u32,
    /// Flare-buffer divisor (2 on Draft, else 1).
    pub flare_div: u32,
    /// Raster px per sensor mm at the FULL raster width (lumit_core
    /// `screen_transform(w)`); the flare buffer's own transform scales by
    /// its divisor.
    pub screen_transform: f32,
    /// Starburst gain.
    pub starburst_intensity: f32,
    /// Whole-flare scale about the optical centre (ghosts and starbursts).
    pub scale: f32,
    /// Horizontal squeeze about the frame centre.
    pub anamorphic: f32,
    /// Source mode: 0 Manual, 1 Matte, 2 Lights (resolves as Manual until
    /// light layers land — K-257).
    pub source: u32,
    /// Matte mode's soft luma gate (lumit_core `threshold_gate`).
    pub threshold: f32,
    /// See `threshold`.
    pub threshold_softness: f32,
    /// Scene-linear RGB multiplying every light's colour (K-259).
    pub light_tint: [f32; 3],
    /// Matte/Lights: whether a detected source's own colour tints its flare.
    pub use_source_colour: bool,
    /// 1 = Black background: the output is made opaque (K-258).
    pub background: u32,
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
    /// Surface rows: radius, z, semi_ap, cauchy_a, cauchy_b,
    /// coating_layers, is_stop, pad — the WGSL `Surface` layout (K-261).
    pub surfaces: Vec<[f32; 8]>,
    /// Ranked ghost pairs, brightest first.
    pub ghosts: Vec<[u32; 2]>,
    /// Sensor plane z, mm.
    pub sensor_z_mm: f32,
    /// Focal length, mm — the in-shader light direction's z.
    pub focal_mm: f32,
    /// Native f-number (the stop-down and wide-open-roundness reference).
    pub native_fstop: f32,
    /// Pupil spray radius, mm.
    pub pupil_mm: f32,
    /// Ray start z, mm.
    pub start_z_mm: f32,
    /// The bake's auto-exposure gain, multiplied into every ghost's energy.
    pub energy_gain: f32,
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
    sensor_z_mm: f32,
    focal_mm: f32,
    native_fstop: f32,
    pupil_mm: f32,
    start_z_mm: f32,
    energy_gain: f32,
    starburst: wgpu::Texture,
}

/// The lens flare's pipelines and its bake cache, one field on [`FxEngine`].
pub struct LensFlareFx {
    trace: wgpu::ComputePipeline,
    quad_energy: wgpu::ComputePipeline,
    build_verts: wgpu::ComputePipeline,
    detect_tiles: wgpu::ComputePipeline,
    detect_pick: wgpu::ComputePipeline,
    draw: wgpu::RenderPipeline,
    blur: wgpu::ComputePipeline,
    combine: wgpu::ComputePipeline,
    trace_layout: wgpu::BindGroupLayout,
    detect_layout: wgpu::BindGroupLayout,
    draw_layout: wgpu::BindGroupLayout,
    blur_layout: wgpu::BindGroupLayout,
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

/// Most flare sources a frame renders — must equal
/// `lumit_core::fx::lens_flare::MAX_LIGHTS` (pinned by test).
pub const MAX_LIGHTS: u32 = 8;

/// Detection tile side — must equal `lens_flare::DETECT_TILE` (pinned by
/// the same test).
const DETECT_TILE: u32 = 32;

/// Byte budget for the per-batch vertex scratch: bounds the batch size so
/// Ultra grids across eight lights cannot ask for a quarter-gigabyte buffer.
const VERTS_BYTE_BUDGET: u64 = 48_000_000;

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct TraceParams {
    surface_count: u32,
    combo_count: u32,
    grid: u32,
    combo_offset: u32,
    coating: f32,
    aspect: f32,
    focal_mm: f32,
    screen_transform: f32,
    raster_w: f32,
    raster_h: f32,
    light_count: u32,
    sensor_shift_mm: f32,
    pupil_mm: f32,
    start_z_mm: f32,
    sensor_z_mm: f32,
    stop_scale: f32,
    cell_area_px: f32,
    blades: u32,
    rot_rad: f32,
    roundness: f32,
    softness: f32,
    _pad0: f32,
    _pad1: f32,
    _pad2: f32,
}

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct DetectParams {
    w: u32,
    h: u32,
    tiles_x: u32,
    tiles_y: u32,
    threshold: f32,
    softness: f32,
    use_source_colour: u32,
    _pad0: f32,
    tint: [f32; 3],
    _pad1: f32,
}

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct BlurParams {
    w: u32,
    h: u32,
    radius: u32,
    dir: u32,
}

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
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
    background: u32,
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

/// One flare source in the WGSL `Light` layout: pos.xy, rgb, three pads.
#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct GpuLight {
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
                storage_entry(6, true, c),
            ],
        });
        let detect_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("fx-lens-flare-detect-layout"),
            entries: &[
                texture_entry(0, c),
                storage_entry(1, false, c),
                storage_entry(2, false, c),
                uniform_entry(3, c),
            ],
        });
        let draw_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("fx-lens-flare-draw-layout"),
            entries: &[storage_entry(0, true, wgpu::ShaderStages::VERTEX)],
        });
        let blur_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("fx-lens-flare-blur-layout"),
            entries: &[
                texture_entry(0, c),
                wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    visibility: c,
                    ty: wgpu::BindingType::StorageTexture {
                        access: wgpu::StorageTextureAccess::WriteOnly,
                        format: WORKING_FORMAT,
                        view_dimension: wgpu::TextureViewDimension::D2,
                    },
                    count: None,
                },
                uniform_entry(2, c),
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
                storage_entry(5, true, c),
            ],
        });

        let trace_mod = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("fx-lens-flare-trace"),
            source: wgpu::ShaderSource::Wgsl(include_str!("../fx_lens_flare_trace.wgsl").into()),
        });
        let detect_mod = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("fx-lens-flare-detect"),
            source: wgpu::ShaderSource::Wgsl(include_str!("../fx_lens_flare_detect.wgsl").into()),
        });
        let draw_mod = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("fx-lens-flare-draw"),
            source: wgpu::ShaderSource::Wgsl(include_str!("../fx_lens_flare_draw.wgsl").into()),
        });
        let combine_mod = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("fx-lens-flare-combine"),
            source: wgpu::ShaderSource::Wgsl(include_str!("../fx_lens_flare_combine.wgsl").into()),
        });
        let blur_mod = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("fx-lens-flare-blur"),
            source: wgpu::ShaderSource::Wgsl(include_str!("../fx_lens_flare_blur.wgsl").into()),
        });

        let trace_pl = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("fx-lens-flare-trace-pl"),
            bind_group_layouts: &[&trace_layout],
            push_constant_ranges: &[],
        });
        let compute = |entry: &str, label: &str, module: &wgpu::ShaderModule, pl| {
            device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
                label: Some(label),
                layout: Some(pl),
                module,
                entry_point: Some(entry),
                compilation_options: Default::default(),
                cache: None,
            })
        };
        let trace = compute("trace", "fx-lens-flare-trace", &trace_mod, &trace_pl);
        let quad_energy = compute("quad_energy", "fx-lens-flare-quad", &trace_mod, &trace_pl);
        let build_verts = compute("build_verts", "fx-lens-flare-verts", &trace_mod, &trace_pl);

        let detect_pl = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("fx-lens-flare-detect-pl"),
            bind_group_layouts: &[&detect_layout],
            push_constant_ranges: &[],
        });
        let detect_tiles = compute(
            "detect_tiles",
            "fx-lens-flare-detect-tiles",
            &detect_mod,
            &detect_pl,
        );
        let detect_pick = compute(
            "detect_pick",
            "fx-lens-flare-detect-pick",
            &detect_mod,
            &detect_pl,
        );

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
        let combine = compute(
            "combine",
            "fx-lens-flare-combine",
            &combine_mod,
            &combine_pl,
        );
        let blur_pl = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("fx-lens-flare-blur-pl"),
            bind_group_layouts: &[&blur_layout],
            push_constant_ranges: &[],
        });
        let blur = compute("blur", "fx-lens-flare-blur", &blur_mod, &blur_pl);

        Self {
            trace,
            quad_energy,
            build_verts,
            detect_tiles,
            detect_pick,
            draw,
            blur,
            combine,
            trace_layout,
            detect_layout,
            draw_layout,
            blur_layout,
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
        sensor_z_mm: data.sensor_z_mm,
        focal_mm: data.focal_mm,
        native_fstop: data.native_fstop,
        pupil_mm: data.pupil_mm,
        start_z_mm: data.start_z_mm,
        energy_gain: data.energy_gain,
        starburst,
    }
}

impl FxEngine {
    /// Apply one Lens flare (docs/08 §3.27) to a linear working texture,
    /// returning a new texture of the same size. `bake` is called only when
    /// the op's bake key misses the cache (the caller wraps
    /// `lumit_core::fx::lens_flare::bake`). `matte` is the Matte source's
    /// rendered layer (the DoF layer-input shape) — read only when
    /// `op.source == 1`; an absent matte there means no sources, the
    /// labelled-no-op convention. The whole frame — source detection, trace,
    /// energy, vertex build, the additive ghost raster in batches, and the
    /// combine — encodes into ONE encoder and submits once.
    #[allow(clippy::too_many_arguments)]
    pub fn lens_flare(
        &self,
        ctx: &GpuContext,
        src: &wgpu::Texture,
        w: u32,
        h: u32,
        op: &LensFlareOp,
        matte: Option<&wgpu::Texture>,
        bake: &dyn Fn() -> FlareBakeData,
    ) -> wgpu::Texture {
        use wgpu::util::DeviceExt;
        let out = work_texture(ctx, w, h, "fx-lens-flare-out");
        let lf = &self.lens_flare;

        // Neutral short-circuit mirror (the combine kernel also guards, but
        // skipping the whole pipeline is the honest fast path).
        let ghost_count_max = op.max_ghosts.min(200);
        let live = op.intensity > 0.0 && op.mix > 0.0;
        let baked = if live {
            Some(lf.baked(ctx, op, bake))
        } else {
            None
        };

        // Matte mode runs with MAX_LIGHTS candidate slots (dead ones carry
        // zero weight and cost no fill); Manual and the prepared Lights mode
        // run one.
        let matte_mode = op.source == 1;
        let light_count = if matte_mode { MAX_LIGHTS } else { 1 };

        // The frame's light list. Manual fills slot 0 from the CPU; Matte
        // mode overwrites the buffer with the detection kernels below.
        let mut light_rows = vec![GpuLight { row: [0.0; 8] }; MAX_LIGHTS as usize];
        if !matte_mode {
            light_rows[0] = GpuLight {
                row: [
                    op.light_frac[0],
                    op.light_frac[1],
                    op.light_tint[0],
                    op.light_tint[1],
                    op.light_tint[2],
                    0.0,
                    0.0,
                    0.0,
                ],
            };
        }
        let lights_buf = ctx
            .device
            .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("fx-lens-flare-lights"),
                contents: bytemuck::cast_slice(&light_rows),
                usage: wgpu::BufferUsages::STORAGE,
            });

        // Flare buffer (half size on Draft).
        let div = op.flare_div.max(1);
        let (fw, fh) = ((w / div).max(1), (h / div).max(1));
        let flare_tex = work_texture(ctx, fw, fh, "fx-lens-flare-buffer");

        let mut encoder = ctx
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("fx-lens-flare-enc"),
            });

        // Matte-mode source detection (impl note §6): tile maxima, then the
        // serial top-K pick — both before any trace pass reads the lights.
        if live && matte_mode {
            if let Some(matte) = matte {
                let (mw, mh) = (matte.width(), matte.height());
                let tiles_x = mw.div_ceil(DETECT_TILE);
                let tiles_y = mh.div_ceil(DETECT_TILE);
                let tiles_buf = ctx.device.create_buffer(&wgpu::BufferDescriptor {
                    label: Some("fx-lens-flare-tiles"),
                    size: u64::from(tiles_x * tiles_y) * 8,
                    usage: wgpu::BufferUsages::STORAGE,
                    mapped_at_creation: false,
                });
                let dp = ctx
                    .device
                    .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                        label: Some("fx-lens-flare-detect-params"),
                        contents: bytemuck::bytes_of(&DetectParams {
                            w: mw,
                            h: mh,
                            tiles_x,
                            tiles_y,
                            threshold: op.threshold,
                            softness: op.threshold_softness,
                            use_source_colour: u32::from(op.use_source_colour),
                            _pad0: 0.0,
                            tint: op.light_tint,
                            _pad1: 0.0,
                        }),
                        usage: wgpu::BufferUsages::UNIFORM,
                    });
                let bind = ctx.device.create_bind_group(&wgpu::BindGroupDescriptor {
                    label: Some("fx-lens-flare-detect-bind"),
                    layout: &lf.detect_layout,
                    entries: &[
                        wgpu::BindGroupEntry {
                            binding: 0,
                            resource: wgpu::BindingResource::TextureView(
                                &matte.create_view(&Default::default()),
                            ),
                        },
                        wgpu::BindGroupEntry {
                            binding: 1,
                            resource: tiles_buf.as_entire_binding(),
                        },
                        wgpu::BindGroupEntry {
                            binding: 2,
                            resource: lights_buf.as_entire_binding(),
                        },
                        wgpu::BindGroupEntry {
                            binding: 3,
                            resource: dp.as_entire_binding(),
                        },
                    ],
                });
                {
                    let mut cpass = encoder.begin_compute_pass(&wgpu::ComputePassDescriptor {
                        label: Some("fx-lens-flare-detect-tiles-pass"),
                        timestamp_writes: None,
                    });
                    cpass.set_pipeline(&lf.detect_tiles);
                    cpass.set_bind_group(0, &bind, &[]);
                    cpass.dispatch_workgroups(tiles_x, tiles_y, 1);
                }
                {
                    let mut cpass = encoder.begin_compute_pass(&wgpu::ComputePassDescriptor {
                        label: Some("fx-lens-flare-detect-pick-pass"),
                        timestamp_writes: None,
                    });
                    cpass.set_pipeline(&lf.detect_pick);
                    cpass.set_bind_group(0, &bind, &[]);
                    cpass.dispatch_workgroups(1, 1, 1);
                }
            }
            // No matte bound: the zero-filled lights render nothing — the
            // labelled-no-op convention for an unset layer reference.
        }

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
            // Build the (ghost × wavelength) combo table for this frame; the
            // light dimension rides the dispatch z instead (its population is
            // only known GPU-side in Matte mode).
            let ghost_count = (ghost_count_max as usize).min(baked.ghosts.len());
            let gain = baked.energy_gain;
            let mut combos: Vec<GpuCombo> = Vec::with_capacity(ghost_count * op.lambdas.len());
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
                // Batch size bounded by the vertex scratch budget: eight
                // lights at an Ultra grid would otherwise ask for a
                // quarter-gigabyte buffer.
                let quad_bytes = u64::from(quad_count) * 6 * 32;
                let batch_cap = (VERTS_BYTE_BUDGET / (u64::from(light_count) * quad_bytes).max(1))
                    .clamp(1, 16) as u32;
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
                let slots = u64::from(light_count) * u64::from(batch_cap);
                let rays_buf = scratch("fx-lens-flare-rays", slots * u64::from(ray_count) * 16);
                let energies_buf =
                    scratch("fx-lens-flare-energies", slots * u64::from(quad_count) * 4);
                let verts_buf = scratch("fx-lens-flare-verts", slots * quad_bytes);
                let draw_bind = ctx.device.create_bind_group(&wgpu::BindGroupDescriptor {
                    label: Some("fx-lens-flare-draw-bind"),
                    layout: &lf.draw_layout,
                    entries: &[wgpu::BindGroupEntry {
                        binding: 0,
                        resource: verts_buf.as_entire_binding(),
                    }],
                });

                let flare_view = flare_tex.create_view(&Default::default());
                let mut offset = 0u32;
                while (offset as usize) < combos.len() {
                    let batch = batch_cap.min(combos.len() as u32 - offset);
                    // Frame-time optics shared with the CPU reference
                    // (K-261): the stop-down scale, the wide-open roundness
                    // blend, and the launch cell area in flare-buffer px².
                    let stop_scale = if baked.native_fstop > 0.0 && op.fstop > 0.0 {
                        (baked.native_fstop / op.fstop).clamp(0.05, 1.0)
                    } else {
                        1.0
                    };
                    let native = baked.native_fstop.max(0.7);
                    let wide_open =
                        (1.0 - (op.fstop / native - 1.0).clamp(0.0, 2.0) / 2.0).clamp(0.0, 1.0);
                    let st_flare = op.screen_transform / div as f32;
                    let cell_mm = 2.0 * baked.pupil_mm * stop_scale / (grid.max(2) - 1) as f32;
                    let params = ctx
                        .device
                        .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                            label: Some("fx-lens-flare-trace-params"),
                            contents: bytemuck::bytes_of(&TraceParams {
                                surface_count: baked.surface_count,
                                combo_count: batch,
                                grid,
                                combo_offset: offset,
                                coating: op.coating,
                                aspect: h as f32 / w.max(1) as f32,
                                focal_mm: baked.focal_mm,
                                // Project into the flare buffer's raster.
                                screen_transform: st_flare,
                                raster_w: fw as f32,
                                raster_h: fh as f32,
                                light_count,
                                // Focus (K-260): thin-lens shift, the same
                                // f²/(1000·d − f) the CPU reference uses.
                                sensor_shift_mm: {
                                    let f = baked.focal_mm;
                                    if op.focus_m <= 0.0 {
                                        0.0
                                    } else {
                                        (f * f / (1000.0 * op.focus_m - f).max(f)).clamp(0.0, f)
                                    }
                                },
                                pupil_mm: baked.pupil_mm * stop_scale,
                                start_z_mm: baked.start_z_mm,
                                sensor_z_mm: baked.sensor_z_mm,
                                stop_scale,
                                cell_area_px: cell_mm * cell_mm * st_flare * st_flare,
                                blades: op.blades.clamp(3, 16),
                                rot_rad: op.aperture_rotation_deg.to_radians(),
                                roundness: op.roundness.max(wide_open),
                                softness: op.aperture_softness,
                                _pad0: 0.0,
                                _pad1: 0.0,
                                _pad2: 0.0,
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
                            wgpu::BindGroupEntry {
                                binding: 6,
                                resource: lights_buf.as_entire_binding(),
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
                        cpass.dispatch_workgroups(x_items.div_ceil(64), batch, light_count);
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
                        rpass.draw(0..light_count * batch * quad_count * 6, 0..1);
                    }
                    offset += batch;
                }
            }

            // Ghost blur (K-261, FlareSim's Ghost Blur): 3 separable box
            // passes over the flare buffer, ping-ponging through a scratch
            // texture — an even pass count lands the result back in
            // `flare_tex` for the combine.
            let radius = {
                let diag = ((fw * fw + fh * fh) as f32).sqrt();
                (op.ghost_softness.clamp(0.0, 2.0) * 0.01 * diag).round() as u32
            };
            if radius > 0 {
                let scratch_tex = work_texture(ctx, fw, fh, "fx-lens-flare-blur-scratch");
                for pass in 0..3u32 {
                    for dir in 0..2u32 {
                        let _ = pass;
                        let (src_t, dst_t) = if dir == 0 {
                            (&flare_tex, &scratch_tex)
                        } else {
                            (&scratch_tex, &flare_tex)
                        };
                        let bp = ctx
                            .device
                            .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                                label: Some("fx-lens-flare-blur-params"),
                                contents: bytemuck::bytes_of(&BlurParams {
                                    w: fw,
                                    h: fh,
                                    radius,
                                    dir,
                                }),
                                usage: wgpu::BufferUsages::UNIFORM,
                            });
                        let bind = ctx.device.create_bind_group(&wgpu::BindGroupDescriptor {
                            label: Some("fx-lens-flare-blur-bind"),
                            layout: &lf.blur_layout,
                            entries: &[
                                wgpu::BindGroupEntry {
                                    binding: 0,
                                    resource: wgpu::BindingResource::TextureView(
                                        &src_t.create_view(&Default::default()),
                                    ),
                                },
                                wgpu::BindGroupEntry {
                                    binding: 1,
                                    resource: wgpu::BindingResource::TextureView(
                                        &dst_t.create_view(&Default::default()),
                                    ),
                                },
                                wgpu::BindGroupEntry {
                                    binding: 2,
                                    resource: bp.as_entire_binding(),
                                },
                            ],
                        });
                        let mut cpass = encoder.begin_compute_pass(&wgpu::ComputePassDescriptor {
                            label: Some("fx-lens-flare-blur-pass"),
                            timestamp_writes: None,
                        });
                        cpass.set_pipeline(&lf.blur);
                        cpass.set_bind_group(0, &bind, &[]);
                        cpass.dispatch_workgroups(fw.div_ceil(8), fh.div_ceil(8), 1);
                    }
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
        let fscale = op.scale.clamp(0.05, 20.0);
        let cp = CombineParams {
            w: w as f32,
            h: h as f32,
            fw: fw as f32,
            fh: fh as f32,
            intensity: op.intensity,
            sb_intensity: op.starburst_intensity,
            sb_half: 0.6 * fscale * w.min(h) as f32,
            squeeze: op.anamorphic.clamp(0.25, 4.0),
            fscale,
            mix_amt: op.mix,
            light_count,
            background: op.background.min(1),
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
                wgpu::BindGroupEntry {
                    binding: 5,
                    resource: lights_buf.as_entire_binding(),
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
    /// pass alone for the first `combo_limit` (pair × wavelength) combos of
    /// the op's MANUAL light and read the ray buffer back — rows `[pos_x,
    /// pos_y, weight, pad]` per corner, combo-major (weight −1 is the GPU's
    /// dead sentinel where the CPU returns None). `w`/`h` feed the aspect
    /// the in-shader light direction uses. Diagnostics and tests only; no
    /// production path calls it.
    pub fn lens_flare_trace_debug(
        &self,
        ctx: &GpuContext,
        op: &LensFlareOp,
        bake: &dyn Fn() -> FlareBakeData,
        combo_limit: u32,
        w: u32,
        h: u32,
    ) -> Vec<[f32; 4]> {
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
        let mut light_rows = vec![GpuLight { row: [0.0; 8] }; MAX_LIGHTS as usize];
        light_rows[0] = GpuLight {
            row: [
                op.light_frac[0],
                op.light_frac[1],
                op.light_tint[0],
                op.light_tint[1],
                op.light_tint[2],
                0.0,
                0.0,
                0.0,
            ],
        };
        let lights_buf = ctx
            .device
            .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("fx-lens-flare-dbg-lights"),
                contents: bytemuck::cast_slice(&light_rows),
                usage: wgpu::BufferUsages::STORAGE,
            });
        let rays_size = combos.len() as u64 * u64::from(ray_count) * 16;
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
                contents: bytemuck::bytes_of(&{
                    let stop_scale = if baked.native_fstop > 0.0 && op.fstop > 0.0 {
                        (baked.native_fstop / op.fstop).clamp(0.05, 1.0)
                    } else {
                        1.0
                    };
                    let native = baked.native_fstop.max(0.7);
                    let wide_open =
                        (1.0 - (op.fstop / native - 1.0).clamp(0.0, 2.0) / 2.0).clamp(0.0, 1.0);
                    let cell_mm = 2.0 * baked.pupil_mm * stop_scale / (grid.max(2) - 1) as f32;
                    TraceParams {
                        surface_count: baked.surface_count,
                        combo_count: combos.len() as u32,
                        grid,
                        combo_offset: 0,
                        coating: op.coating,
                        aspect: h as f32 / w.max(1) as f32,
                        focal_mm: baked.focal_mm,
                        screen_transform: op.screen_transform,
                        raster_w: w as f32,
                        raster_h: h as f32,
                        light_count: 1,
                        sensor_shift_mm: {
                            let f = baked.focal_mm;
                            if op.focus_m <= 0.0 {
                                0.0
                            } else {
                                (f * f / (1000.0 * op.focus_m - f).max(f)).clamp(0.0, f)
                            }
                        },
                        pupil_mm: baked.pupil_mm * stop_scale,
                        start_z_mm: baked.start_z_mm,
                        sensor_z_mm: baked.sensor_z_mm,
                        stop_scale,
                        cell_area_px: cell_mm * cell_mm * op.screen_transform * op.screen_transform,
                        blades: op.blades.clamp(3, 16),
                        rot_rad: op.aperture_rotation_deg.to_radians(),
                        roundness: op.roundness.max(wide_open),
                        softness: op.aperture_softness,
                        _pad0: 0.0,
                        _pad1: 0.0,
                        _pad2: 0.0,
                    }
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
                wgpu::BindGroupEntry {
                    binding: 6,
                    resource: lights_buf.as_entire_binding(),
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
        data.chunks_exact(16)
            .map(|row| {
                let f = |i: usize| f32::from_le_bytes([row[i], row[i + 1], row[i + 2], row[i + 3]]);
                [f(0), f(4), f(8), f(12)]
            })
            .collect()
    }
}
