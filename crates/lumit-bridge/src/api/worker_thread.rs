use std::{eprintln, println, sync::mpsc::Receiver};

use crate::api::composition::BridgePlaybackMode;
use flutter_rust_bridge::frb;
use lumit_core::model::EffectInstance;
use lumit_render::{HeadlessRenderer, PreviewEngine};

// The quality policy is v0's, shared rather than copied: two implementations of
// "what does a scale of 0.5 mean for the decode" would drift, and the two
// frontends would then decode at different sizes for the same on-screen scale.
use crate::render::quality_for;
use uuid::Uuid;

// Each frame type is only constructed by its own platform's `publish_frame`, so
// importing both unconditionally would warn on one of them in every build.
// Windows and macOS share the handle-shaped frame: an opaque integer naming a
// surface (an NT handle there, an `IOSurfaceID` here) plus its size, which is
// why they share this import, the `publish_zero_copy` body and the Dart
// `RenderedSharedTexture` case (K-195).
#[cfg(any(
    all(windows, feature = "shared-texture"),
    all(target_os = "macos", feature = "shared-texture-macos")
))]
use crate::api::state::BridgeSharedFrameInfo;
#[cfg(all(target_os = "linux", feature = "shared-texture-linux"))]
use crate::api::state::BridgeSharedFrameInfoLinux;

use crate::api::{
    composition::CompositionReference,
    layer::LayerReference,
    project::ProjectReference,
    state::{WorkerResponse, WorkerResponseStream},
    BridgeError,
};

#[frb(ignore)]
pub struct WorkerState {
    /// The realtime preview-tier controller (K-030/K-171). Held so the worker
    /// can feed it measured render costs and read the tier back, which is not
    /// wired yet — see docs/TODO.md, "Bridge".
    #[allow(dead_code)]
    pub preview_engine: PreviewEngine,
    /// The session's renderer, owned outright by this thread — no lock, because
    /// nothing else touches it. Every `publish_frame` variant reads it.
    pub renderer: HeadlessRenderer,
    pub project: ProjectReference,
    /// Playback, when it is running. `None` means the worker is idle and blocks
    /// waiting for something to do.
    playback: Option<Playback>,
    /// The decode-ahead thread (docs/impl/playback-scheduler.md §5): playback
    /// posts the source decodes coming frames will need, and files the results
    /// into the renderer's cache, so decode runs alongside compositing rather
    /// than before it.
    prefetcher: crate::prefetch::Prefetcher,
    /// Where the user is looking — the comp, frame and scale last shown — the
    /// idle cache-fill's anchor (docs/06 §5.5).
    last_shown: Option<(CompositionReference, u64, f32)>,
    /// The disk tier (docs/06 §5.4) and its IO thread. Owned here because this
    /// is the thread that has both halves of every hand-off: the renderer whose
    /// evictions fall to disk, and the frame keys to file them under.
    disk: lumit_render::diskio::DiskIo,
    /// Disk frames asked for and not yet arrived, with the position each was
    /// asked for — a frame off disk carries only its name, and putting it back
    /// on the card records where it sits.
    disk_wanted: std::collections::HashMap<u128, lumit_render::FrameProvenance>,
    /// The disk budget last applied, the clear count last honoured, and the
    /// location epoch last opened — all arriving as atomics from the settings
    /// ops (see [`crate::framecache::disk`]).
    applied_disk_budget: u64,
    seen_disk_clears: u64,
    seen_disk_location: (u64, Option<std::path::PathBuf>),
    /// The VRAM budget last applied and the clear-request count last honoured
    /// (both arrive as atomics from the settings ops — see
    /// [`crate::framecache::vram`]).
    applied_vram_budget: usize,
    seen_vram_clears: u64,
    /// `(used, entries)` last published for the VRAM meter, so an unchanged
    /// cache publishes nothing.
    published_vram: (u64, u64),
    /// What the cache bar's published strip was computed from, so an unchanged
    /// world is not hashed again: what the bar asked for, the document revision,
    /// and each tier's own change counter.
    published_bar: Option<BarFingerprint>,
    /// The strip as last published, and how far the refinement pass has got
    /// through it — see [`publish_cache_bar`]. Kept between turns so a long
    /// composition converges to per-frame truth instead of staying sampled.
    bar_strip: Vec<u8>,
    bar_refined_to: u64,
    /// When the strip was last published — see [`BAR_MIN_INTERVAL`].
    bar_published_at: std::time::Instant,
    /// True when the idle fill has nothing left to do (everything near the
    /// playhead is held, or the budget is full). Cleared whenever the anchor,
    /// the document or the budget moves.
    fill_exhausted: bool,
    /// When the last request arrived — the fill waits out a ~200 ms lull
    /// after it (docs/06 §5.5), so a scrub in progress is never contended.
    last_request: std::time::Instant,
    /// The one soloed-layer render the dropper is reading, against the
    /// `(comp, frame, layer, generation)` it was made for — see
    /// [`sample_layer_alone`]. One entry, because the dropper only ever reads
    /// one layer at a time and a pointer drag asks for the same one on every
    /// move.
    layer_sample: Option<LayerSample>,
}

/// One soloed-layer render, held for the dropper (see [`sample_layer_alone`]).
#[frb(ignore)]
struct LayerSample {
    /// `(comp, frame, layer, document revision)` — what this render is of. The
    /// revision is what retires it when an edit lands: the frame cache has no
    /// generation counter any more (K-214 names every frame by its content), and
    /// a soloed render is of a document nobody else holds, thus it cannot be
    /// named the same way.
    stamp: (Uuid, u64, Uuid, u64),
    width: u32,
    height: u32,
    rgba: Vec<u8>,
}

/// How often the cache bar's strip may be recomputed. Building it names every
/// frame of the composition, which is a hash apiece — cheap per frame, worth
/// bounding across a long one. A tenth of a second is far finer than the eye
/// needs on a progress stripe and leaves the worker's core to the fill.
const BAR_MIN_INTERVAL: std::time::Duration = std::time::Duration::from_millis(150);

/// The same, while playback is running.
///
/// This walk shares the thread that renders frames, and during playback that
/// thread has a deadline: every millisecond spent naming frames for the stripe
/// is a millisecond the next frame does not have. Half a second still fills the
/// bar visibly as playback lays frames down — a stripe is not something read at
/// frame precision — and it cuts the work to a third of what an idle editor,
/// which has the whole thread to itself, is happy to spend.
const BAR_MIN_INTERVAL_PLAYING: std::time::Duration = std::time::Duration::from_millis(500);

/// The most frames named in the bar's **first** pass over a composition. A
/// longer one is sampled every `frames / this` frames, each sample filling its
/// stride, so the whole stripe has an answer immediately rather than filling in
/// from the left. The refinement pass below then replaces those samples with
/// per-frame truth.
const BAR_MAX_SAMPLES: u64 = 1024;

/// How many frames the refinement pass names per turn. The first pass gives the
/// whole stripe a coarse answer; this walks it in chunks, replacing each sample
/// with the frames it stood for, so a composition of any length reaches per-frame
/// truth within a second or two of standing still — and no single turn costs more
/// than the first pass did.
const BAR_REFINE_PER_TURN: u64 = 1024;

/// The coarser preview scales worth probing for the bar's dimmed state: the
/// adaptive tiers the realtime controller actually drops to (Half, Third,
/// Quarter — [`crate::realtime::tier_scale`]). Under content keying the scale is
/// inside the name, so "held at *some* coarser scale" cannot be read off a hash;
/// these are the scales frames genuinely get cached at, which is what the dimmed
/// state exists to report.
const BAR_COARSE_TIERS: [f32; 3] = [0.5, 1.0 / 3.0, 0.25];

/// What a published cache-bar strip was computed from. Recomputed only when one
/// of these moves, so an editor sitting still hashes nothing.
#[frb(ignore)]
#[derive(PartialEq, Eq, Clone, Copy)]
struct BarFingerprint {
    comp: Uuid,
    frames: u64,
    scale_q: u16,
    revision: u64,
    /// The VRAM cache's change counter — it moves on every insert, clear and
    /// resize, which is what catches a cache at its budget swapping one frame
    /// for another (both totals stay put while the holdings change).
    vram_version: u64,
    ram_entries: u64,
    disk_entries: u64,
}

/// Apply cross-thread cache controls, move frames between the tiers, and keep
/// the meters and the cache bar fresh — run once per worker loop turn, cheap
/// when nothing changed (a handful of atomic loads).
#[frb(ignore)]
fn sync_caches(state: &mut WorkerState) {
    // Nothing here clears a tier because the document changed. It used to: the
    // frames were named by position, so a committed edit did not rename any of
    // them and the only safe answer was to throw them all away. They are named
    // by content now (K-178, docs/06 §5.2), so an edit renames exactly the frames
    // it changed and leaves the rest addressable — which is what keeps the cache
    // bar green through a rename, and what makes an undo instantly valid.
    let budget = crate::framecache::vram::budget();
    if budget != state.applied_vram_budget {
        state.applied_vram_budget = budget;
        state.renderer.set_frame_texture_budget(budget);
        state.fill_exhausted = false;
    }
    // What the cache is holding to, read back from the cache itself rather than
    // from the wish above — so the meter cannot claim a budget the renderer
    // never took.
    crate::framecache::vram::publish_applied(state.renderer.frame_texture_stats().1);
    let clears = crate::framecache::vram::clears();
    if clears != state.seen_vram_clears {
        state.seen_vram_clears = clears;
        state.renderer.clear_frame_textures();
        state.fill_exhausted = false;
    }
    crate::framecache::publish_comp_decodes(state.renderer.decoded_frames());
    let (used, _, entries) = state.renderer.frame_texture_stats();
    if (used as u64, entries as u64) != state.published_vram {
        state.published_vram = (used as u64, entries as u64);
        crate::framecache::vram::publish(used as u64, entries as u64);
    }

    sync_disk(state);
    drain_demotions(state);
    collect_disk_loads(state);
    publish_cache_bar(state);
}

/// Keep the disk tier pointed at the right folder and inside its budget, and
/// mirror what it holds (docs/06 §5.4).
#[frb(ignore)]
fn sync_disk(state: &mut WorkerState) {
    let (epoch, location) = crate::framecache::disk::location();
    let root = disk_root(state, &location);
    if (epoch, root.clone()) != state.seen_disk_location {
        state.seen_disk_location = (epoch, root.clone());
        crate::framecache::disk::publish_root(
            root.as_ref().map(|r| r.to_string_lossy().into_owned()),
        );
        _ = state
            .disk
            .tx
            .send(lumit_render::diskio::Cmd::SetRoot(root.clone()));
        // A different folder holds different frames, so there may be something
        // to promote again.
        state.fill_exhausted = false;
    }
    let budget = crate::framecache::disk::budget();
    if budget != state.applied_disk_budget {
        state.applied_disk_budget = budget;
        _ = state
            .disk
            .tx
            .send(lumit_render::diskio::Cmd::SetCap(budget));
    }
    let clears = crate::framecache::disk::clears();
    if clears != state.seen_disk_clears {
        state.seen_disk_clears = clears;
        _ = state.disk.tx.send(lumit_render::diskio::Cmd::Clear);
    }
    let (disk_used, disk_entries) = state.disk.stats();
    crate::framecache::disk::publish(disk_used, disk_entries);
}

/// Where this project's parked frames belong, for the location the user chose.
///
/// `None` means the tier stays off — only possible on a platform with no home
/// directory at all, since an unsaved project falls back to the application's
/// own cache folder rather than losing the tier (a project caches from the
/// moment it is created; the document's id is in the `.lum` and survives every
/// save, so its frames are still there tomorrow).
#[frb(ignore)]
fn disk_root(
    state: &WorkerState,
    location: &crate::framecache::disk::Location,
) -> Option<std::path::PathBuf> {
    use crate::framecache::disk::Location;
    let (doc_id, own, path) = {
        let project = state.project.state().ok()?;
        let project = project.read().ok()?;
        let document = project.store.snapshot();
        (
            document.id,
            document.cache_location.clone(),
            project.path.clone(),
        )
    };
    // The project's own answer wins where it has one: a project told to cache on
    // a scratch drive, or beside itself, should do that whatever the application
    // is set to (docs/06 §5.4).
    let location = match own {
        Some(lumit_core::model::CacheLocation::AppData) => Location::AppData,
        Some(lumit_core::model::CacheLocation::BesideProject) => Location::BesideProject,
        Some(lumit_core::model::CacheLocation::Custom { folder }) if !folder.is_empty() => {
            Location::Custom(std::path::PathBuf::from(folder))
        }
        // A custom location with no folder in it is not a location.
        Some(lumit_core::model::CacheLocation::Custom { .. }) => Location::AppData,
        None => location.clone(),
    };
    match location {
        Location::AppData => lumit_project::frame_cache_dir(doc_id),
        Location::BesideProject => match path.as_deref() {
            Some(path) => lumit_render::diskio::sidecar_root(path),
            // Nowhere to sit beside yet.
            None => lumit_project::frame_cache_dir(doc_id),
        },
        Location::Custom(root) => match path.as_deref() {
            Some(path) => lumit_render::diskio::cache_root_for(path, Some(&root)),
            None => Some(root.join(format!("{doc_id}-cache"))),
        },
    }
}

/// Collect the frames the graphics card has finished handing back, and put them
/// where they belong: in memory, and parked on disk (docs/06 §5.3's ladder).
///
/// Both are handed over rather than chained — a frame goes to disk on the way
/// down, not when memory later forgets it, so an editor that crashes has still
/// banked what it rendered.
#[frb(ignore)]
fn drain_demotions(state: &mut WorkerState) {
    for mut demoted in state.renderer.poll_demotions() {
        // One allocation for both tiers. The frame goes to memory and to disk at
        // the same time, and it is 8 MB at 1080p, thus a copy for each tier was
        // the most costly part of a demotion.
        let bytes = std::sync::Arc::new(std::mem::take(&mut demoted.rgba));
        _ = state.disk.tx.send(lumit_render::diskio::Cmd::Store {
            hash: demoted.key,
            width: demoted.width,
            height: demoted.height,
            bgra: demoted.bgra,
            bytes: bytes.clone(),
            // What it cost and what size it was made at, so the disk tier's cap
            // can weigh it against its neighbours rather than taking whatever
            // was written first (docs/06 §5.3).
            cost_ms: demoted.cost_ms,
            scale_q: demoted.provenance.scale_q,
        });
        crate::framecache::put_demoted(demoted.key, &demoted, bytes);
    }
}

