//! Tests for the flutter_rust_bridge API surface.
//!
//! A file of their own, not a `mod tests` inside each api module, for two
//! reasons: test code legitimately uses `expect`/`unwrap` where the api modules
//! deny them, and the `no-panics-in-frb-api` CI job greps `src/api` for exactly
//! those forms — it excludes this one path by name, which is more honest than
//! teaching a grep to recognise where a test module begins.

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use crate::api::{
    composition::{BridgeCompSettings, CompositionReference},
    effect::{
        list_effects, BridgeEffectValue, BridgeKeyframe, BridgeRational, BridgeScalar,
        BridgeSideInterp,
    },
    folder::FolderReference,
    footage::FootageReference,
    footage::LumitMediaStatus,
    layer::LayerReference,
    project::ProjectReference,
    project_item::ItemReference,
    state::LumitBridgeState,
    BridgeError,
};
use lumit_core::model::{Folder, FootageItem, MediaRef, ProjectItem};
use lumit_core::Op;
use uuid::Uuid;

/// A project holding a folder that lists one footage item, plus a second
/// footage item at the root. Returns the project and the three references.
///
/// Note this leaves the project in the process-wide `PROJECTS` registry, keyed
/// by a fresh uuid, so tests do not collide — but a test must never call
/// `open_project`, which clears the whole registry.
fn project_with_folder() -> (
    ProjectReference,
    ItemReference,
    ItemReference,
    ItemReference,
) {
    let project = LumitBridgeState::new_project(None).expect("a new project");

    let filed = FootageItem {
        id: Uuid::now_v7(),
        name: "filed.mp4".into(),
        media: MediaRef {
            relative_path: "filed.mp4".into(),
            absolute_path: String::new(),
            fingerprint: None,
            extra: serde_json::Map::new(),
        },
        extra: serde_json::Map::new(),
    };
    let loose = FootageItem {
        id: Uuid::now_v7(),
        name: "loose.mp4".into(),
        media: MediaRef {
            relative_path: "loose.mp4".into(),
            absolute_path: String::new(),
            fingerprint: None,
            extra: serde_json::Map::new(),
        },
        extra: serde_json::Map::new(),
    };
    let folder = Folder {
        id: Uuid::now_v7(),
        name: "Clips".into(),
        children: vec![filed.id],
        extra: serde_json::Map::new(),
    };
    let (filed_id, loose_id, folder_id) = (filed.id, loose.id, folder.id);

    {
        let state = project.state().expect("state");
        let state = state.write().expect("write");
        for (index, item) in [
            ProjectItem::Folder(folder),
            ProjectItem::Footage(filed),
            ProjectItem::Footage(loose),
        ]
        .into_iter()
        .enumerate()
        {
            state
                .store
                .commit(Op::AddItem {
                    index,
                    item: Box::new(item),
                })
                .expect("seeded");
        }
    }

    let id = project.id;
    (
        project,
        ItemReference::Folder(FolderReference::new(id, folder_id)),
        ItemReference::Footage(FootageReference::new(id, filed_id)),
        ItemReference::Footage(FootageReference::new(id, loose_id)),
    )
}

/// The panel draws roots then recurses, so a folder must report its own
/// children and nothing else — a flat list of everything would nest wrongly.
#[test]
fn a_folder_reports_only_its_own_children() {
    let (project, folder, filed, _loose) = project_with_folder();

    // Roots only: the folder and the unfiled item. The filed footage is reached
    // through the folder, never listed again at the top level — drawing it at both
    // levels was the bug this asserts against.
    let roots = project.get_items().expect("roots");
    assert_eq!(roots.len(), 2, "the folder and the unfiled item");
    assert!(
        !roots.iter().any(|r| r.equals(&filed)),
        "a filed item must not also appear at the root"
    );

    let ItemReference::Folder(folder_ref) = &folder else {
        panic!("the fixture built a folder");
    };
    let children = folder_ref.get_children().expect("children");
    assert_eq!(children.len(), 1);
    assert!(children[0].equals(&filed));
}

#[test]
fn rename_changes_the_name_and_refuses_a_blank_one() {
    let (_project, _folder, filed, _loose) = project_with_folder();

    filed.rename("hero shot".into()).expect("renamed");
    assert_eq!(filed.name().expect("name"), "hero shot");

    // Blank is refused rather than applied, so a row cannot lose its label.
    let err = filed.rename("   ".into());
    assert!(matches!(err, Err(BridgeError::EmptyName)));
    assert_eq!(filed.name().expect("name"), "hero shot", "unchanged");
}

