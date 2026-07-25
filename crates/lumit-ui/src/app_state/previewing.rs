//! `AppState` preview engine: the frame cache and fill scheduler, the disk
//! cache tier, comp-preview compositing jobs, and audio preparation.

use super::*;

impl AppState {
    /// Work-area frame span of a comp (start, end-exclusive); full when unset.
    pub fn work_area_frames(&self, comp: &Composition) -> (usize, usize) {
        lumit_render::cache::work_area_frames(comp)
    }

    /// AE's B/N: set the work-area start or end at the playhead.
    pub fn set_work_area_edge(&mut self, end_edge: bool) {
        use lumit_core::time::CompTime;
        let Some(comp_id) = self.preview_comp else {
            return;
        };
        let doc = self.store.snapshot();
        let Some(comp) = doc.comp(comp_id) else {
            return;
        };
        let fps = comp.frame_rate.fps().max(1.0);
        let t = self.preview_frame as f64 / fps;
        let dur = comp.duration.0.to_f64();
        let (mut a, mut b) = comp
            .work_area
            .map(|(a, b)| (a.0.to_f64(), b.0.to_f64()))
            .unwrap_or((0.0, dur));
        if end_edge {
            b = (t + 1.0 / fps).min(dur);
            if a >= b {
                a = 0.0;
            }
        } else {
            a = t.min(dur - 1.0 / fps);
            if b <= a {
                b = dur;
            }
        }
        let wa = if a <= 0.0 && (b - dur).abs() < 1e-9 {
            None // full span = no work area
        } else {
            Some((
                CompTime(
                    Rational::from_f64_on_grid(a, Rational::FLICK_DEN).unwrap_or(Rational::ZERO),
                ),
                CompTime(
                    Rational::from_f64_on_grid(b, Rational::FLICK_DEN).unwrap_or(comp.duration.0),
                ),
            ))
        };
        self.commit(Op::SetWorkArea {
            comp: comp_id,
            work_area: wa,
        });
    }

    /// Frame count of the comp preview (comp duration × comp rate).
    pub fn comp_frame_count(&self, comp: &Composition) -> usize {
        lumit_render::cache::comp_frame_count(comp)
    }

    /// Total frame count of whatever the Viewer is previewing — the active comp
    /// or a footage item — or 0 when nothing is. Mirrors the transport bar's
    /// own length lookup so the `End` key and the scrubber agree.
    pub fn preview_frame_count(&self) -> usize {
        if let Some(comp_id) = self.preview_comp {
            return self
                .store
                .snapshot()
                .comp(comp_id)
                .map(|c| self.comp_frame_count(c))
                .unwrap_or(0);
        }
        #[cfg(feature = "media")]
        if let Some(id) = self.preview_item {
            use crate::app_state::media::MediaStatus;
            if let Some(MediaStatus::Ready { frames, .. }) = self.media.map.get(&id) {
                return *frames;
            }
        }
        0
    }

    /// How coarsely this preview DECODES: the resolution picker, plus the draft
    /// cap while scrubbing, plus Realtime's adaptive tier when it is driving
    /// (K-030). What actually reaches the decoder.
    #[cfg(feature = "media")]
    pub(crate) fn decode_quality(&self) -> lumit_render::Quality {
        let (auto_res, divisor) = if self.preview_realtime {
            (false, self.realtime_ctrl.tier())
        } else {
            (self.preview_auto_res, self.preview_divisor)
        };
        lumit_render::Quality {
            draft: self.preview_draft,
            auto_res,
            display_scale: self.last_display_scale,
            divisor,
        }
    }

    /// How coarsely a frame is NAMED — the *settled* resolution, deliberately
    /// ignoring both the draft cap and Realtime's tier. Neither of those frames
    /// is ever banked (draft frames are skipped explicitly; Realtime only runs
    /// during playback, and playback does not bank), so naming by the settled
    /// resolution is what lets a scrub and a later still share one entry.
    #[cfg(feature = "media")]
    pub(crate) fn key_quality(&self) -> lumit_render::Quality {
        lumit_render::Quality {
            draft: false,
            auto_res: self.preview_auto_res,
            display_scale: self.last_display_scale,
            divisor: self.preview_divisor,
        }
    }

    /// Content-hash key for one frame of a comp, or None while some footage
    /// is unprobed (rendered live, not cached).
    #[cfg(feature = "media")]
    pub fn frame_key_for(&self, comp_id: Uuid, frame: usize) -> Option<u128> {
        let doc = self.store.snapshot();
        let comp = doc.comp(comp_id)?;
        lumit_render::cache::frame_key(&doc, comp, frame, self.key_quality(), &self.media)
    }