/// Put frames that have come back off disk onto the graphics card, so a promoted
/// frame is shown without compositing anything (docs/06 §5.1: "promotes
/// disk→RAM→VRAM ahead of the playhead").
#[frb(ignore)]
fn collect_disk_loads(state: &mut WorkerState) {
    let loaded: Vec<_> = state.disk.loaded.try_iter().collect();
    for frame in loaded {
        let Some(provenance) = state.disk_wanted.remove(&frame.hash) else {
            // Nobody is waiting for it any more (a comp switch, a clear); the
            // frame is still on disk and will be asked for again if wanted.
            continue;
        };
        let promoted = state
            .renderer
            .upload_frame_texture(lumit_render::Promotion {
                key: frame.hash,
                bgra: frame.bgra,
                width: frame.width,
                height: frame.height,
                bytes: &frame.bytes,
                // Dear enough to hold on to: a frame that reached disk was worth
                // reading back, and re-rendering it is what this saved.
                cost_ms: DISK_PROMOTION_COST_MS,
                provenance,
            });
        if promoted.is_some() {
            state.fill_exhausted = false;
        }
    }
}

/// The recompute cost a promoted frame is credited with. It is not measured —
/// the render that made it happened in another session, possibly on another day
/// — so it is stated: a frame that earned its way to disk is dear enough that
/// the store should not throw it out ahead of a trivial one.
const DISK_PROMOTION_COST_MS: u32 = 16;

/// Compute and publish the cache bar's per-frame strip (docs/06 §5.6).
///
/// The bar leaves a note saying which composition, how many frames and what
/// preview scale it is drawing; this names each of those frames and asks the
/// three tiers whether they hold it. The interface never touches a cache itself
/// — it could not, since naming a frame needs the renderer's probe results, and
/// hashing hundreds of frames is not work for the thread that paints.
///
/// **Two passes, because the two things the bar owes are in tension.** It owes an
/// answer for the whole composition straight away — a stripe that fills in from
/// one end looks like the *cache* filling in from one end — and it owes the truth
/// per frame, which on a long composition is tens of thousands of hashes. So the
/// first pass samples the whole strip, one frame per stride standing for its
/// neighbours, and a refinement pass then walks it in bounded chunks replacing
/// each sample with the frames it stood for. A composition short enough to name
/// in one go has a stride of one, and its first pass *is* the truth.
///
/// The refinement walk starts at the frame last shown and wraps, so the part of
/// the bar the user is actually looking at is the part that firms up first.
#[frb(ignore)]
fn publish_cache_bar(state: &mut WorkerState) {
    let Some((comp_id, frames, scale_q)) = crate::framecache::bar::wanted() else {
        return;
    };
    if frames == 0 {
        return;
    }
    let interval = if state.playback.is_some() {
        BAR_MIN_INTERVAL_PLAYING
    } else {
        BAR_MIN_INTERVAL
    };
    if state.bar_published_at.elapsed() < interval {
        return;
    }
    let (document, revision) = {
        let Ok(project) = state.project.state() else {
            return;
        };
        let Ok(project) = project.read() else {
            return;
        };
        (project.store.snapshot(), project.store.revision())
    };
    let (ram_entries, disk_entries) = (crate::framecache::stats().2 as u64, state.disk.stats().1);
    let fingerprint = BarFingerprint {
        comp: comp_id,
        frames,
        scale_q,
        revision,
        vram_version: state.renderer.frame_texture_version(),
        ram_entries,
        disk_entries,
    };
    let was = state.published_bar;
    let changed = was != Some(fingerprint);
    // Nothing has moved and the strip is already true per frame: nothing to do.
    // Note the second half — an unchanged world is exactly when the refinement
    // pass gets to make progress, so this cannot simply return on `!changed`.
    if !changed && state.bar_refined_to >= frames {
        return;
    }
    if document.comp(comp_id).is_none() {
        return;
    }
    // Whether every frame's *name* may have changed, as against merely which of
    // them are held. A different composition, length, scale or document revision
    // renames frames, so the strip means nothing and is rebuilt; a frame merely
    // arriving in a tier leaves the names alone, so the strip stands and only its
    // values need refreshing.
    let renamed = was.is_none_or(|old| {
        (old.comp, old.frames, old.scale_q, old.revision) != (comp_id, frames, scale_q, revision)
    });
    state.published_bar = Some(fingerprint);
    state.bar_published_at = std::time::Instant::now();

    let bgra = zero_copy_wants_bgra();
    let scale = f32::from(scale_q) / 1000.0;
    let quality = quality_for(scale);
    let stride = frames.div_ceil(BAR_MAX_SAMPLES).max(1);

    // Naming one frame needs the renderer, the document and the three tiers; the
    // walk over frames needs none of them. Split so the walk can be tested
    // without a graphics card (see `bar_strip_tests`).
    //
    // The strip is taken out of the worker for the duration: naming a frame wants
    // the whole of `state`, and holding a borrow of one of its fields across that
    // is what the borrow checker is for.
    let mut strip = std::mem::take(&mut state.bar_strip);
    let mut refined_to = if changed { 0 } else { state.bar_refined_to };
    let rebuild = renamed || strip.len() != frames as usize;
    let anchor = match &state.last_shown {
        Some((comp, frame, _)) if comp.id == comp_id => *frame % frames,
        _ => 0,
    };
    {
        let mut tier_of =
            |frame: u64| frame_tier(state, &document, comp_id, frame, quality, scale, bgra);
        if rebuild {
            let sampled = sample_bar_strip(frames, stride, &mut tier_of);
            strip = sampled.tiers;
            refined_to = sampled.refined_to;
        } else {
            // Names are the same but holdings may have moved: sweep again from
            // the anchor, keeping the strip on screen while it refreshes.
            refined_to = refine_bar_strip(
                &mut strip,
                anchor,
                refined_to,
                BAR_REFINE_PER_TURN,
                &mut tier_of,
            );
        }
    }
    state.bar_strip = strip;
    state.bar_refined_to = refined_to;
    crate::framecache::bar::publish(comp_id, scale_q, state.bar_strip.clone());
}

/// What the bar should draw for one frame: `0` nothing, `1` held coarser, `2`
/// held at this scale, `3` on disk coarser, `4` on disk at this scale. Playable
/// beats promotable — a frame both held and parked reads as held.
#[frb(ignore)]
fn frame_tier(
    state: &mut WorkerState,
    document: &lumit_core::Document,
    comp: Uuid,
    frame: u64,
    quality: lumit_render::Quality,
    scale: f32,
    bgra: bool,
) -> u8 {
    let mut on_disk_at_scale = false;
    if let Some(key) = state.renderer.frame_key(document, comp, frame, quality) {
        if state.renderer.has_frame_texture(key, bgra) || crate::framecache::contains(key) {
            return 2;
        }
        on_disk_at_scale = state.disk.contains(key);
    }
    let mut on_disk_coarser = false;
    for factor in BAR_COARSE_TIERS {
        let coarser = quality_for(scale * factor);
        let Some(key) = state.renderer.frame_key(document, comp, frame, coarser) else {
            continue;
        };
        if state.renderer.has_frame_texture(key, bgra) || crate::framecache::contains(key) {
            return 1;
        }
        on_disk_coarser |= state.disk.contains(key);
    }
    if on_disk_at_scale {
        4
    } else if on_disk_coarser {
        3
    } else {
        0
    }
}

/// A freshly sampled strip and how much of it counts as exact.
#[frb(ignore)]
struct SampledStrip {
    tiers: Vec<u8>,
    refined_to: u64,
}

/// The first pass: name one frame per `stride` and let it stand for the frames it
/// skipped, so the whole stripe has an answer at once (see
/// [`publish_cache_bar`]). A stride of one names everything, and says so by
/// reporting itself fully refined.
///
/// A skipped run is only painted when its sample is held: an uncached sample
/// leaves its neighbours as nothing, which is what they are until something says
/// otherwise. The reverse — painting a whole stride green off one held frame and
/// correcting it later — would flash cache the user does not have.
#[frb(ignore)]
fn sample_bar_strip(frames: u64, stride: u64, tier_of: &mut dyn FnMut(u64) -> u8) -> SampledStrip {
    let stride = stride.max(1);
    let mut tiers = vec![0u8; frames as usize];
    let mut sample = 0u64;
    while sample < frames {
        let tier = tier_of(sample);
        if tier != 0 {
            let end = (sample + stride).min(frames);
            for slot in &mut tiers[sample as usize..end as usize] {
                *slot = tier;
            }
        }
        sample += stride;
    }
    let refined_to = if stride == 1 { frames } else { 0 };
    SampledStrip { tiers, refined_to }
}

/// One turn of the refinement pass: name up to `per_turn` more frames, starting
/// `refined_to` steps on from `anchor` and wrapping, and write each answer into
/// its own slot. Returns how far the sweep has now got.
///
/// Wrapping from the anchor rather than walking from frame zero is what puts the
/// part of the bar under the playhead first in the queue — on a long composition
/// the difference is whether the region you are looking at firms up now or in a
/// few seconds.
#[frb(ignore)]
fn refine_bar_strip(
    tiers: &mut [u8],
    anchor: u64,
    refined_to: u64,
    per_turn: u64,
    tier_of: &mut dyn FnMut(u64) -> u8,
) -> u64 {
    let frames = tiers.len() as u64;
    if frames == 0 {
        return 0;
    }
    let end = refined_to.saturating_add(per_turn).min(frames);
    for step in refined_to..end {
        let frame = (anchor + step) % frames;
        let tier = tier_of(frame);
        if let Some(slot) = tiers.get_mut(frame as usize) {
            *slot = tier;
        }
    }
    end
}

/// Whether this build's zero-copy transport wants BGRA (Windows and macOS) or
/// RGBA (Linux, and any build without one). The channel order is part of a
/// cached texture's identity, so every consumer has to ask the same question.
#[frb(ignore)]
fn zero_copy_wants_bgra() -> bool {
    cfg!(any(
        all(windows, feature = "shared-texture"),
        all(target_os = "macos", feature = "shared-texture-macos")
    ))
}

/// Ask the disk tier for a frame that playback will want soon.
///
/// **Why the lead time is the whole point.** A read off disk goes to the IO
/// thread, and the frame it brings back arrives one or two turns of the worker
/// loop later. [`prepare_frame`] asks for a frame at the moment it must show it,
/// thus the bytes always come too late for that frame and it is composited
/// again. Playback then gets no good from a span that is parked on disk, which
/// is most of what the disk tier holds after a project is re-opened.
///
/// This asks for the frames that playback will reach in a moment, at the same
/// time as the decodes for those frames go to the prefetch thread. The bytes
/// arrive, [`collect_disk_loads`] puts them on the card, and playback finds the
/// frame already there.
///
/// Nothing here waits and nothing here is expensive: naming a frame is a hash of
/// the composition, and the watermark in [`play_one_frame`] names each coming
/// frame once for each pass of playback.
#[frb(ignore)]
fn request_disk_lead(
    renderer: &mut lumit_render::HeadlessRenderer,
    disk: &lumit_render::diskio::DiskIo,
    disk_wanted: &mut std::collections::HashMap<u128, lumit_render::FrameProvenance>,
    document: &lumit_core::Document,
    comp: Uuid,
    frame: u64,
    quality: lumit_render::Quality,
) {
    let bgra = zero_copy_wants_bgra();
    let Some(key) = renderer.frame_key(document, comp, frame, quality) else {
        // Not nameable yet (footage still being probed), thus not on disk under
        // any name either.
        return;
    };
    if !wants_disk_lead(
        renderer.has_frame_texture(key, bgra),
        crate::framecache::contains(key),
        disk.contains(key),
        disk_wanted.contains_key(&key),
    ) {
        return;
    }
    disk_wanted.insert(
        key,
        lumit_render::FrameProvenance {
            comp,
            frame,
            scale_q: lumit_render::preview_scale_q(quality),
        },
    );
    _ = disk
        .tx
        .send(lumit_render::diskio::Cmd::Load { hash: key, bgra });
}

/// Whether a coming frame is worth a read off disk.
///
/// Only one of the four answers leads to a read: the frame is on disk, and no
/// tier above holds it, and nobody has asked for it yet. A read in any other
/// case is IO for a frame that is already there, or a second copy of a read that
/// is already running.
#[frb(ignore)]
fn wants_disk_lead(on_card: bool, in_memory: bool, on_disk: bool, already_asked: bool) -> bool {
    on_disk && !on_card && !in_memory && !already_asked
}

/// Get one frame ready to show, taking the cheapest route the tiers allow
/// (docs/06 §5.1: VRAM first, then promote from the tiers below, and only then
/// composite).
///
/// The order is the ladder itself:
///
/// 1. **Already on the card** — [`HeadlessRenderer::render_prepared`] answers
///    from its own cache without compositing.
/// 2. **Held in memory** — uploaded straight back into a texture, which is a
///    fraction of a composite and the reason the RAM tier exists at all.
/// 3. **Parked on disk** — *asked for*, never waited on. A disk read plus
///    decompression is not something to hold the preview open for, so the frame
///    is composited now and the copy off disk lands a turn or two later, in time
///    for the next visit. This is what makes reopening a project warm up as you
///    scrub rather than only where the fill has reached. Playback does not wait
///    for that second visit: it asks for the coming frames in advance
///    ([`request_disk_lead`]), thus a parked span plays from the card.
/// 4. **Composited**, and banked on the way past.
#[frb(ignore)]
fn prepare_frame(
    state: &mut WorkerState,
    document: &lumit_core::Document,
    comp: Uuid,
    frame: u64,
    quality: lumit_render::Quality,
    bgra: bool,
    cacheable: bool,
) -> Result<lumit_render::PreparedFrame, String> {
    let name = cacheable
        .then(|| state.renderer.frame_key(document, comp, frame, quality))
        .flatten();
    if let Some(key) = name.filter(|key| !state.renderer.has_frame_texture(*key, bgra)) {
        let provenance = lumit_render::FrameProvenance {
            comp,
            frame,
            scale_q: lumit_render::preview_scale_q(quality),
        };
        match crate::framecache::held(key) {
            // Only the order it came down in can go back up: a frame read in the
            // other channel order would show with red and blue swapped, so it is
            // left for the composite below.
            Some(held) if held.bgra == bgra => {
                if let Some(prepared) =
                    state
                        .renderer
                        .upload_frame_texture(lumit_render::Promotion {
                            key,
                            bgra,
                            width: held.width,
                            height: held.height,
                            bytes: &held.bytes,
                            cost_ms: held.cost_ms,
                            provenance,
                        })
                {
                    return Ok(prepared);
                }
            }
            Some(_) => {}
            None => {
                if state.disk.contains(key) && !state.disk_wanted.contains_key(&key) {
                    state.disk_wanted.insert(key, provenance);
                    _ = state
                        .disk
                        .tx
                        .send(lumit_render::diskio::Cmd::Load { hash: key, bgra });
                }
            }
        }
    }
    // Named once, above: hashing the composition again here would be the same
    // walk twice per frame.
    state
        .renderer
        .render_prepared_named(document, comp, frame, quality, bgra, name)
}