#[test]
fn delete_removes_the_item_and_a_second_delete_is_a_calm_error() {
    let (project, _folder, _filed, loose) = project_with_folder();

    loose.delete().expect("deleted");
    assert_eq!(
        project.get_items().expect("roots").len(),
        1,
        "just the folder is left at the root"
    );

    // The reference now outlives its item: an error, never a panic.
    assert!(matches!(loose.delete(), Err(BridgeError::InvalidItem)));
}

/// Moving to the root means "no folder lists it any more". The item itself
/// stays in the document either way, which is what makes this distinct from
/// deleting.
#[test]
fn move_to_root_unfiles_the_item_and_is_a_no_op_when_already_there() {
    let (_project, folder, filed, loose) = project_with_folder();
    let ItemReference::Folder(folder_ref) = &folder else {
        panic!("the fixture built a folder");
    };

    filed.move_to_root().expect("unfiled");
    assert!(
        folder_ref.get_children().expect("children").is_empty(),
        "the folder no longer lists it"
    );
    assert_eq!(
        filed.name().expect("name"),
        "filed.mp4",
        "still in the document"
    );

    // Already at the root: accepted and does nothing, rather than erroring.
    loose.move_to_root().expect("no-op");
    filed.move_to_root().expect("no-op the second time too");
}

/// Relinking points the item at the picked file and, crucially, is refused when
/// there is nothing to point at — a silent success would leave the user thinking
/// a broken item had been fixed.
#[test]
fn relink_refuses_a_blank_or_useless_path() {
    let (_project, _folder, filed, _loose) = project_with_folder();
    let ItemReference::Footage(footage) = &filed else {
        panic!("the fixture built footage");
    };

    assert!(matches!(
        footage.relink(String::new()),
        Err(BridgeError::MediaPathUnresolved)
    ));

    // A path that does not exist: the target itself is still repointed (the user
    // asked for it explicitly), so this succeeds and the document records it.
    let picked = std::env::temp_dir().join("lumit-relink-target.mp4");
    std::fs::write(&picked, b"not really a video").expect("temp file");
    footage
        .relink(picked.to_string_lossy().into_owned())
        .expect("the explicit target is always repointed");
    std::fs::remove_file(&picked).ok();
}

/// A placed clip must land in the composition; the span/size fallbacks are what
/// let a *missing* file still place, so the user can relink rather than being
/// unable to add it at all.
#[test]
fn footage_places_into_a_composition_even_when_the_media_is_missing() {
    let (project, _folder, filed, _loose) = project_with_folder();
    let ItemReference::Footage(footage) = &filed else {
        panic!("the fixture built footage");
    };

    let comp = add_comp(&project, "Scene");
    assert!(comp.get_layers().expect("layers").is_empty());

    // The fixture's media has an empty absolute path and an unsaved project, so
    // it cannot resolve — the comp's own duration and size are used.
    comp.add_footage_layer(footage).expect("placed");

    let layers = comp.get_layers().expect("layers");
    assert_eq!(layers.len(), 1);
    assert_eq!(layers[0].get_name().expect("name"), "filed.mp4");
}

/// `get_size` is what the Viewer divides its panel box by to work out a render
/// scale, so it has to report the comp's own dimensions rather than anything else.
#[test]
fn a_composition_reports_its_own_size() {
    let (project, ..) = project_with_folder();
    let comp = add_comp(&project, "Scene");

    let size = comp.get_size().expect("size");
    assert_eq!((size.width, size.height), (1920, 1080));
}

/// Add a composition straight through the store, since the frb API has no
/// add-composition op yet (that arrives with the Timeline port).
fn add_comp(project: &ProjectReference, name: &str) -> CompositionReference {
    use lumit_core::model::LinearColour;
    use lumit_core::time::{Duration, FrameRate, Rational};

    let comp = lumit_core::model::Composition {
        id: Uuid::now_v7(),
        name: name.into(),
        width: 1920,
        height: 1080,
        frame_rate: FrameRate::new(30, 1).expect("30 fps"),
        duration: Duration(Rational::new(10, 1).expect("10 s")),
        background: LinearColour([0.0, 0.0, 0.0, 0.0]),
        work_area: None,
        layers: Vec::new(),
        markers: Vec::new(),
        motion_blur: Default::default(),
        extra: serde_json::Map::new(),
    };
    let comp_id = comp.id;

    let state = project.state().expect("state");
    let state = state.write().expect("write");
    state
        .store
        .commit(Op::AddItem {
            index: 0,
            item: Box::new(ProjectItem::Composition(comp)),
        })
        .expect("comp added");

    CompositionReference::new(project.id, comp_id)
}

