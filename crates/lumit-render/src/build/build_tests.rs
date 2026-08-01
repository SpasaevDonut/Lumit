//! Draw-building tests: layer geometry under reduced-resolution decode,
//! collapsed Precomps, the live value patch, and adjustment staging.
//!
//! These moved out of the egui shell with the pixel pass (K-178) — they always
//! tested the builder, not the interface, and they now guard it for both
//! frontends at once.

use crate::build::{build_comp_draws, patch_layer_prop};
use crate::decode::CompLayerPixels;
use crate::draw::DrawSource;
use lumit_core::model::{
    Composition, Document, Layer, LayerKind, LinearColour, Switches, TransformGroup,
};
use lumit_core::time::{CompTime, Duration, FrameRate, Rational};
use std::collections::HashMap;
use uuid::Uuid;

// Regression: under auto res a footage layer decodes at a reduced size that
// changes with viewport zoom. Its comp-space geometry must use the *native*
// source size, not the decoded size — otherwise a small layer balloons as
// you zoom in (the auto-res bug Mack reported, 2026-07-13).
#[test]
fn footage_geometry_uses_native_size_not_decoded_size() {
    let item = Uuid::now_v7();
    let layer = Layer {
        id: Uuid::now_v7(),
        name: "clip".into(),
        kind: LayerKind::Footage { item, retime: None },
        in_point: CompTime(Rational::ZERO),
        out_point: CompTime(Rational::new(10, 1).unwrap()),
        start_offset: CompTime(Rational::ZERO),
        transform: TransformGroup::default(),
        matte: None,
        parent: None,
        label: 0,
        volume_db: lumit_core::anim::Property::zero(),
        retime: None,
        blend: Default::default(),
        masks: Vec::new(),
        paint: Vec::new(),
        effects: Vec::new(),
        switches: Switches::default(),
        extra: serde_json::Map::new(),
    };
    let comp = Composition {
        id: Uuid::now_v7(),
        name: "Comp".into(),
        width: 1920,
        height: 1080,
        frame_rate: FrameRate::new(60, 1).unwrap(),
        duration: Duration(Rational::new(10, 1).unwrap()),
        background: LinearColour::BLACK,
        work_area: None,
        layers: vec![layer.clone()],
        markers: Vec::new(),
        motion_blur: Default::default(),
        extra: serde_json::Map::new(),
    };
    // Native 1920x1080, decoded 480x270 (zoomed out, quarter res).
    let lp = CompLayerPixels {
        layer: layer.id,
        width: 480,
        height: 270,
        rgba: vec![0u8; 480 * 270 * 4],
        natural_w: 1920,
        natural_h: 1080,
        temporal: Vec::new(),
        flow_field: None,
    };
    let mut map: HashMap<Uuid, &CompLayerPixels> = HashMap::new();
    map.insert(layer.id, &lp);
    let doc = Document::new();
    let mut visited = vec![comp.id];
    let draws = build_comp_draws(&doc, &comp, 0.0, &map, &mut visited);

    assert_eq!(draws.len(), 1);
    // Geometry uses native size (zoom-independent), not the 480x270 decode.
    assert_eq!(draws[0].natural_size, (1920.0, 1080.0));
    // The texture still carries the decoded dimensions.
    match &draws[0].source {
        DrawSource::Pixels { tex_w, tex_h, .. } => assert_eq!((*tex_w, *tex_h), (480, 270)),
        _ => panic!("expected a pixel source for a footage layer"),
    }
}

