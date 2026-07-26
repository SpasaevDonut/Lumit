use std::{eprintln, ops::ControlFlow, println, sync::mpsc::Receiver};

use flutter_rust_bridge::frb;
use lumit_core::model::EffectInstance;
use lumit_render::{HeadlessRenderer, PreviewEngine};
use uuid::Uuid;

#[cfg(all(target_os = "linux", feature = "shared-texture-linux"))]
use lumit_render::Quality;

#[cfg(all(target_os = "linux", feature = "shared-texture-linux"))]
use crate::api::state::BridgeSharedFrameInfoLinux;

use crate::api::{
    composition::CompositionReference, layer::LayerReference, project::ProjectReference,
    state::WorkerResponseStream, BridgeError,
};

#[frb(ignore)]
pub struct WorkerState {
    /// The realtime preview-tier controller (K-030/K-171). Held so the worker
    /// can feed it measured render costs and read the tier back, which is not
    /// wired yet — see docs/TODO.md, "Bridge".
    #[allow(dead_code)]
    pub preview_engine: PreviewEngine,
    /// Only the Linux DMA-BUF `publish_frame` reads this so far, so on every
    /// other target it is held but unused until the Windows shared-texture and
    /// read-back paths are wired.
    #[allow(dead_code)]
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
/// touches the document — no commit, no undo entry, no journal write. This is
/// the effect-parameter counterpart of the existing `preview_transform` path
/// (docs/TODO.md, "Effect-param drag preview").
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
/// Only the Linux DMA-BUF path is wired through this worker so far (K-177) —
/// the zero-copy Viewer the Flutter shell currently draws. The Windows
/// shared-texture path (`HeadlessRenderer::render_to_shared`) and the portable
/// CPU read-back path (`render_rgba`) still have to be brought across from the
/// old bridge, so on those builds there is nothing to publish yet. That is why
/// this is split by `cfg` rather than calling the DMA-BUF entry point directly:
/// `render_to_shared_dmabuf` only exists on Linux with `shared-texture-linux`,
/// and Lumit is Windows-first — the crate has to compile there.
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

    println!("Finished rendering!");

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

#[cfg(not(all(target_os = "linux", feature = "shared-texture-linux")))]
fn publish_frame(
    _state: &mut WorkerState,
    _comp: Uuid,
    _frame: u64,
    _document: &lumit_core::Document,
    _stream: &mut WorkerResponseStream,
) {
    eprintln!(
        "This build has no Viewer render path wired through the worker yet \
         (only Linux + shared-texture-linux); dropping the frame."
    );
}
