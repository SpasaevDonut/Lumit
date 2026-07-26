use std::sync::Arc;

use flutter_rust_bridge::frb;
use lumit_core::model::ProjectItem;
use uuid::Uuid;

use crate::api::{
    composition::CompositionReference,
    folder::FolderReference,
    footage::FootageReference,
    project_item::ItemReference,
    solid::SolidReference,
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

        Ok(snapshot
            .items
            .iter()
            .map(|i| match i {
                ProjectItem::Composition(_) => {
                    ItemReference::Composition(CompositionReference::new(self.id, i.id()))
                }
                ProjectItem::Folder(_) => {
                    ItemReference::Folder(FolderReference::new(self.id, i.id()))
                }
                ProjectItem::Solid(_) => ItemReference::Solid(SolidReference::new(self.id, i.id())),
                ProjectItem::Footage(_) => {
                    ItemReference::Footage(FootageReference::new(self.id, i.id()))
                }
            })
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
