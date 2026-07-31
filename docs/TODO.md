# TODO - the work backlog

**Status: living.** This is the single source of truth for work that is planned
but not done. It replaces the burn-down that used to be spread across the
`flutter-port` parity checklist and remaining-work ledger (now archived under
[archive/flutter-port/](archive/flutter-port/)) and the per-gate wishlists in
[16-ROADMAP.md](16-ROADMAP.md).

**How to use it.** Keep entries to one line plus a source pointer. Move an item
up the sections as it becomes actionable; delete it when it lands (its regression
test is the permanent record, per [14-ENGINEERING-RULES.md](14-ENGINEERING-RULES.md)).
The roadmap ([16-ROADMAP.md](16-ROADMAP.md)) stays the aspirational phase plan;
this file is the concrete backlog underneath it.

---

## Now - the preview must keep up

These sit above everything else: they are what the editor feels like in the hand.

- **The disk tier is written but dark.** `crates/lumit-cache/src/disk.rs` and
    `crates/lumit-render/src/diskio.rs` are complete — open, park, load back,
    budget, the cache bar's blue tier, and a cache-root override honouring
    "Settings → Performance → Cache" ([07-UI-SPEC.md](07-UI-SPEC.md) §15). Nothing
    outside `diskio.rs` ever constructs it: `grep -rn 'diskio::' crates/` returns
    nothing, so the third tier of the three-tier cache never runs and the Settings
    control it was written for does not exist. Wanted: the worker spawns it, the
    Settings window gets its budget row and root-folder picker back beside the RAM
    and VRAM rows, and the cache bar shows the blue tier. Land the **disk bar** with
    it: the status line's cache meter gains a third bar beside the RAM and VRAM ones
    it grew on 2026-07-29.
    **The demotion ladder is also unbuilt.** docs/06 §5 wants a frame evicted from
    VRAM to fall to RAM, and one evicted from RAM to fall to disk; today an eviction
    simply drops the frame. VRAM→RAM needs a read-back at eviction time and — to be
    worth anything — a way back up, since nothing can currently turn held bytes into
    a texture the Viewer shows, so a demoted frame would be re-rendered anyway. That
    upload path is the same piece the disk tier needs, so the two want doing together:
    read-back on evict, upload on hit, then disk underneath both.
    **Blocked, and on what.** The tier cannot be wired honestly while frames are
    filed by *position*. A disk tier exists to outlive an edit and a restart, and a
    positional name does not identify pixels: the RAM and VRAM tiers are emptied on
    every commit precisely because of that, and a disk copy that survived one would
    serve the picture from before the edit — or, after reopening a project, from
    another day's document. So **content keying comes first** (the entry under *Next*:
    file frames under a content hash). The pieces for it are closer than that entry
    says: `lumit_render::cache::frame_key` already computes the hash, and the
    renderer holds the probe cache it needs (`ProbeView`), so a hash is computable on
    the worker thread without any new bridge view — what needs designing is how the
    cache bar names a frame from its position once the keys are hashes (the worker
    can publish held *positions* alongside the hashes, which is what the VRAM mirror
    already does). Two further pieces the disk tier needs on top: a way back INTO the
    VRAM tier from bytes (nothing uploads a frame to a texture today), and a decision
    about when to pay the read-back that parking a frame costs at all — the zero-copy
    path (K-183) keeps no bytes, so the idle fill is the honest place to spend it.
- **Multi-frame rendering is built; the worker pool is what is left.** Renders run
    ahead of the clock into a bounded ring sized by measured p95 cost, presents pace
    against the clock, decode runs on its own thread, and the sound waits out a
    pre-roll so a press of play no longer begins with a jump. What remains is under
    *Next* ("Playback scheduler — what remains"): composites are still serial on the
    one worker thread, so cancellation latency is one frame's render rather than the
    impl note's 15 ms, and §6's real-window benches (A/V drift, the underrun ladder)
    have not been run.

---

## Now - Flutter frontend parity and regressions

The frontend moved from egui to Flutter (K-174). Flutter is the only frontend:
the egui crates (`lumit-ui`, `lumit-app`) are deleted (K-182) and git history is
the parity reference. These are v1-scope surfaces the Flutter frontend does not
yet match, from the 2026-07-24 doc/code parity pass.

**Playback measurements (2026-07-27, real window, `integration_test/playback_bench_test.dart`):**
every-frame mode with one 1080p60 H.264 layer measured 58.7 fps on the serial
loop just before the ring scheduler landed (earlier the same day: ~64 with the
Dart two-in-flight pipeline, ~56 before it). Re-run to price the ring. The bench
needs `C:/tmp/test1080p60.mp4` (ffmpeg `testsrc2`) and a Windows device, so it
is run by hand, not in CI.

