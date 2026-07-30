//! The GPU colour foundation (docs/impl/gpu-foundation.md §1–2, slice 5).
//!
//! In plain terms: the engine does all its maths on light-linear values (where
//! "add two lights" behaves like real light), but files and screens use sRGB
//! encoding. This crate owns the ONLY two crossings: decode-side linearise
//! (sRGB bytes → linear fp16 working texture) and display-side encode
//! (linear → sRGB for the screen). Keeping both crossings in one module with
//! a round-trip test is what prevents the classic "double gamma" washed-out /
//! too-dark bugs — and it is why preview can be bit-identical to export
//! (decision K-031).

use thiserror::Error;

#[derive(Debug, Error)]
pub enum GpuError {
    #[error("no suitable GPU adapter")]
    NoAdapter,
    #[error("device request failed: {0}")]
    Device(String),
    #[error("readback failed: {0}")]
    Readback(String),
}

/// Device + queue. In the app these come from eframe's render state; tests
/// and future headless export create their own.
pub struct GpuContext {
    pub device: wgpu::Device,
    pub queue: wgpu::Queue,
    /// True when the adapter is a CPU rasteriser (Mesa's lavapipe in CI, WARP
    /// on Windows) rather than real hardware. Only tests read it, and only to
    /// choose how strict a *bit-exactness* claim may be: two mathematically
    /// identical shader paths agree to the bit on a given GPU, but fp16
    /// rounding differs between implementations, so a software rasteriser can
    /// land a least-significant bit away from hardware. The pixels are still
    /// checked — within one 8-bit step instead of exactly (see
    /// `accumulation_still_scene_is_identity_and_moving_scene_smears`).
    pub software: bool,
}

impl GpuContext {
    /// Wrap an existing device/queue (eframe's render state — wgpu handles
    /// are internally reference-counted, so cloning shares the one device).
    /// This is the running application's real display adapter.
    pub fn from_parts(device: wgpu::Device, queue: wgpu::Queue) -> Self {
        Self {
            device,
            queue,
            software: false,
        }
    }

