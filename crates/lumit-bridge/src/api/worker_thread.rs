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
    /// Playback, when it is running. `None` means the worker is idle and blocks
    /// waiting for something to do.
    playback: Option<Playback>,
}

#[frb(ignore)]
pub enum WorkerRequest {
    RenderComp(RenderCompRequest),
    RenderCompWithPreview(RenderCompRequestWithPreview),
    TraceScope(RenderScopeRequest),
    /// Start playing. The worker paces itself from here until it is stopped or
    /// runs off the end.
    Play(PlayRequest),
    /// Stop playing. Harmless when nothing is playing.
    StopPlayback,
}

/// Start playback of `comp` at `from`.
///
/// **Why the worker plays rather than the frontend driving it.** Playback is a
/// decision made once per frame — which frame is next, is the clock ahead of us,
/// is this mode allowed to skip — and every one of those needs the render cost
/// of the frame just finished. The frontend has none of that. It used to guess:
/// a Flutter `Ticker` polled the audio clock each vsync, worked out a frame, and
/// asked for it, with a hand-rolled in-flight counter to stop the requests
/// piling up. That is a scheduler living on the far side of an FFI boundary from
/// everything it needs to schedule against. The frontend now says "play from
/// here" and paints what arrives (K-181).
#[frb(ignore)]
pub struct PlayRequest {
    pub comp: CompositionReference,
    pub from: u64,
    pub mode: BridgePlaybackMode,
    pub scale: f32,
    pub zero_copy: bool,
}

/// Playback in progress: what is being played, and where it has got to.
///
// ponytail: renders one frame at a time, strictly serial. docs/impl/playback-
// scheduler.md §5 specifies a bounded ring with lookahead adapted from measured
// p95 render cost, and epoch tokens for cancellation, so a frame can be
// rendering while the previous one is still being shown. Upgrade when the
// serial hand-off is measurably the limit — the pipelining the every-frame path
// used to do in Dart bought ~4 fps on 1080p60 footage, which is the number to
// beat.
#[frb(ignore)]
struct Playback {
    comp: CompositionReference,
    /// The frame to render next.
    next: u64,
    /// The last frame of the composition — playback ends after it.
    last: u64,
    mode: BridgePlaybackMode,
    scale: f32,
    zero_copy: bool,
    /// The composition's rate, for turning a clock reading into a frame.
    fps: f64,
    /// Where playback started, and when — the wall clock's baseline for as long
    /// as no mix is loaded to be master instead.
    from: u64,
    started: std::time::Instant,
    /// When the last frame was handed over, for every-frame's pacing. `None`
    /// before the first frame of a run.
    last_published: Option<std::time::Instant>,
}

impl Playback {
    /// Where playback has actually got to, in seconds.
    ///
    /// The audio clock is master once a mix is loaded; until then — while it is
    /// still decoding, or on a machine with no sound device — the wall clock
    /// stands in, so silence never stops the picture.
    fn elapsed_seconds(&self) -> f64 {
        match clock_seconds() {
            Some(seconds) => seconds,
            None => self.started.elapsed().as_secs_f64() + self.from as f64 / self.fps,
        }
    }

    /// How long until the next frame is *due*, or `None` when it is due now.
    ///
    /// **This is what keeps adaptive playback at the composition's rate.** A
    /// comp that renders faster than realtime would otherwise play as fast as
    /// the renderer managed — the frontend's `Ticker` used to supply this pacing
    /// by only asking once per vsync, and moving playback without moving the
    /// pacing with it made a 60 fps comp play at several hundred.
    ///
    /// Every-frame paces differently, and against a different baseline: it is
    /// allowed to fall behind (that is the mode — it never skips, so a comp too
    /// heavy to render in realtime simply plays slow), but it is *not* allowed
    /// to run ahead. Once a span is cached, frames cost almost nothing to
    /// produce and the mode would replay it many times faster than realtime,
    /// which is what "it zooms through the cached parts" was. K-171's "replays
    /// it at full speed from cache" means the composition's own rate, not
    /// whatever rate the cache can be read at.
    ///
    /// So the baseline is the *previous frame*, not the start of playback: keep
    /// at least one frame period between hand-offs, and never try to make up
    /// time that has already been lost.
    fn wait_before_next(&self) -> Option<std::time::Duration> {
        let period = std::time::Duration::from_secs_f64(1.0 / self.fps);
        if matches!(self.mode, BridgePlaybackMode::EveryFrame) {
            let since = self.last_published?.elapsed();
            return period.checked_sub(since).filter(|d| !d.is_zero());
        }
        let due = self.next as f64 / self.fps;
        let elapsed = self.elapsed_seconds();
        (due > elapsed).then(|| std::time::Duration::from_secs_f64(due - elapsed))
    }

