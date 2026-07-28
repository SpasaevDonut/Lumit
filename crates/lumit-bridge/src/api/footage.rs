use std::{path::PathBuf, sync::Arc};

use lumit_core::model::FootageItem;
use uuid::Uuid;

use flutter_rust_bridge::frb;

use crate::api::{
    state::{LumitBridgeState, PROJECTS},
    BridgeError,
};

// Not feature-gated: `thumbnail` is declared whatever the build, so its return
// type has to exist whatever the build.
use crate::api::state::BridgeRenderedFrame;

#[derive(Debug, PartialEq, Eq)]
#[frb]
pub struct FootageReference {
    #[frb(name = "internalproject")]
    pub project: Uuid,
    #[frb(name = "internalid")]
    pub id: Uuid,
}

pub enum LumitMediaStatus {
    Missing,
    Ready,
}

/// A footage file's own vital statistics, as the container declares them.
///
/// What "a comp matching the footage" means when a clip is dragged onto the New
/// composition button (docs/07 §3.1): the size, the rate and the length come from
/// here. The rate is the exact pair the container carries and the duration is
/// rational seconds — both because a rate that went through a float would not come
/// back as 30000/1001 (docs/14 §2).
///
/// Audio-only media has no picture, so `width`/`height` are zero and the rate is
/// 0/1; the caller keeps its own size rather than making a comp no pixels wide.
#[frb(non_opaque)]
pub struct BridgeMediaInfo {
    pub width: u32,
    pub height: u32,
    pub fps_num: u32,
    pub fps_den: u32,
    pub duration: crate::api::effect::BridgeRational,
}

impl FootageReference {
    #[frb(ignore)]
    pub fn new(project: Uuid, id: Uuid) -> FootageReference {
        FootageReference { project, id }
    }

    #[frb(ignore)]
    pub fn project_id(&self) -> Uuid {
        self.project
    }

    #[frb(ignore)]
    pub fn id(&self) -> Uuid {
        self.id
    }

    #[frb(ignore)]
    fn project(&self) -> Result<Arc<std::sync::RwLock<LumitBridgeState>>, BridgeError> {
        let projects = PROJECTS.read().map_err(|_| BridgeError::ReadFailed)?;
        let project = projects.get(&self.project);

        let p = project.ok_or(BridgeError::InvalidProject)?;
        Ok(p.clone())
    }

    // copy pasted from lumit-ui/src/headless.rs
    // would be good if these could be shared
    //
    /// Where this footage's file actually is. `None` when the path cannot be
    /// resolved at all — a relative path in a project that has never been saved
    /// (so there is no directory to resolve against), or one that no longer
    /// exists on disk. The caller reports that as missing media, which is what
    /// it is; it is not an error worth surfacing separately.
    pub(crate) fn resolve_path(p: &LumitBridgeState, f: &FootageItem) -> Option<PathBuf> {
        if f.media.absolute_path.is_empty() {
            let path = p.path.clone()?;
            let path = path.parent()?;
            let path = path.join(PathBuf::from(&f.media.relative_path));
            path.canonicalize().ok()
        } else {
            Some(PathBuf::from(&f.media.absolute_path))
        }
    }

