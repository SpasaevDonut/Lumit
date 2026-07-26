use std::{eprintln, println, sync::mpsc::Receiver};

use crate::api::composition::BridgePlaybackMode;
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
// Always needed now: the read-back path is no longer the *fallback* transport
// but one of two, chosen per render by the playback mode.
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
/// How one publish should behave: which playback mode it is serving, and
/// whether its pixels may be kept.
///
/// A pair rather than two arguments because they travel together and are
/// meaningless apart — and because they answer different questions, so folding
/// them into one flag would be wrong: a drag is full resolution (not adaptive)
/// yet must never be kept, its pixels being of values not yet committed.
#[frb(ignore)]
#[derive(Clone, Copy)]
struct Publish {
    mode: BridgePlaybackMode,
    cache: bool,
}

pub struct RenderCompRequest {
    pub comp: CompositionReference,
    pub frame: u64,
    /// Which of the two playback behaviours this render is for.
    pub mode: BridgePlaybackMode,
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
        // Deliberately not logged. Superseding is the normal, healthy case —
        // it is how a drag stays attached to the pointer — and a line per
        // completed render is console I/O on the worker thread for something
        // that happens sixty times a second. `cache_stats` is where to look for
        // how the Viewer is actually doing.
        let _ = superseded;

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

    publish_frame(
        state,
        req.comp.id,
        req.frame,
        req.scale,
        &document,
        stream,
        Publish {
            mode: req.mode,
            cache: true,
        },
    );
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

    // Never cached. These pixels are of values the user has not committed, and
    // the key names only (comp, frame, scale) — so filing them would hand the
    // half-way state of a drag back as the document's own frame once the drag
    // ended.
    publish_frame(
        state,
        req.comp.id,
        req.frame,
        req.scale,
        &document,
        stream,
        Publish {
            // A drag is not playback: full resolution, and never kept.
            mode: BridgePlaybackMode::EveryFrame,
            cache: false,
        },
    );
    Ok(())
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
/// Send one rendered frame to the Viewer, by whichever route the mode calls for.
///
/// **The mode picks the transport, and it has to.** The zero-copy paths hand
/// Flutter a texture the engine drew straight into — nothing is copied, which is
/// what makes playback feel immediate — but there are no *bytes* anywhere, so
/// there is nothing a frame cache could hold. The read-back path copies every
/// pixel down and is slower for it, but those bytes are exactly what the cache
/// keeps and what the cache bar then reports.
///
/// So the two playback behaviours are not just two speeds, they are two routes:
///
/// * [`BridgePlaybackMode::Adaptive`] wants to keep time above all, so it takes
///   the zero-copy path when the build has one and lets the tier drop.
/// * [`BridgePlaybackMode::EveryFrame`] exists to *fill the cache*, so it takes
///   the read-back path deliberately, slower and complete.
///
/// A build without a zero-copy path uses read-back for both, which is what every
/// build did until the Flutter build was taught to pass the feature at all.
fn publish_frame(
    state: &mut WorkerState,
    comp: Uuid,
    frame: u64,
    scale: f32,
    document: &lumit_core::Document,
    stream: &mut WorkerResponseStream,
    publish: Publish,
) {
    #[cfg(any(
        all(windows, feature = "shared-texture"),
        all(target_os = "linux", feature = "shared-texture-linux")
    ))]
    if matches!(publish.mode, BridgePlaybackMode::Adaptive) {
        publish_zero_copy(state, comp, frame, scale, document, stream, publish);
        return;
    }
    publish_read_back(state, comp, frame, scale, document, stream, publish);
}

#[cfg(all(target_os = "linux", feature = "shared-texture-linux"))]
fn publish_zero_copy(
    state: &mut WorkerState,
    comp: Uuid,
    frame: u64,
    scale: f32,
    document: &lumit_core::Document,
    stream: &mut WorkerResponseStream,
    publish: Publish,
) {
    // The zero-copy paths hand out a texture rather than bytes, so there is
    // nothing here for a byte cache to hold.
    let _ = publish;
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
fn publish_zero_copy(
    state: &mut WorkerState,
    comp: Uuid,
    frame: u64,
    scale: f32,
    document: &lumit_core::Document,
    stream: &mut WorkerResponseStream,
    publish: Publish,
) {
    let _ = publish;
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

fn publish_read_back(
    state: &mut WorkerState,
    comp: Uuid,
    frame: u64,
    scale: f32,
    document: &lumit_core::Document,
    stream: &mut WorkerResponseStream,
    publish: Publish,
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
    // Adaptive playback renders at the realtime controller's current tier, which
    // is the whole mechanism: the controller lowers the tier while frames cost
    // more than the frame rate allows, and raises it again when they do not.
    //
    // It had never done anything, for two reasons that had to be fixed together.
    // The tier was never *applied* — every render went out at the panel-fit
    // scale — and `observe` only records a cost when the render was issued at
    // exactly the tier's own scale, so every measurement was discarded and the
    // tier never moved off Full. Reporting `tier_scale(tier)` here is what closes
    // that loop.
    let tier = crate::realtime::tier();
    let Publish { mode, cache } = publish;
    let adaptive = matches!(mode, BridgePlaybackMode::Adaptive);
    let effective = if adaptive {
        scale * crate::realtime::tier_scale(tier)
    } else {
        scale
    };

    let started = std::time::Instant::now();
    let mut render = || {
        state
            .renderer
            .render_preview(
                document,
                comp,
                frame,
                quality_for(effective),
                effective,
                None,
            )
            .ok()
            .map(|(rgba, width, height)| (width, height, rgba))
    };
    // Adaptive frames ARE kept, filed under the tier they were actually made at.
    // That is what lets the cache bar show them dimmed — "held, but coarser than
    // you are watching" — which is the state docs/06 §5.6 asks for, and it means
    // a second pass over a stretch you have already played is served rather than
    // re-rendered. The budget's own eviction handles the tiers you stop asking
    // for; there is no need to refuse to keep them.
    let rendered = if !cache {
        render()
    } else {
        crate::framecache::get_or_render(
            crate::framecache::frame_key(comp, frame, effective),
            render,
        )
    };

    let Some((width, height, rgba)) = rendered else {
        eprintln!("Read-back render failed, dropping frame");
        return;
    };

    // Tell the realtime controller what that cost, so playback can drop to a
    // coarser tier when the comp is too heavy to keep up (K-171). Only a genuine
    // render counts: a cache hit measures the cache, not the comp.
    if adaptive && started.elapsed().as_secs_f64() > 0.001 {
        let fps = document
            .comp(comp)
            .map(|c| c.frame_rate.fps())
            .unwrap_or(0.0);
        crate::realtime::observe(
            started.elapsed().as_secs_f64(),
            fps,
            crate::realtime::tier_scale(tier),
        );
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