    /// The next frame to render, or `None` when playback has run off the end.
    ///
    /// The mode difference, and the policy that used to live in Dart:
    ///
    /// * **Every-frame** never skips — that is the mode's entire promise, since
    ///   the point of it is to render and cache every frame at full quality
    ///   however long that takes (K-171). It simply counts.
    /// * **Adaptive** keeps time, so it asks the clock where playback actually
    ///   is and renders *that* frame, letting frames the clock has already
    ///   passed go by. Being *ahead* of the clock is [`Self::wait_before_next`]'s
    ///   business, not this one's.
    fn advance(&mut self) -> Option<u64> {
        if self.next > self.last {
            return None;
        }
        let frame = match self.mode {
            BridgePlaybackMode::EveryFrame => self.next,
            BridgePlaybackMode::Adaptive => {
                let wanted = (self.elapsed_seconds() * self.fps).floor().max(0.0) as u64;
                // Never go backwards. A clock reading behind the frame just
                // drawn — a resync, or a mix loading part-way through — would
                // otherwise play a short stretch twice.
                wanted.max(self.next)
            }
        };
        if frame > self.last {
            self.next = frame;
            return None;
        }
        self.next = frame + 1;
        Some(frame)
    }
}

/// Where the sound has got to, in seconds, or `None` when there is no mix to
/// follow. The audio module's own clock — read here rather than in Dart so the
/// frame it implies is chosen next to the renderer that has to make it.
#[frb(ignore)]
fn clock_seconds() -> Option<f64> {
    #[cfg(feature = "media")]
    {
        let (seconds, playing, loaded) = crate::audio::clock();
        (loaded && playing).then_some(seconds)
    }
    #[cfg(not(feature = "media"))]
    None
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
    /// Whether the caller can show a shared texture (see `RenderCompRequest`).
    zero_copy: bool,
}

pub struct RenderCompRequest {
    pub comp: CompositionReference,
    pub frame: u64,
    /// Which of the two playback behaviours this render is for.
    pub mode: BridgePlaybackMode,
    /// Whether the caller can actually *show* a shared texture.
    ///
    /// Asked rather than assumed, because the failure is silent and total: if
    /// the frontend cannot register the texture it is handed, it draws nothing
    /// at all, and the engine has no way to find that out. It happened —
    /// switching the zero-copy path on left the Viewer showing its checkerboard
    /// while the playhead ran and the Scopes updated, which reads as the picture
    /// being broken rather than the transport.
    pub zero_copy: bool,
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
        playback: None,
    };

    loop {
        // While playing the worker has work of its own, so it must not block on
        // the channel — it takes whatever has arrived and gets on with the next
        // frame. Idle, it blocks, because an editor sitting still should spin no
        // core at all. (This used to be `try_recv` in a bare loop, which spun one
        // continuously whether or not anything was rendering.)
        let request = if state.playback.is_some() {
            match receiver.try_recv() {
                Ok(request) => Some(request),
                Err(std::sync::mpsc::TryRecvError::Empty) => None,
                Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                    eprintln!("Receiver disconnected, stopping the worker");
                    return;
                }
            }
        } else {
            match receiver.recv() {
                Ok(request) => Some(request),
                Err(_) => {
                    eprintln!("Receiver disconnected, stopping the worker");
                    return;
                }
            }
        };

        if let Some(request) = request {
            handle_requests(request, &receiver, &mut state, &mut stream);
        }

        play_one_frame(&mut state, &mut stream);
    }
}

