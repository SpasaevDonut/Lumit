use std::{println, sync::Arc};

use flutter_rust_bridge::frb;

use uuid::Uuid;

use crate::api::{
    effect::BridgeEffectInstance,
    footage::FootageReference,
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

/// Everything the Composition settings dialog reads and writes.
///
/// The frame rate is the exact `num`/`den` pair and the duration is a frame count,
/// never floating-point seconds (docs/14 §2). A dialog that round-tripped 29.97
/// through a double would not hand it back as 30000/1001.
#[frb(non_opaque)]
pub struct BridgeCompSettings {
    pub name: String,
    pub width: u32,
    pub height: u32,
    pub fps_num: u32,
    pub fps_den: u32,
    pub duration_frames: i64,
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

    /// Everything the Composition settings dialog shows.
    ///
    /// The frame rate crosses as an exact `{num, den}` pair and the duration as a
    /// frame count, never as floating-point seconds — docs/14 §2's rational-time
    /// rule. 29.97 fps is 30000/1001, and a dialog that round-tripped it through a
    /// double would not give it back.
    #[frb(sync)]
    pub fn get_settings(&self) -> Result<BridgeCompSettings, BridgeError> {
        let comp = self.composition()?;
        let frames = comp
            .frame_rate
            .frame_at(lumit_core::time::CompTime(comp.duration.0));
        Ok(BridgeCompSettings {
            name: comp.name.clone(),
            width: comp.width,
            height: comp.height,
            fps_num: comp.frame_rate.num(),
            fps_den: comp.frame_rate.den(),
            duration_frames: frames,
        })
    }

    /// Apply the Composition settings dialog, as one undo step.
    ///
    /// Dimensions are clamped to 16..=16384 and the duration to at least one frame,
    /// so a dialog cannot commit a comp that is zero pixels wide or zero frames
    /// long. The background colour is preserved: it is not part of this dialog, and
    /// `SetCompSettings` carries the whole settings block.
    #[frb(sync)]
    pub fn set_settings(&self, settings: BridgeCompSettings) -> Result<(), BridgeError> {
        use lumit_core::time::{Duration, FrameRate};

        let comp = self.composition()?;
        let frame_rate = FrameRate::new(settings.fps_num, settings.fps_den)
            .map_err(|_| BridgeError::InvalidFrameRate)?;
        let duration = frame_rate
            .time_of_frame(settings.duration_frames.max(1))
            .map(|t| Duration(t.0))
            .map_err(|_| BridgeError::InvalidFrameRate)?;

        let proj = self.project()?;
        let proj = proj.write().map_err(|_| BridgeError::WriteFailed)?;
        proj.store
            .commit(lumit_core::Op::SetCompSettings {
                comp: self.id,
                name: settings.name,
                width: settings.width.clamp(16, 16384),
                height: settings.height.clamp(16, 16384),
                frame_rate,
                duration,
                background: comp.background,
            })
            .map_err(BridgeError::OpError)?;
        Ok(())
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

    /// Place `footage` into this composition as a new top layer.
    ///
    /// The layer's span is the media's own duration in comp frames, and its
    /// transform is anchored on the media's own centre at the comp centre (K-150),
    /// so a placed clip appears centred and pivots about its middle. Both fall
    /// back to the comp's duration and size when the media cannot be probed —
    /// a missing file still places, so the user can relink it rather than being
    /// unable to add it at all.
    ///
    /// The duration comes from the container's real `duration_seconds`, not from
    /// a frame count: audio-only media has no video frame count or rate, and
    /// reconstructing seconds from those silently clamped such a clip to one frame.
    #[frb(sync)]
    pub fn add_footage_layer(&self, footage: &FootageReference) -> Result<(), BridgeError> {
        let proj = self.project()?;
        let comp = self.composition()?;

        let layer = {
            let p = proj.read().map_err(|_| BridgeError::ReadFailed)?;
            let doc = p.store.snapshot();

            let item = footage.id();
            let Some(lumit_core::model::ProjectItem::Footage(f)) = doc.item(item) else {
                return Err(BridgeError::InvalidItem);
            };

            let (out, nat_w, nat_h) = Self::footage_span_and_size(&p, f, &comp);

            crate::edits::base_layer(
                f.name.clone(),
                lumit_core::model::LayerKind::Footage { item, retime: None },
                out,
                crate::edits::centred_transform(nat_w, nat_h, comp.width, comp.height),
            )
        };

        let proj = proj.write().map_err(|_| BridgeError::WriteFailed)?;
        proj.store
            .commit(lumit_core::Op::AddLayer {
                comp: self.id,
                index: 0,
                layer: Box::new(layer),
            })
            .map_err(BridgeError::OpError)?;
        Ok(())
    }

    /// The span end and natural pixel size a placed clip should take: the media's
    /// own when it probes, the comp's when it does not.
    #[frb(ignore)]
    fn footage_span_and_size(
        state: &LumitBridgeState,
        footage: &lumit_core::model::FootageItem,
        comp: &lumit_core::model::Composition,
    ) -> (lumit_core::time::Rational, f64, f64) {
        let fallback = (
            comp.duration.0,
            f64::from(comp.width),
            f64::from(comp.height),
        );

        #[cfg(feature = "media")]
        {
            let Some(path) = FootageReference::resolve_path(state, footage) else {
                return fallback;
            };
            let Ok(info) = lumit_media::probe::probe(&path) else {
                return fallback;
            };
            let frames = (info.duration_seconds * comp.frame_rate.fps()).round() as i64;
            let out = comp
                .frame_rate
                .time_of_frame(frames.max(1))
                .map(|t| t.0)
                .unwrap_or(comp.duration.0);
            // Audio-only media has no video stream at all, so it takes the comp's
            // size — there is no natural size to anchor on.
            let (nat_w, nat_h) = match info.video {
                Some(v) if v.width > 0 && v.height > 0 => (f64::from(v.width), f64::from(v.height)),
                _ => (f64::from(comp.width), f64::from(comp.height)),
            };
            (out, nat_w, nat_h)
        }

        // Without the media feature nothing probes, so a placed clip spans the
        // whole comp at comp size.
        #[cfg(not(feature = "media"))]
        {
            let _ = (state, footage);
            fallback
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
            effects: Some(effects.iter().map(|i| i.get_effects()).collect()),
            transform: None,
        }))
    }

    /// Ask for `frame` with `layer`'s transform replaced by `transform` — the
    /// same live-drag path as [`Self::render_frame_with_preview`], for the
    /// Transform rows. Never touches the document.
    #[frb(sync)]
    pub fn render_frame_with_transform_preview(
        &self,
        frame: u64,
        scale: f32,
        layer: LayerReference,
        transform: crate::api::layer::BridgeTransform,
    ) -> Result<(), BridgeError> {
        self.dispatch(RenderCompWithPreview(RenderCompRequestWithPreview {
            comp: self.clone(),
            frame,
            scale,
            layer,
            effects: None,
            transform: Some(transform),
        }))
    }
}
