//! Latest-wins background frame decoding for the Viewer (slice 5), moved
//! verbatim from app_state.rs.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender, TryRecvError};
use std::sync::Arc;
use uuid::Uuid;

pub struct FramePixels {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
    pub frame: usize,
    pub item: Uuid,
}

pub struct Request {
    pub generation: u64,
    pub item: Uuid,
    pub path: PathBuf,
    pub frame: usize,
    pub target_width: Option<u32>,
    /// The file is missing (docs/07 §3.3): answer with the test-bar slate at
    /// this size instead of decoding. Viewing a lost clip on its own must
    /// show the same bars a comp shows for it — the Viewer previously drew
    /// nothing at all here, which looks identical to a broken application.
    pub slate: Option<(u32, u32)>,
}

/// One layer's decode job inside a comp render request.
pub struct CompJob {
    pub layer: Uuid,
    pub item: Uuid,
    pub path: PathBuf,
    pub source_frame: usize,
    pub target_width: Option<u32>,
    /// The source's native pixel size, independent of the decode width.
    /// Transforms act in comp pixels, so this — not the decoded size —
    /// sizes the layer (auto res must not scale geometry with zoom).
    pub natural_w: u32,
    pub natural_h: u32,
    /// Frame interpolation: `Some((ceil_frame, weight))` pairs
    /// `source_frame` with `ceil_frame` at `weight` (K-021 Blend/Flow).
    pub blend: Option<(usize, f32)>,
    /// When true, `blend`'s pair is combined with optical-flow synthesis
    /// rather than a plain crossfade (K-021 Flow policy).
    pub flow: bool,
    /// Full-resolution flow fields (FlowParams.half_resolution = false).
    pub flow_full: bool,
    /// Neighbour source frames a temporal effect stack needs (echo, flow
    /// motion blur, datamosh): `(offset, source_frame)`, one per non-zero
    /// offset in the stack's temporal window. Empty for a plain layer, so
    /// a single-frame stack decodes exactly one frame.
    pub temporal: Vec<(i32, usize)>,
    /// Set when the stack has a flow-consuming effect (Flow motion blur,
    /// docs/08 §3.2, wants `1`; Datamosh, §3.12, K-104, wants `-1`): the
    /// decode worker measures the dense motion from this frame to the
    /// neighbour at that offset (already fetched via `temporal`) and
    /// stamps it onto [`CompLayerPixels::flow_field`]. See
    /// [`lumit_core::fx::stack_flow_neighbour`].
    pub flow_neighbour: Option<i32>,
    /// The file could not be found (docs/07 §3.3): the worker synthesises the
    /// test-bar slate at the layer's size instead of decoding, so a comp with
    /// missing footage shows unmistakably-absent bars rather than silent
    /// black — and never fails the whole frame.
    pub slate: bool,
}

pub struct CompLayerPixels {
    pub layer: Uuid,
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
    /// Native source size (see [`CompJob::natural_w`]); drives geometry.
    pub natural_w: u32,
    pub natural_h: u32,
    /// Decoded neighbour frames for a temporal effect (see
    /// [`CompJob::temporal`]): `(offset, rgba)`, same size as `rgba`.
    pub temporal: Vec<(i32, Vec<u8>)>,
    /// Dense forward flow (per-pixel `(u, v)` motion in pixels, plus a per-pixel
    /// `conf`idence in 0..1, row-major, same `width × height` as `rgba`) from
    /// this frame to the neighbour at [`CompJob::flow_neighbour`]'s offset,
    /// present only when that neighbour decoded. Fast motion blur (docs/08 §3.2,
    /// offset `1`) smears along it, scaling the streak by `conf` (FX-19);
    /// Datamosh (§3.12, K-104, offset `-1`) warps the previous frame along the
    /// `(u, v)` and ignores `conf`.
    pub flow_field: Option<(Vec<f32>, Vec<f32>, Vec<f32>)>,
}