/// Render the next frame of playback, if playback is running.
///
/// One frame per turn of the loop, so a stop or a seek that arrives mid-playback
/// is seen between frames rather than after the whole run. Rendering is
/// synchronous here on purpose: the next frame's choice depends on how long this
/// one took, which is exactly the coupling that could not exist while the
/// frontend was choosing.
#[frb(ignore)]
fn play_one_frame(state: &mut WorkerState, stream: &mut WorkerResponseStream) {
    let Some(playback) = &mut state.playback else {
        return;
    };

    // Ahead of the clock: wait for this frame to be due rather than racing on.
    // Capped well below a frame so a stop or a seek arriving mid-wait is still
    // acted on promptly — the loop simply comes back round and waits again.
    if let Some(wait) = playback.wait_before_next() {
        std::thread::sleep(wait.min(std::time::Duration::from_millis(4)));
        return;
    }

    let Some(frame) = playback.advance() else {
        state.playback = None;
        _ = stream.add(WorkerResponse::PlaybackEnded);
        return;
    };

    let request = RenderCompRequest {
        comp: playback.comp.clone(),
        frame,
        mode: playback.mode,
        scale: playback.scale,
        zero_copy: playback.zero_copy,
    };
    // Stamped before the render, so the period counts hand-off to hand-off
    // rather than adding the render on top of it — the pacing must not make a
    // slow comp slower still.
    if let Some(playback) = &mut state.playback {
        playback.last_published = Some(std::time::Instant::now());
    }
    if let Err(err) = render_comp(request, state, stream) {
        // A frame that will not render stops playback rather than spinning on it
        // — the alternative is a silent loop burning a core on a comp that
        // cannot be drawn.
        eprintln!("Playback stopped: {err}");
        state.playback = None;
        _ = stream.add(WorkerResponse::PlaybackEnded);
    }
}

/// Begin playing, reading the composition's rate and length once up front.
///
/// Playing from the last frame plays from the start, which is what a transport
/// has to do: pressing play at the end otherwise showed itself playing while
/// nothing moved.
#[frb(ignore)]
fn start_playback(req: PlayRequest, state: &mut WorkerState) -> Result<(), BridgeError> {
    let document = {
        let document = state.project.state()?;
        let document = document.read().map_err(|_| BridgeError::ReadFailed)?;
        document.store.snapshot()
    };
    let comp = document.comp(req.comp.id).ok_or(BridgeError::InvalidComp)?;
    let fps = comp.frame_rate.fps();
    // The same derivation `CompositionReference::duration_frames` uses: the
    // document stores a length in seconds, and the count is that read at the
    // comp's current rate.
    let frames = comp
        .frame_rate
        .frame_at(lumit_core::time::CompTime(comp.duration.0));
    let last = frames.max(1).saturating_sub(1) as u64;

    let from = if req.from >= last { 0 } else { req.from };
    state.playback = Some(Playback {
        comp: req.comp,
        next: from,
        last,
        mode: req.mode,
        scale: req.scale,
        zero_copy: req.zero_copy,
        fps: if fps > 0.0 { fps } else { 60.0 },
        from,
        started: std::time::Instant::now(),
        last_published: None,
    });
    // A fresh run starts optimistic at Full and walks down to whatever this
    // machine can actually hold, rather than inheriting the last run's verdict
    // on a comp that may since have got lighter.
    crate::realtime::reset();
    Ok(())
}

