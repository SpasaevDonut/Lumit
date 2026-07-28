//! Export (docs/06-RENDER-PIPELINE.md §7): render every work-area frame
//! through the compositor at full resolution and encode to H.264/mp4.
//!
//! In plain terms: the same pixels the Viewer shows, written to a file — the
//! preview-equals-export promise (K-031) holds because this path reuses the
//! identical colour engine and compositor. Precomp layers render recursively:
//! the nested comp becomes a texture the parent composites like any other
//! source. Runs on its own thread with its own decoders (K-017); progress
//! streams back; cancel is checked every frame.

use lumit_core::model::{Document, ProjectItem};
pub use lumit_core::pixels::{px_tile, solid_rgba, srgb_decode, srgb_encode};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::Arc;
use uuid::Uuid;

pub enum ExportEvent {
    /// Which encoder the ladder settled on ("NVENC", "software x264", …),
    /// sent once the file is open.
    Encoder(&'static str),
    Progress {
        frame: usize,
        total: usize,
    },
    Done(PathBuf),
    Failed(String),
}

pub struct ExportHandle {
    pub events: Receiver<ExportEvent>,
    cancel: Arc<AtomicBool>,
}

impl ExportHandle {
    pub fn cancel(&self) {
        self.cancel.store(true, Ordering::Relaxed);
    }
}

/// Everything the export thread needs about one footage item.
#[derive(Clone)]
pub struct ItemInfo {
    pub path: PathBuf,
    pub fps: f64,
    pub frames: usize,
    /// The file could not be found (docs/07 §3.3): render the test-bar slate
    /// at this size rather than decoding. `Some((w, h))` carries the comp's
    /// dimensions — the preview sizes a missing layer the same way, since a
    /// file we cannot open has no size of its own, and the two must agree or
    /// the layer's geometry would differ between them. Export must match the
    /// preview (K-031): an export that quietly dropped a missing layer to
    /// black while the Viewer showed bars would hide the mistake in the
    /// delivered file, which is precisely what the slate prevents.
    pub missing: Option<(u32, u32)>,
}

/// One audio-bearing layer, as the export thread needs it: where its file
/// is, its comp-timeline span, its start offset, and its Volume (the same
/// set the preview mix uses, so export audio matches playback).
#[derive(Clone, PartialEq)]
pub struct AudioJob {
    /// The footage item the audio comes from — the key the preview path uses
    /// to reuse an already-decoded buffer instead of re-decoding the file.
    pub item: uuid::Uuid,
    pub path: PathBuf,
    pub in_s: f64,
    pub out_s: f64,
    pub offset_s: f64,
    /// The layer's Volume property (dB, docs/09 §6): static values become a
    /// constant gain; keyframed ones bake to a control-rate envelope.
    pub volume: lumit_core::anim::Property,
    /// Enclosing Precomp layers' Volumes (outermost first), each with the
    /// outer-comp time where its layer time 0 sits — a precomp's Volume
    /// scales everything inside it, so the gains multiply through the chain.
    pub carriers: Vec<(lumit_core::anim::Property, f64)>,
}

/// Bake one job's Volume — its own dB property times every carrier's — for
/// its placed span: `(constant gain, envelope)`. All-static chains are
/// exactly their constant product (envelope None); any animated link bakes
/// the whole chain to a ~10 ms control-rate curve, each property sampled in
/// its own layer time (`lt = comp time − its offset`).
pub fn volume_bake(
    job: &AudioJob,
    start_frame: i64,
    len: usize,
    rate: u32,
) -> (f32, Option<lumit_audio::mix::GainEnvelope>) {
    let gain_at = |t: f64| {
        let mut g = lumit_audio::mix::db_to_gain(job.volume.value_at(t - job.offset_s));
        for (prop, off) in &job.carriers {
            g *= lumit_audio::mix::db_to_gain(prop.value_at(t - off));
        }
        g
    };
    let animated = job.volume.is_animated() || job.carriers.iter().any(|(p, _)| p.is_animated());
    if !animated {
        return (gain_at(0.0), None);
    }
    let stride = (rate / 100).max(1);
    let n = len / stride as usize + 2;
    let points = (0..n)
        .map(|p| {
            let t = (start_frame + p as i64 * i64::from(stride)) as f64 / f64::from(rate);
            gain_at(t)
        })
        .collect();
    (1.0, Some(lumit_audio::mix::GainEnvelope { stride, points }))
}

/// Delivery presets (docs/06-RENDER-PIPELINE.md §7.5): frame, codec, and
/// bitrates as data, not code. Custom keeps the comp's own size and the
/// dialogue's choices; it is also the default (Settings → Export, K-119),
/// matching the implicit behaviour every "Export…" action had before that
/// setting existed.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default, serde::Serialize, serde::Deserialize)]
pub enum ExportPreset {
    #[default]
    Custom,
    Youtube1080p60,
    Youtube1440p60,
    Youtube4k60,
    Vertical1080p60,
}

/// The parameter row one preset stamps into the export dialogue.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct PresetParams {
    pub size: (u32, u32),
    pub codec: lumit_media::encode::VideoCodec,
    /// VBR average target, bits/second.
    pub target_bps: i64,
    /// VBR peak, bits/second.
    pub peak_bps: i64,
}

