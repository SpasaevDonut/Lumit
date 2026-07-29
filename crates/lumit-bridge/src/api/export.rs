//! Writing a composition out to a file.
//!
//! # In plain terms
//!
//! Export is the one long-running job in Lumit. It does not block: you start it,
//! and then you ask how it is getting on. That is why this is three calls rather
//! than one — `start`, `poll`, `cancel` — and why nothing here returns a
//! finished file.
//!
//! Only one export runs at a time. Starting a second while one is in flight is
//! refused rather than queued, because two exports competing for the same GPU
//! would make both slower and neither predictable.

use flutter_rust_bridge::frb;
use serde_json::Value;

use crate::api::{composition::CompositionReference, BridgeError};

/// What the export dialogue is asking for.
///
/// `width`/`height` of zero mean "the composition's own size", which is what the
/// dialogue shows until somebody types over it. `bitrate_mbps` of zero means the
/// encoder's own default — a quality nobody chose is better than a number this
/// layer invented.
#[frb(non_opaque)]
#[derive(Debug, Clone, PartialEq)]
pub struct BridgeExportSpec {
    /// A delivery preset name, or empty for a custom export.
    pub preset: String,
    /// The output format key: `h264` / `hevc` for an `.mp4`, `png` / `tiff`
    /// for a numbered image sequence (K-201).
    pub codec: String,
    pub width: u32,
    pub height: u32,
    pub bitrate_mbps: u32,
    /// Output frame rate; zero means the composition's own. A different rate
    /// resamples by nearest comp frame over the same wall-clock span.
    pub fps: f64,
    /// Export range start, in comp frames. Negative means the default — the
    /// work area when one is set, else the whole comp.
    pub range_start_frame: i64,
    /// Export range end (exclusive), in comp frames. Negative = the default.
    pub range_end_frame: i64,
    pub include_audio: bool,
    /// Audio bits per second; zero takes the preset's own rate.
    pub audio_bit_rate: i64,
}

/// What a delivery preset fills the export dialogue with.
#[frb(non_opaque)]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeExportPreset {
    pub codec: String,
    /// Zero means "the composition's own size".
    pub width: u32,
    pub height: u32,
    /// Zero means the encoder's own default.
    pub bitrate_mbps: u32,
    /// The file name to suggest in the picker.
    pub default_name: String,
}

/// How a running export is getting on.
#[frb(non_opaque)]
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BridgeExportState {
    /// Nothing has run since start-up.
    Idle,
    Running {
        frame: u64,
        /// Zero until the exporter has worked out how many there are.
        total: u64,
        /// The encoder actually chosen, which may not be the one asked for —
        /// a hardware encoder that is not there falls back to software, and the
        /// dialogue should say so rather than claim what was requested.
        encoder: String,
    },
    Done {
        path: String,
    },
    Failed {
        error: String,
    },
}

impl CompositionReference {
    /// Start writing this composition to `path`.
    ///
    /// Returns once the job is *running*, not once it is finished — ask
    /// [`export_poll`] for that. An export already in flight is a calm error.
    #[frb(sync)]
    pub fn start_export(&self, spec: BridgeExportSpec, path: String) -> Result<(), BridgeError> {
        if path.trim().is_empty() {
            return Err(BridgeError::NoProjectPath);
        }
        let document = {
            let state = self.project()?;
            let state = state.read().map_err(|_| BridgeError::ReadFailed)?;
            state.store.snapshot()
        };

        // The exporter takes the dialogue's own JSON shape, which is also what
        // the egui frontend sends — one spec parser, so the two frontends cannot
        // export differently.
        let spec_json = serde_json::json!({
            "preset": spec.preset,
            "codec": spec.codec,
            "size": if spec.width == 0 || spec.height == 0 {
                Value::Null
            } else {
                serde_json::json!([spec.width, spec.height])
            },
            "bitrate_mbps": if spec.bitrate_mbps == 0 {
                String::new()
            } else {
                spec.bitrate_mbps.to_string()
            },
            "fps": spec.fps,
            "range": if spec.range_start_frame < 0
                || spec.range_end_frame <= spec.range_start_frame
            {
                Value::Null
            } else {
                serde_json::json!([spec.range_start_frame, spec.range_end_frame])
            },
            "include_audio": spec.include_audio,
            "audio_bit_rate": spec.audio_bit_rate,
        })
        .to_string();

        let reply = crate::export::start_export_with_document(document, self.id, &spec_json, &path);
        reply_ok(&reply).then_some(()).ok_or_else(|| {
            BridgeError::ExportFailed(reply_error(&reply).unwrap_or_else(|| "export".into()))
        })
    }
}

