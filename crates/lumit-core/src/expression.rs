use std::eprintln;

use crate::Rational;
use rhai::{Dynamic, Engine, Scope};

pub fn evaluate(expression: &String, time: f64) -> f64 {
    let engine = Engine::new();

    let mut scope = Scope::new();

    scope.push_constant("time", time);

    let result = engine.eval_expression_with_scope::<Dynamic>(&mut scope, &expression);

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
                }
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