pub struct CompFrame {
    pub comp: Uuid,
    pub frame: usize,
    /// The media epoch this frame was rendered under — see
    /// `AppState::media_epoch`. A render started before a probe landed drew a
    /// layer whose state was still unknown (so it drew nothing); if its
    /// result arrives afterwards it is banked under a key derived from the
    /// *new* state, filing black pixels under the slate's name. Clearing the
    /// cache when the probe lands cannot help — these frames are still in
    /// flight at that moment — so the receiver drops them by epoch instead.
    ///
    /// Deliberately not the request generation: every request bumps that,
    /// background fills included, so gating on it would let a fill supersede
    /// a display render and the Viewer would stop updating.
    pub media_epoch: u64,
    /// Top-of-stack first (document order); the renderer draws bottom-up.
    pub layers: Vec<CompLayerPixels>,
    /// Wall time this frame's layers took to decode on the worker thread — the
    /// dominant, measurable part of the true render cost. Realtime mode feeds it
    /// to the adaptive controller. Measured here (not as dispatch→display on the
    /// UI thread) so it reflects real work, not the UI's repaint-poll interval —
    /// otherwise every frame would appear to cost one repaint (~16 ms) and the
    /// resolution would walk down even on comps that play fine at Full.
    pub render_cost: std::time::Duration,
}

pub enum PreviewResult {
    Footage(FramePixels),
    Comp(CompFrame),
}

pub struct PreviewEngine {
    tx: Sender<Message>,
    pub results: Receiver<Result<PreviewResult, String>>,
    generation: Arc<AtomicU64>,
}

enum Message {
    Footage(Request),
    Comp {
        generation: u64,
        comp: Uuid,
        frame: usize,
        jobs: Vec<CompJob>,
        media_epoch: u64,
    },
    /// Resize the decoded-frame cache (its slice of the one RAM budget,
    /// Settings → Performance). Applied immediately, never latest-wins-dropped.
    SetCacheBudget(usize),
}

impl Default for PreviewEngine {
    fn default() -> Self {
        let (tx, rx) = channel::<Message>();
        let (result_tx, results) = channel();
        let generation = Arc::new(AtomicU64::new(0));
        let live = generation.clone();
        std::thread::spawn(move || {
            let mut pool = DecodePool::new();
            loop {
                // Block for one request, then drain to the newest (latest
                // wins). Budget messages apply on the spot — they must never
                // be dropped by the latest-wins replacement.
                let mut req = loop {
                    match rx.recv() {
                        Ok(Message::SetCacheBudget(bytes)) => pool.set_budget(bytes),
                        Ok(r) => break r,
                        Err(_) => return,
                    }
                };
                loop {
                    match rx.try_recv() {
                        Ok(Message::SetCacheBudget(bytes)) => pool.set_budget(bytes),
                        Ok(newer) => req = newer,
                        Err(TryRecvError::Empty) => break,
                        Err(TryRecvError::Disconnected) => return,
                    }
                }
                let generation = match &req {
                    Message::Footage(r) => r.generation,
                    Message::Comp { generation, .. } => *generation,
                    Message::SetCacheBudget(_) => continue, // handled above
                };
                if generation != live.load(Ordering::Relaxed) {
                    continue; // superseded while queued
                }
                let result = match req {
                    Message::Footage(r) => pool.decode_footage(&r).map(PreviewResult::Footage),
                    Message::Comp {
                        comp,
                        frame,
                        jobs,
                        media_epoch,
                        ..
                    } => pool
                        // Nobody watches a background decode's progress: the
                        // bar belongs to the frame the Viewer is waiting for.
                        .decode_comp(comp, frame, &jobs, media_epoch, &|_| {})
                        .map(PreviewResult::Comp),
                    Message::SetCacheBudget(_) => continue, // handled above
                };
                let _ = result_tx.send(result);
            }
        });
        Self {
            tx,
            results,
            generation,
        }
    }
}

struct CachedFrame {
    width: u32,
    height: u32,
    rgba: Vec<u8>,
}

impl lumit_cache::ByteSized for CachedFrame {
    fn byte_size(&self) -> usize {
        self.rgba.len() + 16
    }
}

/// The decoders, the decoded-frame cache and the flow backend one decoding
/// context owns.
///
/// # In plain terms
///
/// Opening a video file is expensive and seeking around it is worse, so the
/// pipeline keeps one open decoder per footage item and a byte-budgeted cache of
/// the frames it has already read. This is that state, bundled so it can be
/// owned by whoever is doing the decoding: the background worker thread that
/// serves the egui Viewer, or — for the Flutter frontend, whose render calls
/// already arrive on a worker — the headless renderer itself.
///
/// The decoded-frame cache is what makes a scrub cheap: revisiting a frame is a
/// map lookup rather than a seek and a decode. Note that it holds *decoded
/// source frames*, not finished comp frames — those are named and cached a level
/// up, in [`crate::cache`].
pub struct DecodePool {
    decoders: HashMap<Uuid, lumit_media::VideoDecoder>,
    frame_cache: lumit_cache::ByteLru<(Uuid, usize, Option<u32>), CachedFrame>,
    /// Flow backend, created on the first Flow-policy frame: its own headless
    /// GPU when one exists, the CPU oracle otherwise (lumit-flow degrades by
    /// itself — never a fault).
    flow_engine: Option<lumit_flow::FlowEngine>,
    /// How many comp frames this pool has actually decoded. Diagnostic, and the
    /// thing the drag fast path is *measured* by: a value drag must not move it
    /// (see the headless preview tests).
    comp_decodes: u64,
}

