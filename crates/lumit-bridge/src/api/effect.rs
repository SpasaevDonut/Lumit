use std::sync::Arc;

use flutter_rust_bridge::frb;
pub use lumit_core::model::EffectInstance;
use lumit_core::{anim::Property, model::EffectValue};
use serde_json::json;
use uuid::Uuid;

#[frb(opaque)]
pub struct BridgeEffectInstance {
    effect: EffectInstance,
}

// Temp hacky way to do this quickly, not sure the best way to pass this complex struct
// over to flutter, this will need improving
impl BridgeEffectInstance {
    pub fn new(effect: EffectInstance) -> BridgeEffectInstance {
        return BridgeEffectInstance { effect };
    }

    #[frb(sync)]
    pub fn name(&self) -> String {
        self.effect.effect.match_name.clone()
    }

    #[frb(ignore)]
    pub fn get_effects(&self) -> EffectInstance {
        return self.effect.clone()
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

    // TODO: properly handle this with a data type that can be sent to flutter
    #[frb(sync)]
    pub fn get_value(&mut self, id: String) -> f64 {
        let param = &self
            .effect
            .params
            .iter()
            .filter(|f| f.id == id)
            .nth(0)
            .unwrap();

        match &param.value {
            lumit_core::model::EffectValue::Float(property) => match &property.animation {
                lumit_core::anim::Animation::Static(v) => v.clone(),
                lumit_core::anim::Animation::Keyframed(keyframes) => 0.0,
            },
            lumit_core::model::EffectValue::Point(property, property1) => 0.0,
            lumit_core::model::EffectValue::Colour(_) => 0.0,
            lumit_core::model::EffectValue::Bool(_) => 0.0,
            lumit_core::model::EffectValue::Choice(_) => 0.0,
            lumit_core::model::EffectValue::Seed(_) => 0.0,
            lumit_core::model::EffectValue::File(file_param) => 0.0,
            lumit_core::model::EffectValue::Layer(uuid) => 0.0,
        }
    }

    // TODO: properly handle this with a data type that can be sent to flutter
    #[frb(sync)]
    pub fn set_value(&mut self, id: String, value: f64) {
        let i = self.effect.params.iter().position(|i| i.id == id).unwrap();

        self.effect.params[i].value = EffectValue::Float(Property::fixed(value))
    }
}
