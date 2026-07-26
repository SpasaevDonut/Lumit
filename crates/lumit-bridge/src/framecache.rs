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
//! ## Keying by content
//!
//! Each entry is filed under the **content hash** of the frame
//! ([`lumit_render::cache::frame_key`]): a hash of every layer's transform,
//! effects, masks, blend and switches, which file each footage layer reads and
//! which frame of it, plus the resolution tier. Two frames with the same name
//! are the same picture, so no invalidation step is needed at all — an edit
//! simply produces different names for the frames it changed.
//!
//! That is a real behavioural improvement over what this cache did before
//! K-178, when it keyed on `(comp, frame, scale)` and pinned the *identity* of
//! the current document snapshot, clearing everything whenever the document
//! changed. Renaming a layer, nudging the work area or toggling a solo — none of
//! which can change a pixel — threw away every cached frame in the project.
//! Now they change no frame's name, so nothing is thrown away; and an edit to
//! one layer retires only the frames that layer actually appears in. Frames
//! whose footage is still unprobed have no name and are simply not cached, so a
//! frame can never be filed under a promise it did not keep.
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

/// One frame's cache identity: the content hash
/// [`lumit_render::cache::frame_key`] computed for it. A plain `u128`, because
/// the hash already carries everything that distinguishes one frame from
/// another — including the resolution tier.
pub(crate) type FrameKey = u128;

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
    if let Some(hit) = with_cache(|c| c.get(&key)) {
        return Some(hit);
    }
    let (w, h, rgba) = render()?;
    with_cache(|c| c.put(key, w, h, rgba.clone()));
    Some((w, h, rgba))
}

/// Resize the RAM budget (Settings → Performance). Returns the fresh stats.
pub(crate) fn set_budget(bytes: usize) -> (usize, usize, usize, u64, u64) {
    with_cache(|c| {
        c.set_budget(bytes);
        c.stats()
    })
}

/// Empty the cache now (Settings → Clear cache). Returns the fresh stats.
pub(crate) fn clear() -> (usize, usize, usize, u64, u64) {
    with_cache(|c| {
        c.clear();
        c.stats()
    })
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
        let (_, _, _, _, _) = clear();
        let (_, budget, _, _, _) = set_budget(123 * 1024 * 1024);
        assert_eq!(budget, 123 * 1024 * 1024);
        let (used, budget2, _entries, _hits, _misses) = stats();
        assert_eq!(budget2, 123 * 1024 * 1024);
        assert_eq!(used, 0);
        // Restore the default so other tests see a sane budget.
        set_budget(DEFAULT_BUDGET_BYTES);
    }
}
