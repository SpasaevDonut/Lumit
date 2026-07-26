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
    composition::CompositionReference,
    layer::LayerReference,
    project::ProjectReference,
    state::{WorkerResponse, WorkerResponseStream},
};

#[frb(ignore)]
pub struct WorkerState {
    pub preview_engine: PreviewEngine,
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
        let state = project.state();
        let mut state = state.write().unwrap();

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

    let mut state = WorkerState {
        project: project,
        renderer: HeadlessRenderer::new().unwrap(),
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
    return match receiver.try_recv() {
        Ok(result) => match result {
            WorkerRequest::RenderComp(req) => {
                println!("Rendering comp in worker thread!");
                render_comp(req, state, stream);
                ControlFlow::Continue(())
            }
            WorkerRequest::RenderCompWithPreview(req) => {
                println!("Rendering comp in worker thread!");
                render_comp_with_preview(req, state, stream);
                ControlFlow::Continue(())
            }
        },
        Err(err) => match err {
            std::sync::mpsc::TryRecvError::Empty => ControlFlow::Continue(()),
            std::sync::mpsc::TryRecvError::Disconnected => ControlFlow::Break(()),
        },
    };
}

fn render_comp(req: RenderCompRequest, state: &mut WorkerState, stream: &mut WorkerResponseStream) {
    let document = {
        let document = state.project.state();
        let document = document.read().unwrap();
        let document = document.store.snapshot();
        document
    };

    println!("Rendering frame!");

    publish_frame(state, req.comp.id, req.frame, &document, stream);
}

fn render_comp_with_preview(
    req: RenderCompRequestWithPreview,
    state: &mut WorkerState,
    stream: &mut WorkerResponseStream,
) {
    let mut document = {
        let document = state.project.state();
        let document = document.read().unwrap();
        let document = document.store.snapshot();
        (*document).clone()
    };

    let comp = document.comp_mut(req.layer.comp_id).unwrap();

    let index = comp
        .layers
        .iter()
        .position(|i| i.id == req.layer.layer_id)
        .unwrap();

    comp.layers[index].effects = req.effects;

    println!("Rendering frame with modified effects!");

    publish_frame(state, req.comp.id, req.frame, &document, stream);
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