/// What a delivery preset stamps into the dialogue, and what to call the file.
///
/// A blank `preset` gives the custom defaults. `template` drives the
/// `{comp}`/`{preset}`/`{date}` substitution (K-119); blank yields the preset's
/// own suggested name.
#[frb(sync)]
pub fn export_preset(preset: String, comp_name: String, template: String) -> BridgeExportPreset {
    let reply = crate::export::export_preset(&preset, &comp_name, &template);
    let Ok(Value::Object(map)) = serde_json::from_str::<Value>(&reply) else {
        return BridgeExportPreset {
            codec: "h264".into(),
            width: 0,
            height: 0,
            bitrate_mbps: 0,
            default_name: String::new(),
        };
    };
    let size = map.get("size").and_then(Value::as_array);
    BridgeExportPreset {
        codec: map
            .get("codec")
            .and_then(|v| v.as_str())
            .unwrap_or("h264")
            .to_owned(),
        width: size
            .and_then(|a| a.first())
            .and_then(Value::as_u64)
            .unwrap_or(0) as u32,
        height: size
            .and_then(|a| a.get(1))
            .and_then(Value::as_u64)
            .unwrap_or(0) as u32,
        bitrate_mbps: map
            .get("bitrate_mbps")
            .and_then(|v| v.as_str())
            .and_then(|s| s.parse().ok())
            .unwrap_or(0),
        default_name: map
            .get("default_name")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_owned(),
    }
}

/// How the running export is getting on. Safe to call on the interface's own
/// cadence: it drains a channel and reads a few numbers.
#[frb(sync)]
pub fn export_poll() -> BridgeExportState {
    let reply = crate::export::export_poll();
    let Ok(Value::Object(map)) = serde_json::from_str::<Value>(&reply) else {
        return BridgeExportState::Idle;
    };
    let string = |key: &str| {
        map.get(key)
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_owned()
    };
    let number = |key: &str| map.get(key).and_then(Value::as_u64).unwrap_or(0);

    match map.get("state").and_then(|v| v.as_str()) {
        Some("running") => BridgeExportState::Running {
            frame: number("frame"),
            total: number("total"),
            encoder: string("encoder"),
        },
        Some("done") => BridgeExportState::Done {
            path: string("path"),
        },
        Some("failed") => BridgeExportState::Failed {
            error: string("error"),
        },
        _ => BridgeExportState::Idle,
    }
}

/// Ask the running export to stop. It finishes the frame it is on and then
/// reports `Failed` with "cancelled" — a cancelled export leaves no half-file
/// pretending to be a finished one.
#[frb(sync)]
pub fn export_cancel() {
    let _ = crate::export::export_cancel();
}

#[frb(ignore)]
fn reply_ok(reply: &str) -> bool {
    serde_json::from_str::<Value>(reply)
        .ok()
        .and_then(|v| v.get("ok").and_then(Value::as_bool))
        .unwrap_or(false)
}

#[frb(ignore)]
fn reply_error(reply: &str) -> Option<String> {
    serde_json::from_str::<Value>(reply)
        .ok()
        .and_then(|v| v.get("error").and_then(|e| e.as_str().map(str::to_owned)))
}
