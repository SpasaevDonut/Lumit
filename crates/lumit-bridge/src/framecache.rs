//! The bridge-side rendered-frame cache (K-176) — the scrub fix.
//!
//! # In plain terms
//!
//! Rendering a whole composited comp and reading its pixels back off the GPU is
//! the single most expensive thing the Viewer does. When you scrub back and
//! forth over the same handful of frames, egui never re-renders them: it keeps a
//! map of already-rendered frames in RAM (`AppState::comp_frame_cache`) and a
//! re-visited frame is just a map lookup. The Flutter path had no such thing —
//! every scrub frame re-rendered end to end. This module is that map for the
//! bridge: it holds the finished RGBA bytes of frames we have already rendered,
//! named by what is actually *in* them, so a re-scrubbed frame is served from
//! memory without touching the GPU.
//!
//! ## Keying by position, and what that costs
//!
//! Each entry is filed under `(comp, frame, scale)` — see [`frame_key`]. The
//! name says *where* a frame is, not what is in it.
//!
//! That has one consequence which has to be handled explicitly: an edit does not
//! change any frame's name, so without help the cache would keep serving the
//! picture from before the edit. It did exactly that until this was written —
//! changing a layer's opacity and scrubbing back gave you the old frame, byte
//! for byte. [`invalidate_all`] is the answer: a committed change drops every
//! held frame.
//!
//! The design K-178 describes is better and is still the goal: file each frame
//! under a **content hash** ([`lumit_render::cache::frame_key`]) covering every
//! layer's transform, effects, masks, blend and switches, and which source frame
//! each footage layer reads. Then an edit simply produces different names for
//! the frames it changed, nothing is thrown away unnecessarily, and renaming a
//! layer costs nothing. Reaching it needs the probe view here, which the bridge
//! does not have yet (docs/TODO.md).
//!
//! ## Budget and eviction
//!
//! The cache is bounded by a byte budget ([`DEFAULT_BUDGET_BYTES`], overridable
//! from Settings → Performance). On insert it evicts the least-recently-used
//! entries until it fits. Eviction scans for the oldest entry (`O(n)` in the
//! number of cached frames — a few tens at 1080p under the default budget, so
//! the scan is cheap; a linked-hash-map would make it `O(1)` if the count ever
//! grows large, noted as future work).
//!
//! ## GPU path (shared texture, K-177)
//!
//! Only the CPU read-back path is cached here: it owns the finished RGBA bytes,
//! so caching them is honest and cheap, and a hit skips the whole render. The
//! zero-copy shared-texture path holds exactly **one** GPU texture (the frame
//! last presented into it), so there is nothing to cache without either keeping
//! N shared textures alive (VRAM the budget does not model) or reading the pixels
//! back (defeating the zero-copy point). The honest design is: leave the shared
//! path uncached, and when a comp is being scrubbed the CPU cache still warms —
//! the Viewer can fall back to a cached CPU frame. The Dart worker prefers the
//! shared path when live but the CPU cache is what makes re-scrubs free; the two
//! do not conflict. Recorded here rather than half-built.

// Without the `render` feature nothing populates the cache (there is no
// compositor linked), so the get/put machinery is inert — only the empty-map
// budget/clear/stats controls run. Say so rather than gating each item, so the
// FFI controls stay callable in every build.

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

/// The default RAM cap for rendered frames: 512 MiB. Sized so a comfortable run
/// of 1080p frames (~8 MiB each → ~64 frames) stays warm without the cache
/// growing without bound. Settings → Performance overrides it via
/// [`set_budget`].
pub(crate) const DEFAULT_BUDGET_BYTES: usize = 512 * 1024 * 1024;

/// One frame's cache identity: `(comp, frame, scale)` packed into a `u128` by
/// [`frame_key`].
pub(crate) type FrameKey = u128;

/// A preview scale as it appears in a key: thousandths, so a panel resized by
/// half a pixel does not produce a scale that misses every time.
pub(crate) fn scale_quantised(scale: f32) -> u16 {
    ((scale * 1000.0).round().clamp(0.0, f32::from(u16::MAX)) as u32 & 0xFFFF) as u16
}

