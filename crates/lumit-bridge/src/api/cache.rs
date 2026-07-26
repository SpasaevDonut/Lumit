//! The rendered-frame cache's readouts and controls.
//!
//! # In plain terms
//!
//! Rendering a frame is expensive, so the engine keeps the ones it has already
//! made and hands them back if you return to that moment. This is the window
//! onto that store: how much of it is used, how often it saved a render, and the
//! two buttons that resize or empty it.
//!
//! It is deliberately a readout rather than something the interface has to keep
//! in step. Nothing here changes the document, so none of it is undoable and
//! none of it goes through an op — asking is always safe.

use flutter_rust_bridge::frb;

/// What the cache currently holds, for the Timeline's cache bar and the
/// Settings window's budget control.
#[frb(non_opaque)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BridgeCacheStats {
    pub used_bytes: u64,
    pub budget_bytes: u64,
    pub entries: u64,
    /// Frames served from the cache rather than rendered.
    pub hits: u64,
    /// Frames that had to be rendered.
    pub misses: u64,
}

#[frb(ignore)]
fn read() -> BridgeCacheStats {
    let (used, budget, entries, hits, misses) = crate::framecache::stats();
    BridgeCacheStats {
        used_bytes: used as u64,
        budget_bytes: budget as u64,
        entries: entries as u64,
        hits,
        misses,
    }
}

/// The cache's live numbers.
///
/// Cheap enough to poll on the interface's own cadence — it reads five counters
/// behind one lock and renders nothing. It must never be called *per paint*
/// even so: the lock it takes is the one a render holds.
#[frb(sync)]
pub fn cache_stats() -> BridgeCacheStats {
    read()
}

/// Resize the cache, returning what it holds afterwards.
///
/// Shrinking evicts oldest-first straight away rather than waiting for the next
/// render, so the memory the user just asked to reclaim is actually gone when
/// the number on screen changes.
#[frb(sync)]
pub fn set_cache_budget(bytes: u64) -> BridgeCacheStats {
    let (used, budget, entries, hits, misses) =
        crate::framecache::set_budget(usize::try_from(bytes).unwrap_or(usize::MAX));
    BridgeCacheStats {
        used_bytes: used as u64,
        budget_bytes: budget as u64,
        entries: entries as u64,
        hits,
        misses,
    }
}

/// Empty the cache. Every frame is re-rendered from here on, so this is a
/// deliberate act rather than something to do on a timer.
#[frb(sync)]
pub fn clear_cache() -> BridgeCacheStats {
    let (used, budget, entries, hits, misses) = crate::framecache::clear();
    BridgeCacheStats {
        used_bytes: used as u64,
        budget_bytes: budget as u64,
        entries: entries as u64,
        hits,
        misses,
    }
}

impl crate::api::composition::CompositionReference {
    /// Which frames of this composition are held in the cache, one byte each:
    /// `0` nothing, `1` held only at a coarser resolution than `scale`, `2` held
    /// at `scale` or finer and ready to show now.
    ///
    /// This is what the Timeline's cache bar draws (docs/07-UI-SPEC.md §3.2,
    /// docs/06-RENDER-PIPELINE.md §5.6). It is a snapshot, not a subscription:
    /// the caller redraws when it has reason to, rather than the cache pushing.
    ///
    /// Only the RAM tier exists in this engine — there is no disk or VRAM frame
    /// cache yet — so the "on disk only" state the design language reserves blue
    /// for cannot occur, and is not reported.
    #[frb(sync)]
    pub fn cached_frames(&self, frames: u64, scale: f32) -> Vec<u8> {
        // A composition long enough to make this walk expensive is not a
        // composition anyone can see the whole of at once; the bar is drawn a
        // few pixels per frame at most.
        crate::framecache::cached_tiers(self.id, frames, scale)
    }
}