**Audio ([07-UI-SPEC.md](07-UI-SPEC.md) §10, [09-AUDIO.md](09-AUDIO.md)):**
- **Sequence-clip waveforms** - the footage-layer waveform lane landed
2026-07-28 (K-172's twirl under the Audio group, source peaks mapped through
the live in/out/offset); Sequence layers' clips still draw none.

**Viewer bar ([07-UI-SPEC.md](07-UI-SPEC.md) §2.2):** magnification, channel view,
the transparency grid and wheel zoom about the cursor have landed. Still missing:
- wireframe/overlay menu
- guides menu
- region-of-interest
- colour-management indicator
- background-colour swatch.
- **Click-to-edit timecode** (currently read-only), may want to remove from this bar and
    only keep the one on timeline and add the functionality there.

**Toolbar tools ([07-UI-SPEC.md](07-UI-SPEC.md) §1.7, K-214):** the strip, its groups,
flyouts, shortcuts and the two switches at its right-hand end landed 2026-07-31. What is
armed is a *tool*; what each tool then does is the backlog:
- **Selection** - a drag on the picture pans it; picking a layer by clicking it, and
    marquee-selecting several, is not built (the transform gizmo already drags a
    selected layer, docs/07 §2.3).
- **Zoom** - click to zoom in about the pointer, `Alt` to zoom out. The wheel already
    does this; the tool does not.
- **Rotation**, **Anchor point** - the gizmo drags a layer and its origin already; neither
    is reachable through its tool.
- **Razor** - `Ctrl+Shift+D` and Composition ▸ Cut clip at playhead exist; clicking a clip
    with the tool to cut it there does not.
- **Shape tools** - a rubber-band drag committing mask geometry (the egui build had
    rectangle/ellipse/star; the rounded rectangle and polygon are new).
- **Pen tools** - click-to-place mask drawing, and the four vertex/feather variants.
- **Type**, **Paint** (brush/clone stamp/eraser), **Roto** (roto brush/refine edge),
    **Puppet**, **Camera** - no engine side yet; these are roadmap features
    ([16-ROADMAP.md](16-ROADMAP.md)) that now have a place to appear in.
- **Snapping** is a switch nothing reads (docs/07 §4.5 specifies the behaviour).
- **The workspace strip shows no preset after a restart** - `Workspace.activePreset` is
    session-only, because the stored layout is the user's own by then and may no longer
    match any preset.

**Pixel pickers ([07-UI-SPEC.md](07-UI-SPEC.md) §6.1):**
- **The x/y position pick is not built.** The colour pick and the depth-of-field focal
    point both land with K-210; a *coordinate* pick — one dropper writing an x/y Float
    pair, the egui build's T14 viewfinder — does not, because no Flutter row pairs x and
    y into one control yet. The magnifier already carries the mode.
- **The on-Viewer crosshair handle for point parameters** (docs/07 §6) is still absent:
    a point parameter can be picked but not dragged on the picture.

**Bridge ([17-BRIDGE-CONTRACT.md](17-BRIDGE-CONTRACT.md)):**

- **A panic throws rather than reporting.** frb's handler contains every panic
    (`catch_unwind`, twice), but it surfaces as a thrown Dart exception rather
    than a calm reply — so no Dart call site may treat a throw as impossible.
    The `no-panics-in-frb-api` grep stays as prevention; a panic is still a bug.
- **clippy is blind to the frb surface.** `#[frb(...)]` is a proc-macro
    attribute and clippy's restriction lints skip macro-expanded code, so
    `unwrap_used`/`panic`/`todo` do not fire on any annotated function.
    Covered by that same grep; the real fix is to stop needing it.
- **`ProjectReference::state()` hands the raw `Arc<RwLock<…>>` out**, so a
    caller can hold a project lock for as long as it likes and in any order.
    The lock order is written down and tested beside `PROJECTS`; nothing
    *enforces* it at the type level.
- **`DocumentStore::set_callback` takes `&mut self`**, so the observer can
    only be attached before the store is shared.
- **The macOS podspec now has a CI gate but no runtime check.** Its name matches
    the plugin's pubspec (`lumit_bridge`), and the `flutter-macos` job in
    [.github/workflows/ci.yml](../.github/workflows/ci.yml) builds `macos/Runner`
    so a rename or a missing framework fails there. What is still untested is
    everything past the link: nobody has launched the .app, so the K-195 IOSurface
    Viewer path on macOS is unproven (K-033).