/// Take everything queued, throw away what has been superseded, and serve the
/// rest.
#[frb(ignore)]
fn handle_requests(
    request: WorkerRequest,
    receiver: &Receiver<WorkerRequest>,
    state: &mut WorkerState,
    stream: &mut WorkerResponseStream,
) {
    {
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
        let (pictures, scope, superseded) = drain_to_newest(request, receiver, |r| match r {
            WorkerRequest::TraceScope(_) => DrainClass::Scope,
            // Every-frame requests are the mode's whole promise: each one is
            // rendered and cached, so none may be superseded — and it is what
            // lets the caller keep two in flight to hide its own latency.
            WorkerRequest::RenderComp(req)
                if matches!(req.mode, BridgePlaybackMode::EveryFrame) =>
            {
                DrainClass::PictureKeepAll
            }
            // Transport commands are not pictures and must never be dropped:
            // superseding a Stop would leave playback running with nothing left
            // to stop it.
            WorkerRequest::Play(_) | WorkerRequest::StopPlayback => DrainClass::PictureKeepAll,
            _ => DrainClass::PictureNewestWins,
        });
        // Deliberately not logged. Superseding is the normal, healthy case —
        // it is how a drag stays attached to the pointer — and a line per
        // completed render is console I/O on the worker thread for something
        // that happens sixty times a second. `cache_stats` is where to look for
        // how the Viewer is actually doing.
        let _ = superseded;

        // Pictures first: they are what the user is looking at, and a trace of
        // a frame that is about to be replaced is worth less than the frame.
        //
        // A frame that cannot be rendered is dropped, not fatal: the worker has
        // to survive to serve the next request.
        for request in pictures.into_iter().chain(scope) {
            let outcome = match request {
                WorkerRequest::RenderComp(req) => render_comp(req, state, stream),
                // Named for what it does rather than "render", so the three
                // variants do not all share a prefix that says nothing.
                WorkerRequest::TraceScope(req) => trace_scope(req, state, stream),
                WorkerRequest::RenderCompWithPreview(req) => {
                    render_comp_with_preview(req, state, stream)
                }
                WorkerRequest::Play(req) => start_playback(req, state),
                WorkerRequest::StopPlayback => {
                    state.playback = None;
                    Ok(())
                }
            };
            if let Err(err) = outcome {
                eprintln!("Dropping frame: {err}");
            }
        }
    }
}

/// How the drain treats one queued request.
#[frb(ignore)]
#[derive(Clone, Copy, PartialEq, Eq)]
enum DrainClass {
    /// A stale one is worthless: only the newest survives (a scrub, adaptive
    /// playback — the frame behind the newest will never be looked at).
    PictureNewestWins,
    /// Every one is served, in order (every-frame playback: each frame is
    /// rendered and cached, and the caller may pipeline several).
    PictureKeepAll,
    /// A trace; the newest survives, served after the pictures.
    Scope,
}