    /// Headless context (tests, future CLI export).
    pub fn headless() -> Result<Self, GpuError> {
        // The backend is pinned on all three platforms, in every build (K-205,
        // superseding K-177 on this point). Two reasons: the zero-copy Viewer
        // hand-off reaches through wgpu to a *specific* backend's device, and
        // since K-183 deleted the CPU read-back transport there is no build left
        // that wants a mixed-backend instance. Pinning also fixes the hybrid
        // iGPU+dGPU case described below.
        //
        // `from_env_or_default` supplies the rest of the descriptor (flags, the
        // DX12 shader compiler, the GLES minor version) from `WGPU_*`, so those
        // stay tunable — but `backends` is set explicitly *after* it, so the pin
        // wins and `WGPU_BACKEND` cannot move it. That is intended: an
        // environment variable must not be able to break the Viewer.
        #[cfg(windows)]
        let instance = wgpu::Instance::new(&wgpu::InstanceDescriptor {
            backends: wgpu::Backends::DX12,
            ..wgpu::InstanceDescriptor::from_env_or_default()
        });
        // On a hybrid iGPU+dGPU box (e.g. AMD + Nvidia) mixing GL and Vulkan into one
        // enumeration makes PowerPreference::HighPerformance pick unreliably (commonly
        // picking the AMD iGPU driving the display), which can cause VRAM exhaustion
        // during command submission. Pinning Vulkan prevents that.
        #[cfg(target_os = "linux")]
        let instance = wgpu::Instance::new(&wgpu::InstanceDescriptor {
            backends: wgpu::Backends::VULKAN,
            ..wgpu::InstanceDescriptor::from_env_or_default()
        });
        #[cfg(target_os = "macos")]
        let instance = wgpu::Instance::new(&wgpu::InstanceDescriptor {
            backends: wgpu::Backends::METAL,
            ..wgpu::InstanceDescriptor::from_env_or_default()
        });
        #[cfg(not(any(windows, target_os = "linux", target_os = "macos")))]
        let instance = wgpu::Instance::new(&wgpu::InstanceDescriptor::from_env_or_default());
        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            ..Default::default()
        }))
        .ok_or(GpuError::NoAdapter)?;
        let software = matches!(
            adapter.get_info().device_type,
            wgpu::DeviceType::Cpu | wgpu::DeviceType::Other
        );
        // The Linux DMA-BUF path needs the external-memory device extensions
        // enabled at device-creation time, which wgpu's default Vulkan device does
        // not do (K-177). Open the device ourselves with them appended; if the
        // adapter cannot enable them, fall back to a plain device so the read-back
        // path still works (the DMA-BUF path then reports unavailable).
        #[cfg(all(target_os = "linux", feature = "shared-texture-linux"))]
        let (device, queue) = match shared_linux::open_device(&adapter) {
            Ok(dq) => dq,
            Err(_) => {
                pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor::default(), None))
                    .map_err(|e| GpuError::Device(e.to_string()))?
            }
        };
        #[cfg(not(all(target_os = "linux", feature = "shared-texture-linux")))]
        let (device, queue) =
            pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor::default(), None))
                .map_err(|e| GpuError::Device(e.to_string()))?;

        // Which adapter was picked is the first thing anyone asks when the
        // Viewer is black or a hybrid-GPU machine chose the wrong card — but it
        // is noise on every test and every shipped run, so it is opt-in. The
        // crate has no logging framework (the workspace prints diagnostics with
        // `eprintln!`), so the gate is an environment variable: set
        // `LUMIT_GPU_DEBUG` to anything to get the line.
        if std::env::var_os("LUMIT_GPU_DEBUG").is_some() {
            let info = adapter.get_info();
            eprintln!(
                "lumit-gpu: adapter selected: {} ({:?}, backend {:?}, driver {})",
                info.name, info.device_type, info.backend, info.driver_info,
            );
        }
        // wgpu's defaults for both of these panic. An engine crate may not panic
        // (docs/14-ENGINEERING-RULES.md), and neither condition is recoverable
        // *here*: a validation error means a frame is wrong, a lost device means
        // every later frame fails and the surrounding code already treats a
        // failed render as a dropped frame. So the deliberate behaviour is to
        // report and carry on, in the same shape as the rest of the workspace's
        // diagnostics, rather than to take the process down mid-edit.
        device.on_uncaptured_error(Box::new(|e| {
            eprintln!("lumit-gpu: uncaptured wgpu error: {e}");
        }));
        device.set_device_lost_callback(|reason, msg| {
            eprintln!("lumit-gpu: device lost ({reason:?}): {msg}");
        });

        Ok(Self {
            device,
            queue,
            software,
        })
    }
}

/// The two colour crossings (linearise, display) as render pipelines.
pub struct ColourEngine {
    linearise: wgpu::RenderPipeline,
    display: wgpu::RenderPipeline,
    /// The display pass again, targeting BGRA — for the shared-texture Viewer,
    /// whose consumer (ANGLE inside Flutter) matches share-handle surfaces
    /// against its own B8G8R8A8 configs. Same shader, same hardware sRGB
    /// encode; only the channel order of the render target differs.
    display_bgra: wgpu::RenderPipeline,
    layout: wgpu::BindGroupLayout,
    sampler: wgpu::Sampler,
    linear_sampler: wgpu::Sampler,
}

/// The engine's working format (docs/06-RENDER-PIPELINE.md §3).
pub const WORKING_FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Rgba16Float;
/// Source/display byte format: sRGB-encoded, hardware-converted at the edges.
pub const SRGB_FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Rgba8UnormSrgb;

/// A read-back in flight: the copy is already on the graphics card's queue and
/// the buffer is being mapped, with nobody waiting. Started by
/// [`ColourEngine::start_readback8`]; drained by [`Self::poll`], which never
/// blocks. Dropping one abandons the read-back harmlessly.
pub struct PendingReadback {
    buffer: wgpu::Buffer,
    width: u32,
    height: u32,
    /// The buffer's row stride, which alignment may have padded past `width * 4`.
    padded: u32,
    done: std::sync::mpsc::Receiver<Result<(), wgpu::BufferAsyncError>>,
    taken: bool,
}

impl PendingReadback {
    /// The frame's dimensions, known from the moment the copy is encoded.
    #[must_use]
    pub fn size(&self) -> (u32, u32) {
        (self.width, self.height)
    }

