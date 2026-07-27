//! The decode-ahead thread (docs/impl/playback-scheduler.md §5: decode(N+k)
//! runs alongside evaluate/present, not before them).
//!
//! # In plain terms
//!
//! During playback the worker knows exactly which source frames the next few
//! renders will need — the plan tells it. This thread decodes them EARLY, on
//! its own decoders, and hands the pixels back; the worker files them into
//! the renderer's decoded-frame cache, so when the render arrives its decode
//! is a lookup. The render thread and the decode thread then work at the same
//! time instead of taking turns, and a frame costs the LARGER of decode and
//! composite rather than their sum.
//!
//! Correctness is carried by the cache key, not by trust: a result is filed
//! under (item, source frame, decode width) — the same key the render's own
//! decode would use — so the worst a late or wasted prefetch can do is warm
//! the cache with pixels nobody asks for. An `epoch` guards even that: bump
//! it on stop or seek and in-flight results are dropped on arrival.

use lumit_render::PrefetchWant;
use std::collections::HashMap;
use std::sync::mpsc::{channel, Receiver, Sender, TryRecvError};
use uuid::Uuid;

pub(crate) struct Job {
    pub epoch: u64,
    pub want: PrefetchWant,
}

pub(crate) struct Done {
    pub epoch: u64,
    pub item: Uuid,
    pub frame: usize,
    pub target_width: Option<u32>,
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
}

/// The worker's handle: send wants, drain finished decodes. Dropping it ends
/// the thread (its receiver disconnects).
pub(crate) struct Prefetcher {
    tx: Sender<Job>,
    rx: Receiver<Done>,
    epoch: u64,
}

impl Default for Prefetcher {
    fn default() -> Self {
        let (tx, jobs) = channel::<Job>();
        let (done_tx, rx) = channel::<Done>();
        std::thread::spawn(move || run(jobs, done_tx));
        Self { tx, rx, epoch: 0 }
    }
}

impl Prefetcher {
    /// Invalidate everything queued or in flight (stop, seek, a new play).
    /// Results already decoded still arrive but are dropped by epoch.
    pub(crate) fn invalidate(&mut self) {
        self.epoch += 1;
    }

    /// Queue one decode-ahead. Never blocks; a dead thread makes this a no-op
    /// (playback then simply decodes inline, exactly as before prefetch).
    pub(crate) fn request(&self, want: PrefetchWant) {
        let _ = self.tx.send(Job {
            epoch: self.epoch,
            want,
        });
    }

    /// Everything decoded since the last drain, current-epoch only.
    pub(crate) fn drain(&self) -> Vec<Done> {
        let mut out = Vec::new();
        loop {
            match self.rx.try_recv() {
                Ok(done) if done.epoch == self.epoch => out.push(done),
                Ok(_) => {}
                Err(TryRecvError::Empty) | Err(TryRecvError::Disconnected) => break,
            }
        }
        out
    }
}

/// The thread: its own decoders (the renderer's are untouched — no lock ever
/// crosses the seam), decoding jobs in the order they arrive. Playback asks
/// for frames in playing order, so the decoders run sequentially — the cheap
/// direction. A job that fails to decode is skipped: the render will try it
/// inline and surface the error through the path that already knows how.
fn run(jobs: Receiver<Job>, done: Sender<Done>) {
    let mut decoders: HashMap<Uuid, lumit_media::VideoDecoder> = HashMap::new();
    while let Ok(job) = jobs.recv() {
        let want = job.want;
        let dec = match decoders.entry(want.item) {
            std::collections::hash_map::Entry::Occupied(e) => e.into_mut(),
            std::collections::hash_map::Entry::Vacant(e) => {
                let Ok(index) = lumit_media::index::build_frame_index(&want.path) else {
                    continue;
                };
                let Ok(dec) = lumit_media::VideoDecoder::open(&want.path, index) else {
                    continue;
                };
                e.insert(dec)
            }
        };
        let frame = want.frame.min(dec.frame_count().saturating_sub(1));
        let Ok(out) = dec.frame_rgba(frame, want.target_width) else {
            continue;
        };
        if done
            .send(Done {
                epoch: job.epoch,
                item: want.item,
                frame: want.frame,
                target_width: want.target_width,
                width: out.width,
                height: out.height,
                rgba: out.rgba,
            })
            .is_err()
        {
            return;
        }
    }
}