/// Take everything queued and keep what its class says to keep.
///
/// Generic over the classifier so the policy can be tested on its own — a
/// `WorkerRequest` needs a live project behind it, and the rule being tested has
/// nothing to do with rendering.
///
/// Returns `(pictures_in_order, scope, superseded_count)`.
#[frb(ignore)]
fn drain_to_newest<T>(
    first: T,
    receiver: &Receiver<T>,
    classify: impl Fn(&T) -> DrainClass,
) -> (Vec<T>, Option<T>, usize) {
    let mut kept: Vec<T> = Vec::new();
    let mut newest_wins: Option<T> = None;
    let mut scope = None;
    let mut superseded = 0usize;
    let mut newest = Some(first);
    while let Some(item) = newest.take() {
        match classify(&item) {
            DrainClass::Scope => {
                if scope.replace(item).is_some() {
                    superseded += 1;
                }
            }
            DrainClass::PictureKeepAll => kept.push(item),
            DrainClass::PictureNewestWins => {
                if newest_wins.replace(item).is_some() {
                    superseded += 1;
                }
            }
        }
        newest = receiver.try_recv().ok();
    }
    // A surviving newest-wins picture runs after the kept ones: the kept ones
    // were asked for earlier, and order is part of every-frame's contract.
    kept.extend(newest_wins);
    (kept, scope, superseded)
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
            zero_copy: req.zero_copy,
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
            zero_copy: false,
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

    // Reuse the picture the Viewer already has, at whatever resolution it was
    // made at. Scopes read the *values* in a frame, so any size answers the
    // question — and compositing the composition a second time to ask it was
    // doubling the cost of every played frame with the panel open.
    let (width, height, rgba) = match crate::framecache::best_frame(req.comp.id, req.frame) {
        Some(held) => held,
        None => {
            // Nothing held for this frame — the zero-copy Viewer keeps no bytes,
            // so on that path the trace still has to make its own. Cached, so a
            // second trace of the same frame is free.
            let key = crate::framecache::frame_key(req.comp.id, req.frame, req.scale);
            let mut render = || {
                state
                    .renderer
                    .render_preview(
                        &document,
                        req.comp.id,
                        req.frame,
                        quality_for(req.scale),
                        req.scale,
                        None,
                    )
                    .ok()
                    .map(|(rgba, width, height)| (width, height, rgba))
            };
            let Some(made) = crate::framecache::get_or_render(key, &mut render) else {
                eprintln!("Scope render failed, dropping the trace");
                return Ok(());
            };
            made
        }
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
    // A build with no zero-copy path compiled in has nothing to ask: whatever
    // the caller can show, read-back is the only route there is.
    #[cfg(not(any(
        all(windows, feature = "shared-texture"),
        all(target_os = "linux", feature = "shared-texture-linux")
    )))]
    let _ = publish.zero_copy;

    #[cfg(any(
        all(windows, feature = "shared-texture"),
        all(target_os = "linux", feature = "shared-texture-linux")
    ))]
    if publish.zero_copy && matches!(publish.mode, BridgePlaybackMode::Adaptive) {
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
    let shared =
        match state
            .renderer
            .render_to_shared_dmabuf(document, comp, frame, quality_for(scale))
        {
            Ok(shared) => shared,
            Err(err) => {
                // Fall back rather than drop — see the Windows sibling.
                eprintln!("Shared DMA-BUF render failed, falling back to read-back: {err}");
                publish_read_back(state, comp, frame, scale, document, stream, publish);
                return;
            }
        };

    _ = stream.add(WorkerResponse::RenderedDMABuf(BridgeSharedFrameInfoLinux {
        fd: shared.fd,
        frame,
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
    let shared = match state
        .renderer
        .render_to_shared(document, comp, frame, quality_for(scale))
    {
        Ok(shared) => shared,
        Err(err) => {
            // Fall back rather than drop. A dropped frame here is not a slower
            // Viewer, it is an *empty* one: nothing else publishes a picture, so
            // the panel stays on its checkerboard for the whole session while
            // everything else — the playhead, the Scopes — carries on as though
            // playback were fine. A frame by the slow road beats no frame.
            eprintln!("Shared-texture render failed, falling back to read-back: {err}");
            publish_read_back(state, comp, frame, scale, document, stream, publish);
            return;
        }
    };

    _ = stream.add(WorkerResponse::RenderedSharedTexture(
        BridgeSharedFrameInfo {
            handle: shared.handle,
            frame,
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
    let Publish { mode, cache, .. } = publish;
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

    _ = stream.add(WorkerResponse::RenderedPixels(BridgeRenderedFrame {
        frame,
        width,
        height,
        rgba,
    }));

    // Tell the realtime controller what that frame cost, so playback can drop to
    // a coarser tier when the machine cannot keep up (K-171).
    //
    // **Measured after the hand-off, and that is the whole point.** This used to
    // stop the clock before `stream.add` and report the render alone, which on
    // this transport is the smaller half of the bill: encoding the pixels for
    // Dart costs about 6 ms per 1.4 MB — twice the render — and grows with the
    // panel, so a full-size 1080p Viewer spends over 30 ms handing the frame
    // over. The controller therefore saw 3 ms against a 15 ms threshold,
    // concluded it had headroom, and sat at Full for ever while playback missed
    // its budget and skipped frames instead of getting softer. A tier it cannot
    // see the cost of is a tier it can never choose.
    //
    // A cache hit is measured too, for the same reason: the pixels still have to
    // cross, and that crossing is what is actually slow.
    //
    // Only while *playing*, though. The tier answers "can this machine hold the
    // composition's rate", which is a question a still frame cannot help with: a
    // scrub, an edit redraw, or the first render of a session — which pays for
    // renderer warm-up — would drag the tier down over a cost nothing was
    // keeping time against, and the next playback would start soft for no
    // reason.
    if adaptive && state.playback.is_some() {
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
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::{drain_to_newest, DrainClass, Playback};
    use crate::api::composition::{BridgePlaybackMode, CompositionReference};
    use std::sync::mpsc::channel;
    use uuid::Uuid;

    fn playback(mode: BridgePlaybackMode, last: u64) -> Playback {
        Playback {
            comp: CompositionReference::new(Uuid::nil(), Uuid::nil()),
            next: 0,
            last,
            mode,
            scale: 1.0,
            zero_copy: false,
            fps: 60.0,
            from: 0,
            started: std::time::Instant::now(),
            last_published: None,
        }
    }

    /// **The pacing regression.** Playback moved from a Flutter `Ticker` to the
    /// worker, and the Ticker had been supplying the pacing for free by only
    /// asking once per vsync. Without [`Playback::wait_before_next`] the loop
    /// renders as fast as the renderer manages, so a comp cheaper than realtime
    /// plays at several times its own rate. Fails without the wait.
    #[test]
    fn adaptive_playback_waits_for_each_frame_to_be_due() {
        let mut p = playback(BridgePlaybackMode::Adaptive, 100);

        // Frame 0 is due the instant playback starts.
        assert!(p.wait_before_next().is_none(), "the first frame is due now");
        assert_eq!(p.advance(), Some(0));

        // Frame 1 is not: at 60 fps it is due a sixtieth of a second in, and
        // essentially none of that has passed.
        let wait = p
            .wait_before_next()
            .expect("frame 1 is not due yet, so playback must wait for it");
        assert!(
            wait.as_secs_f64() > 0.010 && wait.as_secs_f64() <= 1.0 / 60.0,
            "waits out most of a frame, not more than one: {wait:?}"
        );
    }

    /// Every-frame never skips, whatever it costs — that is the mode's whole
    /// definition (K-171), and it is why it plays silent.
    #[test]
    fn every_frame_playback_never_skips() {
        let mut p = playback(BridgePlaybackMode::EveryFrame, 3);
        for expected in 0..=3 {
            assert_eq!(p.advance(), Some(expected), "never skips one");
        }
        assert_eq!(p.advance(), None, "past the last frame, playback is over");
    }

    /// **The cached-playback regression.** Every-frame is allowed to fall behind
    /// — a comp too heavy to render in realtime plays slow rather than dropping
    /// frames — but it must never run *ahead*. Once a span is cached, frames
    /// cost almost nothing and it replayed them many times faster than realtime:
    /// "it zooms through those parts". Fails without the per-frame pacing.
    #[test]
    fn every_frame_playback_never_runs_faster_than_realtime() {
        let mut p = playback(BridgePlaybackMode::EveryFrame, 100);

        // The first frame of a run is due immediately — nothing has been shown
        // yet, so there is nothing to be early against.
        assert!(p.wait_before_next().is_none());

        // A frame that has just been handed over: the next one is a sixtieth of
        // a second away, and a cache hit must not be allowed to jump the queue.
        p.last_published = Some(std::time::Instant::now());
        let wait = p
            .wait_before_next()
            .expect("a frame delivered just now means the next one is not due");
        // The upper bound carries a nanosecond of slack: `Duration` rounds
        // 1/60 s up at nanosecond precision, so an exact `<=` fails on the
        // untouched period.
        assert!(
            wait.as_secs_f64() > 0.010 && wait.as_secs_f64() <= 1.0 / 60.0 + 1e-6,
            "waits out the rest of the frame period, no more: {wait:?}"
        );

        // A frame that took longer than its period to produce is already late.
        // Late is allowed; making it later is not.
        p.last_published = Some(std::time::Instant::now() - std::time::Duration::from_millis(50));
        assert!(
            p.wait_before_next().is_none(),
            "already behind, so no further wait — it never tries to catch up \
             and never adds to the delay"
        );
    }

    /// Adaptive skips frames the clock has already gone past, rather than
    /// falling further behind. Driven by moving the start time into the past,
    /// which is what a slow render does to the wall clock.
    #[test]
    fn adaptive_playback_skips_frames_the_clock_has_passed() {
        let mut p = playback(BridgePlaybackMode::Adaptive, 100);
        p.started = std::time::Instant::now() - std::time::Duration::from_millis(500);

        assert!(p.wait_before_next().is_none(), "half a second overdue");
        let frame = p.advance().expect("still inside the composition");
        assert!(
            frame >= 29,
            "half a second at 60 fps is about frame 30, not frame 0: got {frame}"
        );
    }

    /// The requests these tests queue: an adaptive picture (newest wins), an
    /// every-frame picture (all kept, in order), and a scope trace. Standing in
    /// for `WorkerRequest`, which needs a live project.
    #[derive(Debug, PartialEq, Eq, Clone, Copy)]
    enum Req {
        Adaptive(u32),
        EveryFrame(u32),
        Scope(u32),
    }

    fn classify(r: &Req) -> DrainClass {
        match r {
            Req::Adaptive(_) => DrainClass::PictureNewestWins,
            Req::EveryFrame(_) => DrainClass::PictureKeepAll,
            Req::Scope(_) => DrainClass::Scope,
        }
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
            tx.send(Req::Adaptive(frame)).unwrap();
        }
        // The trace arrives last, which is what used to win outright.
        tx.send(Req::Scope(9)).unwrap();
        drop(tx);

        let (pictures, scope, superseded) = drain_to_newest(Req::Adaptive(0), &rx, classify);
        assert_eq!(
            pictures,
            vec![Req::Adaptive(3)],
            "the newest frame survives a trace queued behind it"
        );
        assert_eq!(scope, Some(Req::Scope(9)), "and the trace is served too");
        assert_eq!(superseded, 3, "the three older frames were dropped");
    }

    /// The behaviour the policy is *for*: a backlog of adaptive pictures
    /// collapses to the newest, because the ones behind it are frames nobody
    /// will ever see.
    #[test]
    fn pictures_still_collapse_to_the_newest() {
        let (tx, rx) = channel();
        for frame in 1..=5 {
            tx.send(Req::Adaptive(frame)).unwrap();
        }
        drop(tx);

        let (pictures, scope, superseded) = drain_to_newest(Req::Adaptive(0), &rx, classify);
        assert_eq!(pictures, vec![Req::Adaptive(5)]);
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

        let (pictures, scope, superseded) = drain_to_newest(Req::Scope(1), &rx, classify);
        assert!(pictures.is_empty());
        assert_eq!(scope, Some(Req::Scope(3)));
        assert_eq!(superseded, 2);
    }

    /// A single request with nothing behind it is served as it is.
    #[test]
    fn a_lone_request_is_not_counted_as_superseded() {
        let (tx, rx) = channel::<Req>();
        drop(tx);

        let (pictures, scope, superseded) = drain_to_newest(Req::Adaptive(7), &rx, classify);
        assert_eq!(pictures, vec![Req::Adaptive(7)]);
        assert_eq!(scope, None);
        assert_eq!(superseded, 0);
    }

    /// Every-frame's contract: nothing dropped, order preserved — it is what
    /// makes keeping two requests in flight safe, and what makes the mode's
    /// "every frame rendered and cached" true under a backlog.
    #[test]
    fn every_frame_requests_all_survive_in_order() {
        let (tx, rx) = channel();
        for frame in 2..=4 {
            tx.send(Req::EveryFrame(frame)).unwrap();
        }
        // An adaptive scrub and a trace land in the middle of the backlog.
        tx.send(Req::Adaptive(9)).unwrap();
        tx.send(Req::Scope(1)).unwrap();
        drop(tx);

        let (pictures, scope, superseded) = drain_to_newest(Req::EveryFrame(1), &rx, classify);
        assert_eq!(
            pictures,
            vec![
                Req::EveryFrame(1),
                Req::EveryFrame(2),
                Req::EveryFrame(3),
                Req::EveryFrame(4),
                Req::Adaptive(9),
            ],
            "every-frame requests all survive, in order, before the adaptive one"
        );
        assert_eq!(scope, Some(Req::Scope(1)));
        assert_eq!(superseded, 0, "nothing every-frame was thrown away");
    }
}
