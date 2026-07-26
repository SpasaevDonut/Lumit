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
