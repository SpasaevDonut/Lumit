use std::{eprintln, ops::ControlFlow, println, sync::mpsc::Receiver};

use flutter_rust_bridge::frb;
use lumit_core::model::EffectInstance;
use lumit_render::{HeadlessRenderer, PreviewEngine, Quality};
use uuid::Uuid;

use crate::api::{
    composition::CompositionReference, effect, layer::LayerReference, project::ProjectReference, state::{BridgeSharedFrameInfoLinux, WorkerResponse, WorkerResponseStream},
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
    RenderCompWithPreview(RenderCompRequestWithPreview)
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
            },
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

    let fd = state
        .renderer
        .render_to_shared_dmabuf(&document, req.comp.id, req.frame, Quality::default())
        .unwrap();


    println!("Finished rendering!");

    stream.add(WorkerResponse::RenderedDMABuf(BridgeSharedFrameInfoLinux {
        fd: fd.fd,
        width: fd.width,
        height: fd.height,
        stride: fd.stride,
        offset: fd.offset,
        drm_fourcc: fd.drm_fourcc,
        modifier: fd.modifier,
    }));

    ()
}

fn render_comp_with_preview(req: RenderCompRequestWithPreview, state: &mut WorkerState, stream: &mut WorkerResponseStream) {
    let mut document = {
        let document = state.project.state();
        let document = document.read().unwrap();
        let document = document.store.snapshot();
        (*document).clone()
    };

    let comp = document.comp_mut(req.layer.comp_id).unwrap();

    let index = comp.layers.iter().position(|i| i.id == req.layer.layer_id).unwrap();

    comp.layers[index].effects = req.effects;

    println!("Rendering frame with modified effects!");

    let fd = state
        .renderer
        .render_to_shared_dmabuf(&document, req.comp.id, req.frame, Quality::default())
        .unwrap();


    println!("Finished rendering!");

    stream.add(WorkerResponse::RenderedDMABuf(BridgeSharedFrameInfoLinux {
        fd: fd.fd,
        width: fd.width,
        height: fd.height,
        stride: fd.stride,
        offset: fd.offset,
        drm_fourcc: fd.drm_fourcc,
        modifier: fd.modifier,
    }));

    ()
}
