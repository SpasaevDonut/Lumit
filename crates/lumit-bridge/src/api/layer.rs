use std::sync::Arc;

use flutter_rust_bridge::frb;
use lumit_core::model::{EffectInstance, Layer};

use uuid::Uuid;

use crate::api::{
    effect::{BridgeEffectInstance, BridgeScalar},
    state::{LumitBridgeState, PROJECTS},
    BridgeError,
};

/// A layer's whole transform, one scalar per property.
///
/// Read as a group rather than a property at a time because the panel draws them
/// as a group and a drag on one axis previews the others unchanged — eleven
/// round trips per frame to rebuild what one call already has would be the
/// snapshot habit creeping back in. Writing is per-property (see
/// [`LayerReference::set_transform`]), which is what keeps each edit exactly
/// invertible.
#[frb(non_opaque)]
#[derive(Debug, Clone, PartialEq)]
pub struct BridgeTransform {
    pub anchor_x: BridgeScalar,
    pub anchor_y: BridgeScalar,
    pub position_x: BridgeScalar,
    pub position_y: BridgeScalar,
    /// The 2.5D depth (K-023). Present on every layer; only meaningful, and only
    /// drawn, when the layer's 3D switch is on.
    pub position_z: BridgeScalar,
    /// Percent, 100 = natural size.
    pub scale_x: BridgeScalar,
    pub scale_y: BridgeScalar,
    /// Degrees, about z — the 2D rotation.
    pub rotation: BridgeScalar,
    pub rotation_x: BridgeScalar,
    pub rotation_y: BridgeScalar,
    /// Percent, 0..100.
    pub opacity: BridgeScalar,
}

/// Which transform property an edit names ([`lumit_core::model::TransformProp`]).
#[frb(non_opaque)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BridgeTransformProp {
    AnchorX,
    AnchorY,
    PositionX,
    PositionY,
    PositionZ,
    ScaleX,
    ScaleY,
    Rotation,
    RotationX,
    RotationY,
    Opacity,
}

impl BridgeTransformProp {
    #[frb(ignore)]
    pub(crate) fn core(self) -> lumit_core::model::TransformProp {
        use lumit_core::model::TransformProp as P;
        match self {
            BridgeTransformProp::AnchorX => P::AnchorX,
            BridgeTransformProp::AnchorY => P::AnchorY,
            BridgeTransformProp::PositionX => P::PositionX,
            BridgeTransformProp::PositionY => P::PositionY,
            BridgeTransformProp::PositionZ => P::PositionZ,
            BridgeTransformProp::ScaleX => P::ScaleX,
            BridgeTransformProp::ScaleY => P::ScaleY,
            BridgeTransformProp::Rotation => P::Rotation,
            BridgeTransformProp::RotationX => P::RotationX,
            BridgeTransformProp::RotationY => P::RotationY,
            BridgeTransformProp::Opacity => P::Opacity,
        }
    }
}

impl BridgeTransform {
    #[frb(ignore)]
    pub(crate) fn read(group: &lumit_core::model::TransformGroup) -> BridgeTransform {
        BridgeTransform {
            anchor_x: BridgeScalar::read(&group.anchor_x),
            anchor_y: BridgeScalar::read(&group.anchor_y),
            position_x: BridgeScalar::read(&group.position_x),
            position_y: BridgeScalar::read(&group.position_y),
            position_z: BridgeScalar::read(&group.position_z),
            scale_x: BridgeScalar::read(&group.scale_x),
            scale_y: BridgeScalar::read(&group.scale_y),
            rotation: BridgeScalar::read(&group.rotation),
            rotation_x: BridgeScalar::read(&group.rotation_x),
            rotation_y: BridgeScalar::read(&group.rotation_y),
            opacity: BridgeScalar::read(&group.opacity),
        }
    }

