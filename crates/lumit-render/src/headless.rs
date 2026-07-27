//! Rendering single comp frames without a window — what a frontend that draws
//! its own pixels (Flutter, over `lumit-bridge`) holds and drives.
//!
//! # In plain terms
//!
//! A [`HeadlessRenderer`] owns the expensive things that must survive between
//! frames: the GPU context (whose adapter is acquired once), the compiled
//! shaders, the open video decoders, and the probe results. Hold one per
//! session and ask it for frames.
//!
//! It offers two ways to render, and the difference matters:
//!
//! - [`HeadlessRenderer::render_preview`] is the **interactive** path. It plans
//!   the decode, reuses the pixels it decoded last time whenever the plan has
//!   not changed, builds a draw list and composites. Dragging an effect value
//!   changes what is *done* with the pixels, never *which* pixels are wanted,
//!   so a drag re-composites and decodes nothing at all. It also honours the
//!   preview resolution, so footage is decoded at the size it will be shown
//!   rather than at full size and thrown away. This is the path a Viewer wants.
//! - [`HeadlessRenderer::render_rgba`] is the **export** path, driving
//!   [`crate::export`]'s `Renderer` straight: always full resolution, decoding
//!   every frame afresh, holding nothing between calls. Correct and simple,
//!   which is what writing a file wants.
//!
//! Both composite through the same GPU code, so preview == export == Flutter
//! (K-031). The two currently walk the comp by different routes
//! (`build_comp_draws` here, `render_comp_linear` there) and are kept in step by
//! hand plus tests; unifying them is a recorded next step (docs/TODO.md).

use crate::decode::{CompFrame, CompJob, DecodePool};
use crate::export::{AudioJob, ItemInfo, Renderer};
use crate::plan::{plan_comp_frame, Quality, RetimeOverride};
use crate::source::{SourceProbe, SourceProbes};
use lumit_core::model::{Composition, Document, FootageItem, LayerKind, ProjectItem};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use uuid::Uuid;

/// The persistent GPU engines + decoder pool a render needs, held between calls
/// so shaders compile once and warm decoders survive a scrub. Lent to a
/// [`Renderer`] for the duration of one render and taken back afterwards.
struct Parts {
    colour: lumit_gpu::ColourEngine,
    compositor: lumit_gpu::Compositor,
    fx: lumit_gpu::fx::FxEngine,
    flow: lumit_flow::FlowEngine,
    lut_cache: std::cell::RefCell<HashMap<String, crate::fxops::LoadedLut>>,
    decoders: HashMap<Uuid, lumit_media::VideoDecoder>,
}

/// One footage item's probe result, cached so a scrub does not re-probe. Slate
/// sizing is deliberately *not* stored here — the missing/failed slate is sized
/// to the comp being rendered at call time, since the same item can appear in
/// comps of different dimensions.
enum Probe {
    /// Decodable video: its exact rate, native size and frame count (the
    /// `frame_pick` and decode-width inputs).
    Ok {
        fps: f64,
        frames: usize,
        width: u32,
        height: u32,
    },
    /// A readable file with no video stream (audio-only). Not an error, so it
    /// must never draw the missing-footage slate — the layer simply
    /// contributes no picture, exactly as `item_infos` (export) and
    /// `collect_comp_jobs` (the live preview) already treat it.
    NoVideo,
    /// Not on disk, or present-but-unreadable: render the colour-bars slate,
    /// exactly as export's `item_infos` carries a `Missing` item (docs/07 §3.3).
    Slate,
}

/// A reusable, window-free renderer that turns `(Document, comp, frame)` into an
/// RGBA8 buffer through the export compositor. Hold one per frontend session.
///
/// The GPU adapter is acquired in [`HeadlessRenderer::new`]; a machine with no
/// adapter fails there, and the caller (the bridge) never constructs a second —
/// it returns its calm "no frame" state instead of retrying every call.
pub struct HeadlessRenderer {
    gpu: lumit_gpu::GpuContext,
    /// `Some` except for the instant a render borrows the engines. A render that
    /// unwinds (never expected — engine crates forbid panics) leaves this `None`,
    /// and further calls answer a calm error rather than crashing.
    parts: Option<Parts>,
    /// The GPU scope pass (K-096 v1). Held directly rather than in [`Parts`]
    /// because a scope trace runs *from a finished frame*, not during a
    /// composite, so it is never lent to the `Renderer` — it borrows `&self.gpu`
    /// on its own. Compiled once with the other engines.
    scope: lumit_gpu::scope::ScopeEngine,
    /// The `ItemInfo` map the renderer reads, rebuilt each call (cheap — it only
    /// reads `probe_cache`) so a missing item's slate matches the current comp.
    items: HashMap<Uuid, ItemInfo>,
    /// Probe results by footage id, so each file is probed at most once.
    probe_cache: HashMap<Uuid, Probe>,
    /// The audio-jobs walk with its has-audio probe cache, so building the
    /// export audio jobs probes each file at most once (export path only).
    audio_jobs: AudioJobsBuilder,
    /// The open decoders and the decoded-source-frame cache the interactive
    /// path uses. Deliberately separate from the `Parts::decoders` the export
    /// path lends to `Renderer`: the two decode at different resolutions, and
    /// sharing them would let a half-resolution preview frame reach an export.
    pool: DecodePool,
    /// The last interactive frame's decoded per-layer pixels, kept with the
    /// plan that produced them — what makes a live value drag cost no decoding
    /// at all. Replaced whenever a render genuinely needs different pixels.
    retained: Option<Retained>,
    /// The Windows zero-copy Viewer target (K-177), held for the session and
    /// re-created only when the comp's dimensions change. `None` until the first
    /// `render_to_shared` call. Present only in the opt-in shared-texture build.
    #[cfg(all(windows, feature = "shared-texture"))]
    shared: Option<lumit_gpu::shared::SharedTexture>,
    /// The Linux zero-copy Viewer target (K-177), the DMA-BUF sibling of
    /// [`Self::shared`]. Held for the session and re-created only when the comp's
    /// dimensions change. `None` until the first `render_to_shared_dmabuf` call.
    /// Present only in the opt-in shared-texture-linux build.
    #[cfg(all(target_os = "linux", feature = "shared-texture-linux"))]
    shared_dmabuf: Option<lumit_gpu::shared_linux::SharedDmabuf>,
}

/// One frame's decoded per-layer pixels, kept alongside the decode plan that
/// asked for them, so the next render can tell at a glance whether it needs new
/// ones ([`crate::plan::same_decode`]).
struct Retained {
    comp: Uuid,
    frame: u64,
    jobs: Vec<CompJob>,
    pixels: CompFrame,
}

/// A rendered frame that stayed on the GPU: the NT handle of the shared texture
/// it lives in, plus its dimensions and format (K-177). Handed across the bridge
/// so the Windows runner can register the texture with Flutter without any pixel
/// copy. The handle stays valid across frames (the same texture is re-used) and
/// only changes when the comp is resized.
#[cfg(all(windows, feature = "shared-texture"))]
pub struct SharedFrameInfo {
    /// The NT `HANDLE` value of the shared texture (a
    /// `kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle` surface).
    pub handle: u64,
    pub width: u32,
    pub height: u32,
    /// Always RGBA8888 (`DXGI_FORMAT_R8G8B8A8_UNORM` holding sRGB-encoded bytes),
    /// the identical pixels the read-back path produces.
    pub format: &'static str,
}

/// A rendered frame that stayed on the GPU as a DMA-BUF (the Linux zero-copy
/// Viewer path, K-177): the exported file descriptor plus the dimensions, stride,
/// offset and DRM format/modifier the GTK embedder needs to import it as an
/// `EGLImage`. The Linux sibling of [`SharedFrameInfo`]. The fd stays valid
/// across frames (the same texture is re-used) and only changes when the comp is
/// resized.
#[cfg(all(target_os = "linux", feature = "shared-texture-linux"))]
pub struct SharedFrameInfoLinux {
    pub fd: i32,
    pub width: u32,
    pub height: u32,
    pub stride: u32,
    pub offset: u32,
    /// The DRM fourcc (`DRM_FORMAT_ABGR8888`, memory order R,G,B,A).
    pub drm_fourcc: u32,
    /// The DRM modifier (`DRM_FORMAT_MOD_LINEAR` = 0 on the linear-tiling path).
    pub modifier: u64,
}

/// The inputs one export needs, built through the headless seam (K-175) so the
/// bridge can drive the exact egui exporter (`crate::export::start`): the footage
/// [`ItemInfo`] map, the comp's audio jobs, and a GPU context sharing the
/// renderer's device. Handed to the exporter, which spawns its own encode thread
/// (K-017).
pub struct ExportInputs {
    pub items: HashMap<Uuid, ItemInfo>,
    pub audio: Vec<AudioJob>,
    pub gpu: lumit_gpu::GpuContext,
}