/// Render ONE uncached frame near the playhead into the VRAM frame cache —
/// the idle-time background fill (docs/06 §5.5, forward-biased per
/// [`crate::playback::fill_order`]). One frame per call so a request arriving
/// mid-fill waits at most one render; sets `fill_exhausted` when there is
/// nothing (or no room) left, so an idle editor stops spending the GPU.
#[frb(ignore)]
fn idle_fill(state: &mut WorkerState, stream: &mut WorkerResponseStream) {
    let Some((comp_ref, anchor, scale)) = state.last_shown.clone() else {
        state.fill_exhausted = true;
        return;
    };
    let document = {
        let Ok(document) = state.project.state() else {
            state.fill_exhausted = true;
            return;
        };
        let Ok(document) = document.read() else {
            state.fill_exhausted = true;
            return;
        };
        document.store.snapshot()
    };
    let Some(comp) = document.comp(comp_ref.id) else {
        state.fill_exhausted = true;
        return;
    };
    let frames = comp
        .frame_rate
        .frame_at(lumit_core::time::CompTime(comp.duration.0))
        .max(1) as u64;
    // The work area bounds the fill when one is set (§5.5); else the comp.
    // Both ends are taken through `max(0)` before they are cast: a work area
    // from an older project file may sit outside the comp, and a negative frame
    // number cast unsigned is not a small number, it is an enormous one.
    let (first, last) = match comp.work_area {
        Some((a, b)) => (
            comp.frame_rate.frame_at(a).max(0) as u64,
            (comp.frame_rate.frame_at(b).max(0) as u64).min(frames - 1),
        ),
        None => (0, frames - 1),
    };
    let quality = quality_for(scale);
    let bgra = zero_copy_wants_bgra();
    let (_, budget, _) = state.renderer.frame_texture_stats();
    let (cw, ch) = (comp.width, comp.height);
    let s = scale.clamp(0.05, 1.0);
    let frame_bytes = ((cw as f32 * s) as usize).max(1) * ((ch as f32 * s) as usize).max(1) * 4;
    // A budget that cannot hold one frame is a budget the fill cannot use: the
    // frame would evict itself the moment it landed.
    if budget < frame_bytes {
        state.fill_exhausted = true;
        return;
    }
    // **What the fill keeps is a WINDOW around the playhead**, as many frames as
    // the budget holds, in `fill_order`'s forward-biased shape. It used to stop
    // outright as soon as the cache was within one frame of full — which meant
    // that once the cache filled, moving the playhead banked nothing ever again:
    // the frames it wanted were new, and the ones in the way were far off and
    // stale. Letting it render inside the window puts the eviction decision
    // where it belongs, with the LRU, which drops the stalest and largest first
    // — the far side of where you now are. It still terminates: the walk is
    // bounded, and every frame in the window ends up held.
    let window = (budget / frame_bytes).max(1);
    for frame in crate::playback::fill_order(anchor, first, last).take(window) {
        // Naming the frame is what tells the fill whether there is anything to
        // do — and under content keying the name is the same one every tier files
        // it under, so a frame already held anywhere is skipped without a render.
        if let Some(key) = state
            .renderer
            .frame_key(&document, comp_ref.id, frame, quality)
        {
            if state.renderer.has_frame_texture(key, bgra) {
                continue;
            }
        }
        match prepare_frame(state, &document, comp_ref.id, frame, quality, bgra, true) {
            // Tell the frontend, or the fill is invisible: the cache bar only
            // redraws when it hears something, and a fill shows no frame.
            Ok(_) => _ = stream.add(WorkerResponse::CacheFilled),
            // A comp that will not render must not be retried in a loop.
            Err(_) => state.fill_exhausted = true,
        }
        return;
    }
    state.fill_exhausted = true;
}

#[frb(ignore)]
pub enum WorkerRequest {
    RenderComp(RenderCompRequest),
    RenderCompWithPreview(RenderCompRequestWithPreview),
    TraceScope(RenderScopeRequest),
    /// Read the pixels under the dropper (docs/07 §6.1).
    SamplePixels(SamplePixelsRequest),
    /// Start playing. The worker paces itself from here until it is stopped or
    /// runs off the end.
    Play(PlayRequest),
    /// Stop playing. Harmless when nothing is playing.
    StopPlayback,
}

/// Start playback of `comp` at `from`.
///
/// **Why the worker plays rather than the frontend driving it.** Playback is a
/// decision made once per frame — which frame is next, is the clock ahead of us,
/// is this mode allowed to skip — and every one of those needs the render cost
/// of the frame just finished. The frontend has none of that. It used to guess:
/// a Flutter `Ticker` polled the audio clock each vsync, worked out a frame, and
/// asked for it, with a hand-rolled in-flight counter to stop the requests
/// piling up. That is a scheduler living on the far side of an FFI boundary from
/// everything it needs to schedule against. The frontend now says "play from
/// here" and paints what arrives (K-181).
#[frb(ignore)]
pub struct PlayRequest {
    pub comp: CompositionReference,
    pub from: u64,
    pub mode: BridgePlaybackMode,
    pub scale: f32,
    /// The document the mix is to be built from, snapshotted where play was
    /// asked for rather than read on this thread — the mix must be of the comp
    /// as it was when the button was pressed. The sound itself is started here,
    /// after the pre-roll ([`Playback::pre_roll_done`]).
    pub audio: std::sync::Arc<lumit_core::Document>,
}

/// Playback in progress: what is being played, and where it has got to.
///
/// The scheduler shape (docs/impl/playback-scheduler.md §5): renders run AHEAD
/// of the clock into `ring`, a bounded queue of finished frames still on the
/// graphics card, and each is PRESENTED — one cheap GPU copy — only when it is
/// due. The slack is the point: a span of cheap or cached frames fills the
/// ring, and an expensive frame then spends the banked time instead of
/// stalling the picture. How far ahead is `capacity()`, adapted from the
/// measured p95 render cost. Dropping this struct (stop, seek, a new play)
/// drops the ring and every in-flight frame with it — the cancellation edge.
// ponytail: renders are still serial on this one worker thread, so cancellation
// latency is bounded by one frame's render, not the impl note's 15 ms. Epoch
// tokens inside the render walk (and the worker pool they exist for) are the
// upgrade, docs/impl/playback-scheduler.md §1-2.
/// How many banked frames count as a full pre-roll, and how long the sound is
/// ever made to wait for them (docs/impl/playback-scheduler.md §5).
const PRE_ROLL_FRAMES: usize = 3;
const PRE_ROLL_BUDGET: std::time::Duration = std::time::Duration::from_millis(150);

#[frb(ignore)]
struct Playback {
    comp: CompositionReference,
    /// The frame to render next.
    next: u64,
    /// The last frame of the composition — playback ends after it.
    last: u64,
    mode: BridgePlaybackMode,
    scale: f32,
    /// The composition's rate, for turning a clock reading into a frame.
    fps: f64,
    /// Where playback started, and when — the wall clock's baseline for as long
    /// as no mix is loaded to be master instead.
    from: u64,
    started: std::time::Instant,
    /// When the last frame was shown, for every-frame's pacing. `None`
    /// before the first present of a run.
    last_presented: Option<std::time::Instant>,
    /// Frames rendered ahead of the clock, oldest first, waiting to be shown.
    ring: std::collections::VecDeque<(u64, lumit_render::PreparedFrame)>,
    /// Recent render costs, sizing the ring (`capacity()`).
    costs: crate::playback::CostWindow,
    /// The highest frame whose source decodes have been posted to the
    /// decode-ahead thread this run. A watermark, not a set: playback frames
    /// only move forward, so "post everything from here to there once" is the
    /// whole bookkeeping.
    prefetched_to: Option<u64>,
    /// The mix waiting for the sound to be started, once the picture has
    /// banked enough to start with it (the pre-roll,
    /// [`Self::pre_roll_done`]). `None` once the sound has been started, or
    /// when this run never had any.
    pending_audio: Option<std::sync::Arc<lumit_core::Document>>,
    /// How many frames the last [`Self::advance`] had to jump over to catch the
    /// clock. Zero while playback is keeping up.
    ///
    /// **This is the honest measure of "we cannot keep up", and the only one
    /// available.** The worker can time its own render and hand-off, but that is
    /// not the whole bill: decoding the pixels into an image, painting them, and
    /// whatever else the frontend does per frame all happen after the worker has
    /// let go, and it can never see them. Skipping is the *symptom* of all of it
    /// at once — if the clock has moved past a frame we have not drawn yet, the
    /// round trip cost more than its budget, wherever the time went.
    skipped: u64,
}

impl Playback {
    /// Where playback has actually got to, in seconds.
    ///
    /// The audio clock is master once a mix is loaded; until then — while it is
    /// still decoding, or on a machine with no sound device — the wall clock
    /// stands in, so silence never stops the picture.
    fn elapsed_seconds(&self) -> f64 {
        match clock_seconds() {
            Some(seconds) => seconds,
            None => self.started.elapsed().as_secs_f64() + self.from as f64 / self.fps,
        }
    }

    /// How many frames ahead of the clock to render — the ring's capacity,
    /// adapted from the measured p95 render cost (the impl note's pinned
    /// formula, [`crate::playback::lookahead_frames`]).
    fn capacity(&self) -> usize {
        crate::playback::lookahead_frames(self.costs.p95(), self.fps)
    }

    /// Whether the sound may start: the ring holds a few frames, or the
    /// pre-roll budget is spent.
    ///
    /// **Why the sound waits at all.** Starting the audio stream at the moment
    /// play is pressed means it runs while the first frame is still being
    /// composited — the sound is already a few tens of milliseconds in before
    /// there is anything to see, and in adaptive mode the picture then *skips*
    /// to catch the clock up, so a press of play began with a jump. Filling the
    /// ring first (docs/impl/playback-scheduler.md §5) starts the two together.
    ///
    /// The budget is the other half: a comp too heavy to bank three frames
    /// quickly must not sit in silence waiting: at 150 ms the sound starts
    /// regardless and the picture does what it can.
    fn pre_roll_done(&self, queued: usize) -> bool {
        queued >= PRE_ROLL_FRAMES.min(self.capacity()).max(1)
            || self.started.elapsed() >= PRE_ROLL_BUDGET
    }

    /// Which queued frame to present now — an index into `queued` (the ring's
    /// frame numbers, oldest first) — or `None` while nothing is due yet.
    ///
    /// **This is what keeps playback at the composition's rate.** Renders are
    /// free to run ahead into the ring; the PRESENT is what the user sees, so
    /// the present is what paces. Without this gate a comp cheaper than
    /// realtime would play as fast as the renderer managed — the frontend's
    /// `Ticker` used to supply the pacing for free by only asking once per
    /// vsync, and losing it made a 60 fps comp play at several hundred.
    ///
    /// * **Every-frame** shows every frame in order (the mode's promise), so it
    ///   is always the front — but no sooner than one comp period since the
    ///   last present. It may fall behind (a heavy comp plays slow); it is
    ///   never allowed to run ahead, however full the cache fills the ring
    ///   (K-171: "replays at full speed" means the comp's own rate).
    /// * **Adaptive** keeps time: the NEWEST queued frame the clock has
    ///   reached (docs/impl/playback-scheduler.md §4). The caller drops the
    ///   older entries — the clock has passed them, and showing them would
    ///   mean playing late pictures instead of the current one.
    fn present_choice(&self, queued: &[u64]) -> Option<usize> {
        if queued.is_empty() {
            return None;
        }
        match self.mode {
            BridgePlaybackMode::EveryFrame => {
                let period = std::time::Duration::from_secs_f64(1.0 / self.fps);
                match &self.last_presented {
                    Some(at) if at.elapsed() < period => None,
                    _ => Some(0),
                }
            }
            BridgePlaybackMode::Adaptive => {
                let clock = self.elapsed_seconds();
                queued
                    .iter()
                    .rposition(|&frame| frame as f64 / self.fps <= clock)
            }
        }
    }

    /// How long until the ring's front is due to present, or `None` when it is
    /// due now (or nothing is queued). The worker sleeps this out — in short
    /// slices, so a stop arriving mid-wait is still acted on promptly — when
    /// the ring is full and there is nothing else to do.
    fn wait_until_present(&self, queued: &[u64]) -> Option<std::time::Duration> {
        let &front = queued.first()?;
        match self.mode {
            BridgePlaybackMode::EveryFrame => {
                let period = std::time::Duration::from_secs_f64(1.0 / self.fps);
                let since = self.last_presented?.elapsed();
                period.checked_sub(since).filter(|d| !d.is_zero())
            }
            BridgePlaybackMode::Adaptive => {
                let due = front as f64 / self.fps;
                let clock = self.elapsed_seconds();
                (due > clock).then(|| std::time::Duration::from_secs_f64(due - clock))
            }
        }
    }

    /// The next frame to render, or `None` when playback has run off the end.
    ///
    /// The mode difference, and the policy that used to live in Dart:
    ///
    /// * **Every-frame** never skips — that is the mode's entire promise, since
    ///   the point of it is to render and cache every frame at full quality
    ///   however long that takes (K-171). It simply counts.
    /// * **Adaptive** keeps time, so it never schedules a frame the clock has
    ///   already passed — it jumps to where playback actually is. Running
    ///   *ahead* of the clock is fine now (that is what the ring is for);
    ///   how far ahead is [`Self::capacity`]'s business, not this one's.
    fn advance(&mut self) -> Option<u64> {
        if self.next > self.last {
            return None;
        }
        let frame = match self.mode {
            BridgePlaybackMode::EveryFrame => self.next,
            BridgePlaybackMode::Adaptive => {
                let wanted = (self.elapsed_seconds() * self.fps).floor().max(0.0) as u64;
                // Never go backwards. A clock reading behind the frame just
                // drawn — a resync, or a mix loading part-way through — would
                // otherwise play a short stretch twice.
                wanted.max(self.next)
            }
        };
        self.skipped = frame.saturating_sub(self.next);
        if frame > self.last {
            self.next = frame;
            return None;
        }
        self.next = frame + 1;
        Some(frame)
    }

