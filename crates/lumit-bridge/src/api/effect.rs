//! One effect instance as the Effect controls panel reads and edits it, and the
//! parameter value type that carries every kind of parameter across the seam.
//!
//! # In plain terms
//!
//! An effect has parameters, and they are not all numbers: a blur has a radius
//! (a number), a fill has a colour, a tile has a centre point, a glow has an
//! on/off switch, a noise has a random seed, a dropdown has a chosen option, a
//! displacement map has a file, and a depth blur points at another layer. Any of
//! the number-shaped ones may also be *animated* — following a curve of
//! keyframes instead of holding one value.
//!
//! [`BridgeEffectValue`] is one type that can be any of those things, so the
//! panel can read a parameter without knowing in advance which kind it is, and
//! write it back without flattening it. Its rule is that reading and writing are
//! exact inverses: whatever comes out can go straight back in and the document is
//! unchanged. That is what lets the panel treat "read the value, change one
//! field, write it" as safe — the ordinary way every control in it works.

use std::{println, sync::Arc, todo};

use flutter_rust_bridge::frb;
pub use lumit_core::model::EffectInstance;
use lumit_core::{
    anim::{Animation, Keyframe, Property, SideInterp},
    expression::ExpressionContext,
    model::{EffectParam, EffectValue, FileParam},
    time::Rational,
};
use serde_json::json;
use uuid::Uuid;

use crate::api::{layer::LayerReference, state::PROJECTS, BridgeError};

/// One built-in effect as the Add-effect menu needs it: the stable `name` to
/// pass to [`crate::api::layer::LayerReference::add_effect`], the sentence-case
/// `label` to draw, and the category to group under. `category` is a stable
/// machine key the menu sorts by; `category_label` is its heading (K-090).
#[frb(non_opaque)]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeEffectInfo {
    pub name: String,
    pub label: String,
    pub category: String,
    pub category_label: String,
}

/// Every built-in effect, in schema order — the Add-effect menu's source of
/// truth ([`lumit_core::fx::BUILTINS`]), and the frb form of v0's `list_effects`.
///
/// Stateless, so it is a free function rather than a method: the menu is
/// available before any project is open.
#[frb(sync)]
pub fn list_effects() -> Vec<BridgeEffectInfo> {
    lumit_core::fx::BUILTINS
        .iter()
        .map(|schema| BridgeEffectInfo {
            name: schema.match_name.to_owned(),
            label: schema.label.to_owned(),
            // Shared with v0 rather than restated, so the two frontends cannot
            // disagree about which key a category has.
            category: crate::edits::fx_category_key(schema.category).to_owned(),
            category_label: schema.category.label().to_owned(),
        })
        .collect()
}

/// One saved `.lumfx` preset in the user's library: the display name it was
/// saved under and the file to read when applying it.
#[frb(non_opaque)]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgePresetInfo {
    pub name: String,
    pub path: String,
}

/// Every `.lumfx` in the preset library folder, sorted by name — what the
/// Effects & presets browser lists. A file that is not a preset (unreadable,
/// or not preset JSON) is simply not listed; the folder is the user's to put
/// things in, and a stray file there is not a fault.
#[frb(sync)]
pub fn list_presets() -> Vec<BridgePresetInfo> {
    lumit_project::presets_dir()
        .map(|dir| presets_in(&dir))
        .unwrap_or_default()
}

/// Where the preset library lives, created on first ask — the save dialogue's
/// default folder, so a saved preset appears in the listing without the user
/// navigating anywhere. `None` only when the platform has no home directory.
#[frb(sync)]
pub fn presets_dir_path() -> Option<String> {
    let dir = lumit_project::presets_dir()?;
    std::fs::create_dir_all(&dir).ok()?;
    Some(dir.to_string_lossy().into_owned())
}