/// Audio on all delivery presets: AAC 320 kbps, 48 kHz (docs/06 §7.5).
pub const PRESET_AUDIO_BPS: i64 = 320_000;
/// Export audio sample rate (docs/06 §7.5: 48 kHz on delivery presets).
pub const EXPORT_AUDIO_RATE: u32 = 48_000;

impl ExportPreset {
    pub const ALL: [ExportPreset; 5] = [
        ExportPreset::Custom,
        ExportPreset::Youtube1080p60,
        ExportPreset::Youtube1440p60,
        ExportPreset::Youtube4k60,
        ExportPreset::Vertical1080p60,
    ];

    pub fn label(self) -> &'static str {
        match self {
            ExportPreset::Custom => "Custom (comp size)",
            ExportPreset::Youtube1080p60 => "YouTube 1080p60",
            ExportPreset::Youtube1440p60 => "YouTube 1440p60",
            ExportPreset::Youtube4k60 => "YouTube 4K60",
            ExportPreset::Vertical1080p60 => "Vertical 1080×1920p60",
        }
    }

    /// The parameters this preset stamps; None for Custom (the dialogue's
    /// own fields apply).
    pub fn params(self) -> Option<PresetParams> {
        use lumit_media::encode::VideoCodec;
        match self {
            ExportPreset::Custom => None,
            // H.264 high, VBR 16 target / 24 peak (docs/06 §7.5).
            ExportPreset::Youtube1080p60 => Some(PresetParams {
                size: (1920, 1080),
                codec: VideoCodec::H264,
                target_bps: 16_000_000,
                peak_bps: 24_000_000,
            }),
            // HEVC (H.264 fallback), VBR 25 target / 35 peak — YouTube's
            // 1440p60 band (docs/06 §7.5).
            ExportPreset::Youtube1440p60 => Some(PresetParams {
                size: (2560, 1440),
                codec: VideoCodec::Hevc,
                target_bps: 25_000_000,
                peak_bps: 35_000_000,
            }),
            // HEVC (the ladder falls back to x265 when no hardware offers
            // it), VBR 45 target / 60 peak — YouTube's 2160p60 band.
            ExportPreset::Youtube4k60 => Some(PresetParams {
                size: (3840, 2160),
                codec: VideoCodec::Hevc,
                target_bps: 45_000_000,
                peak_bps: 60_000_000,
            }),
            // The vertical variant of the 1080p60 preset (docs/06 §7.5).
            ExportPreset::Vertical1080p60 => Some(PresetParams {
                size: (1080, 1920),
                codec: VideoCodec::H264,
                target_bps: 16_000_000,
                peak_bps: 24_000_000,
            }),
        }
    }

    /// Suggested file name for the save dialogue.
    pub fn default_file_name(self) -> &'static str {
        match self {
            ExportPreset::Custom => "export.mp4",
            ExportPreset::Youtube1080p60 => "youtube-1080p60.mp4",
            ExportPreset::Youtube1440p60 => "youtube-1440p60.mp4",
            ExportPreset::Youtube4k60 => "youtube-4k60.mp4",
            ExportPreset::Vertical1080p60 => "vertical-1080x1920.mp4",
        }
    }
}