/// `get_status` must report a file that is not there as missing — the Project
/// panel's badge depends on it.
#[test]
fn a_footage_item_pointing_at_nothing_reports_missing() {
    let project = LumitBridgeState::new_project(None).expect("project");
    let footage = project
        .import_footage("C:/nowhere/definitely-not-here.mp4".into())
        .expect("imported");

    let status = footage.get_status().expect("status");
    assert!(matches!(status, LumitMediaStatus::Missing));
}

/// Relink takes a write lock after having taken a read lock earlier in the same
/// call. If those ever overlap, this deadlocks rather than fails — so the test
/// existing at all is the guard.
#[test]
fn relink_does_not_deadlock_against_its_own_read() {
    let project = LumitBridgeState::new_project(None).expect("project");
    let footage = project
        .import_footage("C:/nowhere/gone.mp4".into())
        .expect("imported");

    let target = std::env::temp_dir().join("lumit-relink-deadlock-probe.mp4");
    std::fs::write(&target, b"stub").expect("temp file");

    footage
        .relink(target.to_string_lossy().into_owned())
        .expect("relinked");

    std::fs::remove_file(&target).ok();
}

/// Importing then reading back is the panel's whole read path, and `new_composition`
/// must file its comp so the tree has something to nest.
#[test]
fn import_and_new_composition_land_in_the_item_tree() {
    let project = LumitBridgeState::new_project(None).expect("project");
    project
        .import_footage("C:/clips/shot.mov".into())
        .expect("imported");
    let comp = project.new_composition("Scene".into()).expect("comp");

    let roots = project.get_items().expect("roots");
    // The footage and the Compositions folder. The comp is inside the folder, so
    // it is NOT a root — drawing it at both levels was the bug this asserts against.
    assert_eq!(roots.len(), 2);

    let folder = roots
        .iter()
        .find_map(|i| match i {
            ItemReference::Folder(f) => Some(f),
            _ => None,
        })
        .expect("the Compositions auto-folder was created");
    let children = folder.get_children().expect("children");
    assert_eq!(children.len(), 1, "the comp is filed into it");
    assert_eq!(children[0].name().expect("name"), "Scene");
    assert_eq!(comp.get_size().expect("size").width, 1920);
}

/// Composition settings must round-trip exactly, including a non-integer frame
/// rate. 29.97 fps is 30000/1001; if the pair went through a float anywhere it
/// would not come back, which is why the settings type carries num and den rather
/// than a single number (docs/14 §2).
#[test]
fn composition_settings_round_trip_including_a_drop_frame_rate() {
    let (project, ..) = project_with_folder();
    let comp = add_comp(&project, "Scene");

    let before = comp.get_settings().expect("settings");
    assert_eq!((before.fps_num, before.fps_den), (30, 1));

    comp.set_settings(BridgeCompSettings {
        name: "Renamed".into(),
        width: 1280,
        height: 720,
        fps_num: 30000,
        fps_den: 1001,
        duration_frames: 240,
    })
    .expect("applied");

    let after = comp.get_settings().expect("settings");
    assert_eq!(after.name, "Renamed");
    assert_eq!((after.width, after.height), (1280, 720));
    assert_eq!(
        (after.fps_num, after.fps_den),
        (30000, 1001),
        "the exact rate survives — no float round trip"
    );
    assert_eq!(after.duration_frames, 240);
}

/// A dialog must not be able to commit a comp that is zero pixels wide or zero
/// frames long, and a zero frame rate is refused outright rather than clamped —
/// there is no sensible rate to clamp to.
#[test]
fn composition_settings_clamp_the_absurd_and_refuse_a_zero_rate() {
    let (project, ..) = project_with_folder();
    let comp = add_comp(&project, "Scene");

    comp.set_settings(BridgeCompSettings {
        name: "Tiny".into(),
        width: 0,
        height: 0,
        fps_num: 30,
        fps_den: 1,
        duration_frames: 0,
    })
    .expect("applied");

    let after = comp.get_settings().expect("settings");
    assert_eq!((after.width, after.height), (16, 16), "clamped, not zero");
    assert_eq!(after.duration_frames, 1, "at least one frame");

    assert!(matches!(
        comp.set_settings(BridgeCompSettings {
            name: "Bad".into(),
            width: 1920,
            height: 1080,
            fps_num: 0,
            fps_den: 1,
            duration_frames: 10,
        }),
        Err(BridgeError::InvalidFrameRate)
    ));
}

