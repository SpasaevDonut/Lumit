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
- **The macOS/iOS podspecs are untested** (no target yet, K-033) and named
    `rust_lib_lumit_flutter.podspec` while the plugin's pubspec name is
    `lumit_bridge`; check what CocoaPods resolution requires before renaming.

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
- **No disk frame cache** (docs/06 §5.4): the VRAM tier landed 2026-07-27
    (K-187) and the RAM tier exists, but nothing persists across sessions and
    the design language's steel blue for "on disk only" still has nothing
    behind it ([15-DESIGN.md](15-DESIGN.md) §6.3).
- **The shared-texture chain has no keyed mutex** (a torn frame is possible in
    principle — see the fence entry under Threading), and the D3D12 → D3D11
    legacy-handle hop the Windows path rides is knowledge docs/06 does not yet
    describe.
- **The Scopes' trace still crosses the bridge as pixels**, serialised a byte at
    a time like any other `Vec<u8>`, and is decoded into an image Dart-side. Small
    next to a full frame, but it is on the same per-frame path and could take the
    shared-texture route the Viewer now takes.
- **The matte render-alone pass stays at full comp resolution whatever the
    preview scale** (K-186 records the split): correctness-safe because the
    fragment samples mattes by normalised comp UV, but it is the one composite
    the scale does not shrink — scale it too if it ever shows in a profile.
- **The Linux DMA-BUF path has never run on a Linux machine** (K-033) — it is
    compiled and default-on, so the first Linux run verifies it.
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

- **Panel work left.** The graph editor's speed and time lenses and draggable
    bezier handles; and the Viewer's scale and rotate gizmo handles, motion
    paths, masks and shape tools.

**Shell and onboarding:**
- **The boot splash and a notices feed are not in the frb shell.** The bottom
  status line landed 2026-07-28 (export progress and Cancel, under the dock);
  what remains is the boot splash and a general notices channel for it to show —
  the engine currently has no notice stream, only `boot_log`.
- **Pop-out panel windows are removed** (K-182): the ported-but-never-wired
  subsystem (`lib/popout/`, the `desktop_multi_window` plugin, the dock's
  pop-out chrome) shipped ~500 unreachable lines. Rebuild from git history
  (`flutter-frontend-alternative`, pre-K-182) when pop-out is actually wanted,
  and land it wired end to end.
- **Workspace presets** - only the single default layout exists; the four shipped
presets (Edit/Effects/Colour/Audio) are not built ([07-UI-SPEC.md](07-UI-SPEC.md) §1.6).
- **First-run setup screen** (Vegas/AE preference primer, K-006) - absent
([07-UI-SPEC.md](07-UI-SPEC.md) §13.1).
- **Command palette** - only the Commands category; Effects/Comps/Panels
categories, recent-first ranking, and taught-shortcut hints are not built (§12).

**Timeline Panel**
- **Graph editor / Lane Editor / keyframes ([04-RETIMING.md](04-RETIMING.md), archive/flutter-port/06 §C):**
    - Re-introduce ability to move layer before comp start
    - Re-introduce ability to drag start/end of layer to adjust/crop length
    - All Retime specific's are to be implemented later, currently it should behave and have exact parity
        as all other properties in graph view, same value/speed graph etc. Nothing extra
    - Currently marquee/selection box for dragging doesn't happen in flutter ui, needs adding
    - **Effect-param interpolation menu** on the fx keyframe lane.

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

**Bridge reads left outside the read model (K-184)** — deliberate and small:
the Source card's text/camera fields for the one selected layer, the Viewer's
missing-file probe, and the marker/work-area reads on a Timeline rebuild. Fold
any of these into `BridgeLayerInfo`/`BridgeCompModel` if they ever show up in
the budget ranking (`bridge_call_budget_test.dart` prints it).
- **`LumitAppNew` rebuilds the whole app on any `LumitUiState.notifyListeners`**
    (a `ListenableBuilder` above everything), and un-scoped document changes do
    the same via `LumitState`. Reads are nearly free now (K-184), but the
    widget-tree rebuild itself is not. Scope it.

**The RAM frame cache is now only the scope path's cache (K-183, narrowed by
K-187).** The zero-copy transport keeps no CPU bytes, so `framecache` is filled
only by scope traces; what serves the Viewer is the VRAM final-frame cache
(K-187, "cache on the card"), which the cache bar merges into its answer.
`framecache`'s content-keying upgrade (K-178's design, needs the probe view)
remains worthwhile but is now much lower stakes. Registering a texture still
cannot happen in a widget test; `integration_test/shared_texture_test.dart`
(run by hand on a real window) is the coverage.

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
15 ms — the tokens only mean something once renders leave that thread); pre-roll
before the audio stream starts (§5); and §6's real-window benches (A/V drift
over 10 minutes, the underrun ladder). Re-run
`integration_test/playback_bench_test.dart` to price the stack: the serial loop
measured 58.7 fps on 1080p60 footage just before the ring landed.

**Viewer / comp rendering (gated on the F2 comp-render path):**
- Transform gizmo and motion paths ([07-UI-SPEC.md](07-UI-SPEC.md) §2.3-§2.4);
    timeline razor/clip editing and overrun hatching surface here too.

**Settings pages not built ([07-UI-SPEC.md](07-UI-SPEC.md) §15):**
- Keymap editor (the `lumit-keymap` model was deleted unused in K-182; restore
    it from git history when the editor is actually built); colour-management
    settings; preview-mode (Cached/Realtime) toggle; CUDA on/off;
    plugins/decoder page.
- The egui shell's fuller Performance/General/Export pages are not rebuilt in
    Flutter yet: the disk cache budget and root folder (the tier itself is
    unbuilt), autosave interval/keep, and the export defaults (preset +
    filename template). The RAM and VRAM cache budgets landed in the Settings
    window (K-187); idle background fill landed with no setting (it costs
    nothing the user would trade). Each remaining page lands wired to the
    engine through the bridge, not as a Dart-side setting nothing reads
    (K-181/K-182).

**Threading / platform:**
- **Move footage probing off-thread** - synchronous today; needs a probe worker
    drained on `lumit_bridge_snapshot` plus a synchronous `ensure_probed` fallback
    for consumers that read the cache synchronously (`convert_to_sequenced`,
    `trim_to_source_end`, `add_footage_layer`, relink). (archive/flutter-port/06 §B)
- **Move beat detection off-thread** - `detect_beats` blocks; a start/poll pair like
    export is the fix. (archive/flutter-port/06 §A)
**Shared-texture producer/consumer fence** - only if the owner's live run shows
    tearing; verify on the machine first. (archive/flutter-port/06 §B)
**Linux packaging** - the flatpak shipped the egui `lumit-app` binary and was
    retired with it (K-182); the Flutter Linux build needs its own packaging
    when a Linux release matters.
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
    image-sequence footage; the VRAM cache tier + resource governor;
    ProRes/DNxHR intermediate export (v1 is H.264/HEVC only); the 8-/32-bpc
    working-depth switch (v1 is fp16 only); OCI0 v2 colour management and the
    colour-management UI.

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
- **Platform.** The macOS pass (native menu bar, Metal/VideoToolbox,
    notarisation, K-033) — which since K-183 must include a Metal/IOSurface
    zero-copy Viewer path, because macOS has no Viewer picture without one.
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

- **Rotation gizmo affordance** - egui never offered one; not a regression.
- The two recorded behavioural deviations (export queue-snapshot timing;
    share-export VBR cap) - see [02-DECISIONS.md](02-DECISIONS.md).