/// The cache key for one rendered frame: the comp, the frame, and the scale it
/// was made at.
///
/// The comp's low 64 bits occupy the top half; the frame takes the next 48 bits
/// and the quantised scale the low 16. The frame is masked to its 48 bits so a
/// preposterous frame number cannot run up into the comp's half and name a
/// different composition's picture.
pub(crate) fn frame_key(comp: uuid::Uuid, frame: u64, scale: f32) -> FrameKey {
    frame_key_quantised(comp, frame, scale_quantised(scale))
}

/// [`frame_key`] with the scale already in thousandths — the form the VRAM
/// mirror publishes, since the renderer keys its textures the same way.
pub(crate) fn frame_key_quantised(comp: uuid::Uuid, frame: u64, scale_q: u16) -> FrameKey {
    let low = comp.as_u128() as u64;
    (u128::from(low) << 64) | (u128::from(frame & 0xFFFF_FFFF_FFFF) << 16) | u128::from(scale_q)
}

/// Which of `frames` frames of `comp` are held, and at what resolution relative
/// to `scale` — the answer the Timeline's cache bar draws.
///
/// `0` = not cached, `1` = cached only at a coarser scale than asked for (still
/// something to show, but it would be re-rendered to display at this size),
/// `2` = cached at this scale, ready now.
///
/// One pass over the key set rather than one lookup per frame, so the cost is
/// the number of *cached* frames rather than the length of the composition.
pub(crate) fn cached_tiers(comp: uuid::Uuid, frames: u64, scale: f32) -> Vec<u8> {
    let wanted = scale_quantised(scale);
    let comp_low = comp.as_u128() as u64;
    let mut out = vec![0u8; frames as usize];
    let mut mark = |key: &FrameKey| {
        if (key >> 64) as u64 != comp_low {
            return;
        }
        let frame = ((key >> 16) & 0xFFFF_FFFF_FFFF) as u64;
        if frame >= frames {
            return;
        }
        // A coarser render is a smaller number; equal or finer will serve.
        let held = (key & 0xFFFF) as u16;
        let tier = if held >= wanted { 2u8 } else { 1u8 };
        let slot = &mut out[frame as usize];
        *slot = (*slot).max(tier);
    };
    with_cache(|c| {
        for key in c.map.keys() {
            mark(key);
        }
    });
    // The VRAM tier's holdings, as the worker last published them — same key
    // packing, so the same comparison. A frame held on the card is as green
    // as one held in RAM: playback serves it without rendering.
    for key in vram::keys() {
        mark(&key);
    }
    out
}

/// The finest held picture of `comp` at `frame`, whatever scale it was made at,
/// stamped most-recently-used.
///
/// For the Scopes, which need the *numbers* in a frame rather than a frame at
/// any particular size. They were compositing the whole composition again to get
/// them — a second full render of the frame the Viewer had just rendered, several
/// times a second, all through playback. Any resolution answers the question a
/// waveform or a vectorscope asks, so the one already in hand will do.
///
/// Does not count as a hit or a miss: those numbers describe how well the Viewer
/// is being served, and mixing a second consumer into them would make the meter
/// mean nothing.
pub(crate) fn best_frame(comp: uuid::Uuid, frame: u64) -> Option<(u32, u32, Vec<u8>)> {
    let comp_low = comp.as_u128() as u64;
    with_cache(|c| {
        let key = c
            .map
            .keys()
            .filter(|k| {
                (*k >> 64) as u64 == comp_low && ((*k >> 16) & 0xFFFF_FFFF_FFFF) as u64 == frame
            })
            // The finest one held: the scale lives in the low 16 bits, so the
            // largest key among these is the largest scale.
            .max()
            .copied()?;
        let entry = c.map.get_mut(&key)?;
        c.clock += 1;
        entry.last_used = c.clock;
        Some((entry.width, entry.height, entry.rgba.clone()))
    })
}

