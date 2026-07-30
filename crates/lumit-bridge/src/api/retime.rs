//! Playing a footage layer faster, slower or backwards.
//!
//! # In plain terms
//!
//! Retiming maps a layer's own timeline onto its source's: at half speed, one
//! second of layer time reads half a second of the file. The engine's model is a
//! curve — segments with eased speed, or an explicit source-time map — so that
//! ramps and freezes are exact rather than approximated (docs/04-RETIMING.md).
//!
//! **This surface is the flat part of that model on purpose.** It reads and
//! writes a *constant* speed for the whole layer, plus the reverse gate and the
//! frame-interpolation policy. Those are the controls a row can honestly offer;
//! ramps need the Retime graph to draw and edit, and an API that let a caller
//! set "the speed" of a curve that varies would have to silently discard the
//! curve. So a layer whose retime is not one constant segment reports
//! [`BridgeRetime::varies`] and refuses a speed write rather than flattening it
//! — the same rule the keyframe rows follow.

use flutter_rust_bridge::frb;
use lumit_core::retime::{Interpolation, Retime, RetimeSegment};
use lumit_core::time::Rational;

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

/// A layer's retiming, as a row can show it.
#[frb(non_opaque)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct BridgeRetime {
    /// Percent: 100 is source rate, 50 is half speed, 0 is a freeze.
    pub speed_percent: f64,
    /// True when the curve is *not* one constant segment — a ramp or an
    /// explicit map. `speed_percent` is then the average across the layer and
    /// writing a speed is refused, because it would discard the shape.
    pub varies: bool,
    /// While off, evaluation clamps speed at zero so the curve never runs
    /// backwards (docs/04 §6.2).
    pub allow_reverse: bool,
    pub interpolation: BridgeRetimeInterp,
}

impl LayerReference {
    /// This layer's retiming, or `None` when it plays at source rate (or is not
    /// a footage layer at all).
    #[frb(sync)]
    pub fn get_retime(&self) -> Result<Option<BridgeRetime>, BridgeError> {
        let lumit_core::model::LayerKind::Footage { retime, .. } = self.item()?.kind else {
            return Ok(None);
        };
        let Some(retime) = retime else {
            return Ok(None);
        };
        Ok(Some(read(&retime)))
    }

    /// Turn retiming on or off.
    ///
    /// On installs the identity map — the same length, playing at source rate —
    /// so switching it on changes nothing visible and gives the row something to
    /// edit. Off removes the map entirely rather than setting 100%, because
    /// "not retimed" and "retimed to exactly 1×" are different states in the
    /// file and only the first skips the resampler.
    ///
    /// Off also re-hangs the layer on its source, exactly as the Retime property
    /// does (K-211): it keeps its in point and the frame showing there, then
    /// plays at source rate until the source runs out or its own out point
    /// arrives, whichever comes first. It never grows. One undo step covers both.
    #[frb(sync)]
    pub fn set_retime_enabled(&self, on: bool) -> Result<(), BridgeError> {
        let layer = self.item()?;
        let lumit_core::model::LayerKind::Footage { .. } = layer.kind else {
            return Err(BridgeError::NotFootage);
        };

        let retime = on.then(|| {
            let duration = layer
                .out_point
                .0
                .checked_sub(layer.in_point.0)
                .unwrap_or(layer.out_point.0);
            Retime::identity(duration, Rational::ZERO)
        });
        let removal = lumit_core::Op::SetLayerRetime {
            comp: self.comp_id,
            layer: self.layer_id,
            retime,
        };
        // Off re-hangs the layer on its source, exactly as the Retime property
        // does (K-211): both routes make the same promise, so they let go of it
        // the same way.
        self.commit(if on {
            removal
        } else {
            self.unretime_op(&layer, removal)
        })
    }