/// Everything one queued export needs beyond the document snapshot: the
/// resolved output size, codec, rates, and whether audio joins.
#[derive(Clone)]
pub struct ExportSpec {
    pub codec: lumit_media::encode::VideoCodec,
    pub target: (u32, u32),
    /// Average video bitrate in bits/second; None = encoder default quality.
    pub bit_rate: Option<i64>,
    /// VBR peak in bits/second.
    pub max_rate: Option<i64>,
    pub include_audio: bool,
    pub audio_bit_rate: i64,
}

/// One export waiting its turn. The document and audio jobs are snapshotted
/// at queue time (docs/06 §7.1): later edits never alter a queued item.
pub struct QueuedExport {
    pub doc: Arc<Document>,
    pub comp_id: Uuid,
    pub items: HashMap<Uuid, ItemInfo>,
    pub audio: Vec<AudioJob>,
    pub out_path: PathBuf,
    pub spec: ExportSpec,
}

pub fn start(
    doc: Arc<Document>,
    comp_id: Uuid,
    audio: Vec<AudioJob>,
    out_path: PathBuf,
    spec: ExportSpec,
) -> ExportHandle {
    let (tx, events) = channel();
    let cancel = Arc::new(AtomicBool::new(false));
    let flag = cancel.clone();
    std::thread::spawn(move || {
        let result = run(&doc, comp_id, &audio, &out_path, &spec, &tx, &flag);
        let _ = match result {
            Ok(()) if flag.load(Ordering::Relaxed) => {
                let _ = std::fs::remove_file(&out_path); // no half files
                tx.send(ExportEvent::Failed("cancelled".into()))
            }
            Ok(()) => tx.send(ExportEvent::Done(out_path)),
            Err(e) => {
                let _ = std::fs::remove_file(&out_path);
                tx.send(ExportEvent::Failed(e))
            }
        };
    });
    ExportHandle { events, cancel }
}

/// Decode every audio job (resampled to `rate`), lay each on the comp strip
/// at its offset and trim, and sum — the one mixdown all comp audio flows
/// through: preview playback, beat detection, and export, so they cannot
/// disagree about what the comp sounds like.
pub fn mixdown(jobs: &[AudioJob], rate: u32, duration_s: f64) -> Vec<f32> {
    let decoded: Vec<(lumit_media::AudioBuffer, &AudioJob)> = jobs
        .iter()
        .filter_map(|job| {
            lumit_media::audio::decode_all(&job.path, rate)
                .ok()
                .map(|buf| (buf, job))
        })
        .collect();
    let borrowed: Vec<(&lumit_media::AudioBuffer, &AudioJob)> =
        decoded.iter().map(|(b, j)| (b, *j)).collect();
    mix_decoded(&borrowed, rate, duration_s)
}

/// As [`mixdown`], but over already-decoded buffers — the preview path's
/// fast re-mix (docs/09 §2 lazy-decode direction): a solo/mute/trim edit
/// re-sums cached buffers in seconds instead of re-decoding whole files.
pub fn mixdown_prepared(
    decoded: &[(std::sync::Arc<lumit_media::AudioBuffer>, AudioJob)],
    rate: u32,
    duration_s: f64,
) -> Vec<f32> {
    let borrowed: Vec<(&lumit_media::AudioBuffer, &AudioJob)> =
        decoded.iter().map(|(b, j)| (b.as_ref(), j)).collect();
    mix_decoded(&borrowed, rate, duration_s)
}

