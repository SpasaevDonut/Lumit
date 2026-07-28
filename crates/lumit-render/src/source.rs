//! What the render pipeline needs to know about a footage item's media file.
//!
//! # In plain terms
//!
//! Before anything can be drawn, the pipeline has to answer three questions
//! about each piece of footage: is the file actually there, how fast does it
//! run, and how many frames does it have? Reading that off disk is called
//! *probing*, and each frontend already does it its own way — the egui shell
//! probes on a background thread and keeps a `MediaRegistry`; the bridge probes
//! on the calling thread and keeps a `MediaCache`.
//!
//! Rather than pick one and force the other to convert, this module states the
//! *question* as a trait ([`SourceProbes`]) and the *answer* as a small plain
//! enum ([`SourceProbe`]). Each frontend implements the trait over whatever it
//! already holds, and the pipeline never learns which frontend it is serving.
//! That is what keeps this crate an engine crate: it depends on no frontend, and
//! the arrow in docs/05-ARCHITECTURE.md still points one way.

use uuid::Uuid;

/// One footage item's probe result, as the render pipeline needs it.
///
/// The four failure-ish states are deliberately distinct, because they render
/// differently: unprobed contributes nothing *and* makes the frame unkeyable
/// (so it is never cached under a promise it did not keep); audio-only
/// contributes no picture but is perfectly healthy, so it must never draw the
/// slate; missing and unreadable both draw the colour-bars slate (docs/07 §3.3).
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum SourceProbe {
    /// Not probed yet. The layer draws nothing this frame and the whole comp
    /// frame is not cacheable — it will be re-rendered once the probe lands.
    Unprobed,
    /// A readable file carrying a video stream.
    Video {
        /// The container's exact rate.
        fps: f64,
        /// Native pixel size — what transforms act in, regardless of the
        /// resolution the frame is actually decoded at.
        width: u32,
        height: u32,
        /// Decodable frame count, from the frame index.
        frames: usize,
        /// Whether the same file also carries an audio stream.
        audio: bool,
    },
    /// A readable file with no video stream (a music track, say). Not an
    /// error: it contributes no picture and **no slate**.
    AudioOnly,
    /// Not on disk — moved, renamed, or on an unmounted drive. Draws the slate
    /// and leads to the relink flow.
    Missing,
    /// Present but unreadable (corrupt or unsupported). Draws the slate.
    Failed,
}

impl SourceProbe {
    /// The video details, or `None` for every state that has no picture.
    #[must_use]
    pub fn video(self) -> Option<(f64, u32, u32, usize)> {
        match self {
            SourceProbe::Video {
                fps,
                width,
                height,
                frames,
                ..
            } => Some((fps, width, height, frames)),
            _ => None,
        }
    }

    /// Whether this source draws the missing-footage slate (docs/07 §3.3).
    /// `AudioOnly` deliberately does not: flagging a healthy audio file as
    /// missing would be actively wrong.
    #[must_use]
    pub fn slates(self) -> bool {
        matches!(self, SourceProbe::Missing | SourceProbe::Failed)
    }

    /// Whether this source carries sound.
    #[must_use]
    pub fn has_audio(self) -> bool {
        matches!(
            self,
            SourceProbe::AudioOnly | SourceProbe::Video { audio: true, .. }
        )
    }
}

/// A frontend's probe cache, seen through the one question the pipeline asks.
/// An item nobody has probed answers [`SourceProbe::Unprobed`].
pub trait SourceProbes {
    fn probe(&self, item: Uuid) -> SourceProbe;
}

/// Nothing is probed — the do-nothing implementation a build with no media
/// support (or a test with no files) hands in.
pub struct NoProbes;

impl SourceProbes for NoProbes {
    fn probe(&self, _item: Uuid) -> SourceProbe {
        SourceProbe::Unprobed
    }
}

impl SourceProbes for std::collections::HashMap<Uuid, SourceProbe> {
    fn probe(&self, item: Uuid) -> SourceProbe {
        self.get(&item).copied().unwrap_or(SourceProbe::Unprobed)
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    /// Audio-only media must never slate — the bug that painted colour bars
    /// over a perfectly good music layer. Missing and unreadable both do.
    #[test]
    fn only_missing_and_failed_draw_the_slate() {
        assert!(!SourceProbe::AudioOnly.slates());
        assert!(!SourceProbe::Unprobed.slates());
        assert!(SourceProbe::Missing.slates());
        assert!(SourceProbe::Failed.slates());
        assert!(!SourceProbe::Video {
            fps: 30.0,
            width: 8,
            height: 8,
            frames: 10,
            audio: false,
        }
        .slates());
    }

    /// Only a probed video stream reports a picture; the has-audio question is
    /// answered by both audio-only files and video files with a sound track.
    #[test]
    fn video_and_audio_are_reported_independently() {
        let v = SourceProbe::Video {
            fps: 24.0,
            width: 1920,
            height: 1080,
            frames: 240,
            audio: true,
        };
        assert_eq!(v.video(), Some((24.0, 1920, 1080, 240)));
        assert!(v.has_audio());
        assert!(SourceProbe::AudioOnly.video().is_none());
        assert!(SourceProbe::AudioOnly.has_audio());
        assert!(!SourceProbe::Missing.has_audio());
    }

    /// A plain map is a probe source, and an id it does not hold is unprobed —
    /// the shape tests and simple callers lean on.
    #[test]
    fn a_map_answers_unprobed_for_unknown_items() {
        let mut map = std::collections::HashMap::new();
        let known = Uuid::now_v7();
        map.insert(known, SourceProbe::Missing);
        assert_eq!(map.probe(known), SourceProbe::Missing);
        assert_eq!(map.probe(Uuid::now_v7()), SourceProbe::Unprobed);
        assert_eq!(NoProbes.probe(known), SourceProbe::Unprobed);
    }
}
