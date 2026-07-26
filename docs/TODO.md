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

    **v0 is FROZEN (decided 2026-07-26).** No new ops, no new surface on the
    hand-rolled bridge — every addition goes to `crates/lumit-bridge/src/api/`.
    Nothing is deleted yet, because v0 still runs the whole UI behind
    `--v0-shell` and its Dart suite covers it; it is removed in **one sweep** once
    every panel is on frb. The reason for the freeze: work kept landing in v0
    precisely because v0 was the only shell that could display anything, and that
    produced duplicated capability — ABI 12's `preview_effect_param` went into v0
    even though the frb worker already had `render_comp_with_preview` doing the
    same job by a different idiom. If a task seems to need v0 because only v0 can
    show the result, that is a signal to finish the frb panel first.

    *When the sweep comes* — the easy-to-forget mechanics. Delete together:
    `src/{ffi,state,edits,snapshot,framecache,cancel,render,realtime,export,
    recovery,preset,items,columns,fxkeys,fxparams,retime,sequence,audio,beats,
    assets}.rs`, the `ABI_VERSION` surface, `flutter_ui/lib/bridge/bridge.dart`,
    `state/app_state.dart`, the v0-only panels and their tests, and the
    `--v0-shell` switch in `main.dart`. But:
    - **`media.rs` is not v0.** `MediaCache`, probing and decoding are shared
      infrastructure; `api/footage.rs` calls straight into it. It stays.
    - **Five helpers must MOVE, not die.** The frb side shares them deliberately
      rather than copying: `render::quality_for` (the scale-to-decode-size
      policy, used by `api/worker_thread.rs`), `edits::base_layer` and
      `edits::centred_transform` (both in `api/composition.rs`),
      `edits::fx_category_key` (`api/effect.rs`), `media::thumbnail_from_path`
      (`api/footage.rs`). Plus whatever of `framecache`/`cancel` the frb path
      has adopted by then.
    - **`FootageDragData` stays.** The Timeline's drop target consumes it and
      only the Project panel produces it; changing the payload kills
      drag-to-timeline silently, with nothing to catch it but a test.
    - **`panels/viewer_layer_map.dart` stays.** Pure, unit-tested maths over
      plain doubles — it imports neither bridge and the frb Viewer's gizmo uses
      it as it stands.
    - **`shell/dialogs.dart` stays** until the Timeline and menu bar stop
      reaching for it.
    - **Never needs porting at all:** `free_string`, `free_buffer`, `snapshot`,
      `version` — v0 transport artefacts frb handles structurally.
    - **Already bridge-agnostic, no port needed:** `shell/dock_widget.dart`,
      `shell/splash.dart` (it takes its lines as a parameter — only the
      `boot_log` *source* needs an frb form), `theme/`, `icons/`, `widgets/`.
      Verified: none of them import `bridge/bridge.dart` or `state/app_state.dart`.

    *Where it stands.* `crates/lumit-bridge/src/api/` holds the frb surface and
    `flutter_ui/lib/src/rust/` its generated bindings, built through cargokit
    (`flutter_ui/rust_builder/`). The v0 hand-rolled bridge is untouched and still
    fully exported — `src/ffi.rs`, ABI v12, 107 `extern "C"` functions — so every
    shipping panel keeps working while the port proceeds. `main.dart` boots
    `LumitAppNew`, the frb shell; `LumitApp`/`LumitShell` is the v0 shell the
    ~12,450-line Dart suite exercises. Regenerate with
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

    *What must exist before v0 can be deleted.* Grow the API until a panel's needs
    are covered, port that panel, migrate its tests; the Dart suite for that panel
    is the gate. **All seven panels are ported.** What remains is the shell
    surfaces under 2, the subsystems under 3, and the v0 sweep itself. The full
    ledger:

    **1. The seven docked panels.**
    - **Viewer** — **partial**: the panel is in (toolbar, magnification, channel
        view, transparency grid, transport, timecode, zoom/pan, the
        missing-media badge, and a move gizmo). Outstanding: the **scale and
        rotate gizmo handles**, **motion paths**, masks and the shape tools, and
        the Viewer-bar items under "Viewer bar" above — guides, region of
        interest, the colour-management indicator and the degradation badge.
    - **Timeline** — **partial**: the panel is in, graph editor included.
        Outstanding: the graph editor's **speed and time lenses** (the same curve
        read a different way — v0's `graph_speed_lens.dart` /
        `graph_time_lens.dart`), and **draggable bezier handles** (the interp
        menu sets the AE presets, which covers the easing most of the time).
    - **Effect controls** — **done**, bar one known limit: a multi-axis row's
        stopwatch keys only its first axis, because x and y animate
        independently in the model and one stopwatch cannot honestly show two
        states. It also has no drop target yet for the effect drag the Effects &
        presets panel produces (`EffectDragData`).

    **2. Shell surfaces** — not panels, but v0-bound. Each of these imports
    `bridge/bridge.dart` or `state/app_state.dart` today.
    - **Popout windows** — the five files under `lib/popout/`. Multi-window, and
        the v0 version has a known main-window resync gap.

    **3. Engine subsystems with no frb API yet.** `ffi.rs` exports 107 `extern "C"`
    functions; `api/` has 74 public functions, a good share of which are handle
    plumbing (`new`, `equals`, id accessors) rather than ops. The Timeline alone
    is comparable to everything ported so far. Grouped by subsystem:
    - **Keyframes** — no ops are needed and none will be added: `set_transform`
        and `set_value` take a whole animation, so every keyframe edit is one
        write and one undo step. v0's granular add/remove/shift/set-interp pair
        and `apply_keyframe_batch` have no frb counterpart by design. Recorded
        here only so nobody ports them; the work left is the graph editor UI.
    - **Sequence layers** — `drag_boundary` and `trim_to_source_end`, the two
        Retime-adjacent clip commands. `convert_to_sequenced` and the razor pair
        are in.
    - **Masks** — `add_mask`, `add_mask_geometry`.
    - **Retime** — all of it: enabled/speed/reverse/interpolation,
        `segment_to_rate`, `set_segment_preset`.
    - **Audio** — all of it: prepare/play/pause/seek/stop/clock, `detect_beats`,
        `clear_beat_markers`.
    - **Export presets** — `export_preset` (the suggested file name a delivery
        preset implies). Start/poll/cancel are in; `export.rs` itself is now
        shared rather than v0-only, since `start_with_document` takes the
        document instead of reading the v0 bridge.
    - **Assets** — `set_solid`, `set_text_content`, `set_camera_zoom`.
    - **Presets** — the preset *listing* (a browsable library of saved
        `.lumfx` files), which was never built on either bridge. Save and load
        are in.
    - **Journalling.** `LumitBridgeState.journal` is still always `None`, so
        edits made through frb are not written to the crash journal as they
        happen — `restore_journal` replays whatever *is* there, but nothing puts
        it there. The autosave and the recovery dialogue are in; this is the leg
        that makes them worth having.
    - **`decode_frame`** — the single-layer decode behind the Viewer's fallback.

    **4. The v0 Dart suite is migrated, not deleted.** 33 files and ~12,450 lines
    under `flutter_ui/test/`. That suite *is* the parity ledger: it is the only
    written record of what the shipping UI actually does. Each panel's port moves
    its tests to `test/frb/` against the real engine (pattern in
    `frb_test_support.dart`), and only then deletes the v0 originals. Deleting
    ahead of the port quietly reduces coverage — which is exactly why the Project
    panel's v0 deletion was held back until its last two tests passed.

    **5. Panel-by-panel notes.**

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
        - `render_scope`, which the Scopes panel is waiting on. **Done:** the
            worker blocks on its channel instead of busy-spinning, coalesces
            queued requests to the newest, and carries a `scale` from which it
            derives `Quality` through v0's shared `quality_for`. The frame cache
            and quality tier it still lacks are under "Infrastructure the frb
            path is missing" below.
    2. **Project panel — ported, fully tested.** `project_panel_frb.dart` on the
        frb API, all 13 tests passing against the *real* engine (see
        `test/frb/frb_test_support.dart` for why these are integration tests: the
        generated types are concrete, so there is nothing to fake, and adding a
        Dart interface purely to allow faking would reintroduce the mirror-class
        indirection the migration deletes). Outstanding:
        - **Missing status is cached in the panel**, because `getStatus` probes the
            file so cannot be called from a build, and the missing-only filter needs
            every status at once. v0 got status free from the snapshot because the
            engine probed and cached. The cache is now dropped only on an item-list
            change (`ScopedChange.items`), not on every edit, so a layer tweak no
            longer re-probes every file — but the proper fix is still the off-thread
            probing item under "Threading / platform".
        - **Done:** the v0 parts exclusive to it are deleted — `rename_item`,
            `delete_item`, `move_to_root`, `relink` and `thumbnail` from
            `ffi.rs`/`items.rs`/`media.rs`, the v0 `ProjectPanel`, its bindings
            in `bridge.dart`/`app_state.dart`, the thumbnail leg of the
            off-thread renderer seam (`preview_isolate.dart`/`preview_source.dart`
            — its only caller was that panel), and the v0 test groups. The v0
            shell's Project slot is a placeholder now.
            `import_footage`/`new_composition`/`save_project` are shared with the
            menu bar and stayed; so did `media::thumbnail_from_path`.

    3. **Menu bar and shell** — ported and tested (9 tests). `save_project` plus
        the recovery, autosave and export entries;
        `import_footage`/`new_composition` already existed on `ProjectReference`.
        `showCompositionSettingsDialog` gained its frb form
        (`shell/comp_settings_frb.dart`), which also restored the Project panel's
        context-menu entry.
    4. **Effect controls** — the Rust surface is in. `get_value`/`set_value` speak
        `BridgeEffectValue`, a sum type mirroring `EffectValue`: all eight kinds,
        and a keyframed value carries its keys (exact rational times, per-side
        easing) rather than collapsing to a number, so reading then writing leaves
        the document untouched. `add_effect`, `remove_effect`, `reorder_effect`,
        `set_effect_enabled` and `set_effects` (the mouse-up commit for a staged
        stack) are on `LayerReference`, one `SetLayerEffects` each; `list_effects`
        is a free function, and `list_parameters` hands over the *schema* each
        row is drawn from — labels, slider and hard ranges, choice options, file
        filters — which the panel needed and nothing had exposed. The staging
        path is now proven by a real panel: it holds its own stack copy, renders
        it through `render_frame_with_preview` while the pointer is down, and
        commits once on release, so nothing engine-side has to stage.
        Outstanding: the effect-param keyframe ops and the `.lumfx` presets.

    5. **Transform** — `get_transform` / `set_transform` on `LayerReference`, one
        `SetTransformProperty` op per property so each nudge is exactly one undo
        step. The drag preview reuses the effect path rather than growing its own
        worker message: `RenderCompRequestWithPreview` now carries an optional
        effects list *and* an optional transform, so v0's separate
        `preview_transform`/`cancel_transform_preview` pair has no frb
        counterpart and needs none. `is_three_d` came with it — a reader only;
        the switch's toggle is still a Timeline op.

    Everything after that is grouped by subsystem under **3** above rather than
    ordered here, because the dependencies are between *ops* and *panels* rather
    than between panels: the Timeline needs layer lifecycle, properties, spans and
    markers; the graph editor needs the keyframe ops; Transform rows need
    `set_transform` and its preview pair.

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
    - **No frame cache.** v0 has `framecache`, an LRU of rendered frames; the frb
        worker has none, so every return to a frame re-renders it.
    - **No adaptive quality tier** (K-171). The frb scale tracks the Viewer's
        panel size only, where v0's `effectivePreviewScale` also folds in measured
        render cost via `realtime::observe` — so a comp too heavy to render at
        panel size does not degrade, it just renders slowly.
    - **No cancel generation on the render path.** Settled as unnecessary given
        the worker's queue coalescing, but re-check it if the worker ever becomes
        multi-threaded.
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