// Collapse (docs/06 §1.4): a collapsed Precomp splices its inner draws
// into the parent list with the parent's placement multiplied in front —
// no Nested intermediate. Off (or forced by a mask) renders Nested.
#[test]
fn collapsed_precomp_splices_inner_draws_with_parent_placement() {
    use lumit_core::model::{ProjectItem, TextDocument};
    let text_layer = || Layer {
        id: Uuid::now_v7(),
        name: "inner".into(),
        kind: LayerKind::Text {
            document: TextDocument {
                text: "hi".into(),
                size: 24.0,
                fill: LinearColour([1.0, 1.0, 1.0, 1.0]),
                extra: serde_json::Map::new(),
            },
        },
        in_point: CompTime(Rational::ZERO),
        out_point: CompTime(Rational::new(10, 1).unwrap()),
        start_offset: CompTime(Rational::ZERO),
        transform: TransformGroup::default(),
        matte: None,
        parent: None,
        label: 0,
        volume_db: lumit_core::anim::Property::zero(),
        retime: None,
        blend: Default::default(),
        masks: Vec::new(),
        paint: Vec::new(),
        effects: Vec::new(),
        switches: Switches::default(),
        extra: serde_json::Map::new(),
    };
    let nested = Composition {
        id: Uuid::now_v7(),
        name: "Nested".into(),
        width: 640,
        height: 360,
        frame_rate: FrameRate::new(60, 1).unwrap(),
        duration: Duration(Rational::new(10, 1).unwrap()),
        background: LinearColour::BLACK,
        work_area: None,
        layers: vec![text_layer()],
        markers: Vec::new(),
        motion_blur: Default::default(),
        extra: serde_json::Map::new(),
    };
    let nested_id = nested.id;
    let mut doc = Document::new();
    doc.items.push(ProjectItem::Composition(nested));

    let mut pre_layer = text_layer();
    pre_layer.kind = LayerKind::Precomp { comp: nested_id };
    pre_layer.switches.collapse = true;
    pre_layer.transform.position_x = lumit_core::anim::Property::fixed(100.0);
    pre_layer.transform.scale_x = lumit_core::anim::Property::fixed(200.0);
    let parent = Composition {
        id: Uuid::now_v7(),
        name: "Parent".into(),
        width: 1920,
        height: 1080,
        frame_rate: FrameRate::new(60, 1).unwrap(),
        duration: Duration(Rational::new(10, 1).unwrap()),
        background: LinearColour::BLACK,
        work_area: None,
        layers: vec![pre_layer.clone()],
        markers: Vec::new(),
        motion_blur: Default::default(),
        extra: serde_json::Map::new(),
    };
    let map: HashMap<Uuid, &CompLayerPixels> = HashMap::new();
    let mut visited = vec![parent.id];
    let draws = build_comp_draws(&doc, &parent, 0.0, &map, &mut visited);
    // Spliced: one draw, pixel source (the inner text), pre = the parent
    // Precomp layer's placement matrix — exactly the compositor's maths.
    assert_eq!(draws.len(), 1);
    assert!(matches!(draws[0].source, DrawSource::Pixels { .. }));
    let tr = &pre_layer.transform;
    let expect = lumit_gpu::place_matrix(
        (
            tr.position_x.value_at(0.0) as f32,
            tr.position_y.value_at(0.0) as f32,
        ),
        (
            tr.anchor_x.value_at(0.0) as f32,
            tr.anchor_y.value_at(0.0) as f32,
        ),
        (
            tr.scale_x.value_at(0.0) as f32,
            tr.scale_y.value_at(0.0) as f32,
        ),
        0.0,
        0.0,
        0.0,
        0.0,
    );
    assert_eq!(draws[0].pre, Some(expect));

    // Switch off → the Nested intermediate as before, no pre.
    let mut off = parent.clone();
    off.layers[0].switches.collapse = false;
    let mut visited = vec![off.id];
    let draws = build_comp_draws(&doc, &off, 0.0, &map, &mut visited);
    assert_eq!(draws.len(), 1);
    assert!(matches!(draws[0].source, DrawSource::Nested { .. }));
    assert!(draws[0].pre.is_none());

    // A mask on the Precomp layer forces the intermediate (§1.4) even
    // with the switch set.
    let mut forced = parent.clone();
    forced.layers[0]
        .masks
        .push(lumit_core::mask::Mask::rectangle(0.0, 0.0, 10.0, 10.0));
    let mut visited = vec![forced.id];
    let draws = build_comp_draws(&doc, &forced, 0.0, &map, &mut visited);
    assert_eq!(draws.len(), 1);
    assert!(matches!(draws[0].source, DrawSource::Nested { .. }));
}