/// The listing itself, on any folder — split from [`list_presets`] so the scan
/// is testable without touching the user's real library.
#[frb(ignore)]
pub(crate) fn presets_in(dir: &std::path::Path) -> Vec<BridgePresetInfo> {
    #[derive(serde::Deserialize)]
    struct Named {
        name: Option<String>,
        // Presence is the "is this actually a preset" check; the effects
        // themselves are parsed properly at load time.
        effects: serde_json::Value,
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut out: Vec<BridgePresetInfo> = entries
        .filter_map(|entry| {
            let path = entry.ok()?.path();
            if !path
                .extension()
                .is_some_and(|ext| ext.eq_ignore_ascii_case("lumfx"))
            {
                return None;
            }
            let text = std::fs::read_to_string(&path).ok()?;
            // It must at least be preset JSON with an effects list; the saved
            // display name wins, the file's stem stands in without one.
            let named: Named = serde_json::from_str(&text).ok()?;
            if !named.effects.is_array() {
                return None;
            }
            let name = named
                .name
                .filter(|n| !n.trim().is_empty())
                .or_else(|| Some(path.file_stem()?.to_string_lossy().into_owned()))?;
            Some(BridgePresetInfo {
                name,
                path: path.to_string_lossy().into_owned(),
            })
        })
        .collect();
    out.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    out
}

/// What `scalar` reads as at `time` — the value the picture is actually showing.
///
/// The panel needs this at exactly two moments, and both would be wrong done in
/// Dart. Turning animation *off* keeps the value the curve currently has, rather
/// than snapping to whatever the first key holds; adding a key at the playhead
/// seeds it with the value already on screen, so the act of adding a key never
/// moves the picture. Bezier keys make either one a real evaluation, not a
/// lerp — so this is the engine's own [`lumit_core::anim::evaluate`] rather than
/// a second implementation that would disagree with the renderer.
///
/// Sampling is in `f64` seconds, matching the engine: exactness is a property of
/// key *times* (which cross as integer pairs), not of a sampled value.
#[frb(sync)]
pub fn sample_scalar(scalar: BridgeScalar, time: BridgeRational) -> f64 {
    let seconds = if time.den == 0 {
        0.0
    } else {
        time.num as f64 / time.den as f64
    };
    match scalar {
        BridgeScalar::Static(value) => value,
        BridgeScalar::Keyframed(keys) => {
            let keys: Vec<Keyframe> = keys
                .iter()
                .map(|k| Keyframe {
                    time: Rational::new(k.time.num, k.time.den).unwrap_or(Rational::ZERO),
                    value: k.value,
                    interp_in: k.interp_in.write(),
                    interp_out: k.interp_out.write(),
                })
                .collect();
            lumit_core::anim::evaluate(&keys, seconds).unwrap_or(0.0)
        }
        BridgeScalar::Expression(expr) => lumit_core::expression::evaluate(
            &expr,
            None,
        ),
    }
}

#[frb(sync)]
pub fn sample_scalar_with_context(
    scalar: BridgeScalar,
    time: BridgeRational,
    layer: LayerReference,
) -> f64 {
    let seconds = if time.den == 0 {
        0.0
    } else {
        time.num as f64 / time.den as f64
    };
    match scalar {
        BridgeScalar::Static(value) => value,
        BridgeScalar::Keyframed(keys) => {
            let keys: Vec<Keyframe> = keys
                .iter()
                .map(|k| Keyframe {
                    time: Rational::new(k.time.num, k.time.den).unwrap_or(Rational::ZERO),
                    value: k.value,
                    interp_in: k.interp_in.write(),
                    interp_out: k.interp_out.write(),
                })
                .collect();
            lumit_core::anim::evaluate(&keys, seconds).unwrap_or(0.0)
        }
        BridgeScalar::Expression(expr) => {
            let projects = PROJECTS
                .read()
                .map_err(|_| BridgeError::ReadFailed)
                .unwrap();
            let project = projects.get(&layer.project_id).unwrap();

            let doc = project.read().unwrap();
            let doc = doc.store.snapshot();

            lumit_core::expression::evaluate(
                &expr,
                Some(Arc::new(ExpressionContext {
                    document: doc.clone(),
                    comp: Some(layer.comp_id),
                    layer: Some(layer.layer_id),
                    comp_time: Rational::new(time.num, time.den)
                        .unwrap_or(Rational::ZERO)
                        .to_f64(),
                        current_depth: 0,
                })),
            )
        }
    }
}

#[frb(sync)]
pub fn sample_scalar_range_with_context(
    scalar: BridgeScalar,
    layer: LayerReference,
    start: BridgeRational,
    end: BridgeRational,
    samples: i64,
) -> Vec<f64> {
    match scalar {
        BridgeScalar::Expression(expr) => {
            let projects = PROJECTS
                .read()
                .map_err(|_| BridgeError::ReadFailed)
                .unwrap();
            let project = projects.get(&layer.project_id).unwrap();

            let doc = project.read().unwrap();
            let doc = doc.store.snapshot();

            let start = Rational::new(start.num, start.den)
                .unwrap_or(Rational::ZERO)
                .to_f64();

            let end = Rational::new(end.num, end.den)
                .unwrap_or(Rational::ZERO)
                .to_f64();

            lumit_core::expression::evaluate_range(
                &expr,
                Some(&ExpressionContext {
                    document: doc.clone(),
                    comp: Some(layer.comp_id),
                    layer: Some(layer.layer_id),
                    comp_time: 0.0, // this time will be overwritten internally,
                    current_depth: 0,
                }),
                start,
                end,
                samples,
            )
        }
        _ => {
            todo!();
        }
    }
}

/// One declared parameter of an effect, as the panel needs to *draw* it:
/// what to call it, what kind of control it is, and the range or option list
/// that control needs.
///
/// This is the schema, not the value — [`BridgeEffectValue`] carries what a
/// particular instance currently holds. The panel needs both: the value to show,
/// and this to know whether "0.5" wants a slider from 0 to 100 or a colour
/// channel, and what the third entry in a dropdown is called.
#[frb(non_opaque)]
#[derive(Debug, Clone, PartialEq)]
pub struct BridgeParamInfo {
    /// Stable snake_case id — the key [`BridgeEffectInstance::get_value`] and
    /// `set_value` take.
    pub id: String,
    pub label: String,
    pub kind: BridgeParamKind,
}

/// What kind of control a parameter wants, and the numbers that control needs.
///
/// Mirrors [`lumit_core::fx::ParamKind`]. `Seed` and `Layer` carry nothing: a
/// seed is any `u32`, and a layer picker's options are the comp's own layers,
/// which the panel already has.
#[frb(non_opaque)]
#[derive(Debug, Clone, PartialEq)]
pub enum BridgeParamKind {
    Float {
        default: f64,
        /// The slider's travel. Typing may exceed it (docs/08 §1.2); only
        /// `hard_min`/`hard_max` may not.
        slider_min: f64,
        slider_max: f64,
        /// Hard bounds, either side open (K-090: a threshold clamps at zero
        /// below and runs unbounded above).
        hard_min: Option<f64>,
        hard_max: Option<f64>,
    },
    Choice {
        options: Vec<String>,
        default: u32,
        /// Option indices after which the dropdown draws a group divider (T21).
        /// Empty for an ungrouped list.
        dividers_after: Vec<u32>,
    },
    Bool {
        default: bool,
    },
    Colour {
        /// Scene-linear RGBA. Channels animate independently in the model, so
        /// the panel edits four scalars behind one swatch.
        default: Vec<f64>,
        /// Per-channel edit range — a linear value may exceed 1 (an HDR tint)
        /// or dip below 0 (a lift), so each colour declares its own.
        min: f64,
        max: f64,
    },
    Seed,
    File {
        /// Lower-case extensions without the dot, for the open dialog.
        filter: Vec<String>,
        filter_name: String,
    },
    Layer,
}

/// Every parameter `effect` declares, in schema order — what the panel draws a
/// row per.
///
/// Keyed by the same `match_name` [`list_effects`] hands out and `add_effect`
/// takes. An unknown name is an empty list rather than an error: a project
/// carrying an effect this build does not know still opens, and its instance
/// simply has no rows to draw.
#[frb(sync)]
pub fn list_parameters(effect: String) -> Vec<BridgeParamInfo> {
    use lumit_core::fx::ParamKind;

    let Some(schema) = lumit_core::fx::BUILTINS
        .iter()
        .find(|s| s.match_name == effect)
    else {
        return Vec::new();
    };

    schema
        .params
        .iter()
        .map(|param| BridgeParamInfo {
            id: param.id.to_owned(),
            label: param.label.to_owned(),
            kind: match param.kind {
                ParamKind::Float {
                    default,
                    slider,
                    hard,
                } => BridgeParamKind::Float {
                    default,
                    slider_min: slider.0,
                    slider_max: slider.1,
                    hard_min: hard.0,
                    hard_max: hard.1,
                },
                ParamKind::Choice {
                    options,
                    default,
                    dividers_after,
                } => BridgeParamKind::Choice {
                    options: options.iter().map(|o| (*o).to_owned()).collect(),
                    default,
                    dividers_after: dividers_after.to_vec(),
                },
                ParamKind::Bool { default } => BridgeParamKind::Bool { default },
                ParamKind::Colour { default, range } => BridgeParamKind::Colour {
                    default: default.to_vec(),
                    min: range.0,
                    max: range.1,
                },
                ParamKind::Seed => BridgeParamKind::Seed,
                ParamKind::File {
                    filter,
                    filter_name,
                } => BridgeParamKind::File {
                    filter: filter.iter().map(|f| (*f).to_owned()).collect(),
                    filter_name: filter_name.to_owned(),
                },
                ParamKind::Layer {} => BridgeParamKind::Layer,
            },
        })
        .collect()
}

/// An exact rational time in seconds, as `num / den`.
///
/// Keyframe times cross as the integer pair the document stores, never as
/// floating-point seconds (docs/17 "rational time crosses as integers"): a key
/// at 1/3 s read back as 0.333… and written again would no longer land on the
/// frame it was set on, and this round trip has to be exact.
#[frb(non_opaque)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BridgeRational {
    pub num: i64,
    /// Always positive in anything the engine hands out; a zero or negative
    /// denominator coming the other way is refused, not normalised.
    pub den: i64,
}