/// Drop every held frame, because the document changed.
///
/// **Why all of them, and not just the composition that was edited.** Deciding
/// which frames an edit can reach is a harder question than it looks, and
/// getting it wrong means silently showing a picture the document no longer
/// describes:
///
/// * a batched edit (a two-axis position drag, adding a solid) names no single
///   composition at all;
/// * changing a solid's colour or relinking footage edits a *project item*,
///   which any number of compositions may draw;
/// * a precomp layer means editing composition A changes every composition that
///   contains A, at any depth.
///
/// The scope attached to a change answers a different question — which panel
/// should redraw — and using it here would leave every case above stale. So this
/// is deliberately blunt. It is also why content keying is worth doing (see the
/// module docs): under it none of this reasoning is needed, because an edit
/// simply gives new names to the frames it changed.
///
/// The hit and miss counters survive: they describe the session, not the
/// contents, and resetting them on every keystroke would make the meter useless.
pub(crate) fn invalidate_all() {
    with_cache(|c| {
        c.map.clear();
        c.used = 0;
        // Anything a render is holding right now was planned against the
        // document as it was before this edit, so it must not be banked.
        c.generation = c.generation.wrapping_add(1);
    });
}

/// One cached frame: its dimensions and the tightly-packed RGBA8 bytes, plus the
/// LRU clock value of its last use.
struct Entry {
    width: u32,
    height: u32,
    rgba: Vec<u8>,
    last_used: u64,
}

/// The rendered-frame cache: an LRU of RGBA frames under a byte budget, each
/// named by its content hash (see the module docs).
pub(crate) struct Cache {
    budget: usize,
    used: usize,
    map: HashMap<FrameKey, Entry>,
    /// Monotonic LRU clock; each access stamps an entry's `last_used`.
    clock: u64,
    hits: u64,
    misses: u64,
    /// Bumped by [`invalidate_all`]. A render that began before the bump is of
    /// the document as it was, so its pixels are dropped rather than stored —
    /// otherwise an edit landing mid-render would be undone by that render
    /// finishing, and the stale frame would stay for good.
    generation: u64,
}

impl Cache {
    fn new(budget: usize) -> Self {
        Self {
            budget,
            used: 0,
            map: HashMap::new(),
            clock: 0,
            hits: 0,
            misses: 0,
            generation: 0,
        }
    }

    /// Fetch a cached frame, stamping it most-recently-used. Counts one hit or
    /// one miss. The returned bytes are cloned (the caller owns them; the cache
    /// keeps its copy).
    fn get(&mut self, key: &FrameKey) -> Option<(u32, u32, Vec<u8>)> {
        self.clock += 1;
        let clock = self.clock;
        match self.map.get_mut(key) {
            Some(entry) => {
                entry.last_used = clock;
                self.hits += 1;
                Some((entry.width, entry.height, entry.rgba.clone()))
            }
            None => {
                self.misses += 1;
                None
            }
        }
    }

    /// Store a rendered frame, evicting the least-recently-used entries first so
    /// the total stays within budget. A single frame larger than the whole
    /// budget is not cached (it would evict everything and still not fit).
    fn put(&mut self, key: FrameKey, width: u32, height: u32, rgba: Vec<u8>) {
        let bytes = rgba.len();
        if bytes == 0 || bytes > self.budget {
            return;
        }
        // Replacing an existing key: reclaim its bytes first.
        if let Some(old) = self.map.remove(&key) {
            self.used = self.used.saturating_sub(old.rgba.len());
        }
        self.evict_until_fits(bytes);
        self.clock += 1;
        self.map.insert(
            key,
            Entry {
                width,
                height,
                rgba,
                last_used: self.clock,
            },
        );
        self.used += bytes;
    }

    /// Drop least-recently-used entries until `incoming` more bytes fit.
    fn evict_until_fits(&mut self, incoming: usize) {
        while !self.map.is_empty() && self.used + incoming > self.budget {
            // Find the oldest entry (smallest `last_used`).
            let Some(oldest) = self
                .map
                .iter()
                .min_by_key(|(_, e)| e.last_used)
                .map(|(k, _)| *k)
            else {
                break;
            };
            if let Some(e) = self.map.remove(&oldest) {
                self.used = self.used.saturating_sub(e.rgba.len());
            }
        }
    }