/// The decoded-frame cache's default share of RAM (K-016 tier seed); Settings →
/// Performance moves it.
pub const DEFAULT_DECODE_CACHE_BYTES: usize = 512 * 1024 * 1024;

impl Default for DecodePool {
    fn default() -> Self {
        Self::new()
    }
}

impl DecodePool {
    #[must_use]
    pub fn new() -> Self {
        Self {
            decoders: HashMap::new(),
            frame_cache: lumit_cache::ByteLru::new(DEFAULT_DECODE_CACHE_BYTES),
            flow_engine: None,
            comp_decodes: 0,
        }
    }

    /// How many comp frames this pool has decoded since it was made.
    #[must_use]
    pub fn comp_decodes(&self) -> u64 {
        self.comp_decodes
    }

    /// What the decoded-frame cache is holding, and how many decoders are
    /// open — the pool's share of the memory report (K-294).
    ///
    /// The decoders are counted rather than measured: what a `VideoDecoder`
    /// holds is FFmpeg's business (and, with hardware decode, the driver's), so
    /// a number of them is honest where a number of bytes would be invented.
    #[must_use]
    pub fn memory(&self) -> (usize, usize) {
        (self.frame_cache.used_bytes(), self.decoders.len())
    }

    /// Resize the decoded-frame cache (its slice of the one RAM budget).
    pub fn set_budget(&mut self, bytes: usize) {
        self.frame_cache.set_budget(bytes);
    }

    /// Drop every cached decoded frame, keeping the open decoders (Settings →
    /// Clear cache). The decoders are cheap to keep and expensive to re-open.
    pub fn clear(&mut self) {
        self.frame_cache.clear();
    }

    /// Decode one source frame (or synthesise the missing-footage slate).
    pub fn decode_footage(&mut self, req: &Request) -> Result<FramePixels, String> {
        decode(&mut self.decoders, &mut self.frame_cache, req)
    }

    /// File a frame decoded elsewhere (the decode-ahead thread) into the
    /// decoded-frame cache, under the same key a decode here would use — the
    /// hand-off that makes a prefetched render decode nothing.
    pub fn preload(
        &mut self,
        item: Uuid,
        frame: usize,
        target_width: Option<u32>,
        width: u32,
        height: u32,
        rgba: Vec<u8>,
    ) {
        self.frame_cache.insert(
            (item, frame, target_width),
            CachedFrame {
                width,
                height,
                rgba,
            },
        );
    }

    /// Decode every layer of one comp frame from its plan — the pixels
    /// [`crate::build`] then turns into a draw list. `progress` is called with
    /// the number of jobs finished as each one lands, which is what lets a
    /// Viewer draw an honest bar through the slowest stage of a frame; pass
    /// `&|_| {}` where nobody is watching.
    pub fn decode_comp(
        &mut self,
        comp: Uuid,
        frame: usize,
        jobs: &[CompJob],
        media_epoch: u64,
        progress: &dyn Fn(usize),
    ) -> Result<CompFrame, String> {
        self.comp_decodes += 1;
        decode_comp(
            &mut self.decoders,
            &mut self.frame_cache,
            &mut self.flow_engine,
            comp,
            frame,
            jobs,
            media_epoch,
            progress,
        )
    }
}

