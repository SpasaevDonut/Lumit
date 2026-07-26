use std::sync::Arc;

use flutter_rust_bridge::frb;
use uuid::Uuid;

use crate::api::{
    project_item::{item_reference, ItemReference},
    state::{WorkerResponseStream, PROJECTS},
    worker_thread, BridgeError,
};

#[derive(Debug, Clone)]
#[frb]
pub struct ProjectReference {
    #[frb(name = "internalid")]
    pub id: Uuid,
}

impl ProjectReference {
    #[frb(ignore)]
    pub fn new(id: Uuid) -> ProjectReference {
        ProjectReference { id }
    }

    #[frb(ignore)]
    pub fn state(
        &self,
    ) -> Result<Arc<std::sync::RwLock<super::state::LumitBridgeState>>, BridgeError> {
        let projects = PROJECTS.read().map_err(|_| BridgeError::ReadFailed)?;
        let project = projects.get(&self.id).ok_or(BridgeError::InvalidProject)?;

        Ok(project.clone())
    }

    #[frb(sync)]
    pub fn start_worker(&self, on_reponse: WorkerResponseStream) {
        worker_thread::run_worker(self.clone(), on_reponse);
    }

    #[frb(sync)]
    pub fn get_items(&self) -> Result<Vec<ItemReference>, BridgeError> {
        let s = self.state()?;
        let s = s.read().map_err(|_| BridgeError::ReadFailed)?;

        let snapshot = s.store.snapshot();

        // The panel's roots. Nesting is walked by `FolderReference::get_children`,
        // so a collapsed folder costs nothing.
        Ok(snapshot
            .items
            .iter()
            .map(|i| item_reference(self.id, i))
            .collect())
    }

    #[frb(sync)]
    pub fn undo(&self) -> Result<(), BridgeError> {
        let s = self.state()?;
        let s = s.read().map_err(|_| BridgeError::ReadFailed)?;

        s.store.undo().map_err(BridgeError::OpError)?;

        Ok(())
    }

    #[frb(sync)]
    pub fn redo(&self) -> Result<(), BridgeError> {
        let s = self.state()?;
        let s = s.read().map_err(|_| BridgeError::ReadFailed)?;

        s.store.redo().map_err(BridgeError::OpError)?;

        Ok(())
    }
}