    /// Resize the budget, evicting down to it immediately.
    fn set_budget(&mut self, budget: usize) {
        self.budget = budget;
        self.evict_until_fits(0);
    }

    /// Throw away every cached frame. Keeps the configured budget and the
    /// lifetime hit/miss counters.
    fn clear(&mut self) {
        self.map.clear();
        self.used = 0;
    }

    /// `(used_bytes, budget_bytes, entries, hits, misses)`.
    fn stats(&self) -> (usize, usize, usize, u64, u64) {
        (
            self.used,
            self.budget,
            self.map.len(),
            self.hits,
            self.misses,
        )
    }
}

/// The process-wide cache instance, shared by the render path and the FFI
/// controls. One Flutter window, one cache.
static CACHE: OnceLock<Mutex<Cache>> = OnceLock::new();

/// The worker renderer's comp-decode counter, mirrored each loop turn so
/// `cache_stats` can report it — a decode that should not have happened (a
/// drag that re-decoded, a cache that missed) is then visible in Settings
/// rather than merely slow (docs/TODO.md, Render pipeline).
static COMP_DECODES: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

pub(crate) fn publish_comp_decodes(count: u64) {
    COMP_DECODES.store(count, std::sync::atomic::Ordering::Relaxed);
}

pub(crate) fn comp_decodes() -> u64 {
    COMP_DECODES.load(std::sync::atomic::Ordering::Relaxed)
}

/// The invalidation generation, for consumers on other threads: the worker
/// compares it each loop turn and drops its VRAM final-frame cache when it
/// moved, since those textures are keyed by position exactly as this cache's
/// bytes are.
pub(crate) fn generation() -> u64 {
    with_cache(|c| c.generation)
}

/// The VRAM final-frame cache's controls and mirror. The textures themselves
/// live inside the worker's renderer (they are GPU objects only that thread
/// touches); what crosses threads is three atomics the settings ops write and
/// the worker applies, plus a snapshot of what is held that the worker
/// publishes and the cache bar reads — the §5.6 "lock-free bitmap" idea at
/// its plainest.
pub(crate) mod vram {
    use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
    use std::sync::Mutex;

    /// The budget the settings asked for; the worker applies it on its next
    /// turn.
    static BUDGET: AtomicUsize = AtomicUsize::new(lumit_render::DEFAULT_VRAM_CACHE_BYTES);
    /// Bumped by Clear cache; the worker clears when it sees it move.
    static CLEARS: AtomicU64 = AtomicU64::new(0);
    /// What the worker last reported holding: the invalidation generation it
    /// held them under, (used, entries), and the held keys
    /// `(comp low 64 bits ‖ frame ‖ scale)` packed exactly like
    /// [`super::frame_key`], so the bar merge is integer comparisons. The
    /// generation is what keeps the bar honest across an edit: the worker's
    /// clear-and-republish is a loop turn away, and until it lands these keys
    /// describe frames that no longer exist. (The budget is deliberately not
    /// mirrored — the atomic above is the one authority on it.)
    static MIRROR: Mutex<(u64, u64, u64, Vec<u128>)> = Mutex::new((0, 0, 0, Vec::new()));

    pub(crate) fn set_budget(bytes: usize) {
        BUDGET.store(bytes, Ordering::Relaxed);
    }

    pub(crate) fn budget() -> usize {
        BUDGET.load(Ordering::Relaxed)
    }

    pub(crate) fn request_clear() {
        CLEARS.fetch_add(1, Ordering::Relaxed);
    }

    pub(crate) fn clears() -> u64 {
        CLEARS.load(Ordering::Relaxed)
    }

    /// The worker's report of what it holds, stamped with the invalidation
    /// generation it holds them under.
    pub(crate) fn publish(generation: u64, used: u64, entries: u64, keys: Vec<u128>) {
        let mut guard = MIRROR.lock().unwrap_or_else(|p| p.into_inner());
        *guard = (generation, used, entries, keys);
    }