    /// Write this whole group onto `target`, for the drag preview — which needs
    /// a document to render, not an op to commit.
    #[frb(ignore)]
    pub(crate) fn write(
        &self,
        target: &mut lumit_core::model::TransformGroup,
    ) -> Result<(), BridgeError> {
        target.anchor_x.animation = self.anchor_x.animation()?;
        target.anchor_y.animation = self.anchor_y.animation()?;
        target.position_x.animation = self.position_x.animation()?;
        target.position_y.animation = self.position_y.animation()?;
        target.position_z.animation = self.position_z.animation()?;
        target.scale_x.animation = self.scale_x.animation()?;
        target.scale_y.animation = self.scale_y.animation()?;
        target.rotation.animation = self.rotation.animation()?;
        target.rotation_x.animation = self.rotation_x.animation()?;
        target.rotation_y.animation = self.rotation_y.animation()?;
        target.opacity.animation = self.opacity.animation()?;
        Ok(())
    }
}

#[derive(Debug)]
#[frb]
pub struct LayerReference {
    #[frb(name = "internalprojectId")]
    pub project_id: Uuid,

    #[frb(name = "internalcompId")]
    pub comp_id: Uuid,

    #[frb(name = "internallayerId")]
    pub layer_id: Uuid,
}

impl LayerReference {
    #[frb(ignore)]
    pub fn new(project_id: Uuid, comp_id: Uuid, layer_id: Uuid) -> LayerReference {
        LayerReference {
            project_id,
            comp_id,
            layer_id,
        }
    }

    #[frb(ignore)]
    pub fn project_id(&self) -> Uuid {
        self.project_id
    }

    #[frb(ignore)]
    pub fn comp_id(&self) -> Uuid {
        self.comp_id
    }

    #[frb(ignore)]
    pub fn id(&self) -> Uuid {
        self.layer_id
    }

    #[frb(ignore)]
    fn project(&self) -> Result<Arc<std::sync::RwLock<LumitBridgeState>>, BridgeError> {
        let projects = PROJECTS.read().map_err(|_| BridgeError::ReadFailed)?;
        let project = projects.get(&self.project_id);

        let p = project.ok_or(BridgeError::InvalidProject)?;
        Ok(p.clone())
    }

    /// The composition this layer lives in, cloned out of the current snapshot.
    /// The read lock is released by the time it returns, so a caller is free to
    /// take the write lock next.
    #[frb(ignore)]
    fn composition(&self) -> Result<lumit_core::model::Composition, BridgeError> {
        let proj = self.project()?;
        let proj = proj.read().map_err(|_| BridgeError::ReadFailed)?;
        let snapshot = proj.store.snapshot();

        match snapshot
            .item(self.comp_id)
            .ok_or(BridgeError::InvalidItem)?
        {
            lumit_core::model::ProjectItem::Composition(composition) => Ok(composition.clone()),
            _ => Err(BridgeError::InvalidItem),
        }
    }

    #[frb(ignore)]
    fn item(&self) -> Result<Layer, BridgeError> {
        self.composition()?
            .layers
            .into_iter()
            .find(|l| l.id == self.layer_id)
            .ok_or(BridgeError::InvalidLayer)
    }

    #[frb(sync)]
    pub fn equals(&self, layer: &LayerReference) -> bool {
        self.comp_id == layer.comp_id
            && self.project_id == layer.project_id
            && self.layer_id == layer.layer_id
    }

    #[frb(sync)]
    pub fn get_name(&self) -> Result<String, BridgeError> {
        let item = self.item()?;

        Ok(item.name)
    }

    #[frb(sync)]
    pub fn rename(&self, name: String) -> Result<(), BridgeError> {
        let proj = self.project()?;
        let proj = proj.write().map_err(|_| BridgeError::WriteFailed)?;

        proj.store
            .commit(lumit_core::Op::RenameLayer {
                comp: self.comp_id,
                layer: self.layer_id,
                name,
            })
            .map_err(BridgeError::OpError)?;

        Ok(())
    }

