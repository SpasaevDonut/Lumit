//! The bridge v0.5 layer-identity ops: rename, convert-to-sequenced, and
//! trim-to-source-end.
//!
//! # In plain terms
//!
//! These are three of the commands the timeline's layer menu offers — rename a
//! layer, convert a footage layer into an editable Sequence layer, and trim a
//! retimed clip to where its source runs out. Each routes through the same
//! [`lumit_core::ops::Op`] the egui frontend commits (`RenameLayer`, the
//! convert batch, `SetLayerSpan`), so undo is one clean step and the two
//! frontends cannot drift.
//!
//! The project-item ops that shared this file — delete, rename, move-to-root
//! and relink — went with the frb port of the Project panel; their replacements
//! are methods on `api::project_item::ItemReference`.

use crate::err_json;
use crate::state::{commit, parse_comp_layer, Bridge};
use lumit_core::model::{Composition, Layer, LayerKind};
use lumit_core::ops::Op;
use lumit_core::sequence::{Clip, ClipSource};
use lumit_core::time::Rational;
use uuid::Uuid;

// ---------------------------------------------------------------------------
// Layer-identity ops.
// ---------------------------------------------------------------------------

/// Rename a layer — the outline's inline rename ([`Op::RenameLayer`]). A blank
/// name is refused calmly; an unknown comp/layer is a calm error.
pub(crate) fn rename_layer(
    bridge: &mut Bridge,
    comp_id: &str,
    layer_id: &str,
    name: &str,
) -> String {
    let (comp, layer) = match parse_comp_layer(comp_id, layer_id) {
        Ok(pair) => pair,
        Err(e) => return err_json(format!("rename layer: {e}")),
    };
    if name.trim().is_empty() {
        return err_json("rename layer: the name cannot be empty");
    }
    commit(
        bridge,
        Op::RenameLayer {
            comp,
            layer,
            name: name.to_owned(),
        },
        "rename layer",
    )
}

/// Resolve a comp id, layer id and the layer (cloned), or a calm error.
fn resolve_layer(
    bridge: &Bridge,
    comp_id: &str,
    layer_id: &str,
    ctx: &str,
) -> Result<(Uuid, Composition, Layer, usize), String> {
    let (comp, layer) = parse_comp_layer(comp_id, layer_id).map_err(|e| format!("{ctx}: {e}"))?;
    let doc = bridge.store.snapshot();
    let c = doc
        .comp(comp)
        .cloned()
        .ok_or_else(|| format!("{ctx}: unknown composition"))?;
    let index = c
        .layers
        .iter()
        .position(|l| l.id == layer)
        .ok_or_else(|| format!("{ctx}: unknown layer"))?;
    let l = c.layers[index].clone();
    Ok((comp, c, l, index))
}

/// Convert a footage layer into an editable Sequence layer holding one clip —
/// `lumit-ui`'s `convert_to_sequenced_layer` (K-071): one batch (`RemoveLayer` +
/// `AddLayer` at the same index and id), so it is a true in-place conversion and
/// one undo step. The clip takes the media's own duration when probed, else the
/// layer's span length. Only a footage layer converts; anything else is a calm
/// error.
pub(crate) fn convert_to_sequenced(bridge: &mut Bridge, comp_id: &str, layer_id: &str) -> String {
    let ctx = "convert to sequenced";
    let (comp, _c, layer, index) = match resolve_layer(bridge, comp_id, layer_id, ctx) {
        Ok(t) => t,
        Err(e) => return err_json(e),
    };
    let LayerKind::Footage { item, retime } = &layer.kind else {
        return err_json(format!("{ctx}: only footage layers convert to sequenced"));
    };
    // Footage duration → the clip's source/place length. Probed media wins;
    // otherwise the layer's own span length (both floored to one frame's worth).
    let span_s = (layer.out_point.0.to_f64() - layer.in_point.0.to_f64()).max(0.04);
    #[cfg(feature = "media")]
    let dur_s = match bridge.media.get(item) {
        // `duration_seconds` is the container's real duration, valid for both
        // video and audio-only media (unlike `duration_frames`, a video-only
        // frame count that is 0 for audi only files).
        Some(crate::media::MediaStatus::Ok(info)) if info.duration_seconds > 0.0 => {
            info.duration_seconds
        }
        _ => span_s,
    };
    #[cfg(not(feature = "media"))]
    let dur_s = span_s;
    let dur = Rational::from_f64_on_grid(dur_s.max(0.04), Rational::FLICK_DEN)
        .unwrap_or(layer.out_point.0);
    let clip = Clip {
        id: Uuid::now_v7(),
        source: ClipSource::Footage(*item),
        source_in: Rational::ZERO,
        source_out: dur,
        place_start: Rational::ZERO,
        place_duration: dur,
        retime: retime
            .clone()
            .unwrap_or_else(|| lumit_core::retime::Retime::identity(dur, Rational::ZERO)),
        interpolation: Default::default(),
        extra: serde_json::Map::new(),
    };
    let mut new_layer = layer.clone();
    new_layer.kind = LayerKind::Sequence { clips: vec![clip] };
    commit(
        bridge,
        Op::Batch {
            ops: vec![
                Op::RemoveLayer {
                    comp,
                    layer: layer.id,
                },
                Op::AddLayer {
                    comp,
                    index,
                    layer: Box::new(new_layer),
                },
            ],
        },
        ctx,
    )
}

