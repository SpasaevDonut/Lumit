use std::sync::Arc;

use rhai::{plugin::*, TypeBuilder};
use uuid::Uuid;

use crate::{
    expression::{layer, ExpressionContext},
    model,
};

#[derive(Clone, CustomType)]
pub struct Layer {
    comp_id: Option<Uuid>,
    layer_id: Option<Uuid>,
}

fn get_layer(context: &NativeCallContext, this: &Layer) -> Option<model::Layer> {
    let tag = context.engine().default_tag();
    let context = tag.clone_cast::<Arc<ExpressionContext>>();

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
    if let Some(layer) = get_layer(&context, this) {
        let tag = context.engine().default_tag();
        let context = tag.clone_cast::<Arc<ExpressionContext>>();

        return context.comp_time - layer.in_point.0.to_f64();
    }

    -1.0
}

#[export_module]
pub mod layers {
    use std::{eprintln, sync::Arc};


    use Layer;

    /// get the current layer
    pub fn layer(context: NativeCallContext) -> Layer {
        let tag = context.engine().default_tag();

        let context = tag.clone_cast::<Arc<ExpressionContext>>();

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
        let tag = context.engine().default_tag();

        let context = tag.clone_cast::<Arc<ExpressionContext>>();

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
        if let Some(layer) = get_layer(&context, this) {
            let t = _time(&context, this);

            let tag = context.engine().default_tag();
            let context = tag.clone_cast::<Arc<ExpressionContext>>();

            let mut context = context.increase_depth();
            context.layer = this.layer_id;
            let c = Arc::new(context);

            let x = layer
                .transform
                .position_x
                .value_at_with_context(t, c.clone());
            return x;
        }

        -1.0
    }

    /// y coordinate of the layer's position
    #[rhai_fn(get = "y")]
    pub fn y(context: NativeCallContext, this: &mut Layer) -> f64 {
        if let Some(layer) = get_layer(&context, this) {
            let t = _time(&context, this);

            let tag = context.engine().default_tag();
            let context = tag.clone_cast::<Arc<ExpressionContext>>();

            let mut context = context.increase_depth();
            context.layer = this.layer_id;
            let c = Arc::new(context);
            let y = layer
                .transform
                .position_y
                .value_at_with_context(t, c.clone());
            return y;
        }

        -1.0
    }

    /// value of the layer's rotation
    #[rhai_fn(get = "rotation")]
    pub fn rotation(context: NativeCallContext, this: &mut Layer) -> f64 {
        if let Some(layer) = get_layer(&context, this) {
            let t = _time(&context, this);

            let tag = context.engine().default_tag();
            let context = tag.clone_cast::<Arc<ExpressionContext>>();

            let mut context = context.increase_depth();
            context.layer = this.layer_id;
            let c = Arc::new(context);
            let r = layer.transform.rotation.value_at_with_context(t, c.clone());
            return r;
        }

        -1.0
    }

    /// x component of the layer's scale
    #[rhai_fn(get = "scale_x")]
    pub fn scale_x(context: NativeCallContext, this: &mut Layer) -> f64 {
        if let Some(layer) = get_layer(&context, this) {
            let t = _time(&context, this);

            let tag = context.engine().default_tag();
            let context = tag.clone_cast::<Arc<ExpressionContext>>();

            let mut context = context.increase_depth();
            context.layer = this.layer_id;
            let c = Arc::new(context);
            let v = layer.transform.scale_x.value_at_with_context(t, c.clone());
            return v;
        }

        -1.0
    }

    /// y component of the layer's scale
    #[rhai_fn(get = "scale_y")]
    pub fn scale_y(context: NativeCallContext, this: &mut Layer) -> f64 {
        if let Some(layer) = get_layer(&context, this) {
            let t = _time(&context, this);

            let tag = context.engine().default_tag();
            let context = tag.clone_cast::<Arc<ExpressionContext>>();

            let mut context = context.increase_depth();
            context.layer = this.layer_id;
            let c = Arc::new(context);
            let v = layer.transform.scale_y.value_at_with_context(t, c.clone());
            return v;
        }

        -1.0
    }

    /// x coordinate of the layer's anchor
    #[rhai_fn(get = "anchor_x")]
    pub fn anchor_x(context: NativeCallContext, this: &mut Layer) -> f64 {
        if let Some(layer) = get_layer(&context, this) {
            let t = _time(&context, this);

            let tag = context.engine().default_tag();
            let context = tag.clone_cast::<Arc<ExpressionContext>>();

            let mut context = context.increase_depth();
            context.layer = this.layer_id;
            let c = Arc::new(context);
            let v = layer.transform.anchor_x.value_at_with_context(t, c.clone());
            return v;
        }

        -1.0
    }

    /// y coordinate of the layer's position
    #[rhai_fn(get = "anchor_y")]
    pub fn anchor_y(context: NativeCallContext, this: &mut Layer) -> f64 {
        if let Some(layer) = get_layer(&context, this) {
            let t = _time(&context, this);

            let tag = context.engine().default_tag();
            let context = tag.clone_cast::<Arc<ExpressionContext>>();

            let mut context = context.increase_depth();
            context.layer = this.layer_id;
            let c = Arc::new(context);
            let v = layer.transform.anchor_y.value_at_with_context(t, c.clone());
            return v;
        }

        -1.0
    }

    /// layer's current opacity
    #[rhai_fn(get = "opacity")]
    pub fn opacity(context: NativeCallContext, this: &mut Layer) -> f64 {
        if let Some(layer) = get_layer(&context, this) {
            let t = _time(&context, this);

            let tag = context.engine().default_tag();
            let context = tag.clone_cast::<Arc<ExpressionContext>>();

            let mut context = context.increase_depth();
            context.layer = this.layer_id;
            let c = Arc::new(context);

            let v = layer.transform.opacity.value_at_with_context(t, c.clone());
            return v;
        }

        -1.0
    }
}