    /// Ask the preview engine to render an arbitrary frame (the background
    /// cache fill) without moving the playhead.
    #[cfg(feature = "media")]
    pub fn request_fill_frame(&mut self, comp_id: Uuid, frame: usize) {
        let doc = self.store.snapshot();
        let Some(comp) = doc.comp(comp_id) else {
            return;
        };
        let t = frame as f64 / comp.frame_rate.fps().max(1.0);
        let mut jobs = Vec::new();
        let mut visited = vec![comp_id];
        self.collect_comp_jobs(&doc, comp, t, &mut jobs, &mut visited);
        self.fill_in_flight = Some((comp_id, frame));
        self.preview_engine
            .request_comp(comp_id, frame, jobs, self.media_epoch);
    }

    /// The next work-area frame worth filling (forward-biased from the
    /// playhead), or None when the work area is fully cached or unkeyable.
    #[cfg(feature = "media")]
    pub fn next_fill_frame(&self, comp_id: Uuid) -> Option<usize> {
        let doc = self.store.snapshot();
        let comp = doc.comp(comp_id)?;
        let (start, end) = self.work_area_frames(comp);
        let playhead = self.preview_frame.clamp(start, end.saturating_sub(1));
        lumit_render::cache::fill_walk_order(playhead, start, end)
            .into_iter()
            .find_map(|frame| {
                let key = self.frame_key_for(comp_id, frame)?;
                (!self.comp_frame_cache.contains_key(&key)).then_some(frame)
            })
    }

    /// The next frame worth warming ahead of the playhead during playback: the
    /// first uncached frame in the bounded forward lookahead window, or None
    /// when that window is fully cached or unkeyable. Unlike the idle fill this
    /// is strictly forward — it chases the audio clock, never behind it
    /// (docs/impl/playback-scheduler.md §5).
    #[cfg(feature = "media")]
    pub(crate) fn next_playback_prefetch(
        &self,
        comp_id: Uuid,
        playhead: usize,
        end: usize,
    ) -> Option<usize> {
        // Fixed lookahead for now; the impl note adapts it to render cost in a
        // later slice. Eight to sixteen frames per the note; twelve is a middle.
        const LOOKAHEAD: usize = 12;
        lumit_render::cache::playback_lookahead(playhead, end, LOOKAHEAD)
            .into_iter()
            .find_map(|frame| {
                let key = self.frame_key_for(comp_id, frame)?;
                (!self.comp_frame_cache.contains_key(&key)).then_some(frame)
            })
    }

    /// Which of a comp's frames are in Nebula's RAM tier — the timeline cache
    /// bar (docs/07-UI-SPEC.md: cache bars). Memoised per (document, cache
    /// state, quality); comps beyond 2 400 frames skip the bar for now (the
    /// evaluator's incremental bar replaces this scan — S-budget debt).
    #[cfg(feature = "media")]
    pub fn cache_bar(&mut self, comp: &Composition) -> Option<std::sync::Arc<Vec<CacheTier>>> {
        let total = self.comp_frame_count(comp);
        if total == 0 || total > 2400 {
            return None;
        }
        // A snapshot of the on-disk set (one lock, then no contention in the
        // per-frame loop); its size joins the memo key so disk stores/evicts
        // refresh the bar.
        let disk: std::collections::HashSet<u128> = self
            .disk_io
            .as_ref()
            .and_then(|io| io.known.lock().ok().map(|k| k.clone()))
            .unwrap_or_default();
        let key = (
            std::sync::Arc::as_ptr(&self.store.snapshot()) as usize,
            self.cache_epoch,
            self.key_quality().tag(),
            comp.id,
            disk.len(),
        );
        if let Some((k, bars)) = &self.cache_bar_memo {
            if *k == key {
                return Some(bars.clone());
            }
        }
        let bars: Vec<CacheTier> = (0..total)
            .map(|f| match self.frame_key_for(comp.id, f) {
                Some(k) if self.comp_frame_cache.contains_key(&k) => CacheTier::Ram,
                Some(k) if disk.contains(&k) => CacheTier::Disk,
                _ => CacheTier::None,
            })
            .collect();
        let bars = std::sync::Arc::new(bars);
        self.cache_bar_memo = Some((key, bars.clone()));
        Some(bars)
    }

    /// Keep the disk tier pointed at the saved project's sidecar (or the
    /// user's Settings → Performance → Cache root override, when set),
    /// starting the IO worker on first use. Cheap to call every frame.
    #[cfg(feature = "media")]
    pub fn disk_sync_root(&mut self, cache_root_override: Option<&std::path::Path>) {
        let root = self
            .path
            .as_deref()
            .and_then(|p| lumit_cache::disk::cache_root_for(p, cache_root_override));
        if root == self.disk_root {
            return;
        }
        if self.disk_io.is_none() {
            self.disk_io = Some(lumit_render::diskio::spawn());
        }
        if let Some(io) = &self.disk_io {
            let _ = io.tx.send(lumit_render::diskio::Cmd::SetRoot(root.clone()));
        }
        self.disk_load_pending.clear();
        self.disk_root = root;
    }