/// Trim a retimed footage layer so it ends exactly where the retime runs out of
/// source — `lumit-ui`'s `trim_selected_to_source_end` (K-022): no ripple, an
/// explicit command the overrun indicator invites. Needs the media's source
/// duration (media feature): a clip that does not overrun, or an unprobed
/// source, is a calm note rather than a change. Without the `media` feature the
/// source length is unknown, so this reports that calmly.
pub(crate) fn trim_to_source_end(bridge: &mut Bridge, comp_id: &str, layer_id: &str) -> String {
    let ctx = "trim to source end";
    let (comp, _c, layer, _index) = match resolve_layer(bridge, comp_id, layer_id, ctx) {
        Ok(t) => t,
        Err(e) => return err_json(e),
    };
    let LayerKind::Footage {
        item,
        retime: Some(rt),
    } = &layer.kind
    else {
        return err_json(format!("{ctx}: select a retimed footage layer"));
    };
    #[cfg(feature = "media")]
    {
        let src_dur = match bridge.media.get(item) {
            Some(crate::media::MediaStatus::Ok(info)) if info.fps_num > 0 => {
                info.duration_frames as f64 * f64::from(info.fps_den) / f64::from(info.fps_num)
            }
            _ => return err_json(format!("{ctx}: the source has not been probed")),
        };
        let src_r = Rational::from_f64_on_grid(src_dur, 1000).unwrap_or(Rational::ONE);
        let Some(ot) = rt.overrun_local_time(src_r) else {
            return err_json(format!("{ctx}: this clip doesn't run out of source"));
        };
        let new_out = layer.start_offset.0.to_f64() + ot;
        let out_point = lumit_core::time::CompTime(
            Rational::from_f64_on_grid(new_out, 1000).unwrap_or(layer.out_point.0),
        );
        commit(
            bridge,
            Op::SetLayerSpan {
                comp,
                layer: layer.id,
                in_point: layer.in_point,
                out_point,
                start_offset: layer.start_offset,
            },
            ctx,
        )
    }
    #[cfg(not(feature = "media"))]
    {
        let _ = (bridge, item, comp, rt);
        err_json(format!(
            "{ctx}: the source length is unknown without the media feature"
        ))
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use crate::edits::{add_camera_layer, add_footage_layer};
    use lumit_core::model::ProjectItem;
    use crate::state::{import_footage, new_composition, snapshot, undo};
    use serde_json::{json, Value};

    fn parse(s: &str) -> Value {
        serde_json::from_str(s).expect("reply is valid JSON")
    }

    fn comp_id(b: &Bridge) -> String {
        b.store
            .snapshot()
            .items
            .iter()
            .find_map(|i| match i {
                ProjectItem::Composition(c) => Some(c.id),
                _ => None,
            })
            .expect("a comp exists")
            .to_string()
    }

    fn find_comp(snap: &Value) -> Value {
        for item in snap["items"].as_array().unwrap() {
            if item["kind"] == json!("composition") {
                return item.clone();
            }
            for child in item["children"].as_array().unwrap() {
                if child["kind"] == json!("composition") {
                    return child.clone();
                }
            }
        }
        panic!("no composition in snapshot");
    }

    #[test]
    fn rename_layer_changes_the_name_and_undoes() {
        let mut b = Bridge::new();
        new_composition(&mut b, "Scene");
        let comp = comp_id(&b);
        add_camera_layer(&mut b, &comp);
        let snap = parse(&snapshot(&b));
        let layer = find_comp(&snap)["comp"]["layers"][0]["id"]
            .as_str()
            .unwrap()
            .to_owned();
        let snap = parse(&rename_layer(&mut b, &comp, &layer, "Hero"));
        assert_eq!(find_comp(&snap)["comp"]["layers"][0]["name"], json!("Hero"));
        let after = parse(&undo(&mut b));
        assert_eq!(
            find_comp(&after)["comp"]["layers"][0]["name"],
            json!("Camera")
        );
    }

    #[test]
    fn convert_to_sequenced_swaps_the_kind_in_place() {
        let mut b = Bridge::new();
        new_composition(&mut b, "Scene");
        let comp = comp_id(&b);
        import_footage(&mut b, "/media/clip.mp4");
        let item = b
            .store
            .snapshot()
            .items
            .iter()
            .find_map(|i| match i {
                ProjectItem::Footage(f) => Some(f.id),
                _ => None,
            })
            .unwrap()
            .to_string();
        add_footage_layer(&mut b, &comp, &item);
        let snap = parse(&snapshot(&b));
        let layer = find_comp(&snap)["comp"]["layers"][0]["id"]
            .as_str()
            .unwrap()
            .to_owned();
        let snap = parse(&convert_to_sequenced(&mut b, &comp, &layer));
        assert_eq!(snap["ok"], json!(true));
        let l = find_comp(&snap)["comp"]["layers"][0].clone();
        assert_eq!(l["kind"], json!("sequence"));
        // The layer keeps its id (a true in-place conversion).
        assert_eq!(l["id"].as_str().unwrap(), layer);
        // One undo restores the footage layer.
        let after = parse(&undo(&mut b));
        assert_eq!(
            find_comp(&after)["comp"]["layers"][0]["kind"],
            json!("footage")
        );
    }

    #[test]
    fn convert_refuses_a_non_footage_layer() {
        let mut b = Bridge::new();
        new_composition(&mut b, "Scene");
        let comp = comp_id(&b);
        add_camera_layer(&mut b, &comp);
        let snap = parse(&snapshot(&b));
        let layer = find_comp(&snap)["comp"]["layers"][0]["id"]
            .as_str()
            .unwrap()
            .to_owned();
        let reply = parse(&convert_to_sequenced(&mut b, &comp, &layer));
        assert_eq!(reply["ok"], json!(false));
        assert!(reply["error"].as_str().unwrap().contains("only footage"));
    }

    #[test]
    fn trim_to_source_end_without_a_retime_is_a_calm_note() {
        let mut b = Bridge::new();
        new_composition(&mut b, "Scene");
        let comp = comp_id(&b);
        import_footage(&mut b, "/media/clip.mp4");
        let item = b
            .store
            .snapshot()
            .items
            .iter()
            .find_map(|i| match i {
                ProjectItem::Footage(f) => Some(f.id),
                _ => None,
            })
            .unwrap()
            .to_string();
        add_footage_layer(&mut b, &comp, &item);
        let snap = parse(&snapshot(&b));
        let layer = find_comp(&snap)["comp"]["layers"][0]["id"]
            .as_str()
            .unwrap()
            .to_owned();
        let reply = parse(&trim_to_source_end(&mut b, &comp, &layer));
        assert_eq!(reply["ok"], json!(false));
        assert!(reply["error"].as_str().unwrap().contains("retimed footage"));
    }
}
