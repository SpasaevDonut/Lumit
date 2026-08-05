//! Whether the render worker is measuring what each frame costs (docs/13 §7.1).
//!
//! # In plain terms
//!
//! The render-time indicators — the Timeline's column, the numbers on the
//! effect rows — are only worth their cost while something is showing them.
//! Measuring a frame makes the processor wait for the graphics card at every
//! layer and every effect (see `lumit_render::profile`), which is exactly the
//! overlap a fast preview depends on. So the frontend says when it wants the
//! numbers, and the worker reads that wish before each frame.
//!
//! One flag, one atomic: it is written from Dart's thread and read on the
//! render thread, and neither may wait for the other — the same shape the cache
//! budgets take (see [`crate::framecache`]).

use std::sync::atomic::{AtomicBool, Ordering};

/// The wish, off until something asks. Relaxed ordering throughout: this
/// decides whether the *next* frame is measured, and a frame either side of the
/// change is a correct answer to a question about a moving picture.
static WANTED: AtomicBool = AtomicBool::new(false);

/// Ask for (or stop asking for) per-layer and per-effect timings.
pub(crate) fn set_wanted(on: bool) {
    WANTED.store(on, Ordering::Relaxed);
}

/// Whether the next frame should be measured.
pub(crate) fn wanted() -> bool {
    WANTED.load(Ordering::Relaxed)
}
