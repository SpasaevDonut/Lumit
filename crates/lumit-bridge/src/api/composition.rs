use std::{println, sync::Arc};

use flutter_rust_bridge::frb;

use uuid::Uuid;

use crate::api::effect::BridgeRational;
use crate::api::layer::BridgeSpan;
use crate::api::{
    effect::BridgeEffectInstance,
    footage::FootageReference,
    layer::LayerReference,
    state::{LumitBridgeState, PROJECTS},
    worker_thread::{
        RenderCompRequest, RenderCompRequestWithPreview, RenderScopeRequest, SamplePixelsRequest,
        WorkerRequest,
        WorkerRequest::{RenderComp, RenderCompWithPreview},
    },
    BridgeError,
};

/// One timeline marker (docs/03 §11): a cue on the comp's timebase.
///
/// The engine's marker also carries a duration and a kind; neither has a
/// control yet, so they are not carried across — a marker written back keeps
/// what the panel can actually edit and does not pretend to round-trip the rest.
#[frb(non_opaque)]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeMarker {
    pub id: Uuid,
    pub time: BridgeRational,
    pub label: String,
}

/// Every blend mode, in the order the Timeline's dropdown shows them. The index
/// into this list is what `LayerReference::get_blend`/`set_blend` speak, so the
/// two cannot disagree about what "3" means.
///
/// Stateless, so a free function: the dropdown is built before any layer is
/// selected.
#[frb(sync)]
pub fn list_blend_modes() -> Vec<String> {
    lumit_core::model::BlendMode::ALL
        .iter()
        .map(|mode| format!("{mode:?}"))
        .collect()
}

/// A composition's pixel dimensions.
#[frb(non_opaque)]
pub struct BridgeCompSize {
    pub width: u32,
    pub height: u32,
}

/// One layer of the comp read model (K-184): the plain-data handle Dart
/// addresses edits by, and everything the panels draw for it.
#[frb(non_opaque)]
pub struct BridgeLayerEntry {
    pub layer: LayerReference,
    pub info: crate::api::layer::BridgeLayerInfo,
}

/// The comp read model (K-184): what one `get_model` crossing carries. Dart
/// holds this and refreshes it when the engine reports a change; panels draw
/// from it with no bridge calls at all.
#[frb(non_opaque)]
pub struct BridgeCompModel {
    pub duration_frames: i64,
    /// The comp's rate as a plain number, for panels that map seconds to
    /// pixels (the waveform lane) without a bridge call per paint.
    pub fps: f64,
    /// The exact rate, for the Timeline's timecode readout: 29.97 must count
    /// 30 frames a second, which a double cannot say (docs/14 §2).
    pub fps_num: u32,
    pub fps_den: u32,
    /// The comp's master motion-blur shutter (K-120): whether layers with
    /// their own motion-blur switch actually blur. Drawn by the Timeline's
    /// master button; written through `set_motion_blur_enabled`.
    pub motion_blur_enabled: bool,
    pub layers: Vec<BridgeLayerEntry>,
}

/// Everything the Composition settings dialog reads and writes.
///
/// The frame rate is the exact `num`/`den` pair and the duration is exact
/// rational **seconds**, never floating point (docs/14 §2). A dialog that
/// round-tripped 29.97 through a double would not hand it back as 30000/1001.
///
/// The duration is seconds rather than a frame count because the frame rate is
/// editable in the same dialog, and a frame count means nothing without knowing
/// which rate it was counted at: applying "1800 frames" after changing 60 fps to
/// 30 halved the comp's real length while every layer kept its own seconds, which
/// is what made the layers look retimed (K-180). Seconds are what the document
/// stores, so the rate can change without the comp getting longer or shorter.
/// Callers wanting the count ask [`CompositionReference::duration_frames`].
#[frb(non_opaque)]
pub struct BridgeCompSettings {
    pub name: String,
    pub width: u32,
    pub height: u32,
    pub fps_num: u32,
    pub fps_den: u32,
    pub duration: BridgeRational,
}

impl BridgeCompSettings {
    /// What a comp gets when nobody chose: 1920×1080, 60 fps, 30 seconds.
    ///
    /// Here rather than in the frontend so the New composition dialog and a
    /// `new_composition` with no settings cannot drift into different ideas of
    /// what a default comp is.
    #[frb(sync)]
    pub fn defaults() -> BridgeCompSettings {
        BridgeCompSettings {
            name: String::new(),
            width: 1920,
            height: 1080,
            fps_num: 60,
            fps_den: 1,
            duration: BridgeRational { num: 30, den: 1 },
        }
    }

    /// The engine types this settings block names, or `None` when the rate or
    /// duration is not a time at all.
    #[frb(ignore)]
    pub(crate) fn to_engine(
        &self,
    ) -> Option<(lumit_core::time::FrameRate, lumit_core::time::Duration)> {
        use lumit_core::time::{Duration, FrameRate, Rational};
        let rate = FrameRate::new(self.fps_num, self.fps_den).ok()?;
        let duration = Rational::new(self.duration.num, self.duration.den).ok()?;
        // A comp shorter than one frame has nothing to show, so the floor is one
        // frame at the rate being applied.
        let floor = rate.frame_duration().ok()?;
        Some((rate, Duration(duration.max(floor.0))))
    }
}

