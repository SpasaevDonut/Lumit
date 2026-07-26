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
    TraceScope(RenderScopeRequest),
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

/// A render of one frame with part of `layer` substituted — the live-drag path.
///
/// Both overrides are optional and independent, so the one request shape serves
/// an effect drag and a transform drag rather than each growing its own worker
/// message. `None` means "leave that part of the layer as the document has it".
/// A scope trace of one frame — the Scopes panel's request.
///
/// It renders the comp to CPU pixels and bins them on the GPU, whichever
/// publish path the Viewer is on: the zero-copy paths never read pixels back, so
/// the trace cannot borrow the Viewer's frame and asks for its own. That is why
/// the panel throttles rather than tracing every frame.
#[frb(ignore)]
pub struct RenderScopeRequest {
    pub comp: CompositionReference,
    pub frame: u64,
    pub scale: f32,
    /// Which trace: the codes `lumit_render` reads — 0 waveform, 1 parade,
    /// 2 vectorscope, 3 histogram.
    pub kind: u32,
    /// Background, trace, then the R, G and B channel tints, each `[r, g, b]`.
    pub colours: [[u8; 3]; 5],
}

#[frb(ignore)]
pub struct RenderCompRequestWithPreview {
    pub comp: CompositionReference,
    pub frame: u64,
    pub scale: f32,
    pub layer: LayerReference,
    pub effects: Option<Vec<EffectInstance>>,
    pub transform: Option<crate::api::layer::BridgeTransform>,
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

        // Latest wins — but *per kind*, which is the whole point.
        //
        // Anything that queued while the previous frame rendered is superseded:
        // a drag emits a request every ~20 ms and a render takes longer, so
        // without this the worker works through a backlog nothing will ever
        // see, each one delaying the only frame the user is waiting for
        // (docs/13 §2, B3: the *first* frame after an interaction is budgeted).
        //
        // What a picture supersedes is another picture. Draining to the single
        // newest request of any kind meant a Scopes trace threw away every
        // frame render queued behind it — and during playback the Scopes panel
        // asks every 120 ms while the Viewer asks every tick, so the picture
        // froze on its first frame while the scopes kept updating. A trace and
        // a frame are different jobs; neither is the other's replacement.
        let (picture, scope, superseded) = drain_to_newest(request, &receiver, |r| {
            matches!(r, WorkerRequest::TraceScope(_))
        });
        if superseded > 0 {
            println!("Skipped {superseded} superseded render request(s)");
        }

        // The picture first: it is what the user is looking at, and a trace of
        // a frame that is about to be replaced is worth less than the frame.
        //
        // A frame that cannot be rendered is dropped, not fatal: the worker has
        // to survive to serve the next request.
        for request in picture.into_iter().chain(scope) {
            let outcome = match request {
                WorkerRequest::RenderComp(req) => render_comp(req, &mut state, &mut stream),
                // Named for what it does rather than "render", so the three
                // variants do not all share a prefix that says nothing.
                WorkerRequest::TraceScope(req) => trace_scope(req, &mut state, &mut stream),
                WorkerRequest::RenderCompWithPreview(req) => {
                    render_comp_with_preview(req, &mut state, &mut stream)
                }
            };
            if let Err(err) = outcome {
                eprintln!("Dropping frame: {err}");
            }
        }
    }
}

/// Take everything queued and keep only the newest of each kind: the newest
/// picture, and the newest scope trace.
///
/// Generic over the classifier so the policy can be tested on its own — a
/// `WorkerRequest` needs a live project behind it, and the rule being tested has
/// nothing to do with rendering.
///
/// Returns `(picture, scope, superseded_count)`.
#[frb(ignore)]
fn drain_to_newest<T>(
    first: T,
    receiver: &Receiver<T>,
    is_scope: impl Fn(&T) -> bool,
) -> (Option<T>, Option<T>, usize) {
    let mut picture = None;
    let mut scope = None;
    let mut superseded = 0usize;
    let mut newest = Some(first);
    while let Some(item) = newest.take() {
        let slot = if is_scope(&item) {
            &mut scope
        } else {
            &mut picture
        };
        if slot.replace(item).is_some() {
            superseded += 1;
        }
        newest = receiver.try_recv().ok();
    }
    (picture, scope, superseded)
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

    if let Some(effects) = req.effects {
        comp.layers[index].effects = effects;
    }
    if let Some(transform) = &req.transform {
        transform.write(&mut comp.layers[index].transform)?;
    }

    publish_frame(state, req.comp.id, req.frame, req.scale, &document, stream);
    Ok(())
}

/// The cache key for one rendered frame: the comp, the frame, and the scale it
/// was made at, packed into the `u128` the cache keys on.
///
/// The scale is quantised to a thousandth, because a panel resized by half a
/// pixel produces a scale that differs in the last bits and would miss every
/// time — a cache that never hits is worse than none, since it also holds the
/// memory.
#[frb(ignore)]
fn frame_key(comp: Uuid, frame: u64, scale: f32) -> crate::framecache::FrameKey {
    let quantised = (scale * 1000.0).round() as u64;
    // The comp id's low 64 bits, then the frame and scale — collisions would
    // need two comps agreeing in 64 bits *and* the same frame at the same scale.
    let low = comp.as_u128() as u64;
    (u128::from(low) << 64) | (u128::from(frame) << 16) | u128::from(quantised & 0xFFFF)
}