/// A bezier side's After Effects-compatible handle: `speed` in value-units per
/// second, `influence` as a fraction of the gap to the neighbouring key.
#[frb(non_opaque)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct BridgeBezierSide {
    pub speed: f64,
    pub influence: f64,
}

/// How a keyframe joins its neighbour on one side ([`SideInterp`]).
#[frb(non_opaque)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum BridgeSideInterp {
    Hold,
    Linear,
    Bezier(BridgeBezierSide),
}

impl BridgeSideInterp {
    #[frb(ignore)]
    fn read(side: SideInterp) -> BridgeSideInterp {
        match side {
            SideInterp::Hold => BridgeSideInterp::Hold,
            SideInterp::Linear => BridgeSideInterp::Linear,
            SideInterp::Bezier { speed, influence } => {
                BridgeSideInterp::Bezier(BridgeBezierSide { speed, influence })
            }
        }
    }

    #[frb(ignore)]
    fn write(self) -> SideInterp {
        match self {
            BridgeSideInterp::Hold => SideInterp::Hold,
            BridgeSideInterp::Linear => SideInterp::Linear,
            BridgeSideInterp::Bezier(side) => SideInterp::Bezier {
                speed: side.speed,
                influence: side.influence,
            },
        }
    }
}

/// One keyframe on one scalar channel.
#[frb(non_opaque)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct BridgeKeyframe {
    pub time: BridgeRational,
    pub value: f64,
    /// Approaching this key.
    pub interp_in: BridgeSideInterp,
    /// Leaving this key.
    pub interp_out: BridgeSideInterp,
}