- **The macOS .app is not relocatable.** The podspec links keg-only FFmpeg by
    absolute Homebrew path, so the bundle runs only where that keg is installed.
    Distribution needs the dylibs vendored in and their install names rewritten;
    this belongs to the K-033 notarisation pass, and the podspec says so.
- **The macOS build is single-architecture.** A release build wants to go
    universal, but `pkg-config-rs` refuses to cross-compile and a Homebrew keg
    holds one architecture, so the x86_64 slice cannot link against an arm64
    keg's FFmpeg. The `flutter-macos` job therefore pins `ARCHS` to the runner's
    own architecture. A universal bundle needs both `ffmpeg@7` kegs installed and
    the podspec's `-L` flags selected per slice — part of the K-033 distribution
    pass, along with whether Intel macs are a supported target at all.
- **The iOS podspec is still misnamed** —
    [ios/rust_lib_lumit_flutter.podspec:6](../flutter_ui/rust_builder/ios/rust_lib_lumit_flutter.podspec)
    declares `s.name = 'rust_lib_lumit_flutter'` while the plugin's pubspec name
    is `lumit_bridge`. Same fix the macOS side took; iOS has no target and no CI
    job yet.

- **The frame cache keys by position, not by content (K-178's design).** Each
    entry is filed under `(comp, frame, scale)`, so an edit does not change any
    frame's name and the cache must be told to drop the composition's frames on
    every committed change — which it now is. The cost is that a change which
    cannot alter a pixel (a rename, a work-area nudge, a solo toggle) still
    retires every held frame of that comp, and the cache bar goes blank with it.
    The fix is the documented one: file frames under
    `lumit_render::cache::frame_key`, a hash of what is actually in them. That
    needs a `SourceProbes` view on the bridge side, which is why it was not done
    here. Note the cache bar's per-frame query (`cached_frames`) depends on being
    able to name a frame from its position — under content keying it would
    compute the same hash per frame instead, which works but needs the probes too.
- **The frame key never hashes a layer's parent chain, and skips hidden layers.**
    `comp_frame_key` (crates/lumit-eval/src/lib.rs) `continue`s past any layer with
    `visible == false`, and no layer's key includes the transforms it inherits — so
    hiding a *parent* and then moving it changes the picture (its children still
    follow it) while the key stays put, and the children keep serving stale cached
    frames. This pre-dates the Null layer for any hidden parent, but K-206 makes it
    the common case: a Null is the layer a user will most naturally hide, having
    nothing to look at. Fix is either to hash the parent chain into each child's
    contribution, or to stop gating hidden layers out when something is parented
    to them.
- **The disk frame cache is built but never constructed** — see "The disk tier
    is written but dark" under *Now*, which carries the detail. The VRAM tier
    landed 2026-07-27 (K-187), the RAM tier exists, and the design language's
    steel blue for "on disk only" ([15-DESIGN.md](15-DESIGN.md) §6.3) waits on
    the same wiring.
- **The shared-texture chain has no keyed mutex** (a torn frame is possible in
    principle — see the fence entry under Threading), and the D3D12 → D3D11
    legacy-handle hop the Windows path rides is knowledge docs/06 does not yet
    describe.
- **The Scopes' trace still crosses the bridge as pixels**, serialised a byte at
    a time like any other `Vec<u8>`, and is decoded into an image Dart-side. Small
    next to a full frame, but it is on the same per-frame path and could take the
    shared-texture route the Viewer now takes. The trace is also a fixed 256×256
    whatever the panel size, so a large Scopes panel shows it visibly soft; the
    graticule is drawn over it in Dart and stays crisp, but the trace itself
    wants a size that follows the panel.
- **The matte render-alone pass stays at full comp resolution whatever the
    preview scale** (K-186 records the split): correctness-safe because the
    fragment samples mattes by normalised comp UV, but it is the one composite
    the scale does not shrink — scale it too if it ever shows in a profile.
- **The Linux DMA-BUF path has never run on a Linux machine with a GPU** (K-033) — it is
    compiled and default-on. It has now run on the CI Linux runner, which has no adapter:
    lavapipe refuses the exportable allocation, every frame is dropped at the publish step
    and the engine says so without crashing. That proves the failure is calm; it proves
    nothing about the path working. See the CI-coverage entry under Next.
- **frb's SSE codec encodes `Vec<u8>` one byte at a time** (measured 8.8 ms per
    1080p payload). Frames no longer cross as bytes, so this now only taxes the
    thumbnails and the 256×256 scope traces — small, but the per-byte loop is
    still worth replacing with the bulk codec if traces ever feel late.

- **Engine subsystems with no frb API yet.** Masks (`add_mask`,
    `add_mask_geometry`); the Retime **graph** — the segment
    model (`segment_to_rate`, `set_segment_preset`, `drag_boundary`) and the
    curve view that makes ramps editable; and `trim_to_source_end`.