    /// Park a rendered frame on disk (write-behind; no-op while unsaved).
    #[cfg(feature = "media")]
    pub fn disk_store_behind(&mut self, key: u128, width: u32, height: u32, rgba: Vec<u8>) {
        if let Some(io) = &self.disk_io {
            let _ = io
                .tx
                .send(lumit_render::diskio::Cmd::Store(key, width, height, rgba));
        }
    }

    /// Whether the disk tier holds this frame (per the worker's mirror).
    #[cfg(feature = "media")]
    pub fn disk_has(&self, key: u128) -> bool {
        self.disk_io
            .as_ref()
            .and_then(|io| io.known.lock().ok().map(|k| k.contains(&key)))
            .unwrap_or(false)
    }

    /// Ask the worker to promote a frame disk → RAM (idempotent per key
    /// until the load lands or misses).
    #[cfg(feature = "media")]
    pub fn disk_request_load(&mut self, key: u128) {
        if self.disk_load_pending.contains(&key) {
            return;
        }
        if let Some(io) = &self.disk_io {
            if io.tx.send(lumit_render::diskio::Cmd::Load(key)).is_ok() {
                self.disk_load_pending.insert(key);
            }
        }
    }

    /// Fold completed disk loads into the RAM tier. Returns true when any
    /// frame landed (the caller repaints / re-presents).
    #[cfg(feature = "media")]
    pub fn drain_disk_loads(&mut self) -> bool {
        let mut any = false;
        // Collect first: inserting borrows self mutably.
        let mut landed = Vec::new();
        if let Some(io) = &self.disk_io {
            while let Ok((key, f)) = io.loaded.try_recv() {
                landed.push((key, f));
            }
        }
        for (key, f) in landed {
            self.disk_load_pending.remove(&key);
            self.comp_frame_cache.insert(
                key,
                CachedCompFrame {
                    width: f.width,
                    height: f.height,
                    rgba: f.rgba,
                },
            );
            self.cache_epoch += 1;
            any = true;
        }
        any
    }

    #[cfg(feature = "media")]
    pub fn refresh_comp_preview(&mut self) {
        let Some(comp_id) = self.preview_comp else {
            return;
        };
        let doc = self.store.snapshot();
        let Some(comp) = doc.comp(comp_id) else {
            return;
        };
        let frames = self.comp_frame_count(comp);
        self.preview_frame = self.preview_frame.min(frames.saturating_sub(1));
        let t = self.preview_frame as f64 / comp.frame_rate.fps();

        // A real request supersedes any background fill in flight.
        self.fill_in_flight = None;

        // Nebula warm path: a cached frame presents without decoding anything —
        // but a live value edit needs this frame's decoded per-layer pixels
        // (`last_comp`) to re-composite, and a cache hit never populates them, so
        // skip the shortcut and decode while one is active (owner bug — see
        // `live_edit_active`).
        if !self.live_edit_active() {
            if let Some(key) = self.frame_key_for(comp_id, self.preview_frame) {
                if self.comp_frame_cache.contains_key(&key) {
                    self.cached_present = Some(key);
                    return;
                }
            }
        }

        // Recursive job collection: visible layers, their matte sources, and
        // everything nested comps need at their mapped times (cycle-guarded).
        let mut jobs = Vec::new();
        let mut visited = vec![comp_id];
        self.collect_comp_jobs(&doc, comp, t, &mut jobs, &mut visited);
        self.preview_engine
            .request_comp(comp_id, self.preview_frame, jobs, self.media_epoch);
    }

    /// Decode target width for a source of `natural_w` px under the current
    /// resolution mode. Auto: displayed size, capped at 100% (never above
    /// native, however far the view is zoomed in).
    /// Any live pointer interaction (scrubbing or a drag) — background cache
    /// fills pause while it is true so they don't fight the interaction.
    pub fn is_interacting(&self) -> bool {
        self.preview_draft
            || self.prop_edit.is_some()
            || self.retime_edit.is_some()
            || self.trim_edit.is_some()
            || self.move_edit.is_some()
            || self.graph_edit.is_some()
            || self.graph_marquee.is_some()
            || self.graph_speed_edit.is_some()
            || self.graph_tangent_edit.is_some()
            || self.graph_retime_edit.is_some()
            || self.mask_drag.is_some()
            || self.origin_drag.is_some()
            || self.shape_drag.is_some()
    }

    /// Any value edit whose live preview re-composites from the presented
    /// frame's decoded per-layer pixels (the present path's live patch): an
    /// effect-value drag (`fx_edit`), a linked-scale drag (`scale_preview`), a
    /// transform-value drag (`prop_edit`), or a graph keyframe drag
    /// (`graph_edit`). When one is active on a *cache-hit* frame, the preview
    /// must DECODE rather than take the composite-cache shortcut, so `last_comp`
    /// is populated and the live patch can render — otherwise the drag shows
    /// nothing until release (the owner-reported bug: an effect-value drag in
    /// the layer area only updated on frames with a keyframe, because a keyframe
    /// at the playhead invalidated the cache and forced the decode).
    pub fn live_edit_active(&self) -> bool {
        self.fx_edit.is_some()
            || self.scale_preview.is_some()
            || self.prop_edit.is_some()
            || self.graph_edit.is_some()
            // A Retime "Time" drag re-decodes (a different source frame), so it
            // must force the decode path on a cache-hit frame too.
            || self.retime_edit.is_some()
    }

