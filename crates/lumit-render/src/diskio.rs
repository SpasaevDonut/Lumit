//! The write-behind disk cache tier for comp frames: one IO thread owning a
//! [`lumit_cache::disk::DiskCache`], so no render ever waits on a file.
//!
//! # In plain terms
//!
//! The disk tier is the bottom of the three-tier cache (docs/06 §5.1): frames
//! that no longer fit on the graphics card or in memory are parked in a folder
//! and read back later, so they survive a heavy edit, a comp switch and — unlike
//! the other two tiers — closing the application. All of that happens on this
//! thread. Nothing here can make a render slower: a store is posted and
//! forgotten, and a load arrives whenever it arrives (docs §5.1: "writes are
//! write-behind on background IO threads; a disk write never blocks a render").
//!
//! Two small pieces of bookkeeping cross back to the owner without a message:
//! [`DiskIo::known`], the set of hashes present (what the cache bar's blue tier
//! draws from, and what the fill checks before deciding to render), and
//! [`DiskIo::used_bytes`], for the meter.
//!
//! **Channel order.** Frames are composited in BGRA on the Windows and macOS
//! zero-copy paths and RGBA everywhere else, but a `.kfr` file is always RGBA —
//! one canonical order on disk, so a cache is not silently unreadable on the
//! next platform. The swizzle that costs is therefore paid *here*, on this
//! thread, in both directions: a store converts before compressing, and a load
//! converts back to whatever order the caller asked for.

use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, Sender};
use std::sync::{Arc, Mutex};

/// Where a project's parked frames may sit, re-exported so a consumer choosing
/// between the two does not need a direct dependency on the cache crate (the
/// application-data option is [`lumit_project::frame_cache_dir`], which lives
/// with the other app-data paths).
pub use lumit_cache::disk::{cache_root_for, sidecar_root};

/// Default disk budget (docs/06 §5.4: "default size cap 50 GB, user-set").
pub const DEFAULT_CAP_BYTES: u64 = 50 * 1024 * 1024 * 1024;

pub enum Cmd {
    /// Point the cache at a folder (None disables the tier — no folder, no
    /// parking). Any previously open cache is closed; the cap survives.
    SetRoot(Option<PathBuf>),
    /// Park a rendered frame (write-behind). `bgra` describes the bytes given,
    /// not the file: the file is always RGBA. `cost_ms` and `scale_q` are what
    /// the index ranks the frame by when the cap has to take something
    /// (docs/06 §5.3) — a frame that was dear to render is worth keeping over a
    /// cheap one of the same size.
    ///
    /// The bytes come in a shared handle, because the memory tier keeps the same
    /// frame. A frame is 8 MB at 1080p. Thus the two tiers point at one
    /// allocation, and the demotion does not copy it.
    Store {
        hash: u128,
        width: u32,
        height: u32,
        bgra: bool,
        bytes: Arc<Vec<u8>>,
        cost_ms: u32,
        scale_q: u16,
    },
    /// Bring a frame back for the tiers above, in the channel order the caller
    /// will upload it in.
    Load { hash: u128, bgra: bool },
    /// Set the byte cap (Settings → Performance). Remembered so it also
    /// applies to the cache opened on the next `SetRoot`.
    SetCap(u64),
    /// Delete every parked frame (Settings → Clear cache).
    Clear,
}

/// One frame read back off disk, in the channel order that was asked for.
pub struct LoadedFrame {
    pub hash: u128,
    pub width: u32,
    pub height: u32,
    pub bytes: Vec<u8>,
    pub bgra: bool,
}

pub struct DiskIo {
    pub tx: Sender<Cmd>,
    pub loaded: Receiver<LoadedFrame>,
    /// Hashes present on disk, mirrored by the worker so the owner can ask
    /// "is this frame parked?" without touching the filesystem.
    pub known: Arc<Mutex<HashSet<u128>>>,
    /// Bytes stored, as the IO thread last accounted them — the meter's number.
    pub used_bytes: Arc<AtomicU64>,
}

impl DiskIo {
    /// Whether `hash` is parked on disk. Answers false rather than blocking if
    /// the mirror is momentarily contended: a missed disk hit costs a render,
    /// and the render path must never wait on the IO thread's bookkeeping.
    #[must_use]
    pub fn contains(&self, hash: u128) -> bool {
        self.known
            .try_lock()
            .map(|k| k.contains(&hash))
            .unwrap_or(false)
    }

    /// How many frames are parked, and how many bytes they take.
    #[must_use]
    pub fn stats(&self) -> (u64, u64) {
        let entries = self.known.try_lock().map(|k| k.len() as u64).unwrap_or(0);
        (self.used_bytes.load(Ordering::Relaxed), entries)
    }
}

