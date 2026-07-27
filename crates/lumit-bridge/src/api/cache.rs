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
    /// The answer merges the RAM tier and the VRAM tier (the worker's
    /// final-frame textures, as last published) — a frame on the card plays
    /// without rendering, so it is as green as one in RAM. There is no disk
    /// tier yet, so the "on disk only" state the design language reserves
    /// blue for cannot occur, and is not reported.
    #[frb(sync)]
    pub fn cached_frames(&self, frames: u64, scale: f32) -> Vec<u8> {
        // A composition long enough to make this walk expensive is not a
        // composition anyone can see the whole of at once; the bar is drawn a
        // few pixels per frame at most.
        crate::framecache::cached_tiers(self.id, frames, scale)
    }
}

/// What the VRAM final-frame cache holds — the tier that makes a revisited
/// frame free on the zero-copy Viewer ("cache on the card", docs/06 §5.1).
#[frb(non_opaque)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BridgeVramCacheStats {
    pub used_bytes: u64,
    pub budget_bytes: u64,
    pub entries: u64,
}

/// The VRAM cache's live numbers. `used`/`entries` are as the worker last
/// published (it holds the textures; nothing here touches the GPU); the
/// budget is the asked-for value, applied on the worker's next turn.
#[frb(sync)]
pub fn vram_cache_stats() -> BridgeVramCacheStats {
    let (used, _, entries) = crate::framecache::vram::stats();
    BridgeVramCacheStats {
        used_bytes: used,
        budget_bytes: crate::framecache::vram::budget() as u64,
        entries,
    }
}

/// Resize the VRAM cache. The worker applies it on its next turn, evicting
/// down immediately then; the returned stats show the new budget with the
/// holdings as last published.
#[frb(sync)]
pub fn set_vram_cache_budget(bytes: u64) -> BridgeVramCacheStats {
    crate::framecache::vram::set_budget(usize::try_from(bytes).unwrap_or(usize::MAX));
    vram_cache_stats()
}

/// Empty the VRAM cache on the worker's next turn.
#[frb(sync)]
pub fn clear_vram_cache() -> BridgeVramCacheStats {
    crate::framecache::vram::request_clear();
    vram_cache_stats()
}

/// Which route a rendered frame takes from the engine to the Viewer.
///
/// Worth reporting rather than assuming: the zero-copy paths are build features,
/// and a build without one silently falls back. That fallback is four trips for
/// a picture that never needed to leave the graphics card — composite, copy down
/// to ordinary memory, serialise a byte at a time across the boundary, upload
/// back to the card to draw — so "which one am I on?" is the first question to
/// ask when playback feels heavy, and it should not need a rebuild to answer.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum BridgeViewerTransport {
    /// Windows: a D3D12 texture shared by handle. No pixels cross.
    SharedTexture,
    /// Linux: a DMA-BUF shared by file descriptor. No pixels cross.
    DmaBuf,
    /// Every pixel copied down, serialised, and uploaded again.
    ReadBack,
}

/// What this build compiles to. It reports the *build*, not the run — a machine
/// that cannot provide a shared texture still falls back at runtime.
#[frb(sync)]
pub fn viewer_transport() -> BridgeViewerTransport {
    #[cfg(all(windows, feature = "shared-texture"))]
    {
        BridgeViewerTransport::SharedTexture
    }
    #[cfg(all(target_os = "linux", feature = "shared-texture-linux"))]
    {
        BridgeViewerTransport::DmaBuf
    }
    #[cfg(not(any(
        all(windows, feature = "shared-texture"),
        all(target_os = "linux", feature = "shared-texture-linux")
    )))]
    {
        BridgeViewerTransport::ReadBack
    }
}
