//! `shell::gpu` — the egui Viewer's end of the pixel pass.
//!
//! Everything about *how a comp is composited* now lives in `lumit-render`
//! (K-178): the draw-list types, the draw builder and the [`Realiser`] that
//! turns a draw list into a texture. What is left here is the part that is
//! genuinely egui's — registering a finished GPU texture with egui's renderer so
//! a `Ui` can paint it, and the VRAM tier of already-registered frames that
//! makes a warm scrub free.

#[cfg(feature = "media")]
use lumit_render::Realiser;

/// GPU display path (slice 5 completion): decoded sRGB bytes → linear fp16
/// working texture → display texture registered with egui. Falls back to the
/// CPU/egui-texture path when no wgpu render state exists.
#[cfg(feature = "media")]
pub struct GpuViewer {
    ctx: lumit_gpu::GpuContext,
    engine: lumit_gpu::ColourEngine,
    compositor: lumit_gpu::Compositor,
    fx: lumit_gpu::fx::FxEngine,
    render_state: egui_wgpu::RenderState,
    /// Keep the display texture alive while egui samples it.
    current: Option<(egui_wgpu::wgpu::Texture, egui::TextureId)>,
    /// The VRAM tier (docs/06 §5): displayed textures per frame key, LRU by
    /// position (back = most recent), so a warm scrub re-presents with zero
    /// upload or colour work. Budgeted by texture bytes.
    vram: Vec<VramFrame>,
    vram_bytes: u64,
    /// The live VRAM-tier budget (Settings → Performance, K-100). Starts at
    /// [`VRAM_TIER_CAP`] and moves when the owner drags the slider.
    vram_cap: u64,
    /// Parsed-and-uploaded `.cube` LUTs keyed by path (docs/08 §3.11,
    /// docs/impl/lut.md §4): parse + upload happen once per distinct file, not
    /// per frame. `RefCell` because the realise path takes `&self`. Path-only
    /// key for now — mtime invalidation and bounding are documented follow-ups
    /// (an edited-on-disk LUT needs the app reopened).
    lut_cache:
        std::cell::RefCell<std::collections::HashMap<String, lumit_render::fxops::LoadedLut>>,
}

/// One VRAM-tier entry: the display texture, its egui registration, and size.
#[cfg(feature = "media")]
pub(crate) struct VramFrame {
    key: u128,
    /// Never read — held so the GPU texture outlives its egui registration.
    _texture: egui_wgpu::wgpu::Texture,
    id: egui::TextureId,
    size: egui::Vec2,
    bytes: u64,
}

/// VRAM-tier budget (docs/13-PERFORMANCE-RULES.md: budgets gate merges; the
/// governor makes this adaptive later). 512 MB of display textures ≈ 60
/// frames of 4K, several hundred of 1080p.
#[cfg(feature = "media")]
pub(crate) const VRAM_TIER_CAP: u64 = 512 * 1024 * 1024;

/// How many oldest entries must go so `total` fits under `cap` after adding
/// `incoming` bytes. Pure, so the eviction policy is testable off-GPU.
#[cfg(feature = "media")]
pub(crate) fn vram_evict_count(entry_bytes: &[u64], total: u64, incoming: u64, cap: u64) -> usize {
    let mut running = total.saturating_add(incoming);
    let mut n = 0;
    for b in entry_bytes {
        if running <= cap {
            break;
        }
        running = running.saturating_sub(*b);
        n += 1;
    }
    n
}

#[cfg(feature = "media")]
impl GpuViewer {
    pub fn new(render_state: egui_wgpu::RenderState) -> Self {
        let ctx = lumit_gpu::GpuContext::from_parts(
            render_state.device.clone(),
            render_state.queue.clone(),
        );
        let engine = lumit_gpu::ColourEngine::new(&ctx);
        let compositor = lumit_gpu::Compositor::new(&ctx);
        let fx = lumit_gpu::fx::FxEngine::new(&ctx);
        Self {
            ctx,
            engine,
            compositor,
            fx,
            render_state,
            current: None,
            vram: Vec::new(),
            vram_bytes: 0,
            vram_cap: VRAM_TIER_CAP,
            lut_cache: std::cell::RefCell::new(std::collections::HashMap::new()),
        }
    }

    /// A second handle to the shared device for the export thread.
    pub fn export_context(&self) -> lumit_gpu::GpuContext {
        lumit_gpu::GpuContext::from_parts(self.ctx.device.clone(), self.ctx.queue.clone())
    }

