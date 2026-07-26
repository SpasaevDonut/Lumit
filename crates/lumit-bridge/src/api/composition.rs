use std::{println, sync::Arc};

use flutter_rust_bridge::frb;

use uuid::Uuid;

use crate::api::{
    effect::BridgeEffectInstance,
    layer::LayerReference,
    state::{LumitBridgeState, PROJECTS},
    worker_thread::{
        RenderCompRequest, RenderCompRequestWithPreview, WorkerRequest,
        WorkerRequest::{RenderComp, RenderCompWithPreview},
    },
    BridgeError,
};

/// A composition's pixel dimensions.
#[frb(non_opaque)]
pub struct BridgeCompSize {
    pub width: u32,
    pub height: u32,
}

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
        let projects = PROJECTS.read().map_err(|_| BridgeError::ReadFailed)?;
        let project = projects.get(&self.project);

        let p = project.ok_or(BridgeError::InvalidProject)?;
        Ok(p.clone())
    }

    /// The comp's pixel dimensions. The Viewer needs these to work out what
    /// fraction of comp resolution it is actually showing, which is the `scale`
    /// every render request carries — without them it could only ever ask for
    /// full resolution.
    #[frb(sync)]
    pub fn get_size(&self) -> Result<BridgeCompSize, BridgeError> {
        let comp = self.composition()?;
        Ok(BridgeCompSize {
            width: comp.width,
            height: comp.height,
        })
    }

    /// The composition this reference names, cloned out of the current snapshot.
    #[frb(ignore)]
    fn composition(&self) -> Result<lumit_core::model::Composition, BridgeError> {
        let proj = self.project()?;
        let proj = proj.read().map_err(|_| BridgeError::ReadFailed)?;
        let snapshot = proj.store.snapshot();

        match snapshot.item(self.id).ok_or(BridgeError::InvalidComp)? {
            lumit_core::model::ProjectItem::Composition(composition) => Ok(composition.clone()),
            // A CompositionReference pointing at a non-composition item means the
            // id was reused or the reference outlived its item.
            _ => Err(BridgeError::InvalidComp),
        }
    }

    #[frb(sync)]
    pub fn get_layers(&self) -> Result<Vec<LayerReference>, BridgeError> {
        Ok(self
            .composition()?
            .layers
            .iter()
            .map(|i| LayerReference::new(self.project, self.id, i.id))
            .collect())
    }

    /// Hand a render request to the worker.
    ///
    /// Requests are not queued up behind each other: the worker drains its
    /// channel to the newest before rendering, so asking faster than it can
    /// render simply drops the frames in between rather than working through a
    /// backlog nothing will ever see. That is also why no request carries a
    /// generation — one worker thread renders sequentially and publishes down one
    /// stream, so responses arrive in the order they were asked for and the last
    /// one is always the newest. (The `TODO` that used to sit here asked for
    /// generations to stop out-of-order frames; with the queue coalescing and a
    /// single worker there is no out-of-order case for them to fix.)
    #[frb(ignore)]
    fn dispatch(&self, request: WorkerRequest) -> Result<(), BridgeError> {
        let p = self.project()?;
        let p = p.read().map_err(|_| BridgeError::ReadFailed)?;

        let Some(sender) = &p.sender else {
            return Err(BridgeError::InvalidWorkerState);
        };

        sender.send(request).map_err(|err| {
            println!("Error while requesting render: {err:?}");
            BridgeError::InvalidWorkerState
        })
    }

    /// Ask for `frame` at `scale` — 1.0 meaning "shown at comp resolution".
    /// Below 1.0 the engine decodes and composites smaller, which is how a
    /// Viewer that is not filling the screen stays cheap.
    #[frb(sync)]
    pub fn render_frame(&self, frame: u64, scale: f32) -> Result<(), BridgeError> {
        self.dispatch(RenderComp(RenderCompRequest {
            comp: self.clone(),
            frame,
            scale,
        }))
    }

    /// Ask for `frame` with `layer`'s effect stack replaced by `effects` — the
    /// live drag path, which never touches the document.
    #[frb(sync)]
    pub fn render_frame_with_preview(
        &self,
        frame: u64,
        scale: f32,
        layer: LayerReference,
        effects: Vec<BridgeEffectInstance>,
    ) -> Result<(), BridgeError> {
        self.dispatch(RenderCompWithPreview(RenderCompRequestWithPreview {
            comp: self.clone(),
            frame,
            scale,
            layer,
            effects: effects.iter().map(|i| i.get_effects()).collect(),
        }))
    }
}