    /// Point this footage item at `path`, and fix every *other* missing item
    /// whose file name turns up in the same folder — one undo step for the lot.
    ///
    /// The sibling sweep is the behaviour that makes relinking a moved project
    /// bearable: footage almost always moves as a folder, so relinking one clip
    /// by hand should not mean relinking forty. A sibling is only touched when it
    /// currently fails to resolve *and* a file of its name exists beside the
    /// picked one, so a healthy item is never repointed.
    #[frb(sync)]
    pub fn relink(&self, path: String) -> Result<(), BridgeError> {
        if path.trim().is_empty() {
            return Err(BridgeError::MediaPathUnresolved);
        }
        let picked = PathBuf::from(&path);
        let proj = self.project()?;

        let ops = {
            let p = proj.read().map_err(|_| BridgeError::ReadFailed)?;
            let doc = p.store.snapshot();

            // Refuse early if this reference does not name footage at all.
            match doc.item(self.id).ok_or(BridgeError::InvalidItem)? {
                lumit_core::model::ProjectItem::Footage(_) => {}
                _ => return Err(BridgeError::InvalidItem),
            }

            let folder = picked.parent().map(std::path::Path::to_path_buf);
            let project_dir = p.path.as_deref().and_then(|p| p.parent());

            let mut ops = Vec::new();
            for item in &doc.items {
                let lumit_core::model::ProjectItem::Footage(other) = item else {
                    continue;
                };
                let is_target = other.id == self.id;

                let candidate = if is_target {
                    picked.clone()
                } else {
                    // Only sweep items that are actually broken, and only to a
                    // file that really exists beside the picked one.
                    if Self::resolve_path(&p, other).is_some_and(|p| p.is_file()) {
                        continue;
                    }
                    let Some(folder) = &folder else { continue };
                    let name = std::path::Path::new(&other.media.relative_path)
                        .file_name()
                        .map(std::ffi::OsString::from)
                        .unwrap_or_else(|| std::ffi::OsString::from(&other.name));
                    let candidate = folder.join(name);
                    if !candidate.is_file() {
                        continue;
                    }
                    candidate
                };

                let mut media = other.media.clone();
                media.absolute_path = candidate.to_string_lossy().into_owned();
                if let Some(dir) = project_dir {
                    if let Some(rel) = lumit_project::relative_between(dir, &candidate) {
                        media.relative_path = rel;
                    }
                }
                media.fingerprint = lumit_project::fingerprint_path(&candidate).ok();
                ops.push(lumit_core::Op::SetMediaRef {
                    id: other.id,
                    media: Box::new(media),
                });
            }
            ops
        };

        if ops.is_empty() {
            return Err(BridgeError::MediaPathUnresolved);
        }

        let proj = proj.write().map_err(|_| BridgeError::WriteFailed)?;
        let op = if ops.len() == 1 {
            ops.into_iter().next().ok_or(BridgeError::InvalidItem)?
        } else {
            lumit_core::Op::Batch { ops }
        };
        proj.store.commit(op).map_err(BridgeError::OpError)?;
        Ok(())
    }

    /// A small decoded picture of this footage's first frame, for the Project
    /// panel row. `None` when the file cannot be resolved or decoded — a missing
    /// or unsupported item shows its type glyph instead.
    ///
    /// Deliberately **not** `#[frb(sync)]`: a cold video decode is FFmpeg work
    /// measured in tens of milliseconds, so it must not run on Dart's UI isolate.
    /// frb puts an async call on its own worker pool and Dart simply awaits it —
    /// which is the whole of what v0 needed a hand-rolled isolate, a wire
    /// protocol, a `TransferableTypedData` hand-off and a generation map to
    /// achieve. Memoised per (item, size) in the project's media cache, so a
    /// rebuild costs nothing.
    ///
    /// The pixels are small enough that frb's per-byte `Vec<u8>` encoding does not
    /// matter here: at the panel's 56 px longer edge this is a few kilobytes, not
    /// the megabytes a Viewer frame carries.
    ///
    /// Declared whatever the features are, so the generated Dart is one shape:
    /// a build with no decoder answers `None` rather than the method being
    /// absent and the Dart side failing to compile against it.
    #[cfg(not(feature = "media"))]
    pub fn thumbnail(&self, max_edge: u32) -> Result<Option<BridgeRenderedFrame>, BridgeError> {
        let _ = max_edge;
        Ok(None)
    }