    /// The width one source decodes at under the current preview quality.
    #[cfg(feature = "media")]
    pub fn target_width_for(&self, natural_w: u32) -> Option<u32> {
        self.decode_quality().target_width(natural_w)
    }

    /// The preview divisor Realtime mode is currently applying — the adaptive
    /// controller's tier (1 = Full … 4 = Quarter). 1 when built without media.
    /// Surfaced in the viewer bar so the adaptation is visible.
    pub fn realtime_tier(&self) -> u32 {
        #[cfg(feature = "media")]
        {
            self.realtime_ctrl.tier()
        }
        #[cfg(not(feature = "media"))]
        {
            1
        }
    }

    /// Recursively collect decode jobs for a comp at time `t` — delegated to
    /// the shared planner (`lumit_render::plan`), which the Flutter frontend
    /// drives too, so the two frontends cannot decode different things.
    ///
    /// The one bit of shell state it needs is the live Retime "Time" drag: that
    /// is the only edit that changes *which* source frame a layer shows, so it
    /// reaches the plan rather than being patched in afterwards.
    #[cfg(feature = "media")]
    pub(crate) fn collect_comp_jobs(
        &self,
        doc: &Document,
        comp: &Composition,
        t: f64,
        jobs: &mut Vec<lumit_render::decode::CompJob>,
        visited: &mut Vec<Uuid>,
    ) {
        let retime =
            self.retime_edit
                .as_ref()
                .map(|(layer, retime)| lumit_render::RetimeOverride {
                    layer: *layer,
                    retime: retime.clone(),
                });
        let ctx = lumit_render::plan::PlanContext {
            doc,
            quality: self.decode_quality(),
            probes: &self.media,
            retime_override: retime.as_ref(),
        };
        lumit_render::plan::collect_comp_jobs(&ctx, comp, t, jobs, visited);
    }

    /// Throw away every rendered frame of every comp, because something
    /// outside the document changed what they look like — today only a media
    /// probe landing (found, missing, or unreadable).
    ///
    /// The frame key describes the *document*, so it cannot tell those apart:
    /// a frame rendered while a file's state was still unknown, then banked
    /// once it became known, is filed under a key that promises different
    /// pixels. That is what left a missing-footage comp showing the slate on
    /// the frame you were sitting on and black on every other — the frames
    /// either side had already been banked empty by the background fill.
    ///
    /// This clears what is *banked*; it cannot touch what is still in flight,
    /// so it is only half the guard. [`AppState::media_epoch`] is the other
    /// half, and the two are always bumped together. Probes land rarely
    /// (open, import, relink), and mostly before much is cached, so dropping
    /// the lot is cheap and leaves nothing to reason about.
    /// Whether a comp frame that finished rendering may still be used, given
    /// the [`media_epoch`](AppState::media_epoch) it was rendered under.
    ///
    /// False means a probe landed while it was in flight, so it drew a source
    /// whose state was still unknown — an empty layer where there is now a
    /// slate. Such a frame must be neither shown nor banked: the key it would
    /// be filed under is computed from the *current* document and promises
    /// the picture the render never drew.
    #[cfg(feature = "media")]
    pub fn accepts_comp_frame(&self, media_epoch: u64) -> bool {
        media_epoch == self.media_epoch
    }

    #[cfg(feature = "media")]
    pub fn invalidate_rendered_frames(&mut self) {
        self.comp_frame_cache.clear();
        self.cached_present = None;
        self.cache_epoch += 1;
    }

    /// Re-request the current preview frame (selection/scrub/resolution change).
    #[cfg(feature = "media")]
    pub fn refresh_preview(&mut self) {
        if self.preview_comp.is_some() {
            self.refresh_comp_preview();
            return;
        }
        let Some(id) = self.preview_item else { return };
        let doc = self.store.snapshot();
        let Some(ProjectItem::Footage(f)) = doc.item(id) else {
            return;
        };
        // A lost file previewed on its own shows the same bars a comp shows
        // for it (docs/07 §3.3). Without this the Viewer drew nothing at all —
        // a black panel that looks exactly like a broken application, and
        // never recovers, because nothing further triggers a render. Sized
        // 1920×1080: a file we cannot open has no size to report.
        if matches!(self.media.map.get(&id), Some(media::MediaStatus::Missing)) {
            self.preview_frame = 0;
            self.preview_engine.request_slate(id, (1920, 1080));
            return;
        }
        let (width, frames) = match self.media.map.get(&id) {
            Some(media::MediaStatus::Ready { probe, frames, .. }) => {
                (probe.video.as_ref().map(|v| v.width).unwrap_or(0), *frames)
            }
            _ => return, // not probed yet; selection will refresh on Ready
        };
        if frames == 0 || width == 0 {
            return;
        }
        self.preview_frame = self.preview_frame.min(frames - 1);
        let target = self.target_width_for(width);
        self.preview_engine.request(
            id,
            PathBuf::from(&f.media.absolute_path),
            self.preview_frame,
            target,
        );
    }