- **Audio is in, with one honest limit.** Playback, the transport, beat
    detection and the Timeline waveform lane all work. What is *not* here: the
    mix is rebuilt from scratch whenever the comp's audio signature changes
    rather than patched.

- **Panel work left.** The graph editor's Retime time lens (the speed lens and
    draggable bezier handles landed with K-196); and the Viewer's scale and
    rotate gizmo handles, motion paths, masks and shape tools.

**Retime is a property row now, and the segment card is the leftover (K-197).** A layer
carries `retime: Option<Property>` — source time in seconds, keyframable like any other
property, given with Ctrl+Alt+T and drawn above Transform in the fold-out. Deliberately
bare: no lenses, no ease presets, no freeze, no interpolation policy. What is left over is
the **old segment path**, still in the model (`LayerKind::Footage::retime`), still evaluated
as the fallback in `Layer::source_time_at`, and still edited by the Source card's
speed/reverse/frames rows. Decide its fate before building anything else on Retime: either
the new property grows what is worth keeping and the segment store is deleted, or the two are
reconciled. Two ways to retime one layer is the state to leave, not to extend.

**System memory is only read on Windows (K-194).** `system_memory_bytes` and
`video_memory_bytes` answer 0 elsewhere and the settings fall back to a 16 GB ceiling.
macOS/Linux want `sysctl hw.memsize` and `/proc/meminfo` when those targets land (K-033).

**Settings pages not rebuilt in Flutter (K-193).** The window is paged again — General,
Appearance, Interface, Performance — but the egui build's **Export** page (default preset,
filename template) and **Autosave** group (interval, copies kept) have nothing behind them
on this frontend, so they are not listed rather than shown dead. Build the settings first,
then the page. Same for colour management, CUDA and the plugins page (listed under
*Settings pages not built* below). The **Keymap** page landed with K-199.

**Bound keys with nothing behind them (K-199).** The keymap ships the whole docs/07 §15
table, and this frontend dispatches the Global and Timeline/Graph parts of it. The
**Tools**, **Project**, **Panels** and **Effects** contexts have real bindings and no
commands — no tool palette, no panel-focus cycling, no panel search focus — so those rows
are honest about the keymap and silent in use. They are listed in Settings → Keymap rather
than hidden, because a shortcuts page that quietly omits bindings is worse than one that
shows a key you have not built yet. Either build the commands or drop the bindings; do not
leave the two disagreeing for long.

**Appearance, after K-202.** Custom themes are per-machine: they live in the workspace file
and there is no import/export *of a theme* (the keymap has one; a theme does not yet), so
sending one to somebody means sending them the JSON block by hand. The editor also has no
preview swatch strip and no duplicate-a-theme button — the way to make a variant is to
select the theme, change it, and Save, which updates rather than forks it. And the seven
built-in schemes still restate every colour individually; only the two Timeline tokens
default from the mode.

**Shell and onboarding:**
- **The boot splash is not in the frb shell.** The bottom status line landed
  2026-07-28 (saved/unsaved state, the cache meter, a notices area with a close
  button, and export progress with Cancel, under the dock); what remains is the
  boot splash. Notices are frontend-held (`LumitState.notice`) — the engine
  still has no notice stream of its own, only `boot_log`, so engine-side events
  cannot yet post one.
- **Pop-out panel windows are removed** (K-182): the ported-but-never-wired
  subsystem (`lib/popout/`, the `desktop_multi_window` plugin, the dock's
  pop-out chrome) shipped ~500 unreachable lines. Rebuild from git history
  (`flutter-frontend-alternative`, pre-K-182) when pop-out is actually wanted,
  and land it wired end to end.
- **Workspace machinery beyond the presets** - the four shipped presets landed
2026-07-28 (Window menu; the Audio preset stands in with a taller Timeline
until the Audio panel exists). Still unbuilt from §1.6: user workspaces
(save-as/rename/export), the chrome switcher strip, and Alt+Shift+1-9.
- **First-run setup screen** (Vegas/AE preference primer, K-006) - absent, and
GATED: spec marks it post-v1 polish and its cards set preferences that do not
exist yet (Retime graph-lens default, keymap presets, mapping tips) — build
those first or the screen writes settings nothing reads (K-181/K-182).
- **Command palette** - the Effects/Comps/Panels categories, recent-first
ranking and taught shortcuts landed 2026-07-28; recents are session-lived, and
only genuinely bound shortcuts are taught (today just undo/redo — grows with
the keymap).