    /// The bytes, once the card has finished — `None` while it has not, so the
    /// caller simply asks again next turn.
    ///
    /// `Some(Err(_))` means the read-back failed and will not arrive: the caller
    /// drops it and the frame is re-rendered if it is wanted again, which is all
    /// a cache miss ever costs. After either answer this yields `None` for ever
    /// (the buffer is unmapped), so a caller cannot double-take.
    pub fn poll(&mut self, ctx: &GpuContext) -> Option<Result<Vec<u8>, GpuError>> {
        if self.taken {
            return None;
        }
        // Progress the queue without waiting on it: `Poll` returns whatever has
        // already completed. `Wait` here would defeat the whole point.
        ctx.device.poll(wgpu::Maintain::Poll);
        match self.done.try_recv() {
            Ok(Ok(())) => {}
            Ok(Err(e)) => {
                self.taken = true;
                return Some(Err(GpuError::Readback(e.to_string())));
            }
            Err(std::sync::mpsc::TryRecvError::Empty) => return None,
            Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                self.taken = true;
                return Some(Err(GpuError::Readback("mapping abandoned".into())));
            }
        }
        self.taken = true;
        let slice = self.buffer.slice(..);
        let data = slice.get_mapped_range();
        let row = (self.width * 4) as usize;
        let mut out = Vec::with_capacity(row * self.height as usize);
        for r in 0..self.height as usize {
            let start = r * self.padded as usize;
            match data.get(start..start + row) {
                Some(bytes) => out.extend_from_slice(bytes),
                // A buffer shorter than its own stride promises cannot happen,
                // but an engine crate answers rather than indexes off the end.
                None => {
                    drop(data);
                    self.buffer.unmap();
                    return Some(Err(GpuError::Readback("short read-back buffer".into())));
                }
            }
        }
        drop(data);
        self.buffer.unmap();
        Some(Ok(out))
    }
}

