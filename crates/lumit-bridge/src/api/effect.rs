use flutter_rust_bridge::frb;
pub use lumit_core::model::EffectInstance;
use lumit_core::{
    anim::{Animation, Property},
    model::{EffectParam, EffectValue},
};
use serde_json::json;

use crate::api::BridgeError;

#[frb(opaque)]
pub struct BridgeEffectInstance {
    effect: EffectInstance,
}

// Temp hacky way to do this quickly, not sure the best way to pass this complex struct
// over to flutter, this will need improving
impl BridgeEffectInstance {
    pub fn new(effect: EffectInstance) -> BridgeEffectInstance {
        BridgeEffectInstance { effect }
    }

    #[frb(sync)]
    pub fn name(&self) -> String {
        self.effect.effect.match_name.clone()
    }

    #[frb(ignore)]
    pub fn get_effects(&self) -> EffectInstance {
        return self.effect.clone();
    }

    #[frb(sync)]
    pub fn serialize(&self) -> String {
        let serialized = json!(&self.effect);
        serialized.to_string()
    }

    #[frb(sync)]
    pub fn get_parameters(&self) -> Vec<String> {
        self.effect
            .params
            .iter()
            .map(|f| f.id.to_string())
            .collect()
    }

    /// A parameter's static scalar value.
    ///
    /// Only `Float` is carried so far, and only its static value: the other
    /// seven `EffectValue` shapes (point, colour, bool, choice, seed, file,
    /// layer) and the keyframed case have no Dart-side representation yet, so
    /// they answer `None` rather than silently reading as 0.0 — a colour
    /// parameter rendering as "0" is worse than one rendering as blank.
    ///
    /// TODO: replace this with a sum type mirroring `EffectValue`, so every
    /// parameter kind is expressible. Tracked in docs/TODO.md under "Bridge".
    #[frb(sync)]
    pub fn get_value(&self, id: String) -> Result<Option<f64>, BridgeError> {
        let param = self.param(&id)?;

        Ok(match &param.value {
            EffectValue::Float(property) => match &property.animation {
                Animation::Static(v) => Some(*v),
                Animation::Keyframed(_) => None,
            },
            EffectValue::Point(..)
            | EffectValue::Colour(_)
            | EffectValue::Bool(_)
            | EffectValue::Choice(_)
            | EffectValue::Seed(_)
            | EffectValue::File(_)
            | EffectValue::Layer(_) => None,
        })
    }

    /// Overwrite a parameter with a static scalar. Same limitation as
    /// [`Self::get_value`]: it can only express `Float`, so calling it on a
    /// parameter of another kind would change its type. It therefore refuses
    /// rather than corrupting the effect.
    #[frb(sync)]
    pub fn set_value(&mut self, id: String, value: f64) -> Result<(), BridgeError> {
        let index = self
            .effect
            .params
            .iter()
            .position(|p| p.id == id)
            .ok_or(BridgeError::InvalidParam)?;

        if !matches!(self.effect.params[index].value, EffectValue::Float(_)) {
            return Err(BridgeError::UnsupportedParamKind);
        }

        self.effect.params[index].value = EffectValue::Float(Property::fixed(value));
        Ok(())
    }

    #[frb(ignore)]
    fn param(&self, id: &str) -> Result<&EffectParam, BridgeError> {
        self.effect
            .params
            .iter()
            .find(|p| p.id == id)
            .ok_or(BridgeError::InvalidParam)
    }
}
