use std::{path::PathBuf, sync::Arc};

use lumit_core::model::FootageItem;
use uuid::Uuid;

use flutter_rust_bridge::frb;

use crate::api::{
    state::{LumitBridgeState, PROJECTS},
    BridgeError,
};

#[derive(Debug, PartialEq, Eq)]
#[frb]
pub struct FootageReference {
    #[frb(name = "internalproject")]
    pub project: Uuid,
    #[frb(name = "internalid")]
    pub id: Uuid,
}

pub enum LumitMediaStatus {
    Missing,
    Ready,
}

impl FootageReference {
    #[frb(ignore)]
    pub fn new(project: Uuid, id: Uuid) -> FootageReference {
        FootageReference { project, id }
    }

    #[frb(ignore)]
    pub fn project_id(&self) -> Uuid {
        self.project
    }

    #[frb(ignore)]
    pub fn id(&self) -> Uuid {
        self.id
    }

    #[frb(ignore)]
    fn project(&self) -> Result<Arc<std::sync::RwLock<LumitBridgeState>>, BridgeError> {
        let projects = PROJECTS.read().unwrap();
        let project = projects.get(&self.project);

        let p = project.ok_or(BridgeError::InvalidProject)?;
        Ok(p.clone())
    }

    // copy pasted from lumit-ui/src/headless.rs
    // would be good if these could be shared
    fn footage_path(p: &LumitBridgeState, f: &FootageItem) -> PathBuf {
        if f.media.absolute_path.is_empty() {
            let path = p.path.clone().unwrap();
            let path = path.parent().unwrap();
            println!("current path: {}", path.to_str().unwrap());
            let path = path.join(PathBuf::from(&f.media.relative_path));
            path.canonicalize().unwrap()
        } else {
            PathBuf::from(&f.media.absolute_path)
        }
    }

    pub fn get_status(&self) -> Result<LumitMediaStatus, BridgeError> {
        let proj = self.project()?;
        let proj = proj.read().map_err(|_| BridgeError::ReadFailed)?;

        let snapshot = proj.store.snapshot();
        let item = snapshot.item(self.id).unwrap();

        match item {
            lumit_core::model::ProjectItem::Footage(footage_item) => {
                let path = Self::footage_path(&proj, &footage_item);

                let probe = lumit_media::probe::probe(&path);

                match probe {
                    // not sure where this info comes from
                    Ok(_) => Ok(LumitMediaStatus::Ready),
                    Err(_) => Ok(LumitMediaStatus::Missing),
                }
            }
            _ => Err(BridgeError::InvalidItem),
        }
    }
}