    /// Whether this layer positions in z and honours the active camera (K-023).
    ///
    /// Read-only for now: the switch's *toggle* is a Timeline op that has not
    /// been ported. The Effect controls panel needs the reader regardless, to
    /// decide whether to draw the z and x/y-rotation rows at all — a 2D layer
    /// showing 3D controls that do nothing is worse than not showing them. A
    /// camera is 3D by construction whatever its switch says.
    #[frb(sync)]
    pub fn is_three_d(&self) -> Result<bool, BridgeError> {
        let layer = self.item()?;
        Ok(layer.switches.three_d
            || matches!(layer.kind, lumit_core::model::LayerKind::Camera { .. }))
    }

    /// This layer's whole transform.
    #[frb(sync)]
    pub fn get_transform(&self) -> Result<BridgeTransform, BridgeError> {
        Ok(BridgeTransform::read(&self.item()?.transform))
    }

    /// Replace one transform property's whole animation, as one
    /// [`lumit_core::Op::SetTransformProperty`].
    ///
    /// One property per op, not the whole group: the op is exactly invertible
    /// that way, so a nudged Position is one undo step that puts back precisely
    /// what was there — where committing all eleven would make undo restore ten
    /// properties nobody touched.
    #[frb(sync)]
    pub fn set_transform(
        &self,
        prop: BridgeTransformProp,
        value: BridgeScalar,
    ) -> Result<(), BridgeError> {
        let animation = value.animation()?;
        // Confirm the layer is there before committing, so a stale reference is
        // a calm error rather than a failed op.
        self.item()?;

        let proj = self.project()?;
        let proj = proj.write().map_err(|_| BridgeError::WriteFailed)?;
        proj.store
            .commit(lumit_core::Op::SetTransformProperty {
                comp: self.comp_id,
                layer: self.layer_id,
                prop: prop.core(),
                animation,
            })
            .map_err(BridgeError::OpError)?;
        Ok(())
    }

    #[frb(sync)]
    pub fn get_effects(&self) -> Result<Vec<BridgeEffectInstance>, BridgeError> {
        let layer = self.item()?;

        Ok(layer
            .effects
            .iter()
            .map(|f| BridgeEffectInstance::new(f.clone()))
            .collect())
    }

    /// Read this layer's effect stack, let `edit` change a clone of it, and
    /// commit the result as a single [`lumit_core::Op::SetLayerEffects`].
    ///
    /// The shared tail of every stack op below, exactly as v0's
    /// `edits::with_effects` is: one user action becomes one op and therefore one
    /// undo step (docs/17 "commands down"), and the two frontends cannot drift
    /// apart on what an effect edit means.
    ///
    /// Unlike v0 there is no drag overlay to discard here. The frb preview lives
    /// in the render request (`CompositionReference::render_frame_with_preview`)
    /// rather than in a field beside the document, so a failed edit cannot leave
    /// a stale staged value laid over later frames — the bug v0 had to clear the
    /// overlay at the top of `with_effects` to avoid.
    #[frb(ignore)]
    fn with_effects(
        &self,
        edit: impl FnOnce(&mut Vec<EffectInstance>) -> Result<(), BridgeError>,
    ) -> Result<(), BridgeError> {
        let mut effects = self.item()?.effects;
        edit(&mut effects)?;

        let proj = self.project()?;
        let proj = proj.write().map_err(|_| BridgeError::WriteFailed)?;
        proj.store
            .commit(lumit_core::Op::SetLayerEffects {
                comp: self.comp_id,
                layer: self.layer_id,
                effects,
            })
            .map_err(BridgeError::OpError)?;
        Ok(())
    }

