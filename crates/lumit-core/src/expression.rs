use std::{eprintln, println};

use crate::{Document, Rational};
use rhai::{Dynamic, Engine, Scope};
use uuid::Uuid;

pub struct ExpressionContext<'a> {
    pub document: &'a Document,
    pub comp: Option<Uuid>,
    pub layer: Option<Uuid>,
}

pub fn evaluate(expression: &String, time: f64, context: Option<&ExpressionContext>) -> f64 {
    let engine = Engine::new();

    let mut scope = Scope::new();

    scope.push_constant("time", time);

    match context {
        Some(context) => {
            // TODO: figure out how to access context state from engine context
            // engine.set_default_tag( Dynamic:: Box::new(context));
            apply_context_to_scope(&mut scope, context);
        }
        None => (),
    }

    let result = engine.eval_expression_with_scope::<Dynamic>(&mut scope, &expression);

    convert_result(result)
}

pub fn evaluate_range(
    expression: &String,
    context: Option<&ExpressionContext>,
    start: f64,
    end: f64,
    samples: i64,
) -> Vec<f64> {
    let engine = Engine::new();

    let mut scope = Scope::new();

    match context {
        Some(context) => {
            // TODO: figure out how to access context state from engine context
            // engine.set_default_tag( Dynamic:: Box::new(context));
            apply_context_to_scope(&mut scope, context);
        }
        None => (),
    }

    let compiled = engine.compile_expression_with_scope(&scope, &expression);

    let mut result: Vec<f64> = Vec::new();

    match compiled {
        Ok(ast) => {
            let delta = (end - start) / (samples as f64);
            for i in 0..samples {
                let time = start + (delta * (i as f64));

                let mut scope = scope.clone();

                scope.push_constant("time", time);

                let v = engine.eval_ast_with_scope::<Dynamic>(&mut scope, &ast);
                result.push(convert_result(v));
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

fn apply_context_to_scope(scope: &mut Scope<'_>, context: &ExpressionContext<'_>) {
    let doc = context.document;

    if let Some(comp_id) = context.comp {
        if let Some(comp) = doc.comp(comp_id) {
            scope.push_constant("comp_height", comp.height as i64);
            scope.push_constant("comp_width", comp.width as i64);
            scope.push_constant("comp_fps", comp.frame_rate.fps() as i64);
            scope.push_constant("num_markers", comp.markers.len() as i64);
            scope.push_constant("num_layers", comp.layers.len() as i64);

            if let Some(layer_id) = context.layer {
                if let Some(layer) = comp.layers.iter().find(|l| l.id == layer_id) {
                    scope.push_constant("cut_in", layer.in_point.0.to_f64());
                    scope.push_constant("cut_out", layer.out_point.0.to_f64());
                }
            }
        }
    }
}
