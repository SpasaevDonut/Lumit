use std::{error::Error, fmt};

use lumit_core::OpError;

pub mod composition;
pub mod effect;
pub mod folder;
pub mod footage;
pub mod layer;
pub mod project;
pub mod project_item;
pub mod solid;
pub mod state;

mod worker_thread;

#[cfg(test)]
mod tests;

#[derive(Debug)]
pub enum BridgeError {
    InvalidProject,
    InvalidComp,
    InvalidItem,
    InvalidLayer,
    /// A media path could not be resolved, or a relink found nothing to point at.
    MediaPathUnresolved,
    /// A frame rate of zero, or one whose frame count cannot be expressed.
    InvalidFrameRate,
    /// Save was asked to write a project that has never been saved, without being
    /// told where. The caller has to pick a path.
    NoProjectPath,
    /// A rename was given a blank name. Refused rather than applied, so a row
    /// cannot lose its label.
    EmptyName,
    /// No parameter of that id on the effect.
    InvalidParam,
    /// No effect of that id in the layer's stack — a reference that outlived the
    /// effect it named.
    InvalidEffect,
    /// No built-in effect goes by that match name.
    UnknownEffectName,
    /// The value written to a parameter is of a different kind from the
    /// parameter. A parameter's kind is the effect's schema to declare, not the
    /// panel's to change, so this is refused rather than applied.
    ParamKindMismatch,
    /// A keyframed value whose keys are not a curve the engine can evaluate:
    /// none at all, an invalid time, or times that do not strictly ascend.
    InvalidKeyframes,
    /// A time whose denominator is zero or negative — a span or marker built
    /// wrongly by the caller. Refused rather than normalised: quietly fixing it
    /// would put the thing somewhere nobody asked for.
    InvalidTime,
    /// A blend-mode index outside the list `list_blend_modes` hands out.
    InvalidBlendMode,
    /// A staged effect stack no longer matches the document's — something else
    /// added, removed or reordered an effect while it was being edited.
    StaleEffectStack,
    ReadFailed,
    WriteFailed,
    InvalidWorkerState,
    OpError(OpError),
}

impl Error for BridgeError {}

impl fmt::Display for BridgeError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        let _ = match &self {
            BridgeError::ReadFailed => write!(f, "Read Failed"),
            BridgeError::InvalidProject => write!(f, "Invalid ProjectItem"),
            BridgeError::InvalidComp => write!(f, "Invalid Comp"),
            BridgeError::InvalidItem => write!(f, "Invalid Item"),
            BridgeError::InvalidLayer => write!(f, "Invalid Layer"),
            BridgeError::EmptyName => write!(f, "The name cannot be empty"),
            BridgeError::InvalidFrameRate => write!(f, "Invalid frame rate"),
            BridgeError::NoProjectPath => {
                write!(
                    f,
                    "This project has never been saved, so a path is required"
                )
            }
            BridgeError::MediaPathUnresolved => write!(f, "Nothing to relink at that path"),
            BridgeError::InvalidParam => write!(f, "No such effect parameter"),
            BridgeError::InvalidEffect => write!(f, "No such effect on this layer"),
            BridgeError::UnknownEffectName => write!(f, "No built-in effect by that name"),
            BridgeError::ParamKindMismatch => {
                write!(f, "That value is the wrong kind for this effect parameter")
            }
            BridgeError::InvalidKeyframes => write!(
                f,
                "A keyframed value needs at least one key, in ascending time order"
            ),
            BridgeError::InvalidTime => write!(f, "That time is not a valid duration"),
            BridgeError::InvalidBlendMode => write!(f, "No blend mode at that index"),
            BridgeError::StaleEffectStack => {
                write!(f, "The effect stack changed while it was being edited")
            }
            BridgeError::WriteFailed => write!(f, "Write Failed"),
            BridgeError::InvalidWorkerState => write!(f, "Invalid worker state"),
            BridgeError::OpError(op_error) => write!(f, "{}", op_error),
        };

        Ok(())
    }
}