/// Saving answers where it wrote, and a project that has never been saved refuses
/// an empty path rather than guessing a location.
#[test]
fn save_reports_its_path_and_refuses_to_guess_one() {
    let (project, ..) = project_with_folder();

    assert!(project.path().expect("path").is_none());
    assert!(matches!(
        project.save(String::new()),
        Err(BridgeError::NoProjectPath)
    ));

    let dir = std::env::temp_dir().join("lumit-save-probe");
    std::fs::create_dir_all(&dir).expect("temp dir");
    let target = dir.join("probe.lum");

    let written = project
        .save(target.to_string_lossy().into_owned())
        .expect("saved");
    assert!(written.ends_with("probe.lum"));
    assert!(target.is_file(), "the file really exists");

    // Now it knows where it lives, so an empty path saves in place.
    assert_eq!(
        project.path().expect("path").as_deref(),
        Some(written.as_str())
    );
    project.save(String::new()).expect("saved in place");

    std::fs::remove_dir_all(&dir).ok();
}

/// The menu bar greys Undo and Redo from this, so it has to track the store.
#[test]
fn history_reports_what_undo_and_redo_can_do() {
    let project = LumitBridgeState::new_project(None).expect("project");

    let empty = project.history().expect("history");
    assert!(
        !empty.can_undo && !empty.can_redo,
        "a fresh project has none"
    );

    project.new_composition("Scene".into()).expect("comp");
    let after_edit = project.history().expect("history");
    assert!(after_edit.can_undo && !after_edit.can_redo);

    project.undo().expect("undone");
    let after_undo = project.history().expect("history");
    assert!(after_undo.can_redo, "undoing makes a redo available");
}

// ---------------------------------------------------------------------------
// Effect controls: the parameter value type and the stack ops.
// ---------------------------------------------------------------------------

/// A fresh project holding one composition with one adjustment layer in it.
/// Adjustment is chosen because it needs no media: the effect surface only cares
/// that a layer exists to hang a stack on.
fn project_with_layer() -> (ProjectReference, LayerReference) {
    use lumit_core::model::{LayerKind, TransformGroup};

    let project = LumitBridgeState::new_project(None).expect("a new project");
    let comp = add_comp(&project, "Scene");
    let layer = crate::edits::base_layer(
        "Adjust".into(),
        LayerKind::Adjustment,
        lumit_core::time::Rational::new(5, 1).expect("5 s"),
        TransformGroup::default(),
    );
    let layer_id = layer.id;

    {
        let state = project.state().expect("state");
        let state = state.write().expect("write");
        state
            .store
            .commit(Op::AddLayer {
                comp: comp.id,
                index: 0,
                layer: Box::new(layer),
            })
            .expect("layer added");
    }

    let layer = LayerReference::new(project.id, comp.id, layer_id);
    (project, layer)
}

/// An effect instance carrying one parameter of every `EffectValue` kind, plus a
/// keyframed `Float` beside the static one. `float` also carries an unknown
/// `extra` field, standing in for a document written by a newer Lumit: the
/// round-trip assertions below compare whole instances, so anything the bridge
/// dropped on the way through would show up there.
fn effect_with_every_kind() -> lumit_core::model::EffectInstance {
    use lumit_core::anim::{Animation, Keyframe, Property, SideInterp, EASY_EASE};
    use lumit_core::model::{
        EffectInstance, EffectKey, EffectNamespace, EffectParam, EffectValue, FileParam,
    };
    use lumit_core::time::Rational;

    let param = |id: &str, value: EffectValue| EffectParam {
        id: id.into(),
        value,
        extra: serde_json::Map::new(),
    };

    let mut carries_extra = serde_json::Map::new();
    carries_extra.insert("expression".into(), serde_json::json!("time * 2"));

    let curve = Animation::Keyframed(vec![
        Keyframe {
            time: Rational::new(0, 1).expect("0 s"),
            value: 5.0,
            interp_in: SideInterp::Linear,
            interp_out: SideInterp::Linear,
        },
        Keyframe {
            // A half-second: exactly the sort of time that would stop landing on
            // its own frame if it crossed as a float.
            time: Rational::new(1, 2).expect("half a second"),
            value: 20.0,
            interp_in: EASY_EASE,
            interp_out: SideInterp::Hold,
        },
    ]);

    EffectInstance {
        id: Uuid::now_v7(),
        effect: EffectKey {
            namespace: EffectNamespace::Builtin,
            match_name: "blur".into(),
            version: 1,
            extra: serde_json::Map::new(),
        },
        enabled: true,
        params: vec![
            param(
                "float",
                EffectValue::Float(Property {
                    animation: Animation::Static(4.5),
                    extra: carries_extra,
                }),
            ),
            param(
                "animated",
                EffectValue::Float(Property {
                    animation: curve,
                    extra: serde_json::Map::new(),
                }),
            ),
            param(
                "point",
                EffectValue::Point(Property::fixed(10.0), Property::fixed(-3.0)),
            ),
            param(
                "colour",
                EffectValue::Colour([
                    Property::fixed(0.1),
                    Property::fixed(0.2),
                    Property::fixed(0.3),
                    Property::fixed(1.0),
                ]),
            ),
            param("bool", EffectValue::Bool(true)),
            param("choice", EffectValue::Choice(2)),
            param("seed", EffectValue::Seed(77)),
            param(
                "file",
                EffectValue::File(FileParam::single("C:/maps/displace.png")),
            ),
            param("layer", EffectValue::Layer(Some(Uuid::now_v7()))),
        ],
        sample_temporally: true,
        extra: serde_json::Map::new(),
    }
}