    /// Frames-per-second of the current preview item, once probed.
    #[cfg(feature = "media")]
    pub fn preview_fps(&self) -> Option<f64> {
        let id = self.preview_item?;
        match self.media.map.get(&id) {
            Some(media::MediaStatus::Ready { probe, .. }) => {
                probe.video.as_ref().map(|v| v.fps()).filter(|f| *f > 0.0)
            }
            _ => None,
        }
    }

    /// Kick off background audio decode for the preview item (idempotent).
    #[cfg(feature = "media")]
    pub fn request_preview_audio(&mut self) {
        let Some(id) = self.preview_item else { return };
        let has_audio = matches!(
            self.media.map.get(&id),
            Some(media::MediaStatus::Ready { probe, .. }) if probe.audio.is_some()
        );
        if !has_audio {
            return;
        }
        let doc = self.store.snapshot();
        let Some(ProjectItem::Footage(f)) = doc.item(id) else {
            return;
        };
        let path = PathBuf::from(&f.media.absolute_path);
        self.request_footage_audio(id, path);
    }

    /// Decode one footage item's whole audio into the byte-budgeted cache on
    /// a background thread — the single decode both the footage preview and
    /// the comp mix draw from. Idempotent: cached, in-flight and failed items
    /// are not re-spawned (the failed set is cleared when a project is
    /// opened, so a fixed path gets retried after a relink-and-reopen).
    #[cfg(feature = "media")]
    pub fn request_footage_audio(&mut self, id: Uuid, path: PathBuf) {
        if self.audio_cache.contains_key(&id)
            || self.audio_decode_pending.contains(&id)
            || self.audio_decode_failed.contains(&id)
        {
            return;
        }
        let rate = self
            .ensure_audio_engine()
            .map(|e| e.device_rate())
            .unwrap_or(48_000);
        self.audio_decode_pending.insert(id);
        let tx = self.audio_tx.clone();
        std::thread::spawn(move || {
            let result = lumit_media::audio::decode_all(&path, rate).map_err(|e| e.to_string());
            let _ = tx.send((id, result));
        });
    }

    /// Resize the decoded-audio budget (Settings → Performance).
    #[cfg(feature = "media")]
    pub fn set_audio_cache_budget(&mut self, bytes: usize) {
        self.audio_cache.set_budget(bytes);
    }

    /// The `(source duration s, peaks)` strip of one item's decoded audio
    /// for the per-layer Waveform lane (K-172): 2048 (min,max) buckets over
    /// the whole source, computed once from the shared decoded buffer and
    /// memoised. `None` until the decode lands — this kicks it off, so the
    /// lane fills in on a later frame.
    #[cfg(feature = "media")]
    pub fn item_waveform(
        &mut self,
        item: Uuid,
        path: &std::path::Path,
    ) -> Option<super::ItemWaveform> {
        if let Some(w) = self.item_waveforms.get(&item) {
            return Some(w.clone());
        }
        let hit = self
            .audio_cache
            .get(&item)
            .map(|c| std::sync::Arc::clone(&c.0));
        match hit {
            Some(buf) => {
                let frames = buf.samples.len() / 2;
                let dur = frames as f64 / f64::from(buf.rate.max(1));
                let peaks = lumit_audio::mix::waveform_peaks(&buf.samples, 2048);
                let strip = std::sync::Arc::new((dur, peaks));
                self.item_waveforms.insert(item, strip.clone());
                Some(strip)
            }
            None => {
                self.request_footage_audio(item, path.to_owned());
                None
            }
        }
    }

    #[cfg(feature = "media")]
    pub(crate) fn ensure_audio_engine(&mut self) -> Option<&lumit_audio::AudioEngine> {
        if self.audio_engine.is_none() {
            match lumit_audio::AudioEngine::new() {
                Ok(engine) => self.audio_engine = Some(engine),
                Err(e) => {
                    self.error = Some(format!("audio: {e}"));
                    return None;
                }
            }
        }
        self.audio_engine.as_ref()
    }

