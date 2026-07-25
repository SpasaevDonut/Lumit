use std::{eprintln, ops::ControlFlow, println, sync::mpsc::Receiver};

use flutter_rust_bridge::frb;
use lumit_ui::{app_state::preview::PreviewEngine, headless::HeadlessRenderer};
use uuid::Uuid;

use crate::api::{
    composition::CompositionReference,
    project::ProjectReference,
    state::{BridgeSharedFrameInfoLinux, WorkerResponse, WorkerResponseStream},
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
}

#[frb(ignore)]
pub struct RenderCompRequest {
    pub comp: CompositionReference,
    pub frame: u64,
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
        .render_to_shared_dmabuf(&document, req.comp.id, req.frame)
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