    /// What the last frame really cost, for the realtime controller.
    ///
    /// `busy` is what the worker itself measured — render plus hand-off. When
    /// playback is keeping up that is the honest number and lets the tier climb
    /// back. When frames are being skipped it is an *under*-estimate by
    /// definition: the skip proves the round trip took longer than its budget,
    /// and the part the worker cannot see is exactly the part that made it so.
    /// One skipped frame means the last one took about two budgets, two means
    /// about three, and so on — which is the cost to report if the tier is ever
    /// to come down over work the worker is blind to.
    fn observed_cost(&self, busy: f64) -> f64 {
        let budget = 1.0 / self.fps;
        if self.skipped == 0 {
            busy
        } else {
            (self.skipped + 1) as f64 * budget
        }
    }
}

/// Start the sound for `comp` at `start` seconds, from the snapshot playback
/// captured. A build with no media support has nothing to start.
#[frb(ignore)]
fn start_audio(comp: Uuid, start: f64, document: Option<std::sync::Arc<lumit_core::Document>>) {
    let Some(document) = document else {
        return;
    };
    #[cfg(feature = "media")]
    crate::audio::play(comp, start, document);
    #[cfg(not(feature = "media"))]
    let _ = (comp, start, document);
}

/// Where the sound has got to, in seconds, or `None` when there is no mix to
/// follow. The audio module's own clock — read here rather than in Dart so the
/// frame it implies is chosen next to the renderer that has to make it.
#[frb(ignore)]
fn clock_seconds() -> Option<f64> {
    #[cfg(feature = "media")]
    {
        let (seconds, playing, loaded) = crate::audio::clock();
        (loaded && playing).then_some(seconds)
    }
    #[cfg(not(feature = "media"))]
    None
}

pub struct RenderCompRequest {
    pub comp: CompositionReference,
    pub frame: u64,
    /// Which of the two playback behaviours this render is for.
    pub mode: BridgePlaybackMode,
    /// The on-screen scale of the Viewer, 1.0 meaning "shown at comp
    /// resolution". Below 1.0 the frame is being displayed smaller than the comp,
    /// so it is decoded smaller too — see [`crate::render::quality_for`].
    pub scale: f32,
}

/// A render of one frame with part of `layer` substituted — the live-drag path.
///
/// Both overrides are optional and independent, so the one request shape serves
/// an effect drag and a transform drag rather than each growing its own worker
/// message. `None` means "leave that part of the layer as the document has it".
/// A scope trace of one frame — the Scopes panel's request.
///
/// It renders the comp to CPU pixels and bins them on the GPU, whichever
/// publish path the Viewer is on: the zero-copy paths never read pixels back, so
/// the trace cannot borrow the Viewer's frame and asks for its own. That is why
/// the panel throttles rather than tracing every frame.
#[frb(ignore)]
pub struct RenderScopeRequest {
    pub comp: CompositionReference,
    pub frame: u64,
    pub scale: f32,
    /// Which trace: the codes `lumit_render` reads — 0 waveform, 1 parade,
    /// 2 vectorscope, 3 histogram.
    pub kind: u32,
    /// Background, trace, then the R, G and B channel tints, each `[r, g, b]`.
    pub colours: [[u8; 3]; 5],
}

/// One read of the pixels under the dropper — the magnifier's request.
///
/// **Why the worker answers it and not a plain synchronous call.** The pixels
/// only exist where the renderer does, and the renderer is owned outright by
/// this thread (no lock, by design). A sync call would either have to render on
/// Dart's UI isolate or reach across a lock at the one place docs/14 forbids
/// one. So the dropper asks the way the Scopes panel asks, and paints what comes
/// back.
#[frb(ignore)]
pub struct SamplePixelsRequest {
    pub comp: CompositionReference,
    pub frame: u64,
    pub scale: f32,
    /// Where to read, as a fraction of the picture: `(0, 0)` its top-left,
    /// `(1, 1)` its bottom-right. **Not a pixel** — see [`sample_pixels`] for
    /// why the caller cannot name one.
    pub u: f64,
    pub v: f64,
    /// The window's side length in pixels, forced odd and capped at
    /// [`MAX_WINDOW`]. Bigger than the magnifier's own grid on purpose: the
    /// frontend follows the pointer inside what it already has, and asks again
    /// only when the pointer nears the edge of it.
    pub window: u32,
    /// Read this layer *alone* instead of the composite — what a depth pick
    /// does, so a hidden depth pass (which never shows in the composite) can
    /// still be read. `None` samples the composite.
    pub layer: Option<LayerReference>,
}

/// The largest window one read may carry: 129×129 pixels, 66 KiB.
///
/// Chosen to be worth a read — a pointer can travel sixty pixels in any
/// direction before the frontend needs another one — while staying far below
/// the size at which a pixel payload stops being a reading and becomes a frame
/// transport (a 1080p frame is 8 MiB, and 8.8 ms in the codec: K-183).
#[frb(ignore)]
pub const MAX_WINDOW: u32 = 129;

#[frb(ignore)]
pub struct RenderCompRequestWithPreview {
    pub comp: CompositionReference,
    pub frame: u64,
    pub scale: f32,
    pub layer: LayerReference,
    pub effects: Option<Vec<EffectInstance>>,
    pub transform: Option<crate::api::layer::BridgeTransform>,
    /// A text layer's document, while it is being typed (K-225). The Type tool
    /// writes the layer once, when the edit ends; this is what keeps the
    /// picture in step in the meantime without an undo step per keystroke.
    pub text: Option<crate::api::assets::BridgeTextDocument>,
}

#[frb(ignore)]
pub fn run_worker(project: ProjectReference, stream: WorkerResponseStream) {
    let (send_to_worker, receive_from_app) = std::sync::mpsc::channel::<WorkerRequest>();

    {
        let Ok(state) = project.state() else {
            eprintln!("No such project; not starting the render worker");
            return;
        };
        let Ok(mut state) = state.write() else {
            eprintln!("Project state poisoned; not starting the render worker");
            return;
        };

        state.sender = Some(send_to_worker);
    }

    std::thread::spawn(move || worker_loop(project, receive_from_app, stream));
}

#[frb(ignore)]
fn worker_loop(
    project: ProjectReference,
    receiver: Receiver<WorkerRequest>,
    stream: WorkerResponseStream,
) {
    println!("Worker thread started");
    let mut stream = stream;

    // No renderer means no Viewer, but the editor itself stays usable — the
    // worker just stops instead of taking the process down with it.
    let renderer = match HeadlessRenderer::new() {
        Ok(renderer) => renderer,
        Err(err) => {
            eprintln!("Could not create the renderer, stopping the worker: {err}");
            return;
        }
    };

    let mut state = WorkerState {
        project,
        renderer,
        preview_engine: PreviewEngine::default(),
        playback: None,
        prefetcher: crate::prefetch::Prefetcher::default(),
        last_shown: None,
        disk: lumit_render::diskio::spawn(),
        disk_wanted: std::collections::HashMap::new(),
        // Zero and "never opened", so the first sync applies whatever the
        // settings hold and opens the folder for the project that is loaded —
        // see the note on `applied_vram_budget` below.
        applied_disk_budget: 0,
        seen_disk_clears: crate::framecache::disk::clears(),
        seen_disk_location: (u64::MAX, None),
        // NOT the wish's current value. A fresh renderer's cache holds the
        // built-in default, and the settings' value is usually already in that
        // atomic by the time a worker starts — restored at launch, or left there
        // by the previous project. Seeding this from it therefore claimed the
        // budget was applied when it never had been, and the cache stayed at
        // its 512 MiB default for the whole session while Settings read 8 GB.
        // Zero means "nothing applied yet", so the first sync applies whatever
        // the wish is.
        applied_vram_budget: 0,
        seen_vram_clears: crate::framecache::vram::clears(),
        published_vram: (0, 0),
        published_bar: None,
        bar_strip: Vec::new(),
        bar_refined_to: 0,
        bar_published_at: std::time::Instant::now() - BAR_MIN_INTERVAL,
        fill_exhausted: true,
        last_request: std::time::Instant::now(),
        layer_sample: None,
    };

    loop {
        sync_caches(&mut state);

        // While playing the worker has work of its own, so it must not block on
        // the channel — it takes whatever has arrived and gets on with the next
        // frame. Idle, it waits — indefinitely in spirit, but waking after a
        // 200 ms lull to fill the cache around the playhead (docs/06 §5.5),
        // then on a short leash while that filling is productive so it
        // proceeds briskly yet yields to any request within one frame's
        // render. With nothing left to fill the wake does no work at all, so
        // an editor sitting still spins no core worth speaking of.
        let request = if state.playback.is_some() {
            match receiver.try_recv() {
                Ok(request) => Some(request),
                Err(std::sync::mpsc::TryRecvError::Empty) => None,
                Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                    eprintln!("Receiver disconnected, stopping the worker");
                    return;
                }
            }
        } else {
            let wait = if state.fill_exhausted {
                std::time::Duration::from_millis(200)
            } else {
                std::time::Duration::from_millis(2)
            };
            match receiver.recv_timeout(wait) {
                Ok(request) => Some(request),
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                    let lull =
                        state.last_request.elapsed() >= std::time::Duration::from_millis(200);
                    if !state.fill_exhausted && lull {
                        idle_fill(&mut state, &mut stream);
                    }
                    None
                }
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                    eprintln!("Receiver disconnected, stopping the worker");
                    return;
                }
            }
        };

        if let Some(request) = request {
            state.last_request = std::time::Instant::now();
            // No second sync before serving. There used to be one, and it
            // mattered: a commit landing while the worker was parked in `recv`
            // retired every held frame, and the sync at the top of the turn had
            // already run — so the request the commit provoked was answered from
            // the caches that commit had just invalidated, and the Viewer kept
            // the pre-edit picture until something else moved the playhead. With
            // content-hash names there is no invalidation to be on the wrong side
            // of: the edited document asks for different names and misses.
            handle_requests(request, &receiver, &mut state, &mut stream);
        }

        play_one_frame(&mut state, &mut stream);
    }
}

/// One turn of the playback scheduler, if playback is running
/// (docs/impl/playback-scheduler.md §5).
///
/// Each turn does at most one piece of work — present a due frame, or render
/// one frame ahead into the ring, or sleep a short bounded slice — so a stop
/// or a seek arriving mid-playback is seen between pieces rather than after
/// the whole run. Renders and presents are decoupled: renders fill the ring as
/// fast as the machine allows (up to `capacity()` frames ahead), presents pace
/// against the clock, and the ring between them is the slack that lets one
/// expensive frame spend what the cheap frames before it banked.
#[frb(ignore)]
fn play_one_frame(state: &mut WorkerState, stream: &mut WorkerResponseStream) {
    // File whatever the decode-ahead thread has finished into the renderer's
    // cache, so the renders below find their source pixels already decoded.
    for done in state.prefetcher.drain() {
        state.renderer.preload_decoded(
            done.item,
            done.frame,
            done.target_width,
            done.width,
            done.height,
            done.rgba,
        );
    }

    // The pre-roll: the sound starts once the picture has something banked to
    // start alongside it (or the budget is spent), not at the press of play.
    if let Some(playback) = &mut state.playback {
        if playback.pending_audio.is_some() && playback.pre_roll_done(playback.ring.len()) {
            let document = playback.pending_audio.take();
            let start = playback.from as f64 / playback.fps;
            // The clock's baseline is now, not when the request arrived: the
            // pre-roll's own milliseconds are not playback time, and counting
            // them would have adaptive skip straight over the frames just
            // banked.
            playback.started = std::time::Instant::now();
            start_audio(playback.comp.id, start, document);
        }
    }

    // Present first: at a frame boundary the due picture goes out BEFORE the
    // next render is started, so an expensive render never delays a present
    // that was already payable.
    if let Some(playback) = &mut state.playback {
        let queued: Vec<u64> = playback.ring.iter().map(|(frame, _)| *frame).collect();
        if let Some(chosen) = playback.present_choice(&queued) {
            // Everything before the chosen entry arrived too late — adaptive's
            // clock has passed it (every-frame always chooses the front, so
            // this drops nothing there). Rendered but never shown; the frame
            // cache keeps the work.
            let Some((frame, prepared)) = playback.ring.drain(..=chosen).last() else {
                return;
            };
            playback.last_presented = Some(std::time::Instant::now());
            // Playback moves the playhead: keep the idle fill's anchor with
            // it, so a stop resumes filling from where the user actually is.
            state.last_shown = Some((playback.comp.clone(), frame, playback.scale));
            state.fill_exhausted = false;
            // Every-frame plays WITH sound while it holds the comp's rate, and
            // pauses the sound when the picture falls genuinely behind — the
            // K-171 v1 behaviour (a paused track over a slow-motion picture,
            // never a drifting one). Half a second of lag is well past any
            // jitter the ring absorbs. Once paused the clock stops reporting,
            // so this fires once per fall-behind, and the next press of play
            // starts the sound afresh.
            if matches!(playback.mode, BridgePlaybackMode::EveryFrame) {
                if let Some(clock) = clock_seconds() {
                    if clock - frame as f64 / playback.fps > 0.5 {
                        crate::api::audio::audio_pause();
                    }
                }
            }
            present_ring_frame(&mut state.renderer, frame, &prepared, stream);
            return;
        }
    }

    let Some(playback) = &mut state.playback else {
        return;
    };

    // Render ahead while the ring has room and frames remain.
    if playback.ring.len() < playback.capacity() {
        if let Some(frame) = playback.advance() {
            let document = {
                let Ok(document) = state.project.state() else {
                    return;
                };
                let Ok(document) = document.read() else {
                    return;
                };
                document.store.snapshot()
            };
            // The adaptive tier applies at RENDER time — the whole point of a
            // coarser tier is a cheaper composite (K-186), so it must be in
            // force while the frame is made, not when it is shown. Read before
            // the render so the cost can be attributed to it afterwards.
            let tier = crate::realtime::tier();
            let effective = if matches!(playback.mode, BridgePlaybackMode::Adaptive) {
                playback.scale * crate::realtime::tier_scale(tier)
            } else {
                playback.scale
            };
            // Post the COMING frames' source decodes to the decode-ahead
            // thread before this frame's render occupies the loop, so those
            // decodes and this composite run at the same time. The watermark
            // posts each frame once per run; an adaptive skip jumps it
            // forward with the playhead.
            let ahead_to = frame
                .saturating_add(crate::playback::PREFETCH_AHEAD)
                .min(playback.last);
            let from = playback
                .prefetched_to
                .map_or(frame + 1, |posted| posted + 1)
                .max(frame + 1);
            let comp_ahead = playback.comp.id;
            for future in from..=ahead_to {
                let wants = state.renderer.prefetch_wants(
                    &document,
                    playback.comp.id,
                    future,
                    quality_for(effective),
                );
                for want in wants {
                    state.prefetcher.request(want);
                }
                // And ask the disk tier for the coming frames at the same time.
                // A read off disk takes a turn or two of the loop, thus a frame
                // asked for when it is shown always comes too late and is
                // composited again. Asked for now, it is on the card before
                // playback gets there.
                request_disk_lead(
                    &mut state.renderer,
                    &state.disk,
                    &mut state.disk_wanted,
                    &document,
                    comp_ahead,
                    future,
                    quality_for(effective),
                );
            }
            if ahead_to >= from {
                playback.prefetched_to = Some(ahead_to);
            }
            // BGRA on the Windows shared-texture path (ANGLE only opens BGRA
            // surfaces); RGBA everywhere else.
            let bgra = zero_copy_wants_bgra();
            let started = std::time::Instant::now();
            let (comp_id, quality) = (playback.comp.id, quality_for(effective));
            let rendered = prepare_frame(
                state, &document, comp_id, frame, quality, bgra,
                // Committed document: a warm span plays from the VRAM cache
                // and every rendered frame warms it for the next pass.
                true,
            );
            let cost = started.elapsed().as_secs_f64();
            // `prepare_frame` borrowed the whole worker, so the playback state
            // has to be picked up again to file the result.
            let Some(playback) = &mut state.playback else {
                return;
            };
            match rendered {
                Ok(prepared) => {
                    playback.ring.push_back((frame, prepared));
                    playback.costs.push(cost);
                    // Tell the realtime controller what that frame cost, so
                    // playback can drop to a coarser preview when this machine
                    // cannot hold the composition's rate (K-171). Here because
                    // this is the only place that knows both halves: what the
                    // worker measured, and whether the clock has run away from
                    // it regardless (`observed_cost`).
                    if matches!(playback.mode, BridgePlaybackMode::Adaptive) {
                        crate::realtime::observe(
                            playback.observed_cost(cost),
                            playback.fps,
                            crate::realtime::tier_scale(tier),
                        );
                    }
                }
                Err(err) => {
                    // A frame that will not render stops playback rather than
                    // spinning on it — the alternative is a silent loop burning
                    // a core on a comp that cannot be drawn.
                    eprintln!("Playback stopped: {err}");
                    state.playback = None;
                    _ = stream.add(WorkerResponse::PlaybackEnded);
                }
            }
            return;
        }
        // Nothing left to schedule: playback ends once the ring has drained.
        if playback.ring.is_empty() {
            state.playback = None;
            _ = stream.add(WorkerResponse::PlaybackEnded);
            return;
        }
    }

    // Ring full (or everything is rendered) and nothing due: wait, in slices
    // capped well below a frame so a stop or a seek arriving mid-wait is still
    // acted on promptly — the loop simply comes back round.
    let queued: Vec<u64> = playback.ring.iter().map(|(frame, _)| *frame).collect();
    if let Some(wait) = playback.wait_until_present(&queued) {
        std::thread::sleep(wait.min(std::time::Duration::from_millis(4)));
    }
}