**Timeline Panel**
- **Graph editor / Lane Editor / keyframes ([04-RETIMING.md](04-RETIMING.md), archive/flutter-port/06 §C):**
    - All Retime specific's are to be implemented later, currently it should behave and have exact parity
        as all other properties in graph view, same value/speed graph etc. Nothing extra
- **The Flow column is reserved, not wired (K-188).** Per-layer optical flow has no engine
    backing (no switch, no settings group); the outline's flow cell shows collapse on a
    Precomp and nothing elsewhere. Build the engine model first, then the fold-out's Flow
    group with its settings.
- **Lock guards the gestures, not the property rows (K-188).** A locked layer's bar,
    razor, rename, reorder and delete all refuse; its transform/effect/volume rows are
    still editable. Either guard the rows or enforce in the engine ops — decide which
    before wiring.
- **The Timeline's two halves are built twice, and kept in step by hand.** The
    outline (`_Outline`, layer names and columns) and the lane area (`_LayerArea`,
    bars and keyframes) are separate widget trees that each walk the same layer
    list, each consume the same `layerBlockHeights` list, and are aligned only
    because both happen to read the same numbers. Vertical scroll is two
    controllers mirrored through `_followScroll` behind a reentrancy flag. Flutter
    gives all of that for nothing if a layer is built **once** as a row holding
    both halves inside one vertical scrollable (the lane side keeping its own
    horizontal controller) — one pass, one scroll position, alignment by
    construction. The current shape keeps producing the same class of bug (K-208's
    layer drag moving only one half; the test that exists purely to check an open
    layer's bars still line up with its names) and is most of why the file is 4400
    lines. A session's refactor, no behaviour change intended, with the alignment
    tests as the safety net — and it deletes `blockHeights`, both scroll
    controllers' sync and the guard flag rather than adding anything.
- **The lane keyframe selection selects and eases, nothing more (K-189, K-196).** The
    marquee gathers diamonds, a click selects one and a diamond drags in time (K-190),
    and the F9 family and the bottom bar's easing buttons act on the catch — but moving
    or deleting a *whole lane selection* is still not built (the graph view has both). Nor are
    `=`/`-`/`\` or edge-follow during playback (the wheel bindings landed with K-190).
- **Column widths and the property selection are session-lived (K-192).** Both reset when
    the panel is rebuilt from scratch; fold them into the workspace when per-workspace
    column layouts land (docs/07 §4.2's reorder/hide-per-workspace item).
- **The Flutter suite has ~4 order-dependent tests.** `flutter test` occasionally fails a
    different one or two of the playback/cache-bar tests each run; every one of them passes
    alone, and the whole suite passes with `--concurrency=1` — which is what CI now runs,
    so the gate is honest while the cause stands. They contend for the shared engine (the
    audio device and the render worker) across test *files*, which run in parallel
    processes. Give those files a serial marker, or make the engine per-file, before this
    masks a real failure; the serial run is a mitigation, not the fix, and it costs the
    Flutter job wall-clock.
- **The magnet snaps keyframes to frames, and nothing else yet (K-190).** Docs/07 §4.5
    wants edit points, in/out points, markers, beat markers, the playhead and work-area
    edges as snap sources and targets, plus `Ctrl`-hold to suspend mid-drag.
- **Volume keyframes draw no lane diamonds and no graph curve.** Volume is not in the
    comp read model (K-184's deliberate exceptions), so its fold row shows controls but
    no diamonds, and selecting it puts nothing in the graph editor (`graphChannels`
    skips it); fold `volume` into `BridgeLayerInfo` if either matters.
- **A Null layer cannot be selected in the Viewer (K-206).** After Effects draws a null
    as a clickable 100×100 box; a Lumit Null has no size and no pixels, so there is
    nothing to hit-test and it can only be moved from its Timeline property rows.
    Acceptable for v1 and deliberately recorded — a drawn, selectable Viewer handle for
    transform-only layers is the fix, and it would serve Camera layers too.
- **Effects on a Null layer are accepted and never run (K-206).** `add_effect` works on a
    Null, the effects appear in Effect Controls, and nothing ever evaluates them because
    there are no pixels. Harmless in the same way as a Camera's, but undecided: either
    refuse the drop, or say plainly in the interface that the stack is inert.

## Next - engine/bridge follow-ups

**Anti-aliasing in the renderer.** Edges of transformed layers, shape strokes and
text can visibly stair-step, most noticeably on a slow rotation where the jaggies
crawl. The renderer has no anti-aliasing option at all today. Two questions to
settle before writing any of it, because they decide where the setting lives:
whether the sample count is a **project** property (it changes what a comp looks
like, so it belongs in the file and must match on another machine and in export)
or a **preference** (it trades quality for speed on *this* machine, like the cache
budgets), and whether preview and export share one value or preview is allowed to
run cheaper. The likely answer is both: a project-level quality that export always
honours, and a preview override in settings — the same shape as the existing
adaptive/every-frame playback pair. Sample counts must be checked against the
adapter rather than assumed (`wgpu` reports supported counts per format).

**The stale-fd race on a Linux Viewer resize** (`crates/lumit-render/src/headless.rs`
around the `shared_dmabuf = Some(...)` re-create, with
`crates/lumit-gpu/src/shared_linux.rs`'s `Drop`). The exported DMA-BUF descriptor
is owned by `SharedDmabuf` and closed when it drops, but the descriptor *number*
travels to Dart asynchronously inside `WorkerResponse::RenderedDMABuf`. A resize
replaces the `SharedDmabuf` immediately, closing the old fd, so two resizes in
quick succession can have Dart register a descriptor that is already closed — or,
worse, one the operating system has since handed to something else. Two candidate
fixes: hold the previous `SharedDmabuf` for one generation so its fd outlives the
message, or `dup()` on the Rust side at export so the number in flight is its own
owned descriptor. Not urgent today only because the Linux runner now checks its
`dup()` and reports a register failure instead of dying quietly (a bad fd fails
loudly rather than showing a black Viewer for the session).

**Retime UI wiring** (the engine is fully built; these are UI/command affordances -
[04-RETIMING.md](04-RETIMING.md)):
- Freeze-at-playhead (`insert_freeze' built, no caller); Hold preset button;
    RATE/MAP type chips; kink badge; graph overrun band + source-out reference line;
    compensating Alt-drag; copy/paste a retime between clips; outward-trim-extends-map;
    the retime keyboard shortcuts (§12); Blend interpolation UI toggle; Flow-params UI
    and the source-rate advisory badge.
- Precomp retiming - Precomp layers carry no Retime today (only Footage does);
    decide the intended scope before building.
- Retime Time-lens **vertical (source-position) boundary drag** has no bridge op
    (`SetLayerRetime`/`from_source_keyframes` unexposed).

**Bridge reads left outside the read model (K-184)** — deliberate and small:
the Source card's text/camera fields for the one selected layer, the Viewer's
missing-file probe, and the marker/work-area reads on a Timeline rebuild. Fold
any of these into `BridgeLayerInfo`/`BridgeCompModel` if they ever show up in
the budget ranking (`bridge_call_budget_test.dart` prints it).
- **`LumitAppNew` rebuilds the whole app on any `LumitUiState.notifyListeners`**
    (a `ListenableBuilder` above everything), and un-scoped document changes do
    the same via `LumitState`. Reads are nearly free now (K-184), but the
    widget-tree rebuild itself is not. Hidden dock tabs are already out of it
    (they are never built while hidden, 2026-07-28); scoping the visible tree
    remains.

**The RAM frame cache is now only the scope path's cache (K-183, narrowed by
K-187).** The zero-copy transport keeps no CPU bytes, so `framecache` is filled
only by scope traces; what serves the Viewer is the VRAM final-frame cache
(K-187, "cache on the card"), which the cache bar merges into its answer.
`framecache`'s content-keying upgrade (K-178's design, needs the probe view)
remains worthwhile but is now much lower stakes. Registering a texture still
cannot happen in a widget test; `integration_test/shared_texture_test.dart`
(run by hand on a real window) is the coverage.