impl HeadlessRenderer {
    /// Build a headless renderer, acquiring a GPU adapter and compiling the
    /// shader engines. `Err` when no adapter exists (the bridge turns this into
    /// its "no adapter" state) or the device request fails.
    pub fn new() -> Result<Self, String> {
        let gpu = lumit_gpu::GpuContext::headless().map_err(|e| e.to_string())?;
        let parts = Parts {
            colour: lumit_gpu::ColourEngine::new(&gpu),
            compositor: lumit_gpu::Compositor::new(&gpu),
            fx: lumit_gpu::fx::FxEngine::new(&gpu),
            flow: lumit_flow::FlowEngine::with_context(&gpu),
            lut_cache: std::cell::RefCell::new(HashMap::new()),
            decoders: HashMap::new(),
        };
        let scope = lumit_gpu::scope::ScopeEngine::new(&gpu);
        Ok(Self {
            gpu,
            parts: Some(parts),
            scope,
            items: HashMap::new(),
            probe_cache: HashMap::new(),
            audio_jobs: AudioJobsBuilder::new(),
            pool: DecodePool::new(),
            retained: None,
            #[cfg(all(windows, feature = "shared-texture"))]
            shared: None,
            #[cfg(all(target_os = "linux", feature = "shared-texture-linux"))]
            shared_dmabuf: None,
        })
    }

    /// Build the inputs one export of `comp_id` needs (the bridge's v0.4 export
    /// path, K-175): the footage [`ItemInfo`] map (probed exactly as a render
    /// probes, sharing this renderer's cache), the comp's audio jobs, and a GPU
    /// context sharing this renderer's device. `None` when `comp_id` is unknown.
    /// The exporter (`crate::export::start`) takes these and spawns its own
    /// encode thread (K-017), so this call is cheap and holds no GPU work.
    pub fn export_inputs(&mut self, doc: &Document, comp_id: Uuid) -> Option<ExportInputs> {
        let comp = doc.comp(comp_id)?;
        let (cw, ch) = (comp.width, comp.height);
        self.sync_items(doc, (cw, ch));
        let items = self.items.clone();
        let audio = self.collect_audio(doc, comp);
        // Share the device/queue (wgpu handles are reference-counted); the
        // exporter builds its own engines on top, exactly as the egui path's
        // `export_context` lends the display device.
        let gpu =
            lumit_gpu::GpuContext::from_parts(self.gpu.device.clone(), self.gpu.queue.clone());
        Some(ExportInputs { items, audio, gpu })
    }

    /// Collect `comp`'s audio jobs for export — see [`AudioJobsBuilder`], which
    /// this renderer holds so the has-audio probe cache warms across a session.
    fn collect_audio(&mut self, doc: &Document, comp: &Composition) -> Vec<AudioJob> {
        self.audio_jobs.audio_jobs(doc, comp)
    }

    /// The content-hash name of this comp frame ([`crate::cache::frame_key`]),
    /// computed from **this renderer's own** probe results so the name and the
    /// pixels can never disagree about what a source file is. `None` while some
    /// footage is unprobed — the frame renders live and is not cached.
    ///
    /// Takes `&mut self` because it probes anything new, exactly as a render
    /// would; a caller that then renders pays for the probe only once.
    pub fn frame_key(
        &mut self,
        doc: &Document,
        comp_id: Uuid,
        frame: u64,
        quality: Quality,
    ) -> Option<u128> {
        let comp = doc.comp(comp_id)?;
        let slate = (comp.width, comp.height);
        self.sync_items(doc, slate);
        let comp = doc.comp(comp_id)?;
        crate::cache::frame_key(
            doc,
            comp,
            frame as usize,
            quality,
            &ProbeView(&self.probe_cache),
        )
    }

    /// Composite one interactive frame and return the display-encoded GPU
    /// texture with the comp's dimensions — the shared body of both interactive
    /// entry points.
    ///
    /// Its callers differ only in what they do with the texture: read it back to
    /// bytes ([`Self::render_preview`]) or copy it into a texture the frontend
    /// samples directly ([`Self::render_preview_to_shared`]). So both show the
    /// same pixels, and both get the drag fast path.
    fn preview_display_texture(
        &mut self,
        doc: &Document,
        comp_id: Uuid,
        frame: u64,
        quality: Quality,
        retime_override: Option<&RetimeOverride>,
    ) -> Result<(wgpu::Texture, u32, u32), String> {
        self.preview_display_texture_fmt(doc, comp_id, frame, quality, retime_override, false)
    }

    /// [`Self::preview_display_texture`] with the output channel order chosen:
    /// `bgra` is for the shared-texture Viewer only (see `render_to_shared`).
    fn preview_display_texture_fmt(
        &mut self,
        doc: &Document,
        comp_id: Uuid,
        frame: u64,
        quality: Quality,
        retime_override: Option<&RetimeOverride>,
        bgra: bool,
    ) -> Result<(wgpu::Texture, u32, u32), String> {
        let comp = doc
            .comp(comp_id)
            .ok_or_else(|| "headless preview: unknown composition".to_string())?;
        let (cw, ch) = (comp.width, comp.height);
        // Fills `probe_cache` for anything new, which `ProbeView` then reads.
        self.sync_items(doc, (cw, ch));
        let fps = comp.frame_rate.fps().max(1.0);
        let t = frame as f64 / fps;

        let jobs = plan_comp_frame(
            doc,
            comp,
            t,
            quality,
            &ProbeView(&self.probe_cache),
            retime_override,
        );
        // The whole point: decode only when the wanted pixels actually differ.
        let reusable = matches!(
            &self.retained,
            Some(r) if r.comp == comp_id
                && r.frame == frame
                && crate::plan::same_decode(&r.jobs, &jobs)
        );
        if !reusable {
            let pixels = self
                .pool
                .decode_comp(comp_id, frame as usize, &jobs, 0)
                .map_err(|e| format!("headless preview: {e}"))?;
            self.retained = Some(Retained {
                comp: comp_id,
                frame,
                jobs,
                pixels,
            });
        }
        let Some(retained) = self.retained.as_ref() else {
            return Err("headless preview: no decoded pixels".into());
        };

        let Some(parts) = self.parts.take() else {
            return Err("headless preview: renderer is unavailable after an earlier fault".into());
        };
        let out = {
            let realiser = crate::realise::Realiser {
                ctx: lumit_gpu::GpuContext::from_parts(
                    self.gpu.device.clone(),
                    self.gpu.queue.clone(),
                ),
                engine: &parts.colour,
                compositor: &parts.compositor,
                fx: &parts.fx,
                lut_cache: &parts.lut_cache,
            };
            let pixels_by_layer: HashMap<Uuid, &crate::decode::CompLayerPixels> = retained
                .pixels
                .layers
                .iter()
                .map(|lp| (lp.layer, lp))
                .collect();
            let mut visited = vec![comp_id];
            let draws =
                crate::build::build_comp_draws(doc, comp, t, &pixels_by_layer, &mut visited);
            let background = comp.background.0.map(f64::from);
            let linear = realiser.realise(comp.camera_pose(t), cw, ch, background, &draws);
            Ok(if bgra {
                parts.colour.display_bgra(&self.gpu, &linear)
            } else {
                parts.colour.display(&self.gpu, &linear)
            })
        };
        // Return the engines to the pool even on error, so one failed frame does
        // not discard the compiled shaders.
        self.parts = Some(parts);
        out.map(|shown| (shown, cw, ch))
    }

    /// The interactive render: composition `comp_id` at integer `frame`, read
    /// back to tightly-packed RGBA8 as `(pixels, width, height)`.
    ///
    /// This is the path a Viewer should drive. Unlike [`Self::render_rgba`] it:
    ///
    /// - **decodes at the preview resolution** `quality` asks for, so a source
    ///   shown in a small viewport is decoded small rather than in full and then
    ///   thrown away;
    /// - **reuses the pixels it already has** whenever the decode plan has not
    ///   changed. Dragging a transform or effect value alters what is done with
    ///   the footage, never which frame of it is wanted, so a drag composites
    ///   from the retained pixels and touches no file at all. That is what makes
    ///   a value drag feel live rather than stuttery.
    ///
    /// `retime_override` is the one live edit that *does* change the decode — a
    /// Retime "Time" drag moves to a different source frame — so it is applied
    /// to the plan rather than patched into the document afterwards.
    ///
    /// The document handed in may be a throwaway with a drag's provisional value
    /// already patched in; nothing is cached against its identity here, so that
    /// costs nothing. `scale` shrinks the returned buffer for the trip back to
    /// the frontend only (see [`resize_output`]).
    ///
    /// A missing layer is drawn as colour bars by the compositor itself, so the
    /// returned buffer already carries the slate.
    pub fn render_preview(
        &mut self,
        doc: &Document,
        comp_id: Uuid,
        frame: u64,
        quality: Quality,
        scale: f32,
        retime_override: Option<&RetimeOverride>,
    ) -> Result<(Vec<u8>, u32, u32), String> {
        let (shown, cw, ch) =
            self.preview_display_texture(doc, comp_id, frame, quality, retime_override)?;
        let Some(parts) = self.parts.as_ref() else {
            return Err("headless preview: renderer is unavailable after an earlier fault".into());
        };

        // Reduce on the graphics card, before the read-back, not after it.
        //
        // This used to composite full size, copy the whole thing down into
        // ordinary memory — 8 MB per frame for a 1080p comp — and only then
        // resize on the processor. Both of those costs scaled with the *comp*,
        // not with what was actually being shown, so a Viewer at a third of comp
        // resolution paid full price for every frame. Now the read-back is
        // already the size the Viewer asked for.
        let (sw, sh) = scaled_size(cw, ch, scale);
        if (sw, sh) == (cw, ch) {
            return parts
                .colour
                .readback8(&self.gpu, &shown)
                .map(|rgba| (rgba, cw, ch))
                .map_err(|e| format!("headless preview: {e}"));
        }
        let reduced = parts.colour.display_scaled(&self.gpu, &shown, sw, sh);
        parts
            .colour
            .readback8(&self.gpu, &reduced)
            .map(|rgba| (rgba, sw, sh))
            .map_err(|e| format!("headless preview: {e}"))
    }