/// Show one already-rendered ring frame — the present half of the pipeline,
/// one GPU copy plus the handle relay to Dart. A failed present drops the
/// frame and says so; it never takes playback down.
#[frb(ignore)]
fn present_ring_frame(
    renderer: &mut HeadlessRenderer,
    frame: u64,
    prepared: &lumit_render::PreparedFrame,
    stream: &mut WorkerResponseStream,
) {
    #[cfg(any(
        all(windows, feature = "shared-texture"),
        all(target_os = "macos", feature = "shared-texture-macos")
    ))]
    match renderer.present_prepared(prepared) {
        Ok(shared) => {
            _ = stream.add(WorkerResponse::RenderedSharedTexture(
                BridgeSharedFrameInfo {
                    handle: shared.handle,
                    frame,
                    width: shared.width,
                    height: shared.height,
                    tier: crate::realtime::tier(),
                },
            ));
        }
        Err(err) => eprintln!("Shared-texture present failed, dropping frame: {err}"),
    }

    #[cfg(all(target_os = "linux", feature = "shared-texture-linux"))]
    match renderer.present_prepared_dmabuf(prepared) {
        Ok(shared) => {
            _ = stream.add(WorkerResponse::RenderedDMABuf(BridgeSharedFrameInfoLinux {
                fd: shared.fd,
                frame,
                width: shared.width,
                height: shared.height,
                stride: shared.stride,
                offset: shared.offset,
                drm_fourcc: shared.drm_fourcc,
                modifier: shared.modifier,
                tier: crate::realtime::tier(),
            }));
        }
        Err(err) => eprintln!("Shared DMA-BUF present failed, dropping frame: {err}"),
    }

    #[cfg(not(any(
        all(windows, feature = "shared-texture"),
        all(target_os = "linux", feature = "shared-texture-linux"),
        all(target_os = "macos", feature = "shared-texture-macos")
    )))]
    {
        let _ = (renderer, frame, prepared, stream);
        eprintln!("No zero-copy transport in this build; dropping the frame");
    }
}

/// Begin playing, reading the composition's rate and length once up front.
///
/// Playing from the last frame plays from the start, which is what a transport
/// has to do: pressing play at the end otherwise showed itself playing while
/// nothing moved.
#[frb(ignore)]
fn start_playback(req: PlayRequest, state: &mut WorkerState) -> Result<(), BridgeError> {
    let document = {
        let document = state.project.state()?;
        let document = document.read().map_err(|_| BridgeError::ReadFailed)?;
        document.store.snapshot()
    };
    let comp = document.comp(req.comp.id).ok_or(BridgeError::InvalidComp)?;
    let fps = comp.frame_rate.fps();
    // The same derivation `CompositionReference::duration_frames` uses: the
    // document stores a length in seconds, and the count is that read at the
    // comp's current rate.
    let frames = comp
        .frame_rate
        .frame_at(lumit_core::time::CompTime(comp.duration.0));
    let last = frames.max(1).saturating_sub(1) as u64;

    let from = if req.from >= last { 0 } else { req.from };
    state.playback = Some(Playback {
        comp: req.comp,
        pending_audio: Some(req.audio),
        next: from,
        last,
        mode: req.mode,
        scale: req.scale,
        fps: if fps > 0.0 { fps } else { 60.0 },
        from,
        started: std::time::Instant::now(),
        last_presented: None,
        ring: std::collections::VecDeque::new(),
        costs: crate::playback::CostWindow::default(),
        prefetched_to: None,
        skipped: 0,
    });
    // A fresh run starts optimistic at Full and walks down to whatever this
    // machine can actually hold, rather than inheriting the last run's verdict
    // on a comp that may since have got lighter.
    crate::realtime::reset();
    Ok(())
}

/// Take everything queued, throw away what has been superseded, and serve the
/// rest.
#[frb(ignore)]
fn handle_requests(
    request: WorkerRequest,
    receiver: &Receiver<WorkerRequest>,
    state: &mut WorkerState,
    stream: &mut WorkerResponseStream,
) {
    {
        // Latest wins — but *per kind*, which is the whole point.
        //
        // Anything that queued while the previous frame rendered is superseded:
        // a drag emits a request every ~20 ms and a render takes longer, so
        // without this the worker works through a backlog nothing will ever
        // see, each one delaying the only frame the user is waiting for
        // (docs/13 §2, B3: the *first* frame after an interaction is budgeted).
        //
        // What a picture supersedes is another picture. Draining to the single
        // newest request of any kind meant a Scopes trace threw away every
        // frame render queued behind it — and during playback the Scopes panel
        // asks every 120 ms while the Viewer asks every tick, so the picture
        // froze on its first frame while the scopes kept updating. A trace and
        // a frame are different jobs; neither is the other's replacement.
        let (pictures, scope, sample, superseded) =
            drain_to_newest(request, receiver, classify_request);
        // Deliberately not logged. Superseding is the normal, healthy case —
        // it is how a drag stays attached to the pointer — and a line per
        // completed render is console I/O on the worker thread for something
        // that happens sixty times a second. `cache_stats` is where to look for
        // how the Viewer is actually doing.
        let _ = superseded;

        // Pictures first: they are what the user is looking at, and a trace of
        // a frame that is about to be replaced is worth less than the frame.
        //
        // A frame that cannot be rendered is dropped, not fatal: the worker has
        // to survive to serve the next request.
        for request in pictures.into_iter().chain(scope).chain(sample) {
            let outcome = match request {
                WorkerRequest::RenderComp(req) => render_comp(req, state, stream),
                WorkerRequest::SamplePixels(req) => sample_pixels(req, state, stream),
                // Named for what it does rather than "render", so the three
                // variants do not all share a prefix that says nothing.
                WorkerRequest::TraceScope(req) => trace_scope(req, state, stream),
                WorkerRequest::RenderCompWithPreview(req) => {
                    render_comp_with_preview(req, state, stream)
                }
                WorkerRequest::Play(req) => start_playback(req, state),
                WorkerRequest::StopPlayback => {
                    state.playback = None;
                    Ok(())
                }
            };
            if let Err(err) = outcome {
                eprintln!("Dropping frame: {err}");
            }
        }
    }
}

/// How the drain treats each request kind.
///
/// A [`WorkerRequest::RenderComp`] is always newest-wins, WHATEVER its mode:
/// since playback moved into the worker (K-181) the only RenderComp traffic
/// is "show me the frame under the playhead", and a playhead position the
/// user has already dragged past will never be looked at. Treating every-frame
/// scrubs as keep-all — a leftover from the deleted Dart-side playback
/// pipeline — made a playhead drag render every frame it crossed, in order,
/// long after the user had let go.
///
/// Transport commands are not pictures and must never be dropped: superseding
/// a Stop would leave playback running with nothing left to stop it.
#[frb(ignore)]
fn classify_request(r: &WorkerRequest) -> DrainClass {
    match r {
        WorkerRequest::TraceScope(_) => DrainClass::Scope,
        WorkerRequest::SamplePixels(_) => DrainClass::Sample,
        WorkerRequest::Play(_) | WorkerRequest::StopPlayback => DrainClass::PictureKeepAll,
        WorkerRequest::RenderComp(_) | WorkerRequest::RenderCompWithPreview(_) => {
            DrainClass::PictureNewestWins
        }
    }
}

/// How the drain treats one queued request.
#[frb(ignore)]
#[derive(Clone, Copy, PartialEq, Eq)]
enum DrainClass {
    /// A stale one is worthless: only the newest survives (a scrub — the
    /// playhead position behind the newest will never be looked at).
    PictureNewestWins,
    /// Every one is served, in order (transport commands: Play and Stop).
    PictureKeepAll,
    /// A trace; the newest survives, served after the pictures.
    Scope,
    /// A dropper read; the newest survives, served after the pictures — and in
    /// its own lane, not the trace's. The two are different questions, and a
    /// Scopes panel open while the dropper is armed must not make either one
    /// throw the other away (the same reasoning that gave a trace its own lane
    /// against a frame).
    Sample,
}

/// Take everything queued and keep what its class says to keep.
///
/// Generic over the classifier so the policy can be tested on its own — a
/// `WorkerRequest` needs a live project behind it, and the rule being tested has
/// nothing to do with rendering.
///
/// Returns `(pictures_in_order, scope, sample, superseded_count)`.
#[frb(ignore)]
fn drain_to_newest<T>(
    first: T,
    receiver: &Receiver<T>,
    classify: impl Fn(&T) -> DrainClass,
) -> (Vec<T>, Option<T>, Option<T>, usize) {
    let mut kept: Vec<T> = Vec::new();
    let mut newest_wins: Option<T> = None;
    let mut scope = None;
    let mut sample = None;
    let mut superseded = 0usize;
    let mut newest = Some(first);
    while let Some(item) = newest.take() {
        match classify(&item) {
            DrainClass::Scope => {
                if scope.replace(item).is_some() {
                    superseded += 1;
                }
            }
            DrainClass::Sample => {
                if sample.replace(item).is_some() {
                    superseded += 1;
                }
            }
            DrainClass::PictureKeepAll => kept.push(item),
            DrainClass::PictureNewestWins => {
                if newest_wins.replace(item).is_some() {
                    superseded += 1;
                }
            }
        }
        newest = receiver.try_recv().ok();
    }
    // A surviving newest-wins picture runs after the kept ones: the kept ones
    // were asked for earlier, and order is part of every-frame's contract.
    kept.extend(newest_wins);
    (kept, scope, sample, superseded)
}

fn render_comp(
    req: RenderCompRequest,
    state: &mut WorkerState,
    stream: &mut WorkerResponseStream,
) -> Result<(), BridgeError> {
    let document = {
        let document = state.project.state()?;
        let document = document.read().map_err(|_| BridgeError::ReadFailed)?;
        document.store.snapshot()
    };

    // The user is looking here now: anchor the idle fill on it, and wake it.
    state.last_shown = Some((req.comp.clone(), req.frame, req.scale));
    state.fill_exhausted = false;
    publish_frame(
        state,
        req.comp.id,
        req.frame,
        req.scale,
        &document,
        stream,
        req.mode,
        // A committed document: cacheable, and a held frame serves the scrub.
        true,
    );
    Ok(())
}

/// Replace a text layer's document with the one being typed (K-225).
///
/// Only a text layer has a document to replace; anything else is a preview from
/// a layer that changed kind under the tool, and is ignored rather than failing
/// the frame — a provisional picture is never worth taking the worker down for.
#[frb(ignore)]
fn apply_text_preview(
    kind: &mut lumit_core::model::LayerKind,
    document: crate::api::assets::BridgeTextDocument,
) {
    if let lumit_core::model::LayerKind::Text { document: existing } = kind {
        *existing = lumit_core::model::TextDocument {
            text: document.text,
            size: document.size,
            fill: crate::api::assets::linear_of(document.fill),
            extra: serde_json::Map::new(),
        };
    }
}

