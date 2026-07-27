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

## Now - Flutter frontend parity and regressions

The frontend moved from egui to Flutter (K-174). Flutter is now the frontend; the
egui code remains only as the parity reference. These are v1-scope surfaces the
Flutter frontend does not yet match, from the 2026-07-24 doc/code parity pass.

**Playback measurements (2026-07-27, real window, `integration_test/playback_bench_test.dart`):**
every-frame mode with one 1080p60 H.264 layer sustains ~64 fps (was ~56 before
the two-in-flight pipeline). The bench needs `C:/tmp/test1080p60.mp4` (ffmpeg
`testsrc2`) and a Windows device, so it is run by hand, not in CI.

**Audio ([07-UI-SPEC.md](07-UI-SPEC.md) §10, [09-AUDIO.md](09-AUDIO.md)):**
- **Timeline audio waveforms** - no waveform lane on audio/footage layers or in
sequence clips.

**Viewer bar ([07-UI-SPEC.md](07-UI-SPEC.md) §2.2):** magnification, channel view
and the transparency grid have landed. Still missing:
- re-introduce zooming via scrolling (focused on mouse position)
- wireframe/overlay menu
- guides menu
- region-of-interest
- colour-management indicator
- degradation indicator badge
- background-colour swatch.
- **Click-to-edit timecode** (currently read-only), may want to remove from this bar and
    only keep the one on timeline and add the functionality there.

**Render pipeline ([05-ARCHITECTURE.md](05-ARCHITECTURE.md), K-178):**
- **Unify the two comp walks — the immediate next job.** `build_comp_draws`
    (interactive) and `render_comp_linear` (export) do the same thing by different
    routes and are kept in step by hand; that hand-syncing is what K-031 currently
    rests on. Make export decode into a `pixels_by_layer` map — it already does
    exactly this for the temporal re-render, in `collect_below_pixels` — then have
    it call `build_comp_draws` + `Realiser::realise` like everything else. Deletes
    ~500 duplicated lines and makes preview == export true by construction.
    **Gate:** a bit-identity test matrix (plain footage, nested and collapsed
    precomps, mattes of each source mode, adjustment layers, per-layer and
    accumulation motion blur, Retime blend/flow) must pass *before* the old walk
    is deleted. `the_preview_and_export_paths_agree_on_a_solid_comp` is the first
    row of that matrix.
- Feed the egui Viewer's live drag through `HeadlessRenderer::render_preview` too,
    so the retained-pixel path is one implementation rather than two (the shell
    still has its own `last_comp` patch loop in `shell/app_update.rs`).
- Surface `DecodePool::comp_decodes` in the bridge's cache stats, so a decode that
    should not have happened is visible rather than merely slow.

**Bridge ([17-BRIDGE-CONTRACT.md](17-BRIDGE-CONTRACT.md)):**