    /// Drain finished audio decodes; auto-load the current preview item's.
    #[cfg(feature = "media")]
    pub fn poll_audio(&mut self) {
        while let Ok((id, result)) = self.audio_rx.try_recv() {
            self.audio_decode_pending.remove(&id);
            match result {
                Ok(buffer) => {
                    let cached = super::CachedAudio(std::sync::Arc::new(buffer));
                    if !self.audio_cache.insert(id, cached) {
                        // Larger than the whole audio budget: don't retry every
                        // frame; the comp mix falls back to decode-per-bake.
                        self.audio_decode_failed.insert(id);
                        self.error = Some(
                            "audio is larger than the audio cache budget (Settings → Performance)"
                                .into(),
                        );
                    }
                }
                Err(e) => {
                    self.audio_decode_failed.insert(id);
                    self.error = Some(format!("audio decode: {e}"));
                }
            }
        }
    }

    /// Every audible footage layer with an audio stream, as mixdown jobs —
    /// including the ones inside Precomp layers, walked recursively with
    /// their times mapped onto the outer comp and their carriers' Volumes
    /// chained (owner: a precomp holding music was silent). The one list
    /// playback, beat detection, and export all mix from, so they always
    /// hear the same comp.
    #[cfg(feature = "media")]
    pub fn comp_audio_jobs(
        &self,
        doc: &lumit_core::model::Document,
        comp: &lumit_core::model::Composition,
    ) -> Vec<lumit_render::export::AudioJob> {
        let mut jobs = Vec::new();
        let mut visited = vec![comp.id];
        self.collect_audio_jobs(
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

    /// Whether a comp holds any audio — its own footage layers' streams, or
    /// (recursively) a nested Precomp's. Gates the Audio group on Precomp
    /// layers in the outline. `visited` must already contain the comp ids on
    /// the walk so a comp cycle terminates.
    #[cfg(feature = "media")]
    pub fn comp_has_audio(
        &self,
        doc: &lumit_core::model::Document,
        comp_id: Uuid,
        visited: &mut Vec<Uuid>,
    ) -> bool {
        use lumit_core::model::LayerKind;
        let Some(comp) = doc.comp(comp_id) else {
            return false;
        };
        for layer in &comp.layers {
            match &layer.kind {
                LayerKind::Footage { item, .. } => {
                    if matches!(
                        self.media.map.get(item),
                        Some(media::MediaStatus::Ready { probe, .. }) if probe.audio.is_some()
                    ) {
                        return true;
                    }
                }
                LayerKind::Precomp { comp: nested } if !visited.contains(nested) => {
                    visited.push(*nested);
                    if self.comp_has_audio(doc, *nested, visited) {
                        return true;
                    }
                    visited.pop();
                }
                _ => {}
            }
        }
        false
    }

    /// The recursive walk behind [`Self::comp_audio_jobs`]. `base_s` is where
    /// this comp's time 0 sits on the OUTER timeline; `window` is the span the
    /// carrier chain leaves audible (each Precomp layer's own in/out clips its
    /// contents); `carriers` are the enclosing Precomp layers' Volumes with
    /// their outer-time offsets, applied on top of each job's own.
    #[cfg(feature = "media")]
    #[allow(clippy::too_many_arguments)]
    fn collect_audio_jobs(
        &self,
        doc: &lumit_core::model::Document,
        comp: &lumit_core::model::Composition,
        base_s: f64,
        window: (f64, f64),
        carriers: &[(lumit_core::anim::Property, f64)],
        visited: &mut Vec<Uuid>,
        jobs: &mut Vec<lumit_render::export::AudioJob>,
    ) {
        use lumit_core::model::LayerKind;
        // Solo silences non-soloed audio exactly as it hides non-soloed video
        // (docs/09 §6), scoped per comp: a solo inside a precomp isolates
        // within that precomp. Mirrors the video gate in draws.rs / export.rs.
        let any_solo = lumit_core::model::any_solo(comp);
        for layer in &comp.layers {
            if !layer.switches.audible || (any_solo && !layer.switches.solo) {
                continue;
            }
            // This layer's span mapped to the outer timeline, clipped to what
            // the carrier chain leaves audible.
            let in_s = (layer.in_point.0.to_f64() + base_s).max(window.0);
            let out_s = (layer.out_point.0.to_f64() + base_s).min(window.1);
            if out_s <= in_s {
                continue;
            }
            let offset_s = layer.start_offset.0.to_f64() + base_s;
            match &layer.kind {
                LayerKind::Footage { item, .. } => {
                    let has_audio = matches!(
                        self.media.map.get(item),
                        Some(media::MediaStatus::Ready { probe, .. }) if probe.audio.is_some()
                    );
                    if !has_audio {
                        continue;
                    }
                    let Some(ProjectItem::Footage(f)) = doc.item(*item) else {
                        continue;
                    };
                    jobs.push(lumit_render::export::AudioJob {
                        item: *item,
                        path: PathBuf::from(&f.media.absolute_path),
                        in_s,
                        out_s,
                        offset_s,
                        volume: layer.volume_db.clone(),
                        carriers: carriers.to_vec(),
                    });
                }
                LayerKind::Precomp { comp: nested_id } => {
                    if visited.contains(nested_id) {
                        continue; // cycle guard
                    }
                    let Some(nested) = doc.comp(*nested_id) else {
                        continue;
                    };
                    // The precomp layer's own Volume joins the carrier chain,
                    // evaluated in its own layer time (outer t − offset).
                    let mut chain = carriers.to_vec();
                    chain.push((layer.volume_db.clone(), offset_s));
                    visited.push(*nested_id);
                    self.collect_audio_jobs(
                        doc,
                        nested,
                        offset_s,
                        (in_s, out_s),
                        &chain,
                        visited,
                        jobs,
                    );
                    visited.pop();
                }
                _ => {}
            }
        }
    }

    /// Kick off background decode + mix of a comp's audio layers into one
    /// buffer (Pulsar mix): the layers' sound laid on the comp timeline at
    /// their offsets and trims. The result arrives via [`Self::poll_comp_audio`].
    /// A comp with no audio layers prepares nothing (it plays on the fallback
    /// wall clock).
    #[cfg(feature = "media")]
    pub fn prepare_comp_audio(&mut self, comp_id: Uuid) {
        let doc = self.store.snapshot();
        let Some(comp) = doc.comp(comp_id) else {
            return;
        };
        let rate = self
            .ensure_audio_engine()
            .map(|e| e.device_rate())
            .unwrap_or(48_000);
        let jobs = self.comp_audio_jobs(&doc, comp);
        if jobs.is_empty() {
            return; // silent comp: wall-clock fallback drives playback
        }
        let duration_s = comp.duration.0.to_f64();
        let sig = super::audio_jobs_signature(&jobs, duration_s);
        if self.audio_preparing == Some((comp_id, sig)) {
            return; // this exact mix is already on its way
        }
        // Live-mix path: build a MixPlan over the byte-budgeted decoded-audio
        // cache and hand it to the engine *now* — a solo/mute/move/trim edit
        // is heard on the next audio callback, no re-bake. Missing items kick
        // off their one shared decode and the plan waits (sync_comp_audio
        // retries every frame); items the cache cannot hold (decode failed,
        // or larger than the whole budget) drop to the legacy bake thread.
        let mut clips: Vec<lumit_audio::mix::PlacedClip> = Vec::with_capacity(jobs.len());
        let mut fallback = false;
        let mut waiting = false;
        let total_frames = (duration_s * f64::from(rate)).round().max(0.0) as usize;
        for job in &jobs {
            if self.audio_decode_failed.contains(&job.item) {
                fallback = true;
                break;
            }
            // Clone the Arc out first so the cache borrow ends before the
            // &mut self decode request below.
            let hit = self
                .audio_cache
                .get(&job.item)
                .filter(|c| c.0.rate == rate)
                .map(|c| std::sync::Arc::clone(&c.0));
            match hit {
                Some(buffer) => {
                    if let Some((start_frame, src_start, len)) = lumit_audio::mix::place_on_timeline(
                        job.in_s,
                        job.out_s,
                        job.offset_s,
                        buffer.samples.len() / 2,
                        rate,
                    ) {
                        // Volume (docs/09 §6): static → a constant gain;
                        // keyframed → a control-rate envelope. Same bake the
                        // export mixdown uses, so playback == export.
                        let (gain, envelope) =
                            lumit_render::export::volume_bake(job, start_frame, len, rate);
                        clips.push(lumit_audio::mix::PlacedClip {
                            buffer,
                            start_frame,
                            src_start,
                            len,
                            gain,
                            envelope: envelope.map(std::sync::Arc::new),
                        });
                    }
                }
                None => {
                    waiting = true;
                    self.request_footage_audio(job.item, job.path.clone());
                }
            }
        }
        let tx = self.comp_audio_tx.clone();
        if fallback {
            self.audio_preparing = Some((comp_id, sig));
            std::thread::spawn(move || {
                let samples = lumit_render::export::mixdown(&jobs, rate, duration_s);
                let _ = tx.send(super::CompAudioMsg::Baked(
                    comp_id,
                    sig,
                    lumit_media::AudioBuffer { rate, samples },
                ));
            });
            return;
        }
        if waiting {
            return; // decodes in flight; retried next frame with the cache warmer
        }
        // Apply the plan immediately, preserving the clock and play state when
        // this comp's audio is already running (the instant-edit contract).
        let plan = std::sync::Arc::new(lumit_audio::mix::MixPlan {
            clips,
            total_frames,
        });
        let start_s = self.preview_frame as f64 / comp.frame_rate.fps().max(1.0);
        let playing = self.comp_playback.is_some();
        let already = self.audio_loaded_comp == Some(comp_id);
        let Some(engine) = self.ensure_audio_engine() else {
            return;
        };
        if already {
            engine.swap_plan(std::sync::Arc::clone(&plan));
        } else {
            engine.load_plan(std::sync::Arc::clone(&plan));
            engine.seek_seconds(start_s);
            if playing {
                engine.play();
            }
        }
        self.audio_loaded_comp = Some(comp_id);
        self.audio_loaded_sig = Some(sig);
        self.audio_loaded = None;
        // (The comp-wide waveform strip once computed off the plan here is
        // gone, K-172: each audio layer's Waveform twirl draws its own item's
        // peaks instead.)
    }

    /// Drain background comp-audio deliveries. Waveform peaks (the live-mix
    /// path — the plan itself was applied instantly by
    /// [`Self::prepare_comp_audio`]) just update the strip; a legacy baked
    /// mix loads into the engine. Deliveries that no longer match the
    /// document are dropped — [`Self::sync_comp_audio`] keeps state current.
    #[cfg(feature = "media")]
    pub fn poll_comp_audio(&mut self) {
        while let Ok(msg) = self.comp_audio_rx.try_recv() {
            match msg {
                super::CompAudioMsg::Baked(comp_id, sig, buffer) => {
                    if self.audio_preparing == Some((comp_id, sig)) {
                        self.audio_preparing = None;
                    }
                    if self.preview_comp != Some(comp_id) {
                        continue; // the user moved on before the bake finished
                    }
                    let doc = self.store.snapshot();
                    let Some(comp) = doc.comp(comp_id) else {
                        continue;
                    };
                    let fps = comp.frame_rate.fps().max(1.0);
                    // Only present a bake that still matches the document.
                    let current = self.comp_audio_jobs(&doc, comp);
                    if current.is_empty()
                        || super::audio_jobs_signature(&current, comp.duration.0.to_f64()) != sig
                    {
                        continue;
                    }
                    if self.ensure_audio_engine().is_none() {
                        continue;
                    }
                    let playing = self.comp_playback.is_some();
                    let start_s = self.preview_frame as f64 / fps;
                    if let Some(engine) = &self.audio_engine {
                        engine.load(std::sync::Arc::new(buffer));
                        engine.seek_seconds(start_s);
                        if playing {
                            engine.play();
                        }
                    }
                    self.audio_loaded_comp = Some(comp_id);
                    self.audio_loaded_sig = Some(sig);
                    self.audio_loaded = None;
                }
            }
        }
    }

    /// Keep the loaded comp mix in step with the document. Runs each UI frame:
    /// while a comp's audio is being managed (loaded, in flight, or playing),
    /// an edit that changes what the comp sounds like re-bakes the mix, and a
    /// comp that has fallen silent (every audio layer muted or deleted) is
    /// unloaded so it stops sounding. This is what makes muting, moving,
    /// trimming and deleting an audio layer take effect on playback (GEN-4).
    ///
    /// Two comps can need managing: the fronted one, and the one whose mix is
    /// actually sitting in the engine when they differ — editing inside a
    /// fronted precomp stales the PARENT's loaded mix (its jobs walk the
    /// nesting), and gating on the fronted tab alone left that mix playing
    /// stale (owner: a mute inside the precomp changed nothing).
    #[cfg(feature = "media")]
    pub fn sync_comp_audio(&mut self) {
        if let Some(comp_id) = self.preview_comp {
            // Only manage audio we are already responsible for: a mix loaded
            // for this comp, a bake in flight for it, or active playback of
            // it. This keeps a comp with audio from decoding just because it
            // is on screen.
            let managing = self.comp_playback.is_some()
                || self.audio_loaded_comp == Some(comp_id)
                || self.audio_preparing.map(|(c, _)| c) == Some(comp_id);
            if managing {
                self.sync_one_comp_audio(comp_id);
            }
        }
        // The engine's mix is always managed, fronted or not.
        if let Some(loaded) = self.audio_loaded_comp {
            if self.preview_comp != Some(loaded) {
                self.sync_one_comp_audio(loaded);
            }
        }
    }

    /// Reconcile one comp's audio against the document (the body of
    /// [`Self::sync_comp_audio`], per comp).
    #[cfg(feature = "media")]
    fn sync_one_comp_audio(&mut self, comp_id: Uuid) {
        let doc = self.store.snapshot();
        let Some(comp) = doc.comp(comp_id) else {
            return;
        };
        let jobs = self.comp_audio_jobs(&doc, comp);
        match super::comp_audio_sync(
            self.audio_loaded_comp,
            self.audio_loaded_sig,
            self.audio_preparing,
            comp_id,
            &jobs,
            comp.duration.0.to_f64(),
        ) {
            super::AudioSync::UpToDate => {}
            super::AudioSync::Silence => {
                if let Some(engine) = &self.audio_engine {
                    engine.unload();
                }
                self.audio_loaded_comp = None;
                self.audio_loaded_sig = None;
                self.audio_preparing = None;
                // Keep any in-progress playback going on the wall clock, from
                // the current playhead (the audio clock has just gone away).
                if self.comp_playback.is_some() {
                    self.comp_playback = Some(CompPlayback::start(self.preview_frame));
                }
            }
            super::AudioSync::Rebake(_) => {
                self.prepare_comp_audio(comp_id);
            }
        }
    }
}