fn decode(
    decoders: &mut HashMap<Uuid, lumit_media::VideoDecoder>,
    cache: &mut lumit_cache::ByteLru<(Uuid, usize, Option<u32>), CachedFrame>,
    req: &Request,
) -> Result<FramePixels, String> {
    if let Some((w, h)) = req.slate {
        let (w, h) = (w.max(1), h.max(1));
        return Ok(FramePixels {
            width: w,
            height: h,
            rgba: lumit_media::slate::colour_bars(w, h),
            frame: req.frame,
            item: req.item,
        });
    }
    let cache_key = (req.item, req.frame, req.target_width);
    if let Some(hit) = cache.get(&cache_key) {
        return Ok(FramePixels {
            width: hit.width,
            height: hit.height,
            rgba: hit.rgba.clone(),
            frame: req.frame,
            item: req.item,
        });
    }
    let dec = match decoders.entry(req.item) {
        std::collections::hash_map::Entry::Occupied(e) => e.into_mut(),
        std::collections::hash_map::Entry::Vacant(e) => {
            let index =
                lumit_media::index::build_frame_index(&req.path).map_err(|e| e.to_string())?;
            let dec =
                lumit_media::VideoDecoder::open(&req.path, index).map_err(|e| e.to_string())?;
            e.insert(dec)
        }
    };
    let frame = req.frame.min(dec.frame_count().saturating_sub(1));
    let out = dec
        .frame_rgba(frame, req.target_width)
        .map_err(|e| e.to_string())?;
    cache.insert(
        cache_key,
        CachedFrame {
            width: out.width,
            height: out.height,
            rgba: out.rgba.clone(),
        },
    );
    Ok(FramePixels {
        width: out.width,
        height: out.height,
        rgba: out.rgba,
        frame,
        item: req.item,
    })
}

impl PreviewEngine {
    /// Ask for a frame; any not-yet-decoded older request is abandoned.
    pub fn request(&self, item: Uuid, path: PathBuf, frame: usize, target_width: Option<u32>) {
        self.request_inner(item, path, frame, target_width, None);
    }

    /// As [`Self::request`], but answers with the missing-footage slate at
    /// `size` rather than decoding (docs/07 §3.3).
    pub fn request_slate(&self, item: Uuid, size: (u32, u32)) {
        self.request_inner(item, PathBuf::new(), 0, None, Some(size));
    }

    fn request_inner(
        &self,
        item: Uuid,
        path: PathBuf,
        frame: usize,
        target_width: Option<u32>,
        slate: Option<(u32, u32)>,
    ) {
        let generation = self.generation.fetch_add(1, Ordering::Relaxed) + 1;
        let _ = self.tx.send(Message::Footage(Request {
            generation,
            item,
            path,
            frame,
            target_width,
            slate,
        }));
    }

    /// Ask for every layer frame of a comp at one comp frame (latest wins).
    /// Resize the decoded-frame cache (its slice of the RAM budget).
    pub fn set_cache_budget(&self, bytes: usize) {
        let _ = self.tx.send(Message::SetCacheBudget(bytes));
    }

    pub fn request_comp(&self, comp: Uuid, frame: usize, jobs: Vec<CompJob>, media_epoch: u64) {
        let generation = self.generation.fetch_add(1, Ordering::Relaxed) + 1;
        let _ = self.tx.send(Message::Comp {
            generation,
            comp,
            frame,
            media_epoch,
            jobs,
        });
    }
}