    /// How many comp frames the interactive path has actually decoded. A live
    /// value drag must not move this — that is the whole promise of
    /// [`Self::render_preview`], and the preview tests assert it here.
    #[must_use]
    pub fn decoded_frames(&self) -> u64 {
        self.pool.comp_decodes()
    }

    /// Forget the retained per-layer pixels. The next [`Self::render_preview`]
    /// decodes afresh. Called when something outside the document changes what
    /// the sources *are* — a probe landing, a relink — since the decode plan
    /// alone cannot see that.
    pub fn forget_retained(&mut self) {
        self.retained = None;
    }

    /// Resize the decoded-source-frame cache (Settings → Performance).
    pub fn set_decode_budget(&mut self, bytes: usize) {
        self.pool.set_budget(bytes);
    }

    /// Drop every cached decoded source frame and the retained pixels, keeping
    /// the open decoders (Settings → Clear cache).
    pub fn clear_decoded(&mut self) {
        self.pool.clear();
        self.retained = None;
    }

    /// Render composition `comp_id` at integer `frame` to tightly-packed RGBA8,
    /// returning `(pixels, width, height)`. `scale` of 1.0 is the comp's own
    /// resolution; a smaller positive `scale` downsamples the *output* (the
    /// internal composite is always full resolution — see the note below).
    ///
    /// The **export** path: every frame decodes afresh at full resolution and
    /// nothing is retained between calls. A Viewer wants
    /// [`Self::render_preview`] instead.
    ///
    /// The frame is `frame / fps` seconds of comp time, `fps` the comp's exact
    /// rational rate, exactly as export computes it. A missing layer inside the
    /// comp is drawn as colour bars by the compositor itself (the slate is baked
    /// into the composited frame, not painted around it), so the returned buffer
    /// already carries it — the Flutter Viewer needs no separate slate on the
    /// comp path.
    ///
    /// `scale` note: the export compositor renders at the comp's dimensions;
    /// there is no cheap reduced-resolution target on this path, so `scale`
    /// only resizes the finished buffer (a cheaper blit for the Viewer), it does
    /// not reduce the GPU cost. A future reduced-resolution preview render would
    /// change that.
    pub fn render_rgba(
        &mut self,
        doc: &Document,
        comp_id: Uuid,
        frame: u64,
        scale: f32,
    ) -> Result<(Vec<u8>, u32, u32), String> {
        let comp = doc
            .comp(comp_id)
            .ok_or_else(|| "headless render: unknown composition".to_string())?;
        let (cw, ch) = (comp.width, comp.height);
        self.sync_items(doc, (cw, ch));
        let fps = comp.frame_rate.fps().max(1.0);
        let t = frame as f64 / fps;

        let Some(parts) = self.parts.take() else {
            return Err("headless render: renderer is unavailable after an earlier fault".into());
        };
        let mut renderer = Renderer {
            doc,
            items: &self.items,
            gpu: &self.gpu,
            colour: parts.colour,
            compositor: parts.compositor,
            decoders: parts.decoders,
            flow: parts.flow,
            fx: parts.fx,
            lut_cache: parts.lut_cache,
        };
        // Drive the exact export path: composite to a linear texture, encode to
        // the display transfer function, read the bytes back (K-031).
        let mut visited = vec![comp_id];
        let out = render_to_rgba(
            &mut renderer,
            comp,
            t,
            &mut visited,
            &self.gpu,
            cw,
            ch,
            scale,
        );
        // Return the engines and warm decoders to the pool, even on error, so a
        // single failed frame does not discard the compiled shaders.
        self.parts = Some(Parts {
            colour: renderer.colour,
            compositor: renderer.compositor,
            fx: renderer.fx,
            flow: renderer.flow,
            lut_cache: renderer.lut_cache,
            decoders: renderer.decoders,
        });
        out
    }

    /// Compute a scope trace (waveform/vectorscope/histogram, K-096 v1) from an
    /// already-rendered comp frame's display bytes, returning the `GRID × GRID`
    /// RGBA8 trace. `rgba` is the exact frame the Viewer shows (served from the
    /// bridge's rendered-frame cache, so the scope traces the same frame at no
    /// re-render cost); the binning runs on the GPU and only the tiny trace is
    /// read back.
    ///
    /// `kind` is `0` luma / `1` RGB waveform / `2` vectorscope / `3` histogram
    /// (an unknown value is a calm `Err`); `colours` carries the frontend's fixed
    /// `ScopeColours` as `[bg, trace, red, green, blue]` RGB byte triples, so no
    /// colour literal lives in the engine (docs/15-DESIGN.md) and the bridge need
    /// not name `lumit-gpu`. `Err` on an unknown kind or if the tiny readback
    /// fails.
    pub fn render_scope(
        &self,
        rgba: &[u8],
        width: u32,
        height: u32,
        kind: u32,
        colours: [[u8; 3]; 5],
    ) -> Result<Vec<u8>, String> {
        let kind = match kind {
            0 => lumit_gpu::scope::ScopeKind::WaveformLuma,
            1 => lumit_gpu::scope::ScopeKind::WaveformRgb,
            2 => lumit_gpu::scope::ScopeKind::Vectorscope,
            3 => lumit_gpu::scope::ScopeKind::Histogram,
            other => return Err(format!("headless scope: unknown kind {other}")),
        };
        let colours = lumit_gpu::scope::ScopeColours {
            bg: colours[0],
            trace: colours[1],
            red: colours[2],
            green: colours[3],
            blue: colours[4],
        };
        self.scope
            .trace_rgba8(&self.gpu, kind, colours, rgba, width, height)
            .map_err(|e| e.to_string())
    }

    /// Render composition `comp_id` at integer `frame` into the Windows shared
    /// GPU texture, returning its NT handle and dimensions ([`SharedFrameInfo`],
    /// K-177) — the zero-copy sibling of [`Self::render_preview`]. The frame
    /// never leaves the graphics card: it is composited and display-encoded by
    /// the identical interactive path, then copied GPU-to-GPU into the shared
    /// texture instead of being read back to the CPU.
    ///
    /// Because it shares that path it also shares the drag fast path: on the
    /// shipped Windows build, dragging a value re-composites and copies without
    /// decoding or reading anything back at all.
    ///
    /// The shared texture is created on the first call and re-used across frames
    /// (a stable handle); a comp of different dimensions re-creates it and reports
    /// the new handle. `Err` on an unknown comp, when wgpu is not on the D3D12
    /// backend, or any D3D interop failure — the bridge turns that into "no
    /// shared frame" and Dart falls back to the read-back path.
    #[cfg(all(windows, feature = "shared-texture"))]
    pub fn render_to_shared(
        &mut self,
        doc: &Document,
        comp_id: Uuid,
        frame: u64,
        quality: Quality,
    ) -> Result<SharedFrameInfo, String> {
        // BGRA, not the RGBA every other path uses: the shared texture's
        // consumer is ANGLE, which only opens BGRA share-handle surfaces.
        let (shown, cw, ch) =
            self.preview_display_texture_fmt(doc, comp_id, frame, quality, None, true)?;
        // Re-create the shared texture when it is missing or the comp changed
        // size — a new handle is reported then, which the bridge relays so Dart
        // re-registers.
        let needs_new = match self.shared.as_ref() {
            Some(sh) => sh.width != cw || sh.height != ch,
            None => true,
        };
        if needs_new {
            self.shared = Some(lumit_gpu::shared::SharedTexture::new(&self.gpu, cw, ch)?);
        }
        let target = self
            .shared
            .as_ref()
            .ok_or_else(|| "headless render: shared texture missing after create".to_string())?;
        target.present(&self.gpu, &shown);
        Ok(SharedFrameInfo {
            handle: target.handle(),
            width: cw,
            height: ch,
            format: "rgba8888",
        })
    }