/// Put `effects` on the layer straight through the store, so a test can start
/// from a stack the frb add path could not have built.
fn seed_stack(
    project: &ProjectReference,
    layer: &LayerReference,
    effects: Vec<lumit_core::model::EffectInstance>,
) {
    let state = project.state().expect("state");
    let state = state.write().expect("write");
    state
        .store
        .commit(Op::SetLayerEffects {
            comp: layer.comp_id,
            layer: layer.layer_id,
            effects,
        })
        .expect("stack seeded");
}

/// The layer's effect stack as the document holds it.
fn stack_of(layer: &LayerReference) -> Vec<lumit_core::model::EffectInstance> {
    layer
        .get_effects()
        .expect("stack")
        .iter()
        .map(|e| e.get_effects())
        .collect()
}

/// Undo exactly one step.
fn undo_once(project: &ProjectReference) {
    let state = project.state().expect("state");
    let state = state.read().expect("read");
    state
        .store
        .undo()
        .expect("undo applied")
        .expect("there was something to undo");
}

/// The whole promise of the value type: whatever a parameter reads as can be
/// written straight back, for every kind, and the document is left exactly as it
/// was — keyframes, keyframe interpolation, file paths, layer reference and all.
/// Without that, "read the value, change one field, write it" — the way every
/// control in the panel works — would quietly damage the parameters it touched.
#[test]
fn every_effect_value_kind_round_trips_through_the_document() {
    let (project, layer) = project_with_layer();
    let original = effect_with_every_kind();
    seed_stack(&project, &layer, vec![original.clone()]);

    let mut staged = layer.get_effects().expect("stack");
    assert_eq!(staged.len(), 1);
    let ids = staged[0].get_parameters();
    assert_eq!(
        ids.len(),
        9,
        "one parameter per kind, plus the animated float"
    );

    for id in ids {
        let value = staged[0]
            .get_value(id.clone())
            .unwrap_or_else(|e| panic!("every kind reads: {id} answered {e}"));
        staged[0]
            .set_value(id.clone(), value)
            .unwrap_or_else(|e| panic!("every kind writes: {id} answered {e}"));
    }
    layer.set_effects(staged).expect("committed");

    assert_eq!(stack_of(&layer), vec![original]);
}

/// A keyframed Float must read as its curve, not as its value at time zero. The
/// `f64`-only predecessor could only answer `None` here, which is why an animated
/// parameter was unreachable; answering a number instead would be worse, because
/// writing it back would delete the animation.
#[test]
fn a_keyframed_float_reads_as_its_keys_and_is_not_flattened() {
    let (project, layer) = project_with_layer();
    seed_stack(&project, &layer, vec![effect_with_every_kind()]);
    let staged = layer.get_effects().expect("stack");

    let value = staged[0].get_value("animated".into()).expect("a value");
    let BridgeEffectValue::Float(BridgeScalar::Keyframed(keys)) = value else {
        panic!("a keyframed float must not read as a static number");
    };
    assert_eq!(keys.len(), 2);
    // Exact times, as integers: 1/2 s, not 0.5.
    assert_eq!((keys[0].time.num, keys[0].time.den), (0, 1));
    assert_eq!((keys[1].time.num, keys[1].time.den), (1, 2));
    assert_eq!(keys[1].value, 20.0);
    assert!(
        matches!(keys[1].interp_in, BridgeSideInterp::Bezier(_)),
        "the eased side survives, so the graph editor can draw its handle"
    );
    assert!(matches!(keys[1].interp_out, BridgeSideInterp::Hold));

    // The static sibling still reads static — the distinction is per parameter.
    assert!(matches!(
        staged[0].get_value("float".into()),
        Ok(BridgeEffectValue::Float(BridgeScalar::Static(_)))
    ));
}