// The live value-drag preview renders a comp patched with the provisional
// value. Patching a layer's Position X to 500 must show through as the
// draw's position, without touching the committed document.
#[test]
fn patch_layer_prop_overrides_the_previewed_value() {
    use lumit_core::model::TransformProp;
    let item = Uuid::now_v7();
    let layer = Layer {
        id: Uuid::now_v7(),
        name: "clip".into(),
        kind: LayerKind::Footage { item, retime: None },
        in_point: CompTime(Rational::ZERO),
        out_point: CompTime(Rational::new(10, 1).unwrap()),
        start_offset: CompTime(Rational::ZERO),
        transform: TransformGroup::default(),
        matte: None,
        parent: None,
        label: 0,
        volume_db: lumit_core::anim::Property::zero(),
        retime: None,
        blend: Default::default(),
        masks: Vec::new(),
        paint: Vec::new(),
        effects: Vec::new(),
        switches: Switches::default(),
        extra: serde_json::Map::new(),
    };
    let comp = Composition {
        id: Uuid::now_v7(),
        name: "Comp".into(),
        width: 1920,
        height: 1080,
        frame_rate: FrameRate::new(60, 1).unwrap(),
        duration: Duration(Rational::new(10, 1).unwrap()),
        background: LinearColour::BLACK,
        work_area: None,
        layers: vec![layer.clone()],
        markers: Vec::new(),
        motion_blur: Default::default(),
        extra: serde_json::Map::new(),
    };

    let patched = patch_layer_prop(&comp, layer.id, TransformProp::PositionX, 500.0);
    // The committed comp is untouched (default position 0).
    assert_eq!(comp.layers[0].transform.position_x.value_at(0.0), 0.0);

    let lp = CompLayerPixels {
        layer: layer.id,
        width: 1920,
        height: 1080,
        rgba: vec![0u8; 16],
        natural_w: 1920,
        natural_h: 1080,
        temporal: Vec::new(),
        flow_field: None,
    };
    let mut map: HashMap<Uuid, &CompLayerPixels> = HashMap::new();
    map.insert(layer.id, &lp);
    let doc = Document::new();
    let mut visited = vec![patched.id];
    let draws = build_comp_draws(&doc, &patched, 0.0, &map, &mut visited);
    assert_eq!(draws.len(), 1);
    assert_eq!(draws[0].position.0, 500.0);
}

/// An adjustment layer with a live stack emits an Adjust staging draw
/// above the content beneath it (docs/06 §1.5), carrying its resolved
/// effects, comp-sized geometry, and a comp-sized mask coverage; a dead
/// stack (fx switch off, everything disabled, or no effects) emits
/// nothing at all.
#[test]
fn a_live_adjustment_layer_emits_a_staging_draw() {
    let solid_def = Uuid::now_v7();
    let base = Layer {
        id: Uuid::now_v7(),
        name: "under".into(),
        kind: LayerKind::Solid { def: solid_def },
        in_point: CompTime(Rational::ZERO),
        out_point: CompTime(Rational::new(10, 1).unwrap()),
        start_offset: CompTime(Rational::ZERO),
        transform: TransformGroup::default(),
        matte: None,
        parent: None,
        label: 0,
        volume_db: lumit_core::anim::Property::zero(),
        retime: None,
        blend: Default::default(),
        masks: Vec::new(),
        paint: Vec::new(),
        effects: Vec::new(),
        switches: Switches::default(),
        extra: serde_json::Map::new(),
    };
    let mut adj = base.clone();
    adj.id = Uuid::now_v7();
    adj.name = "adjust".into();
    adj.kind = LayerKind::Adjustment;
    adj.effects
        .push(lumit_core::fx::instantiate("saturation").unwrap());
    adj.masks
        .push(lumit_core::mask::Mask::rectangle(0.0, 0.0, 960.0, 1080.0));
    let mut doc = Document::new();
    doc.items.push(lumit_core::model::ProjectItem::Solid(
        lumit_core::model::SolidDef {
            id: solid_def,
            name: "red".into(),
            colour: LinearColour([1.0, 0.0, 0.0, 1.0]),
            width: 1920,
            height: 1080,
            extra: serde_json::Map::new(),
        },
    ));
    let comp = Composition {
        id: Uuid::now_v7(),
        name: "Comp".into(),
        width: 1920,
        height: 1080,
        frame_rate: FrameRate::new(60, 1).unwrap(),
        duration: Duration(Rational::new(10, 1).unwrap()),
        background: LinearColour::BLACK,
        work_area: None,
        // Index 0 = top: the adjustment sits above the solid.
        layers: vec![adj.clone(), base.clone()],
        markers: Vec::new(),
        motion_blur: Default::default(),
        extra: serde_json::Map::new(),
    };
    let map: HashMap<Uuid, &CompLayerPixels> = HashMap::new();
    let mut visited = vec![comp.id];
    let draws = build_comp_draws(&doc, &comp, 0.0, &map, &mut visited);
    // Bottom-up: the solid first, then the staging point above it.
    assert_eq!(draws.len(), 2);
    assert!(matches!(draws[0].source, DrawSource::Pixels { .. }));
    assert!(matches!(draws[1].source, DrawSource::Adjust));
    assert_eq!(draws[1].natural_size, (1920.0, 1080.0));
    assert_eq!(draws[1].fx.len(), 1);
    let (_, cov_w, cov_h) = draws[1].mask_cov.as_ref().unwrap();
    assert_eq!((*cov_w, *cov_h), (1920, 1080));

    // Dead stacks emit nothing: fx switch off, all effects disabled,
    // or an empty stack.
    for edit in [
        &(|l: &mut Layer| l.switches.fx = false) as &dyn Fn(&mut Layer),
        &|l: &mut Layer| l.effects[0].enabled = false,
        &|l: &mut Layer| l.effects.clear(),
    ] {
        let mut dead = adj.clone();
        edit(&mut dead);
        let mut comp = comp.clone();
        comp.layers[0] = dead;
        let mut visited = vec![comp.id];
        let draws = build_comp_draws(&doc, &comp, 0.0, &map, &mut visited);
        assert_eq!(draws.len(), 1, "a dead adjustment stack must not stage");
        assert!(matches!(draws[0].source, DrawSource::Pixels { .. }));
    }
}