    /// Borrow this viewer's GPU primitives as a [`Realiser`] — the shared
    /// draw-list compositor the Flutter frontend and export drive too, so a
    /// comp realises identically in the viewport and the file (K-031).
    pub(crate) fn realiser(&self) -> Realiser<'_> {
        Realiser {
            ctx: lumit_gpu::GpuContext::from_parts(self.ctx.device.clone(), self.ctx.queue.clone()),
            engine: &self.engine,
            compositor: &self.compositor,
            fx: &self.fx,
            lut_cache: &self.lut_cache,
        }
    }

    /// Realise a draw list into a linear comp texture — delegates to the shared
    /// [`Realiser`].
    fn realise(
        &self,
        camera: Option<lumit_core::model::CameraPose>,
        width: u32,
        height: u32,
        background: [f64; 4],
        layers: &[lumit_render::CompLayerDraw],
    ) -> egui_wgpu::wgpu::Texture {
        self.realiser()
            .realise(camera, width, height, background, layers)
    }

    /// Realise a comp frame straight to display-ready sRGB bytes (Nebula's
    /// cache-fill path — nothing is registered for painting).
    pub(crate) fn realise_to_bytes(
        &self,
        camera: Option<lumit_core::model::CameraPose>,
        width: u32,
        height: u32,
        background: [f64; 4],
        layers: &[lumit_render::CompLayerDraw],
    ) -> Option<Vec<u8>> {
        let linear = self.realise(camera, width, height, background, layers);
        let shown = self.engine.display(&self.ctx, &linear);
        self.engine.readback8(&self.ctx, &shown).ok()
    }

    /// Realise a comp's draws and register the frame for painting.
    pub(crate) fn present_comp(
        &mut self,
        camera: Option<lumit_core::model::CameraPose>,
        width: u32,
        height: u32,
        background: [f64; 4],
        layers: &[lumit_render::CompLayerDraw],
    ) -> (egui::TextureId, egui::Vec2) {
        let linear = self.realise(camera, width, height, background, layers);
        let shown = self.engine.display(&self.ctx, &linear);
        let view = shown.create_view(&Default::default());
        let id = self.render_state.renderer.write().register_native_texture(
            &self.ctx.device,
            &view,
            egui_wgpu::wgpu::FilterMode::Linear,
        );
        if let Some((_, old)) = self.current.replace((shown, id)) {
            self.render_state.renderer.write().free_texture(&old);
        }
        (id, egui::vec2(width as f32, height as f32))
    }

    /// A warm VRAM hit: re-present a frame whose display texture is still on
    /// the GPU — no upload, no colour passes (docs/06 §5: VRAM reads first).
    pub(crate) fn present_vram(&mut self, key: u128) -> Option<(egui::TextureId, egui::Vec2)> {
        let idx = self.vram.iter().position(|e| e.key == key)?;
        let entry = self.vram.remove(idx);
        let out = (entry.id, entry.size);
        self.vram.push(entry); // back = most recently used
        Some(out)
    }

    /// Present a RAM-tier frame and keep its display texture in the VRAM tier
    /// under `key`, evicting oldest entries past the byte budget.
    pub(crate) fn present_keyed(
        &mut self,
        key: u128,
        rgba: &[u8],
        w: u32,
        h: u32,
    ) -> (egui::TextureId, egui::Vec2) {
        let src = self.engine.upload_srgb8(&self.ctx, rgba, w, h);
        let linear = self.engine.linearise(&self.ctx, &src);
        let shown = self.engine.display(&self.ctx, &linear);
        let view = shown.create_view(&Default::default());
        let id = self.render_state.renderer.write().register_native_texture(
            &self.ctx.device,
            &view,
            egui_wgpu::wgpu::FilterMode::Linear,
        );
        let bytes = u64::from(w) * u64::from(h) * 4;
        let sizes: Vec<u64> = self.vram.iter().map(|e| e.bytes).collect();
        let drop_n = vram_evict_count(&sizes, self.vram_bytes, bytes, self.vram_cap);
        for old in self.vram.drain(..drop_n) {
            self.vram_bytes = self.vram_bytes.saturating_sub(old.bytes);
            self.render_state.renderer.write().free_texture(&old.id);
        }
        let size = egui::vec2(w as f32, h as f32);
        self.vram.push(VramFrame {
            key,
            _texture: shown,
            id,
            size,
            bytes,
        });
        self.vram_bytes = self.vram_bytes.saturating_add(bytes);
        (id, size)
    }

    /// Move the VRAM-tier budget (Settings → Performance, K-100), evicting
    /// oldest entries immediately if the new cap is below what is currently
    /// held — the same oldest-first policy `present_keyed` uses on insert,
    /// just with nothing incoming.
    pub(crate) fn set_vram_cap(&mut self, bytes: u64) {
        self.vram_cap = bytes;
        let sizes: Vec<u64> = self.vram.iter().map(|e| e.bytes).collect();
        let drop_n = vram_evict_count(&sizes, self.vram_bytes, 0, self.vram_cap);
        for old in self.vram.drain(..drop_n) {
            self.vram_bytes = self.vram_bytes.saturating_sub(old.bytes);
            self.render_state.renderer.write().free_texture(&old.id);
        }
    }

    /// Drop every VRAM-tier entry (Settings → Performance "Clear cache",
    /// K-100), releasing each texture's egui registration so nothing leaks.
    pub(crate) fn clear_vram(&mut self) {
        for old in self.vram.drain(..) {
            self.render_state.renderer.write().free_texture(&old.id);
        }
        self.vram_bytes = 0;
    }

    /// Upload a decoded frame through the colour pipeline; returns the egui
    /// texture id + size to paint.
    pub(crate) fn present(&mut self, rgba: &[u8], w: u32, h: u32) -> (egui::TextureId, egui::Vec2) {
        let src = self.engine.upload_srgb8(&self.ctx, rgba, w, h);
        let linear = self.engine.linearise(&self.ctx, &src);
        let shown = self.engine.display(&self.ctx, &linear);
        let view = shown.create_view(&Default::default());
        let id = self.render_state.renderer.write().register_native_texture(
            &self.ctx.device,
            &view,
            egui_wgpu::wgpu::FilterMode::Linear,
        );
        if let Some((_, old)) = self.current.replace((shown, id)) {
            self.render_state.renderer.write().free_texture(&old);
        }
        (id, egui::vec2(w as f32, h as f32))
    }
}