- **The frb migration is done; v0 is deleted (2026-07-26).** `ffi.rs`, its 107
    `extern "C"` exports, the `ABI_VERSION` surface, the v0 `Bridge` and its op
    modules, `bridge/bridge.dart`, `state/app_state.dart`, every v0 panel and the
    `--v0-shell` switch are gone. `crates/lumit-bridge/src/api/` is the whole
    front/back boundary ([17-BRIDGE-CONTRACT.md](17-BRIDGE-CONTRACT.md)).

    *What survived the sweep, and why.* `edits.rs` keeps the layer and asset
    defaults both frontends build from (a new solid is comp-sized and white, a
    camera's zoom is the AE 50 mm model) — pure functions over lumit-core, so it
    is no longer gated on the media and render features it once needed.
    `render::quality_for` is the scale-to-decode-size policy; `framecache`,
    `realtime`, `media` and `export` are shared infrastructure the frb worker now
    drives directly. `viewer_layer_map.dart` needed no port at all.

    *Two gaps the sweep closed rather than carried.* The frb worker now serves
    frames from the rendered-frame cache instead of re-rendering a frame it has
    already made, and reports each genuine render's cost to the realtime
    controller — so playback can drop to a coarser tier on a comp too heavy to
    keep up (K-171).

    *Still outstanding on the frb path:*
    - **A panic throws rather than reporting.** Containment is *not* missing —
        this list previously said it was, wrongly. flutter_rust_bridge's handler
        wraps every call in `catch_unwind` (twice, deliberately: see
        `handler/implementation/handler.rs`), so a panic cannot unwind across the
        boundary. But it surfaces as a thrown Dart exception, where the old
        transport turned it into an ordinary `ok:false` reply the interface
        showed calmly. So the remaining work is Dart-side: no call site should
        treat a throw as impossible. The `no-panics-in-frb-api` grep stays, as
        prevention — a panic is still a bug.
    - **clippy is blind to the frb surface.** `#[frb(...)]` is a proc-macro
        attribute and clippy's restriction lints skip macro-expanded code, so
        `unwrap_used`/`panic`/`todo` do not fire on any annotated function.
        Covered by that same grep; the real fix is to stop needing it.
    - **`ProjectReference::state()` hands the raw `Arc<RwLock<…>>` out**, so a
        caller can hold a project lock for as long as it likes and in any order.
        The lock order itself is now written down and tested beside `PROJECTS`;
        what is left is that nothing *enforces* it at the type level.
    - **`DocumentStore::set_callback` takes `&mut self`**, so the observer can
        only be attached before the store is shared.

    *cargokit is only wired up for two platforms.* The merge adapted
    `rust_builder/linux/CMakeLists.txt` and left every other platform on the frb
    template's values, so the Windows build failed outright. Windows is fixed and
    verified; Android and the macOS/iOS podspecs are corrected by inspection but
    **untested** (no target yet, K-033). Two things still open:
    - The podspecs are named `rust_lib_lumit_flutter.podspec` with a matching
      `s.name`, while the plugin's pubspec name is `lumit_bridge`. Check what
      Flutter's CocoaPods resolution requires before renaming.
    - **cargokit has no hook for cargo features**, so a Linux developer cannot
      ask `flutter run` for `--features shared-texture-linux` and the zero-copy
      Viewer silently is not in the build. Needs a `cargokit_options.yaml` (or an
      env var read in the CMake) carrying per-platform features.

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
- **No disk or VRAM frame cache**, so the cache bar can only ever show the RAM
    tier. The design language's steel blue for "on disk only" and the future VRAM
    tier have nothing behind them yet ([15-DESIGN.md](15-DESIGN.md) §6.3).
- **The zero-copy Viewer works and is on by default (fixed 2026-07-27).** The
    root cause was two-fold, found by driving a real window from an integration
    test and screenshotting it: Flutter's `DxgiSharedHandle` surface goes through
    ANGLE's share-handle path, which (a) takes a *legacy* DXGI share handle
    (`IDXGIResource::GetSharedHandle`) while the engine exported an *NT* handle
    from `ID3D12Device::CreateSharedHandle`, and (b) only opens **BGRA**
    surfaces, while the engine shared RGBA. Both fail silently — the texture
    registers, the compositor asks for it every frame, nothing appears. The
    engine now hops D3D12 → same-adapter D3D11 (NT open, GPU `CopyResource`)
    into a legacy `MISC_SHARED` B8G8R8A8 texture whose legacy handle Flutter
    gets; `the_legacy_handle_yields_the_pixels_angle_style` proves the chain in
    Rust and `integration_test/shared_texture_test.dart` proves it on a window.
    Still open here: no keyed mutex (a torn frame is possible in principle), and
    the D3D11 hop is Windows-only knowledge that docs/06 does not yet describe.
- **The Scopes' trace still crosses the bridge as pixels**, serialised a byte at
    a time like any other `Vec<u8>`, and is decoded into an image Dart-side. Small
    next to a full frame, but it is on the same per-frame path and could take the
    shared-texture route the Viewer now takes.
- **Adaptive playback keeps no frames on the zero-copy path**, because there are
    no bytes to keep — so the Scopes still composite their own frame there, and
    the cache bar stays empty until you switch to Every frame. Both would be
    solved by the engine keeping a small read-back copy a few times a second (as
    the egui shell did) rather than per frame.
- **Playback is driven from Dart**: the audio clock is read over the bridge each
    tick, the playhead moved, and a render asked for back across the boundary.
    With one render in flight that is one round trip per displayed frame rather
    than per tick, so the overhead is small — but the loop would be tighter
    entirely engine-side, which is worth revisiting if the frame budget gets
    tight (docs/13 §B1).
- **The Dart suite only ever exercises the read-back transport.** The harness
    loads `target/debug/lumit_bridge.dll`, which a plain `cargo build` produces
    without `shared-texture` — while the *shipped* Windows build now has it
    (`crates/lumit-bridge/cargokit.yaml`). So the zero-copy path, and the
    mode-picks-the-transport routing in `publish_frame`, are compiled by CI but
    not behaviourally covered. A texture cannot be registered in a widget test at
    all (no platform channel), so covering it needs an integration test on a real
    window.
- **The Viewer composites at full comp resolution whatever the preview scale —
    the dominant playback cost.** `preview_display_texture` always renders the
    comp at `(comp.width, comp.height)`; `Quality::divisor` only shrinks the
    *decode* width (`plan.rs:77`), and the preview `scale` only sizes the output.
    So a Viewer showing a 1080p comp at a third still composites 1920x1080 every
    frame. Measured 59.7 ms/frame for a one-solid 1080p comp shown at 0.42
    (was 74.5 ms before the read-back was reduced on the GPU). Until the comp can
    be composited at reduced size, the realtime controller has nothing to
    usefully lower — and note `realtime::observe` is inert for a second reason:
    it only records a cost when the render was issued at exactly `tier_scale`,
    while Dart sends the panel-fit scale, so the tier never moves. Both need
    fixing together; this is an `06-RENDER-PIPELINE` change (every layer
    transform is in comp pixels), not a patch.
- **The Viewer's zero-copy path was never actually in a shipped build until
    2026-07-26.** `shared-texture` is off by default and was meant to be switched
    on for the built application, but nothing switched it on: `flutter build
    windows` drives cargo through cargokit rather than a command line. The claim
    recorded here that "cargokit has no hook for cargo features" was **wrong** —
    `extra_flags` is exactly that hook (`options.dart`,
    `CargoBuildOptions.parse`), and `cargokit.yaml` now uses it. Linux still has
    no equivalent switched on, deliberately: that path has never run on a Linux
    machine (K-033).
- **The read-back Viewer path costs 8.8 ms per 1080p frame in serialisation
    alone** (37 ms at 4K), because flutter_rust_bridge's SSE codec encodes a
    `Vec<u8>` *one byte at a time* — the generated Rust `SseEncode for Vec<u8>`
    is a per-byte loop, while the Dart side already decodes in bulk. Measured;
    that is the whole of budget B1 for 1080p before any rendering happens. A
    Windows build should prefer `--features shared-texture` (zero-copy, no pixels
    cross at all). Fix properly by getting frb to emit the bulk codec on the Rust
    side too — worth checking whether a bare `Vec<u8>` return rather than a
    struct field is what triggers it — or by moving that call to the DCO codec,
    whose `IntoDart` for `Vec<u8>` is already zero-copy.

- **Engine subsystems with no frb API yet.** Masks (`add_mask`,
    `add_mask_geometry`); the Retime **graph** — the segment
    model (`segment_to_rate`, `set_segment_preset`, `drag_boundary`) and the
    curve view that makes ramps editable; `trim_to_source_end`; the preset *listing*; and `decode_frame`, the
    single-layer decode behind the Viewer's fallback.

- **Audio is in, with one honest limit.** Playback, the transport and beat
    detection all work. What is *not* here: an audio waveform on the Timeline
    (the lane the "Now" list above still asks for), and the mix is rebuilt from
    scratch whenever the comp's audio signature changes rather than patched.

- **Panel work left.** The graph editor's speed and time lenses and draggable
    bezier handles; and the Viewer's scale and rotate gizmo handles, motion
    paths, masks and shape tools.

**Shell and onboarding:**
- **Several panel toolbars overflow when docked narrow.** The Scopes toolbar and
  others lay out as a plain `Row` with fixed-width controls, so a narrow dock
  shows the overflow stripe. The Timeline toolbar, the Viewer transport and the
  Project panel footer scroll horizontally instead; the rest need the same.
- **Status line and splash are not in the frb shell.** The port's shell rebuilt
  the menu bar and dock but not the bottom status line (notices, export progress
  and its cancel button) or the boot splash; `boot_log` and the export poll both
  exist on the frb API, so this is Dart-side only.
- **Pop-out panel windows are switched off** in the frb shell (`canPopOut` is
  hard-coded false). `popout_host_frb.dart` and `popout_main.dart` are ported and
  the multi-window plugin is wired; only the shell's wiring is missing.
- **Workspace presets** - only the single default layout exists; the four shipped
presets (Edit/Effects/Colour/Audio) are not built ([07-UI-SPEC.md](07-UI-SPEC.md) §1.6).
- **First-run setup screen** (Vegas/AE preference primer, K-006) - absent
([07-UI-SPEC.md](07-UI-SPEC.md) §13.1).
- **Command palette** - only the Commands category; Effects/Comps/Panels
categories, recent-first ranking, and taught-shortcut hints are not built (§12).

**Timeline Panel**
- **Layer area**
    - Fix ordering of subcolumns, and groupings, e.g. left most should be Visiblity o Volume
        then twirl/layer color and layer name, then the rest of the options, and the final
        group is the matte o blend boxes.
    - Effects and Audio sub-menus don't appear on layers
    - Double clicking layer name allows user to edit it
    - Clicking anywhere on a layer (once) Selects the layer
    - Clicking a layer's sub-items/properties, i.e. transform, effects,
        audio also Highlights the layer. Please bear in mind there should be a slight difference
        in color between the Highlight and Selected color (Selected is brighter)
- **Graph editor / Lane Editor / keyframes ([04-RETIMING.md](04-RETIMING.md), archive/flutter-port/06 §C):**
    - Re-introduce ability to move layer before comp start
    - Re-introduce ability to drag start/end of layer to adjust/crop length
    - All Retime specific's are to be implemented later, currently it should behave and have exact parity
        as all other properties in graph view, same value/speed graph etc. Nothing extra
    - Currently marquee/selection box for dragging doesn't happen in flutter ui, needs adding
    - **Effect-param interpolation menu** on the fx keyframe lane.

**Effects & presets / popout:**
- **Preset browser listing** - save/load a `.lumfx` works, but saved presets are
    not listed; needs a 'list_presets / presets_dir bridge op.
- **Main-window resync from a popout** - a popout sees main-window edits via its
    ~2 Hz poll, but the main window only sees a popout's edit on next interaction
    (`AppStateStub` has no public resync). (archive/flutter-port/06 §E)

## Next - engine/bridge follow-ups

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

**The read-back transport is the playback bottleneck, not the renderer.** Measured
on the frb read-back path: a 1.44 MB frame (800x450) costs ~3 ms to render and
**~6 ms to hand to Dart** — `stream.add`'s SSE encode, which is linear in bytes,
so a full 1080p frame is ~35 ms against a 16.7 ms budget at 60 fps. That is why a
single-layer comp with no effects cannot preview at 60 fps: the pixels, not the
compositing. The realtime tier now measures the whole cost and drops resolution
in response (which cuts bytes quadratically, so it does help), but that is
mitigation. The fix is to stop copying: build with `--features shared-texture`
on Windows (K-177 zero-copy is written and unused by default), or replace the
per-byte SSE codec for this one payload. Note `publish_zero_copy` currently
ignores the tier and never reports a cost — wire both when that path goes on, or
adaptive playback will regress to always-Full there.

**Playback scheduler — the rest of it.** Playback now runs in the render worker
rather than in Flutter (K-181), which was the boundary fix. What it is not yet is
the scheduler [impl/playback-scheduler.md](impl/playback-scheduler.md) §5
specifies: it renders one frame at a time, strictly serial, with no ring buffer,
no lookahead adapted from measured p95 cost, and no epoch tokens — cancellation
is still the coarse newest-wins drain. The serial hand-off costs roughly what the
Dart-side two-deep pipeline used to hide (~4 fps on 1080p60 footage), so that is
the number the ring has to beat. Its test plan (§6: cancellation latency,
snapshot isolation, A/V drift, the underrun ladder, the realtime controller)
lands with it.

**Viewer / comp rendering (gated on the F2 comp-render path):**
- Transform gizmo and motion paths ([07-UI-SPEC.md](07-UI-SPEC.md) §2.3-§2.4);
    timeline razor/clip editing and overrun hatching surface here too.

**Settings pages not built ([07-UI-SPEC.md](07-UI-SPEC.md) §15):**
- Keymap editor (`lumit-keymap` model exists); colour-management settings;
    preview-mode (Cached/Realtime) toggle; CUDA on/off; plugins/decoder page.

**Threading / platform:**
- **Move footage probing off-thread** - synchronous today; needs a probe worker
    drained on `lumit_bridge_snapshot` plus a synchronous `ensure_probed` fallback
    for consumers that read the cache synchronously (`convert_to_sequenced`,
    `trim_to_source_end`, `add_footage_layer`, relink). (archive/flutter-port/06 §B)
- **Move beat detection off-thread** - `detect_beats` blocks; a start/poll pair like
    export is the fix. (archive/flutter-port/06 §A)
**Shared-texture producer/consumer fence** - only if the owner's live run shows
    tearing; verify on the machine first. (archive/flutter-port/06 §B)
**Popout multi-window on-machine verification** - the native plugin/dispatch
    compile only in a real `flutter build windows`. (archive/flutter-port/06 §E)

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
    Hardware decode (D3D11VA/D3D12VA/VideoToolbox); persistent decoder pool
    (v1 is one-shot CPU decode); proxy generation; image-sequence footage; the VRAM
    cache tier + resource governor; ProRes/DNxHR intermediate export (v1 is
    H.264/HEVC only); the 8-/32-bpc working-depth switch (v1 is fp16 only); OCI0 v2
    colour management and the colour-management UI.

- **Audio (the largest gap - [07-UI-SPEC.md](07-UI-SPEC.md) §10, [09-AUDIO.md](09-AUDIO.md)):**
    - **Audio panel** - the whole panel is missing in Flutter. The engine (playback,
        volume, beat detection) works; there is no UI for it. Per-layer **Volume** now
        has one: the Audio group in the Timeline's fold-out, shown only on a layer whose
        source carries sound ([07-UI-SPEC.md](07-UI-SPEC.md) §4.3). The panel itself,
        level meters and the waveform lane are still missing.
    - **Beat-marker generation UI** (sensitivity, BPM-grid, range) - `detectBeatMarkers`
        exists on the bridge; the controls to drive it do not.
    **Beat tap** (press `8` during playback) and **level meters** - not wired.
    - **Persistent waveform peak** Persistent waveform peak files (peaks are
        computed on demand today);
- **File format ([10-FILE-FORMAT.md] (10-FILE-FORMAT.md)).** Embedded `thumbs/`
    previews in the `.lum`; the per-project sidecar `proxies/`, `peaks/`, `flow/`
    directories (only `frames/` + the global media index exist today).
- **Design ([15-DESIGN.md](15-DESIGN.md)).** Bundle JetBrains Mono, Schibsted
    Grotesk and Source Serif 4 (only Inter is wired); add the 13/14/20 px type-scale
    steps to the theme; add 'ScopeColours' to the Flutter theme (Rust has it).
- **Bridge and platform.** Migrate the hand-written bridge to
    `flutter rust_bridge` once the command surface stabilises
    ([17-BRIDGE-CONTRACT.md](17-BRIDGE-CONTRACT.md)); the macOS pass (native menu
    bar, Metal/VideoToolbox, notarisation, K-033).
- **Phase 2 - Retime.** Flow interpolation policies; audio waveforms in the
    Timeline; automatic beat snapping across edit/retime points
    ([04-RETIMING.md](04-RETIMING.md), [09-AUDIO.md](09-AUDIO.md)).
- **Phase 3 - The look.** Per-layer motion blur polish, preset import/export,
    scopes GPU pass ([08-EFFECTS.md](08-EFFECTS.md)). The Tier-1 effect suite itself
    is already shipped. This gate is the v1.0 milestone.
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

- **`flutter_rust_bridge` codegen** - deferred by design until the API stabilises
    ([17-BRIDGE-CONTRACT.md](17-BRIDGE-CONTRACT.md)).
- **Rotation gizmo affordance** - egui never offered one; not a regression.
- The two recorded behavioural deviations (export queue-snapshot timing;
    share-export VBR cap) - see [02-DECISIONS.md](02-DECISIONS.md).