    /// Render composition `comp_id` at integer `frame` into the Linux DMA-BUF GPU
    /// texture, returning its exported fd and DRM metadata ([`SharedFrameInfoLinux`],
    /// K-177) — the Linux sibling of [`Self::render_to_shared`]. The frame never
    /// leaves the graphics card: it is composited and display-encoded by the same
    /// interactive path (so it shares the drag fast path), then copied into the
    /// DMA-BUF texture instead of being read back.
    ///
    /// The texture is created on the first call and re-used across frames (a
    /// stable fd); a comp of different dimensions re-creates it and reports the new
    /// fd. `Err` on an unknown comp, when wgpu is not on the Vulkan backend, when
    /// the external-memory extensions were not enabled, or any Vulkan failure — the
    /// bridge turns that into "no shared frame" and Dart falls back to read-back.
    #[cfg(all(target_os = "linux", feature = "shared-texture-linux"))]
    pub fn render_to_shared_dmabuf(
        &mut self,
        doc: &Document,
        comp_id: Uuid,
        frame: u64,
        quality: Quality,
    ) -> Result<SharedFrameInfoLinux, String> {
        let (shown, cw, ch) = self.preview_display_texture(doc, comp_id, frame, quality, None)?;
        // Re-create the DMA-BUF texture when it is missing or the comp changed
        // size — a new fd is reported then, which the bridge relays so Dart
        // re-registers.
        let needs_new = match self.shared_dmabuf.as_ref() {
            Some(sh) => sh.width != cw || sh.height != ch,
            None => true,
        };
        if needs_new {
            self.shared_dmabuf = Some(lumit_gpu::shared_linux::SharedDmabuf::new(
                &self.gpu, cw, ch,
            )?);
        }
        let target = self
            .shared_dmabuf
            .as_ref()
            .ok_or_else(|| "headless render: dmabuf texture missing after create".to_string())?;
        target.present(&self.gpu, &shown);
        let info = target.info();
        Ok(SharedFrameInfoLinux {
            fd: info.fd,
            width: info.width,
            height: info.height,
            stride: info.stride,
            offset: info.offset,
            drm_fourcc: info.drm_fourcc,
            modifier: info.modifier,
        })
    }

    /// Rebuild the `ItemInfo` map from the document's footage, probing any item
    /// not already in `probe_cache`. Slate items are sized to `slate` (the
    /// comp's dimensions this call), matching export's `item_infos`.
    fn sync_items(&mut self, doc: &Document, slate: (u32, u32)) {
        self.items.clear();
        for item in &doc.items {
            let ProjectItem::Footage(f) = item else {
                continue;
            };
            let probe = self
                .probe_cache
                .entry(f.id)
                .or_insert_with(|| probe_item(&footage_path(f)));
            match probe {
                Probe::Ok { fps, frames, .. } => {
                    self.items.insert(
                        f.id,
                        ItemInfo {
                            path: footage_path(f),
                            fps: *fps,
                            frames: *frames,
                            missing: None,
                        },
                    );
                }
                // A slate item carries the comp's size so its geometry matches a
                // real layer's (the same reasoning export's `ItemInfo::missing`
                // documents). A `Failed` file in export is simply absent from the
                // map; here it slates instead, so an unreadable source is visibly
                // flagged in the Viewer rather than silently dropped.
                Probe::Slate => {
                    self.items.insert(
                        f.id,
                        ItemInfo {
                            path: footage_path(f),
                            fps: 1.0,
                            frames: 1,
                            missing: Some(slate),
                        },
                    );
                }
                // Audio-only media has no picture to composite: leave it out of
                // the map entirely, exactly as export's `item_infos` does, so
                // `footage_rgba` answers `Ok(None)` for it and the layer draws
                // nothing rather than the missing-footage slate.
                Probe::NoVideo => {}
            }
        }
    }
}

/// The comp audio-jobs walk WITHOUT the GPU renderer — the seam audio playback
/// prepares through, so building a mix never queues behind a slow comp render.
///
/// # In plain terms
///
/// "Which layers make sound, and where do they land on the timeline?" needs no
/// graphics card to answer — only the document and a quick look at each media
/// file (does it carry an audio stream?). [`HeadlessRenderer`] used to own this
/// walk, which meant asking for audio jobs meant owning a whole GPU renderer;
/// now the walk stands alone and the renderer simply holds one of these. The
/// bridge's audio-playback path holds its own, so preparing sound never waits
/// for a picture.
///
/// It is the headless twin of `AppState::comp_audio_jobs` (docs/09 §6): every
/// audible footage layer with an audio stream, its span mapped to the comp
/// timeline, plus nested Precomp layers' contents scaled by their carrier
/// Volumes. Solo silences non-soloed audio per comp, exactly as the video gate
/// does. The has-audio probe result is cached per item, so each file is probed
/// at most once per session.
#[derive(Default)]
pub struct AudioJobsBuilder {
    /// Whether each footage item carries an audio stream, cached so each file
    /// is probed at most once.
    has_audio: HashMap<Uuid, bool>,
}

impl AudioJobsBuilder {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// The comp's audio jobs (empty for a silent comp) — the same list export,
    /// beat detection and playback all mix from, so they cannot disagree about
    /// what the comp sounds like.
    pub fn audio_jobs(&mut self, doc: &Document, comp: &Composition) -> Vec<AudioJob> {
        let mut jobs = Vec::new();
        let mut visited = vec![comp.id];
        self.walk(
            doc,
            comp,
            0.0,
            (f64::NEG_INFINITY, f64::INFINITY),
            &[],
            &mut visited,
            &mut jobs,
        );
        jobs
    }

    #[allow(clippy::too_many_arguments)]
    fn walk(
        &mut self,
        doc: &Document,
        comp: &Composition,
        base_s: f64,
        window: (f64, f64),
        carriers: &[(lumit_core::anim::Property, f64)],
        visited: &mut Vec<Uuid>,
        jobs: &mut Vec<AudioJob>,
    ) {
        let any_solo = lumit_core::model::any_solo(comp);
        for layer in &comp.layers {
            if !layer.switches.audible || (any_solo && !layer.switches.solo) {
                continue;
            }
            let in_s = (layer.in_point.0.to_f64() + base_s).max(window.0);
            let out_s = (layer.out_point.0.to_f64() + base_s).min(window.1);
            if out_s <= in_s {
                continue;
            }
            let offset_s = layer.start_offset.0.to_f64() + base_s;
            match &layer.kind {
                LayerKind::Footage { item, .. } => {
                    let Some(ProjectItem::Footage(f)) = doc.item(*item) else {
                        continue;
                    };
                    if !self.item_has_audio(*item, &footage_path(f)) {
                        continue;
                    }
                    jobs.push(AudioJob {
                        item: *item,
                        path: footage_path(f),
                        in_s,
                        out_s,
                        offset_s,
                        volume: layer.volume_db.clone(),
                        carriers: carriers.to_vec(),
                    });
                }
                LayerKind::Precomp { comp: nested_id } => {
                    if visited.contains(nested_id) {
                        continue;
                    }
                    let Some(nested) = doc.comp(*nested_id) else {
                        continue;
                    };
                    let mut inner = carriers.to_vec();
                    inner.push((layer.volume_db.clone(), offset_s));
                    visited.push(*nested_id);
                    self.walk(doc, nested, offset_s, (in_s, out_s), &inner, visited, jobs);
                    visited.pop();
                }
                _ => {}
            }
        }
    }

    /// Whether footage `item` at `path` carries an audio stream, cached so each
    /// file is probed for audio at most once across a session.
    fn item_has_audio(&mut self, item: Uuid, path: &Path) -> bool {
        if let Some(&has) = self.has_audio.get(&item) {
            return has;
        }
        let has = path.is_file()
            && lumit_media::probe::probe(path)
                .map(|p| p.audio.is_some())
                .unwrap_or(false);
        self.has_audio.insert(item, has);
        has
    }
}

/// Composite once and read the pixels back at the output `scale`.
/// Split out so `render_rgba` can restore the engine pool on either arm.
#[allow(clippy::too_many_arguments)]
fn render_to_rgba(
    renderer: &mut Renderer,
    comp: &lumit_core::model::Composition,
    t: f64,
    visited: &mut Vec<Uuid>,
    gpu: &lumit_gpu::GpuContext,
    width: u32,
    height: u32,
    scale: f32,
) -> Result<(Vec<u8>, u32, u32), String> {
    let linear = renderer.render_comp_linear(comp, t, visited)?;
    let (sw, sh) = scaled_size(width, height, scale);
    // Reduced on the card before the read-back, as in `render_preview`.
    let shown = if (sw, sh) == (width, height) {
        renderer.colour.display(gpu, &linear)
    } else {
        renderer.colour.display_scaled(gpu, &linear, sw, sh)
    };
    let rgba = renderer
        .colour
        .readback8(gpu, &shown)
        .map_err(|e| e.to_string())?;
    Ok((rgba, sw, sh))
}

/// This is a **transfer** saving, not a render saving: the composite has already
/// happened at the comp's own size. The saving that reduces real work is the
/// decode width, which [`crate::plan::Quality`] controls. The resize preserves
/// aspect (a same-aspect target, so no letterbox bars appear) and reuses the
/// export path's bilinear resampler, so both render paths downsample alike.
/// The size a preview at `scale` should come back at, and so the size it is
/// reduced to on the graphics card before the read-back.
///
/// The rounding is the same the processor-side resize used before this moved to
/// the card, so nothing downstream sees a different answer than it used to.
fn scaled_size(width: u32, height: u32, scale: f32) -> (u32, u32) {
    if !scale.is_finite() || scale <= 0.0 || (scale - 1.0).abs() < 1e-4 {
        return (width, height);
    }
    (
        ((width as f32 * scale).round() as u32).max(1),
        ((height as f32 * scale).round() as u32).max(1),
    )
}

