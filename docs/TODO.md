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

**Audio ([07-UI-SPEC.md](07-UI-SPEC.md) §10, [09-AUDIO.md](09-AUDIO.md)):**
- **Timeline audio waveforms** - no waveform lane on audio/footage layers or in
sequence clips.

**Viewer bar ([07-UI-SPEC.md](07-UI-SPEC.md) §2.2 - 9 of 11 controls missing):**
- Magnification picker,
- re-introduce zooming via scrolling (focused on mouse position)
- channel view (RGB/R/G/B/A)
- transparency-grid toggle
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
    `add_mask_geometry`); Retime (enabled/speed/reverse/interpolation,
    `segment_to_rate`, `set_segment_preset`) and the two clip commands beside it
    (`drag_boundary`, `trim_to_source_end`); audio (prepare/play/pause/seek/stop/
    clock, `detect_beats`, `clear_beat_markers`); assets (`set_solid`,
    `set_text_content`, `set_camera_zoom`); the preset *listing*; and
    `decode_frame`, the single-layer decode behind the Viewer's fallback.

- **Panel work left.** The graph editor's speed and time lenses and draggable
    bezier handles; the Viewer's scale and rotate gizmo handles, motion paths,
    masks and shape tools; a multi-axis transform row's stopwatch keys only its
    first axis; and the Effect controls panel has no drop target yet for the
    effect drag the Effects & presets panel produces.

**Shell and onboarding:**
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
    - A key drag that moves both time and value currently commits two ops (`shiftKeyframes` then
        `addKeyframe`) because the bridge exposes only granular keyframe ops - add a
        single `set_animation` bridge op.
    - All Retime specific's are to be implemented later, currently it should behave and have exact parity
        as all other properties in graph view, same value/speed graph etc. Nothing extra
    - **Value-key marquee multi-select** (single-key selection landed).
    - Currently marquee/selection box for dragging doesn't happen in flutter ui, needs adding
    - **Effect-param interpolation menu** on the fx keyframe lane
        (`setEffectParamKeyframeInterp` op exists; the menu does not).

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
        volume, beat detection) works; there is no UI for it.
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