/// Swap the red and blue bytes of a display frame in place — the one difference
/// between the two orders the compositor emits. Alpha and green sit still.
fn swizzle_rb(bytes: &mut [u8]) {
    for px in bytes.chunks_exact_mut(4) {
        px.swap(0, 2);
    }
}

/// Spawn the worker. It exits when the sender side drops.
pub fn spawn() -> DiskIo {
    let (tx, rx) = std::sync::mpsc::channel::<Cmd>();
    let (loaded_tx, loaded) = std::sync::mpsc::channel();
    let known: Arc<Mutex<HashSet<u128>>> = Arc::default();
    let used_bytes: Arc<AtomicU64> = Arc::default();
    let known_worker = known.clone();
    let used_worker = used_bytes.clone();
    std::thread::Builder::new()
        .name("nebula-disk".into())
        .spawn(move || {
            let mut cache: Option<lumit_cache::disk::DiskCache> = None;
            // The desired cap, so it survives project switches (a fresh
            // cache is opened per `SetRoot`) rather than resetting.
            let mut cap = DEFAULT_CAP_BYTES;
            while let Ok(cmd) = rx.recv() {
                match cmd {
                    Cmd::SetRoot(root) => {
                        // Snapshot the index of the cache being closed: its log
                        // already carries everything, but folding it in now keeps
                        // the next open cheap.
                        if let Some(c) = &mut cache {
                            c.flush_index();
                        }
                        cache = root.map(|r| lumit_cache::disk::DiskCache::open(r, cap));
                        let hashes = cache.as_ref().map(|c| c.known_hashes()).unwrap_or_default();
                        if let Ok(mut k) = known_worker.lock() {
                            k.clear();
                            k.extend(hashes);
                        }
                    }
                    Cmd::SetCap(bytes) => {
                        cap = bytes;
                        if let Some(c) = &mut cache {
                            c.set_cap(bytes);
                            // Lowering the cap evicts, so the mirror has to
                            // follow or the bar promises what was just deleted.
                            if let Ok(mut k) = known_worker.lock() {
                                k.clear();
                                k.extend(c.known_hashes());
                            }
                        }
                    }
                    Cmd::Clear => {
                        if let Some(c) = &mut cache {
                            c.clear();
                            c.flush_index();
                        }
                        if let Ok(mut k) = known_worker.lock() {
                            k.clear();
                        }
                    }
                    Cmd::Store {
                        hash,
                        width,
                        height,
                        bgra,
                        bytes,
                        cost_ms,
                        scale_q,
                    } => {
                        let Some(c) = &mut cache else { continue };
                        // One order on disk (see the module note); the swizzle is
                        // this thread's to pay, never the renderer's. The bytes
                        // are shared with the memory tier, thus a swizzle needs
                        // its own copy. Only the two zero-copy platforms pay for
                        // that copy, and they pay for it on this thread.
                        let swizzled = bgra.then(|| {
                            let mut owned = bytes.as_ref().clone();
                            swizzle_rb(&mut owned);
                            owned
                        });
                        c.store(lumit_cache::disk::Parked {
                            hash,
                            width,
                            height,
                            rgba: swizzled.as_deref().unwrap_or(bytes.as_ref()),
                            cost_ms,
                            scale_q,
                        });
                        // The store may have evicted to stay under the cap, so
                        // the mirror is refreshed from the index rather than just
                        // gaining this hash — otherwise the cache bar would go on
                        // promising frames the cap has taken.
                        if let Ok(mut k) = known_worker.lock() {
                            k.clear();
                            k.extend(c.known_hashes());
                        }
                    }
                    Cmd::Load { hash, bgra } => {
                        let frame = cache.as_mut().and_then(|c| c.load(hash));
                        match frame {
                            Some(f) => {
                                let mut bytes = f.rgba;
                                if bgra {
                                    swizzle_rb(&mut bytes);
                                }
                                let _ = loaded_tx.send(LoadedFrame {
                                    hash,
                                    width: f.width,
                                    height: f.height,
                                    bytes,
                                    bgra,
                                });
                            }
                            None => {
                                // Missing or corrupt-discarded: unmirror it
                                // so the fill falls back to rendering.
                                if let Ok(mut k) = known_worker.lock() {
                                    k.remove(&hash);
                                }
                            }
                        }
                    }
                }
                used_worker.store(
                    cache.as_ref().map(|c| c.used_bytes()).unwrap_or(0),
                    Ordering::Relaxed,
                );
            }
        })
        .ok();
    DiskIo {
        tx,
        loaded,
        known,
        used_bytes,
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    fn frame(w: u32, h: u32) -> Vec<u8> {
        (0..(w * h * 4)).map(|i| (i % 251) as u8).collect()
    }

    /// The tier end to end on its own thread: park a frame, see it appear in the
    /// mirror the cache bar and the fill read, and get the identical bytes back.
    #[test]
    fn a_parked_frame_comes_back_byte_for_byte() {
        let dir = tempfile::tempdir().unwrap();
        let io = spawn();
        io.tx
            .send(Cmd::SetRoot(Some(dir.path().to_path_buf())))
            .unwrap();
        let bytes = frame(8, 4);
        io.tx
            .send(Cmd::Store {
                hash: 42,
                width: 8,
                height: 4,
                bgra: false,
                bytes: Arc::new(bytes.clone()),
                cost_ms: 8,
                scale_q: 1000,
            })
            .unwrap();
        io.tx
            .send(Cmd::Load {
                hash: 42,
                bgra: false,
            })
            .unwrap();

        let got = io
            .loaded
            .recv_timeout(std::time::Duration::from_secs(5))
            .expect("the parked frame comes back");
        assert_eq!(got.hash, 42);
        assert_eq!((got.width, got.height), (8, 4));
        assert_eq!(got.bytes, bytes);
        assert!(io.contains(42), "and the mirror knows it is parked");
        let (used, entries) = io.stats();
        assert!(used > 0 && entries == 1);

        // A frame nobody parked is reported missing rather than answered.
        io.tx
            .send(Cmd::Load {
                hash: 7,
                bgra: false,
            })
            .unwrap();
        assert!(io
            .loaded
            .recv_timeout(std::time::Duration::from_millis(300))
            .is_err());

        io.tx.send(Cmd::Clear).unwrap();
        // Round-trip a command so the clear has certainly been handled.
        io.tx
            .send(Cmd::Load {
                hash: 42,
                bgra: false,
            })
            .unwrap();
        assert!(io
            .loaded
            .recv_timeout(std::time::Duration::from_millis(500))
            .is_err());
        assert!(!io.contains(42), "Clear cache empties the tier");
    }

    /// A BGRA frame (the Windows and macOS zero-copy order) is stored as RGBA
    /// and handed back in whichever order the caller asks for — so a cache is
    /// never silently unreadable, and the swizzle is always on this thread.
    #[test]
    fn the_channel_order_is_normalised_on_the_io_thread() {
        let dir = tempfile::tempdir().unwrap();
        let io = spawn();
        io.tx
            .send(Cmd::SetRoot(Some(dir.path().to_path_buf())))
            .unwrap();
        // One opaque pixel, obviously ordered: B=1, G=2, R=3, A=4.
        io.tx
            .send(Cmd::Store {
                hash: 9,
                width: 1,
                height: 1,
                bgra: true,
                bytes: Arc::new(vec![1, 2, 3, 4]),
                cost_ms: 8,
                scale_q: 1000,
            })
            .unwrap();

        io.tx
            .send(Cmd::Load {
                hash: 9,
                bgra: false,
            })
            .unwrap();
        let rgba = io
            .loaded
            .recv_timeout(std::time::Duration::from_secs(5))
            .unwrap();
        assert_eq!(rgba.bytes, vec![3, 2, 1, 4], "on disk, and out, as RGBA");

        io.tx
            .send(Cmd::Load {
                hash: 9,
                bgra: true,
            })
            .unwrap();
        let back = io
            .loaded
            .recv_timeout(std::time::Duration::from_secs(5))
            .unwrap();
        assert_eq!(
            back.bytes,
            vec![1, 2, 3, 4],
            "asked for BGRA, given back exactly what was stored"
        );
    }

    /// With no root the tier is simply off: a store is dropped and a load
    /// answers nothing. This is what an unsaved project with the cache set to
    /// live beside its file looks like, and it must not be an error.
    #[test]
    fn with_no_root_the_tier_is_inert() {
        let io = spawn();
        io.tx
            .send(Cmd::Store {
                hash: 1,
                width: 1,
                height: 1,
                bgra: false,
                bytes: Arc::new(vec![0, 0, 0, 255]),
                cost_ms: 8,
                scale_q: 1000,
            })
            .unwrap();
        io.tx
            .send(Cmd::Load {
                hash: 1,
                bgra: false,
            })
            .unwrap();
        assert!(io
            .loaded
            .recv_timeout(std::time::Duration::from_millis(300))
            .is_err());
        assert!(!io.contains(1));
        assert_eq!(io.stats(), (0, 0));
    }
}