impl BridgeKeyframe {
    #[frb(ignore)]
    fn read(key: &Keyframe) -> BridgeKeyframe {
        BridgeKeyframe {
            time: BridgeRational {
                num: key.time.num(),
                den: key.time.den(),
            },
            value: key.value,
            interp_in: BridgeSideInterp::read(key.interp_in),
            interp_out: BridgeSideInterp::read(key.interp_out),
        }
    }

    #[frb(ignore)]
    fn write(&self) -> Result<Keyframe, BridgeError> {
        Ok(Keyframe {
            time: Rational::new(self.time.num, self.time.den)
                .map_err(|_| BridgeError::InvalidKeyframes)?,
            value: self.value,
            interp_in: self.interp_in.write(),
            interp_out: self.interp_out.write(),
        })
    }
}

/// One animatable scalar channel: a single number, or the curve it follows.
///
/// The two are separate variants rather than a number plus an "animated" flag
/// because the panel must both tell them apart *and* write either back
/// unchanged. A keyframed parameter read as its value at time zero, then written
/// again, would silently delete the animation — which is exactly the trap the
/// `f64`-only predecessor of this type could not avoid, and why it answered
/// nothing at all for an animated parameter.
#[frb(non_opaque)]
#[derive(Debug, Clone, PartialEq)]
pub enum BridgeScalar {
    Static(f64),
    /// At least one key, strictly ascending in time — the invariant the
    /// engine's keyframe ops maintain, enforced here on the way in.
    Keyframed(Vec<BridgeKeyframe>),
    Expression(String),
}

