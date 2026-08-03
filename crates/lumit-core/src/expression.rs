use std::eprintln;
use std::sync::OnceLock;

use crate::Document;
use rhai::{Dynamic, Engine, Scope, exported_module};
use uuid::Uuid;

mod math;

pub struct ExpressionContext<'a> {
    pub document: &'a Document,
    pub comp: Option<Uuid>,
    pub layer: Option<Uuid>,
}

impl ExpressionContext<'_> {
    /// A context that offers nothing but `time` — for evaluations with no comp
    /// or layer behind them: a standalone preview of an expression, and the
    /// unit tests. The comp and layer constants are simply absent from the
    /// scope, so an expression that reads one fails visibly rather than
    /// quietly reading an invented number.
    pub fn detached() -> ExpressionContext<'static> {
        static EMPTY: OnceLock<Document> = OnceLock::new();
        ExpressionContext {
            document: EMPTY.get_or_init(Document::new),
            comp: None,
            layer: None,
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
    time: f64,
    context: Option<&ExpressionContext>,
) -> Result<Dynamic, Box<rhai::EvalAltResult>> {
    let engine = make_engine();

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

    engine.eval_expression_with_scope::<Dynamic>(&mut scope, expression)
}

pub fn evaluate(expression: &String, time: f64, context: Option<&ExpressionContext>) -> f64 {
    convert_result(eval_dynamic(expression, time, context))
}

/// Evaluate an expression for its **words** rather than its number — what a
/// text layer whose content is expression-driven shows at `time`.
///
/// In plain terms: the same expression language the numeric properties use,
/// except the answer is printed instead of measured. Every result type is
/// welcome — a number prints as a number, a string prints as itself — because
/// the point of the feature is putting a value on screen, and refusing a type
/// would just mean the user has to wrap it in a conversion.
///
/// A broken expression prints nothing. It cannot fail the frame: an unreadable
/// caption is a smaller problem than a render that stops, and the empty line is
/// the same signal the editor already shows for empty text.
pub fn evaluate_text(expression: &str, time: f64, context: Option<&ExpressionContext>) -> String {
    match eval_dynamic(expression, time, context) {
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

            if let Some(layer_id) = context.layer {
                if let Some(layer) = comp.layers.iter().find(|l| l.id == layer_id) {
                    scope.push_constant("cut_in", layer.in_point.0.to_f64());
                    scope.push_constant("cut_out", layer.out_point.0.to_f64());
                }
            }
        }
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use crate::model::{LinearColour, TextDocument};

    fn document(expression: Option<&str>) -> TextDocument {
        TextDocument {
            text: "typed".into(),
            expression: expression.map(str::to_owned),
            size: 48.0,
            fill: LinearColour([1.0, 1.0, 1.0, 1.0]),
            extra: serde_json::Map::new(),
        }
    }

    /// The point of the feature: a number reaches the screen as words.
    #[test]
    fn a_number_prints_as_words() {
        assert_eq!(evaluate_text("1 + 1", 0.0, None), "2");
        assert_eq!(evaluate_text("time", 3.0, None), "3.0");
        assert_eq!(evaluate_text("\"frame \" + 7", 0.0, None), "frame 7");
    }

    /// A broken expression prints nothing rather than failing the frame.
    #[test]
    fn a_broken_expression_prints_nothing() {
        assert_eq!(evaluate_text("this is not an expression", 0.0, None), "");
        assert_eq!(evaluate_text("no_such_variable", 0.0, None), "");
    }

    /// Without an expression the layer shows exactly what was typed, and the
    /// typed words survive underneath one that is set.
    #[test]
    fn the_typed_words_are_kept_and_restored() {
        let context = ExpressionContext::detached();
        assert_eq!(document(None).resolved_text(0.0, &context), "typed");
        let driven = document(Some("time * 2"));
        assert_eq!(driven.resolved_text(1.5, &context), "3.0");
        assert_eq!(driven.text, "typed");
    }

    /// The same expression at the same time gives the same line, on any
    /// machine and any run — the determinism rule, applied to words.
    #[test]
    fn resolution_is_deterministic() {
        let context = ExpressionContext::detached();
        let d = document(Some("noise(time) + time"));
        assert_eq!(
            d.resolved_text(2.0, &context),
            d.resolved_text(2.0, &context)
        );
        assert_ne!(
            d.resolved_text(2.0, &context),
            d.resolved_text(3.0, &context)
        );
    }

    /// A document written before expressions existed loads with none, and a
    /// document with one round-trips.
    #[test]
    fn the_field_is_optional_on_disk() {
        let old = r#"{"text":"hi","size":12.0,"fill":[1.0,1.0,1.0,1.0]}"#;
        let d: TextDocument = serde_json::from_str(old).unwrap();
        assert_eq!(d.expression, None);
        // Absent rather than null, so an untouched project file does not grow.
        assert!(!serde_json::to_string(&d).unwrap().contains("expression"));

        let driven = document(Some("time"));
        let json = serde_json::to_string(&driven).unwrap();
        assert_eq!(serde_json::from_str::<TextDocument>(&json).unwrap(), driven);
    }
}
