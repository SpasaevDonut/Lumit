# TODO - the work backlog

**Status: living.** The single source of truth for work that is planned but not
done, and the one document that says what is built. The specs describe the
target; gaps live here.

**How to use it.** Keep entries to one line plus a source pointer. Move an item
up the sections as it becomes actionable; **delete it when it lands** - its
regression test is the permanent record, per
[14-ENGINEERING-RULES.md](14-ENGINEERING-RULES.md). Landed work does not belong
in a backlog. [16-ROADMAP.md](16-ROADMAP.md) stays the aspirational phase plan;
this file is the concrete backlog underneath it.

---

## Now - the preview must keep up

These sit above everything else: they are what the editor feels like in the hand.

- **Replace `poll(Maintain::Wait)` with a keyed mutex** - every present waits for
    the card to go idle before handing the texture over (`shared.rs`,
    `shared_linux.rs`, `shared_metal.rs`; find it by the call, not a line number).
    Playback from the card has slack to hide the stall; playback from memory does
    not. **Its own branch and its own pull request** - surgery on the
    shared-texture chain, where a mistake shows as tearing, not as an error.
    Measure first: the 2026-07-30 fixes may have made it moot. Not a revival of
    the read-back transport (deleted in K-183) - the Viewer receives a GPU handle
    and nothing else.
- **Playback's remaining bridge chatter scales with rows on screen** - one
    `sample_scalar` per animated row plus one `time_of_frame`. Batch per frame if
    it ever bites, the way `time_of_frame` already was.
    (`bridge_call_budget_test.dart` is the gate.)
- **A frame gives the card one command buffer per layer, where one would do.**
    Measured 2026-07-31: submits per frame = layers + 2 (3 at one layer, 10 at
    eight, 34 at thirty-two). Every pass in `lumit-gpu` makes and submits its own
    encoder (`composite.rs`, `fx/*`, the display pass), yet all of a frame's
    passes are in order on one queue, so they can be encoded once and handed over
    once. Each submit is a round trip to the driver, a cost that does not depend
    on the card - which is why this is worth doing even though it cannot be
    *timed* on a software rasteriser. It takes
    [impl/playback-scheduler.md](impl/playback-scheduler.md) §2's one-submit-thread
    rule further rather than conflicting with it. The shape: pass a
    `&mut wgpu::CommandEncoder` down the realise walk and submit once at the top,
    leaving the read-backs (`start_readback8`) and shared-texture copies alone -
    both need their own submission to be waited on. **Re-measure on real hardware
    either side**: the stopwatch that found it was on the dropped worker-pool
    branch, and a change made for a number needs the number.

---

## Now - Flutter frontend parity and regressions

Flutter is the only frontend (K-174, K-182); git history is the parity reference.
These are v1-scope surfaces it does not yet match.

**Audio ([07-UI-SPEC.md](07-UI-SPEC.md) §10, [09-AUDIO.md](09-AUDIO.md)):**
- Sequence-clip waveforms - Sequence layers' clips draw none.

**The sequence view (K-248), still owed after the view itself landed:**
- **Per-clip thumbnails** at each clip's start and end. They want a decode at a
    *given source moment*; `FootageReference::thumbnail` only ever decodes the
    media's first frame, so this is a new engine path plus a cache, not a
    drawing change.
- **Shaping a clip's ramp beyond its two ends** - the in-row strip sets a
    clip's speed (and a straight ramp); the full envelope with points inside a
    clip is the graph editor's, and a Sequence layer has no Retime channel
    there yet (K-075 sent it here instead).
- **Dragging clips to reorder** - `move_clip` is built and tested; nothing in
    the row drags yet, so the only way to reorder is through the bridge.

**Viewer bar ([07-UI-SPEC.md](07-UI-SPEC.md) §2.2):**
- The wireframe/overlay *menu*; guides menu; region-of-interest;
    colour-management indicator; background-colour swatch.
- Click-to-edit timecode (read-only today) - decide whether it moves to the
    Timeline's clock rather than being built twice.

