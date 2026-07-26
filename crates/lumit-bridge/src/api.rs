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

#[derive(Debug)]
pub enum BridgeError {
    InvalidProject,
    InvalidComp,
    InvalidItem,
    InvalidLayer,
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