/// Render a frame under effect values the user is still dragging.
///
/// The effect stack is patched on a *clone* of the snapshot, so a drag never
/// touches the document — no commit, no undo entry, no journal write.
///
/// Note this is a *different* idiom from the v0 bridge's `preview_effect_param`
/// (ABI 12), which keeps a persistent overlay in `Bridge::preview` and replays
/// `Op::SetLayerEffects` over it. Here the whole effect list rides along with the
/// render request instead. Worth converging on one of the two when this path is
/// finished.
fn render_comp_with_preview(
    req: RenderCompRequestWithPreview,
    state: &mut WorkerState,
    stream: &mut WorkerResponseStream,
) -> Result<(), BridgeError> {
    let mut document = {
        let document = state.project.state()?;
        let document = document.read().map_err(|_| BridgeError::ReadFailed)?;
        (*document.store.snapshot()).clone()
    };

    let comp = document
        .comp_mut(req.layer.comp_id)
        .ok_or(BridgeError::InvalidComp)?;

    let index = comp
        .layers
        .iter()
        .position(|i| i.id == req.layer.layer_id)
        .ok_or(BridgeError::InvalidLayer)?;

    if let Some(effects) = req.effects {
        comp.layers[index].effects = effects;
    }
    if let Some(document) = req.text {
        apply_text_preview(&mut comp.layers[index].kind, document);
    }
    if let Some(transform) = &req.transform {
        // The preview's keys arrive on the composition's clock like every other
        // read (K-213); the layer's own offset carries them back.
        let offset = comp.layers[index].start_offset.0;
        transform.write_at(&mut comp.layers[index].transform, offset)?;
    }

    // A drag is not playback: full resolution (EveryFrame skips the adaptive
    // tier), and NOT cacheable — these pixels are of provisional values the
    // document never committed, so they must neither be served back later nor
    // displace honest frames.
    publish_frame(
        state,
        req.comp.id,
        req.frame,
        req.scale,
        &document,
        stream,
        BridgePlaybackMode::EveryFrame,
        false,
    );
    Ok(())
}

/// Trace `frame` and publish the result.
///
/// Always a CPU read-back even on a zero-copy build: the binning kernel needs
/// the pixels, and on those builds nothing ever brings them back. A failure
/// publishes nothing rather than taking the worker down — a scope that cannot
/// draw is a blank panel, not a lost session.
#[frb(ignore)]
fn trace_scope(
    req: RenderScopeRequest,
    state: &mut WorkerState,
    stream: &mut WorkerResponseStream,
) -> Result<(), BridgeError> {
    let document = {
        let document = state.project.state()?;
        let document = document.read().map_err(|_| BridgeError::ReadFailed)?;
        document.store.snapshot()
    };

    // Reuse the picture the Viewer already has, at whatever resolution it was
    // made at. Scopes read the *values* in a frame, so any size answers the
    // question — and compositing the composition a second time to ask it was
    // doubling the cost of every played frame with the panel open.
    let (width, height, rgba) = match crate::framecache::best_frame(req.comp.id, req.frame) {
        Some(held) => held,
        None => {
            // Nothing held for this frame — the zero-copy Viewer keeps no bytes,
            // so on that path the trace still has to make its own. Cached under
            // the frame's content name, so a second trace of the same frame is
            // free; an unnameable frame (footage still being probed) is traced
            // without banking anything.
            let quality = quality_for(req.scale);
            let key = state
                .renderer
                .frame_key(&document, req.comp.id, req.frame, quality);
            let provenance = lumit_render::FrameProvenance {
                comp: req.comp.id,
                frame: req.frame,
                scale_q: lumit_render::preview_scale_q(quality),
            };
            let mut render = || {
                state
                    .renderer
                    .render_preview(
                        &document,
                        req.comp.id,
                        req.frame,
                        quality_for(req.scale),
                        req.scale,
                        None,
                    )
                    .ok()
                    .map(|(rgba, width, height)| (width, height, rgba))
            };
            let made = match key {
                Some(key) => crate::framecache::get_or_render(key, provenance, &mut render),
                None => render(),
            };
            let Some(made) = made else {
                eprintln!("Scope render failed, dropping the trace");
                return Ok(());
            };
            made
        }
    };

    match state
        .renderer
        .render_scope(&rgba, width, height, req.kind, req.colours)
    {
        Ok(trace) => {
            _ = stream.add(WorkerResponse::Scope(crate::api::state::BridgeScopeTrace {
                rgba: trace,
            }));
        }
        Err(err) => eprintln!("Scope trace failed: {err}"),
    }
    Ok(())
}

/// Answer one dropper read: find the pixels, cut the window, publish it.
///
/// **A window, not a pixel.** The reply carries a whole square of the picture —
/// [`MAX_WINDOW`] a side — so the frontend can follow the pointer through it
/// without asking again. One read then serves a whole sweep of the pointer and
/// every change of sample size, instead of a request, a render lookup and a
/// stream message per mouse move. It stays a *reading* rather than a picture:
/// 129×129 is 66 KiB, a fraction of a millisecond in the codec, against 8 MiB
/// for a 1080p frame (K-183's reason for deleting the read-back transport).
///
/// The picture comes from the same places a trace's does, in the same order:
/// the frame already banked in RAM — read **in place**, never cloned, since
/// cutting a window out of eight megabytes by copying all eight is the cost
/// this is here to avoid — else a render of it, banked so the next read of the
/// same frame is free. A **layer** read is the one that can reuse neither: it
/// needs that layer alone, which is not what the composite shows, so it renders
/// the composition with the layer soloed and keeps the result in
/// `layer_sample`.
#[frb(ignore)]
fn sample_pixels(
    req: SamplePixelsRequest,
    state: &mut WorkerState,
    stream: &mut WorkerResponseStream,
) -> Result<(), BridgeError> {
    let (document, revision) = {
        let document = state.project.state()?;
        let document = document.read().map_err(|_| BridgeError::ReadFailed)?;
        (document.store.snapshot(), document.store.revision())
    };

    let layer_alone = req.layer.is_some();

    // The point arrives as a FRACTION of the picture, not as a pixel of
    // anything, and that is deliberate: the picture actually read may be a
    // reduced-resolution preview, so its pixel grid is not the composition's
    // and neither side can name a pixel in the other's. The reply says which
    // raster it cut from, and every pixel the caller then names is in that one.
    let (u, v) = (req.u.clamp(0.0, 1.0), req.v.clamp(0.0, 1.0));

    let cut = match &req.layer {
        Some(layer) => sample_layer_alone(&document, revision, layer.layer_id, &req, state)
            .and_then(|(w, h, rgba)| cut_patch(&rgba, w, h, u, v, req.window).map(|p| (p, w, h))),
        None => {
            // In place, under the cache lock: a bounded copy of the window's
            // own pixels, not of the frame around them. A frame that came down
            // off the card is BGRA on two of the three platforms, thus the
            // window — and only the window — is put right after the cut.
            let held =
                crate::framecache::with_best_frame(req.comp.id, req.frame, |bytes, w, h, bgra| {
                    cut_patch(bytes, w, h, u, v, req.window).map(|mut p| {
                        if bgra {
                            for px in p.rgba.chunks_exact_mut(4) {
                                px.swap(0, 2);
                            }
                        }
                        (p, w, h)
                    })
                })
                .flatten();
            match held {
                Some(cut) => Some(cut),
                // Nothing banked for this frame: render it once (banked under
                // the frame's content name, so a re-read of the same frame is
                // free) and cut from that.
                None => {
                    let quality = quality_for(req.scale);
                    let name = state
                        .renderer
                        .frame_key(&document, req.comp.id, req.frame, quality);
                    let mut render = || {
                        state
                            .renderer
                            .render_preview(
                                &document,
                                req.comp.id,
                                req.frame,
                                quality,
                                req.scale,
                                None,
                            )
                            .ok()
                            .map(|(rgba, width, height)| (width, height, rgba))
                    };
                    // A frame that cannot be named yet (its footage is still
                    // being probed) is rendered and not banked: an entry under
                    // a name the renderer did not keep is worse than no entry.
                    let made = match name {
                        Some(key) => crate::framecache::get_or_render(
                            key,
                            lumit_render::FrameProvenance {
                                comp: req.comp.id,
                                frame: req.frame,
                                scale_q: lumit_render::preview_scale_q(quality),
                            },
                            render,
                        ),
                        None => render(),
                    };
                    made.and_then(|(w, h, rgba)| {
                        cut_patch(&rgba, w, h, u, v, req.window).map(|p| (p, w, h))
                    })
                }
            }
        }
    };

    // Nothing to read: no reply is itself the answer — the magnifier keeps the
    // window it had until a new one arrives, rather than blanking.
    let Some((patch, width, height)) = cut else {
        return Ok(());
    };

    _ = stream.add(WorkerResponse::Sampled(
        crate::api::state::BridgeSampledPixels {
            window: patch.window,
            rgba: patch.rgba,
            width,
            height,
            x: patch.x,
            y: patch.y,
            frame: req.frame,
            layer_alone,
        },
    ));
    Ok(())
}

/// The composition rendered with one layer soloed — that layer alone, in its
/// own place, on nothing.
///
/// Held in `state.layer_sample` against `(comp, frame, layer, revision)`: the
/// dropper asks again on every pointer move, and re-compositing the whole
/// composition per move is not a thing to do while someone is dragging a
/// pointer. An edit moves the document's revision, which retires the entry.
#[frb(ignore)]
fn sample_layer_alone(
    document: &lumit_core::Document,
    revision: u64,
    layer: Uuid,
    req: &SamplePixelsRequest,
    state: &mut WorkerState,
) -> Option<(u32, u32, Vec<u8>)> {
    let stamp = (req.comp.id, req.frame, layer, revision);
    if let Some(held) = &state.layer_sample {
        if held.stamp == stamp {
            return Some((held.width, held.height, held.rgba.clone()));
        }
    }

    // A patched *copy* of the snapshot: soloing for the read must never be
    // something the document remembers, so nothing here goes near `commit`.
    let mut patched = lumit_core::Document::clone(document);
    let comp = patched.comp_mut(req.comp.id)?;
    for l in &mut comp.layers {
        l.switches.solo = l.id == layer;
        // Soloed and still hidden is nothing at all — and a depth pass is very
        // often hidden, which is exactly why this read exists.
        if l.id == layer {
            l.switches.visible = true;
        }
    }

    let (rgba, w, h) = state
        .renderer
        .render_preview(
            &patched,
            req.comp.id,
            req.frame,
            quality_for(req.scale),
            req.scale,
            None,
        )
        .ok()?;
    state.layer_sample = Some(LayerSample {
        stamp,
        width: w,
        height: h,
        rgba: rgba.clone(),
    });
    Some((w, h, rgba))
}

/// A window cut out of a picture: the pixels, and where its centre landed.
#[frb(ignore)]
pub(crate) struct Patch {
    pub window: u32,
    pub rgba: Vec<u8>,
    pub x: u32,
    pub y: u32,
}

/// Cut a `window × window` square centred on the fraction `(u, v)` of a
/// picture.
///
/// `window` is forced odd and capped at [`MAX_WINDOW`] here rather than
/// trusted: the centre must be a single pixel for the magnifier's centre cell
/// to mean anything, and the payload must stay small enough to be a reading
/// rather than a picture. Pixels off the edge repeat the edge, so the square is
/// always exactly `window × window` and the caller never has a ragged one to
/// draw — and the frontend can index it without a bounds case at the picture's
/// border.
#[frb(ignore)]
pub(crate) fn cut_patch(
    rgba: &[u8],
    width: u32,
    height: u32,
    u: f64,
    v: f64,
    window: u32,
) -> Option<Patch> {
    if width == 0 || height == 0 || rgba.len() < (width as usize * height as usize * 4) {
        return None;
    }
    let grid = window.clamp(1, MAX_WINDOW) | 1;
    let w = width as i64;
    let h = height as i64;
    let cx = ((u * width as f64) as i64).clamp(0, w - 1);
    let cy = ((v * height as f64) as i64).clamp(0, h - 1);
    let half = i64::from(grid / 2);

    let mut out = Vec::with_capacity((grid * grid * 4) as usize);
    for dy in 0..i64::from(grid) {
        for dx in 0..i64::from(grid) {
            let px = (cx - half + dx).clamp(0, w - 1);
            let py = (cy - half + dy).clamp(0, h - 1);
            let i = ((py * w + px) * 4) as usize;
            out.extend_from_slice(&rgba[i..i + 4]);
        }
    }
    Some(Patch {
        window: grid,
        rgba: out,
        x: cx as u32,
        y: cy as u32,
    })
}

/// Render one frame and publish it to Dart — always as a GPU handle (K-183).
///
/// Two implementations, selected at compile time, because the zero-copy entry
/// points only *exist* under their own platform and feature:
///
/// 1. Linux + `shared-texture-linux` → a DMA-BUF handle (K-177).
/// 2. Windows + `shared-texture` → a shared D3D12 texture handle (K-177), and
///    macOS + `shared-texture-macos` → an `IOSurfaceID` (K-195). One body: both
///    report one opaque integer naming a surface, plus its size.
///
/// The engine draws straight into a texture the runner displays and no pixels
/// cross the boundary at all; the read-back transport that copied every pixel
/// off the card and serialised it a byte at a time (~6 ms per 1.4 MB) is
/// deleted. A failed render, or a build with no zero-copy path at all, drops the
/// frame and says so; it never takes the worker down.
#[allow(clippy::too_many_arguments)]
fn publish_frame(
    state: &mut WorkerState,
    comp: Uuid,
    frame: u64,
    scale: f32,
    document: &lumit_core::Document,
    stream: &mut WorkerResponseStream,
    mode: BridgePlaybackMode,
    cacheable: bool,
) {
    #[cfg(any(
        all(windows, feature = "shared-texture"),
        all(target_os = "linux", feature = "shared-texture-linux"),
        all(target_os = "macos", feature = "shared-texture-macos")
    ))]
    publish_zero_copy(state, comp, frame, scale, document, stream, mode, cacheable);

    #[cfg(not(any(
        all(windows, feature = "shared-texture"),
        all(target_os = "linux", feature = "shared-texture-linux"),
        all(target_os = "macos", feature = "shared-texture-macos")
    )))]
    {
        let _ = (state, comp, frame, scale, document, stream, mode, cacheable);
        eprintln!("No zero-copy transport in this build; dropping the frame");
    }
}

#[cfg(all(target_os = "linux", feature = "shared-texture-linux"))]
#[allow(clippy::too_many_arguments)]
fn publish_zero_copy(
    state: &mut WorkerState,
    comp: Uuid,
    frame: u64,
    scale: f32,
    document: &lumit_core::Document,
    stream: &mut WorkerResponseStream,
    mode: BridgePlaybackMode,
    cacheable: bool,
) {
    // The adaptive tier applies here exactly as on the Windows sibling: without
    // it a coarser tier makes the picture no cheaper, so the controller's
    // decision has no effect and playback drops frames instead of softening.
    let effective = if matches!(mode, BridgePlaybackMode::Adaptive) {
        scale * crate::realtime::tier_scale(crate::realtime::tier())
    } else {
        scale
    };
    // Through the ladder, not straight to a composite: a frame already held on
    // the card, in memory, or parked on disk costs a copy or an upload rather
    // than a render (see `prepare_frame`).
    let prepared = match prepare_frame(
        state,
        document,
        comp,
        frame,
        quality_for(effective),
        false,
        cacheable,
    ) {
        Ok(prepared) => prepared,
        Err(err) => {
            // Dropped, not fatal: the next request renders afresh.
            eprintln!("Shared DMA-BUF render failed, dropping frame: {err}");
            return;
        }
    };
    let shared = match state.renderer.present_prepared_dmabuf(&prepared) {
        Ok(shared) => shared,
        Err(err) => {
            eprintln!("Shared DMA-BUF present failed, dropping frame: {err}");
            return;
        }
    };

    _ = stream.add(WorkerResponse::RenderedDMABuf(BridgeSharedFrameInfoLinux {
        fd: shared.fd,
        frame,
        width: shared.width,
        height: shared.height,
        stride: shared.stride,
        offset: shared.offset,
        drm_fourcc: shared.drm_fourcc,
        modifier: shared.modifier,
        tier: crate::realtime::tier(),
    }));
}

