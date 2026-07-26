use std::sync::Arc;

use flutter_rust_bridge::frb;
use lumit_core::Op;
use uuid::Uuid;

use crate::api::{
    composition::CompositionReference,
    footage::FootageReference,
    project_item::{item_reference, ItemReference},
    state::{WorkerResponseStream, PROJECTS},
    worker_thread, BridgeError,
};

/// Whether undo and redo have anything to do, for greying the menu items.
#[frb(non_opaque)]
pub struct BridgeHistory {
    pub can_undo: bool,
    pub can_redo: bool,
}

#[derive(Debug, Clone)]
#[frb]
pub struct ProjectReference {
    #[frb(name = "internalid")]
    pub id: Uuid,
}

impl ProjectReference {
    #[frb(ignore)]
    pub fn new(id: Uuid) -> ProjectReference {
        ProjectReference { id }
    }

    #[frb(ignore)]
    pub fn state(
        &self,
    ) -> Result<Arc<std::sync::RwLock<super::state::LumitBridgeState>>, BridgeError> {
        let projects = PROJECTS.read().map_err(|_| BridgeError::ReadFailed)?;
        let project = projects.get(&self.id).ok_or(BridgeError::InvalidProject)?;

        Ok(project.clone())
    }

    #[frb(sync)]
    pub fn start_worker(&self, on_reponse: WorkerResponseStream) {
        worker_thread::run_worker(self.clone(), on_reponse);
    }

    #[frb(sync)]
    pub fn get_items(&self) -> Result<Vec<ItemReference>, BridgeError> {
        let s = self.state()?;
        let s = s.read().map_err(|_| BridgeError::ReadFailed)?;

        let snapshot = s.store.snapshot();

        // The panel's ROOTS only — items no folder lists. `Document::items` is the
        // flat set of every item in the project, so returning it whole made a
        // filed item appear twice: once at the top level and again under its
        // folder, because the panel recurses through
        // `FolderReference::get_children`. Nesting is that method's job; this one
        // answers "what does the tree start from".
        let filed: std::collections::HashSet<Uuid> = snapshot
            .items
            .iter()
            .filter_map(|i| match i {
                lumit_core::model::ProjectItem::Folder(f) => Some(f.children.iter().copied()),
                _ => None,
            })
            .flatten()
            .collect();

        Ok(snapshot
            .items
            .iter()
            .filter(|i| !filed.contains(&i.id()))
            .map(|i| item_reference(self.id, i))
            .collect())
    }

    /// Add a composition, filed into the Compositions auto-folder, as one undo
    /// step. A blank name gets the next "Comp N".
    ///
    /// The folder is tracked by id, not by name, so renaming or nesting it keeps
    /// it the Compositions folder — the same habit the egui frontend has.
    #[frb(sync)]
    pub fn new_composition(&self, name: String) -> Result<CompositionReference, BridgeError> {
        use lumit_core::model::{Composition, Folder, LinearColour, MotionBlur, ProjectItem};
        use lumit_core::ops::AutoFolderKind;
        use lumit_core::time::{Duration, FrameRate, Rational};

        let state = self.state()?;
        let state = state.write().map_err(|_| BridgeError::WriteFailed)?;
        let doc = state.store.snapshot();

        let name = if name.trim().is_empty() {
            let existing = doc
                .items
                .iter()
                .filter(|i| matches!(i, ProjectItem::Composition(_)))
                .count();
            format!("Comp {}", existing + 1)
        } else {
            name
        };

        let (frame_rate, duration) = match (FrameRate::new(60, 1), Rational::new(30, 1)) {
            (Ok(fr), Ok(dur)) => (fr, Duration(dur)),
            _ => return Err(BridgeError::InvalidComp),
        };

        let mut ops: Vec<Op> = Vec::new();
        let folder_id = match doc
            .auto_folders
            .compositions
            .filter(|id| doc.folder(*id).is_some())
        {
            Some(id) => id,
            None => {
                let id = Uuid::now_v7();
                ops.push(Op::AddItem {
                    index: doc.items.len(),
                    item: Box::new(ProjectItem::Folder(Folder {
                        id,
                        name: "Compositions".into(),
                        children: Vec::new(),
                        extra: serde_json::Map::new(),
                    })),
                });
                ops.push(Op::SetAutoFolder {
                    kind: AutoFolderKind::Compositions,
                    folder: Some(id),
                });
                id
            }
        };

        let comp = Composition {
            id: Uuid::now_v7(),
            name,
            width: 1920,
            height: 1080,
            frame_rate,
            duration,
            background: LinearColour::BLACK,
            work_area: None,
            layers: Vec::new(),
            markers: Vec::new(),
            motion_blur: MotionBlur::default(),
            extra: serde_json::Map::new(),
        };
        let comp_id = comp.id;

        // The comp's index has to account for any AddItem already queued ahead of
        // it in this same batch.
        let queued = ops
            .iter()
            .filter(|o| matches!(o, Op::AddItem { .. }))
            .count();
        ops.push(Op::AddItem {
            index: doc.items.len() + queued,
            item: Box::new(ProjectItem::Composition(comp)),
        });

        // The folder may have been created earlier in this same batch, so it is
        // absent from `doc` and its children start empty.
        let mut children = doc
            .folder(folder_id)
            .map(|f| f.children.clone())
            .unwrap_or_default();
        children.push(comp_id);
        ops.push(Op::SetFolderChildren {
            folder: folder_id,
            children,
        });

        state
            .store
            .commit(Op::Batch { ops })
            .map_err(BridgeError::OpError)?;

        Ok(CompositionReference::new(self.id, comp_id))
    }

