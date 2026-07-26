use core::panic;
use std::{
    collections::BTreeMap,
    path::PathBuf,
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
        project_item::ItemReference, worker_thread::WorkerRequest,
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
    pub fn new_project(on_change_stream: Option<CallbackStream>) -> ProjectReference {
        let id = Uuid::now_v7();

        let mut p = PROJECTS.write().unwrap();

        let mut state = LumitBridgeState {
            store: DocumentStore::new(Document::new()),
            path: None,
            media: MediaCache::default(),
            journal: None,
            sender: None,
        };

        match on_change_stream {
            Some(stream) => {
                let mut s = STREAMS.write().unwrap();
                s.insert(id.clone(), Arc::new(stream));
            }
            None => (),
        }

        state.store.set_callback(Arc::new(move |c| {
            Self::handle_change_callback(c, id.clone())
        }));

        p.insert(id.clone(), Arc::new(RwLock::new(state)));

        ProjectReference::new(id)
    }

    #[frb(sync)]
    pub fn get_current_project() -> Option<ProjectReference> {
        let p = PROJECTS.read().unwrap();
        let item = p.iter().next();

        match item {
            Some(i) => Some(ProjectReference::new(i.0.clone())),
            None => None,
        }
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
    ) -> Option<ProjectReference> {
        let path = PathBuf::from(path);
        match lumit_project::open(&path) {
            Ok((mut doc, _manifest)) => {
                let id = Uuid::now_v7();

                let project_dir = path.parent().unwrap();
                let (_relinked, _missing) =
                    lumit_project::resolve_all_media(&mut doc, project_dir, &[]);

                let mut state = LumitBridgeState {
                    store: DocumentStore::new(doc),
                    path: Some(path),
                    media: MediaCache::default(),
                    journal: None,
                    sender: None,
                };
                state.store.set_callback(Arc::new(move |c| {
                    Self::handle_change_callback(c, id.clone())
                }));

                match on_change_stream {
                    Some(stream) => {
                        let mut s = STREAMS.write().unwrap();
                        s.insert(id.clone(), Arc::new(stream));
                    }
                    None => (),
                }

                {
                    let mut p = PROJECTS.write().unwrap();

                    for entry in p.iter_mut() {
                        let mut e = entry.1.write().unwrap();
                        e.media.clear()
                    }

                    // Clear any other project that is currently open
                    // Will also prevent any existing references from working
                    p.clear();

                    p.insert(id.clone(), Arc::new(RwLock::new(state)));
                }

                Some(ProjectReference::new(id))
            }
            Err(_) => None,
        }
    }
}