**The Windows shared-texture test races, rarely (seen 2026-07-30).**
`lumit-gpu`'s `shared::tests::the_legacy_handle_yields_the_pixels_angle_style` failed one
CI run with `[0, 0, 0, 0]` where the orange should be, and passed on the run before and the
run after with nothing between them touching that code. The cause is the missing handshake
the module note already records: `present` ends with a D3D11 `CopyResource` and a `Flush`,
which *submits* the copy without waiting for it, and the test's reader opens the shared
texture on a third device with no keyed mutex to wait on — so it can map the surface before
the copy has landed. Fix it with the reader waiting on a `D3D11_QUERY_EVENT` (test-side, no
change to the shipping path) or by landing the keyed-mutex handshake K-177 defers. Wants a
Windows machine to write it on: a blind fix cannot be run before it is pushed.

**Playback scheduler — what remains.** The ring landed (2026-07-27): renders run
ahead of the clock into a bounded ring sized by measured p95 cost
([impl/playback-scheduler.md](impl/playback-scheduler.md) §5), presents pace
against the clock, and a stop/seek drops the ring wholesale. The decode-ahead
thread landed the same day (`lumit-bridge/src/prefetch.rs`): playback posts the
coming frames' source decodes to a thread with its own decoders, results file
into the renderer's decoded-frame cache under the decode's own key, so decode
runs alongside compositing (§5's decode ∥ evaluate). Still not built from the
note: the worker pool and in-render epoch tokens (composites are serial on the
one worker thread, so cancellation latency is one frame's render, not §1's
15 ms — the tokens only mean something once renders leave that thread); and §6's
real-window benches (A/V drift over 10 minutes, the underrun ladder). The
**pre-roll landed 2026-07-29**: the sound starts when the ring holds three frames
or 150 ms have passed, whichever is first, and the clock's baseline is taken then
rather than when the request arrived. Re-run
`integration_test/playback_bench_test.dart` to price the stack: the serial loop
measured 58.7 fps on 1080p60 footage just before the ring landed.

**Viewer / comp rendering (gated on the F2 comp-render path):**
- Transform gizmo and motion paths ([07-UI-SPEC.md](07-UI-SPEC.md) §2.3-§2.4);
    timeline razor/clip editing and overrun hatching surface here too.

**Settings pages not built ([07-UI-SPEC.md](07-UI-SPEC.md) §15):**
- Colour-management settings; preview-mode (Cached/Realtime) toggle; CUDA on/off;
    plugins/decoder page. (The **Keymap** editor landed with K-199.)
- The egui shell's fuller Performance/General/Export pages are not rebuilt in
    Flutter yet: the disk cache budget and root folder (the tier is built but
    never constructed — see *Now*), autosave interval/keep, and the export
    defaults (preset + filename template). The RAM and VRAM cache budgets
    landed in the Settings window (K-187) and now survive a restart; idle
    background fill landed with no setting (it costs nothing the user would
    trade). Each remaining page lands wired to the
    engine through the bridge, not as a Dart-side setting nothing reads
    (K-181/K-182).

**CI coverage the Flutter port left thin (2026-07-28, from the merge of K-174 → K-198):**
- **Nothing in CI proves a Viewer frame arrives.** The Linux job is the only one that
    runs the Flutter suite, and it has no GPU: wgpu lands on Mesa's lavapipe, whose
    `vkAllocateMemory` refuses the exportable allocation DMA-BUF needs, so every frame is
    dropped at the publish step. Zero-copy is the only transport (K-183), so the six
    Viewer tests that wait for a frame skip there on `LUMIT_NO_ZERO_COPY_VIEWER=1`
    (set in `.github/workflows/ci.yml`, read in `test/frb/frb_test_support.dart`). They
    still run — and still fail on a regression — on any machine with a real adapter, so
    the owner's box is the gate for now. Either a Linux runner with a GPU or a Windows
    job that runs `flutter test` would close this and verify the DMA-BUF path above at
    the same time.
- **The Flutter suite runs at `--concurrency=1` in CI**, which is the mitigation for the
    order-dependent tests under Now, not the fix. It costs the Flutter job wall-clock and
    it hides the contention rather than removing it; the per-file engine does the latter.

**Threading / platform:**
- **Move footage probing off-thread** - synchronous today; needs a probe worker
    drained on `lumit_bridge_snapshot` plus a synchronous `ensure_probed` fallback
    for consumers that read the cache synchronously (`convert_to_sequenced`,
    `trim_to_source_end`, `add_footage_layer`, relink). (archive/flutter-port/06 §B)
**Shared-texture producer/consumer fence** - only if the owner's live run shows
    tearing; verify on the machine first. (archive/flutter-port/06 §B)
**Linux packaging** - the flatpak shipped the egui `lumit-app` binary and was
    retired with it (K-182); the Flutter Linux build needs its own packaging
    when a Linux release matters.
**Export options still to build (K-201 landed format/fps/range/audio-rate; docs/06 §7).**
The one-click vertical variants (centre-crop reframe), user presets serialised beside the
built-ins, export priority and encoder preference order, and the 48 kHz-only audio rate
becoming a choice. The size fields also stay preset-driven — the dialogue has no free
width/height boxes yet.
**Export status still speaks v0's idiom** - `export.rs` replies in JSON strings
    (`err_json`) that the export dialog polls on a timer; the worker shows the
    typed-stream way, and export should follow it.

**Layer Area & Effect Control Panel Performance Indicator**
- Display performance indicator, the ms time for layer (total including all effect changes etc.), this
    should be on the main layer row, then each effect also have this on it's title row (but just the time
    for that specific effect to render for that frame). These values should also be given a column they're
    all in, same as all other layer area sub-columns.