    /// Set one constant speed for the whole layer.
    ///
    /// Refused on a layer whose curve varies — see the module note. A speed of
    /// zero is a freeze, which is legal and useful; a negative one needs the
    /// reverse gate open, which the engine enforces at evaluation.
    #[frb(sync)]
    pub fn set_retime_speed(&self, percent: f64) -> Result<(), BridgeError> {
        let layer = self.item()?;
        let lumit_core::model::LayerKind::Footage { retime, .. } = &layer.kind else {
            return Err(BridgeError::NotFootage);
        };
        let Some(existing) = retime.as_ref() else {
            return Err(BridgeError::NotRetimed);
        };
        if segments_vary(existing) {
            return Err(BridgeError::RetimeVaries);
        }

        let duration = existing
            .boundaries
            .last()
            .map(|b| b.t)
            .unwrap_or(Rational::ZERO);
        let source_in = existing
            .boundaries
            .first()
            .map(|b| b.s)
            .unwrap_or(Rational::ZERO);
        let speed = Rational::from_f64_on_grid(percent / 100.0, Rational::FLICK_DEN)
            .map_err(|_| BridgeError::InvalidTime)?;

        let mut next = Retime::constant_speed(duration, source_in, speed);
        // The gate and the policy are the user's settings, not consequences of
        // the speed — a speed edit must not silently re-lock reverse.
        next.allow_reverse = existing.allow_reverse;
        next.interpolation = existing.interpolation.clone();

        self.commit(lumit_core::Op::SetLayerRetime {
            comp: self.comp_id,
            layer: self.layer_id,
            retime: Some(next),
        })
    }

    /// Open or close the reverse gate.
    #[frb(sync)]
    pub fn set_retime_reverse(&self, allow: bool) -> Result<(), BridgeError> {
        self.with_retime(|retime| {
            retime.allow_reverse = allow;
            Ok(())
        })
    }

    /// Choose how in-between frames are found.
    #[frb(sync)]
    pub fn set_retime_interpolation(
        &self,
        interpolation: BridgeRetimeInterp,
    ) -> Result<(), BridgeError> {
        self.with_retime(|retime| {
            retime.interpolation = match interpolation {
                BridgeRetimeInterp::Nearest => Interpolation::Nearest,
                BridgeRetimeInterp::Blend => Interpolation::Blend,
                BridgeRetimeInterp::Flow => Interpolation::Flow(Default::default()),
            };
            Ok(())
        })
    }

    /// Read this layer's retime, let `edit` change a clone, and commit it.
    #[frb(ignore)]
    fn with_retime(
        &self,
        edit: impl FnOnce(&mut Retime) -> Result<(), BridgeError>,
    ) -> Result<(), BridgeError> {
        let layer = self.item()?;
        let lumit_core::model::LayerKind::Footage { retime, .. } = &layer.kind else {
            return Err(BridgeError::NotFootage);
        };
        let mut next = retime.clone().ok_or(BridgeError::NotRetimed)?;
        edit(&mut next)?;
        self.commit(lumit_core::Op::SetLayerRetime {
            comp: self.comp_id,
            layer: self.layer_id,
            retime: Some(next),
        })
    }
}

/// Whether this curve is anything other than one constant-speed segment.
#[frb(ignore)]
fn segments_vary(retime: &Retime) -> bool {
    match retime.segments.as_slice() {
        [RetimeSegment::Rate(rate)] => rate.v0 != rate.v1,
        // No segments at all is degenerate rather than varying; anything else —
        // several segments, or a value-native map — is a shape to preserve.
        [] => false,
        _ => true,
    }
}

#[frb(ignore)]
fn read(retime: &Retime) -> BridgeRetime {
    // The average speed across the layer: source travelled over time taken.
    // For the constant case that is exactly the speed; for a ramp it is the
    // honest summary a row can show beside "varies".
    let span = retime
        .boundaries
        .last()
        .map(|b| b.t)
        .unwrap_or(Rational::ZERO);
    let source = match (retime.boundaries.first(), retime.boundaries.last()) {
        (Some(first), Some(last)) => last.s.checked_sub(first.s).unwrap_or(Rational::ZERO),
        _ => Rational::ZERO,
    };
    let speed_percent = if span.to_f64() <= 0.0 {
        100.0
    } else {
        source.to_f64() / span.to_f64() * 100.0
    };

    BridgeRetime {
        speed_percent,
        varies: segments_vary(retime),
        allow_reverse: retime.allow_reverse,
        interpolation: match retime.interpolation {
            Interpolation::Nearest => BridgeRetimeInterp::Nearest,
            Interpolation::Blend => BridgeRetimeInterp::Blend,
            Interpolation::Flow(_) => BridgeRetimeInterp::Flow,
        },
    }
}
