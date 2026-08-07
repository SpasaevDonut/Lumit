use std::sync::Arc;

use rhai::plugin::*;
use uuid::Uuid;

use crate::{expression::ExpressionContext, model};

#[derive(Clone, CustomType)]
pub struct Layer {
    comp_id: Option<Uuid>,
    layer_id: Option<Uuid>,
}

fn get_layer(context: &NativeCallContext, this: &Layer) -> Option<model::Layer> {
    let context = ExpressionContext::from_call(context);

    if let Some(id) = this.comp_id {
        if let Some(comp) = context.document.comp(id) {
            if let Some(layer_id) = this.layer_id {
                if let Some(layer) = comp.layers.iter().find(|l| l.id == layer_id) {
                    return Some(layer.clone());
                }
            }
        }
    }

    None
}

fn _time(context: &NativeCallContext, this: &mut Layer) -> f64 {
    if let Some(layer) = get_layer(context, this) {
        let context = ExpressionContext::from_call(context);

        return context.comp_time - layer.in_point.0.to_f64();
    }

    -1.0
}

/// One of the referenced layer's transform properties, evaluated at that
/// layer's own time.
///
/// Every property getter below is this same handful of steps with a different
/// field picked out, so they share it: find the layer, work out its local time,
/// and evaluate the property under a context that has been re-pointed at *that*
/// layer and stepped one level deeper — the depth is what stops two properties
/// that refer to each other from recursing forever.
fn transform_property(
    call: &NativeCallContext,
    this: &mut Layer,
    pick: impl Fn(&model::TransformGroup) -> &crate::anim::Property,
) -> f64 {
    let Some(layer) = get_layer(call, this) else {
        return -1.0;
    };

    let t = _time(call, this);

    let mut context = ExpressionContext::from_call(call).increase_depth();
    context.layer = this.layer_id;

    pick(&layer.transform).value_at_with_context(t, Arc::new(context))
}

// Rhai's `#[export_module]` expands to argument-unwrapping code of its own,
// which trips `clippy::unwrap_used` on the generated `&mut` receivers. The
// lint is about *our* unwraps, and there is no way to spell these differently
// short of dropping the macro, so it is switched off for the generated module
// only — not for the module's callers, and not for the helpers above.
#[allow(clippy::unwrap_used)]
#[export_module]
pub mod layers {
    use Layer;

    /// get the current layer
    pub fn layer(context: NativeCallContext) -> Layer {
        let context = ExpressionContext::from_call(&context);

        match context.comp {
            Some(comp) => match context.layer {
                Some(layer) => Layer {
                    comp_id: Some(comp),
                    layer_id: Some(layer),
                },
                None => Layer {
                    comp_id: None,
                    layer_id: None,
                },
            },
            None => Layer {
                comp_id: None,
                layer_id: None,
            },
        }
    }

    #[rhai_fn(name = "layer")]
    /// get a layer by name
    pub fn layer_by_name(context: NativeCallContext, name: String) -> Layer {
        let context = ExpressionContext::from_call(&context);

        match context.comp {
            Some(c) => {
                if let Some(comp) = context.document.comp(c) {
                    if let Some(layer) = comp.layers.iter().find(|f| f.name == name) {
                        return Layer {
                            comp_id: Some(comp.id),
                            layer_id: Some(layer.id),
                        };
                    }
                }

                Layer {
                    comp_id: None,
                    layer_id: None,
                }
            }
            None => Layer {
                comp_id: None,
                layer_id: None,
            },
        }
    }

    /// get the name of a layer
    #[rhai_fn(get = "name")]
    pub fn name(context: NativeCallContext, this: &mut Layer) -> String {
        if let Some(layer) = get_layer(&context, this) {
            return layer.name;
        }

        "Invalid Layer Reference".into()
    }

    /// get the current time of this layer
    #[rhai_fn(get = "time")]
    pub fn time(context: NativeCallContext, this: &mut Layer) -> f64 {
        _time(&context, this)
    }

    /// x coordinate of the layer's position
    #[rhai_fn(get = "x")]
    pub fn x(context: NativeCallContext, this: &mut Layer) -> f64 {
        transform_property(&context, this, |tr| &tr.position_x)
    }

    /// y coordinate of the layer's position
    #[rhai_fn(get = "y")]
    pub fn y(context: NativeCallContext, this: &mut Layer) -> f64 {
        transform_property(&context, this, |tr| &tr.position_y)
    }

    /// value of the layer's rotation
    #[rhai_fn(get = "rotation")]
    pub fn rotation(context: NativeCallContext, this: &mut Layer) -> f64 {
        transform_property(&context, this, |tr| &tr.rotation)
    }

    /// x component of the layer's scale
    #[rhai_fn(get = "scale_x")]
    pub fn scale_x(context: NativeCallContext, this: &mut Layer) -> f64 {
        transform_property(&context, this, |tr| &tr.scale_x)
    }

    /// y component of the layer's scale
    #[rhai_fn(get = "scale_y")]
    pub fn scale_y(context: NativeCallContext, this: &mut Layer) -> f64 {
        transform_property(&context, this, |tr| &tr.scale_y)
    }

    /// x coordinate of the layer's anchor
    #[rhai_fn(get = "anchor_x")]
    pub fn anchor_x(context: NativeCallContext, this: &mut Layer) -> f64 {
        transform_property(&context, this, |tr| &tr.anchor_x)
    }

    /// y coordinate of the layer's anchor
    #[rhai_fn(get = "anchor_y")]
    pub fn anchor_y(context: NativeCallContext, this: &mut Layer) -> f64 {
        transform_property(&context, this, |tr| &tr.anchor_y)
    }

    /// layer's current opacity
    #[rhai_fn(get = "opacity")]
    pub fn opacity(context: NativeCallContext, this: &mut Layer) -> f64 {
        transform_property(&context, this, |tr| &tr.opacity)
    }
}