- For the Effect Control panel/tab, the same value for an effect's time to composite should be listed on
    it's title row.
## Later - roadmap features not yet built

Grouped by the phase they belong to in [16-ROADMAP.md](16-ROADMAP.md). Pointer
list, not a re-statement of the roadmap.

- **Media engine ([05-ARCHITECTURE.md](05-ARCHITECTURE.md) §6, [06-RENDER-PIPELINE.md](06-RENDER-PIPELINE.md)).**
    Hardware decode: the D3D11VA baseline landed 2026-07-27 (decode on the video
    unit, transfer to system memory, sw fallback —
    [impl/media-io.md](impl/media-io.md) §4); still to come are the one-copy
    D3D11→DX12 interop and VideoToolbox (K-033). Also: proxy generation;
    image-sequence footage; the resource governor (the VRAM cache tier itself
    landed 2026-07-27, K-187);
    ProRes/DNxHR intermediate export (v1 is H.264/HEVC only); the 8-/32-bpc
    working-depth switch (v1 is fp16 only); OCI0 v2 colour management and the
    colour-management UI.

- **Audio (the largest gap - [07-UI-SPEC.md](07-UI-SPEC.md) §10, [09-AUDIO.md](09-AUDIO.md)):**
    - **Audio panel** - the whole panel is missing in Flutter. The engine (playback,
        volume, beat detection) works; there is no UI for it. Per-layer **Volume** now
        has one: the Audio group in the Timeline's fold-out, shown only on a layer whose
        source carries sound ([07-UI-SPEC.md](07-UI-SPEC.md) §4.3), and the waveform
        lane landed 2026-07-28. The panel itself and level meters are still missing.
    - **Beat-marker generation UI** (sensitivity, BPM-grid, range) - a one-click
        detect button landed 2026-07-28 in the layer fold-out; the tuning
        controls do not exist.
    **Beat tap** (press `8` during playback) and **level meters** - not wired.
    - **Persistent waveform peak** Persistent waveform peak files (peaks are
        computed on demand today);