/// The shared placement + sum over decoded buffers (each already at `rate`).
fn mix_decoded(
    decoded: &[(&lumit_media::AudioBuffer, &AudioJob)],
    rate: u32,
    duration_s: f64,
) -> Vec<f32> {
    let total_frames = (duration_s * f64::from(rate)).round().max(0.0) as usize;
    let placements: Vec<lumit_audio::mix::PlacedAudio> = decoded
        .iter()
        .filter_map(|(buf, job)| {
            let (start_frame, src_start, len) = lumit_audio::mix::place_on_timeline(
                job.in_s,
                job.out_s,
                job.offset_s,
                buf.samples.len() / 2,
                rate,
            )?;
            let (gain, envelope) = volume_bake(job, start_frame, len, rate);
            Some(lumit_audio::mix::PlacedAudio {
                start_frame,
                samples: &buf.samples[src_start * 2..(src_start + len) * 2],
                gain,
                envelope,
            })
        })
        .collect();
    lumit_audio::mix::mix_stereo(&placements, total_frames)
}

/// How many audio samples (per channel) belong before the end of video
/// frame `frame_count` — the A/V interleaving rule. Cumulative rounding, so
/// the running total never drifts from `frames / fps × rate`.
pub fn audio_samples_through(frame_count: usize, fps: f64, rate: u32) -> usize {
    if fps <= 0.0 {
        return 0;
    }
    ((frame_count as f64 / fps) * f64::from(rate)).round() as usize
}