**Toolbar tools ([07-UI-SPEC.md](07-UI-SPEC.md) §1.7):** what is armed is a
*tool*; what each tool then does is the backlog.
- **Razor** - a Sequence layer's eased ramps refuse a cut (`UncuttableClip`), and
    its **clips'** own speed maps get no key at the cut the way a layer's Retime
    does.
- **Shape layers** - built (K-237, [impl/shape-layers.md](impl/shape-layers.md)):
    with nothing selected a shape tool or the Pen makes a layer holding the art,
    in the toolbar's fill and stroke, listed in the Timeline under Contents.
    Still owed: nested groups and the shape **modifiers** (repeater, trim paths,
    wiggle, offset paths), gradient fills, dashed strokes, joins and caps other
    than round, animated paths, and dragging a shape's points on the picture the
    way a mask's drag.
- **Path editing on the picture** - a *mask's* points drag (K-224); a **shape
    layer's** and a **stroke's** do not, so art can be drawn but not reshaped
    without redrawing it. No path's bezier **handles** can be dragged either, so
    the `Alt`-drag that re-links a broken tangent pair exists only while a point
    is being *placed*. One piece of work with the Pen's add/delete/convert-vertex
    siblings and dragging a whole path by a segment: all of them edit a path that
    already exists, and none of them can today.
- **Wireframes over a shape layer's own art** - a shape layer draws the box its
    art fills, like every other layer, rather than the paths inside it.
- **Mask paths cannot be keyframed** ([03-DATA-MODEL.md](03-DATA-MODEL.md) has
    them as animatable); there is no mask **mode** (add/subtract/intersect) -
    every mask adds; **mask feather** has neither a control nor a renderer path.
- **Type** - vertical type (needs `lumit-text` to lay a line downwards); true
    glyph metrics across the bridge (the caret, the anchor and the gizmo all use
    the same half-an-em estimate, and one measured advance width would replace
    all three); multiple lines and a character panel (font, tracking, leading,
    alignment - the document is one styled run, [03-DATA-MODEL.md](03-DATA-MODEL.md)
    §9.1); per-character and per-word animators.
- **Paint** (brush/clone stamp/eraser) - built (K-227, [impl/paint.md](impl/paint.md)):
    strokes are stored as the gesture in layer space and stamped into the layer's
    pixels before its masks, with the brush's size, hardness and opacity on the
    toolbar, a Paint heading in the Timeline, and one undo step per stroke. Still
    owed: **pressure and tilt** from a tablet, **brush shapes** other than round,
    **spacing** and **scatter**; **write-on** (a stroke's own start and end times,
    which is what makes paint animate in After Effects - nothing in the model
    yet); **per-stroke blending modes**; painting in **Layer view** rather than on
    the composite; **a GPU stamping path** (the rasteriser is a CPU loop beside
    the mask one, and it changes the rasteriser, not the stored stroke); and
    **paint on a Precomp layer's nested pixels**, which never come back to the
    CPU, so a stroke on one currently marks nothing.