    /// Append the built-in effect named `name` to this layer's stack.
    ///
    /// Seeded at composition size, because a few effects' defaults are positions
    /// (a transform's anchor and position start at the centre of the frame), and
    /// a fresh effect should look like identity rather than dragging the picture
    /// to a corner. An unknown name is refused; nothing partial is committed.
    #[frb(sync)]
    pub fn add_effect(&self, name: String) -> Result<(), BridgeError> {
        let comp = self.composition()?;
        let instance = lumit_core::fx::instantiate_for_raster(
            &name,
            f64::from(comp.width),
            f64::from(comp.height),
        )
        .ok_or(BridgeError::UnknownEffectName)?;

        self.with_effects(move |effects| {
            effects.push(instance);
            Ok(())
        })
    }

    /// Remove `effect` from this layer's stack. An effect that is no longer there
    /// is an error rather than a silent success, so a double-click on Remove
    /// cannot look as though it deleted a second effect.
    #[frb(sync)]
    pub fn remove_effect(&self, effect: &BridgeEffectInstance) -> Result<(), BridgeError> {
        let id = effect.id();
        self.with_effects(move |effects| {
            let before = effects.len();
            effects.retain(|e| e.id != id);
            if effects.len() == before {
                return Err(BridgeError::InvalidEffect);
            }
            Ok(())
        })
    }

    /// Move `effect` to `new_index` in the stack — drag-to-reorder.
    ///
    /// The index clamps into range rather than failing: past the end lands the
    /// effect at the bottom, negative lands it at the top. A drag that overshoots
    /// the list is an ordinary thing for a pointer to do, and refusing it would
    /// leave the effect where it started with no explanation.
    #[frb(sync)]
    pub fn reorder_effect(
        &self,
        effect: &BridgeEffectInstance,
        new_index: i64,
    ) -> Result<(), BridgeError> {
        let id = effect.id();
        self.with_effects(move |effects| {
            let from = effects
                .iter()
                .position(|e| e.id == id)
                .ok_or(BridgeError::InvalidEffect)?;
            let instance = effects.remove(from);
            let to = usize::try_from(new_index).unwrap_or(0).min(effects.len());
            effects.insert(to, instance);
            Ok(())
        })
    }

    /// Enable or bypass `effect`. A bypassed effect renders as identity and is
    /// not animatable (docs/08 §1.5 — the effect's own Mix parameter is the
    /// animatable dial).
    #[frb(sync)]
    pub fn set_effect_enabled(
        &self,
        effect: &BridgeEffectInstance,
        enabled: bool,
    ) -> Result<(), BridgeError> {
        let id = effect.id();
        self.with_effects(move |effects| {
            let instance = effects
                .iter_mut()
                .find(|e| e.id == id)
                .ok_or(BridgeError::InvalidEffect)?;
            instance.enabled = enabled;
            Ok(())
        })
    }

    /// Commit a staged effect stack — the mouse-up for a gesture Dart has been
    /// editing through `BridgeEffectInstance::set_value` and previewing through
    /// `CompositionReference::render_frame_with_preview`. The whole drag becomes
    /// one undo step, which is the entire point of staging (docs/17 ABI v12).
    ///
    /// Only parameter *values* may cross this way: the staged stack must still
    /// name the same effects, in the same order, as the document does. Otherwise
    /// a stack read before some other action removed an effect from it would
    /// resurrect that effect on mouse-up, and reordering or deleting would have
    /// two paths — this one, which cannot say what it meant, and the dedicated
    /// ops above, which can.
    #[frb(sync)]
    pub fn set_effects(&self, effects: Vec<BridgeEffectInstance>) -> Result<(), BridgeError> {
        let staged: Vec<EffectInstance> = effects
            .iter()
            .map(BridgeEffectInstance::get_effects)
            .collect();

        self.with_effects(move |current| {
            let same_stack = current.len() == staged.len()
                && current.iter().zip(&staged).all(|(a, b)| a.id == b.id);
            if !same_stack {
                return Err(BridgeError::StaleEffectStack);
            }
            *current = staged;
            Ok(())
        })
    }
}
