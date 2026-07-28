//! Finding the beat in a composition's audio, and marking it.
//!
//! # In plain terms
//!
//! Cutting to music means knowing where the beats are. This listens to
//! everything audible in a composition, finds the moments that sound like hits,
//! works out the tempo, nudges the near-misses onto that grid, and drops a
//! marker on each — so the Timeline's snapping has something true to snap to
//! (docs/09 §5).
//!
//! **Detection replaces only the beat markers.** Chapter marks and anything
//! typed by hand survive, because re-running detection at a different
//! sensitivity is an ordinary thing to do and losing your own notes to it would
//! not be.
//!
//! It can take a few seconds on a long comp — it mixes the audio and analyses
//! the lot — so detection is deliberately NOT `#[frb(sync)]`: it runs on the
//! bridge's worker pool and the interface never waits on it. The markers land
//! as one committed op when it finishes, and the change stream repaints the
//! panels exactly as any other edit does.

use flutter_rust_bridge::frb;

use crate::api::{composition::CompositionReference, BridgeError};

impl CompositionReference {
    /// Detect beats and replace this comp's beat markers.
    ///
    /// `sensitivity_percent` runs 0..100, where 50 is the standard setting and
    /// higher finds more. Returns how many markers were placed — zero is a
    /// legitimate answer for quiet or arrhythmic audio, and worth showing as
    /// such rather than as a failure. Seconds-long on a long comp, so it is
    /// async on purpose (docs/TODO: "move beat detection off-thread").
    pub fn detect_beats(&self, sensitivity_percent: u32) -> Result<u32, BridgeError> {
        let composition = self.composition()?;
        let document = {
            let state = self.project()?;
            let state = state.read().map_err(|_| BridgeError::ReadFailed)?;
            state.store.snapshot()
        };

        // The audio, built through the same headless input path the exporter
        // uses — so what is analysed is what will be exported.
        let inputs = crate::render::with_export_inputs(&document, self.id)
            .ok_or(BridgeError::NoAudioPipeline)?;
        if inputs.audio.is_empty() {
            return Err(BridgeError::NoAudio);
        }

        const RATE: u32 = 48_000;
        let samples =
            lumit_render::export::mixdown(&inputs.audio, RATE, composition.duration.0.to_f64());
        let delta =
            lumit_audio::beat::delta_from_sensitivity(sensitivity_percent.clamp(0, 100) as u8);
        let analysis = lumit_audio::beat::analyse_stereo(&samples, RATE, delta);

        // Snapping pulls onsets that are nearly on the tempo grid onto it, so a
        // performance that drifts by a few milliseconds still cuts cleanly. The
        // 45 ms window is the egui frontend's, kept identical on purpose.
        let times: Vec<f64> = analysis.onsets.iter().map(|o| o.time).collect();
        let snapped = lumit_audio::beat::snap_to_grid(&times, analysis.bpm, 0.045);

        let beats: Vec<lumit_core::markers::Marker> = snapped
            .iter()
            .zip(&analysis.onsets)
            .filter_map(|(t, onset)| {
                let time = lumit_core::Rational::from_f64_on_grid(t.max(0.0), 1000).ok()?;
                Some(lumit_core::markers::Marker::beat(
                    uuid::Uuid::now_v7(),
                    time,
                    onset.confidence,
                ))
            })
            .collect();
        let placed = beats.len() as u32;

        let markers = lumit_core::markers::with_regenerated_beats(&composition.markers, beats);
        self.commit_markers(markers)?;
        Ok(placed)
    }

    /// Remove every detected beat marker, keeping the ones a person made.
    ///
    /// A comp with none is a calm no-op rather than an error — clearing twice is
    /// something a user does without thinking about it.
    #[frb(sync)]
    pub fn clear_beat_markers(&self) -> Result<(), BridgeError> {
        let composition = self.composition()?;
        let kept: Vec<_> = composition
            .markers
            .iter()
            .filter(|m| !matches!(m.kind, lumit_core::markers::MarkerKind::Beat { .. }))
            .cloned()
            .collect();
        if kept.len() == composition.markers.len() {
            return Ok(());
        }
        self.commit_markers(kept)
    }

    #[frb(ignore)]
    fn commit_markers(&self, markers: Vec<lumit_core::markers::Marker>) -> Result<(), BridgeError> {
        let state = self.project()?;
        let state = state.write().map_err(|_| BridgeError::WriteFailed)?;
        state
            .store
            .commit(lumit_core::Op::SetCompMarkers {
                comp: self.id,
                markers,
            })
            .map_err(BridgeError::OpError)?;
        Ok(())
    }
}
