use std::{eprintln, println, sync::mpsc::Receiver};

use flutter_rust_bridge::frb;
use lumit_core::model::EffectInstance;
use lumit_render::{HeadlessRenderer, PreviewEngine};

// The quality policy is v0's, shared rather than copied: two implementations of
// "what does a scale of 0.5 mean for the decode" would drift, and the two
// frontends would then decode at different sizes for the same on-screen scale.
use crate::render::quality_for;
use uuid::Uuid;

// Each frame type is only constructed by its own platform's `publish_frame`, so
// importing all three unconditionally would warn on two of them in every build.
#[cfg(not(any(
    all(target_os = "linux", feature = "shared-texture-linux"),
    all(windows, feature = "shared-texture")
)))]
use crate::api::state::BridgeRenderedFrame;
#[cfg(all(windows, feature = "shared-texture"))]
use crate::api::state::BridgeSharedFrameInfo;
#[cfg(all(target_os = "linux", feature = "shared-texture-linux"))]
use crate::api::state::BridgeSharedFrameInfoLinux;

use crate::api::{
    composition::CompositionReference,
    layer::LayerReference,
    project::ProjectReference,
    state::{WorkerResponse, WorkerResponseStream},
    BridgeError,
};

#[frb(ignore)]
pub struct WorkerState {
    /// The realtime preview-tier controller (K-030/K-171). Held so the worker
    /// can feed it measured render costs and read the tier back, which is not
    /// wired yet — see docs/TODO.md, "Bridge".
    #[allow(dead_code)]
    pub preview_engine: PreviewEngine,
    /// The session's renderer, owned outright by this thread — no lock, because
    /// nothing else touches it. Every `publish_frame` variant reads it.
    pub renderer: HeadlessRenderer,
    pub project: ProjectReference,
}

#[frb(ignore)]
pub enum WorkerRequest {
    RenderComp(RenderCompRequest),
    RenderCompWithPreview(RenderCompRequestWithPreview),
}

#[frb(ignore)]
pub struct RenderCompRequest {
    pub comp: CompositionReference,
    pub frame: u64,
    /// The on-screen scale of the Viewer, 1.0 meaning "shown at comp
    /// resolution". Below 1.0 the frame is being displayed smaller than the comp,
    /// so it is decoded smaller too — see [`crate::render::quality_for`].
    pub scale: f32,
}

#[frb(ignore)]
pub struct RenderCompRequestWithPreview {
    pub comp: CompositionReference,
    pub frame: u64,
    pub scale: f32,
    pub layer: LayerReference,
    pub effects: Vec<EffectInstance>,
}

#[frb(ignore)]
pub fn run_worker(project: ProjectReference, stream: WorkerResponseStream) {
    let (send_to_worker, receive_from_app) = std::sync::mpsc::channel::<WorkerRequest>();

    {
        let Ok(state) = project.state() else {
            eprintln!("No such project; not starting the render worker");
            return;
        };
        let Ok(mut state) = state.write() else {
            eprintln!("Project state poisoned; not starting the render worker");
            return;
        };

        state.sender = Some(send_to_worker);
    }

    std::thread::spawn(move || worker_loop(project, receive_from_app, stream));
}

#[frb(ignore)]
fn worker_loop(
    project: ProjectReference,
    receiver: Receiver<WorkerRequest>,
    stream: WorkerResponseStream,
) {
    println!("Worker thread started");
    let mut stream = stream;

    // No renderer means no Viewer, but the editor itself stays usable — the
    // worker just stops instead of taking the process down with it.
    let renderer = match HeadlessRenderer::new() {
        Ok(renderer) => renderer,
        Err(err) => {
            eprintln!("Could not create the renderer, stopping the worker: {err}");
            return;
        }
    };

    let mut state = WorkerState {
        project,
        renderer,
        preview_engine: PreviewEngine::default(),
    };

    loop {
        // Block until there is something to do. This used to be `try_recv` in a
        // bare `loop` beside an empty `process_loop`, which spun a whole core
        // continuously whether or not anything was rendering.
        let Ok(request) = receiver.recv() else {
            eprintln!("Receiver disconnected, stopping the worker");
            return;
        };

        // Latest wins. Anything that queued up while the previous frame was
        // rendering is already superseded — a drag emits a request every ~20 ms
        // and a render takes longer than that, so without this the worker works
        // through a backlog of frames nothing will ever see, each one delaying
        // the only one the user is waiting for. Draining to the newest is what
        // keeps a fast drag feeling attached to the pointer (docs/13 §2, B3:
        // the *first* frame after an interaction is what is budgeted).
        let mut request = request;
        let mut superseded = 0usize;
        while let Ok(newer) = receiver.try_recv() {
            request = newer;
            superseded += 1;
        }
        if superseded > 0 {
            println!("Skipped {superseded} superseded render request(s)");
        }

        // A frame that cannot be rendered is dropped, not fatal: the worker has
        // to survive to serve the next request.
        let outcome = match request {
            WorkerRequest::RenderComp(req) => render_comp(req, &mut state, &mut stream),
            WorkerRequest::RenderCompWithPreview(req) => {
                render_comp_with_preview(req, &mut state, &mut stream)
            }
        };
        if let Err(err) = outcome {
            eprintln!("Dropping frame: {err}");
        }
    }
}