#[derive(Debug, PartialEq, Eq, Clone)]
#[frb]
pub struct CompositionReference {
    #[frb(name = "internalproject")]
    pub project: Uuid,
    #[frb(name = "internalid")]
    pub id: Uuid,
}

/// How playback should behave when the machine cannot render at the
/// composition's own rate — the choice the Viewer offers, and shows.
///
/// The two are genuinely different jobs, not a quality slider:
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum BridgePlaybackMode {
    /// **Keep time; lower the resolution.** The realtime controller measures
    /// each frame and drops to a coarser preview tier until playback keeps up,
    /// so the picture stays in step with the sound and goes soft rather than
    /// stuttering. Frames are kept under the tier they were actually made at, so
    /// the cache bar can show them dimmed — held, but coarser than you are
    /// watching — and a second pass over the same stretch is served rather than
    /// rendered again.
    Adaptive,
    /// **Every frame, at the resolution asked for, however long it takes** — and
    /// kept, so the second pass over the same stretch plays properly. Sound
    /// plays while rendering holds the comp's rate and is paused by the worker
    /// if the picture falls genuinely behind (K-171): a paused track over a
    /// slow-motion picture, never a drifting one.
    EveryFrame,
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
    pub(crate) fn project(&self) -> Result<Arc<std::sync::RwLock<LumitBridgeState>>, BridgeError> {
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
    /// The frame rate crosses as an exact `{num, den}` pair and the duration as
    /// exact rational seconds, never as a float — docs/14 §2's rational-time rule.
    /// 29.97 fps is 30000/1001, and a dialog that round-tripped it through a double
    /// would not give it back.
    #[frb(sync)]
    pub fn get_settings(&self) -> Result<BridgeCompSettings, BridgeError> {
        let comp = self.composition()?;
        Ok(BridgeCompSettings {
            name: comp.name.clone(),
            width: comp.width,
            height: comp.height,
            fps_num: comp.frame_rate.num(),
            fps_den: comp.frame_rate.den(),
            duration: BridgeRational {
                num: comp.duration.0.num(),
                den: comp.duration.0.den(),
            },
        })
    }

    /// How many frames the comp is long at its own rate — the Timeline's axis,
    /// and one past the last frame the transport can reach.
    ///
    /// Derived rather than stored: the document holds a length in seconds, and
    /// the count is that length read at whatever rate the comp currently has.
    #[frb(sync)]
    pub fn duration_frames(&self) -> Result<i64, BridgeError> {
        let comp = self.composition()?;
        Ok(comp
            .frame_rate
            .frame_at(lumit_core::time::CompTime(comp.duration.0)))
    }

    /// The document's revision number: bumped once per committed change, undo,
    /// redo or recovery. The Dart read model compares it per rebuild — one
    /// cheap crossing — and re-reads [`Self::get_model`] only when it moved,
    /// so a rebuild of an unchanged document costs exactly one call (K-184).
    #[frb(sync)]
    pub fn document_revision(&self) -> Result<u64, BridgeError> {
        let proj = self.project()?;
        let proj = proj.read().map_err(|_| BridgeError::ReadFailed)?;
        Ok(proj.store.revision())
    }

    /// The whole comp as the panels draw it, in ONE crossing (K-184): every
    /// layer's handle and its full [`BridgeLayerInfo`] (switches, blend, span
    /// as frames, transform, every effect's every value), plus the comp's
    /// length. This is the Dart read model's refresh: read once per document
    /// change, never per widget rebuild — so selecting a layer, or any other
    /// pure-interface change, costs zero bridge calls.
    #[frb(sync)]
    pub fn get_model(&self) -> Result<BridgeCompModel, BridgeError> {
        let comp = self.composition()?;
        Ok(BridgeCompModel {
            duration_frames: comp
                .frame_rate
                .frame_at(lumit_core::time::CompTime(comp.duration.0)),
            fps: comp.frame_rate.fps(),
            fps_num: comp.frame_rate.num(),
            fps_den: comp.frame_rate.den(),
            motion_blur_enabled: comp.motion_blur.enabled,
            layers: comp
                .layers
                .iter()
                .map(|layer| BridgeLayerEntry {
                    layer: LayerReference::new(self.project, self.id, layer.id),
                    info: crate::api::layer::read_layer_info(&comp, layer),
                })
                .collect(),
        })
    }

    /// Apply the Composition settings dialog, as one undo step.
    ///
    /// Dimensions are clamped to 16..=16384 and the duration to at least one frame,
    /// so a dialog cannot commit a comp that is zero pixels wide or zero frames
    /// long. The background colour is preserved: it is not part of this dialog, and
    /// `SetCompSettings` carries the whole settings block.
    ///
    /// Changing only the frame rate changes only the frame rate: the duration
    /// crosses as seconds, so the comp keeps its real length and every layer keeps
    /// its own timing — the comp shows more (or fewer) frames per second and
    /// nothing plays faster (K-180).
    #[frb(sync)]
    pub fn set_settings(&self, settings: BridgeCompSettings) -> Result<(), BridgeError> {
        let comp = self.composition()?;
        let (frame_rate, duration) = settings.to_engine().ok_or(BridgeError::InvalidFrameRate)?;

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

    /// Turn the comp's master motion-blur shutter on or off (K-120), keeping
    /// the shutter's angle, phase and sample count as they are. One op, one
    /// undo step — the Timeline's master button.
    #[frb(sync)]
    pub fn set_motion_blur_enabled(&self, on: bool) -> Result<(), BridgeError> {
        let comp = self.composition()?;
        let proj = self.project()?;
        let proj = proj.write().map_err(|_| BridgeError::WriteFailed)?;
        proj.store
            .commit(lumit_core::Op::SetCompMotionBlur {
                comp: self.id,
                motion_blur: lumit_core::model::MotionBlur {
                    enabled: on,
                    ..comp.motion_blur
                },
            })
            .map_err(BridgeError::OpError)?;
        Ok(())
    }

    /// Add a Solid layer backed by a fresh SolidDef filed in the Solids
    /// auto-folder — one batch, one undo step, matching the egui frontend. The
    /// solid is comp-sized and white, named "White solid N".
    #[frb(sync)]
    pub fn add_solid_layer(&self) -> Result<LayerReference, BridgeError> {
        use lumit_core::model::{LinearColour, ProjectItem, SolidDef};
        use lumit_core::ops::AutoFolderKind;

        let comp = self.composition()?;
        let doc = self.document()?;
        let (folder, mut ops) = crate::edits::ensure_auto_folder_ops(&doc, AutoFolderKind::Solids);

        let def = Uuid::now_v7();
        let solids = doc
            .items
            .iter()
            .filter(|i| matches!(i, ProjectItem::Solid(_)))
            .count();
        let name = format!("White solid {}", solids + 1);

        // The folder op may itself be an AddItem, so the index has to account
        // for what this batch has already inserted.
        let added = ops
            .iter()
            .filter(|o| matches!(o, lumit_core::Op::AddItem { .. }))
            .count();
        ops.push(lumit_core::Op::AddItem {
            index: doc.items.len() + added,
            item: Box::new(ProjectItem::Solid(SolidDef {
                id: def,
                name: name.clone(),
                colour: LinearColour([1.0, 1.0, 1.0, 1.0]),
                width: comp.width,
                height: comp.height,
                extra: serde_json::Map::new(),
            })),
        });
        ops.push(crate::edits::file_into_folder_op(&doc, folder, def));

        let layer = crate::edits::base_layer(
            name,
            lumit_core::model::LayerKind::Solid { def },
            comp.duration.0,
            crate::edits::centred_transform(
                f64::from(comp.width),
                f64::from(comp.height),
                comp.width,
                comp.height,
            ),
        );
        let id = layer.id;
        ops.push(lumit_core::Op::AddLayer {
            comp: self.id,
            index: 0,
            layer: Box::new(layer),
        });

        self.commit(lumit_core::Op::Batch { ops })?;
        Ok(LayerReference::new(self.project, self.id, id))
    }

    /// Place another composition into this one as a Precomp layer.
    ///
    /// Refuses to nest a comp inside itself. A deeper cycle — A inside B inside
    /// A — is not checked here, because doing it properly means walking the
    /// whole tree on every insertion; the render guards defensively against one
    /// and the Hierarchy panel bounds its own recursion. The one-step case is
    /// checked because it is the one a user reaches by accident.
    #[frb(sync)]
    pub fn add_precomp_layer(
        &self,
        comp: &CompositionReference,
    ) -> Result<LayerReference, BridgeError> {
        if comp.id == self.id {
            return Err(BridgeError::InvalidComp);
        }
        let inner = comp.composition()?;
        let outer = self.composition()?;

        let layer = crate::edits::base_layer(
            inner.name.clone(),
            lumit_core::model::LayerKind::Precomp { comp: inner.id },
            outer.duration.0,
            crate::edits::centred_transform(
                f64::from(inner.width),
                f64::from(inner.height),
                outer.width,
                outer.height,
            ),
        );
     /// Precompose one or more layers into a new composition (docs/07 §13.4, K-068).
    ///
    /// `layer_ids` are the layers in `self` to precompose.
    /// `name` is the name of the new composition.
    /// `leave_attributes` leaves transform/effects/masks/retime on the new Precomp layer in `self`
    /// (only valid when `layer_ids.len() == 1`).
    /// `adjust_duration` sets the new comp's duration to the time span of the selected layers.
    #[frb(sync)]
    pub fn precompose(
        &self,
        layer_ids: Vec<Uuid>,
        name: String,
        leave_attributes: bool,
        adjust_duration: bool,
    ) -> Result<LayerReference, BridgeError> {
        use lumit_core::model::{Composition, MotionBlur, ProjectItem};
        use lumit_core::ops::{AutoFolderKind, Op};

        if layer_ids.is_empty() {
            return Err(BridgeError::InvalidLayer);
        }
        if leave_attributes && layer_ids.len() > 1 {
            return Err(BridgeError::InvalidLayer);
        }

        let parent_comp = self.composition()?;
        let bridge_state = self.project()?;
        let state = bridge_state.write().map_err(|_| BridgeError::WriteFailed)?;
        let doc = state.store.snapshot();

        let mut target_layers = Vec::new();
        let mut top_index = usize::MAX;
        for (idx, layer) in parent_comp.layers.iter().enumerate() {
            if layer_ids.contains(&layer.id) {
                target_layers.push(layer.clone());
                if idx < top_index {
                    top_index = idx;
                }
            }
        }
        if target_layers.len() != layer_ids.len() {
            return Err(BridgeError::InvalidLayer);
        }

        let min_in = target_layers
            .iter()
            .map(|l| l.in_point)
            .min()
            .unwrap_or(lumit_core::time::CompTime::ZERO);
        let max_out = target_layers
            .iter()
            .map(|l| l.out_point)
            .max()
            .unwrap_or(lumit_core::time::CompTime(parent_comp.duration.0));

        let new_comp_duration = if adjust_duration && max_out > min_in {
            max_out.delta(min_in).unwrap_or(parent_comp.duration)
        } else {
            parent_comp.duration
        };

        let comp_name = if name.trim().is_empty() {
            let existing = doc
                .items
                .iter()
                .filter(|i| matches!(i, lumit_core::model::ProjectItem::Composition(_)))
                .count();
            format!("Comp {}", existing + 1)
        } else {
            name.trim().to_string()
        };

        let new_comp_id = Uuid::now_v7();
        let mut new_comp = Composition {
            id: new_comp_id,
            name: comp_name.clone(),
            width: parent_comp.width,
            height: parent_comp.height,
            frame_rate: parent_comp.frame_rate,
            duration: new_comp_duration,
            background: parent_comp.background,
            layers: Vec::new(),
            work_area: None,
            markers: Vec::new(),
            motion_blur: MotionBlur::default(),
            extra: serde_json::Map::new(),
        };

        let time_shift = if adjust_duration {
            min_in
        } else {
            lumit_core::time::CompTime::ZERO
        };

        if leave_attributes && target_layers.len() == 1 {
            let src_layer = &target_layers[0];
            let mut inner_layer = src_layer.clone();
            inner_layer.id = Uuid::now_v7();
            inner_layer.transform = crate::edits::centred_transform(
                f64::from(parent_comp.width),
                f64::from(parent_comp.height),
                parent_comp.width,
                parent_comp.height,
            );
            inner_layer.effects.clear();
            inner_layer.masks.clear();
            inner_layer.retime = None;
            inner_layer.in_point = lumit_core::time::CompTime(src_layer.in_point.0.checked_sub(time_shift.0).unwrap_or(src_layer.in_point.0));
            inner_layer.out_point = lumit_core::time::CompTime(src_layer.out_point.0.checked_sub(time_shift.0).unwrap_or(src_layer.out_point.0));
            inner_layer.start_offset = lumit_core::time::CompTime(src_layer.start_offset.0.checked_sub(time_shift.0).unwrap_or(src_layer.start_offset.0));

            new_comp.layers.push(inner_layer);
        } else {
            for src_layer in &target_layers {
                let mut inner_layer = src_layer.clone();
                inner_layer.in_point = lumit_core::time::CompTime(src_layer.in_point.0.checked_sub(time_shift.0).unwrap_or(src_layer.in_point.0));
                inner_layer.out_point = lumit_core::time::CompTime(src_layer.out_point.0.checked_sub(time_shift.0).unwrap_or(src_layer.out_point.0));
                inner_layer.start_offset = lumit_core::time::CompTime(src_layer.start_offset.0.checked_sub(time_shift.0).unwrap_or(src_layer.start_offset.0));
                new_comp.layers.push(inner_layer);
            }
        }

        let mut ops: Vec<Op> = Vec::new();

        let (folder_id, folder_ops) = crate::edits::ensure_auto_folder_ops(&doc, AutoFolderKind::Compositions);
        ops.extend(folder_ops);

        let new_comp_uuid = new_comp.id;
        ops.push(Op::AddItem {
            index: doc.items.len(),
            item: Box::new(ProjectItem::Composition(new_comp)),
        });
        ops.push(crate::edits::file_into_folder_op(&doc, folder_id, new_comp_uuid));

        let precomp_layer_id = Uuid::now_v7();
        let precomp_layer = if leave_attributes && target_layers.len() == 1 {
            let src_layer = &target_layers[0];
            let (in_pt, out_pt, start_off) = if adjust_duration {
                (min_in, max_out, min_in)
            } else {
                (src_layer.in_point, src_layer.out_point, src_layer.start_offset)
            };
            let mut layer = crate::edits::base_layer(
                comp_name,
                lumit_core::model::LayerKind::Precomp { comp: new_comp_id },
                out_pt.0,
                src_layer.transform.clone(),
            );
            layer.id = precomp_layer_id;
            layer.in_point = in_pt;
            layer.out_point = out_pt;
            layer.start_offset = start_off;
            layer.effects = src_layer.effects.clone();
            layer.masks = src_layer.masks.clone();
            layer.retime = src_layer.retime.clone();
            layer.switches = src_layer.switches.clone();
            layer
        } else {
            let (in_pt, out_pt, start_off) = if adjust_duration {
                (min_in, max_out, min_in)
            } else {
                (lumit_core::time::CompTime::ZERO, lumit_core::time::CompTime(parent_comp.duration.0), lumit_core::time::CompTime::ZERO)
            };
            let mut layer = crate::edits::base_layer(
                comp_name,
                lumit_core::model::LayerKind::Precomp { comp: new_comp_id },
                out_pt.0,
                crate::edits::centred_transform(
                    f64::from(parent_comp.width),
                    f64::from(parent_comp.height),
                    parent_comp.width,
                    parent_comp.height,
                ),
            );
            layer.id = precomp_layer_id;
            layer.in_point = in_pt;
            layer.out_point = out_pt;
            layer.start_offset = start_off;
            layer
        };

        for layer in &target_layers {
            ops.push(Op::RemoveLayer {
                comp: self.id,
                layer: layer.id,
            });
        }

        let insert_idx = top_index.min(parent_comp.layers.len().saturating_sub(target_layers.len()));
        ops.push(Op::AddLayer {
            comp: self.id,
            index: insert_idx,
            layer: Box::new(precomp_layer),
        });

        drop(state);

        self.commit(Op::Batch { ops })?;

        Ok(LayerReference::new(self.project, self.id, precomp_layer_id))
    }

    /// Add a Text layer with the "Text" starter document, centred.
    #[frb(sync)]
    pub fn add_text_layer(&self) -> Result<LayerReference, BridgeError> {
        use lumit_core::anim::Property;
        use lumit_core::model::{LinearColour, TextDocument, TransformGroup};

        let comp = self.composition()?;
        let size = 72.0_f64;
        let text = "Text";
        // The anchor sits on the estimated glyph bounds so the layer rotates
        // and scales about its own middle rather than its top-left corner.
        let estimated_width = text.chars().count() as f64 * size * 0.5;

        let layer = crate::edits::base_layer(
            "Text".into(),
            lumit_core::model::LayerKind::Text {
                document: TextDocument {
                    text: text.into(),
                    size,
                    fill: LinearColour([1.0, 1.0, 1.0, 1.0]),
                    extra: serde_json::Map::new(),
                },
            },
            comp.duration.0,
            TransformGroup {
                anchor_x: Property::fixed(estimated_width * 0.5),
                anchor_y: Property::fixed(size * 0.5),
                position_x: Property::fixed(f64::from(comp.width) * 0.5),
                position_y: Property::fixed(f64::from(comp.height) * 0.5),
                ..TransformGroup::default()
            },
        );
        self.add_at_top(layer)
    }

    /// Add a text layer **where the Type tool clicked**, already holding the
    /// document it should hold, as one op (K-230).
    ///
    /// The tool used to make a layer and then correct it: `add_text_layer`
    /// starts a layer saying "Text" in the middle of the composition, and the
    /// tool then wrote an empty line into it and moved it to the click. Three
    /// ops for one gesture, so `Ctrl+Z` walked back through two states nobody
    /// had ever seen — an empty box, then the word "Text" — before the layer
    /// finally went away. One op is one undo step, and undoing it removes the
    /// layer, which is what making a layer means.
    ///
    /// The anchor sits on the **left end of the baseline**, so what is typed
    /// runs to the right of the point clicked and sits on it rather than
    /// straddling it. It is recentred on the finished line when the edit ends.
    #[frb(sync)]
    pub fn add_text_layer_at(
        &self,
        document: crate::api::assets::BridgeTextDocument,
        x: f64,
        y: f64,
    ) -> Result<LayerReference, BridgeError> {
        use lumit_core::anim::Property;
        use lumit_core::model::TransformGroup;

        let comp = self.composition()?;
        let size = document.size;
        let layer = crate::edits::base_layer(
            "Text".into(),
            lumit_core::model::LayerKind::Text {
                document: crate::api::assets::text_document_of(document),
            },
            comp.duration.0,
            TransformGroup {
                anchor_x: Property::fixed(0.0),
                anchor_y: Property::fixed(size),
                position_x: Property::fixed(x),
                position_y: Property::fixed(y),
                ..TransformGroup::default()
            },
        );
        self.add_at_top(layer)
    }

    /// Add a Camera layer at the comp centre. The default zoom is the After
    /// Effects 50 mm model, `comp width × 50/36`.
    #[frb(sync)]
    pub fn add_camera_layer(&self) -> Result<LayerReference, BridgeError> {
        use lumit_core::anim::Property;
        use lumit_core::model::TransformGroup;

        let comp = self.composition()?;
        let layer = crate::edits::base_layer(
            "Camera".into(),
            lumit_core::model::LayerKind::Camera {
                zoom: Property::fixed(f64::from(comp.width) * 50.0 / 36.0),
            },
            comp.duration.0,
            TransformGroup {
                position_x: Property::fixed(f64::from(comp.width) * 0.5),
                position_y: Property::fixed(f64::from(comp.height) * 0.5),
                ..TransformGroup::default()
            },
        );
        self.add_at_top(layer)
    }

    /// Add an Adjustment layer: a comp-sized effect container with no source of
    /// its own, centred so scale and rotation pivot about the middle.
    #[frb(sync)]
    pub fn add_adjustment_layer(&self) -> Result<LayerReference, BridgeError> {
        let comp = self.composition()?;
        let layer = crate::edits::base_layer(
            "Adjustment".into(),
            lumit_core::model::LayerKind::Adjustment,
            comp.duration.0,
            crate::edits::centred_transform(
                f64::from(comp.width),
                f64::from(comp.height),
                comp.width,
                comp.height,
            ),
        );
        self.add_at_top(layer)
    }

    /// Add a Null layer: an invisible layer with no source of its own, carrying
    /// only a transform, for parenting rigs. It has no size, so only its
    /// position is centred and the anchor stays at the origin.
    #[frb(sync)]
    pub fn add_null_layer(&self) -> Result<LayerReference, BridgeError> {
        use lumit_core::anim::Property;
        use lumit_core::model::TransformGroup;

        let comp = self.composition()?;
        let layer = crate::edits::base_layer(
            "Null".into(),
            lumit_core::model::LayerKind::Null,
            comp.duration.0,
            TransformGroup {
                position_x: Property::fixed(f64::from(comp.width) * 0.5),
                position_y: Property::fixed(f64::from(comp.height) * 0.5),
                ..TransformGroup::default()
            },
        );
        self.add_at_top(layer)
    }

    /// Add an empty Sequence layer — a clip row spanning the comp.
    #[frb(sync)]
    pub fn add_sequence_layer(&self) -> Result<LayerReference, BridgeError> {
        let comp = self.composition()?;
        let layer = crate::edits::base_layer(
            "Sequence".into(),
            lumit_core::model::LayerKind::Sequence { clips: Vec::new() },
            comp.duration.0,
            crate::edits::centred_transform(
                f64::from(comp.width),
                f64::from(comp.height),
                comp.width,
                comp.height,
            ),
        );
        self.add_at_top(layer)
    }

    /// The comp's work area — the span the Viewer previews and the export
    /// writes — or `None` for the whole comp.
    #[frb(sync)]
    pub fn get_work_area(&self) -> Result<Option<BridgeSpan>, BridgeError> {
        Ok(self.composition()?.work_area.map(|(a, b)| BridgeSpan {
            in_point: BridgeRational {
                num: a.0.num(),
                den: a.0.den(),
            },
            out_point: BridgeRational {
                num: b.0.num(),
                den: b.0.den(),
            },
            // A work area has no content of its own to slip, so this is always
            // zero; the field is shared with a layer span for one type.
            start_offset: BridgeRational { num: 0, den: 1 },
        }))
    }

    /// Set the work area, or clear it with `None`.
    #[frb(sync)]
    pub fn set_work_area(&self, span: Option<BridgeSpan>) -> Result<(), BridgeError> {
        use lumit_core::time::{CompTime, Rational};
        let work_area = match span {
            None => None,
            Some(span) => {
                let a = Rational::new(span.in_point.num, span.in_point.den)
                    .map_err(|_| BridgeError::InvalidTime)?;
                let b = Rational::new(span.out_point.num, span.out_point.den)
                    .map_err(|_| BridgeError::InvalidTime)?;
                Some((CompTime(a), CompTime(b)))
            }
        };
        self.commit(lumit_core::Op::SetWorkArea {
            comp: self.id,
            work_area,
        })
    }

    /// Every marker on this comp, in the order the document holds them.
    #[frb(sync)]
    pub fn get_markers(&self) -> Result<Vec<BridgeMarker>, BridgeError> {
        Ok(self
            .composition()?
            .markers
            .iter()
            .map(|m| BridgeMarker {
                id: m.id,
                time: BridgeRational {
                    num: m.time.0.num(),
                    den: m.time.0.den(),
                },
                label: m.label.clone(),
            })
            .collect())
    }

    /// Replace the whole marker list — one op, trivially invertible, which is
    /// also how beat detection commits a regenerated set.
    #[frb(sync)]
    pub fn set_markers(&self, markers: Vec<BridgeMarker>) -> Result<(), BridgeError> {
        use lumit_core::markers::Marker;
        use lumit_core::time::{CompTime, Rational};

        let markers = markers
            .into_iter()
            .map(|m| {
                Ok(Marker {
                    id: m.id,
                    time: CompTime(
                        Rational::new(m.time.num, m.time.den)
                            .map_err(|_| BridgeError::InvalidTime)?,
                    ),
                    duration: None,
                    label: m.label,
                    kind: lumit_core::markers::MarkerKind::default(),
                    extra: serde_json::Map::new(),
                })
            })
            .collect::<Result<Vec<_>, BridgeError>>()?;

        self.commit(lumit_core::Op::SetCompMarkers {
            comp: self.id,
            markers,
        })
    }

    /// Insert `layer` at the top of the stack.
    #[frb(ignore)]
    fn add_at_top(&self, layer: lumit_core::model::Layer) -> Result<LayerReference, BridgeError> {
        let id = layer.id;
        self.commit(lumit_core::Op::AddLayer {
            comp: self.id,
            index: 0,
            layer: Box::new(layer),
        })?;
        Ok(LayerReference::new(self.project, self.id, id))
    }

    #[frb(ignore)]
    fn document(&self) -> Result<std::sync::Arc<lumit_core::Document>, BridgeError> {
        let proj = self.project()?;
        let proj = proj.read().map_err(|_| BridgeError::ReadFailed)?;
        Ok(proj.store.snapshot())
    }

    #[frb(ignore)]
    fn commit(&self, op: lumit_core::Op) -> Result<(), BridgeError> {
        let proj = self.project()?;
        let proj = proj.write().map_err(|_| BridgeError::WriteFailed)?;
        proj.store.commit(op).map_err(BridgeError::OpError)?;
        Ok(())
    }

    /// The composition this reference names, cloned out of the current snapshot.
    #[frb(ignore)]
    pub(crate) fn composition(&self) -> Result<lumit_core::model::Composition, BridgeError> {
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
    pub fn render_frame(
        &self,
        frame: u64,
        scale: f32,
        mode: BridgePlaybackMode,
    ) -> Result<(), BridgeError> {
        self.dispatch(RenderComp(RenderCompRequest {
            comp: self.clone(),
            frame,
            scale,
            mode,
        }))
    }

    /// Play from `from` at this comp's own rate, with sound.
    ///
    /// The frontend calls this and then paints whatever frames arrive: each one
    /// says which frame it is, so the transport and the playhead follow the
    /// picture rather than predicting it. Playback stops when the frontend says
    /// so ([`Self::stop_playback`]) or when it runs off the end, which arrives as
    /// `WorkerResponse::PlaybackEnded`.
    ///
    /// The sound is started here too, so "play" is one call rather than a pair
    /// the frontend has to keep in step — in BOTH modes. Every-frame used to
    /// play silent outright, which was coarser than K-171 asks for: sound
    /// plays while rendering keeps the comp's rate (which, cached, it mostly
    /// does now), and the worker PAUSES it if the picture falls genuinely
    /// behind — a paused track is honest, a drifting one is a lie in sync's
    /// clothing. Timestretch-to-match is K-171's recorded "later".
    ///
    /// `mode` comes from the frontend because it is a user *setting*, kept in the
    /// workspace file the frontend owns — stating it is not deciding anything.
    #[frb(sync)]
    pub fn play(&self, from: u64, scale: f32, mode: BridgePlaybackMode) -> Result<(), BridgeError> {
        // The mix's document is snapshotted HERE — it must be the comp as it
        // was when play was pressed — but the sound is started by the worker,
        // once it has banked a frame or two to start alongside it (the
        // pre-roll, docs/impl/playback-scheduler.md §5). Starting it here meant
        // the sound ran while the first frame was still being composited, and
        // adaptive playback then skipped to catch up: every press of play began
        // with a jump.
        let audio = {
            let state = self.project()?;
            let state = state.read().map_err(|_| BridgeError::ReadFailed)?;
            state.store.snapshot()
        };
        // Building the mix means decoding, which is slow and asynchronous, so it
        // is kicked off HERE rather than after the pre-roll: the decode then
        // overlaps the first renders instead of following them. Only the "now
        // play" waits. A prepare of a mix already loaded is recognised by its
        // signature and costs nothing.
        self.audio_prepare()?;

        self.dispatch(WorkerRequest::Play(
            crate::api::worker_thread::PlayRequest {
                comp: self.clone(),
                from,
                mode,
                scale,
                audio,
            },
        ))
    }

    /// Stop playing, and silence the sound. Harmless when nothing is playing.
    #[frb(sync)]
    pub fn stop_playback(&self) -> Result<(), BridgeError> {
        crate::api::audio::audio_pause();
        self.dispatch(WorkerRequest::StopPlayback)
    }

    /// This composition's rate as a plain number, for turning frames into
    /// seconds. Falls back to 60 for a comp with a nonsense rate rather than
    /// dividing by zero.
    #[frb(sync)]
    pub fn fps(&self) -> f64 {
        self.composition()
            .map(|c| c.frame_rate.fps())
            .ok()
            .filter(|fps| *fps > 0.0)
            .unwrap_or(60.0)
    }

    /// The preview tier adaptive playback has settled on: 1 Full, 2 Half,
    /// 3 Third, 4 Quarter. Shown beside the mode so "why is it soft?" has an
    /// answer on screen rather than in a log.
    #[frb(sync)]
    pub fn playback_tier(&self) -> u32 {
        crate::realtime::tier()
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
            text: None,
        }))
    }

    /// The exact time frame `frame` starts at, as the rational the document
    /// stores.
    ///
    /// Exposed rather than left to Dart because keyframe times must be exact
    /// (docs/14 §2): at 29.97 fps a frame is 1001/30000 s, and a panel that
    /// worked that out in floating point would place keys that do not land on
    /// the frame they were set on. This is the engine's own
    /// `FrameRate::time_of_frame`, so there is one implementation of it.
    #[frb(sync)]
    pub fn time_of_frame(&self, frame: i64) -> Result<BridgeRational, BridgeError> {
        let comp = self.composition()?;
        let time = comp
            .frame_rate
            .time_of_frame(frame)
            .map_err(|_| BridgeError::InvalidComp)?;
        Ok(BridgeRational {
            num: time.0.num(),
            den: time.0.den(),
        })
    }

    /// The frame containing `time` (floored) — the inverse of
    /// [`Self::time_of_frame`], for drawing a key at a frame position.
    #[frb(sync)]
    pub fn frame_at_time(&self, time: BridgeRational) -> Result<i64, BridgeError> {
        let comp = self.composition()?;
        let rational = lumit_core::time::Rational::new(time.num, time.den)
            .map_err(|_| BridgeError::InvalidComp)?;
        Ok(comp
            .frame_rate
            .frame_at(lumit_core::time::CompTime(rational)))
    }

    /// Ask the worker for a scope trace of `frame`.
    ///
    /// `kind` is the trace: 0 waveform, 1 parade, 2 vectorscope, 3 histogram.
    /// `colours` is background, trace, then the R, G and B tints, each as
    /// `[r, g, b]` — the panel's theme decides them, so the engine never has to
    /// know what a Lumit surface looks like.
    #[frb(sync)]
    pub fn render_scope(
        &self,
        frame: u64,
        scale: f32,
        kind: u32,
        colours: Vec<Vec<u8>>,
    ) -> Result<(), BridgeError> {
        // Five triples, and anything else is a caller bug rather than something
        // to pad out with a colour nobody chose.
        if colours.len() != 5 || colours.iter().any(|c| c.len() != 3) {
            return Err(BridgeError::InvalidScopeColours);
        }
        let mut packed = [[0_u8; 3]; 5];
        for (slot, colour) in packed.iter_mut().zip(&colours) {
            slot.copy_from_slice(colour);
        }

        self.dispatch(WorkerRequest::TraceScope(RenderScopeRequest {
            comp: self.clone(),
            frame,
            scale,
            kind,
            colours: packed,
        }))
    }

    /// Ask the worker for the pixels under the dropper: a `window × window`
    /// square of `frame` centred on the point `(u, v)` of the picture, each a
    /// fraction from 0 to 1 (docs/07 §6.1).
    ///
    /// **A fraction, not a pixel, and that is the point.** The picture actually
    /// read may be a reduced-resolution preview, so its pixel grid is neither
    /// the composition's nor anything the caller can know in advance. The reply
    /// says which raster it cut from (`width`, `height`) and where in that
    /// raster the window's centre landed, and every pixel the caller then names
    /// is in that same raster. Asking in composition pixels and indexing the
    /// reply with them is a real bug that has been made unwritable here: with a
    /// fitted Viewer the two grids differ by the preview scale, and the
    /// magnifier showed one repeated edge pixel — a flat colour where the
    /// picture should be.
    ///
    /// A window rather than the nine pixels the magnifier shows, because the
    /// pointer moves and the picture does not: the caller reads its grid out of
    /// the window it already holds and asks again only when the pointer nears
    /// the window's edge, the frame changes, or an edit lands.
    ///
    /// `layer` reads that layer **alone** rather than the composite — what a
    /// depth pick does, since a depth pass is usually hidden and so never
    /// appears in the composite at all. The answer arrives as
    /// `WorkerResponse::Sampled`, on the stream the frames and traces already
    /// ride; a frame with nothing to read publishes nothing, and the magnifier
    /// keeps what it had.
    #[frb(sync)]
    pub fn sample_pixels(
        &self,
        frame: u64,
        u: f64,
        v: f64,
        window: u32,
        scale: f32,
        layer: Option<LayerReference>,
    ) -> Result<(), BridgeError> {
        self.dispatch(WorkerRequest::SamplePixels(SamplePixelsRequest {
            comp: self.clone(),
            frame,
            scale,
            u,
            v,
            window,
            layer,
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
            text: None,
        }))
    }

    /// Ask for `frame` with `layer`'s text document replaced by `document` —
    /// the same live path as the two above, for the Type tool (K-225).
    ///
    /// Typing is the one edit where the provisional value changes many times a
    /// second and the document must *not*: a `set_text` per keystroke would be
    /// an undo step per keystroke. So the tool previews as it types and writes
    /// once, when the edit ends.
    #[frb(sync)]
    pub fn render_frame_with_text_preview(
        &self,
        frame: u64,
        scale: f32,
        layer: LayerReference,
        document: crate::api::assets::BridgeTextDocument,
    ) -> Result<(), BridgeError> {
        self.dispatch(RenderCompWithPreview(RenderCompRequestWithPreview {
            comp: self.clone(),
            frame,
            scale,
            layer,
            effects: None,
            transform: None,
            text: Some(document),
        }))
    }
}
