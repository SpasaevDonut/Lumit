
use std::{
    error::Error,
    fmt,
};

use lumit_core::OpError;

pub mod state;
pub mod project;
pub mod project_item;
pub mod composition;
pub mod layer;
pub mod folder;
pub mod solid;
pub mod footage;

#[derive(Debug)]
pub enum BridgeError {
    InvalidProject,
    InvalidComp,
    InvalidItem,
    InvalidLayer,
    ReadFailed,
    WriteFailed,
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
            BridgeError::WriteFailed => write!(f, "Write Failed"),
            BridgeError::OpError(op_error) => write!(f, "{}", op_error),
        };

        Ok(())
    }
}