impl BridgeScalar {
    #[frb(ignore)]
    pub(crate) fn read(property: &Property) -> BridgeScalar {
        match &property.animation {
            Animation::Static(value) => BridgeScalar::Static(*value),
            // A keyframed property with no keys is not a curve anything can
            // evaluate, and the editing ops never produce one (removing the last
            // key collapses to static). It reads as the value the engine itself
            // would evaluate it to, so it normalises on write-back rather than
            // being an unwritable value.
            Animation::Keyframed(keys) if keys.is_empty() => {
                BridgeScalar::Static(property.value_at(0.0))
            }
            Animation::Keyframed(keys) => {
                BridgeScalar::Keyframed(keys.iter().map(BridgeKeyframe::read).collect())
            }
            Animation::Expression(expr) => BridgeScalar::Expression(expr.clone()),
        }
    }

    /// This channel as an [`Animation`], or a calm error when the keys are not a
    /// curve the engine can evaluate.
    ///
    /// Deliberately separate from assigning it: a point or a colour has to
    /// validate every channel *before* writing any of them, or a bad third
    /// channel would leave the parameter half-updated.
    #[frb(ignore)]
    pub(crate) fn animation(&self) -> Result<Animation, BridgeError> {
        match self {
            BridgeScalar::Static(value) => Ok(Animation::Static(*value)),
            BridgeScalar::Keyframed(keys) => {
                if keys.is_empty() {
                    return Err(BridgeError::InvalidKeyframes);
                }
                let mut out: Vec<Keyframe> = Vec::with_capacity(keys.len());
                for key in keys {
                    let key = key.write()?;
                    // Ascending, unique times: `anim::evaluate` walks the list
                    // assuming it is sorted, so an unsorted one does not error,
                    // it silently evaluates wrongly.
                    if out.last().is_some_and(|previous| key.time <= previous.time) {
                        return Err(BridgeError::InvalidKeyframes);
                    }
                    out.push(key);
                }
                Ok(Animation::Keyframed(out))
            }
            BridgeScalar::Expression(expr) => Ok(Animation::Expression(expr.clone())),
        }
    }
}

/// A point parameter: two independently animatable axes.
#[frb(non_opaque)]
#[derive(Debug, Clone, PartialEq)]
pub struct BridgePoint {
    pub x: BridgeScalar,
    pub y: BridgeScalar,
}

/// A colour parameter: four independently animatable scene-linear channels.
#[frb(non_opaque)]
#[derive(Debug, Clone, PartialEq)]
pub struct BridgeColour {
    pub r: BridgeScalar,
    pub g: BridgeScalar,
    pub b: BridgeScalar,
    pub a: BridgeScalar,
}

/// A file parameter: the paths it references, and the index that selects which
/// one is live. Two paths cannot be blended, so the index only ever steps
/// (hold keyframes, K-111); the common case is one path and a static index.
/// An empty `paths` means unset, which the consuming effect treats as identity.
#[frb(non_opaque)]
#[derive(Debug, Clone, PartialEq)]
pub struct BridgeFileParam {
    pub paths: Vec<String>,
    pub index: BridgeScalar,
}