/// Trace `frame` and publish the result.
///
/// Always a CPU read-back even on a zero-copy build: the binning kernel needs
/// the pixels, and on those builds nothing ever brings them back. A failure
/// publishes nothing rather than taking the worker down — a scope that cannot
/// draw is a blank panel, not a lost session.
#[frb(ignore)]
fn trace_scope(
    req: RenderScopeRequest,
    state: &mut WorkerState,
    stream: &mut WorkerResponseStream,
) -> Result<(), BridgeError> {
    let document = {
        let document = state.project.state()?;
        let document = document.read().map_err(|_| BridgeError::ReadFailed)?;
        document.store.snapshot()
    };

    let rendered = state.renderer.render_preview(
        &document,
        req.comp.id,
        req.frame,
        quality_for(req.scale),
        req.scale,
        None,
    );
    let Ok((rgba, width, height)) = rendered else {
        eprintln!("Scope render failed, dropping the trace");
        return Ok(());
    };

    match state
        .renderer
        .render_scope(&rgba, width, height, req.kind, req.colours)
    {
        Ok(trace) => {
            _ = stream.add(WorkerResponse::Scope(crate::api::state::BridgeScopeTrace {
                rgba: trace,
            }));
        }
        Err(err) => eprintln!("Scope trace failed: {err}"),
    }
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
    //
    // Served through the rendered-frame cache, so scrubbing back to a frame
    // already made does not render it again. The key names the *content*: comp,
    // frame, and the scale it was made at — two requests that agree on all three
    // produce identical pixels, and one that does not must not be served the
    // other's.
    let key = frame_key(comp, frame, scale);
    let started = std::time::Instant::now();
    let rendered = crate::framecache::get_or_render(key, || {
        state
            .renderer
            .render_preview(document, comp, frame, quality_for(scale), scale, None)
            .ok()
            .map(|(rgba, width, height)| (width, height, rgba))
    });

    let Some((width, height, rgba)) = rendered else {
        eprintln!("Read-back render failed, dropping frame");
        return;
    };

    // Tell the realtime controller what that cost, so playback can drop to a
    // coarser tier when the comp is too heavy to keep up (K-171). Only a genuine
    // render counts: a cache hit measures the cache, not the comp.
    if started.elapsed().as_secs_f64() > 0.001 {
        let fps = document
            .comp(comp)
            .map(|c| c.frame_rate.fps())
            .unwrap_or(0.0);
        crate::realtime::observe(started.elapsed().as_secs_f64(), fps, scale);
    }

    _ = stream.add(WorkerResponse::RenderedPixels(BridgeRenderedFrame {
        width,
        height,
        rgba,
    }));
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::drain_to_newest;
    use std::sync::mpsc::channel;

    /// The requests these tests queue: a picture carrying a frame number, and a
    /// scope trace. Standing in for `WorkerRequest`, which needs a live project.
    #[derive(Debug, PartialEq, Eq, Clone, Copy)]
    enum Req {
        Picture(u32),
        Scope(u32),
    }

    fn is_scope(r: &Req) -> bool {
        matches!(r, Req::Scope(_))
    }

    /// The bug this policy exists to fix: during playback the Viewer asks for a
    /// frame every tick and the Scopes panel asks for a trace every 120 ms.
    /// Draining to the single newest request of *any* kind meant one trace threw
    /// away every frame queued behind it, so the picture froze on its first
    /// frame while the scopes carried on updating.
    #[test]
    fn a_scope_trace_does_not_supersede_a_frame() {
        let (tx, rx) = channel();
        for frame in 1..=3 {
            tx.send(Req::Picture(frame)).unwrap();
        }
        // The trace arrives last, which is what used to win outright.
        tx.send(Req::Scope(9)).unwrap();
        drop(tx);

        let (picture, scope, superseded) = drain_to_newest(Req::Picture(0), &rx, is_scope);
        assert_eq!(
            picture,
            Some(Req::Picture(3)),
            "the newest frame survives a trace queued behind it"
        );
        assert_eq!(scope, Some(Req::Scope(9)), "and the trace is served too");
        assert_eq!(superseded, 3, "the three older frames were dropped");
    }

    /// The behaviour the policy is *for*: a backlog of pictures collapses to the
    /// newest, because the ones behind it are frames nobody will ever see.
    #[test]
    fn pictures_still_collapse_to_the_newest() {
        let (tx, rx) = channel();
        for frame in 1..=5 {
            tx.send(Req::Picture(frame)).unwrap();
        }
        drop(tx);

        let (picture, scope, superseded) = drain_to_newest(Req::Picture(0), &rx, is_scope);
        assert_eq!(picture, Some(Req::Picture(5)));
        assert_eq!(scope, None, "nothing asked for a trace");
        assert_eq!(superseded, 5);
    }

    /// And traces collapse among themselves for the same reason.
    #[test]
    fn traces_collapse_to_the_newest_too() {
        let (tx, rx) = channel();
        tx.send(Req::Scope(2)).unwrap();
        tx.send(Req::Scope(3)).unwrap();
        drop(tx);

        let (picture, scope, superseded) = drain_to_newest(Req::Scope(1), &rx, is_scope);
        assert_eq!(picture, None);
        assert_eq!(scope, Some(Req::Scope(3)));
        assert_eq!(superseded, 2);
    }

    /// A single request with nothing behind it is served as it is.
    #[test]
    fn a_lone_request_is_not_counted_as_superseded() {
        let (tx, rx) = channel::<Req>();
        drop(tx);

        let (picture, scope, superseded) = drain_to_newest(Req::Picture(7), &rx, is_scope);
        assert_eq!(picture, Some(Req::Picture(7)));
        assert_eq!(scope, None);
        assert_eq!(superseded, 0);
    }
}