/// The on-disk path a footage item points at (absolute when known, else the
/// stored relative path) — the same resolution the bridge's decode path uses.
fn footage_path(f: &FootageItem) -> PathBuf {
    if f.media.absolute_path.is_empty() {
        PathBuf::from(&f.media.relative_path)
    } else {
        PathBuf::from(&f.media.absolute_path)
    }
}

/// Probe one footage path into a [`Probe`]. A path that is not a file, an
/// unreadable file, or one whose frame index will not build falls to
/// [`Probe::Slate`] — none of them is an error, they are the states the slate
/// exists for. A readable file with no video stream (audio-only) is
/// [`Probe::NoVideo`] instead: also not an error, but the opposite treatment —
/// no slate, no picture at all, since flagging a valid audio-only source as
/// "missing" would be actively wrong. A clean video caches its exact rate and
/// frame count, warming the on-disk frame index so the decoder open reuses it.
fn probe_item(path: &Path) -> Probe {
    if !path.is_file() {
        return Probe::Slate;
    }
    let Ok(probe) = lumit_media::probe::probe(path) else {
        return Probe::Slate;
    };
    let Some(video) = probe.video.as_ref() else {
        return Probe::NoVideo;
    };
    let Some(index) = load_or_build_index(path) else {
        return Probe::Slate;
    };
    Probe::Ok {
        fps: video.fps(),
        frames: index.frame_count(),
        width: video.width,
        height: video.height,
    }
}

/// The renderer's own probe cache, seen through the pipeline's one media
/// question ([`SourceProbes`]), so the decode planner and the frame-key stamper
/// read exactly what `sync_items` already resolved — no second probe, and no
/// chance of the two disagreeing about what a file is.
pub(crate) struct ProbeView<'a>(&'a HashMap<Uuid, Probe>);

impl SourceProbes for ProbeView<'_> {
    fn probe(&self, item: Uuid) -> SourceProbe {
        match self.0.get(&item) {
            None => SourceProbe::Unprobed,
            Some(Probe::NoVideo) => SourceProbe::AudioOnly,
            Some(Probe::Slate) => SourceProbe::Missing,
            Some(Probe::Ok {
                fps,
                frames,
                width,
                height,
            }) => SourceProbe::Video {
                fps: *fps,
                width: *width,
                height: *height,
                frames: *frames,
                // The has-audio question is answered by `AudioJobsBuilder`,
                // which probes for it separately; the picture path never asks.
                audio: false,
            },
        }
    }
}

