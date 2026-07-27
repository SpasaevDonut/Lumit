//! The playback scheduler's pure decisions (docs/impl/playback-scheduler.md §5).
//!
//! # In plain terms
//!
//! During playback the worker no longer renders one frame and shows it in the
//! same breath. It renders AHEAD of the clock into a small ring of finished
//! frames, and shows each one only when it is due. The point is slack: a span
//! of cheap (or cached) frames fills the ring, and when an expensive frame
//! comes along it can spend the banked time instead of stalling the picture.
//! How far ahead to render is not guessed — it adapts to what frames have
//! actually been costing, measured as they happen.
//!
//! This module holds the arithmetic of those decisions — the cost window and
//! the lookahead formula — kept free of the GPU and the worker loop so they
//! are testable on their own. The ring itself lives with the worker's
//! `Playback` state; its entries are `lumit_render::PreparedFrame`s.

use std::collections::VecDeque;

/// How many recent render costs the p95 is taken over. Small on purpose: the
/// lookahead should follow the comp the playhead is in NOW, not the average of
/// the whole session.
const COST_WINDOW: usize = 32;

/// How many frames past the one being rendered have their source decodes
/// posted to the decode-ahead thread. Enough to keep that thread busy through
/// one composite; more would just fill the decoded-frame cache further ahead
/// than the ring ever presents.
pub(crate) const PREFETCH_AHEAD: u64 = 4;

/// The measured cost of recent renders, for the scheduler's lookahead.
///
/// The impl note asks for the 95th percentile rather than the mean: lookahead
/// exists to absorb the OCCASIONAL slow frame, so it must be sized by what the
/// slow frames cost, not by the typical one.
#[derive(Default)]
pub(crate) struct CostWindow {
    samples: VecDeque<f64>,
}

impl CostWindow {
    /// Record one render's measured cost in seconds.
    pub(crate) fn push(&mut self, cost_secs: f64) {
        if !cost_secs.is_finite() || cost_secs < 0.0 {
            return;
        }
        if self.samples.len() == COST_WINDOW {
            self.samples.pop_front();
        }
        self.samples.push_back(cost_secs);
    }

    /// The 95th-percentile cost over the window, or `None` before any sample —
    /// a fresh run has nothing to size its lookahead by yet.
    pub(crate) fn p95(&self) -> Option<f64> {
        if self.samples.is_empty() {
            return None;
        }
        let mut sorted: Vec<f64> = self.samples.iter().copied().collect();
        sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        // Nearest-rank p95: the value 95% of samples sit at or below.
        let rank = ((sorted.len() as f64) * 0.95).ceil() as usize;
        Some(sorted[rank.saturating_sub(1).min(sorted.len() - 1)])
    }
}

/// How many frames ahead of the clock the scheduler renders — the ring
/// capacity. The impl note's formula, pinned: `clamp(2 × p95 cost × fps, 8,
/// 16)`. Before any cost has been measured the floor applies.
///
/// The floor is also the VRAM ceiling to know about: at worst 16 display
/// textures are held at once (~8 MB each at full 1080p, less at any preview
/// scale), freed the moment they are presented or playback stops.
pub(crate) fn lookahead_frames(p95_cost: Option<f64>, fps: f64) -> usize {
    let frames = match p95_cost {
        Some(cost) if fps > 0.0 => (2.0 * cost * fps).ceil() as usize,
        _ => 0,
    };
    frames.clamp(8, 16)
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    /// The window sizes lookahead by the recurring SLOW frames, which are what
    /// the ring exists to absorb — a mean would let a spike every half-second
    /// vanish into thirty cheap frames. (A single once-off outlier is excluded
    /// by design: that is what the 95th percentile is, as against a max.)
    #[test]
    fn the_cost_window_reports_the_slow_tail_not_the_mean() {
        let mut w = CostWindow::default();
        assert_eq!(w.p95(), None, "no verdict before any sample");
        for _ in 0..30 {
            w.push(0.005);
        }
        w.push(0.050);
        w.push(0.050);
        let p95 = w.p95().unwrap();
        assert!(p95 >= 0.049, "the slow tail is what p95 reports, got {p95}");
        // Nonsense samples are ignored, never poison the window.
        w.push(f64::NAN);
        w.push(-1.0);
        assert!(w.p95().unwrap().is_finite());
    }

    /// The window is a window: old costs age out, so the lookahead follows the
    /// comp the playhead is in now.
    #[test]
    fn old_costs_age_out_of_the_window() {
        let mut w = CostWindow::default();
        w.push(1.0); // One ancient, terrible frame.
        for _ in 0..COST_WINDOW {
            w.push(0.004);
        }
        assert!(
            w.p95().unwrap() < 0.005,
            "a cost older than the window must not size the ring for ever"
        );
    }

    /// The impl note's clamp, pinned: never fewer than 8 frames of lookahead
    /// (cheap comps still bank slack), never more than 16 (bounded VRAM), and
    /// in between it scales with what frames cost.
    #[test]
    fn lookahead_follows_the_pinned_clamp() {
        // Fresh run, nothing measured: the floor.
        assert_eq!(lookahead_frames(None, 60.0), 8);
        // Cheap frames: still the floor.
        assert_eq!(lookahead_frames(Some(0.002), 60.0), 8);
        // Costly frames: 2 × 0.1 s × 60 fps = 12 frames.
        assert_eq!(lookahead_frames(Some(0.1), 60.0), 12);
        // Hopeless frames: capped.
        assert_eq!(lookahead_frames(Some(1.0), 60.0), 16);
        // A degenerate rate never panics or explodes the ring.
        assert_eq!(lookahead_frames(Some(0.1), 0.0), 8);
    }
}
