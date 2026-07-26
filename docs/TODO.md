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

- **Migrate to [flutter_rust_bridge](https://github.com/fzyzcjy/flutter_rust_bridge) —
    the frontend's main line of work.** Started; both bridges are live side by side.

    *Where it stands.* `crates/lumit-bridge/src/api/` holds the frb surface and
    `flutter_ui/lib/src/rust/` its generated bindings, built through cargokit
    (`flutter_ui/rust_builder/`). The v0 hand-rolled bridge is untouched and still
    fully exported — `src/ffi.rs`, ABI v11, 110 `extern "C"` functions — so every
    shipping panel keeps working while the port proceeds. `main.dart` boots
    `LumitAppNew`, the frb shell; `LumitApp`/`LumitShell` is the v0 shell the
    ~11k-line Dart suite exercises. Regenerate with
    `flutter_rust_bridge_codegen generate` from `flutter_ui/` after any `api`
    change (config in `flutter_ui/flutter_rust_bridge.yaml`).

    *The design to follow*, set by the three worked examples — `panels_frb.dart`,
    `project_panel_frb.dart`, `menu_bar_frb.dart` — and the reason this is a
    rewrite rather than a transliteration: **the reference types are the
    identity.** v0 shipped one big `snapshot()` JSON blob that Dart mirrored into
    `BridgeItem`/`BridgeLayer` classes and re-read wholesale on every change, then
    addressed edits by UUID string. frb instead hands Dart opaque
    `ProjectReference`/`CompositionReference`/`LayerReference`/`ItemReference`
    handles with methods on them, so there is no snapshot to diff, no mirror class
    to keep in step, and no id lookup. Ops become methods on the thing they act
    on (`layer.rename(name:)`), and `ScopedChange` tells Dart *which* reference
    changed so only that subtree rebuilds — the `item_builder.dart` /
    `layer_builder.dart` seam, which is the point of the exercise and is not yet
    used by the panels.

    *Order of work.* Grow the API until a panel's needs are covered, port that
    panel, delete its v0 path; the Dart suite for that panel is the gate. Roughly
    by dependency:

    1. **Viewer render paths.** Done for the basics: all three publish paths are
        wired (`RenderedDMABuf` / `RenderedSharedTexture` / `RenderedPixels`), so
        the Viewer draws on Windows again. Still outstanding here:
        - **The read-back path costs 8.8 ms per 1080p frame in serialisation
            alone** (37 ms at 4K), because flutter_rust_bridge's SSE codec
            encodes a `Vec<u8>` *one byte at a time* — the generated Rust
            `SseEncode for Vec<u8>` is a per-byte loop, while the Dart side
            already decodes in bulk via `sse_decode_list_prim_u_8_strict`.
            Measured; that is the whole of budget B1 for 1080p before any
            rendering happens. So a Windows build should prefer
            `--features shared-texture` (zero-copy, no pixels cross at all), and
            the read-back is a correctness fallback rather than the fast path.
            Fix properly by getting frb to emit the bulk codec on the Rust side
            too — worth checking whether a bare `Vec<u8>` return rather than a
            struct field is what triggers it — or by moving that call to the DCO
            codec, whose `IntoDart` for `Vec<u8>` is already zero-copy.
        - Bring across what v0 has and the worker lacks: the rendered-frame LRU
            (`framecache`), and a `scale`/`Quality` other than `default()` —
            there is no scale on the frb path at all, so no adaptive resolution
            and no `quality_for`. Then `render_scope`.
        - The worker loop busy-spins on `try_recv()` with an empty
            `process_loop`, so it burns a core continuously — make it block on
            the channel.
    2. **Project panel** — `save_project`, `import_footage`, `new_composition`,
        `delete_item`, `rename_item`, `move_to_root`, `relink`, `thumbnail`,
        plus children/parent on `ItemReference` for the folder tree. Note
        `FootageReference::get_status` probes synchronously on every build, so the
        off-thread probing item under "Threading / platform" lands with this.
    3. **Effect controls** — `BridgeEffectInstance` is the furthest along and the
        most provisional: `get_value`/`set_value` speak only static `f64`, so
        seven of the eight `EffectValue` kinds and every keyframed value are
        unreachable (they answer `None`). Replace the pair with a sum type
        mirroring `EffectValue`, then add `add_effect`, `remove_effect`,
        `reorder_effect`, `set_effect_enabled`, `list_effects` and the presets.
    4. **Transform rows** — `set_transform`, and `preview_transform` /
        `cancel_transform_preview` for the drag path.
    5. **Timeline** — the largest surface: layer lifecycle (add solid/text/camera/
        adjustment/sequence/footage, delete, duplicate, reorder), the switch and
        column ops (`set_layer_switch`, `set_blend_mode`, `set_matte`,
        `set_parent`, `set_motion_blur`, `list_blend_modes`), spans
        (`edit_layer_span`, `drag_boundary`, `trim_to_source_end`,
        `convert_to_sequenced`), the razor, markers, work area, comp settings.
    6. **Keyframes and the graph editor** — the property ops plus their
        effect-param twins. Add the single `set_animation` op noted below rather
        than porting the granular pair.
    7. **Retime, audio, export, then the performance/infra readouts**
        (`cache_stats`, `playback_tier`, `boot_log`, recovery).

    *cargokit is only wired up for two platforms.* The merge adapted
    `rust_builder/linux/CMakeLists.txt` and left every other platform on the frb
    template's values — crate path `rust/`, library `rust_lib_lumit_flutter` —
    so the Windows build failed outright and would not have bundled the `.dll`
    even if it had linked. Windows is fixed and verified; Android and the
    macOS/iOS podspecs are corrected by inspection but **untested** (no target
    yet, K-033). Two things still open there:
    - The podspecs are named `rust_lib_lumit_flutter.podspec` with a matching
      `s.name`, while the plugin's pubspec name is `lumit_bridge`. Check what
      Flutter's CocoaPods resolution actually requires before renaming.
    - **cargokit has no hook for cargo features**, so a Linux developer cannot
      ask `flutter run` for `--features shared-texture-linux` and the zero-copy
      Viewer silently is not in the build. Needs a `cargokit_options.yaml` (or an
      env var read in the CMake) carrying per-platform features.

    *Infrastructure the frb path is missing and v0 had.* Each is a correctness
    gap, not a nicety:
    - **No `catch_unwind`.** Every v0 export wrapped its body so a panic became an
        error reply rather than unwinding across the FFI boundary (`lib.rs`
        "No exported function crosses the C boundary with a panic"). The frb
        surface has no equivalent.
    - **clippy is blind to the frb surface.** `#[frb(...)]` is a proc-macro
        attribute and clippy's restriction lints skip macro-expanded code, so
        `unwrap_used`/`panic`/`todo` do not fire on any annotated function — the
        crate's `deny` silently does not apply to the code Dart calls. Covered for
        now by the `no-panics-in-frb-api` CI grep; the real fix is to stop needing
        it.
    - **No journal or autosave.** `LumitBridgeState.journal` is always `None`, so
        crash recovery does not see work done through frb, and there is no
        `autosave`. v0 appends every commit.
    - **`ScopedChange` is coarse and lossy.** It re-serialises each `Op` to JSON
        and looks for `comp`/`layer` string fields, so every project-level edit
        falls through to "rebuild everything". Match on the `Op` enum instead.
    - **The `PROJECTS`/`STREAMS` global pair** are two `LazyLock<RwLock<BTreeMap>>`
        registries kept apart only by a comment about lock ordering, and
        `ProjectReference::state()` hands the raw `Arc<RwLock<…>>` out.
    - **`DocumentStore::set_callback` takes `&mut self`**, so the observer can only
        be attached before the store is shared — workable, but it means the
        callback cannot be changed or removed for the store's lifetime.

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