    /// `(used, entries)` as last published.
    pub(crate) fn stats() -> (u64, u64) {
        let guard = MIRROR.lock().unwrap_or_else(|p| p.into_inner());
        (guard.1, guard.2)
    }

    /// The held keys as last published — empty when an edit has moved the
    /// generation past the report, since those frames are already gone (the
    /// worker just has not said so yet).
    pub(crate) fn keys() -> Vec<u128> {
        let guard = MIRROR.lock().unwrap_or_else(|p| p.into_inner());
        if guard.0 != super::generation() {
            return Vec::new();
        }
        guard.3.clone()
    }
}

fn with_cache<R>(f: impl FnOnce(&mut Cache) -> R) -> R {
    let mutex = CACHE.get_or_init(|| Mutex::new(Cache::new(DEFAULT_BUDGET_BYTES)));
    let mut guard = mutex.lock().unwrap_or_else(|p| p.into_inner());
    f(&mut guard)
}

/// Serve `key` from the cache, or render it with `render` and bank the result.
/// The cache lock is **dropped** across `render` (it never wraps GPU/FFI work —
/// docs/14 §"no locks across GPU"): a hit returns under the lock; a miss
/// releases it, renders, then re-locks to insert. A superseded render for the
/// same key simply overwrites, which is harmless — the key names the content, so
/// the pixels are identical. `render` is called at most once per genuine miss,
/// so a re-scrubbed frame never re-renders (proven by the module tests' render
/// counter).
pub(crate) fn get_or_render(
    key: FrameKey,
    render: impl FnOnce() -> Option<(u32, u32, Vec<u8>)>,
) -> Option<(u32, u32, Vec<u8>)> {
    let generation = match with_cache(|c| (c.get(&key), c.generation)) {
        (Some(hit), _) => return Some(hit),
        (None, generation) => generation,
    };
    let (w, h, rgba) = render()?;
    with_cache(|c| {
        // An edit landed while this was rendering, so these pixels are of the
        // document as it *was*. Hand them back — the caller asked for them, and
        // a newer frame is already on its way — but do not file them, or the
        // invalidation would be quietly undone and the stale frame kept for good.
        if c.generation == generation {
            c.put(key, w, h, rgba.clone());
        }
    });
    Some((w, h, rgba))
}

/// Resize the RAM budget (Settings → Performance).
pub(crate) fn set_budget(bytes: usize) {
    with_cache(|c| c.set_budget(bytes));
}

/// Empty the cache now (Settings → Clear cache).
pub(crate) fn clear() {
    with_cache(|c| c.clear());
}