/// A parameter's kind is the effect's schema to declare, not the panel's to
/// change. Writing the wrong kind is refused and the value left alone, rather
/// than becoming something the effect's own resolver cannot read.
#[test]
fn writing_the_wrong_kind_to_a_parameter_is_refused() {
    let (project, layer) = project_with_layer();
    seed_stack(&project, &layer, vec![effect_with_every_kind()]);
    let mut staged = layer.get_effects().expect("stack");

    let before = staged[0].get_value("colour".into()).expect("a colour");
    let refused = staged[0].set_value(
        "colour".into(),
        BridgeEffectValue::Float(BridgeScalar::Static(1.0)),
    );
    assert!(matches!(refused, Err(BridgeError::ParamKindMismatch)));
    assert_eq!(
        staged[0]
            .get_value("colour".into())
            .expect("still a colour"),
        before,
        "a refused write changes nothing"
    );

    // The other direction refuses too, and an unknown parameter is a calm error
    // rather than a silent no-op.
    assert!(matches!(
        staged[0].set_value("float".into(), BridgeEffectValue::Bool(true)),
        Err(BridgeError::ParamKindMismatch)
    ));
    assert!(matches!(
        staged[0].get_value("nope".into()),
        Err(BridgeError::InvalidParam)
    ));
}

/// Keys the engine could not evaluate are refused on the way in. `anim::evaluate`
/// walks the list assuming it is sorted, so an unsorted one would not fail — it
/// would silently evaluate wrongly, which is far harder to notice.
#[test]
fn a_keyframed_value_the_engine_could_not_evaluate_is_refused() {
    let (project, layer) = project_with_layer();
    seed_stack(&project, &layer, vec![effect_with_every_kind()]);
    let mut staged = layer.get_effects().expect("stack");

    let key = |num: i64, den: i64| BridgeKeyframe {
        time: BridgeRational { num, den },
        value: 1.0,
        interp_in: BridgeSideInterp::Linear,
        interp_out: BridgeSideInterp::Linear,
    };
    let write = |staged: &mut Vec<crate::api::effect::BridgeEffectInstance>,
                 keys: Vec<BridgeKeyframe>| {
        staged[0].set_value(
            "animated".into(),
            BridgeEffectValue::Float(BridgeScalar::Keyframed(keys)),
        )
    };

    assert!(matches!(
        write(&mut staged, Vec::new()),
        Err(BridgeError::InvalidKeyframes)
    ));
    assert!(matches!(
        write(&mut staged, vec![key(1, 1), key(0, 1)]),
        Err(BridgeError::InvalidKeyframes)
    ));
    assert!(
        matches!(
            write(&mut staged, vec![key(0, 1), key(0, 1)]),
            Err(BridgeError::InvalidKeyframes)
        ),
        "two keys at the same time are not a curve either"
    );
    assert!(matches!(
        write(&mut staged, vec![key(1, 0)]),
        Err(BridgeError::InvalidKeyframes)
    ));

    // A valid curve still writes, so the guard is not simply refusing everything.
    write(&mut staged, vec![key(0, 1), key(1, 2)]).expect("an ascending curve writes");
}

/// The Add-effect menu's source list. It carries the label and the category keys
/// as well as the match name, because the menu groups by category (K-090) and
/// draws the label, and a second call to find those out would be wasted.
#[test]
fn list_effects_names_the_builtins_with_their_labels_and_categories() {
    let effects = list_effects();
    assert!(!effects.is_empty());
    assert!(
        effects
            .iter()
            .any(|e| e.name == "blur" && e.label == "Gaussian blur"),
        "the match name and its menu label are distinct, and both are carried"
    );
    assert!(effects
        .iter()
        .all(|e| !e.category.is_empty() && !e.category_label.is_empty()));
}

/// Each stack op is one `SetLayerEffects`, so one undo puts the stack back
/// exactly as it was. A single op that landed as two would leave the stack
/// half-restored here, which is the failure this is watching for.
#[test]
fn each_effect_stack_op_lands_as_one_undo_step() {
    let (project, layer) = project_with_layer();
    let builtins = list_effects();
    let (first, second) = (builtins[0].name.clone(), builtins[1].name.clone());

    // Add.
    layer.add_effect(first.clone()).expect("added");
    let added = stack_of(&layer);
    assert_eq!(added.len(), 1);
    assert_eq!(added[0].effect.match_name, first);
    undo_once(&project);
    assert!(
        stack_of(&layer).is_empty(),
        "one undo unwinds the whole add"
    );

    layer.add_effect(first.clone()).expect("added again");
    layer.add_effect(second).expect("a second effect");
    let two = stack_of(&layer);
    assert_eq!(two.len(), 2, "an added effect appends to the stack");

    // Bypass.
    layer
        .set_effect_enabled(&layer.get_effects().expect("stack")[0], false)
        .expect("bypassed");
    assert!(!stack_of(&layer)[0].enabled);
    undo_once(&project);
    assert_eq!(stack_of(&layer), two, "one undo restores the whole stack");

    // Reorder.
    layer
        .reorder_effect(&layer.get_effects().expect("stack")[0], 1)
        .expect("reordered");
    assert_eq!(stack_of(&layer)[1].id, two[0].id);
    undo_once(&project);
    assert_eq!(stack_of(&layer), two);

    // Remove.
    layer
        .remove_effect(&layer.get_effects().expect("stack")[0])
        .expect("removed");
    assert_eq!(stack_of(&layer).len(), 1);
    undo_once(&project);
    assert_eq!(stack_of(&layer), two);
}