#[allow(clippy::too_many_arguments)]
fn decode_comp(
    decoders: &mut HashMap<Uuid, lumit_media::VideoDecoder>,
    cache: &mut lumit_cache::ByteLru<(Uuid, usize, Option<u32>), CachedFrame>,
    flow_engine: &mut Option<lumit_flow::FlowEngine>,
    comp: Uuid,
    frame: usize,
    jobs: &[CompJob],
    media_epoch: u64,
    progress: &dyn Fn(usize),
) -> Result<CompFrame, String> {
    let decode_started = std::time::Instant::now();
    let mut layers = Vec::with_capacity(jobs.len());
    for job in jobs {
        let req = Request {
            generation: 0,
            item: job.item,
            path: job.path.clone(),
            frame: job.source_frame,
            target_width: job.target_width,
            slate: None, // the comp path builds its slate below, from natural size
        };
        // Missing media renders the slate; nothing else about the layer
        // changes, so transforms, effects and blending all still apply.
        let px = if job.slate {
            let (w, h) = (job.natural_w.max(1), job.natural_h.max(1));
            FramePixels {
                width: w,
                height: h,
                rgba: lumit_media::slate::colour_bars(w, h),
                frame: job.source_frame,
                item: job.item,
            }
        } else {
            decode(decoders, cache, &req)?
        };
        // Neighbour frames for a temporal effect (job.temporal is empty
        // for a plain layer, so this loop does nothing then). A neighbour
        // that fails to decode is simply dropped — a missing echo tap
        // degrades the effect, never the frame.
        let temporal: Vec<(i32, Vec<u8>)> = job
            .temporal
            .iter()
            .filter_map(|&(offset, frame)| {
                let nreq = Request {
                    generation: 0,
                    item: job.item,
                    path: job.path.clone(),
                    frame,
                    target_width: job.target_width,
                    slate: None,
                };
                decode(decoders, cache, &nreq)
                    .ok()
                    .map(|p| (offset, p.rgba))
            })
            .collect();
        // Flow motion blur (docs/08 §3.2, offset +1) and Datamosh (§3.12,
        // K-104, offset -1) both need a dense motion field: the forward
        // flow from this frame to the requested neighbour (already
        // decoded above). Computed from the raw current frame before it
        // is consumed into `rgba` below, where both frames live as RGBA —
        // exactly as the Flow retiming policy computes its flow, on the
        // shared engine that reuses the GPU when one is present. A
        // dropped neighbour just leaves it None, degrading the
        // flow-consuming effect to a passthrough.
        let flow_field = job.flow_neighbour.and_then(|offset| {
            temporal
                .iter()
                .find(|(o, _)| *o == offset)
                .map(|(_, other)| {
                    let (w, h) = (px.width as usize, px.height as usize);
                    let ga = lumit_flow::to_gray(&px.rgba, w, h);
                    let gb = lumit_flow::to_gray(other, w, h);
                    let (fwd, bwd) = flow_engine
                        .get_or_insert_with(lumit_flow::FlowEngine::new_auto)
                        .flow_pair(&ga, &gb);
                    // The per-pixel confidence Fast motion blur tapers the streak
                    // by (FX-19); the same deterministic function export runs, so
                    // the two match (K-031). Datamosh ignores it.
                    let conf = lumit_flow::confidence(&fwd, &bwd);
                    (fwd.u, fwd.v, conf)
                })
        });
        // Blend / Flow policy: combine with the next source frame.
        let rgba = if let Some((ceil, w)) = job.blend {
            let req2 = Request {
                generation: req.generation,
                item: req.item,
                path: job.path.clone(),
                frame: ceil,
                target_width: req.target_width,
                slate: None,
            };
            let px2 = decode(decoders, cache, &req2)?;
            if job.flow {
                let quality = if job.flow_full {
                    lumit_flow::FlowQuality::Full
                } else {
                    lumit_flow::FlowQuality::Half
                };
                flow_engine
                    .get_or_insert_with(lumit_flow::FlowEngine::new_auto)
                    .interpolate_at(
                        &px.rgba,
                        &px2.rgba,
                        px.width as usize,
                        px.height as usize,
                        w,
                        quality,
                    )
            } else {
                lumit_core::pixels::blend_rgba(&px.rgba, &px2.rgba, w)
            }
        } else {
            px.rgba
        };
        layers.push(CompLayerPixels {
            layer: job.layer,
            width: px.width,
            height: px.height,
            rgba,
            natural_w: job.natural_w,
            natural_h: job.natural_h,
            temporal,
            flow_field,
        });
        // One more source frame in hand. Reported after the layer is filed, so
        // "n of m done" is true of what has actually been decoded.
        progress(layers.len());
    }
    Ok(CompFrame {
        comp,
        frame,
        media_epoch,
        layers,
        render_cost: decode_started.elapsed(),
    })
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    /// **The decode-ahead hand-off.** A frame filed by [`DecodePool::preload`]
    /// must be served by the render's own decode as a cache hit — proven by
    /// requesting it against a path that does not exist, which would error if
    /// anything tried to open a decoder. And the key is the whole contract:
    /// a different decode width is a genuine miss, never a wrong-sized hit.
    #[test]
    fn a_preloaded_frame_is_served_without_touching_the_file() {
        let mut pool = DecodePool::new();
        let item = Uuid::now_v7();
        pool.preload(item, 3, Some(64), 2, 2, vec![200u8; 16]);

        let hit = pool.decode_footage(&Request {
            generation: 0,
            item,
            path: PathBuf::from("Z:/definitely/not/here/gone.mp4"),
            frame: 3,
            target_width: Some(64),
            slate: None,
        });
        let px = hit.expect("preloaded pixels are a cache hit; the file does not exist");
        assert_eq!((px.width, px.height, px.rgba[0]), (2, 2, 200));

        // Same frame, different decode width: not this entry.
        assert!(pool
            .decode_footage(&Request {
                generation: 0,
                item,
                path: PathBuf::from("Z:/definitely/not/here/gone.mp4"),
                frame: 3,
                target_width: None,
                slate: None,
            })
            .is_err());
    }
}
