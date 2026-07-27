//! lumit-render: the pixel pass — everything between "here is the document"
//! and "here are the pixels".
//!
//! # In plain terms
//!
//! This crate is the part of Lumit that actually makes pictures. It is an
//! *engine* crate: it knows nothing about egui, Flutter, the bridge, or windows.
//! Both frontends drive it, which is the point — a comp must look the same in
//! the egui Viewer, in the Flutter Viewer, and in the exported file (K-031), and
//! the surest way to guarantee that is for there to be only one implementation.
//!
//! ## The five steps of a frame
//!
//! 1. **Probe** ([`source`]) — what is this footage file: is it there, how fast
//!    does it run, how many frames? Each frontend probes its own way and answers
//!    the one question this crate asks.
//! 2. **Plan** ([`plan`]) — walk the comp and write down which layer needs which
//!    frame of which file, at what width. Cheap, pure, opens nothing.
//! 3. **Decode** ([`decode`]) — a background worker turns that plan into actual
//!    pixels, keeping recently-decoded frames in a byte-budgeted cache so a
//!    scrub does not re-read the same frames off disk.
//! 4. **Build** ([`build`]) — turn the document plus those decoded pixels into a
//!    *draw list* ([`draw`]): a plain description of every layer's picture,
//!    placement, blend and resolved effects. Still no graphics card.
//! 5. **Realise** ([`realise`]) — walk the draw list on the GPU and produce the
//!    finished frame.
//!
//! ## Why the split matters
//!
//! Steps 4 and 5 are fast; step 3 is slow. Dragging an effect value changes
//! nothing about *which* pixels are needed — only what is done with them — so a
//! drag re-runs only steps 4 and 5 against pixels it already has. That is the
//! difference between a value slider that moves smoothly and one that stutters.
//! [`plan::same_decode`] is the test that licenses the shortcut.
//!
//! ## Where finished frames go
//!
//! [`cache`] gives every finished frame a name derived from its *content* — a
//! hash of everything that went into it — so scrubbing back to a frame finds it
//! already made, and an edit that cannot change the picture (a rename, say)
//! throws nothing away. Frames live in RAM, and [`diskio`] parks them in the
//! project's sidecar so they survive a restart.
//!
//! [`export`] and [`headless`] are the two entry points that drive all of the
//! above without a window: writing a file, and rendering single frames for a
//! frontend that draws them itself.

pub mod build;
pub mod cache;
pub mod decode;
pub mod diskio;
pub mod draw;
pub mod export;
pub mod fxops;
pub mod headless;
pub mod plan;
pub mod realise;
pub mod source;

pub use build::{
    below_draws_at, build_comp_draws, build_comp_draws_at, patch_layer_effect_param,
    patch_layer_prop, render_below_at,
};
pub use cache::{CacheTier, CachedCompFrame};
pub use decode::{CompFrame, CompJob, CompLayerPixels, PreviewEngine, PreviewResult};
pub use draw::{
    AccumulationBelow, CompLayerDraw, DofInputDraw, DrawSource, MatteDraw, TemporalBelow,
};
pub use headless::{HeadlessRenderer, PreparedFrame};
pub use plan::{plan_comp_frame, Quality, RetimeOverride};
pub use realise::Realiser;
pub use source::{SourceProbe, SourceProbes};
