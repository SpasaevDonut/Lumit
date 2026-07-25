use std::{println, sync::Arc, todo};

use flutter_rust_bridge::frb;

use uuid::Uuid;

use crate::api::{
    effect::BridgeEffectInstance,
    layer::LayerReference,
    state::{LumitBridgeState, PROJECTS},
    worker_thread::{
        RenderCompRequest, RenderCompRequestWithPreview,
        WorkerRequest::{RenderComp, RenderCompWithPreview},
    },
    BridgeError,
};

#[derive(Debug, PartialEq, Eq, Clone)]
#[frb]
pub struct CompositionReference {
    #[frb(name = "internalproject")]
    pub project: Uuid,
    #[frb(name = "internalid")]
    pub id: Uuid,
}

impl CompositionReference {
    #[frb(ignore)]
    pub fn new(project: Uuid, id: Uuid) -> CompositionReference {
        CompositionReference { project, id }
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

    #[frb(sync)]
    pub fn get_layers(&self) -> Result<Vec<LayerReference>, BridgeError> {
        let proj = self.project()?;
        let proj = proj.read().map_err(|_| BridgeError::ReadFailed)?;

        let snapshot = proj.store.snapshot();
        let item = snapshot.item(self.id).unwrap();

        match item {
            lumit_core::model::ProjectItem::Composition(composition) => Ok(composition
                .layers
                .iter()
                .map(|i| LayerReference::new(self.project.clone(), self.id.clone(), i.id.clone()))
                .collect()),
            _ => todo!(),
        }
    }

    #[frb(sync)]
    pub fn render_frame(&self, frame: u64) -> Result<(), BridgeError> {
        let p = self.project()?;

        let p = p.read().map_err(|_| BridgeError::ReadFailed)?;

        match &p.sender {
            Some(sender) => {
                let result = sender.send(RenderComp(RenderCompRequest {
                    comp: self.clone(),
                    frame,
                }));

                return match result {
                    Ok(_) => Ok(()),
                    Err(err) => {
                        println!("Error while requesting render: {:?}", err);
                        Err(BridgeError::InvalidWorkerState)
                    }
                };
            }
            None => Err(BridgeError::InvalidWorkerState),
        }
    }

    #[frb(sync)]
    pub fn render_frame_with_preview(
        &self,
        frame: u64,
        layer: LayerReference,
        effects: Vec<BridgeEffectInstance>,
    ) -> Result<(), BridgeError> {
        let p = self.project()?;

        let p = p.read().map_err(|_| BridgeError::ReadFailed)?;

        match &p.sender {
            Some(sender) => {
                let result = sender.send(RenderCompWithPreview(RenderCompRequestWithPreview {
                    comp: self.clone(),
                    frame,
                    layer: layer,
                    effects: effects.iter().map(|i| i.get_effects()).collect(),
                }));

                // TODO: properly handle generations so that frames which render out of order to not
                // show up in viewport when they are already out of date
                return match result {
                    Ok(_) => Ok(()),
                    Err(err) => {
                        println!("Error while requesting render: {:?}", err);
                        Err(BridgeError::InvalidWorkerState)
                    }
                };
            }
            None => Err(BridgeError::InvalidWorkerState),
        }
    }
}