fn run(
    doc: &Document,
    comp_id: Uuid,
    audio_jobs: &[AudioJob],
    out_path: &std::path::Path,
    spec: &ExportSpec,
    tx: &Sender<ExportEvent>,
    cancel: &AtomicBool,
) -> Result<(), String> {
    let comp = doc.comp(comp_id).ok_or("composition missing")?;
    let fps = comp.frame_rate.fps().max(1.0);
    let comp_frames = (comp.duration.0.to_f64() * fps).round().max(1.0) as usize;
    // The work area is the export range (docs/01-GLOSSARY.md; K-037 relies on it).
    let (first, end) = match comp.work_area {
        Some((a, b)) => {
            let s = ((a.0.to_f64() * fps).round() as usize).min(comp_frames.saturating_sub(1));
            let e = ((b.0.to_f64() * fps).round() as usize).clamp(s + 1, comp_frames);
            (s, e)
        }
        None => (0, comp_frames),
    };
    let total = end - first;
    let _ = tx.send(ExportEvent::Progress { frame: 0, total });

    // The comp's audio, mixed exactly as playback mixes it, then cut to the
    // export range and padded so sound and picture end together.
    let rate = EXPORT_AUDIO_RATE;
    let audio_mix: Option<Vec<f32>> = if spec.include_audio && !audio_jobs.is_empty() {
        let full = mixdown(audio_jobs, rate, comp.duration.0.to_f64());
        if cancel.load(Ordering::Relaxed) {
            return Ok(());
        }
        let start = audio_samples_through(first, fps, rate).min(full.len() / 2);
        let expect = audio_samples_through(total, fps, rate);
        let mut cut = full[start * 2..(start + expect).min(full.len() / 2) * 2].to_vec();
        cut.resize(expect * 2, 0.0);
        Some(cut)
    } else {
        None
    };

    // The export renders through the SAME walk the Viewer does — the headless
    // preview at full decode quality (K-031: preview == export by
    // construction, gated by the bit-identity matrix in `headless::tests`).
    // Its own renderer on its own device, so an export never contends with the
    // Viewer's GPU work.
    let mut renderer =
        crate::headless::HeadlessRenderer::new().map_err(|e| format!("export renderer: {e}"))?;
    // Encoded frame dimensions must be even for 4:2:0 H.264/HEVC.
    let (tw, th) = (spec.target.0 & !1, spec.target.1 & !1);
    let (tw, th) = (tw.max(2), th.max(2));
    let resize = (tw, th) != (comp.width, comp.height);
    let audio_settings = audio_mix
        .as_ref()
        .map(|_| lumit_media::encode::AudioSettings {
            rate,
            bit_rate: spec.audio_bit_rate,
        });
    let mut encoder = lumit_media::Encoder::open(
        out_path,
        &lumit_media::encode::VideoSettings {
            codec: spec.codec,
            width: tw,
            height: th,
            fps_num: i32::try_from(comp.frame_rate.fps().round() as i64).unwrap_or(60),
            fps_den: 1,
            bit_rate: spec.bit_rate,
            max_rate: spec.max_rate,
        },
        audio_settings.as_ref(),
    )
    .map_err(|e| e.to_string())?;
    let _ = tx.send(ExportEvent::Encoder(encoder.encoder_label()));

    let mut audio_fed = 0usize;
    for frame_n in 0..total {
        if cancel.load(Ordering::Relaxed) {
            return Ok(());
        }
        let (rgba, _, _) = renderer.render_preview(
            doc,
            comp_id,
            (first + frame_n) as u64,
            crate::plan::Quality::default(),
            1.0,
            None,
        )?;
        // Letterbox into the delivery frame when a preset changes the size.
        let rgba = if resize {
            lumit_core::pixels::letterbox_resize(&rgba, comp.width, comp.height, tw, th)
        } else {
            rgba
        };
        encoder.write_rgba(&rgba).map_err(|e| e.to_string())?;
        // Interleave: after each picture frame, the samples that cover it,
        // so the muxer keeps sound and picture together in the file.
        if let Some(mix) = &audio_mix {
            let upto = audio_samples_through(frame_n + 1, fps, rate).min(mix.len() / 2);
            if upto > audio_fed {
                encoder
                    .write_audio(&mix[audio_fed * 2..upto * 2])
                    .map_err(|e| e.to_string())?;
                audio_fed = upto;
            }
        }
        let _ = tx.send(ExportEvent::Progress {
            frame: frame_n + 1,
            total,
        });
    }
    // Any samples the per-frame rounding left behind.
    if let Some(mix) = &audio_mix {
        if mix.len() / 2 > audio_fed {
            encoder
                .write_audio(&mix[audio_fed * 2..])
                .map_err(|e| e.to_string())?;
        }
    }
    encoder.finish().map_err(|e| e.to_string())?;
    Ok(())
}

/// Coverage bytes → white RGBA whose alpha is the coverage (the layer-mask
/// texture format the compositor samples).
pub fn mask_rgba(coverage: &[u8]) -> Vec<u8> {
    coverage.iter().flat_map(|c| [255, 255, 255, *c]).collect()
}

/// CameraPose (core model) -> GPU camera matrix: the single conversion both
/// the preview and the export path share, so they cannot disagree (K-031).
pub fn camera_mat(
    comp_w: u32,
    comp_h: u32,
    pose: lumit_core::model::CameraPose,
) -> lumit_gpu::Mat4 {
    lumit_gpu::camera_matrix(
        comp_w as f32,
        comp_h as f32,
        pose.zoom as f32,
        (
            pose.position.0 as f32,
            pose.position.1 as f32,
            pose.position.2 as f32,
        ),
        (
            pose.rotation_deg.0 as f32,
            pose.rotation_deg.1 as f32,
            pose.rotation_deg.2 as f32,
        ),
    )
}