- **Camera** - a separate point of interest (AE's two-node camera) is an engine
    change; the Unified Camera tool; depth-of-field handles on the picture; a
    keyframed camera cannot be dragged (no single value to add to); a drag
    spanning several layers is one undo step per layer, because no op carries
    edits to more than one.
- **Roto** and **Puppet** - disabled on the strip until there is an engine behind
    them ([16-ROADMAP.md](16-ROADMAP.md)). Roto wants a segmentation model and
    per-frame stroke propagation; Puppet wants a mesh, pins and a deformer.
- **Snapping** is a switch nothing reads ([07-UI-SPEC.md](07-UI-SPEC.md) §4.5).
- **The workspace strip shows no preset after a restart** -
    `Workspace.activePreset` is session-only.

**Smooth zooming everywhere else.** The Viewer's magnification flies; the
Timeline's time zoom (`=`/`-`, `Ctrl+wheel`, `\`), the graph editor's zoom and
auto-fit, and the Project panel's thumbnail scaling all still cut. Lift the
Viewer's shape into one shared helper rather than writing it three more times.
The Timeline matters most - it is zoomed constantly while cutting.

**Layer controls in the Viewer ([07-UI-SPEC.md](07-UI-SPEC.md) §2.3):**
- **Motion paths** (§2.4) - a keyed position draws no path and its keys cannot be
    dragged there.
- **Scale and rotation of a multiple selection** - each layer keeps its own box
    and only a lone selection grows handles; AE scales a set about one shared box.
- **Snapping** - nothing outside the Timeline's keyframe magnet snaps to
    anything (§4.5, §1.7).
- **Parent-aware and 3D gizmos** - the box is built from the layer's own
    transform, so a parented layer's ignores its parent and a 3D layer's ignores
    the camera.
- **A keyframed position draws no box**, so an animated layer cannot be picked on
    the picture. It wants the value *at the playhead*, which the read model does
    not carry.

**Pixel pickers ([07-UI-SPEC.md](07-UI-SPEC.md) §6.1):**
- The x/y coordinate pick - no Flutter row pairs x and y into one control yet
    (the magnifier already carries the mode).
- The on-Viewer crosshair handle for point parameters - a point parameter can be
    picked but not dragged on the picture.

**Bridge ([17-BRIDGE-CONTRACT.md](17-BRIDGE-CONTRACT.md)):**
- **A panic throws rather than reporting.** frb contains every panic but surfaces
    it as a thrown Dart exception, so no call site may treat a throw as
    impossible. The `no-panics-in-frb-api` grep is prevention, not a fix.
- **clippy is blind to the frb surface** - `#[frb(...)]` is a proc-macro
    attribute and restriction lints skip macro-expanded code, so
    `unwrap_used`/`panic`/`todo` never fire on an annotated function. The real fix
    is to stop needing the grep.
- **`ProjectReference::state()` hands the raw `Arc<RwLock<…>>` out**, so a caller
    can hold a project lock as long as it likes and in any order. The order is
    written down and tested; nothing enforces it at the type level.
- **`DocumentStore::set_callback` takes `&mut self`**, so the observer can only be
    attached before the store is shared.
- **The macOS IOSurface Viewer path is unproven** - CI links the bundle but
    nobody has launched the .app (K-033).
- **The macOS .app is not relocatable** - the podspec links keg-only FFmpeg by
    absolute Homebrew path. Distribution needs the dylibs vendored and install
    names rewritten (K-033).
- **The macOS build is single-architecture** - `pkg-config-rs` refuses to
    cross-compile and a keg holds one architecture, so `ARCHS` is pinned to the
    runner's. A universal bundle needs both `ffmpeg@7` kegs and per-slice `-L`
    flags (K-033), plus a decision on whether Intel macs are supported at all.
- **The iOS podspec is misnamed** - `rust_lib_lumit_flutter` against a pubspec
    name of `lumit_bridge`. Same fix macOS took; iOS has no target and no CI job.
- **The shared-texture chain has no keyed mutex** (a torn frame is possible in
    principle), and the D3D12 → D3D11 legacy-handle hop the Windows path rides is
    not described in [06-RENDER-PIPELINE.md](06-RENDER-PIPELINE.md).
- **The Scopes' trace crosses the bridge as pixels**, a byte at a time, and is a
    fixed 256×256 whatever the panel size - so a large Scopes panel shows it
    visibly soft. It could take the shared-texture route and a size that follows
    the panel.
- **The matte render-alone pass stays at full comp resolution** whatever the
    preview scale (K-186) - correctness-safe, but it is the one composite the
    scale does not shrink.
- **The Linux DMA-BUF path has never run on a Linux machine with a GPU** (K-033).
    It fails calmly on the adapter-less CI runner, which proves the failure is
    calm and nothing about the path working.
- **frb's SSE codec encodes `Vec<u8>` one byte at a time** - now taxes only
    thumbnails and scope traces, but worth the bulk codec if traces feel late.
- **Engine subsystems with no frb API** - masks (`add_mask`,
    `add_mask_geometry`); the Retime **graph** (`segment_to_rate`,
    `set_segment_preset`, `drag_boundary`) and the curve view that makes ramps
    editable; `trim_to_source_end`.
- **The audio mix is rebuilt from scratch** whenever the comp's audio signature
    changes, rather than patched.

**Retime follow-ups after K-249** (the system is one property now, layers and
clips alike):
- **`convert_to_sequenced` drops the layer's Retime** rather than carrying it
    onto the clip it makes (`layer.rs`). A layer's map is keyed in layer time
    and a clip's in clip time; they coincide only while the clip spans the
    whole layer, and carrying one across as if they were interchangeable is
    how a conversion silently re-times footage.
- **A clip's own map gets no key at a razor cut**, the way a layer's does
    (below, under Toolbar tools).
- **The eased ramp shapes are gone from clips** — `Clip::with_ramp` takes two
    speeds and runs straight between them, which is what the envelope authors.
    Slow/Fast/Smooth/Sharp come back with the preset-shelf rework above,
    rebuilt on the property like everything else K-249 moved.

**System memory is only read on Windows.** `system_memory_bytes` and
`video_memory_bytes` answer 0 elsewhere and the settings fall back to a 16 GB
ceiling. macOS/Linux want `sysctl hw.memsize` and `/proc/meminfo` (K-033).

**Bound keys with nothing behind them.** The **Tools**, **Project**, **Panels**
and **Effects** keymap contexts have real bindings and no commands. Either build
the commands or drop the bindings; do not leave the two disagreeing for long.

**Appearance.** Custom themes are per-machine - they live in the workspace file
with no import/export *of a theme* (the keymap has one). No preview swatch strip
and no duplicate-a-theme button. The seven built-in schemes still restate every
colour individually; only the two Timeline tokens default from the mode.

**Shell and onboarding:**
- **The boot splash is not mounted.** `flutter_ui/lib/shell/splash.dart` exists
    and only its test imports it. Engine-side events cannot post a notice either:
    there is no notice stream, only `boot_log`.
- **Pop-out panel windows are removed** (K-182). Rebuild from git history
    (`flutter-frontend-alternative`, pre-K-182) when pop-out is wanted, and land
    it wired end to end.
- **Workspace machinery beyond the presets** ([07-UI-SPEC.md](07-UI-SPEC.md)
    §1.6) - user workspaces (save-as/rename/export), the chrome switcher strip,
    and Alt+Shift+1-9.
- **First-run setup screen** (K-006, K-246) - v1 ships minimal in the Vegas PR:
    one AE-style / Vegas-style choice writing the two K-246 settings. Still owed
    after that lands: the four-card version with a small image over each choice
    ([07-UI-SPEC.md](07-UI-SPEC.md) §13.1).
- **Command palette** - recents are session-lived, and only genuinely bound
    shortcuts are taught (today just undo/redo).

**Timeline panel:**
- **Retime in the graph editor** behaves exactly as any other property - same
    value and speed graphs, nothing extra. Retime-specific affordances come later
    (see *Retime UI wiring* under Next); the parity rule itself is spec, and lives
    in [04-RETIMING.md](04-RETIMING.md).
- **The Flow column is reserved, not wired** - per-layer optical flow has no
    engine backing. Build the engine model first, then the fold-out's Flow group.
- **Lock guards the gestures, not the property rows** - a locked layer's bar,
    razor, rename, reorder and delete refuse; its transform/effect/volume rows are
    still editable. Guard the rows or enforce in the engine ops; decide which.
- **The Timeline's two halves are built twice and kept in step by hand.**
    `_Outline` and `_LayerArea` are separate widget trees walking the same layer
    list, aligned only because both read the same numbers, with vertical scroll
    mirrored behind a reentrancy flag. Building a layer **once** as a row holding
    both halves inside one vertical scrollable (the lane side keeping its own
    horizontal controller) gives alignment by construction. It deletes
    `blockHeights`, both controllers' sync and the guard flag rather than adding
    anything. A session's refactor, no behaviour change, alignment tests as the
    net.
- **The lane keyframe selection selects and eases, nothing more** - moving or
    deleting a *whole lane selection* is not built (the graph view has both), nor
    are `=`/`-`/`\` or edge-follow during playback.
- **Column widths and the property selection are session-lived** - fold into the
    workspace when per-workspace column layouts land ([07-UI-SPEC.md](07-UI-SPEC.md)
    §4.2).
- **~4 order-dependent tests in the Flutter suite.** Each passes alone; the suite
    passes at `--concurrency=1`, which is what CI runs. They contend for the
    shared engine (audio device, render worker) across test *files*. Give those
    files a serial marker or make the engine per-file - the serial run is a
    mitigation, not the fix, and it costs wall-clock.
- **The magnet snaps keyframes to frames and nothing else**
    ([07-UI-SPEC.md](07-UI-SPEC.md) §4.5 wants edit points, in/out points,
    markers, beat markers, the playhead and work-area edges, plus `Ctrl`-hold to
    suspend mid-drag).
- **Volume keyframes draw no lane diamonds and no graph curve** - volume is not
    in the comp read model; fold it into `BridgeLayerInfo` if either matters.
- **A Null layer cannot be selected in the Viewer** - no size, no pixels, nothing
    to hit-test. A drawn, selectable handle for transform-only layers is the fix
    and would serve Camera layers too.
- **Effects on a Null are accepted and never run** - either refuse the drop or
    say plainly that the stack is inert.

**Layer and effect render-time indicator.** Per-layer total render time in ms on
the layer row, and per-effect time on each effect's title row, both as a Timeline
sub-column like the other sub-columns; the same per-effect value on its title row
in the Effect controls panel ([13-PERFORMANCE-RULES.md](13-PERFORMANCE-RULES.md)
§7.1).

## Next - engine/bridge follow-ups

**Anti-aliasing in the renderer.** Edges of transformed layers, shape strokes and
text stair-step, worst on a slow rotation. Two questions decide where the setting
lives: whether the sample count is a **project** property (it changes what a comp
looks like, so it must match on another machine and in export) or a
**preference** (it trades quality for speed on this machine), and whether preview
and export share one value. Sample counts must be checked against the adapter
rather than assumed.

**The stale-fd race on a Linux Viewer resize** (`lumit-render/src/headless.rs`'s
`shared_dmabuf` re-create, with `lumit-gpu/src/shared_linux.rs`'s `Drop`). The
exported descriptor is closed when `SharedDmabuf` drops, but the descriptor
*number* travels to Dart asynchronously, so two quick resizes can have Dart
register a closed fd - or one the OS has since reissued. Either hold the previous
`SharedDmabuf` for one generation, or `dup()` at export so the number in flight
owns itself.

**Ramp preset shelf rework** - the Linear/Slow/Fast/Smooth/Sharp buttons need a
general rethink (owner, 2026-08-02) before they return on the property path; not
a Vegas-mode concern ([04-RETIMING.md](04-RETIMING.md) §12.2).

**Retime UI wiring** (UI/command affordances - [04-RETIMING.md](04-RETIMING.md);
post-K-249 these return on the **property** path — the segment calls named here
are the reference for behaviour, not wiring targets):
- Freeze-at-playhead (`insert_freeze` built, no caller); Hold preset button;
    RATE/MAP type chips; kink badge; graph overrun band + source-out reference
    line; compensating Alt-drag; copy/paste a retime between clips;
    outward-trim-extends-map; the retime keyboard shortcuts (§12); Blend
    interpolation toggle; Flow-params UI and the source-rate advisory badge.
- Precomp retiming - Precomp layers carry no Retime today; decide the intended
    scope before building.
- The Time-lens **vertical (source-position) boundary drag** has no bridge op
    (`SetLayerRetime`/`from_source_keyframes` unexposed).

**Bridge reads left outside the read model** - the Source card's text/camera
fields for the selected layer, the Viewer's missing-file probe, and the
marker/work-area reads on a Timeline rebuild. Fold any into
`BridgeLayerInfo`/`BridgeCompModel` if they show up in the budget ranking.

**`LumitAppNew` rebuilds the whole app on any `LumitUiState.notifyListeners`** (a
`ListenableBuilder` above everything), and un-scoped document changes do the same
via `LumitState`. Reads are nearly free; the widget-tree rebuild is not. Scoping
the visible tree remains.

**The Windows shared-texture test races, rarely.**
`lumit-gpu`'s `shared::tests::the_legacy_handle_yields_the_pixels_angle_style`
failed one CI run with `[0, 0, 0, 0]`. `present` ends with a `CopyResource` and a
`Flush`, which submits without waiting, and the test's reader opens the shared
texture on a third device with no keyed mutex to wait on. Fix with a
`D3D11_QUERY_EVENT` on the reader (test-side only) or by landing the keyed-mutex
handshake. Wants a Windows machine to write it on.

**Playback scheduler - what remains**
([impl/playback-scheduler.md](impl/playback-scheduler.md)): in-render epoch tokens
(composites are serial on one worker thread, so cancellation latency is one
frame's render rather than §1's 15 ms), and §6's real-window benches (A/V drift
over 10 minutes, the underrun ladder). Re-run
`integration_test/playback_bench_test.dart` to price the stack; it needs a
1080p60 fixture and a Windows device, so it is run by hand.

**Settings pages not built ([07-UI-SPEC.md](07-UI-SPEC.md) §15):**
colour-management; preview-mode (Cached/Realtime) toggle; CUDA on/off;
plugins/decoder page; autosave interval/keep; export defaults (preset + filename
template). Each lands wired to the engine through the bridge, not as a Dart-side
setting nothing reads.

**CI coverage the Flutter port left thin:**
- **Nothing in CI proves a Viewer frame arrives.** The Linux job is the only one
    running the Flutter suite and has no GPU, so the six Viewer tests that wait
    for a frame skip there on `LUMIT_NO_ZERO_COPY_VIEWER=1`. They still fail on a
    regression on any machine with a real adapter, so the owner's box is the gate.
    A Linux runner with a GPU, or a Windows job running `flutter test`, closes
    this and verifies the DMA-BUF path at the same time.
- **The Flutter suite runs at `--concurrency=1`** - the mitigation for the
    order-dependent tests above, not the fix.
- **Registering a texture cannot happen in a widget test**, so
    `integration_test/shared_texture_test.dart`, run by hand on a real window, is
    the only coverage of that path.

**Threading / platform:**
- **Move footage probing off-thread** - synchronous today; needs a probe worker
    drained on `lumit_bridge_snapshot` plus a synchronous `ensure_probed` fallback
    for `convert_to_sequenced`, `trim_to_source_end`, `add_footage_layer` and
    relink.
- **Shared-texture producer/consumer fence** - only if a live run shows tearing;
    verify on the machine first.
- **Linux packaging** - the Flutter Linux build needs its own packaging when a
    Linux release matters.
- **Export options still to build** ([06-RENDER-PIPELINE.md](06-RENDER-PIPELINE.md)
    §7) - one-click vertical variants (centre-crop reframe), user presets
    serialised beside the built-ins, export priority and encoder preference order,
    the 48 kHz-only audio rate becoming a choice, and free width/height boxes
    (sizes are preset-driven today).
- **Export status still speaks the old idiom** - `export.rs` replies in JSON
    strings (`err_json`) polled on a timer; follow the worker's typed-stream way.

- **The menu bar names its own backlog (K-244).** Every row marked
    "(Not implemented)" in File/Edit/Composition/Layer/Animation/View/Help is a
    command with a place waiting for it: Close project, History, Cut/Copy/Paste,
    layer settings and the mask/transform/blending/matte/style families, the
    whole Animation menu, the View menu's zoom/resolution/grid/ruler rows,
    Trim and Crop comp to work area, Add to export queue, Check for updates and
    the help links. Delete each mark as the command lands. Suggested chords for
    the AE-shaped ones are in K-244.

## Later - roadmap features not yet built

Grouped by the phase they belong to in [16-ROADMAP.md](16-ROADMAP.md). A pointer
list, not a re-statement of the roadmap.

- **Media engine ([05-ARCHITECTURE.md](05-ARCHITECTURE.md) §6).** The one-copy
    D3D11→DX12 interop and VideoToolbox (K-033); proxy generation; image-sequence
    footage; the resource governor; ProRes/DNxHR intermediate export (v1 is
    H.264/HEVC only); the 8-/32-bpc working-depth switch (v1 is fp16 only); OCIO
    v2 colour management and its UI.
- **Audio - the largest gap** ([07-UI-SPEC.md](07-UI-SPEC.md) §10,
    [09-AUDIO.md](09-AUDIO.md)): the whole **Audio panel** and level meters; the
    beat-marker tuning controls (sensitivity, BPM-grid, range); **Beat tap**
    (`8` during playback); persistent waveform peak files (peaks are computed on
    demand today).
- **File format ([10-FILE-FORMAT.md](10-FILE-FORMAT.md)).** Embedded `thumbs/`
    previews in the `.lum`; the per-project sidecar `proxies/`, `peaks/` and
    `flow/` directories (only `frames/` and the global media index exist).
- **Design ([15-DESIGN.md](15-DESIGN.md)).** Bundle JetBrains Mono, Schibsted
    Grotesk and Source Serif 4 (only Inter is wired); add the 13/14/20 px
    type-scale steps to the theme; add `ScopeColours` to the Flutter theme (Rust
    has it).
- **Platform.** The macOS pass - native menu bar, VideoToolbox, ProRes,
    notarisation (K-033). The Metal/IOSurface Viewer path is unverified on real
    hardware.
- **Phase 2 - Retime.** Flow interpolation policies; automatic beat snapping
    across edit/retime points ([04-RETIMING.md](04-RETIMING.md),
    [09-AUDIO.md](09-AUDIO.md)).
- **Phase 3 - The look.** Per-layer motion blur polish and the scopes GPU pass
    ([08-EFFECTS.md](08-EFFECTS.md)); importing a preset file from outside the
    presets folder is still a manual copy. This gate is the v1.0 milestone.
- **Phase 4 - Extensibility** (whole docs, nothing built -
    [11-AE-IMPORT.md](11-AE-IMPORT.md), [12-PLUGINS.md](12-PLUGINS.md)). AE
    import (Bridge panel, `.aep` parser, Lottie, fidelity report); the OFX host;
    the LFX C ABI + validator; expressions (QuickJS-ng). Placeholder
    round-tripping already preserves unknown effects/expressions.
- **Phase 5 - AE parity march.** 2.5D cameras/lights/DOF, tracker/stabiliser,
    keying, rotoscoping, particles, tier-2 effects, text animators, shape
    operators, the Composer audio workspace ([09-AUDIO.md](09-AUDIO.md)).
- **Phase 6 - Beyond parity.** Node view over the evaluation graph, Blender scene
    import, Lottie export, OpenTimelineIO interchange, render-farm/CLI export
    (K-023, K-036).

## Deliberately deferred (not backlog)

Recorded so they are not re-proposed as gaps:

- **The render worker pool, measured and deliberately not built (2026-07-31).**
    [impl/playback-scheduler.md](impl/playback-scheduler.md) §2 reserves GPU
    submits to one thread, so the only work a pool could take is the processor
    half of a frame - naming it, planning the decode, building the draw list.
    That half measured **0.03 ms at 32 animated layers against 200 ms for the
    whole frame**, or 0.015%, and it is an absolute CPU cost that does not shrink
    on a faster card, so its share only falls on real hardware. Spreading it over
    threads saves nothing at any layer count. The same measurement found the
    command-buffer item under *Now*, which is where the win actually is. Anyone
    reaching for the pool again should re-run the stopwatch first: if the
    processor half has not grown, this entry still stands.
- **Rotation gizmo affordance** - the previous frontend never offered one; not a
    regression.
- The two recorded behavioural deviations (export queue-snapshot timing;
    share-export VBR cap) - see [02-DECISIONS.md](02-DECISIONS.md).
