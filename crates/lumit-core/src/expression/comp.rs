use rhai::{plugin::*, TypeBuilder};
use uuid::Uuid; // a "prelude" import for macros

#[export_module]
pub mod comp {
    use std::{eprintln, sync::Arc};

    use crate::expression::ExpressionContext;

    #[derive(Clone, CustomType)]
    pub struct Comp {
        id: Option<Uuid>,
    }

    /// get the current composition
    pub fn comp(context: NativeCallContext) -> Comp {
        let tag = context.engine().default_tag();

        let context = tag.clone_cast::<Arc<ExpressionContext>>();

        match context.comp {
            Some(comp) => Comp { id: Some(comp) },
            None => Comp { id: None },
        }
    }

    pub fn name(context: NativeCallContext, this: &mut Comp) -> String {
        let tag = context.engine().default_tag();
        let context = tag.clone_cast::<Arc<ExpressionContext>>();
        
        if let Some(id) = this.id {
            if let Some(comp) = context.document.comp(id) {
                return comp.name.clone();
            }
        }
        
        "Invalid Comp Reference".into()
    }
}
