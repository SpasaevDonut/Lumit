use std::sync::Arc;

use flutter_rust_bridge::frb;
use lumit_core::model::ProjectItem;
use uuid::Uuid;

use crate::api::{
    BridgeError, composition::CompositionReference, folder::FolderReference, footage::FootageReference, project_item::ItemReference, solid::SolidReference, state::{PROJECTS, WorkerResponseStream}, worker_thread,
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
    pub fn state(&self) -> Arc<std::sync::RwLock<super::state::LumitBridgeState>> {
        let projects = PROJECTS.read().unwrap();
        let project = projects.get(&self.id);

        project.unwrap().clone()
    }

    #[frb(sync)]
    pub fn start_worker(&self, on_reponse: WorkerResponseStream) {
        worker_thread::run_worker(self.clone(), on_reponse);
    }

    #[frb(sync)]
    pub fn get_items(&self) -> Vec<ItemReference> {
        let s = self.state();
        let s = s.read().unwrap();

        let snapshot = s.store.snapshot();

        snapshot
            .items
            .iter()
            .map(|i| match i {
                ProjectItem::Composition(_) => {
                    ItemReference::Composition(CompositionReference::new(self.id.clone(), i.id()))
                }
                ProjectItem::Folder(_) => {
                    ItemReference::Folder(FolderReference::new(self.id.clone(), i.id()))
                }
                ProjectItem::Solid(_) => {
                    ItemReference::Solid(SolidReference::new(self.id.clone(), i.id()))
                }
                ProjectItem::Footage(_) => {
                    ItemReference::Footage(FootageReference::new(self.id.clone(), i.id()))
                }
            })
            .collect()
    }

    #[frb(sync)]
    pub fn undo(&self) -> Result<(), BridgeError> {
        let s = self.state();
        let s = s.read().unwrap();

        s.store.undo().map_err(|e| BridgeError::OpError(e))?;

        Ok(())
    }

    #[frb(sync)]
    pub fn redo(&self) -> Result<(), BridgeError> {
        let s = self.state();
        let s = s.read().unwrap();

        s.store.redo().map_err(|e| BridgeError::OpError(e))?;

        Ok(())
    }
}
