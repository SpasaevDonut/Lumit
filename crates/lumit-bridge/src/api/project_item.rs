use std::sync::{Arc, RwLock};

use flutter_rust_bridge::frb;
use lumit_core::model::ProjectItem;

use crate::api::{
    composition::CompositionReference,
    folder::FolderReference,
    footage::FootageReference,
    solid::SolidReference,
    state::{LumitBridgeState, PROJECTS},
    BridgeError,
};

#[frb(non_opaque)]
#[derive(Debug, PartialEq, Eq)]
pub enum ItemReference {
    Footage(FootageReference),
    Solid(SolidReference),
    Composition(CompositionReference),
    Folder(FolderReference),
}

#[frb(name = "ItemInfo")]
#[frb(non_opaque)]
pub struct LumitProjectItemInfo {
    pub name: String,
}

impl ItemReference {
    #[frb(sync)]
    pub fn equals(&self, item: &ItemReference) -> bool {
        self == item
    }

    fn project(&self) -> Result<Arc<RwLock<LumitBridgeState>>, BridgeError> {
        let proj_id = match self {
            ItemReference::Footage(footage_reference) => footage_reference.project_id(),
            ItemReference::Solid(solid_reference) => solid_reference.project_id(),
            ItemReference::Composition(composition_reference) => composition_reference.project_id(),
            ItemReference::Folder(folder_reference) => folder_reference.project_id(),
        };

        let projects = PROJECTS.read().unwrap();
        let project = projects.get(&proj_id);

        Ok(project.unwrap().clone())
    }

    fn item(&self) -> Result<ProjectItem, BridgeError> {
        let proj = self.project()?;

        let item_id = match self {
            ItemReference::Footage(footage_reference) => footage_reference.id(),
            ItemReference::Solid(solid_reference) => solid_reference.id(),
            ItemReference::Composition(composition_reference) => composition_reference.id(),
            ItemReference::Folder(folder_reference) => folder_reference.id(),
        };

        let p = proj.read().map_err(|_| BridgeError::ReadFailed)?;
        let snapshot = p.store.snapshot();
        Ok(snapshot.item(item_id).unwrap().clone())
    }

    #[frb(sync)]
    pub fn name(&self) -> Result<String, BridgeError> {
        let item = self.item()?;

        Ok(item.name().to_string())
    }
}
