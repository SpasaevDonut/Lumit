use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    println,
    sync::{mpsc::Sender, Arc, LazyLock, RwLock},
};

use flutter_rust_bridge::frb;
use lumit_core::{store::DocumentChange, Document, DocumentStore};
use lumit_project::JournalFile;
use serde_json::json;
use uuid::Uuid;

use crate::{
    api::{
        composition::CompositionReference, layer::LayerReference, project::ProjectReference,
        project_item::ItemReference, worker_thread::WorkerRequest, BridgeError,
    },
    frb_generated::StreamSink,
    media::MediaCache,
};
#[frb(ignore_all)]
pub struct LumitBridgeState {
    pub store: DocumentStore,
    pub path: Option<PathBuf>,
    media: MediaCache,
    pub journal: Option<JournalFile>,
    pub sender: Option<Sender<WorkerRequest>>,
}

#[frb(non_opaque)]
#[derive(Debug)]
pub struct ScopedChange {
    pub project: ProjectReference,
    pub item: Option<ItemReference>,
    pub layer: Option<LayerReference>,
}

#[frb(non_opaque)]
pub struct BridgeSharedFrameInfoLinux {
    pub fd: i32,
    pub width: u32,
    pub height: u32,
    pub stride: u32,
    pub offset: u32,
    /// The DRM fourcc (`DRM_FORMAT_ABGR8888`, memory order R,G,B,A).
    pub drm_fourcc: u32,
    /// The DRM modifier (`DRM_FORMAT_MOD_LINEAR` = 0 on the linear-tiling path).
    pub modifier: u64,
}

#[frb(non_opaque)]
pub enum WorkerResponse {
    RenderedDMABuf(BridgeSharedFrameInfoLinux),
}

type CallbackStream = StreamSink<ScopedChange>;

pub type WorkerResponseStream = StreamSink<WorkerResponse>;

// Global Singleton for storing bridged state.
// Supports storing multiple projects, but for now should only ever have one
// just in case one day we want to support having multiple projects open at a time
pub static PROJECTS: LazyLock<RwLock<BTreeMap<Uuid, Arc<RwLock<LumitBridgeState>>>>> =
    LazyLock::new(|| RwLock::new(BTreeMap::new()));

// Guarded by different lock, so we dont deadlock if called while PROJECTS is locked
pub static STREAMS: LazyLock<RwLock<BTreeMap<Uuid, Arc<CallbackStream>>>> =
    LazyLock::new(|| RwLock::new(BTreeMap::new()));

impl LumitBridgeState {
    #[frb(sync)]
    pub fn new_project(
        on_change_stream: Option<CallbackStream>,
    ) -> Result<ProjectReference, BridgeError> {
        let id = Uuid::now_v7();

        let mut p = PROJECTS.write().map_err(|_| BridgeError::WriteFailed)?;

        let mut state = LumitBridgeState {
            store: DocumentStore::new(Document::new()),
            path: None,
            media: MediaCache::default(),
            journal: None,
            sender: None,
        };

        if let Some(stream) = on_change_stream {
            let mut s = STREAMS.write().map_err(|_| BridgeError::WriteFailed)?;
            s.insert(id, Arc::new(stream));
        }

        state
            .store
            .set_callback(Arc::new(move |c| Self::handle_change_callback(c, id)));

        p.insert(id, Arc::new(RwLock::new(state)));

        Ok(ProjectReference::new(id))
    }

    #[frb(sync)]
    pub fn get_current_project() -> Result<Option<ProjectReference>, BridgeError> {
        let p = PROJECTS.read().map_err(|_| BridgeError::ReadFailed)?;

        Ok(p.keys().next().map(|id| ProjectReference::new(*id)))
    }

    /// Turn a committed op into the narrowest scope Dart can rebuild from.
    ///
    /// This runs inside `DocumentStore`'s observer, which returns nothing, so
    /// there is no caller to hand an error to. Every failure therefore degrades
    /// rather than propagating: an op whose scope cannot be read leaves `item`
    /// and `layer` as `None`, which Dart already treats as "rebuild everything".
    /// That is slower but always correct — the opposite of panicking inside a
    /// commit, which would poison the store's lock and take the editor with it.
    fn handle_change_callback(document_change: DocumentChange, project_id: Uuid) {
        let converted = json!(document_change.op);

        let mut change = ScopedChange {
            project: ProjectReference::new(project_id),
            item: None,
            layer: None,
        };

        // Ops carry their scope as `comp`/`layer` UUID fields; the ones that do
        // not (project-level edits) fall through with both left as None.
        if let serde_json::Value::Object(map) = converted {
            let field = |key: &str| {
                map.get(key)
                    .and_then(|f| f.as_str())
                    .and_then(|f| Uuid::parse_str(f).ok())
            };

            if let Some(comp) = field("comp") {
                change.item = Some(ItemReference::Composition(CompositionReference::new(
                    project_id, comp,
                )));

                if let Some(layer) = field("layer") {
                    change.layer = Some(LayerReference::new(project_id, comp, layer));
                }
            }
        }

        println!("Got change: {:#?}", change);

        let Ok(streams) = STREAMS.read() else {
            eprintln!("Stream registry poisoned; dropping change for {project_id}");
            return;
        };

        if let Some(stream) = streams.get(&project_id) {
            _ = stream.add(change);
        }

        println!("Document changed! - {project_id}");
    }

    #[frb(sync)]
    pub fn open_project(
        path: &str,
        on_change_stream: Option<CallbackStream>,
    ) -> Result<Option<ProjectReference>, BridgeError> {
        let path = PathBuf::from(path);
        let Ok((mut doc, _manifest)) = lumit_project::open(&path) else {
            // Not an error to report: a `.lum` that will not open is the file
            // picker's problem, and Dart shows its own notice for None.
            return Ok(None);
        };

        let id = Uuid::now_v7();

        // Relative media paths resolve against the project's own directory. A
        // path with no parent (a bare filename) resolves against the working
        // directory, which `Path::new("")` gives us — nothing to relink from,
        // rather than a panic.
        let project_dir = path.parent().unwrap_or_else(|| Path::new(""));
        let (_relinked, _missing) = lumit_project::resolve_all_media(&mut doc, project_dir, &[]);

        let mut state = LumitBridgeState {
            store: DocumentStore::new(doc),
            path: Some(path),
            media: MediaCache::default(),
            journal: None,
            sender: None,
        };
        state
            .store
            .set_callback(Arc::new(move |c| Self::handle_change_callback(c, id)));

        if let Some(stream) = on_change_stream {
            let mut s = STREAMS.write().map_err(|_| BridgeError::WriteFailed)?;
            s.insert(id, Arc::new(stream));
        }

        {
            let mut p = PROJECTS.write().map_err(|_| BridgeError::WriteFailed)?;

            for entry in p.values() {
                // A project whose lock is poisoned is being discarded anyway,
                // so a failed cache clear is not worth refusing the open over.
                if let Ok(mut e) = entry.write() {
                    e.media.clear();
                }
            }

            // Clear any other project that is currently open
            // Will also prevent any existing references from working
            p.clear();

            p.insert(id, Arc::new(RwLock::new(state)));
        }

        Ok(Some(ProjectReference::new(id)))
    }
}
