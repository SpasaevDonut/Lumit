use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    sync::{mpsc::Sender, Arc, LazyLock, Mutex, RwLock},
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
    /// Where committed ops are journalled for crash recovery.
    ///
    /// Shared with the change observer rather than owned outright, and that is
    /// not a style choice: the observer fires from inside `commit`, while the
    /// caller still holds this project's write lock. An observer that reached
    /// back through `PROJECTS` for the journal would take that same lock and
    /// deadlock on the first edit. Sharing an `Arc` means it needs no lookup —
    /// and a `Mutex` rather than a bare handle so recovery can re-arm it when
    /// the document changes identity.
    pub journal: SharedJournal,
    pub sender: Option<Sender<WorkerRequest>>,
}

/// The journal handle the observer writes through. `None` before one is armed,
/// or after a save has made it redundant.
pub type SharedJournal = Arc<Mutex<Option<JournalFile>>>;

/// Arm a journal for `document`, if this platform gives us somewhere to put one.
#[frb(ignore)]
pub(crate) fn journal_for(document: &Document) -> SharedJournal {
    Arc::new(Mutex::new(JournalFile::for_document(document.id)))
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
    /// Which frame this is. See [`BridgeRenderedFrame::frame`].
    pub frame: u64,
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
    /// Which frame this is. See [`BridgeRenderedFrame::frame`].
    pub frame: u64,
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
    /// Which frame of the composition this is.
    ///
    /// **The frontend does not track this itself.** It used to: the Viewer held
    /// the frame it had asked for and assumed the next arrival answered it,
    /// which made a scheduler out of a panel and went wrong the moment anything
    /// else published a frame. A picture that says which frame it is needs no
    /// bookkeeping to place — the frontend paints it and moves the playhead
    /// there.
    pub frame: u64,
    pub width: u32,
    pub height: u32,
    /// Tightly packed, straight (non-premultiplied) RGBA8: `width * height * 4`.
    pub rgba: Vec<u8>,
}

/// One scope trace: a fixed 256x256 RGBA picture the Scopes panel draws.
///
/// Small enough that the per-byte SSE cost `BridgeRenderedFrame` warns about
/// does not matter here — 256 KiB against a 1080p frame's 8 MiB.
#[frb(non_opaque)]
pub struct BridgeScopeTrace {
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
    /// A scope trace, which rides the same stream as the frames so the panel
    /// needs no second channel.
    Scope(BridgeScopeTrace),
    /// Playback finished on its own — it ran off the end of the composition.
    ///
    /// Sent so the transport can show itself stopped without the frontend having
    /// to work out where the end was. Stopping *because the user asked* needs no
    /// message: the frontend already knows, having asked.
    PlaybackEnded,
}

type CallbackStream = StreamSink<ScopedChange>;

pub type WorkerResponseStream = StreamSink<WorkerResponse>;

// The open projects, and the change stream each one publishes to.
//
// Two registries rather than one struct, because the change observer needs the
// stream *while a project's own lock is held* — it fires from inside `commit`.
// Keeping them apart is what lets it reach the stream without touching the lock
// the committing thread already has.
//
// **The lock order is a rule, not a coincidence**, and frb calls run on a worker
// pool so two threads really can be in here at once:
//
//   1. `PROJECTS` or `STREAMS` — the registries. Take what you need, clone the
//      `Arc` out, and *drop the guard*. Never hold one across step 2, and never
//      hold both at once.
//   2. One project's `RwLock`. Held across a commit.
//   3. Inside the observer, from within step 2: `STREAMS` for the sink, and the
//      project's journal `Mutex`. Both are leaves — nothing taken here may ever
//      reach back for a project lock.
//
// Anything that takes these in another order can deadlock against an ordinary
// edit. `new_project` and `open_project` disagreed about steps 1 and 2 until
// this was written down.
pub static PROJECTS: LazyLock<RwLock<BTreeMap<Uuid, Arc<RwLock<LumitBridgeState>>>>> =
    LazyLock::new(|| RwLock::new(BTreeMap::new()));

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

        // The stream first, and its guard dropped before the registry is
        // touched — see the lock-order note above. Registering it before the
        // project exists is safe: the observer cannot fire until the store has
        // one, and the store is built below.
        if let Some(stream) = on_change_stream {
            let mut s = STREAMS.write().map_err(|_| BridgeError::WriteFailed)?;
            s.insert(id, Arc::new(stream));
        }

        let document = Document::new();
        let journal = journal_for(&document);
        let mut state = LumitBridgeState {
            store: DocumentStore::new(document),
            path: None,
            media: MediaCache::default(),
            journal: Arc::clone(&journal),
            sender: None,
        };

        state.store.set_callback(Arc::new(move |c| {
            Self::handle_change_callback(c, id, &journal)
        }));

        PROJECTS
            .write()
            .map_err(|_| BridgeError::WriteFailed)?
            .insert(id, Arc::new(RwLock::new(state)));

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
    fn handle_change_callback(
        document_change: DocumentChange,
        project_id: Uuid,
        journal: &SharedJournal,
    ) {
        // Journal first, then tell the interface. A crash between the two loses
        // the redraw, which the next one fixes; a crash the other way round
        // loses the edit, which nothing does.
        if let Ok(journal) = journal.lock() {
            if let Some(journal) = journal.as_ref() {
                // A journal that cannot be written is not worth taking the
                // editor down for — the work is still in the document, and the
                // next save writes it properly.
                let _ = journal.append(&document_change.op);
            }
        }

        let (comp, layer, items) = op_scope(&document_change.op);

        // Frames are filed by position, not by content, so the edit that just
        // landed did not change any frame's name — drop the held frames or the
        // Viewer would be served the picture from before it.
        //
        // All of them, not the scope's composition: `op_scope` answers "which
        // panel redraws", which is a different and narrower question. A batched
        // edit names no composition, a solid or a relink belongs to the project
        // rather than to one comp, and a precomp layer means an edit to one
        // composition changes every composition that contains it.
        crate::framecache::invalidate_all();

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

        let journal = journal_for(&doc);
        let mut state = LumitBridgeState {
            store: DocumentStore::new(doc),
            path: Some(path),
            media: MediaCache::default(),
            journal: Arc::clone(&journal),
            sender: None,
        };
        state.store.set_callback(Arc::new(move |c| {
            Self::handle_change_callback(c, id, &journal)
        }));

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