#[cfg(any(
    all(windows, feature = "shared-texture"),
    all(target_os = "macos", feature = "shared-texture-macos")
))]
#[allow(clippy::too_many_arguments)]
fn publish_zero_copy(
    state: &mut WorkerState,
    comp: Uuid,
    frame: u64,
    scale: f32,
    document: &lumit_core::Document,
    stream: &mut WorkerResponseStream,
    mode: BridgePlaybackMode,
    cacheable: bool,
) {
    // The adaptive tier is applied here, the only display path: without it the
    // controller could drop to Quarter and the picture would not get any
    // cheaper, so the tier would do nothing at all and playback would keep time
    // by dropping frames for ever. What a frame costs is reported by
    // `play_one_frame`, which times the render.
    let effective = if matches!(mode, BridgePlaybackMode::Adaptive) {
        scale * crate::realtime::tier_scale(crate::realtime::tier())
    } else {
        scale
    };
    // Through the ladder, not straight to a composite — see `prepare_frame`.
    let prepared = match prepare_frame(
        state,
        document,
        comp,
        frame,
        quality_for(effective),
        true,
        cacheable,
    ) {
        Ok(prepared) => prepared,
        Err(err) => {
            // Dropped, not fatal: the next request renders afresh.
            eprintln!("Shared-texture render failed, dropping frame: {err}");
            return;
        }
    };
    let shared = match state.renderer.present_prepared(&prepared) {
        Ok(shared) => shared,
        Err(err) => {
            eprintln!("Shared-texture present failed, dropping frame: {err}");
            return;
        }
    };

    _ = stream.add(WorkerResponse::RenderedSharedTexture(
        BridgeSharedFrameInfo {
            handle: shared.handle,
            frame,
            width: shared.width,
            height: shared.height,
            tier: crate::realtime::tier(),
        },
    ));
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::{drain_to_newest, DrainClass, Playback};
    use crate::api::composition::{BridgePlaybackMode, CompositionReference};
    use std::sync::mpsc::channel;
    use uuid::Uuid;

    fn playback(mode: BridgePlaybackMode, last: u64) -> Playback {
        Playback {
            comp: CompositionReference::new(Uuid::nil(), Uuid::nil()),
            next: 0,
            last,
            mode,
            scale: 1.0,
            fps: 60.0,
            from: 0,
            started: std::time::Instant::now(),
            last_presented: None,
            ring: std::collections::VecDeque::new(),
            costs: crate::playback::CostWindow::default(),
            prefetched_to: None,
            pending_audio: None,
            skipped: 0,
        }
    }

    /// **The pre-roll.** The sound waits for the picture to bank a frame or two
    /// — otherwise it starts while the first composite is still running and, in
    /// adaptive mode, the picture skips to catch the clock up, so every press of
    /// play begins with a jump. The wait is bounded: a comp too heavy to bank
    /// three frames inside the budget starts anyway rather than sitting silent.
    #[test]
    fn the_sound_waits_for_the_first_frames_but_not_for_long() {
        let play = playback(BridgePlaybackMode::Adaptive, 100);
        assert!(!play.pre_roll_done(0), "nothing banked yet");
        assert!(!play.pre_roll_done(2), "still short of the pre-roll");
        assert!(play.pre_roll_done(3), "three frames is a pre-roll");

        // Budget spent: the sound starts on whatever there is.
        let mut slow = playback(BridgePlaybackMode::Adaptive, 100);
        slow.started = std::time::Instant::now() - std::time::Duration::from_millis(200);
        assert!(
            slow.pre_roll_done(0),
            "a heavy comp must not play in silence waiting for a ring"
        );
    }

    /// **The pacing regression, on the present side.** Renders are free to run
    /// ahead into the ring — that is the scheduler's point — so the PRESENT is
    /// what paces playback now. Without [`Playback::present_choice`]'s clock
    /// gate a comp cheaper than realtime would play as fast as the renderer
    /// manages, which is the "plays at several hundred fps" bug the old
    /// per-render wait existed for. Fails without the gate.
    #[test]
    fn adaptive_playback_presents_frames_only_when_the_clock_reaches_them() {
        let mut p = playback(BridgePlaybackMode::Adaptive, 100);
        let queued = [0u64, 1, 2, 3];

        // Frame 0 is due the instant playback starts; nothing beyond it is.
        assert_eq!(
            p.present_choice(&queued),
            Some(0),
            "frame 0 is due at the very start, and only frame 0"
        );

        // Half a second in, the clock has reached frame 30: the ring's newest
        // due entry is presented and everything older is dropped with it —
        // showing frame 1 half a second late is worse than not showing it.
        p.started = std::time::Instant::now() - std::time::Duration::from_millis(500);
        let queued = [28u64, 29, 30, 40];
        let chosen = p.present_choice(&queued).expect("plenty is due by now");
        assert!(
            (1..=2).contains(&chosen),
            "the newest frame the clock has reached, not the oldest queued: {chosen}"
        );

        // And a ring full of the future presents nothing at all.
        assert_eq!(p.present_choice(&[500, 501]), None, "the future can wait");
        // The wait until it is due is bounded by when frame 500 falls due.
        let wait = p.wait_until_present(&[500, 501]).expect("not due yet");
        assert!(wait.as_secs_f64() <= 500.0 / 60.0);
    }

    /// Every-frame never skips, whatever it costs — that is the mode's whole
    /// definition (K-171); when it cannot keep the comp's rate it plays slow
    /// and the sound pauses rather than drifting.
    #[test]
    fn every_frame_playback_never_skips() {
        let mut p = playback(BridgePlaybackMode::EveryFrame, 3);
        for expected in 0..=3 {
            assert_eq!(p.advance(), Some(expected), "never skips one");
        }
        assert_eq!(p.advance(), None, "past the last frame, playback is over");
    }

    /// **The cached-playback regression, on the present side.** Every-frame is
    /// allowed to fall behind — a comp too heavy to render in realtime plays
    /// slow rather than dropping frames — but it must never run *ahead*. Once a
    /// span is cached, renders cost almost nothing and the RING fills instantly;
    /// without the present gate the mode replayed cached spans many times
    /// faster than realtime: "it zooms through those parts". Fails without the
    /// per-present pacing.
    #[test]
    fn every_frame_playback_never_presents_faster_than_realtime() {
        let mut p = playback(BridgePlaybackMode::EveryFrame, 100);
        let queued = [0u64, 1, 2];

        // The first frame of a run is due immediately — nothing has been shown
        // yet, so there is nothing to be early against. And it is the FRONT:
        // every-frame shows every frame, in order, never the newest.
        assert_eq!(p.present_choice(&queued), Some(0));

        // A frame shown just now: the next present is a sixtieth of a second
        // away, however full of cached frames the ring already is.
        p.last_presented = Some(std::time::Instant::now());
        assert_eq!(
            p.present_choice(&queued),
            None,
            "a full ring is not a licence to run ahead of the comp's rate"
        );
        let wait = p
            .wait_until_present(&queued)
            .expect("a frame shown just now means the next one is not due");
        // The upper bound carries a nanosecond of slack: `Duration` rounds
        // 1/60 s up at nanosecond precision, so an exact `<=` fails on the
        // untouched period.
        assert!(
            wait.as_secs_f64() > 0.010 && wait.as_secs_f64() <= 1.0 / 60.0 + 1e-6,
            "waits out the rest of the frame period, no more: {wait:?}"
        );

        // A present that is already overdue happens now. Late is allowed;
        // making it later is not.
        p.last_presented = Some(std::time::Instant::now() - std::time::Duration::from_millis(50));
        assert_eq!(
            p.present_choice(&queued),
            Some(0),
            "already behind, so the front goes out immediately — it never \
             tries to catch up and never adds to the delay"
        );
    }

    /// The scheduler's slack, end to end at the decision level: cheap frames
    /// keep the ring's capacity at the impl note's floor of 8, a run of
    /// expensive ones raises it, and the raise ages out with the costs that
    /// caused it — the lookahead follows the comp the playhead is in now.
    #[test]
    fn the_ring_capacity_adapts_to_measured_render_cost() {
        let mut p = playback(BridgePlaybackMode::Adaptive, 1000);
        assert_eq!(p.capacity(), 8, "a fresh run starts at the floor");
        for _ in 0..32 {
            p.costs.push(0.1); // 6 budgets at 60 fps: a struggling comp.
        }
        assert_eq!(p.capacity(), 12, "2 × 0.1 s × 60 fps");
        for _ in 0..32 {
            p.costs.push(0.004); // The playhead moved somewhere cheap.
        }
        assert_eq!(p.capacity(), 8, "the expensive stretch ages out");
    }

    /// Adaptive skips frames the clock has already gone past, rather than
    /// falling further behind. Driven by moving the start time into the past,
    /// which is what a slow render does to the wall clock.
    #[test]
    fn adaptive_playback_skips_frames_the_clock_has_passed() {
        let mut p = playback(BridgePlaybackMode::Adaptive, 100);
        p.started = std::time::Instant::now() - std::time::Duration::from_millis(500);

        let frame = p.advance().expect("still inside the composition");
        assert!(
            frame >= 29,
            "half a second at 60 fps is about frame 30, not frame 0: got {frame}"
        );
    }

    /// **The always-Full regression.** The tier only ever saw what the worker
    /// could time — its own render and hand-off — and the rest of a frame's
    /// journey (the decode, the paint, everything the frontend does per frame)
    /// happens after the worker has let go. So on a machine where the worker
    /// spent 9 ms of a 16.7 ms budget the controller read "plenty of headroom"
    /// and stayed at Full, while playback visibly skipped frames to keep time.
    ///
    /// A skip is the symptom of the whole round trip being too slow, whoever
    /// spent the time, so it is what the cost is derived from. Fails without
    /// `observed_cost` — the reported cost would be the 9 ms busy time, which
    /// sits comfortably under the 15 ms drop threshold and moves nothing.
    #[test]
    fn skipped_frames_are_reported_as_over_budget_however_little_the_worker_spent() {
        let mut p = playback(BridgePlaybackMode::Adaptive, 1000);
        let budget = 1.0 / 60.0;

        // Keeping up: the worker's own measurement stands, so a cheap frame
        // reads cheap and the tier is free to climb back.
        p.skipped = 0;
        assert_eq!(p.observed_cost(0.009), 0.009);
        assert!(
            p.observed_cost(0.009) < 0.9 * budget,
            "a frame that kept up must not read as over budget"
        );

        // Behind by one frame: the worker still only spent 9 ms, but the round
        // trip demonstrably took more than its budget.
        p.skipped = 1;
        assert!(
            p.observed_cost(0.009) > 0.9 * budget,
            "one skipped frame means the last one cost about two budgets, \
             whatever the worker's own stopwatch says"
        );

        // And the further behind it falls, the worse the reported cost, so the
        // tier keeps coming down instead of settling one step in.
        p.skipped = 3;
        assert!(p.observed_cost(0.009) > p.observed_cost(0.009) / 2.0);
        assert_eq!(p.observed_cost(0.009), 4.0 * budget);
    }

    /// The requests these tests queue: an adaptive picture (newest wins), an
    /// every-frame picture (all kept, in order), and a scope trace. Standing in
    /// for `WorkerRequest`, which needs a live project.
    #[derive(Debug, PartialEq, Eq, Clone, Copy)]
    enum Req {
        Adaptive(u32),
        Sample(u32),
        // Kept-in-order requests — standing in for the transport commands
        // (Play, Stop), the only keep-all class since scrubs became
        // newest-wins in every mode.
        EveryFrame(u32),
        Scope(u32),
    }

    fn classify(r: &Req) -> DrainClass {
        match r {
            Req::Adaptive(_) => DrainClass::PictureNewestWins,
            Req::EveryFrame(_) => DrainClass::PictureKeepAll,
            Req::Scope(_) => DrainClass::Scope,
            Req::Sample(_) => DrainClass::Sample,
        }
    }

    /// **The playhead-drag regression.** A scrub render is newest-wins in
    /// EVERY transport mode: since playback moved into the worker (K-181),
    /// a RenderComp only ever means "show the frame under the playhead", and
    /// classifying every-frame scrubs as keep-all made a drag render every
    /// frame it crossed, in order, long after the pointer had let go.
    #[test]
    fn a_scrub_supersedes_whatever_the_transport_mode() {
        let comp = CompositionReference::new(Uuid::nil(), Uuid::nil());
        let scrub = |frame: u64, mode: BridgePlaybackMode| {
            super::WorkerRequest::RenderComp(super::RenderCompRequest {
                comp: comp.clone(),
                frame,
                mode,
                scale: 1.0,
            })
        };
        assert!(matches!(
            super::classify_request(&scrub(5, BridgePlaybackMode::EveryFrame)),
            DrainClass::PictureNewestWins
        ));
        assert!(matches!(
            super::classify_request(&scrub(5, BridgePlaybackMode::Adaptive)),
            DrainClass::PictureNewestWins
        ));
        // The transport commands stay keep-all: superseding a Stop would leave
        // playback running with nothing left to stop it.
        assert!(matches!(
            super::classify_request(&super::WorkerRequest::StopPlayback),
            DrainClass::PictureKeepAll
        ));
    }

    /// The bug this policy exists to fix: during playback the Viewer asks for a
    /// frame every tick and the Scopes panel asks for a trace every 120 ms.
    /// Draining to the single newest request of *any* kind meant one trace threw
    /// away every frame queued behind it, so the picture froze on its first
    /// frame while the scopes carried on updating.
    #[test]
    fn a_scope_trace_does_not_supersede_a_frame() {
        let (tx, rx) = channel();
        for frame in 1..=3 {
            tx.send(Req::Adaptive(frame)).unwrap();
        }
        // The trace arrives last, which is what used to win outright.
        tx.send(Req::Scope(9)).unwrap();
        drop(tx);

        let (pictures, scope, _, superseded) = drain_to_newest(Req::Adaptive(0), &rx, classify);
        assert_eq!(
            pictures,
            vec![Req::Adaptive(3)],
            "the newest frame survives a trace queued behind it"
        );
        assert_eq!(scope, Some(Req::Scope(9)), "and the trace is served too");
        assert_eq!(superseded, 3, "the three older frames were dropped");
    }

    /// The behaviour the policy is *for*: a backlog of adaptive pictures
    /// collapses to the newest, because the ones behind it are frames nobody
    /// will ever see.
    #[test]
    fn pictures_still_collapse_to_the_newest() {
        let (tx, rx) = channel();
        for frame in 1..=5 {
            tx.send(Req::Adaptive(frame)).unwrap();
        }
        drop(tx);

        let (pictures, scope, _, superseded) = drain_to_newest(Req::Adaptive(0), &rx, classify);
        assert_eq!(pictures, vec![Req::Adaptive(5)]);
        assert_eq!(scope, None, "nothing asked for a trace");
        assert_eq!(superseded, 5);
    }

    /// And traces collapse among themselves for the same reason.
    #[test]
    fn traces_collapse_to_the_newest_too() {
        let (tx, rx) = channel();
        tx.send(Req::Scope(2)).unwrap();
        tx.send(Req::Scope(3)).unwrap();
        drop(tx);

        let (pictures, scope, _, superseded) = drain_to_newest(Req::Scope(1), &rx, classify);
        assert!(pictures.is_empty());
        assert_eq!(scope, Some(Req::Scope(3)));
        assert_eq!(superseded, 2);
    }

    /// A single request with nothing behind it is served as it is.
    #[test]
    fn a_lone_request_is_not_counted_as_superseded() {
        let (tx, rx) = channel::<Req>();
        drop(tx);

        let (pictures, scope, _, superseded) = drain_to_newest(Req::Adaptive(7), &rx, classify);
        assert_eq!(pictures, vec![Req::Adaptive(7)]);
        assert_eq!(scope, None);
        assert_eq!(superseded, 0);
    }

    /// The keep-all class's contract: nothing dropped, order preserved — what
    /// keeps a Play or a Stop from vanishing under a backlog of pictures.
    #[test]
    fn every_frame_requests_all_survive_in_order() {
        let (tx, rx) = channel();
        for frame in 2..=4 {
            tx.send(Req::EveryFrame(frame)).unwrap();
        }
        // An adaptive scrub and a trace land in the middle of the backlog.
        tx.send(Req::Adaptive(9)).unwrap();
        tx.send(Req::Scope(1)).unwrap();
        drop(tx);

        let (pictures, scope, _, superseded) = drain_to_newest(Req::EveryFrame(1), &rx, classify);
        assert_eq!(
            pictures,
            vec![
                Req::EveryFrame(1),
                Req::EveryFrame(2),
                Req::EveryFrame(3),
                Req::EveryFrame(4),
                Req::Adaptive(9),
            ],
            "every-frame requests all survive, in order, before the adaptive one"
        );
        assert_eq!(scope, Some(Req::Scope(1)));
        assert_eq!(superseded, 0, "nothing every-frame was thrown away");
    }

    /// A dropper read has its own lane. The Scopes panel and an armed dropper
    /// are often open together — the panel asks every 120 ms and the magnifier
    /// asks on every pointer move — and neither question is the other's
    /// replacement, so neither may supersede the other or a frame.
    #[test]
    fn a_dropper_read_and_a_trace_do_not_supersede_each_other() {
        let (tx, rx) = channel();
        tx.send(Req::Scope(1)).unwrap();
        tx.send(Req::Sample(7)).unwrap();
        tx.send(Req::Sample(8)).unwrap();
        drop(tx);

        let (pictures, scope, sample, superseded) =
            drain_to_newest(Req::Adaptive(4), &rx, classify);
        assert_eq!(pictures, vec![Req::Adaptive(4)], "the frame survives both");
        assert_eq!(
            scope,
            Some(Req::Scope(1)),
            "and the trace survives the reads"
        );
        assert_eq!(
            sample,
            Some(Req::Sample(8)),
            "reads collapse among themselves — only where the pointer is now matters"
        );
        assert_eq!(superseded, 1, "one older read, and nothing else");
    }

    /// The window is always exactly `window × window`, odd, and centred on the
    /// pixel the fraction names — including hard against an edge, where the
    /// picture runs out and the edge pixel repeats. A ragged square would leave
    /// the magnifier drawing whatever was in memory next, and the frontend
    /// indexes this square without a border case.
    #[test]
    fn a_window_is_square_odd_and_clamped_to_the_picture() {
        // 2×2: red, green / blue, white.
        let rgba = vec![
            255, 0, 0, 255, 0, 255, 0, 255, //
            0, 0, 255, 255, 255, 255, 255, 255,
        ];
        let patch = super::cut_patch(&rgba, 2, 2, 0.0, 0.0, 3).expect("a picture to read");
        assert_eq!(patch.window, 3);
        assert_eq!(patch.rgba.len(), 3 * 3 * 4);
        assert_eq!((patch.x, patch.y), (0, 0), "the top-left pixel");
        // The centre cell is the pixel asked for; the row above repeats it,
        // because there is no row above.
        assert_eq!(
            &patch.rgba[16..20],
            &[255, 0, 0, 255],
            "centre is the red pixel"
        );
        assert_eq!(
            &patch.rgba[0..4],
            &[255, 0, 0, 255],
            "off the top-left, the edge repeats"
        );
        assert_eq!(
            &patch.rgba[20..24],
            &[0, 255, 0, 255],
            "and the neighbour is the green one"
        );

        // An even window is forced odd, and one past the cap is capped, so the
        // centre cell always means one pixel and the payload stays a reading.
        assert_eq!(
            super::cut_patch(&rgba, 2, 2, 0.5, 0.5, 4)
                .expect("cut")
                .window,
            5
        );
        assert_eq!(
            super::cut_patch(&rgba, 2, 2, 0.5, 0.5, 9999)
                .expect("cut")
                .window,
            super::MAX_WINDOW
        );
        // And the cap really is a cap on the payload: the biggest reply the
        // dropper can ask for stays two orders of magnitude below a frame
        // (8 MiB at 1080p, K-183), which is what keeps this a reading.
        let biggest = super::cut_patch(&rgba, 2, 2, 0.5, 0.5, u32::MAX).expect("cut");
        assert_eq!(biggest.window, super::MAX_WINDOW);
        assert!(biggest.rgba.len() < 100_000, "{}", biggest.rgba.len());

        // A picture with fewer bytes than it claims is refused rather than read
        // past the end of.
        assert!(super::cut_patch(&[0, 0, 0, 255], 2, 2, 0.0, 0.0, 1).is_none());
        assert!(super::cut_patch(&rgba, 0, 0, 0.0, 0.0, 1).is_none());
    }

    /// The Type tool's live preview (K-225): the picture keeps up with what is
    /// being typed, and the document is not touched until the edit ends.
    #[test]
    fn a_text_preview_replaces_only_a_text_layer() {
        use crate::api::assets::{BridgeColourRgba, BridgeTextDocument};
        use lumit_core::model::{LayerKind, LinearColour, TextDocument};

        let typed = BridgeTextDocument {
            text: "Hello".into(),
            size: 48.0,
            fill: BridgeColourRgba {
                r: 1.0,
                g: 0.5,
                b: 0.0,
                a: 1.0,
            },
        };

        let mut text = LayerKind::Text {
            document: TextDocument {
                text: "Text".into(),
                size: 72.0,
                fill: LinearColour([1.0, 1.0, 1.0, 1.0]),
                extra: serde_json::Map::new(),
            },
        };
        super::apply_text_preview(&mut text, typed.clone());
        let LayerKind::Text { document } = &text else {
            panic!("still a text layer");
        };
        assert_eq!(document.text, "Hello");
        assert_eq!(document.size, 48.0);
        assert_eq!(document.fill.0[1], 0.5);

        // A layer that is not text takes the preview without changing: a stale
        // request must never fail a frame.
        let mut other = LayerKind::Adjustment;
        super::apply_text_preview(&mut other, typed);
        assert!(matches!(other, LayerKind::Adjustment));
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod bar_strip_tests {
    use super::{refine_bar_strip, sample_bar_strip, wants_disk_lead};

    /// Playback asks the disk tier for a frame in advance, and only when the
    /// read is of use.
    ///
    /// **Why this matters.** A read off disk arrives one or two turns of the
    /// worker loop after it is asked for. A frame asked for at the moment it
    /// must be shown thus always arrives too late, and the frame is composited
    /// again — which made a span parked on disk worth nothing to playback. The
    /// loop asks for the coming frames instead, at the same time as it posts
    /// their source decodes.
    ///
    /// The rule is tested here; that playback applies it over the whole
    /// look-ahead window is `play_one_frame`'s to do, and the tiers below it are
    /// proven in `lumit_render::diskio::tests`.
    #[test]
    fn a_coming_frame_is_read_off_disk_only_when_the_read_helps() {
        // On disk, and nowhere above it: the one case that gains a read.
        assert!(wants_disk_lead(false, false, true, false));
        // On the card already: playback shows it without any of this.
        assert!(!wants_disk_lead(true, false, true, false));
        // In memory: one upload away, which is cheaper than a file.
        assert!(!wants_disk_lead(false, true, true, false));
        // Not on disk at all: there is nothing to read.
        assert!(!wants_disk_lead(false, false, false, false));
        // Asked for already: a second read of the same frame is pure IO.
        assert!(!wants_disk_lead(false, false, true, true));
    }

    /// A composition short enough to name every frame of is named exactly, and
    /// reports itself finished — there is nothing for the refinement pass to do.
    #[test]
    fn a_short_composition_is_exact_on_the_first_pass() {
        let held = [false, true, true, false, true];
        let mut asked = Vec::new();
        let sampled = sample_bar_strip(5, 1, &mut |frame| {
            asked.push(frame);
            u8::from(held[frame as usize]) * 2
        });
        assert_eq!(sampled.tiers, vec![0, 2, 2, 0, 2]);
        assert_eq!(sampled.refined_to, 5, "a stride of one leaves nothing over");
        assert_eq!(asked, vec![0, 1, 2, 3, 4], "every frame named once");
    }

    /// A long one is sampled: one frame in four is named and stands for the four.
    /// The whole stripe therefore has an answer immediately — the alternative is a
    /// bar that fills in from one end, which reads as the *cache* filling in from
    /// one end.
    #[test]
    fn a_long_composition_is_sampled_then_refined_to_the_truth() {
        // Frame 4 is the only one held, and it is not a sample point (samples are
        // 0, 4, 8, … with stride 4 — so it IS one here; use 5 instead).
        let held = |frame: u64| frame == 5;
        let tier = move |frame: u64| u8::from(held(frame)) * 2;

        let mut sampled = sample_bar_strip(12, 4, &mut { tier });
        assert_eq!(
            sampled.tiers,
            vec![0; 12],
            "frame 5 is not a sample point, so the coarse pass misses it"
        );
        assert_eq!(sampled.refined_to, 0, "and the strip needs refining");

        // Two turns of four frames each: the truth appears where it belongs, and
        // only there.
        let refined = refine_bar_strip(&mut sampled.tiers, 0, 0, 4, &mut { tier });
        assert_eq!(refined, 4);
        assert_eq!(sampled.tiers, vec![0; 12], "the first four hold nothing");
        let refined = refine_bar_strip(&mut sampled.tiers, 0, refined, 4, &mut { tier });
        assert_eq!(refined, 8);
        assert_eq!(
            sampled.tiers,
            vec![0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0],
            "frame 5 alone, not the run of four it sits in"
        );

        // And the sweep finishes rather than running past the end.
        let refined = refine_bar_strip(&mut sampled.tiers, 0, refined, 100, &mut { tier });
        assert_eq!(refined, 12);
    }

    /// A held sample paints the frames it stands for, so a warm span reads warm
    /// straight away — the coarse pass's whole purpose.
    #[test]
    fn a_held_sample_stands_for_the_frames_it_skipped() {
        let sampled = sample_bar_strip(8, 4, &mut |frame| if frame == 0 { 2 } else { 0 });
        assert_eq!(sampled.tiers, vec![2, 2, 2, 2, 0, 0, 0, 0]);
    }

    /// **The refinement starts where the user is looking.** It sweeps from the
    /// anchor and wraps, so on a long composition the region under the playhead
    /// firms up in the first turn rather than after a sweep of everything before
    /// it.
    #[test]
    fn the_refinement_sweep_starts_at_the_anchor_and_wraps() {
        let mut asked = Vec::new();
        let mut tiers = vec![0u8; 10];
        let refined = refine_bar_strip(&mut tiers, 8, 0, 4, &mut |frame| {
            asked.push(frame);
            0
        });
        assert_eq!(
            asked,
            vec![8, 9, 0, 1],
            "from the anchor, wrapping past the end"
        );
        assert_eq!(refined, 4);

        // Picking up where it left off, still relative to the anchor.
        asked.clear();
        refine_bar_strip(&mut tiers, 8, refined, 3, &mut |frame| {
            asked.push(frame);
            0
        });
        assert_eq!(asked, vec![2, 3, 4]);
    }

    /// Refinement overwrites a coarse guess with the truth, including downwards:
    /// a frame the coarse pass painted green because its sample was held reads as
    /// nothing once it is named itself.
    #[test]
    fn refinement_corrects_the_coarse_guess_in_both_directions() {
        let mut tiers = vec![2u8, 2, 2, 2];
        refine_bar_strip(&mut tiers, 0, 0, 4, &mut |frame| {
            if frame == 1 {
                4
            } else {
                0
            }
        });
        assert_eq!(tiers, vec![0, 4, 0, 0]);
    }

    /// Degenerate spans do nothing rather than panicking — an empty composition
    /// and a zero-length turn both reach here from ordinary interface states.
    #[test]
    fn empty_strips_and_empty_turns_are_calm() {
        let mut none: Vec<u8> = Vec::new();
        assert_eq!(refine_bar_strip(&mut none, 0, 0, 8, &mut |_| 2), 0);
        let mut some = vec![0u8; 4];
        assert_eq!(refine_bar_strip(&mut some, 0, 0, 0, &mut |_| 2), 0);
        assert_eq!(some, vec![0; 4]);
        assert!(sample_bar_strip(0, 4, &mut |_| 2).tiers.is_empty());
        // A stride of zero would divide by nothing; it is floored to one.
        assert_eq!(sample_bar_strip(2, 0, &mut |_| 2).tiers, vec![2, 2]);
    }
}
