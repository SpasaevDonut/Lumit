use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    sync::{mpsc::Sender, Arc, LazyLock, RwLock},
};

use flutter_rust_bridge::frb;
use lumit_core::{store::DocumentChange, Document, DocumentStore};
use lumit_project::JournalFile;
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
    pub(crate) media: MediaCache,
    pub journal: Option<JournalFile>,
    pub sender: Option<Sender<WorkerRequest>>,
}

#[frb(non_opaque)]
#[derive(Debug)]
pub struct ScopedChange {
    pub project: ProjectReference,
    pub item: Option<ItemReference>,
    pub layer: Option<LayerReference>,
    /// The project item list changed: an item was added, removed, renamed,
    /// refiled or relinked. The Project panel rebuilds on this and ignores
    /// everything else, so tweaking a layer value no longer re-probes every
    /// footage file on disk.
    pub items: bool,
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

/// The Windows zero-copy Viewer frame (K-177): an NT handle to a shared D3D12
/// texture the Flutter runner imports directly, so no pixels cross the FFI
/// boundary. The handle is stable for the session and changes only when the
/// comp's dimensions do. The format is always RGBA8, so it is not carried.
#[frb(non_opaque)]
pub struct BridgeSharedFrameInfo {
    /// The NT `HANDLE` value. `u64` because a Windows handle is 64-bit; it
    /// reaches Dart as a `BigInt`.
    pub handle: u64,
    pub width: u32,
    pub height: u32,
}

/// A Viewer frame that came back as pixels rather than a GPU handle — the
/// portable path, used on any build without one of the zero-copy features (the
/// default on Windows). Dart turns `rgba` into a `ui.Image`.
///
/// Costly by construction: flutter_rust_bridge's SSE codec serialises a
/// `Vec<u8>` one byte at a time, measured at 8.8 ms for a 1080p frame and 37 ms
/// at 4K — the whole of budget B1 (docs/13 §2) for the 1080p case, before any
/// rendering. Prefer a zero-copy build where the platform allows one; see
/// docs/TODO.md for the fix.
#[frb(non_opaque)]
pub struct BridgeRenderedFrame {
    pub width: u32,
    pub height: u32,
    /// Tightly packed, straight (non-premultiplied) RGBA8: `width * height * 4`.
    pub rgba: Vec<u8>,
}

/// What the render worker publishes for one frame. Which variant a build can
/// actually produce is decided at compile time by the zero-copy features — see
/// `worker_thread::publish_frame` — but all three are always declared, so the
/// generated Dart is identical on every platform and the Viewer holds one
/// `switch` over the lot.
#[frb(non_opaque)]
pub enum WorkerResponse {
    /// Linux, `shared-texture-linux`.
    RenderedDMABuf(BridgeSharedFrameInfoLinux),
    /// Windows, `shared-texture`.
    RenderedSharedTexture(BridgeSharedFrameInfo),
    /// Everything else: a CPU read-back.
    RenderedPixels(BridgeRenderedFrame),
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

/// The scope of one op: which composition it touches, which layer within it,
/// and whether it changed the project item list.
///
/// Matching the enum rather than sniffing a JSON blob for `comp`/`layer` string
/// fields is the whole point: every project-level op used to fall through with
/// nothing set, so the Project panel had no way to tell "an item was added" from
/// "someone nudged an opacity keyframe" and rebuilt on both.
///
/// Structural layer ops (add / remove / reorder) report the comp but not the
/// layer: what changed is the comp's layer list, not one layer's contents.
pub(crate) fn op_scope(op: &lumit_core::Op) -> (Option<Uuid>, Option<Uuid>, bool) {
    use lumit_core::Op;
    match op {
        // The project item list itself.
        Op::AddItem { .. }
        | Op::RemoveItem { .. }
        | Op::RenameItem { .. }
        | Op::SetMediaRef { .. }
        | Op::SetFolderChildren { .. }
        | Op::SetAutoFolder { .. }
        // A solid def is a project item, and its name shows in the panel.
        | Op::SetSolidDef { .. } => (None, None, true),

        // Comp settings carry the comp's name, so the panel row changes too.
        Op::SetCompSettings { comp, .. } => (Some(*comp), None, true),

        // The comp, but no one layer.
        Op::AddLayer { comp, .. }
        | Op::RemoveLayer { comp, .. }
        | Op::ReorderLayer { comp, .. }
        | Op::SetCompMotionBlur { comp, .. }
        | Op::SetWorkArea { comp, .. }
        | Op::SetCompMarkers { comp, .. } => (Some(*comp), None, false),

        // One layer's own contents.
        Op::SetLayerSpan { comp, layer, .. }
        | Op::RenameLayer { comp, layer, .. }
        | Op::SetLayerMasks { comp, layer, .. }
        | Op::SetLayerEffects { comp, layer, .. }
        | Op::SetLayerFx { comp, layer, .. }
        | Op::SetLayerThreeD { comp, layer, .. }
        | Op::SetSequenceClips { comp, layer, .. }
        | Op::SetLayerAudible { comp, layer, .. }
        | Op::SetLayerVisible { comp, layer, .. }
        | Op::SetLayerSolo { comp, layer, .. }
        | Op::SetLayerMotionBlur { comp, layer, .. }
        | Op::SetLayerLocked { comp, layer, .. }
        | Op::SetLayerLabel { comp, layer, .. }
        | Op::SetLayerCollapse { comp, layer, .. }
        | Op::SetTextDocument { comp, layer, .. }
        | Op::SetLayerBlend { comp, layer, .. }
        | Op::SetLayerMatte { comp, layer, .. }
        | Op::SetLayerParent { comp, layer, .. }
        | Op::SetTransformProperty { comp, layer, .. }
        | Op::SetCameraZoom { comp, layer, .. }
        | Op::SetLayerVolume { comp, layer, .. }
        | Op::SetLayerRetime { comp, layer, .. } => (Some(*comp), Some(*layer), false),

        // A batch is as broad as its members: the item flag is the union, and
        // the reference scope widens to "no one subtree" rather than picking a
        // member's comp and leaving the others unrefreshed.
        Op::Batch { ops } => (None, None, ops.iter().any(|o| op_scope(o).2)),
    }
}

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
    /// there is no caller to hand an error to. It therefore cannot fail: the
    /// scope comes from matching the `Op` enum, so a new variant is a compile
    /// error here rather than a silently unscoped change at runtime.
    fn handle_change_callback(document_change: DocumentChange, project_id: Uuid) {
        let (comp, layer, items) = op_scope(&document_change.op);

        let change = ScopedChange {
            project: ProjectReference::new(project_id),
            item: comp
                .map(|c| ItemReference::Composition(CompositionReference::new(project_id, c))),
            layer: comp
                .zip(layer)
                .map(|(c, l)| LayerReference::new(project_id, c, l)),
            items,
        };

        let Ok(streams) = STREAMS.read() else {
            eprintln!("Stream registry poisoned; dropping change for {project_id}");
            return;
        };

        if let Some(stream) = streams.get(&project_id) {
            _ = stream.add(change);
        }
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