/// Collect the ItemInfo map from probed media (cheap — it only reads the
/// frontend's probe cache, never touches disk). `slate_size` is the exported
/// comp's dimensions, used to size the missing-footage slate exactly as the
/// preview does.
pub fn item_infos(
    doc: &Document,
    probes: &dyn crate::source::SourceProbes,
    slate_size: (u32, u32),
) -> HashMap<Uuid, ItemInfo> {
    let mut map = HashMap::new();
    for item in &doc.items {
        let ProjectItem::Footage(f) = item else {
            continue;
        };
        let probe = probes.probe(f.id);
        if let Some((fps, _w, _h, frames)) = probe.video() {
            map.insert(
                f.id,
                ItemInfo {
                    path: PathBuf::from(&f.media.absolute_path),
                    fps,
                    frames,
                    missing: None,
                },
            );
        } else if probe.slates() {
            // Missing/unreadable media is carried, not skipped, so export
            // renders the same slate the Viewer shows (K-031). Audio-only and
            // unprobed items are simply absent: no picture, and — crucially —
            // no slate over a perfectly healthy sound file.
            map.insert(
                f.id,
                ItemInfo {
                    path: PathBuf::from(&f.media.absolute_path),
                    fps: 1.0,
                    frames: 1,
                    missing: Some(slate_size),
                },
            );
        }
    }
    map
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use lumit_media::encode::VideoCodec;

    /// Volume baking (docs/09 §6): a static Volume is exactly its constant
    /// gain; a keyframed fade becomes a control-rate envelope sampled in
    /// layer time (comp time − start offset), falling to true zero at the
    /// −inf knee.
    #[test]
    fn volume_bake_static_gain_and_animated_envelope() {
        use lumit_core::anim::{Animation, Keyframe, Property, SideInterp};
        use lumit_core::Rational;
        let job = |volume: Property, offset_s: f64| AudioJob {
            item: uuid::Uuid::nil(),
            path: PathBuf::new(),
            in_s: 0.0,
            out_s: 10.0,
            offset_s,
            volume,
            carriers: Vec::new(),
        };
        let (g, env) = volume_bake(&job(Property::fixed(-6.0), 0.0), 0, 48_000, 48_000);
        assert!(env.is_none(), "static volume needs no envelope");
        assert!((g - 0.501_19).abs() < 1e-3);

        // A 1 s fade 0 dB → −inf, on a layer whose time 0 sits at comp 1 s.
        let key = |t: i64, v: f64| Keyframe {
            time: Rational::new(t, 1).unwrap(),
            value: v,
            interp_in: SideInterp::Linear,
            interp_out: SideInterp::Linear,
        };
        let fade = Property {
            animation: Animation::Keyframed(vec![key(0, 0.0), key(1, -100.0)]),
            extra: serde_json::Map::new(),
        };
        // Placed at comp 1 s (start_frame 48000), offset 1 s: layer time 0..1.
        let (g, env) = volume_bake(&job(fade.clone(), 1.0), 48_000, 48_000, 48_000);
        assert_eq!(g, 1.0);
        let env = env.unwrap();
        assert!((env.gain_at(0) - 1.0).abs() < 1e-6, "fade starts at unity");
        assert!(
            env.gain_at(0) > env.gain_at(24_000) && env.gain_at(24_000) > env.gain_at(47_500),
            "the fade descends"
        );
        assert_eq!(env.gain_at(48_000), 0.0, "the −inf knee lands at silence");

        // Carrier chain (precomp audio): the precomp layer's −6 dB multiplies
        // the inner layer's −6 dB — two static links stay a constant product.
        let mut carried = job(Property::fixed(-6.0), 0.0);
        carried.carriers = vec![(Property::fixed(-6.0), 0.0)];
        let (g, env) = volume_bake(&carried, 0, 48_000, 48_000);
        assert!(env.is_none());
        assert!(
            (g - 0.251_19).abs() < 1e-3,
            "gains multiply through the chain"
        );
        // An animated carrier envelopes the whole chain.
        let mut fading_carrier = job(Property::fixed(0.0), 0.0);
        fading_carrier.carriers = vec![(fade, 0.0)];
        let (_, env) = volume_bake(&fading_carrier, 0, 48_000, 48_000);
        assert!(env.is_some(), "an animated carrier forces the envelope");
    }

    /// The delivery-preset table is spec (docs/06 §7.5): frame, codec, and
    /// bitrates are pinned here so a stray edit can't silently change what
    /// "YouTube 1080p60" means.
    #[test]
    fn preset_table_matches_the_spec() {
        let p = ExportPreset::Youtube1080p60.params().unwrap();
        assert_eq!(p.size, (1920, 1080));
        assert_eq!(p.codec, VideoCodec::H264);
        assert_eq!(p.target_bps, 16_000_000);
        assert_eq!(p.peak_bps, 24_000_000);

        let p = ExportPreset::Youtube4k60.params().unwrap();
        assert_eq!(p.size, (3840, 2160));
        assert_eq!(p.codec, VideoCodec::Hevc);
        assert_eq!(p.target_bps, 45_000_000);
        assert_eq!(p.peak_bps, 60_000_000);

        let p = ExportPreset::Vertical1080p60.params().unwrap();
        assert_eq!(p.size, (1080, 1920));
        assert_eq!(p.codec, VideoCodec::H264);
        assert_eq!(p.target_bps, 16_000_000);
        assert_eq!(p.peak_bps, 24_000_000);

        assert!(ExportPreset::Custom.params().is_none());
        assert_eq!(PRESET_AUDIO_BPS, 320_000);
        assert_eq!(EXPORT_AUDIO_RATE, 48_000);
    }

    #[test]
    fn every_preset_has_a_label_and_file_name() {
        for preset in ExportPreset::ALL {
            assert!(!preset.label().is_empty());
            assert!(preset.default_file_name().ends_with(".mp4"));
        }
    }

    /// K-119: `ExportPreset::default()` must be Custom, so a fresh Settings →
    /// Export default-preset field reproduces today's implicit behaviour
    /// (every generic "Export…" action stamping Custom) until the user
    /// changes it. Also proves the type round-trips through JSON, which
    /// `ExportSettings` (settings.rs) relies on to persist the pick.
    #[test]
    fn export_preset_defaults_to_custom_and_round_trips_through_json() {
        assert_eq!(ExportPreset::default(), ExportPreset::Custom);
        for preset in ExportPreset::ALL {
            let json = serde_json::to_string(&preset).unwrap();
            let back: ExportPreset = serde_json::from_str(&json).unwrap();
            assert_eq!(back, preset);
        }
    }

    /// The A/V interleave rule: cumulative rounding never drifts, and the
    /// total after all frames equals the whole soundtrack.
    #[test]
    fn audio_samples_through_never_drifts() {
        let (fps, rate) = (60.0, 48_000u32);
        // 60 fps at 48 kHz is exactly 800 samples per frame.
        assert_eq!(audio_samples_through(1, fps, rate), 800);
        assert_eq!(audio_samples_through(300, fps, rate), 240_000);
        // An awkward rate: 29.97 fps. Per-frame chunks vary by ±1 sample but
        // the cumulative total stays glued to the exact value.
        let fps = 30_000.0 / 1001.0;
        let mut prev = 0;
        for n in 1..=1000 {
            let now = audio_samples_through(n, fps, rate);
            let chunk = now - prev;
            assert!((1601..=1602).contains(&chunk), "frame {n} chunk {chunk}");
            let exact = n as f64 / fps * 48_000.0;
            assert!((now as f64 - exact).abs() <= 0.5, "frame {n} drifted");
            prev = now;
        }
        // Degenerate input answers zero, never panics.
        assert_eq!(audio_samples_through(100, 0.0, rate), 0);
    }

    /// A silent comp exports video-only; the padding rule keeps sound and
    /// picture the same length when there is audio.
    #[test]
    fn mixdown_of_no_jobs_is_silence_of_the_right_length() {
        let mix = mixdown(&[], 48_000, 2.0);
        assert_eq!(mix.len(), 96_000 * 2);
        assert!(mix.iter().all(|s| *s == 0.0));
    }
}