/// One effect parameter's value — the bridge mirror of [`EffectValue`], with one
/// variant per kind so no parameter is unreachable.
///
/// Reading and writing are exact inverses (see the module docs): the write side
/// replaces only what a value actually carries, leaving each property's
/// forward-compatibility `extra` fields in place (docs/10 §1.1), so a document
/// saved by a newer Lumit does not lose anything by being read and written here.
///
/// A `Layer` carries a bare id rather than a `LayerReference` because an effect
/// instance is a detached copy that does not know its own composition; the panel
/// resolves the id against `CompositionReference::get_layers`.
#[frb(non_opaque)]
#[derive(Debug, Clone, PartialEq)]
pub enum BridgeEffectValue {
    Float(BridgeScalar),
    Point(BridgePoint),
    Colour(BridgeColour),
    Bool(bool),
    Choice(u32),
    Seed(u32),
    File(BridgeFileParam),
    Layer(Option<Uuid>),
}

impl BridgeEffectValue {
    #[frb(ignore)]
    fn read(value: &EffectValue) -> BridgeEffectValue {
        match value {
            EffectValue::Float(property) => BridgeEffectValue::Float(BridgeScalar::read(property)),
            EffectValue::Point(x, y) => BridgeEffectValue::Point(BridgePoint {
                x: BridgeScalar::read(x),
                y: BridgeScalar::read(y),
            }),
            EffectValue::Colour(channels) => BridgeEffectValue::Colour(BridgeColour {
                r: BridgeScalar::read(&channels[0]),
                g: BridgeScalar::read(&channels[1]),
                b: BridgeScalar::read(&channels[2]),
                a: BridgeScalar::read(&channels[3]),
            }),
            EffectValue::Bool(value) => BridgeEffectValue::Bool(*value),
            EffectValue::Choice(index) => BridgeEffectValue::Choice(*index),
            EffectValue::Seed(seed) => BridgeEffectValue::Seed(*seed),
            EffectValue::File(file) => BridgeEffectValue::File(BridgeFileParam {
                paths: file.paths.clone(),
                index: BridgeScalar::read(&file.index),
            }),
            EffectValue::Layer(layer) => BridgeEffectValue::Layer(*layer),
        }
    }

    /// Overwrite `target` with this value.
    ///
    /// A parameter's *kind* is declared by the effect's schema and is not the
    /// panel's to change, so a mismatched pair is refused rather than replacing
    /// the value: writing a number to a colour would leave an instance the
    /// effect's own resolver cannot read, and it would be undoable but not
    /// obviously wrong on screen.
    #[frb(ignore)]
    fn write(self, target: &mut EffectValue) -> Result<(), BridgeError> {
        match (self, target) {
            (BridgeEffectValue::Float(scalar), EffectValue::Float(property)) => {
                property.animation = scalar.animation()?;
                Ok(())
            }
            (BridgeEffectValue::Point(point), EffectValue::Point(x, y)) => {
                let (ax, ay) = (point.x.animation()?, point.y.animation()?);
                x.animation = ax;
                y.animation = ay;
                Ok(())
            }
            (BridgeEffectValue::Colour(colour), EffectValue::Colour(channels)) => {
                let animations = [
                    colour.r.animation()?,
                    colour.g.animation()?,
                    colour.b.animation()?,
                    colour.a.animation()?,
                ];
                for (property, animation) in channels.iter_mut().zip(animations) {
                    property.animation = animation;
                }
                Ok(())
            }
            (BridgeEffectValue::Bool(value), EffectValue::Bool(target)) => {
                *target = value;
                Ok(())
            }
            (BridgeEffectValue::Choice(index), EffectValue::Choice(target)) => {
                *target = index;
                Ok(())
            }
            (BridgeEffectValue::Seed(seed), EffectValue::Seed(target)) => {
                *target = seed;
                Ok(())
            }
            (BridgeEffectValue::File(file), EffectValue::File(target)) => {
                let animation = file.index.animation()?;
                *target = FileParam {
                    paths: file.paths,
                    index: Property {
                        animation,
                        // The index's own forward-compatibility fields survive a
                        // path change, as they do for every other property here.
                        extra: std::mem::take(&mut target.index.extra),
                    },
                };
                Ok(())
            }
            (BridgeEffectValue::Layer(layer), EffectValue::Layer(target)) => {
                *target = layer;
                Ok(())
            }
            _ => Err(BridgeError::ParamKindMismatch),
        }
    }
}

