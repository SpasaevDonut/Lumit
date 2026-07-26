//! Tests for the flutter_rust_bridge API surface.
//!
//! A file of their own, not a `mod tests` inside each api module, for two
//! reasons: test code legitimately uses `expect`/`unwrap` where the api modules
//! deny them, and the `no-panics-in-frb-api` CI job greps `src/api` for exactly
//! those forms — it excludes this one path by name, which is more honest than
//! teaching a grep to recognise where a test module begins.

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use crate::api::{
    composition::CompositionReference, folder::FolderReference, footage::FootageReference,
    project::ProjectReference, project_item::ItemReference, state::LumitBridgeState, BridgeError,
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

    let roots = project.get_items().expect("roots");
    assert_eq!(
        roots.len(),
        3,
        "all three are root entries in the item list"
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
    assert_eq!(project.get_items().expect("roots").len(), 2);

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