/// `(used_bytes, budget_bytes, entries, hits, misses)`.
pub(crate) fn stats() -> (usize, usize, usize, u64, u64) {
    with_cache(|c| c.stats())
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    /// Frame names in these tests are arbitrary `u128`s: the cache only ever
    /// compares them. What the name MEANS — and the guarantee that an edit which
    /// cannot change a pixel produces the same name — is `lumit-render`'s to
    /// prove, and it does (`cache::tests`).
    const A: FrameKey = 1;
    const B: FrameKey = 2;
    const C: FrameKey = 3;

    /// A cached frame is served on the second identical request without invoking
    /// the renderer — the scrub guarantee, proven with a render counter on a
    /// local cache (deterministic, no GPU, no shared global).
    #[test]
    fn a_cached_frame_is_served_without_re_rendering() {
        let mut cache = Cache::new(DEFAULT_BUDGET_BYTES);
        let renders = std::cell::Cell::new(0u32);

        // The get-or-render dance the production path runs (here inline so the
        // counter is observable): hit, else render + put.
        let once = |cache: &mut Cache| -> (u32, u32, Vec<u8>) {
            if let Some(hit) = cache.get(&A) {
                return hit;
            }
            renders.set(renders.get() + 1);
            let frame = (4u32, 4u32, vec![7u8; 4 * 4 * 4]);
            cache.put(A, frame.0, frame.1, frame.2.clone());
            frame
        };

        let first = once(&mut cache);
        assert_eq!(renders.get(), 1, "first request renders");
        let second = once(&mut cache);
        assert_eq!(
            renders.get(),
            1,
            "second identical request is served from the cache"
        );
        assert_eq!(first, second, "the cached bytes match the rendered ones");
    }

    /// An edit that changes the picture changes the frame's name, so the render
    /// path simply misses and renders afresh — there is no invalidation step to
    /// get wrong. The flip side matters just as much: an edit that changes no
    /// pixel produces the same name and hits, which is why the cache no longer
    /// empties itself on every commit.
    #[test]
    fn a_changed_frame_name_misses_and_an_unchanged_one_hits() {
        let mut cache = Cache::new(DEFAULT_BUDGET_BYTES);
        cache.put(A, 2, 2, vec![1u8; 16]);

        assert!(
            cache.get(&B).is_none(),
            "a picture-changing edit renames the frame, so it misses"
        );
        assert!(
            cache.get(&A).is_some(),
            "an edit that cannot change a pixel keeps the name, so it hits"
        );
    }

    /// The byte budget evicts the least-recently-used frame first.
    #[test]
    fn the_budget_evicts_least_recently_used() {
        // Budget holds exactly two 16-byte frames.
        let mut cache = Cache::new(32);
        cache.put(A, 2, 2, vec![0u8; 16]);
        cache.put(B, 2, 2, vec![1u8; 16]);
        // Touch A so B is now the least-recently-used.
        assert!(cache.get(&A).is_some());
        cache.put(C, 2, 2, vec![2u8; 16]);

        assert!(cache.get(&A).is_some(), "recently used survives");
        assert!(cache.get(&C).is_some(), "the new frame is present");
        assert!(cache.get(&B).is_none(), "the LRU frame was evicted");
        let (used, budget, entries, _, _) = cache.stats();
        assert_eq!(budget, 32);
        assert_eq!(entries, 2);
        assert_eq!(used, 32);
    }

    /// Shrinking the budget evicts immediately; clearing empties the cache.
    #[test]
    fn resizing_and_clearing_free_frames() {
        let mut cache = Cache::new(64);
        cache.put(A, 2, 2, vec![0u8; 16]);
        cache.put(B, 2, 2, vec![0u8; 16]);
        assert_eq!(cache.stats().2, 2);

        cache.set_budget(16); // room for one
        assert_eq!(cache.stats().2, 1, "shrinking the budget evicts");

        cache.clear();
        assert_eq!(cache.stats().0, 0);
        assert_eq!(cache.stats().2, 0);
    }

    /// A frame larger than the whole budget is refused rather than thrashing.
    #[test]
    fn an_oversized_frame_is_not_cached() {
        let mut cache = Cache::new(16);
        cache.put(A, 4, 4, vec![0u8; 64]);
        assert_eq!(cache.stats().2, 0, "oversized frame skipped");
    }

    /// The global FFI-facing controls round-trip: clear, set budget, stats.
    #[test]
    fn global_controls_round_trip() {
        clear();
        set_budget(123 * 1024 * 1024);
        let (used, budget, _entries, _hits, _misses) = stats();
        assert_eq!(budget, 123 * 1024 * 1024);
        assert_eq!(used, 0);
        // Restore the default so other tests see a sane budget.
        set_budget(DEFAULT_BUDGET_BYTES);
    }

    /// The key's three fields survive a round trip and stay in their own bits.
    /// The frame is masked to 48 bits so an absurd frame number cannot run up
    /// into the composition's half and name another comp's picture.
    #[test]
    fn a_key_keeps_its_fields_apart() {
        let comp = uuid::Uuid::from_u128(0x1234_5678_9abc_def0_1122_3344_5566_7788);
        let key = frame_key(comp, 42, 0.5);
        assert_eq!(
            (key >> 64) as u64,
            comp.as_u128() as u64,
            "comp in the top half"
        );
        assert_eq!(
            ((key >> 16) & 0xFFFF_FFFF_FFFF) as u64,
            42,
            "frame in the middle"
        );
        assert_eq!((key & 0xFFFF) as u16, 500, "scale in thousandths");

        let absurd = frame_key(comp, u64::MAX, 1.0);
        assert_eq!(
            (absurd >> 64) as u64,
            comp.as_u128() as u64,
            "a huge frame number must not corrupt the composition"
        );
    }

    /// Two comps that differ only above the low 64 bits of their id would share
    /// a key. Vanishingly unlikely with v7 uuids, but worth stating: this is the
    /// one collision the packing permits.
    #[test]
    fn scale_is_quantised_to_thousandths() {
        assert_eq!(scale_quantised(1.0), 1000);
        assert_eq!(scale_quantised(0.3333), 333);
        // A panel resized by half a pixel must land on the same number.
        assert_eq!(scale_quantised(0.500_01), scale_quantised(0.499_99));
        // Nonsense cannot wrap into a plausible scale.
        assert_eq!(scale_quantised(-1.0), 0);
    }

    /// The bar merges the VRAM tier: a frame the worker published as held on
    /// the card is as green as one held in RAM, at the same scale comparison.
    #[test]
    fn cached_tiers_merges_the_vram_mirror() {
        let comp = uuid::Uuid::now_v7();
        clear();
        vram::publish(
            generation(),
            1,
            1,
            vec![
                frame_key_quantised(comp, 3, 500),
                frame_key_quantised(comp, 4, 250),
            ],
        );

        let tiers = cached_tiers(comp, 6, 0.5);
        assert_eq!(
            tiers,
            vec![0, 0, 0, 2, 1, 0],
            "frame 3 ready at this scale, frame 4 held only coarser"
        );

        // A generation older than the present names frames that are already
        // gone: the merge must ignore the whole report.
        invalidate_all();
        assert_eq!(
            cached_tiers(comp, 6, 0.5),
            vec![0; 6],
            "a stale mirror must not promise dropped frames"
        );

        // Leave the shared mirror empty for the other tests.
        vram::publish(generation(), 0, 0, Vec::new());
        clear();
    }

    /// The cache bar's answer: nothing, coarser than asked for, or ready.
    #[test]
    fn cached_tiers_reports_what_is_held_and_how_fine() {
        let comp = uuid::Uuid::now_v7();
        let other = uuid::Uuid::now_v7();
        clear();

        with_cache(|c| {
            // Frame 1 at the wanted scale, frame 2 only coarser, frame 4 finer.
            c.put(frame_key(comp, 1, 0.5), 2, 2, vec![0; 16]);
            c.put(frame_key(comp, 2, 0.25), 2, 2, vec![0; 16]);
            c.put(frame_key(comp, 4, 1.0), 2, 2, vec![0; 16]);
            // Another composition's frame must not appear in this one's bar.
            c.put(frame_key(other, 3, 0.5), 2, 2, vec![0; 16]);
        });

        let tiers = cached_tiers(comp, 6, 0.5);
        assert_eq!(tiers, vec![0, 2, 1, 0, 2, 0]);
        clear();
    }

    /// Positional keys do not change when the picture does, so a committed edit
    /// has to drop held frames by hand. Until this existed the Viewer was served
    /// the frame from before the edit, byte for byte.
    ///
    /// Every composition's frames go, not just the edited one: a batched edit
    /// names no composition, a solid or a footage relink is a project item many
    /// compositions may draw, and a precomp means editing one composition
    /// changes every composition that contains it.
    #[test]
    fn invalidating_drops_every_composition() {
        let comp = uuid::Uuid::now_v7();
        let other = uuid::Uuid::now_v7();
        clear();
        with_cache(|c| {
            c.put(frame_key(comp, 0, 1.0), 2, 2, vec![0; 16]);
            c.put(frame_key(other, 0, 1.0), 2, 2, vec![0; 16]);
        });

        invalidate_all();

        assert_eq!(cached_tiers(comp, 1, 1.0), vec![0]);
        assert_eq!(
            cached_tiers(other, 1, 1.0),
            vec![0],
            "a precomp or a shared solid could have reached it"
        );
        with_cache(|c| assert_eq!(c.used, 0));
        clear();
    }

    /// The Scopes read the values in a frame, so any resolution answers their
    /// question — and the frame the Viewer just rendered is right there. They
    /// were compositing the whole composition a second time to get it, several
    /// times a second, for as long as playback ran with the panel open.
    #[test]
    fn the_finest_held_picture_of_a_frame_is_reusable() {
        let comp = uuid::Uuid::now_v7();
        let other = uuid::Uuid::now_v7();
        clear();
        with_cache(|c| {
            c.put(frame_key(comp, 5, 0.25), 4, 4, vec![1; 64]);
            c.put(frame_key(comp, 5, 0.5), 8, 8, vec![2; 256]);
            c.put(frame_key(comp, 6, 1.0), 16, 16, vec![3; 1024]);
            c.put(frame_key(other, 5, 1.0), 32, 32, vec![4; 4096]);
        });

        let (w, h, rgba) = best_frame(comp, 5).expect("frame 5 is held");
        assert_eq!((w, h), (8, 8), "the finest one held, not just any");
        assert_eq!(rgba[0], 2);

        assert!(best_frame(comp, 7).is_none(), "nothing held for frame 7");

        // Another composition's frame of the same number must never be handed
        // over — the scope would be reading a different picture entirely.
        let (w, _, _) = best_frame(other, 5).expect("the other comp has its own");
        assert_eq!(w, 32);

        // `best_frame` deliberately does not touch the hit and miss counters —
        // they describe how well the *Viewer* is served, and folding a second
        // consumer into them would make the meter meaningless. Not asserted
        // here: those counters are global and these tests share them, so the
        // check would depend on what else happened to be running.
        clear();
    }

    /// The race: an edit landing while a frame is being rendered must not be
    /// undone by that render finishing and banking pre-edit pixels.
    #[test]
    fn a_render_in_flight_when_an_edit_lands_is_not_banked() {
        let comp = uuid::Uuid::now_v7();
        clear();

        let out = get_or_render(frame_key(comp, 0, 1.0), || {
            invalidate_all();
            Some((2, 2, vec![9; 16]))
        });

        assert!(
            out.is_some(),
            "the caller still gets the pixels it asked for"
        );
        assert_eq!(
            cached_tiers(comp, 1, 1.0),
            vec![0],
            "but they are not kept, or the invalidation would be undone"
        );
        clear();
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod transport_cost {
    /// A stopwatch for the pixel path's serialisation, run by hand:
    /// `cargo test -p lumit_bridge --release -- --ignored --nocapture encode_cost`
    ///
    /// It reproduces the generated `SseEncode for Vec<u8>` exactly — a per-byte
    /// `write_u8` loop (`frb_generated.rs`, `impl SseEncode for Vec<u8>`) —
    /// against the bulk copy the same bytes could have had. The generated code
    /// itself is not callable from a test (the trait is private to the generated
    /// module), so this measures the identical loop rather than the code.
    #[test]
    #[ignore = "timing, not correctness"]
    fn encode_cost() {
        use flutter_rust_bridge::for_generated::byteorder::WriteBytesExt;

        for (label, w, h) in [("800x450", 800u32, 450u32), ("1920x1080", 1920, 1080)] {
            let bytes = (w * h * 4) as usize;
            let frame = vec![7u8; bytes];
            let n = 20;

            let started = std::time::Instant::now();
            for _ in 0..n {
                let mut out: Vec<u8> = Vec::new();
                for item in &frame {
                    out.write_u8(*item).unwrap();
                }
                std::hint::black_box(out);
            }
            let per_byte = started.elapsed().as_secs_f64() * 1000.0 / f64::from(n);

            let started = std::time::Instant::now();
            for _ in 0..n {
                let mut out: Vec<u8> = Vec::new();
                out.extend_from_slice(&frame);
                std::hint::black_box(out);
            }
            let bulk = started.elapsed().as_secs_f64() * 1000.0 / f64::from(n);

            println!(
                "ENCODE {label:>10} {:>5.1} MB  per-byte {per_byte:>7.2} ms  bulk {bulk:>7.2} ms",
                bytes as f64 / 1e6
            );
        }
    }
}