    #[cfg(feature = "media")]
    pub fn thumbnail(&self, max_edge: u32) -> Result<Option<BridgeRenderedFrame>, BridgeError> {
        let proj = self.project()?;
        let mut proj = proj.write().map_err(|_| BridgeError::WriteFailed)?;

        let Some(path) = ({
            let snapshot = proj.store.snapshot();
            match snapshot.item(self.id) {
                Some(lumit_core::model::ProjectItem::Footage(footage)) => {
                    Self::resolve_path(&proj, footage)
                }
                _ => None,
            }
        }) else {
            return Ok(None);
        };

        let id = self.id;
        Ok(
            crate::media::thumbnail_from_path(&mut proj.media, id, max_edge, &path).map(
                |(width, height, rgba)| BridgeRenderedFrame {
                    // A thumbnail is of the media's own first frame, not of a
                    // composition — there is no playhead behind it to report.
                    frame: 0,
                    width,
                    height,
                    rgba,
                },
            ),
        )
    }

    /// This footage's declared size, rate and length, or `None` when the file
    /// cannot be resolved or does not probe.
    ///
    /// Async for the same reason `thumbnail` is: probing opens the container with
    /// FFmpeg, which is not work for Dart's UI isolate. Declared whatever the
    /// features are, so a build with no decoder answers `None` rather than the
    /// method being absent and the Dart side failing to compile against it.
    #[cfg(not(feature = "media"))]
    pub fn media_info(&self) -> Result<Option<BridgeMediaInfo>, BridgeError> {
        Ok(None)
    }

    #[cfg(feature = "media")]
    pub fn media_info(&self) -> Result<Option<BridgeMediaInfo>, BridgeError> {
        let proj = self.project()?;
        let proj = proj.read().map_err(|_| BridgeError::ReadFailed)?;

        let snapshot = proj.store.snapshot();
        let Some(lumit_core::model::ProjectItem::Footage(footage)) = snapshot.item(self.id) else {
            return Err(BridgeError::InvalidItem);
        };
        let Some(path) = Self::resolve_path(&proj, footage) else {
            return Ok(None);
        };
        let Ok(info) = lumit_media::probe::probe(&path) else {
            return Ok(None);
        };

        // The only sanctioned route back from the container's floating-point
        // duration is an explicit grid (docs/impl/rational-time.md §4); the
        // millisecond grid is the resolution the Duration field edits in anyway.
        let duration = lumit_core::time::Rational::from_f64_on_grid(info.duration_seconds, 1000)
            .unwrap_or(lumit_core::time::Rational::ZERO);
        let video = info.video.as_ref();
        Ok(Some(BridgeMediaInfo {
            width: video.map_or(0, |v| v.width),
            height: video.map_or(0, |v| v.height),
            fps_num: video
                .and_then(|v| u32::try_from(v.fps_num).ok())
                .unwrap_or(0),
            fps_den: video
                .and_then(|v| u32::try_from(v.fps_den).ok())
                .unwrap_or(1),
            duration: crate::api::effect::BridgeRational {
                num: duration.num(),
                den: duration.den(),
            },
        }))
    }

    pub fn get_status(&self) -> Result<LumitMediaStatus, BridgeError> {
        let proj = self.project()?;
        let proj = proj.read().map_err(|_| BridgeError::ReadFailed)?;

        let snapshot = proj.store.snapshot();
        let item = snapshot.item(self.id).ok_or(BridgeError::InvalidItem)?;

        match item {
            lumit_core::model::ProjectItem::Footage(footage_item) => {
                // An unresolvable path is missing media, same as one that
                // resolves but no longer decodes.
                let Some(_path) = Self::resolve_path(&proj, footage_item) else {
                    return Ok(LumitMediaStatus::Missing);
                };

                // The file is there; whether it *decodes* takes a prober. A
                // build without one answers that it resolved, because reporting
                // "missing" for a file plainly on disk would send the user to
                // relink something that is not lost.
                #[cfg(not(feature = "media"))]
                let probe: Result<(), ()> = Ok(());
                #[cfg(feature = "media")]
                let probe = lumit_media::probe::probe(&_path);

                match probe {
                    Ok(_) => Ok(LumitMediaStatus::Ready),
                    Err(_) => Ok(LumitMediaStatus::Missing),
                }
            }
            _ => Err(BridgeError::InvalidItem),
        }
    }
}