impl ColourEngine {
    pub fn new(ctx: &GpuContext) -> Self {
        let shader = ctx
            .device
            .create_shader_module(wgpu::include_wgsl!("colour.wgsl"));
        let layout = ctx
            .device
            .create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
                label: Some("colour-src"),
                entries: &[
                    wgpu::BindGroupLayoutEntry {
                        binding: 0,
                        visibility: wgpu::ShaderStages::FRAGMENT,
                        ty: wgpu::BindingType::Texture {
                            sample_type: wgpu::TextureSampleType::Float { filterable: true },
                            view_dimension: wgpu::TextureViewDimension::D2,
                            multisampled: false,
                        },
                        count: None,
                    },
                    wgpu::BindGroupLayoutEntry {
                        binding: 1,
                        visibility: wgpu::ShaderStages::FRAGMENT,
                        ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                        count: None,
                    },
                ],
            });
        let pipeline_layout = ctx
            .device
            .create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: Some("colour"),
                bind_group_layouts: &[&layout],
                push_constant_ranges: &[],
            });
        let make = |target: wgpu::TextureFormat, label: &str| {
            ctx.device
                .create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                    label: Some(label),
                    layout: Some(&pipeline_layout),
                    vertex: wgpu::VertexState {
                        module: &shader,
                        entry_point: Some("vs_fullscreen"),
                        buffers: &[],
                        compilation_options: Default::default(),
                    },
                    fragment: Some(wgpu::FragmentState {
                        module: &shader,
                        entry_point: Some("fs_copy"),
                        targets: &[Some(target.into())],
                        compilation_options: Default::default(),
                    }),
                    primitive: Default::default(),
                    depth_stencil: None,
                    multisample: Default::default(),
                    multiview: None,
                    cache: None,
                })
        };
        let sampler = ctx.device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("colour-nearest"),
            mag_filter: wgpu::FilterMode::Nearest,
            min_filter: wgpu::FilterMode::Nearest,
            ..Default::default()
        });
        // Only for [`Self::display_scaled`]. The 1:1 passes must stay Nearest —
        // exact texel-for-texel sampling is what makes the colour round-trip
        // golden meaningful — but a downscale sampled Nearest is just aliasing.
        let linear_sampler = ctx.device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("colour-linear"),
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            ..Default::default()
        });
        Self {
            linearise: make(WORKING_FORMAT, "linearise"),
            display: make(SRGB_FORMAT, "display"),
            display_bgra: make(wgpu::TextureFormat::Bgra8UnormSrgb, "display-bgra"),
            layout,
            sampler,
            linear_sampler,
        }
    }

    /// Upload sRGB-encoded RGBA8 bytes (a decoded frame) ready for linearising.
    pub fn upload_srgb8(
        &self,
        ctx: &GpuContext,
        rgba: &[u8],
        width: u32,
        height: u32,
    ) -> wgpu::Texture {
        let texture = ctx.device.create_texture(&wgpu::TextureDescriptor {
            label: Some("frame-srgb8"),
            size: wgpu::Extent3d {
                width,
                height,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: SRGB_FORMAT,
            usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
            view_formats: &[],
        });
        ctx.queue.write_texture(
            texture.as_image_copy(),
            rgba,
            wgpu::TexelCopyBufferLayout {
                offset: 0,
                bytes_per_row: Some(width * 4),
                rows_per_image: Some(height),
            },
            wgpu::Extent3d {
                width,
                height,
                depth_or_array_layers: 1,
            },
        );
        texture
    }

    fn pass(
        &self,
        ctx: &GpuContext,
        pipeline: &wgpu::RenderPipeline,
        src: &wgpu::Texture,
        format: wgpu::TextureFormat,
        extra_usage: wgpu::TextureUsages,
        label: &str,
    ) -> wgpu::Texture {
        self.pass_sized(ctx, pipeline, src, None, format, extra_usage, label)
    }

    /// [`Self::pass`] with an explicit destination size. A `size` smaller than
    /// the source resamples through the linear sampler, which is how a preview
    /// is reduced on the graphics card rather than after it.
    #[allow(clippy::too_many_arguments)]
    fn pass_sized(
        &self,
        ctx: &GpuContext,
        pipeline: &wgpu::RenderPipeline,
        src: &wgpu::Texture,
        size: Option<(u32, u32)>,
        format: wgpu::TextureFormat,
        extra_usage: wgpu::TextureUsages,
        label: &str,
    ) -> wgpu::Texture {
        let scaled = size.is_some();
        let size = match size {
            Some((width, height)) => wgpu::Extent3d {
                width: width.max(1),
                height: height.max(1),
                depth_or_array_layers: 1,
            },
            None => src.size(),
        };
        let dst = ctx.device.create_texture(&wgpu::TextureDescriptor {
            label: Some(label),
            size,
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT
                | wgpu::TextureUsages::TEXTURE_BINDING
                | extra_usage,
            view_formats: &[],
        });
        let bind = ctx.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some(label),
            layout: &self.layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::TextureView(
                        &src.create_view(&Default::default()),
                    ),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::Sampler(if scaled {
                        &self.linear_sampler
                    } else {
                        &self.sampler
                    }),
                },
            ],
        });
        let mut encoder = ctx
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some(label) });
        {
            let view = dst.create_view(&Default::default());
            let mut rpass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some(label),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color::BLACK),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                ..Default::default()
            });
            rpass.set_pipeline(pipeline);
            rpass.set_bind_group(0, &bind, &[]);
            rpass.draw(0..3, 0..1);
        }
        ctx.queue.submit([encoder.finish()]);
        dst
    }

    /// sRGB source texture → linear fp16 working texture.
    pub fn linearise(&self, ctx: &GpuContext, src: &wgpu::Texture) -> wgpu::Texture {
        self.pass(
            ctx,
            &self.linearise,
            src,
            WORKING_FORMAT,
            wgpu::TextureUsages::empty(),
            "linearise",
        )
    }

    /// Linear working texture → sRGB display texture (register this with the
    /// UI, or read it back for export/tests).
    pub fn display(&self, ctx: &GpuContext, src: &wgpu::Texture) -> wgpu::Texture {
        self.pass(
            ctx,
            &self.display,
            src,
            SRGB_FORMAT,
            wgpu::TextureUsages::COPY_SRC,
            "display",
        )
    }

    /// Linear working texture → sRGB-encoded BGRA display texture.
    ///
    /// For the zero-copy Viewer only (see the field's comment): pixels bound for
    /// a DXGI share handle must be BGRA or ANGLE cannot open the surface, and
    /// it declines silently. Encoded by the same hardware sRGB write as
    /// [`Self::display`], so the values are bit-identical, reordered.
    pub fn display_bgra(&self, ctx: &GpuContext, src: &wgpu::Texture) -> wgpu::Texture {
        self.pass(
            ctx,
            &self.display_bgra,
            src,
            wgpu::TextureFormat::Bgra8UnormSrgb,
            wgpu::TextureUsages::COPY_SRC,
            "display-bgra",
        )
    }

    /// Linear working texture → sRGB display texture at `width` x `height`.
    ///
    /// The point is what does *not* happen afterwards: a preview shown at a
    /// third of comp resolution used to be composited full size, read back full
    /// size — 8 MB off the graphics card for a 1080p comp — and only then
    /// resized on the processor. Resizing here means the read-back is already
    /// the size the Viewer wants.
    pub fn display_scaled(
        &self,
        ctx: &GpuContext,
        src: &wgpu::Texture,
        width: u32,
        height: u32,
    ) -> wgpu::Texture {
        self.pass_sized(
            ctx,
            &self.display,
            src,
            Some((width, height)),
            SRGB_FORMAT,
            wgpu::TextureUsages::COPY_SRC,
            "display-scaled",
        )
    }

    /// Upload display-encoded bytes back into a display texture — the way UP the
    /// cache ladder (docs/06 §5.1: "promotes RAM→VRAM").
    ///
    /// **Why this has to exist.** Every other path here makes pixels *from* a
    /// composite. A frame held as bytes in the RAM tier, or read back off disk,
    /// has no way to reach the screen without one of these: the zero-copy Viewer
    /// presents by copying one texture into another, so bytes alone cannot be
    /// shown and a demoted frame would simply be composited again — which makes
    /// the tiers below VRAM worth nothing.
    ///
    /// `bgra` picks the channel order the bytes are in, matching
    /// [`Self::display`] / [`Self::display_bgra`], so a frame goes back up in the
    /// order it came down and no per-frame swizzle is needed. The usages are the
    /// ones a present and a further read-back need (`COPY_SRC`), so an uploaded
    /// frame behaves exactly like a freshly composited one.
    pub fn upload_display8(
        &self,
        ctx: &GpuContext,
        bytes: &[u8],
        width: u32,
        height: u32,
        bgra: bool,
    ) -> Option<wgpu::Texture> {
        // A payload that is not exactly one frame is refused before anything is
        // made: a texture of no width stops the program, and an engine crate
        // does not stop the program (docs/14).
        let want = (width as usize)
            .checked_mul(height as usize)?
            .checked_mul(4)?;
        if want == 0 || bytes.len() != want {
            return None;
        }
        let texture = ctx.device.create_texture(&wgpu::TextureDescriptor {
            label: Some("frame-display8-upload"),
            size: wgpu::Extent3d {
                width,
                height,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: Self::display8_format(bgra),
            usage: wgpu::TextureUsages::TEXTURE_BINDING
                | wgpu::TextureUsages::COPY_DST
                | wgpu::TextureUsages::COPY_SRC,
            view_formats: &[],
        });
        self.write_display8(ctx, &texture, bytes, width, height)
            .then_some(texture)
    }

    /// The pixel format [`Self::upload_display8`] gives a frame of each channel
    /// order. A pool of textures for re-use must compare formats, thus the
    /// choice is stated once here and not in each caller.
    #[must_use]
    pub fn display8_format(bgra: bool) -> wgpu::TextureFormat {
        if bgra {
            wgpu::TextureFormat::Bgra8UnormSrgb
        } else {
            SRGB_FORMAT
        }
    }

    /// Write display-encoded bytes into a texture that already exists — the
    /// re-use path for [`Self::upload_display8`].
    ///
    /// A new texture for each promoted frame means one allocation on the
    /// graphics card for each frame that playback goes past, and each one is
    /// 8 MB at 1080p. A texture that came out of the cache has the correct size
    /// and format for the next frame, thus the caller keeps it and writes over
    /// it. The queue keeps the two operations in order: a write always occurs
    /// after the copies that were sent before it.
    ///
    /// `false` when the payload is not exactly one frame of the given size, or
    /// when the texture is a different size. The caller must then make a new
    /// texture. A short payload is refused because `write_texture` stops the
    /// program if you give it too few bytes, and an engine crate does not stop
    /// the program (docs/14).
    #[must_use]
    pub fn write_display8(
        &self,
        ctx: &GpuContext,
        texture: &wgpu::Texture,
        bytes: &[u8],
        width: u32,
        height: u32,
    ) -> bool {
        let Some(want) = (width as usize)
            .checked_mul(height as usize)
            .and_then(|px| px.checked_mul(4))
        else {
            return false;
        };
        if want == 0
            || bytes.len() != want
            || texture.width() != width
            || texture.height() != height
        {
            return false;
        }
        ctx.queue.write_texture(
            texture.as_image_copy(),
            bytes,
            wgpu::TexelCopyBufferLayout {
                offset: 0,
                bytes_per_row: Some(width * 4),
                rows_per_image: Some(height),
            },
            wgpu::Extent3d {
                width,
                height,
                depth_or_array_layers: 1,
            },
        );
        true
    }

    /// Begin reading a display texture back WITHOUT waiting for it — the
    /// non-blocking sibling of [`Self::readback8`].
    ///
    /// **Why the split matters.** [`Self::readback8`] ends in
    /// `poll(Maintain::Wait)`: the calling thread sits there until the graphics
    /// card has finished. That is right for export and for tests, and quite
    /// wrong for demoting a frame out of the VRAM cache — that happens *during*
    /// a render, on the worker thread the preview is waiting on, so paying a
    /// full read-back there would make every eviction a stutter. This encodes
    /// the copy, submits it, and returns; the copy runs on the card alongside
    /// the next composite and the caller collects the bytes a loop turn or two
    /// later ([`PendingReadback::poll`]).
    pub fn start_readback8(&self, ctx: &GpuContext, tex: &wgpu::Texture) -> PendingReadback {
        let size = tex.size();
        let row = size.width * 4;
        let padded =
            row.div_ceil(wgpu::COPY_BYTES_PER_ROW_ALIGNMENT) * wgpu::COPY_BYTES_PER_ROW_ALIGNMENT;
        let buffer = ctx.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("readback-async"),
            size: u64::from(padded) * u64::from(size.height),
            usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
            mapped_at_creation: false,
        });
        let mut encoder = ctx.device.create_command_encoder(&Default::default());
        encoder.copy_texture_to_buffer(
            tex.as_image_copy(),
            wgpu::TexelCopyBufferInfo {
                buffer: &buffer,
                layout: wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(padded),
                    rows_per_image: Some(size.height),
                },
            },
            size,
        );
        ctx.queue.submit([encoder.finish()]);
        let (tx, rx) = std::sync::mpsc::channel();
        buffer
            .slice(..)
            .map_async(wgpu::MapMode::Read, move |r| _ = tx.send(r));
        PendingReadback {
            buffer,
            width: size.width,
            height: size.height,
            padded,
            done: rx,
            taken: false,
        }
    }

    /// Read a display texture back as tight RGBA8 bytes (tests, export).
    pub fn readback8(&self, ctx: &GpuContext, tex: &wgpu::Texture) -> Result<Vec<u8>, GpuError> {
        let size = tex.size();
        let row = size.width * 4;
        let padded =
            row.div_ceil(wgpu::COPY_BYTES_PER_ROW_ALIGNMENT) * wgpu::COPY_BYTES_PER_ROW_ALIGNMENT;
        let buffer = ctx.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("readback"),
            size: u64::from(padded) * u64::from(size.height),
            usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
            mapped_at_creation: false,
        });
        let mut encoder = ctx.device.create_command_encoder(&Default::default());
        encoder.copy_texture_to_buffer(
            tex.as_image_copy(),
            wgpu::TexelCopyBufferInfo {
                buffer: &buffer,
                layout: wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(padded),
                    rows_per_image: Some(size.height),
                },
            },
            size,
        );
        ctx.queue.submit([encoder.finish()]);

        let slice = buffer.slice(..);
        let (tx, rx) = std::sync::mpsc::channel();
        slice.map_async(wgpu::MapMode::Read, move |r| {
            let _ = tx.send(r);
        });
        ctx.device.poll(wgpu::Maintain::Wait);
        rx.recv()
            .map_err(|e| GpuError::Readback(e.to_string()))?
            .map_err(|e| GpuError::Readback(e.to_string()))?;

        let data = slice.get_mapped_range();
        let mut out = Vec::with_capacity((row * size.height) as usize);
        for r in 0..size.height {
            let start = (r * padded) as usize;
            out.extend_from_slice(&data[start..start + row as usize]);
        }
        drop(data);
        buffer.unmap();
        Ok(out)
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    /// The gpu-foundation §7 golden: every 8-bit value survives
    /// sRGB → linear fp16 → sRGB within 1 LSB. This is the test that makes
    /// double-gamma bugs impossible to reintroduce silently (K-031).
    #[test]
    fn colour_round_trip_is_within_one_lsb() {
        let Ok(ctx) = GpuContext::headless() else {
            eprintln!("skipping: no GPU adapter available");
            return;
        };
        let engine = ColourEngine::new(&ctx);

        // 16×16: every possible byte value in R, G and B (offset per channel).
        let (w, h) = (16u32, 16u32);
        let mut rgba = Vec::with_capacity((w * h * 4) as usize);
        for i in 0..256u32 {
            rgba.push(i as u8); // R = 0..255
            rgba.push((255 - i) as u8); // G reversed
            rgba.push(((i * 7) % 256) as u8); // B strided
            rgba.push(255);
        }

        let src = engine.upload_srgb8(&ctx, &rgba, w, h);
        let linear = engine.linearise(&ctx, &src);
        let shown = engine.display(&ctx, &linear);
        let back = engine.readback8(&ctx, &shown).unwrap();

        assert_eq!(back.len(), rgba.len());
        let mut worst = 0i16;
        for (i, (a, b)) in rgba.iter().zip(back.iter()).enumerate() {
            let d = (i16::from(*a) - i16::from(*b)).abs();
            worst = worst.max(d);
            assert!(d <= 1, "byte {i}: {a} → {b} (Δ{d})");
        }
        eprintln!("worst Δ = {worst}");
    }

    /// The working texture really is fp16 linear: mid-grey sRGB 128 must
    /// round-trip through a value near 0.216 linear, not 0.5 — proven by the
    /// round trip staying exact where a linear-as-srgb confusion would clamp
    /// or shift the dark end.
    #[test]
    fn dark_end_precision_survives_fp16() {
        let Ok(ctx) = GpuContext::headless() else {
            eprintln!("skipping: no GPU adapter available");
            return;
        };
        let engine = ColourEngine::new(&ctx);
        // The 64 darkest values — where fp16-in-linear-light is tightest.
        let (w, h) = (8u32, 8u32);
        let mut rgba = Vec::new();
        for i in 0..64u8 {
            rgba.extend_from_slice(&[i, i, i, 255]);
        }
        let src = engine.upload_srgb8(&ctx, &rgba, w, h);
        let back = engine
            .readback8(&ctx, &engine.display(&ctx, &engine.linearise(&ctx, &src)))
            .unwrap();
        for (i, (a, b)) in rgba.iter().zip(back.iter()).enumerate() {
            let d = (i16::from(*a) - i16::from(*b)).abs();
            assert!(d <= 1, "dark byte {i}: {a} → {b}");
        }
    }
}

pub mod composite;
pub mod fx;
pub mod oklab;
pub mod scope;
/// The Windows-only zero-copy Viewer target (K-177). Present only in the opt-in
/// `shared-texture` build on Windows; every other build has no shared texture at
/// all, exactly as it had no D3D interop before.
#[cfg(all(windows, feature = "shared-texture"))]
pub mod shared;
/// The Linux-only zero-copy Viewer target via DMA-BUF (K-177). Present only in
/// the opt-in `shared-texture-linux` build on Linux; every other build has no
/// DMA-BUF interop at all, exactly as it had no Vulkan external memory before.
#[cfg(all(target_os = "linux", feature = "shared-texture-linux"))]
pub mod shared_linux;
/// The macOS-only zero-copy Viewer target via IOSurface (K-195). Present only in
/// the opt-in `shared-texture-macos` build on macOS; every other build has no
/// Metal interop at all.
#[cfg(all(target_os = "macos", feature = "shared-texture-macos"))]
pub mod shared_metal;
pub use composite::{
    camera_matrix, concat_place, place_matrix, scaled_size, Blend, CompositeLayer, Compositor,
    MatteInput, MbSample,
};
pub use glam::Mat4;