fn render_comp(
    req: RenderCompRequest,
    state: &mut WorkerState,
    stream: &mut WorkerResponseStream,
) -> Result<(), BridgeError> {
    let document = {
        let document = state.project.state()?;
        let document = document.read().map_err(|_| BridgeError::ReadFailed)?;
        document.store.snapshot()
    };

    println!("Rendering frame!");

    publish_frame(state, req.comp.id, req.frame, req.scale, &document, stream);
    Ok(())
}

/// Render a frame under effect values the user is still dragging.
///
/// The effect stack is patched on a *clone* of the snapshot, so a drag never
/// touches the document — no commit, no undo entry, no journal write.
///
/// Note this is a *different* idiom from the v0 bridge's `preview_effect_param`
/// (ABI 12), which keeps a persistent overlay in `Bridge::preview` and replays
/// `Op::SetLayerEffects` over it. Here the whole effect list rides along with the
/// render request instead. Worth converging on one of the two when this path is
/// finished.
fn render_comp_with_preview(
    req: RenderCompRequestWithPreview,
    state: &mut WorkerState,
    stream: &mut WorkerResponseStream,
) -> Result<(), BridgeError> {
    let mut document = {
        let document = state.project.state()?;
        let document = document.read().map_err(|_| BridgeError::ReadFailed)?;
        (*document.store.snapshot()).clone()
    };

    let comp = document
        .comp_mut(req.layer.comp_id)
        .ok_or(BridgeError::InvalidComp)?;

    let index = comp
        .layers
        .iter()
        .position(|i| i.id == req.layer.layer_id)
        .ok_or(BridgeError::InvalidLayer)?;

    comp.layers[index].effects = req.effects;

    println!("Rendering frame with modified effects!");

    publish_frame(state, req.comp.id, req.frame, req.scale, &document, stream);
    Ok(())
}

/// Render one frame and publish it to Dart.
///
/// Three implementations, selected at compile time, because the zero-copy entry
/// points only *exist* under their own platform and feature. The conditions are
/// mutually exclusive and together exhaustive, so exactly one is compiled:
///
/// 1. Linux + `shared-texture-linux` → a DMA-BUF handle (K-177).
/// 2. Windows + `shared-texture` → a shared D3D12 texture handle (K-177).
/// 3. anything else → a CPU read-back of the pixels.
///
/// The read-back is `render_preview`, deliberately **not** `render_rgba`.
/// `render_rgba` is the export path: it decodes afresh at full resolution and
/// retains nothing. `render_preview` decodes at the quality asked for and reuses
/// retained pixels when the decode plan has not changed, which is what makes a
/// drag cheap — v0 uses it for both the Viewer and drag previews.
///
/// A failed render drops the frame and says so; it never takes the worker down.
#[cfg(all(target_os = "linux", feature = "shared-texture-linux"))]
fn publish_frame(
    state: &mut WorkerState,
    comp: Uuid,
    frame: u64,
    scale: f32,
    document: &lumit_core::Document,
    stream: &mut WorkerResponseStream,
) {
    let shared =
        match state
            .renderer
            .render_to_shared_dmabuf(document, comp, frame, quality_for(scale))
        {
            Ok(shared) => shared,
            Err(err) => {
                eprintln!("Shared DMA-BUF render failed, dropping frame: {err}");
                return;
            }
        };

    _ = stream.add(WorkerResponse::RenderedDMABuf(BridgeSharedFrameInfoLinux {
        fd: shared.fd,
        width: shared.width,
        height: shared.height,
        stride: shared.stride,
        offset: shared.offset,
        drm_fourcc: shared.drm_fourcc,
        modifier: shared.modifier,
    }));
}

#[cfg(all(windows, feature = "shared-texture"))]
fn publish_frame(
    state: &mut WorkerState,
    comp: Uuid,
    frame: u64,
    scale: f32,
    document: &lumit_core::Document,
    stream: &mut WorkerResponseStream,
) {
    let shared = match state
        .renderer
        .render_to_shared(document, comp, frame, quality_for(scale))
    {
        Ok(shared) => shared,
        Err(err) => {
            eprintln!("Shared-texture render failed, dropping frame: {err}");
            return;
        }
    };

    _ = stream.add(WorkerResponse::RenderedSharedTexture(
        BridgeSharedFrameInfo {
            handle: shared.handle,
            width: shared.width,
            height: shared.height,
        },
    ));
}

#[cfg(not(any(
    all(target_os = "linux", feature = "shared-texture-linux"),
    all(windows, feature = "shared-texture")
)))]
fn publish_frame(
    state: &mut WorkerState,
    comp: Uuid,
    frame: u64,
    scale: f32,
    document: &lumit_core::Document,
    stream: &mut WorkerResponseStream,
) {
    // `scale` twice over, and they mean different things: `quality_for` turns it
    // into a *decode* size (don't decode 4K footage to fill a 500 px panel), and
    // the trailing argument resizes the finished buffer. Both matter — the first
    // is where the time goes, the second is how many bytes then cross to Dart,
    // which on this path is the expensive part (see `BridgeRenderedFrame`).
    let rendered =
        state
            .renderer
            .render_preview(document, comp, frame, quality_for(scale), scale, None);

    let (rgba, width, height) = match rendered {
        Ok(frame) => frame,
        Err(err) => {
            eprintln!("Read-back render failed, dropping frame: {err}");
            return;
        }
    };

    _ = stream.add(WorkerResponse::RenderedPixels(BridgeRenderedFrame {
        width,
        height,
        rgba,
    }));
}
