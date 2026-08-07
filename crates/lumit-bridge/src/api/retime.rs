//! How a layer's in-between frames are made.
//!
//! # In plain terms
//!
//! When a layer asks for a moment of its source that falls between two real
//! frames — which is what retiming does constantly, and what any mismatch of
//! rates does anyway — something has to decide which pixels to show. Nearest
//! shows the closer of the two frames, blend crossfades them, flow synthesises
//! a new one. That is all this file is (docs/04-RETIMING.md §10).
//!
//! **Retiming itself is not here.** The map from a layer's own clock to its
//! source's is the layer's `retime` property — an ordinary keyframable property
//! edited in the graph editor (K-197), reached through `layer.rs`. This file
//! used to hold a second, rival retime store with its own constant-speed,
//! reverse-gate and enable controls; K-249 deleted it, leaving the one thing
//! that was never part of the map to begin with. §10 is explicit that the
//! policy and the map are orthogonal, and now the code says so too.

use flutter_rust_bridge::frb;
use lumit_core::retime::Interpolation;

use crate::api::{layer::LayerReference, BridgeError};

/// How a source frame is chosen when the map lands between two (docs/04 §10).
#[frb(non_opaque)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BridgeRetimeInterp {
    /// Round to the nearest source frame — crisp and deterministic.
    Nearest,
    /// Crossfade the two neighbours.
    Blend,
    /// Optical-flow synthesis. The flow engine is future work; the policy
    /// round-trips today so a project set to it is not silently downgraded.
    Flow,
}

impl LayerReference {
    /// How this layer's in-between frames are made.
    ///
    /// Every layer has an answer, retimed or not: a layer whose source runs at
    /// a different rate from its comp is already being asked for frames between
    /// the ones it has.
    #[frb(sync)]
    pub fn get_interpolation(&self) -> Result<BridgeRetimeInterp, BridgeError> {
        Ok(match self.item()?.interpolation {
            Interpolation::Nearest => BridgeRetimeInterp::Nearest,
            Interpolation::Blend => BridgeRetimeInterp::Blend,
            Interpolation::Flow(_) => BridgeRetimeInterp::Flow,
        })
    }

    /// Choose how in-between frames are found. One undo step.
    #[frb(sync)]
    pub fn set_interpolation(&self, interpolation: BridgeRetimeInterp) -> Result<(), BridgeError> {
        self.commit(lumit_core::Op::SetLayerInterpolation {
            comp: self.comp_id,
            layer: self.layer_id,
            interpolation: match interpolation {
                BridgeRetimeInterp::Nearest => Interpolation::Nearest,
                BridgeRetimeInterp::Blend => Interpolation::Blend,
                BridgeRetimeInterp::Flow => Interpolation::Flow(Default::default()),
            },
        })
    }
}