- **File format ([10-FILE-FORMAT.md] (10-FILE-FORMAT.md)).** Embedded `thumbs/`
    previews in the `.lum`; the per-project sidecar `proxies/`, `peaks/`, `flow/`
    directories (only `frames/` + the global media index exist today).
- **Design ([15-DESIGN.md](15-DESIGN.md)).** Bundle JetBrains Mono, Schibsted
    Grotesk and Source Serif 4 (only Inter is wired); add the 13/14/20 px type-scale
    steps to the theme; add 'ScopeColours' to the Flutter theme (Rust has it).
- **Platform.** The macOS pass (native menu bar, VideoToolbox, ProRes,
    notarisation, K-033). The Metal/IOSurface zero-copy Viewer path landed
    2026-07-28 (K-195) and is unverified on real hardware — the checklist is in
    GUIDE §9, next to the Linux one.
- **Phase 2 - Retime.** Flow interpolation policies; automatic beat snapping
    across edit/retime points ([04-RETIMING.md](04-RETIMING.md),
    [09-AUDIO.md](09-AUDIO.md)). The Timeline audio waveforms landed 2026-07-28.
- **Phase 3 - The look.** Per-layer motion blur polish and the scopes GPU pass
    ([08-EFFECTS.md](08-EFFECTS.md)). Preset save/list/apply landed 2026-07-28
    (the Effects & presets panel's Saved presets group); importing a preset
    file from outside the presets folder is still a manual copy. The Tier-1
    effect suite itself is already shipped. This gate is the v1.0 milestone.
**Phase 4 - Extensibility (whole docs, nothing built -
[11-AE-IMPORT.md](11-AE-IMPORT.md), [12-PLUGINS.md](12-PLUGINS.md)).** AE import
(Bridge panel, `.aep` parser, Lottie, fidelity report); the OFX host; the LFX C
ABI + validator; expressions (QuickJS-ng). Placeholder round-tripping already
preserves unknown effects/expressions.
- **Phase 5 - AE parity march.** 2.5D cameras/lights/DOF, tracker/stabiliser,
keying, rotoscoping, particles, tier-2 effects, text animators, shape
operators, the Composer audio workspace ([09-AUDIO.md](09-AUDIO.md) ).
- **Phase 6 - Beyond parity.** Node view over the evaluation graph, Blender scene
import, Lottie export, OpenTimelineIO interchange, render-farm/CLI export
(K-023, K-036).

## Deliberately deferred (not backlog)

Recorded so they are not re-proposed as gaps:

- **Rotation gizmo affordance** - egui never offered one; not a regression.
- The two recorded behavioural deviations (export queue-snapshot timing;
    share-export VBR cap) - see [02-DECISIONS.md](02-DECISIONS.md).