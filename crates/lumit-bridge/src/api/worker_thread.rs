use std::{eprintln, ops::ControlFlow, println, sync::mpsc::Receiver};

use flutter_rust_bridge::frb;
use lumit_core::model::EffectInstance;
// Every `publish_frame` variant needs Quality, so this is unconditional.
use lumit_render::{HeadlessRenderer, PreviewEngine, Quality};
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
}

#[frb(ignore)]
pub struct RenderCompRequestWithPreview {
    pub comp: CompositionReference,
    pub frame: u64,
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
        if let ControlFlow::Break(_) = handle_incoming_requests(&receiver, &mut state, &mut stream)
        {
            eprintln!("Receiver disconnected");
            return;
        }

        process_loop(&mut state);
    }
}

fn process_loop(_: &mut WorkerState) {}

fn handle_incoming_requests(
    receiver: &Receiver<WorkerRequest>,
    state: &mut WorkerState,
    stream: &mut WorkerResponseStream,
) -> ControlFlow<()> {
    match receiver.try_recv() {
        Ok(result) => match result {
            // A frame that cannot be rendered is dropped, not fatal: the worker
            // has to survive to serve the next request.
            WorkerRequest::RenderComp(req) => {
                println!("Rendering comp in worker thread!");
                if let Err(err) = render_comp(req, state, stream) {
                    eprintln!("Dropping frame: {err}");
                }
                ControlFlow::Continue(())
            }
            WorkerRequest::RenderCompWithPreview(req) => {
                println!("Rendering comp in worker thread!");
                if let Err(err) = render_comp_with_preview(req, state, stream) {
                    eprintln!("Dropping preview frame: {err}");
                }
                ControlFlow::Continue(())
            }
        },
        Err(err) => match err {
            std::sync::mpsc::TryRecvError::Empty => ControlFlow::Continue(()),
            std::sync::mpsc::TryRecvError::Disconnected => ControlFlow::Break(()),
        },
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

    publish_frame(state, req.comp.id, req.frame, &document, stream);
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

    publish_frame(state, req.comp.id, req.frame, &document, stream);
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
    document: &lumit_core::Document,
    stream: &mut WorkerResponseStream,
) {
    let shared =
        match state
            .renderer
            .render_to_shared_dmabuf(document, comp, frame, Quality::default())
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
    document: &lumit_core::Document,
    stream: &mut WorkerResponseStream,
) {
    let shared = match state
        .renderer
        .render_to_shared(document, comp, frame, Quality::default())
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
    document: &lumit_core::Document,
    stream: &mut WorkerResponseStream,
) {
    // Full resolution and no draft: the frb path carries no scale yet, so there
    // is nothing to derive a preview quality from. Wiring `scale`/`Quality`
    // through is tracked in docs/TODO.md.
    let rendered =
        state
            .renderer
            .render_preview(document, comp, frame, Quality::default(), 1.0, None);

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
