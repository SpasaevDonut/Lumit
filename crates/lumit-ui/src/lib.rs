//! Lumit's UI shell (egui). Engine crates must never depend on this crate —
//! the dependency arrow points the other way (docs/05-ARCHITECTURE.md).
//!
//! The pixel pass this shell used to own — decode planning, the decode worker,
//! draw building, GPU compositing, the frame caches, export and the headless
//! seam — now lives in `lumit-render` (K-178), where the Flutter frontend
//! reaches it too. What is left here is the interface: panels, the dock, the
//! theme, and the egui-side of showing a finished frame.

pub mod app_state;
pub mod icons;
pub mod native_menu;
pub mod shell;
pub mod splash;
pub mod theme;

pub use shell::Shell;
pub use theme::Theme;