/// A drag that overshoots the list is an ordinary thing for a pointer to do, so
/// the index clamps rather than the reorder failing and leaving the effect where
/// it started with no explanation.
#[test]
fn reorder_effect_clamps_an_index_outside_the_stack() {
    let (project, layer) = project_with_layer();
    let names: Vec<String> = list_effects()
        .iter()
        .take(3)
        .map(|e| e.name.clone())
        .collect();
    for name in &names {
        layer.add_effect(name.clone()).expect("added");
    }
    let ids: Vec<Uuid> = stack_of(&layer).iter().map(|e| e.id).collect();
    assert_eq!(ids.len(), 3);

    // Far past the end lands it at the bottom.
    layer
        .reorder_effect(&layer.get_effects().expect("stack")[0], 99)
        .expect("clamped, not refused");
    assert_eq!(stack_of(&layer)[2].id, ids[0]);

    // Negative lands it back at the top.
    layer
        .reorder_effect(&layer.get_effects().expect("stack")[2], -5)
        .expect("clamped, not refused");
    assert_eq!(stack_of(&layer)[0].id, ids[0]);

    // And the whole document is still consistent: three effects, no duplicates.
    let after: Vec<Uuid> = stack_of(&layer).iter().map(|e| e.id).collect();
    assert_eq!(after.len(), 3);
    assert_eq!(after[0], ids[0]);
    let _ = project;
}

/// Effects that are no longer there, and names that never were, are calm errors.
#[test]
fn the_stack_ops_refuse_what_they_cannot_find() {
    let (project, layer) = project_with_layer();
    seed_stack(&project, &layer, vec![effect_with_every_kind()]);

    assert!(matches!(
        layer.add_effect("not-an-effect".into()),
        Err(BridgeError::UnknownEffectName)
    ));

    let stale = layer.get_effects().expect("stack");
    layer.remove_effect(&stale[0]).expect("removed");
    // The reference now outlives its effect: an error, never a panic.
    assert!(matches!(
        layer.remove_effect(&stale[0]),
        Err(BridgeError::InvalidEffect)
    ));
    assert!(matches!(
        layer.reorder_effect(&stale[0], 0),
        Err(BridgeError::InvalidEffect)
    ));
    assert!(matches!(
        layer.set_effect_enabled(&stale[0], false),
        Err(BridgeError::InvalidEffect)
    ));
}

/// `set_effects` commits parameter values, and only those. A stack staged before
/// something else removed an effect from it would otherwise resurrect that
/// effect on mouse-up — and reorder and delete would have a second, silent path
/// that cannot say what it meant.
#[test]
fn committing_a_staged_stack_that_no_longer_matches_the_document_is_refused() {
    let (project, layer) = project_with_layer();
    let mut first = effect_with_every_kind();
    first.params.clear();
    let mut second = effect_with_every_kind();
    second.params.clear();
    second.id = Uuid::now_v7();
    seed_stack(&project, &layer, vec![first.clone(), second.clone()]);

    let staged = layer.get_effects().expect("stack");
    layer
        .remove_effect(&layer.get_effects().expect("stack")[1])
        .expect("removed behind the panel's back");

    assert!(matches!(
        layer.set_effects(staged),
        Err(BridgeError::StaleEffectStack)
    ));
    assert_eq!(
        stack_of(&layer),
        vec![first],
        "the removal stands; nothing is resurrected"
    );
}

// --- Change scoping -------------------------------------------------------
//
// `op_scope` is what stops the Project panel rebuilding — and re-probing every
// footage file on disk — every time someone nudges a layer value. It used to
// serialise each op to JSON and look for `comp`/`layer` string fields, so every
// project-level op fell through unscoped and Dart could not tell the two apart.

/// A layer edit is not a project-item edit. This is the regression: with the
/// JSON sniffing, `items` did not exist and the panel rebuilt on this op.
#[test]
fn a_layer_edit_scopes_to_its_layer_and_not_the_item_list() {
    let (comp, layer) = (Uuid::now_v7(), Uuid::now_v7());

    assert_eq!(
        crate::api::state::op_scope(&Op::SetLayerVisible {
            comp,
            layer,
            visible: false,
        }),
        (Some(comp), Some(layer), false)
    );

    // Adding or removing a layer changes the comp's layer list, not one layer's
    // contents, so it reports the comp alone.
    assert_eq!(
        crate::api::state::op_scope(&Op::RemoveLayer { comp, layer }),
        (Some(comp), None, false)
    );
}