// --- K-119: Settings → Export filename template ------------------------

/// A paint stroke is stamped into the layer's own pixels before its masks gate
/// them (K-227) — the render side of the feature, checked where the pixels are
/// actually made rather than through a GPU nobody has on CI.
#[test]
fn a_paint_stroke_reaches_the_layers_pixels() {
    let solid_id = Uuid::now_v7();
    let mut layer = Layer {
        id: Uuid::now_v7(),
        name: "solid".into(),
        kind: LayerKind::Solid { def: solid_id },
        in_point: CompTime(Rational::ZERO),
        out_point: CompTime(Rational::new(10, 1).unwrap()),
        start_offset: CompTime(Rational::ZERO),
        transform: TransformGroup::default(),
        matte: None,
        parent: None,
        label: 0,
        volume_db: lumit_core::anim::Property::zero(),
        retime: None,
        blend: Default::default(),
        masks: Vec::new(),
        paint: Vec::new(),
        effects: Vec::new(),
        switches: Switches::default(),
        extra: serde_json::Map::new(),
    };
    let mut stroke = lumit_core::paint::PaintStroke::new("Brush 1", vec![(20.0, 20.0)]);
    stroke.width = 10.0;
    stroke.colour = LinearColour([1.0, 0.0, 0.0, 1.0]);
    layer.paint.push(stroke);

    let painted = Composition {
        id: Uuid::now_v7(),
        name: "Comp".into(),
        width: 40,
        height: 40,
        frame_rate: FrameRate::new(60, 1).unwrap(),
        duration: Duration(Rational::new(10, 1).unwrap()),
        background: LinearColour::BLACK,
        work_area: None,
        layers: vec![layer],
        markers: Vec::new(),
        motion_blur: Default::default(),
        extra: serde_json::Map::new(),
    };
    let mut doc = Document::new();
    doc.items.push(lumit_core::model::ProjectItem::Solid(
        lumit_core::model::SolidDef {
            id: solid_id,
            name: "White".into(),
            colour: LinearColour([1.0, 1.0, 1.0, 1.0]),
            width: 40,
            height: 40,
            extra: serde_json::Map::new(),
        },
    ));
    doc.items
        .push(lumit_core::model::ProjectItem::Composition(painted.clone()));

    let map: HashMap<Uuid, &CompLayerPixels> = HashMap::new();
    let mut visited = vec![painted.id];
    let draws = build_comp_draws(&doc, &painted, 0.0, &map, &mut visited);
    assert_eq!(draws.len(), 1);
    let DrawSource::Pixels { rgba, tex_w, .. } = &draws[0].source else {
        panic!("a solid draws pixels");
    };
    assert_eq!(
        *tex_w, 40,
        "a painted solid is rasterised at its real size, not as an 8x8 tile"
    );
    let px = |x: u32, y: u32| {
        let i = ((y * tex_w + x) as usize) * 4;
        [rgba[i], rgba[i + 1], rgba[i + 2]]
    };
    assert_eq!(px(20, 20), [255, 0, 0], "the stroke is in the picture");
    assert_eq!(px(2, 2), [255, 255, 255], "and the solid elsewhere");
}
