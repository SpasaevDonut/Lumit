use std::sync::OnceLock;
use std::{eprintln, println};

use crate::Document;
use rhai::{exported_module, Dynamic, Engine, Scope};
use uuid::Uuid;

mod math;

#[derive(Clone)]
pub struct ExpressionContext<'a> {
    pub document: &'a Document,
    pub comp: Option<Uuid>,
    pub layer: Option<Uuid>,
    pub time: f64,
}

impl ExpressionContext<'_> {
    pub fn detached() -> ExpressionContext<'static> {
        static EMPTY: OnceLock<Document> = OnceLock::new();
        ExpressionContext {
            document: EMPTY.get_or_init(Document::new),
            comp: None,
            layer: None,
            time: 0.0,
        }
    }
}

fn make_engine() -> Engine {
    let mut engine = Engine::new();
    let math = exported_module!(math::math);

    engine.register_global_module(math.into());

    engine
}

/// Run `expression` at `time` and hand back whatever it produced, untouched.
/// The typed wrappers below decide what to make of it.
fn eval_dynamic(
    expression: &str,
    context: Option<&ExpressionContext>,
) -> Result<Dynamic, Box<rhai::EvalAltResult>> {
    let engine = make_engine();

    let mut scope = Scope::new();

    match context {
        Some(context) => {
            // TODO: figure out how to access context state from engine context
            // engine.set_default_tag( Dynamic:: Box::new(context));
            apply_context_to_scope(&mut scope, context);
        }
        None => (),
    }

    engine.eval_expression_with_scope::<Dynamic>(&mut scope, expression)
}

pub fn evaluate(expression: &String, context: Option<&ExpressionContext>) -> f64 {
    convert_result(eval_dynamic(expression, context))
}

pub fn evaluate_text(expression: &str, context: Option<&ExpressionContext>) -> String {
    match eval_dynamic(expression, context) {
        Ok(val) => val.to_string(),
        Err(e) => {
            eprintln!("Expression error: {:?}", e.unwrap_inner());
            String::new()
        }
    }
}

pub fn evaluate_range(
    expression: &String,
    context: Option<&ExpressionContext>,
    start: f64,
    end: f64,
    samples: i64,
) -> Vec<f64> {
    let engine = make_engine();

    let compiled = engine.compile_expression(&expression);

    let mut result: Vec<f64> = Vec::new();

    match compiled {
        Ok(ast) => {
            let delta = (end - start) / (samples as f64);
            for i in 0..samples {
                let time = start + (delta * (i as f64));

                let mut scope = Scope::new();
                let mut ctx = context.cloned();

                match ctx.as_mut() {
                    Some(ctx) => {
                        ctx.time = time;
                        apply_context_to_scope(&mut scope, ctx);
                    }
                    None => (),
                }

                let v = engine.eval_ast_with_scope::<Dynamic>(&mut scope, &ast);
                let v = convert_result(v);
                result.push(v);
            }
        }
        Err(_) => todo!(),
    }

    result
}

fn convert_result(result: Result<Dynamic, Box<rhai::EvalAltResult>>) -> f64 {
    match result {
        Ok(val) => {
            if val.is_float() {
                return val.as_float().unwrap();
            }

            if val.is_int() {
                let val = val.as_int().unwrap();
                return val as f64;
            }

            if val.is_bool() {
                return match val.as_bool().unwrap() {
                    true => 1.0,
                    false => 0.0,
                };
            }

            eprintln!("Invalid expression result: {:?}", val.type_name());

            -1.0
        }
        Err(e) => {
            eprintln!("Expression error: {:?}", e.unwrap_inner());
            -1.0
        }
    }
}

pub fn get_api_metadata() -> String {
    let engine = make_engine();
    engine.gen_fn_metadata_to_json(false).unwrap()
}

fn apply_context_to_scope(scope: &mut Scope<'_>, context: &ExpressionContext<'_>) {
    let doc = context.document;

    if let Some(comp_id) = context.comp {
        if let Some(comp) = doc.comp(comp_id) {
            scope.push_constant("comp_height", comp.height as i64);
            scope.push_constant("comp_width", comp.width as i64);
            scope.push_constant("comp_fps", comp.frame_rate.fps() as i64);
            scope.push_constant("num_markers", comp.markers.len() as i64);
            scope.push_constant("num_layers", comp.layers.len() as i64);
            scope.push_constant("time", context.time);

            if let Some(layer_id) = context.layer {
                if let Some(layer) = comp.layers.iter().find(|l| l.id == layer_id) {
                    scope.push_constant("cut_in", layer.in_point.0.to_f64());
                    scope.push_constant("cut_out", layer.out_point.0.to_f64());
                }
            }
        }
    }
}