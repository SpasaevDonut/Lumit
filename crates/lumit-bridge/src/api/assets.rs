//! Editing what a layer is *made of*, as opposed to where it sits.
//!
//! # In plain terms
//!
//! A solid, a text layer and a camera each have content of their own: a colour
//! and a size, some words, a zoom. Moving or fading such a layer is a transform
//! edit and lives elsewhere; changing what it *says* or what colour it *is*
//! lives here.
//!
//! One asymmetry is worth knowing because it surprises people. Editing a solid
//! changes an **asset** in the Project panel, so every layer using that solid
//! changes with it — that is the point of solids being assets rather than
//! per-layer settings. Editing a text layer changes only that layer.

use flutter_rust_bridge::frb;

use crate::api::{effect::BridgeScalar, layer::LayerReference, solid::SolidReference, BridgeError};

/// A colour as the document stores it: scene-linear RGBA, which may exceed 1
/// (an HDR tint) or dip below 0 (a lift), so it is not a byte triple.
#[frb(non_opaque)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct BridgeColourRgba {
    pub r: f64,
    pub g: f64,
    pub b: f64,
    pub a: f64,
}

/// A text layer's document (v1: one styled run — docs/03 §9.1).
#[frb(non_opaque)]
#[derive(Debug, Clone, PartialEq)]
pub struct BridgeTextDocument {
    pub text: String,
    /// Pixel size at natural scale.
    pub size: f64,
    pub fill: BridgeColourRgba,
}

/// A solid asset's definition.
#[frb(non_opaque)]
#[derive(Debug, Clone, PartialEq)]
pub struct BridgeSolidDef {
    pub name: String,
    pub colour: BridgeColourRgba,
    pub width: u32,
    pub height: u32,
}

impl LayerReference {
    /// This layer's text document, or `None` when it is not a text layer.
    #[frb(sync)]
    pub fn get_text(&self) -> Result<Option<BridgeTextDocument>, BridgeError> {
        let lumit_core::model::LayerKind::Text { document } = self.item()?.kind else {
            return Ok(None);
        };
        Ok(Some(BridgeTextDocument {
            text: document.text,
            size: document.size,
            fill: colour_of(document.fill),
        }))
    }

    /// Replace a text layer's document — one op, exactly invertible.
    ///
    /// The whole document rather than a field at a time, for the same reason
    /// every other edit here takes a whole value: retyping a word and changing
    /// its size is one action to the user and should be one undo step.
    #[frb(sync)]
    pub fn set_text(&self, document: BridgeTextDocument) -> Result<(), BridgeError> {
        let lumit_core::model::LayerKind::Text { .. } = self.item()?.kind else {
            return Err(BridgeError::NotText);
        };
        self.commit(lumit_core::Op::SetTextDocument {
            comp: self.comp_id,
            layer: self.layer_id,
            document: lumit_core::model::TextDocument {
                text: document.text,
                size: document.size,
                fill: linear_of(document.fill),
                extra: serde_json::Map::new(),
            },
        })
    }

    /// A camera layer's zoom — focal distance in comp pixels, the After Effects
    /// model where the z=0 plane maps 1:1. `None` on any other kind.
    #[frb(sync)]
    pub fn get_camera_zoom(&self) -> Result<Option<BridgeScalar>, BridgeError> {
        let layer = self.item()?;
        let lumit_core::model::LayerKind::Camera { zoom } = layer.kind else {
            return Ok(None);
        };
        // Keys on the composition's clock, like every other channel (K-213).
        Ok(Some(BridgeScalar::read_at(&zoom, layer.start_offset.0)))
    }

    /// Set a camera's zoom. Animatable, so it takes a whole `BridgeScalar` like
    /// every other curve-capable value.
    #[frb(sync)]
    pub fn set_camera_zoom(&self, zoom: BridgeScalar) -> Result<(), BridgeError> {
        let layer = self.item()?;
        let lumit_core::model::LayerKind::Camera { .. } = layer.kind else {
            return Err(BridgeError::NotCamera);
        };
        let animation = zoom.animation_at(layer.start_offset.0)?;
        self.commit(lumit_core::Op::SetCameraZoom {
            comp: self.comp_id,
            layer: self.layer_id,
            animation,
        })
    }
}

impl SolidReference {
    /// This solid asset's definition.
    #[frb(sync)]
    pub fn get_definition(&self) -> Result<BridgeSolidDef, BridgeError> {
        let solid = self.definition()?;
        Ok(BridgeSolidDef {
            name: solid.name,
            colour: colour_of(solid.colour),
            width: solid.width,
            height: solid.height,
        })
    }

    /// Edit the solid. **Every layer using it changes**, because a solid is an
    /// asset in the Project panel rather than a per-layer setting — which is
    /// what makes "recolour every background at once" one edit.
    #[frb(sync)]
    pub fn set_definition(&self, definition: BridgeSolidDef) -> Result<(), BridgeError> {
        if definition.name.trim().is_empty() {
            return Err(BridgeError::EmptyName);
        }
        self.definition()?;
        self.commit(lumit_core::Op::SetSolidDef {
            def: self.id(),
            name: definition.name,
            colour: linear_of(definition.colour),
            // A solid with no area is not a picture; the op would take it, but
            // nothing would ever draw.
            width: definition.width.max(1),
            height: definition.height.max(1),
        })
    }
}

#[frb(ignore)]
pub(crate) fn colour_of(c: lumit_core::model::LinearColour) -> BridgeColourRgba {
    BridgeColourRgba {
        r: f64::from(c.0[0]),
        g: f64::from(c.0[1]),
        b: f64::from(c.0[2]),
        a: f64::from(c.0[3]),
    }
}

#[frb(ignore)]
pub(crate) fn linear_of(c: BridgeColourRgba) -> lumit_core::model::LinearColour {
    lumit_core::model::LinearColour([c.r as f32, c.g as f32, c.b as f32, c.a as f32])
}