/// Load the cached frame index for `path` if one matches, else build it and try
/// to cache it — the same warm-the-cache dance the bridge's decode path runs, so
/// the count here and the decoder the renderer opens share one index. `None`
/// when the index cannot be built.
fn load_or_build_index(path: &Path) -> Option<lumit_media::FrameIndex> {
    let cache_dir = lumit_project::media_index_dir();
    if let (Some(dir), Ok(fp)) = (&cache_dir, lumit_media::Fingerprint::of(path)) {
        if let Some(index) = lumit_media::FrameIndex::load_cached(dir, &fp) {
            return Some(index);
        }
    }
    let index = lumit_media::index::build_frame_index(path).ok()?;
    if let Some(dir) = &cache_dir {
        let _ = index.save_to(dir);
    }
    Some(index)
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use lumit_core::anim::Property;
    use lumit_core::model::{
        Composition, LayerKind, LinearColour, ProjectItem, SolidDef, Switches, TransformGroup,
    };
    use lumit_core::store::DocumentStore;
    use lumit_core::time::{CompTime, Duration, FrameRate, Rational};

    /// The size a scaled preview comes back at, which is now also the size that
    /// is copied off the graphics card. The rounding matches what the
    /// processor-side resize did, so nothing downstream sees a different answer
    /// than it used to.
    #[test]
    fn a_scaled_preview_reports_the_reduced_size() {
        assert_eq!(scaled_size(1920, 1080, 0.5), (960, 540));
        assert_eq!(scaled_size(1920, 1080, 1.0 / 3.0), (640, 360));
        // Rounded, not truncated.
        assert_eq!(scaled_size(1919, 1081, 0.5), (960, 541));
    }

    /// Full scale must stay bit-identical: it takes the untouched path, with no
    /// resampling pass at all.
    #[test]
    fn full_scale_is_left_alone() {
        assert_eq!(scaled_size(1920, 1080, 1.0), (1920, 1080));
        // And nonsense is treated as full rather than producing a 0-wide frame.
        assert_eq!(scaled_size(1920, 1080, 0.0), (1920, 1080));
        assert_eq!(scaled_size(1920, 1080, f32::NAN), (1920, 1080));
        assert_eq!(scaled_size(1920, 1080, -1.0), (1920, 1080));
    }

    /// A scale small enough to round to nothing still has to produce a frame.
    #[test]
    fn a_tiny_scale_still_has_a_pixel() {
        assert_eq!(scaled_size(100, 100, 0.001), (1, 1));
    }

    /// A transform that centres a `w`×`h` object over a `w`×`h` comp (anchor at
    /// the object's middle, position at the comp's middle) — a copy of the
    /// engine's `centred_transform`, so the solid fills the frame.
    fn centred(w: u32, h: u32) -> TransformGroup {
        TransformGroup {
            anchor_x: Property::fixed(f64::from(w) * 0.5),
            anchor_y: Property::fixed(f64::from(h) * 0.5),
            position_x: Property::fixed(f64::from(w) * 0.5),
            position_y: Property::fixed(f64::from(h) * 0.5),
            ..Default::default()
        }
    }

    /// Build a document with one comp holding a single full-frame solid layer of
    /// `colour`, returning the store and the comp id. Drives the real model, so
    /// the render walks the same path a user-built comp would.
    fn doc_with_solid(colour: LinearColour, w: u32, h: u32) -> (DocumentStore, Uuid) {
        let mut doc = Document::new();
        let solid_id = Uuid::now_v7();
        doc.items.push(ProjectItem::Solid(SolidDef {
            id: solid_id,
            name: "Solid".into(),
            colour,
            width: w,
            height: h,
            extra: serde_json::Map::new(),
        }));
        let comp_id = Uuid::now_v7();
        let layer = lumit_core::model::Layer {
            id: Uuid::now_v7(),
            name: "Solid".into(),
            kind: LayerKind::Solid { def: solid_id },
            in_point: CompTime(Rational::new(0, 1).unwrap()),
            out_point: CompTime(Rational::new(5, 1).unwrap()),
            start_offset: CompTime(Rational::new(0, 1).unwrap()),
            transform: centred(w, h),
            matte: None,
            parent: None,
            label: 0,
            volume_db: lumit_core::anim::Property::zero(),
            blend: Default::default(),
            masks: Vec::new(),
            effects: Vec::new(),
            switches: Switches::default(),
            extra: serde_json::Map::new(),
        };
        doc.items.push(ProjectItem::Composition(Composition {
            id: comp_id,
            name: "Scene".into(),
            width: w,
            height: h,
            frame_rate: FrameRate::new(30, 1).unwrap(),
            duration: Duration(Rational::new(5, 1).unwrap()),
            background: LinearColour::BLACK,
            work_area: None,
            layers: vec![layer],
            markers: Vec::new(),
            motion_blur: lumit_core::model::MotionBlur::default(),
            extra: serde_json::Map::new(),
        }));
        (DocumentStore::new(doc), comp_id)
    }

    /// A full-frame red solid composites to red in the centre pixel — the GPU
    /// oracle that proves the headless seam drives the real compositor. Skips
    /// when the machine has no adapter (the lavapipe/hardware convention the
    /// lumit-gpu tests use).
    #[test]
    fn solid_comp_renders_its_colour_in_the_centre() {
        let mut r = match HeadlessRenderer::new() {
            Ok(r) => r,
            Err(_) => {
                eprintln!("skipping: no GPU adapter");
                return;
            }
        };
        // Pure-red scene-linear solid, 8×8.
        let (store, comp_id) = doc_with_solid(LinearColour([1.0, 0.0, 0.0, 1.0]), 8, 8);
        let doc = store.snapshot();
        let (rgba, w, h) = r.render_rgba(&doc, comp_id, 0, 1.0).expect("render");
        assert_eq!((w, h), (8, 8));
        assert_eq!(rgba.len(), (w * h * 4) as usize);
        // Centre pixel: strongly red, weak green/blue, opaque. sRGB-encoded, so
        // the exact byte depends on the transfer function; assert the channel
        // ordering and that red dominates rather than an exact value.
        let idx = (((h / 2) * w + w / 2) * 4) as usize;
        let (red, green, blue, alpha) = (rgba[idx], rgba[idx + 1], rgba[idx + 2], rgba[idx + 3]);
        assert!(red > 200, "red channel should dominate, got {red}");
        assert!(green < 60, "green should be low, got {green}");
        assert!(blue < 60, "blue should be low, got {blue}");
        assert_eq!(alpha, 255, "the solid is opaque");
    }

    /// `scale` below 1 downsamples the output buffer; the centre stays the solid
    /// colour, proving the resize path is wired and does not corrupt the frame.
    #[test]
    fn scale_downsamples_the_output() {
        let mut r = match HeadlessRenderer::new() {
            Ok(r) => r,
            Err(_) => {
                eprintln!("skipping: no GPU adapter");
                return;
            }
        };
        let (store, comp_id) = doc_with_solid(LinearColour([0.0, 1.0, 0.0, 1.0]), 16, 16);
        let doc = store.snapshot();
        let (rgba, w, h) = r.render_rgba(&doc, comp_id, 0, 0.5).expect("render");
        assert_eq!((w, h), (8, 8), "half scale halves each dimension");
        assert_eq!(rgba.len(), (w * h * 4) as usize);
        let idx = (((h / 2) * w + w / 2) * 4) as usize;
        assert!(rgba[idx + 1] > 200, "green solid stays green after resize");
    }

    /// Audio-only media (a readable file with no video stream) must not draw
    /// the missing-footage slate: it is a valid source, not a broken one. Bugs
    /// here previously conflated the two (`Probe::Slate`), which painted the
    /// colour bars over a perfectly good audio-only layer in the Flutter
    /// Viewer. Bypasses real FFmpeg probing by seeding `probe_cache` directly
    /// with the outcome `probe_item` would give each file, so the test needs
    /// no media fixture. A genuinely missing file is asserted to still slate,
    /// so a regression collapsing `NoVideo` back onto `Slate` fails this test.
    #[test]
    fn audio_only_media_is_omitted_not_slated() {
        let mut r = match HeadlessRenderer::new() {
            Ok(r) => r,
            Err(_) => {
                eprintln!("skipping: no GPU adapter");
                return;
            }
        };
        let (store, _comp_id) = doc_with_solid(LinearColour([1.0, 1.0, 1.0, 1.0]), 4, 4);
        let mut doc = (*store.snapshot()).clone();

        let audio_id = Uuid::now_v7();
        doc.items
            .push(ProjectItem::Footage(lumit_core::model::FootageItem {
                id: audio_id,
                name: "audio.wav".into(),
                media: lumit_core::model::MediaRef {
                    relative_path: "audio.wav".into(),
                    absolute_path: "audio.wav".into(),
                    fingerprint: None,
                    extra: serde_json::Map::new(),
                },
                extra: serde_json::Map::new(),
            }));
        r.probe_cache.insert(audio_id, Probe::NoVideo);
        r.sync_items(&doc, (64, 64));
        assert!(
            !r.items.contains_key(&audio_id),
            "audio-only media must contribute no picture, not a missing slate"
        );

        // Contrast: a genuinely missing/unreadable file DOES slate.
        let missing_id = Uuid::now_v7();
        doc.items
            .push(ProjectItem::Footage(lumit_core::model::FootageItem {
                id: missing_id,
                name: "gone.mp4".into(),
                media: lumit_core::model::MediaRef {
                    relative_path: "gone.mp4".into(),
                    absolute_path: "gone.mp4".into(),
                    fingerprint: None,
                    extra: serde_json::Map::new(),
                },
                extra: serde_json::Map::new(),
            }));
        r.probe_cache.insert(missing_id, Probe::Slate);
        r.sync_items(&doc, (64, 64));
        assert_eq!(
            r.items.get(&missing_id).map(|i| i.missing),
            Some(Some((64, 64))),
            "a missing/unreadable file still slates at the comp's size"
        );
        // The audio-only item stays omitted across the second sync_items call.
        assert!(!r.items.contains_key(&audio_id));
    }

    /// The zero-copy path (K-177) renders a real comp into a shared GPU texture
    /// and reports a non-zero NT handle whose dimensions are stable across two
    /// frames (the texture is re-used, not re-created). Skips when there is no
    /// GPU adapter; also skips calmly if this machine's wgpu is not on the D3D12
    /// backend (the shared path needs D3D12 — the read-back path still works).
    #[cfg(all(windows, feature = "shared-texture"))]
    #[test]
    fn solid_comp_renders_to_a_stable_shared_handle() {
        let mut r = match HeadlessRenderer::new() {
            Ok(r) => r,
            Err(_) => {
                eprintln!("skipping: no GPU adapter");
                return;
            }
        };
        let (store, comp_id) = doc_with_solid(LinearColour([0.0, 0.0, 1.0, 1.0]), 32, 16);
        let doc = store.snapshot();
        let first = match r.render_to_shared(&doc, comp_id, 0, crate::plan::Quality::default()) {
            Ok(info) => info,
            Err(e) => {
                // e.g. wgpu chose Vulkan over D3D12, or no shared-heap support.
                eprintln!("skipping: shared texture unavailable here: {e}");
                return;
            }
        };
        assert_ne!(first.handle, 0, "a shared render yields a non-zero handle");
        assert_eq!((first.width, first.height), (32, 16));
        assert_eq!(first.format, "rgba8888");

        // A second frame re-uses the same texture: same dimensions, same handle.
        let second = r
            .render_to_shared(&doc, comp_id, 1, crate::plan::Quality::default())
            .expect("second shared render");
        assert_eq!((second.width, second.height), (32, 16));
        assert_eq!(
            second.handle, first.handle,
            "the handle is stable while the comp size is unchanged"
        );
    }

    /// An unknown comp id on the shared path is a calm error, never a panic.
    #[cfg(all(windows, feature = "shared-texture"))]
    #[test]
    fn unknown_comp_is_an_error_on_the_shared_path() {
        let mut r = match HeadlessRenderer::new() {
            Ok(r) => r,
            Err(_) => {
                eprintln!("skipping: no GPU adapter");
                return;
            }
        };
        let (store, _comp_id) = doc_with_solid(LinearColour([1.0, 1.0, 1.0, 1.0]), 4, 4);
        let doc = store.snapshot();
        assert!(r
            .render_to_shared(&doc, Uuid::now_v7(), 0, crate::plan::Quality::default())
            .is_err());
    }

    /// The audio-jobs builder needs no GPU: a comp holding a solid (no sound)
    /// and a footage layer whose file is not on disk yields no jobs, calmly,
    /// and the has-audio probe result is cached so the file is checked once.
    #[test]
    fn audio_jobs_builder_needs_no_gpu_and_caches_the_probe() {
        let (store, comp_id) = doc_with_solid(LinearColour([1.0, 0.0, 0.0, 1.0]), 8, 8);
        let mut doc = (*store.snapshot()).clone();
        // Add a footage item + an audible layer pointing at a missing file.
        let item_id = Uuid::now_v7();
        doc.items
            .push(ProjectItem::Footage(lumit_core::model::FootageItem {
                id: item_id,
                name: "gone.mp4".into(),
                media: lumit_core::model::MediaRef {
                    relative_path: "gone.mp4".into(),
                    absolute_path: "Z:/definitely/not/here/gone.mp4".into(),
                    fingerprint: None,
                    extra: serde_json::Map::new(),
                },
                extra: serde_json::Map::new(),
            }));
        if let Some(ProjectItem::Composition(c)) = doc
            .items
            .iter_mut()
            .find(|i| matches!(i, ProjectItem::Composition(_)))
        {
            c.layers.push(lumit_core::model::Layer {
                id: Uuid::now_v7(),
                name: "gone.mp4".into(),
                kind: LayerKind::Footage {
                    item: item_id,
                    retime: None,
                },
                in_point: CompTime(Rational::new(0, 1).unwrap()),
                out_point: CompTime(Rational::new(5, 1).unwrap()),
                start_offset: CompTime(Rational::new(0, 1).unwrap()),
                transform: TransformGroup::default(),
                matte: None,
                parent: None,
                label: 0,
                volume_db: Property::zero(),
                blend: Default::default(),
                masks: Vec::new(),
                effects: Vec::new(),
                switches: Switches::default(),
                extra: serde_json::Map::new(),
            });
        }
        let comp = doc.comp(comp_id).unwrap().clone();
        let mut builder = AudioJobsBuilder::new();
        assert!(builder.audio_jobs(&doc, &comp).is_empty());
        assert_eq!(builder.has_audio.len(), 1, "the probe result is cached");
        assert_eq!(builder.has_audio.get(&item_id), Some(&false));
        // A second build reads the cache (no way to observe the skipped disk
        // probe directly, but the cached map must not grow).
        assert!(builder.audio_jobs(&doc, &comp).is_empty());
        assert_eq!(builder.has_audio.len(), 1);
    }

    /// An unknown comp id is a calm error, never a panic.
    #[test]
    fn unknown_comp_is_an_error() {
        let mut r = match HeadlessRenderer::new() {
            Ok(r) => r,
            Err(_) => {
                eprintln!("skipping: no GPU adapter");
                return;
            }
        };
        let (store, _comp_id) = doc_with_solid(LinearColour([1.0, 1.0, 1.0, 1.0]), 4, 4);
        let doc = store.snapshot();
        let err = r.render_rgba(&doc, Uuid::now_v7(), 0, 1.0);
        assert!(err.is_err(), "an unknown comp id yields an error");
    }

    /// **The drag contract.** Re-rendering the same frame of a document whose
    /// only difference is a dragged value must not decode again: the pixels are
    /// the same, only what is done with them changed. This is the whole reason
    /// the interactive path exists, so it is asserted on the decode counter
    /// rather than on timing.
    ///
    /// Moving to a different frame *must* decode, or the fast path would be
    /// serving stale pixels — so that is asserted in the same test, which means
    /// a regression that simply never decodes cannot pass it.
    #[test]
    fn a_value_drag_recomposites_without_decoding_again() {
        let mut r = match HeadlessRenderer::new() {
            Ok(r) => r,
            Err(_) => {
                eprintln!("skipping: no GPU adapter");
                return;
            }
        };
        let (store, comp_id) = doc_with_solid(LinearColour([0.0, 0.0, 1.0, 1.0]), 16, 16);
        let doc = store.snapshot();
        let q = crate::plan::Quality::default();

        r.render_preview(&doc, comp_id, 0, q, 1.0, None)
            .expect("first");
        let after_first = r.decoded_frames();
        assert_eq!(after_first, 1, "the first frame decodes");

        // Ten drag ticks, each a throwaway document with a provisional value —
        // exactly what a frontend hands in while a slider is held.
        let layer = doc.comp(comp_id).expect("comp").layers[0].id;
        for tick in 1..=10 {
            let comp = doc.comp(comp_id).expect("comp");
            let patched = crate::build::patch_layer_prop(
                comp,
                layer,
                lumit_core::model::TransformProp::Rotation,
                f64::from(tick) * 3.0,
            );
            let mut dragging = (*doc).clone();
            for item in &mut dragging.items {
                if let ProjectItem::Composition(c) = item {
                    if c.id == comp_id {
                        *c = patched.clone();
                    }
                }
            }
            r.render_preview(&dragging, comp_id, 0, q, 1.0, None)
                .expect("drag tick");
        }
        assert_eq!(
            r.decoded_frames(),
            after_first,
            "ten drag ticks must decode nothing — the pixels never changed"
        );

        // A different frame is genuinely different pixels, so it decodes.
        r.render_preview(&doc, comp_id, 1, q, 1.0, None)
            .expect("frame 1");
        assert_eq!(
            r.decoded_frames(),
            after_first + 1,
            "moving the playhead must decode"
        );
    }

    /// The interactive path renders the same picture the export path does — the
    /// K-031 promise, checked on the one comp both can build without media. A
    /// solid is enough to catch a wrong background, colour pipeline or camera:
    /// those are the parts the two walks each implement separately.
    #[test]
    fn the_preview_and_export_paths_agree_on_a_solid_comp() {
        let mut r = match HeadlessRenderer::new() {
            Ok(r) => r,
            Err(_) => {
                eprintln!("skipping: no GPU adapter");
                return;
            }
        };
        let (store, comp_id) = doc_with_solid(LinearColour([0.2, 0.7, 0.4, 1.0]), 32, 16);
        let doc = store.snapshot();

        let (preview, pw, ph) = r
            .render_preview(&doc, comp_id, 0, crate::plan::Quality::default(), 1.0, None)
            .expect("preview render");
        let (export, ew, eh) = r.render_rgba(&doc, comp_id, 0, 1.0).expect("export render");

        assert_eq!((pw, ph), (ew, eh), "both paths render at the comp's size");
        assert_eq!(
            preview, export,
            "the interactive and export paths must produce identical pixels (K-031)"
        );
    }

    /// One layer for the matrix scenarios: full-frame span, centred over its
    /// own natural size, everything else the model's defaults.
    fn matrix_layer(name: &str, kind: LayerKind, w: u32, h: u32) -> lumit_core::model::Layer {
        lumit_core::model::Layer {
            id: Uuid::now_v7(),
            name: name.into(),
            kind,
            in_point: CompTime(Rational::new(0, 1).unwrap()),
            out_point: CompTime(Rational::new(5, 1).unwrap()),
            start_offset: CompTime(Rational::new(0, 1).unwrap()),
            transform: centred(w, h),
            matte: None,
            parent: None,
            label: 0,
            volume_db: Property::zero(),
            blend: Default::default(),
            masks: Vec::new(),
            effects: Vec::new(),
            switches: Switches::default(),
            extra: serde_json::Map::new(),
        }
    }

    /// A two-key linear ramp, for rows that need genuine animation (motion
    /// blur's sub-frame samples, the temporal re-render's held time).
    fn ramp(from: f64, to: f64, over_s: i64) -> Property {
        use lumit_core::anim::{Animation, Keyframe, SideInterp};
        Property {
            animation: Animation::Keyframed(vec![
                Keyframe {
                    time: Rational::new(0, 1).unwrap(),
                    value: from,
                    interp_in: SideInterp::Linear,
                    interp_out: SideInterp::Linear,
                },
                Keyframe {
                    time: Rational::new(over_s, 1).unwrap(),
                    value: to,
                    interp_in: SideInterp::Linear,
                    interp_out: SideInterp::Linear,
                },
            ]),
            extra: serde_json::Map::new(),
        }
    }

    /// The K-031 gate for the comp-walk unification (docs/TODO.md): the
    /// interactive path (`build_comp_draws` + `Realiser`) and the export walk
    /// (`render_comp_linear`) must produce identical bytes across every
    /// construction the two implement separately. Each row is a document the
    /// model can build without a media file; the Retime blend/flow rows join
    /// when a footage fixture exists.
    #[test]
    fn the_preview_and_export_paths_agree_across_the_matrix() {
        let mut r = match HeadlessRenderer::new() {
            Ok(r) => r,
            Err(_) => {
                eprintln!("skipping: no GPU adapter");
                return;
            }
        };

        let (cw, ch) = (32u32, 16u32);
        let red = LinearColour([0.8, 0.1, 0.1, 1.0]);
        let blue = LinearColour([0.1, 0.2, 0.9, 1.0]);

        // Each scenario builds its own document from scratch, so a row can
        // never lean on another's state.
        type Build = fn(u32, u32, LinearColour, LinearColour) -> (Document, Uuid, u64);
        let scenarios: Vec<(&str, Build)> = vec![
            ("stacked blends and opacity", |w, h, red, blue| {
                let (mut doc, comp_id, _) = matrix_base(w, h, red);
                let (_, top) = matrix_top(&mut doc, comp_id, blue);
                let comp = doc.comp_mut(comp_id).unwrap();
                let l = comp.layers.iter_mut().find(|l| l.id == top).unwrap();
                l.blend = lumit_core::model::BlendMode::Multiply;
                l.transform.opacity = Property::fixed(60.0);
                l.transform.rotation = Property::fixed(25.0);
                (doc, comp_id, 0)
            }),
            ("nested precomp", |w, h, red, blue| {
                let (mut doc, comp_id, _) = matrix_base(w, h, red);
                let (child_doc, child_id, _) = matrix_base(16, 16, blue);
                for item in child_doc.items {
                    doc.items.push(item);
                }
                let layer = matrix_layer("Nested", LayerKind::Precomp { comp: child_id }, 16, 16);
                doc.comp_mut(comp_id).unwrap().layers.insert(0, layer);
                (doc, comp_id, 0)
            }),
            ("collapsed precomp", |w, h, red, blue| {
                let (mut doc, comp_id, _) = matrix_base(w, h, red);
                let (child_doc, child_id, _) = matrix_base(16, 16, blue);
                for item in child_doc.items {
                    doc.items.push(item);
                }
                let mut layer =
                    matrix_layer("Collapsed", LayerKind::Precomp { comp: child_id }, 16, 16);
                layer.switches.collapse = true;
                doc.comp_mut(comp_id).unwrap().layers.insert(0, layer);
                (doc, comp_id, 0)
            }),
            ("matte source none", |w, h, red, blue| {
                matte_doc(w, h, red, blue, lumit_core::model::LayerInputSource::None)
            }),
            ("matte source masks", |w, h, red, blue| {
                matte_doc(w, h, red, blue, lumit_core::model::LayerInputSource::Masks)
            }),
            ("matte source effects and masks", |w, h, red, blue| {
                matte_doc(
                    w,
                    h,
                    red,
                    blue,
                    lumit_core::model::LayerInputSource::EffectsAndMasks,
                )
            }),
            ("adjustment layer with an effect", |w, h, red, _blue| {
                let (mut doc, comp_id, _) = matrix_base(w, h, red);
                let mut adj = matrix_layer("Adjust", LayerKind::Adjustment, w, h);
                adj.effects
                    .push(lumit_core::fx::instantiate("invert").unwrap());
                doc.comp_mut(comp_id).unwrap().layers.insert(0, adj);
                (doc, comp_id, 0)
            }),
            ("per-layer motion blur", |w, h, red, blue| {
                let (mut doc, comp_id, _) = matrix_base(w, h, red);
                let (_, top) = matrix_top(&mut doc, comp_id, blue);
                let comp = doc.comp_mut(comp_id).unwrap();
                comp.motion_blur = lumit_core::model::MotionBlur {
                    enabled: true,
                    shutter_angle: 180.0,
                    shutter_phase: -90.0,
                    samples: 8,
                };
                let l = comp.layers.iter_mut().find(|l| l.id == top).unwrap();
                l.switches.motion_blur = true;
                l.transform.rotation = ramp(0.0, 180.0, 1);
                (doc, comp_id, 15)
            }),
            ("posterize time holds the stack below", |w, h, red, blue| {
                let (mut doc, comp_id, _) = matrix_base(w, h, red);
                let (_, top) = matrix_top(&mut doc, comp_id, blue);
                let comp = doc.comp_mut(comp_id).unwrap();
                let l = comp.layers.iter_mut().find(|l| l.id == top).unwrap();
                l.transform.rotation = ramp(0.0, 180.0, 1);
                let mut adj = matrix_layer("Hold", LayerKind::Adjustment, w, h);
                adj.effects
                    .push(lumit_core::fx::instantiate("posterize_time").unwrap());
                comp.layers.insert(0, adj);
                (doc, comp_id, 15)
            }),
            ("camera over a 3d layer", |w, h, red, blue| {
                let (mut doc, comp_id, _) = matrix_base(w, h, red);
                let (_, top) = matrix_top(&mut doc, comp_id, blue);
                let comp = doc.comp_mut(comp_id).unwrap();
                let l = comp.layers.iter_mut().find(|l| l.id == top).unwrap();
                l.switches.three_d = true;
                l.transform.rotation_y = Property::fixed(35.0);
                l.transform.position_z = Property::fixed(40.0);
                let camera = matrix_layer(
                    "Camera",
                    LayerKind::Camera {
                        zoom: Property::fixed(f64::from(h) * 2.0),
                    },
                    w,
                    h,
                );
                comp.layers.insert(0, camera);
                (doc, comp_id, 0)
            }),
        ];

        for (name, build) in scenarios {
            let (doc, comp_id, frame) = build(cw, ch, red, blue);
            let store = DocumentStore::new(doc);
            let doc = store.snapshot();
            let (preview, pw, ph) = r
                .render_preview(
                    &doc,
                    comp_id,
                    frame,
                    crate::plan::Quality::default(),
                    1.0,
                    None,
                )
                .unwrap_or_else(|e| panic!("{name}: preview render failed: {e}"));
            let (export, ew, eh) = r
                .render_rgba(&doc, comp_id, frame, 1.0)
                .unwrap_or_else(|e| panic!("{name}: export render failed: {e}"));
            assert_eq!(
                (pw, ph),
                (ew, eh),
                "{name}: the two paths render at different sizes"
            );
            assert_eq!(
                preview, export,
                "{name}: the interactive and export paths must be bit-identical (K-031)"
            );
        }
    }

    /// A document with one comp holding a full-frame solid of `colour`.
    fn matrix_base(w: u32, h: u32, colour: LinearColour) -> (Document, Uuid, Uuid) {
        let mut doc = Document::new();
        let solid = Uuid::now_v7();
        doc.items.push(ProjectItem::Solid(SolidDef {
            id: solid,
            name: "Base".into(),
            colour,
            width: w,
            height: h,
            extra: serde_json::Map::new(),
        }));
        let comp_id = Uuid::now_v7();
        doc.items.push(ProjectItem::Composition(Composition {
            id: comp_id,
            name: "Scene".into(),
            width: w,
            height: h,
            frame_rate: FrameRate::new(30, 1).unwrap(),
            duration: Duration(Rational::new(5, 1).unwrap()),
            background: LinearColour::BLACK,
            work_area: None,
            layers: vec![matrix_layer("Base", LayerKind::Solid { def: solid }, w, h)],
            markers: Vec::new(),
            motion_blur: lumit_core::model::MotionBlur::default(),
            extra: serde_json::Map::new(),
        }));
        (doc, comp_id, solid)
    }

    /// A second, smaller solid item plus a layer of it at the top of the stack.
    fn matrix_top(doc: &mut Document, comp_id: Uuid, colour: LinearColour) -> (Uuid, Uuid) {
        let solid = Uuid::now_v7();
        doc.items.push(ProjectItem::Solid(SolidDef {
            id: solid,
            name: "Top".into(),
            colour,
            width: 12,
            height: 10,
            extra: serde_json::Map::new(),
        }));
        let layer = matrix_layer("Top", LayerKind::Solid { def: solid }, 12, 10);
        let layer_id = layer.id;
        if let Some(comp) = doc.comp_mut(comp_id) {
            // Index 0 = top of the stack.
            comp.layers.insert(0, layer);
        }
        (solid, layer_id)
    }

    /// A consumer layer matted by a hidden source carrying a mask and an
    /// effect, with the matte's sampling mode chosen per row (K-142).
    fn matte_doc(
        w: u32,
        h: u32,
        red: LinearColour,
        blue: LinearColour,
        source: lumit_core::model::LayerInputSource,
    ) -> (Document, Uuid, u64) {
        let mut doc = Document::new();
        let red_solid = Uuid::now_v7();
        let blue_solid = Uuid::now_v7();
        for (id, name, colour, sw, sh) in [
            (red_solid, "Red", red, w, h),
            (blue_solid, "Blue", blue, 12u32, 12u32),
        ] {
            doc.items.push(ProjectItem::Solid(SolidDef {
                id,
                name: name.into(),
                colour,
                width: sw,
                height: sh,
                extra: serde_json::Map::new(),
            }));
        }
        let mut matte_layer = matrix_layer("Matte", LayerKind::Solid { def: blue_solid }, 12, 12);
        matte_layer.switches.visible = false;
        matte_layer
            .masks
            .push(lumit_core::mask::Mask::rectangle(0.0, 0.0, 6.0, 12.0));
        matte_layer
            .effects
            .push(lumit_core::fx::instantiate("invert").unwrap());
        let mut consumer = matrix_layer("Red", LayerKind::Solid { def: red_solid }, w, h);
        consumer.matte = Some(lumit_core::model::MatteRef {
            layer: matte_layer.id,
            channel: lumit_core::model::MatteChannel::Alpha,
            inverted: false,
            source,
        });
        let comp_id = Uuid::now_v7();
        doc.items.push(ProjectItem::Composition(Composition {
            id: comp_id,
            name: "Scene".into(),
            width: w,
            height: h,
            frame_rate: FrameRate::new(30, 1).unwrap(),
            duration: Duration(Rational::new(5, 1).unwrap()),
            background: LinearColour::BLACK,
            work_area: None,
            layers: vec![consumer, matte_layer],
            markers: Vec::new(),
            motion_blur: lumit_core::model::MotionBlur::default(),
            extra: serde_json::Map::new(),
        }));
        (doc, comp_id, 0)
    }

    /// An unknown comp id on the interactive path is a calm error, and it must
    /// not disturb the pixels retained for a comp that *does* exist.
    #[test]
    fn an_unknown_comp_is_a_calm_error_on_the_preview_path() {
        let mut r = match HeadlessRenderer::new() {
            Ok(r) => r,
            Err(_) => {
                eprintln!("skipping: no GPU adapter");
                return;
            }
        };
        let (store, comp_id) = doc_with_solid(LinearColour([1.0, 1.0, 1.0, 1.0]), 8, 8);
        let doc = store.snapshot();
        let q = crate::plan::Quality::default();
        r.render_preview(&doc, comp_id, 0, q, 1.0, None)
            .expect("render");
        let decodes = r.decoded_frames();

        assert!(r
            .render_preview(&doc, Uuid::now_v7(), 0, q, 1.0, None)
            .is_err());
        // The good comp still re-composites from its retained pixels.
        r.render_preview(&doc, comp_id, 0, q, 1.0, None)
            .expect("still fine");
        assert_eq!(r.decoded_frames(), decodes);
    }

    /// Not a correctness test — a stopwatch, run by hand:
    /// `cargo test -p lumit-render --release -- --ignored --nocapture preview_cost`
    ///
    /// It exists because a Dart-side measurement of this cannot be trusted: the
    /// widget-test harness settles in 20 ms slices, so anything measured through
    /// it reports the polling granularity rather than the render.
    #[test]
    #[ignore = "timing, not correctness"]
    fn preview_cost() {
        let Ok(mut renderer) = HeadlessRenderer::new() else {
            eprintln!("skipping: no GPU adapter");
            return;
        };
        let (store, comp_id) = doc_with_solid(LinearColour([0.2, 0.4, 0.8, 1.0]), 1920, 1080);
        let doc = store.snapshot();

        for (label, scale) in [("full", 1.0f32), ("fit-0.42", 0.42), ("quarter", 0.25)] {
            let quality = Quality {
                draft: false,
                auto_res: scale < 1.0,
                display_scale: scale,
                divisor: 1,
            };
            // Warm: the first render builds pipelines and probes.
            let _ = renderer.render_preview(&doc, comp_id, 0, quality, scale, None);

            let n = 30u32;
            let started = std::time::Instant::now();
            for frame in 0..n {
                let out =
                    renderer.render_preview(&doc, comp_id, u64::from(frame), quality, scale, None);
                assert!(out.is_ok(), "{label} frame {frame} failed");
            }
            let each = started.elapsed().as_secs_f64() * 1000.0 / f64::from(n);
            println!("PREVIEW {label:>10} scale={scale:<5} {each:>7.2} ms/frame");
        }
    }
}