/// Every op that adds, removes, renames, refiles or relinks an item sets the
/// flag the Project panel listens on.
#[test]
fn project_item_edits_scope_to_the_item_list() {
    let (id, folder) = (Uuid::now_v7(), Uuid::now_v7());

    for op in [
        Op::RemoveItem { id },
        Op::RenameItem {
            id,
            name: "hero".into(),
        },
        Op::SetFolderChildren {
            folder,
            children: vec![id],
        },
        Op::SetAutoFolder {
            kind: lumit_core::ops::AutoFolderKind::Solids,
            folder: Some(folder),
        },
    ] {
        assert_eq!(
            crate::api::state::op_scope(&op),
            (None, None, true),
            "{op:?} should reach the Project panel"
        );
    }

    // Comp settings carry the comp's name, which is the panel's row label, so
    // this one is both an item-list change and a comp change.
    assert_eq!(
        crate::api::state::op_scope(&Op::SetCompSettings {
            comp: id,
            name: "Scene".into(),
            width: 1920,
            height: 1080,
            frame_rate: lumit_core::time::FrameRate::new(25, 1).expect("25 fps"),
            duration: lumit_core::time::Duration(
                lumit_core::time::Rational::new(5, 1).expect("5 s")
            ),
            background: lumit_core::model::LinearColour::BLACK,
        }),
        (Some(id), None, true)
    );
}

/// A batch is as broad as its members: `move_to_root` commits a batch of folder
/// edits and must still reach the panel, while a batch of layer edits must not.
#[test]
fn a_batch_takes_the_widest_scope_of_its_members() {
    let (comp, layer, folder) = (Uuid::now_v7(), Uuid::now_v7(), Uuid::now_v7());

    assert_eq!(
        crate::api::state::op_scope(&Op::Batch {
            ops: vec![
                Op::SetLayerVisible {
                    comp,
                    layer,
                    visible: false,
                },
                Op::SetFolderChildren {
                    folder,
                    children: vec![],
                },
            ],
        }),
        (None, None, true)
    );

    assert_eq!(
        crate::api::state::op_scope(&Op::Batch {
            ops: vec![
                Op::SetLayerVisible {
                    comp,
                    layer,
                    visible: false,
                },
                Op::RenameLayer {
                    comp,
                    layer,
                    name: "Adjust".into(),
                },
            ],
        }),
        (None, None, false)
    );
}

/// The panel draws a row per declared parameter, so the schema has to come
/// across whole: labels to show, ranges for the sliders, option names for the
/// dropdowns. Blur is the check because it declares a Float with a slider and a
/// half-open hard bound plus a grouped Choice.
#[test]
fn list_parameters_carries_the_schema_a_control_needs() {
    use crate::api::effect::{list_parameters, BridgeParamKind};

    let params = list_parameters("blur".into());
    assert!(!params.is_empty(), "blur declares parameters");

    let radius = params
        .iter()
        .find(|p| p.id == "radius")
        .expect("blur has a radius");
    assert_eq!(radius.label, "Radius", "the label is what the row shows");
    let BridgeParamKind::Float {
        slider_min,
        slider_max,
        hard_min,
        ..
    } = &radius.kind
    else {
        panic!("radius is a float");
    };
    assert!(slider_max > slider_min, "the slider has travel");
    assert_eq!(*hard_min, Some(0.0), "a blur radius cannot go negative");

    // Every declared parameter is expressible: no kind falls through.
    for p in &params {
        assert!(!p.label.is_empty(), "{} has a label", p.id);
    }
}

/// An effect this build does not know is an empty list, not an error — a project
/// carrying one still opens, its instance simply has no rows.
#[test]
fn list_parameters_of_an_unknown_effect_is_empty() {
    assert!(crate::api::effect::list_parameters("not-an-effect".into()).is_empty());
}

/// Every built-in's parameters survive the crossing. A kind added to the schema
/// without an arm here would panic in the mapping; this walks the lot so that
/// cannot reach a user.
#[test]
fn every_builtin_lists_its_parameters() {
    for info in crate::api::effect::list_effects() {
        let params = crate::api::effect::list_parameters(info.name.clone());
        let declared = lumit_core::fx::BUILTINS
            .iter()
            .find(|s| s.match_name == info.name)
            .expect("listed effects are built in")
            .params
            .len();
        assert_eq!(params.len(), declared, "{} lost a parameter", info.name);
    }
}