    /// Record `path` as a footage item, as one undo step.
    ///
    /// Importing only *records* the file — it does not decode it or read its size.
    /// Footage has no auto-folder (only solids and comps do), so the item lands at
    /// the panel root, matching the egui frontend exactly.
    ///
    /// The bare file name becomes the relative path; saving rebases it against the
    /// project folder (K-173).
    #[frb(sync)]
    pub fn import_footage(&self, path: String) -> Result<FootageReference, BridgeError> {
        use lumit_core::model::{FootageItem, MediaRef, ProjectItem};

        if path.trim().is_empty() {
            return Err(BridgeError::MediaPathUnresolved);
        }
        let file = std::path::PathBuf::from(&path);
        let name = file
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| "footage".into());

        let item = FootageItem {
            id: Uuid::now_v7(),
            name: name.clone(),
            media: MediaRef {
                relative_path: name,
                absolute_path: file.to_string_lossy().into_owned(),
                fingerprint: None,
                extra: serde_json::Map::new(),
            },
            extra: serde_json::Map::new(),
        };
        let item_id = item.id;

        let state = self.state()?;
        let state = state.write().map_err(|_| BridgeError::WriteFailed)?;
        let index = state.store.snapshot().items.len();
        state
            .store
            .commit(Op::AddItem {
                index,
                item: Box::new(ProjectItem::Footage(item)),
            })
            .map_err(BridgeError::OpError)?;

        Ok(FootageReference::new(self.id, item_id))
    }

    /// Save to `path`, or to wherever the project was last saved when `path` is
    /// empty. Answers the path actually written, so Dart can show it and stop
    /// asking where to put the file.
    ///
    /// Deliberately **not** `#[frb(sync)]`: this writes a whole document to disk
    /// and fsyncs it, so it must not run on Dart's UI isolate. Budget S5
    /// (docs/13 §2.1) asks for a stress-document save to be non-blocking, and an
    /// async frb call is that for free.
    ///
    /// Media paths are rebased against the destination directory before writing
    /// (K-173), so a project saved somewhere new keeps relative links that work.
    /// A successful save clears the crash journal: the journal covers work
    /// *between* saves, so once the document is on disk it is redundant.
    pub fn save(&self, path: String) -> Result<String, BridgeError> {
        let state = self.state()?;
        let mut state = state.write().map_err(|_| BridgeError::WriteFailed)?;

        let target = if path.trim().is_empty() {
            // Never saved and no path given: the caller has to pick one.
            state.path.clone().ok_or(BridgeError::NoProjectPath)?
        } else {
            std::path::PathBuf::from(path)
        };

        let dir = target.parent().unwrap_or_else(|| std::path::Path::new(""));
        let doc = lumit_project::rebase_for_save(&state.store.snapshot(), dir);
        lumit_project::save(&doc, &target).map_err(|_| BridgeError::WriteFailed)?;

        if let Some(journal) = &state.journal {
            let _ = journal.clear();
        }
        let written = target.to_string_lossy().into_owned();
        state.path = Some(target);
        Ok(written)
    }

    /// Where this project was last saved, or null when it never has been. The
    /// menu bar needs it to decide between Save and Save as.
    #[frb(sync)]
    pub fn path(&self) -> Result<Option<String>, BridgeError> {
        let state = self.state()?;
        let state = state.read().map_err(|_| BridgeError::ReadFailed)?;
        Ok(state
            .path
            .as_ref()
            .map(|p| p.to_string_lossy().into_owned()))
    }

    /// Whether there is anything to undo or redo, for greying the menu items.
    #[frb(sync)]
    pub fn history(&self) -> Result<BridgeHistory, BridgeError> {
        let state = self.state()?;
        let state = state.read().map_err(|_| BridgeError::ReadFailed)?;
        Ok(BridgeHistory {
            can_undo: state.store.can_undo(),
            can_redo: state.store.can_redo(),
        })
    }

    #[frb(sync)]
    pub fn undo(&self) -> Result<(), BridgeError> {
        let s = self.state()?;
        let s = s.read().map_err(|_| BridgeError::ReadFailed)?;

        s.store.undo().map_err(BridgeError::OpError)?;

        Ok(())
    }

    #[frb(sync)]
    pub fn redo(&self) -> Result<(), BridgeError> {
        let s = self.state()?;
        let s = s.read().map_err(|_| BridgeError::ReadFailed)?;

        s.store.redo().map_err(BridgeError::OpError)?;

        Ok(())
    }
}
