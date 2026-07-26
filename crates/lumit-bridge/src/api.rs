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
    /// The parameter exists but is of a kind this API cannot yet express (see
    /// `BridgeEffectInstance::get_value`).
    UnsupportedParamKind,
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
            BridgeError::UnsupportedParamKind => {
                write!(f, "That effect parameter is not a scalar")
            }
            BridgeError::WriteFailed => write!(f, "Write Failed"),
            BridgeError::InvalidWorkerState => write!(f, "Invalid worker state"),
            BridgeError::OpError(op_error) => write!(f, "{}", op_error),
        };

        Ok(())
    }
}