/// One effect in a layer's stack, as the Effect controls panel holds it.
///
/// A **detached copy**, not a live handle: reading the stack clones it out of the
/// document, and [`Self::set_value`] edits that clone without committing
/// anything. That is what makes a drag cheap — Dart stages a value, renders it
/// through `CompositionReference::render_frame_with_preview`, and touches the
/// document, the undo history and the disk exactly once, on release, through
/// `LayerReference::set_effects` (docs/17 ABI v11/v12; GUIDE "Staging versus
/// committing").
#[frb(opaque)]
pub struct BridgeEffectInstance {
    effect: EffectInstance,
}

/// One parameter's current value, as [`BridgeEffectInstance::get_info`]
/// carries it.
#[frb(non_opaque)]
#[derive(Debug, Clone, PartialEq)]
pub struct BridgeParamValue {
    pub id: String,
    pub value: BridgeEffectValue,
}

/// Everything a panel draws for one effect instance, in one crossing (K-183):
/// its id, match name, bypass state, and every parameter's current value. The
/// instance is an opaque handle, so `id()`/`name()`/`get_value()` each cross
/// the bridge — a card that read them one at a time cost a call per field per
/// parameter per rebuild.
#[frb(non_opaque)]
#[derive(Debug, Clone, PartialEq)]
pub struct BridgeEffectInstanceInfo {
    pub id: Uuid,
    pub name: String,
    pub enabled: bool,
    pub values: Vec<BridgeParamValue>,
}

/// Build one instance's [`BridgeEffectInstanceInfo`] — the shared body of
/// [`BridgeEffectInstance::get_info`] and the comp read model (K-184).
#[frb(ignore)]
pub(crate) fn read_instance_info(effect: &EffectInstance) -> BridgeEffectInstanceInfo {
    BridgeEffectInstanceInfo {
        id: effect.id,
        name: effect.effect.match_name.clone(),
        enabled: effect.enabled,
        values: effect
            .params
            .iter()
            .map(|p| BridgeParamValue {
                id: p.id.to_string(),
                value: BridgeEffectValue::read(&p.value),
            })
            .collect(),
    }
}

impl BridgeEffectInstance {
    pub fn new(effect: EffectInstance) -> BridgeEffectInstance {
        BridgeEffectInstance { effect }
    }

    /// One read for everything a card draws — see [`BridgeEffectInstanceInfo`].
    #[frb(sync)]
    pub fn get_info(&self) -> BridgeEffectInstanceInfo {
        read_instance_info(&self.effect)
    }

    /// This instance's own id — what the stack ops on
    /// [`crate::api::layer::LayerReference`] address it by.
    #[frb(sync)]
    pub fn id(&self) -> Uuid {
        self.effect.id
    }

    #[frb(sync)]
    pub fn name(&self) -> String {
        self.effect.effect.match_name.clone()
    }

    /// False when the effect is individually bypassed (docs/08 §1.5) — the state
    /// of the checkbox in its title bar.
    #[frb(sync)]
    pub fn enabled(&self) -> bool {
        self.effect.enabled
    }

    #[frb(ignore)]
    pub fn get_effects(&self) -> EffectInstance {
        self.effect.clone()
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

    /// A parameter's value, whatever kind it is. An unknown `id` is an error;
    /// every parameter an instance actually carries is expressible, so there is
    /// no "cannot represent this one" answer any more.
    #[frb(sync)]
    pub fn get_value(&self, id: String) -> Result<BridgeEffectValue, BridgeError> {
        Ok(BridgeEffectValue::read(&self.param(&id)?.value))
    }

    /// Overwrite a parameter on this staged copy. Nothing is committed — see the
    /// type's own documentation; `LayerReference::set_effects` is the commit.
    ///
    /// Refused when `value` is of a different kind from the parameter, so a
    /// control can never quietly change what a parameter *is*.
    #[frb(sync)]
    pub fn set_value(&mut self, id: String, value: BridgeEffectValue) -> Result<(), BridgeError> {
        let param = self
            .effect
            .params
            .iter_mut()
            .find(|p| p.id == id)
            .ok_or(BridgeError::InvalidParam)?;

        value.write(&mut param.value)
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
