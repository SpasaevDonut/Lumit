# Kiriko decision log

**Status: canonical.** Numbered, append-only. Every entry is either **DECIDED** (locked by
the project owner) or **PROPOSED** (a strong default chosen during the July 2026 design sessions; veto by
editing the entry and noting why). Reversing a DECIDED entry requires a new entry that
supersedes it — never edit history.

**How to use this log:** it is a long reference, not a start-of-task read. Don't read it end to end - search it for the entries relevant to your task (by topic keyword, or by the `k-###` numbers the relevant spec cites) and read those. Where two entries conflict, the later one that says it supersedes the earlier wins.

Format: ID · status · decision · rationale · consequences.

---

## Product

**K-001 · DECIDED · Kiriko is a native Windows application, developed cross-platform.**
Ships and is optimised for Windows; the Rust/wgpu stack (K-010) means the app also runs on
macOS during development so the window can be watched while building. macOS/Linux releases are
a possibility, never a priority.

**K-002 · DECIDED · Primary audience: flow / MVM-style gaming editors first; full AE
replacement over time.** Clarified 2026-07-12: the target lane is the smooth, cinematic
style (the CoD movie-making "MVM" lineage and today's flow style — the project owner's own
lane, per editors like stooh and starkerr), not classic kill-montage editing. This style is
compositing and animation as much as cutting. v1 milestone: a flow-style edit can be
completed start-to-finish in Kiriko (import high-fps captures, cut against the music with
beat markers, speed ramping with optical-flow slow motion, a smooth 2.5D camera move, a
masked transition, shake/glow/motion-blur/grade, export for YouTube). Long-term: Kiriko's
own version of everything After Effects has. Consequence: graph-editor ergonomics, masking,
and a basic camera join the v1 path ([16-ROADMAP.md](16-ROADMAP.md)); the effect staples of
K-064 are unchanged. Roadmap gates are phrased as "can a flow-style editor do X yet".

**K-003 · DECIDED · Licence: GPLv3.** Community contributions welcome; forks must stay open;
official binaries may still be sold later. LICENSE file at repo root.

**K-004 · DECIDED · Dark-first Aizome design.** Kiriko uses a dark-native variant of the
household Aizome design language: near-neutral dark panels (colour-grading accuracy), clay as
the single accent, hairline borders, household type stack. Recorded as a deliberate deviation
from the paper-light household default. Light mode is documented as a later option.
Spec: [15-DESIGN.md](15-DESIGN.md).

**K-005 · PROPOSED · Voice: en-GB, sentence case, calm, no exclamation marks** — in docs and
UI copy, per the household mandate. UI strings go through an i18n table from day one so this
is cheap to revisit.

**K-006 · DECIDED · Migration-aware first run.** On first launch, one skippable screen asks
which tools the user comes from (Vegas for ramps+effects / Vegas ramps + AE effects / AE for
both / neither) and tunes defaults accordingly — chiefly the Retime graph lens (speed vs
value), keymap preset offer, and which mapping tips show. One screen only, re-runnable from
the command palette, every setting individually changeable. Added 2026-07-12 at Mack's
request; post-v1 polish. Spec: [07-UI-SPEC.md](07-UI-SPEC.md) §13.1.

## Core model

**K-007 · DECIDED · Docs stay owner-readable; regression coverage is near-full.** All
documentation must remain understandable to the project owner (expert editor, new to Rust
and systems concepts): [GUIDE.md](GUIDE.md) is the plain-English companion, updated in the
same commit as any new concept. Testing policy: every feature ships with tests, every bug
fix ships with a regression test, CI enforces fmt/clippy/tests on macOS + Windows plus an
engine-crate coverage gate whose threshold may rise but never fall, and a design-token
lint. Added 2026-07-13 at Mack's request. Spec: [14-ENGINEERING-RULES.md](14-ENGINEERING-RULES.md).

**K-008 · DECIDED · Brand mark and boot splash.** The mark is an Edo-kiriko faceted glass
hexagon whose clay facets form a K (assets/brand/; construction and colour constants in
[15-DESIGN.md](15-DESIGN.md) §brand). Boot shows a small centred splash listing each module
and effect as it initialises (the boot log — real registry plumbing that grows with the
effect suite and OFX scanning), minimum ~1 s dwell, failure lines in kraft. Added
2026-07-13 at Mack's request.

**K-020 · DECIDED · Layer-based model with a Sequence layer type.** Ordinary layers stay 1:1
with a source, as in AE. A dedicated **Sequence layer** holds clips cut back-to-back on one
row — the Vegas-style surface. This was chosen over (a) making every layer multi-clip and
(b) a Resolve-style dual-mode timeline.

**K-021 · DECIDED · One retiming system ("Retime") with two graph views.** Stored as retime
segments per clip (Sequence layers) or per layer (Footage layers); edited through the value
graph (AE-style) or the speed graph (Vegas-style semantics, drawn in the graph editor below
the value view — never overlaid on the clip like Vegas). Spec: [04-RETIMING.md](04-RETIMING.md).

**K-022 · DECIDED · Retime edits never move clip boundaries ("the beat-sync covenant").**
When a retime runs out of source media, Kiriko holds the boundary frame and draws an explicit
overrun indicator; an explicit "trim to source end" command exists. No auto-ripple, ever.

**K-023 · DECIDED · 2.5D now, deeper 3D later.** v1 core: 3D layer transforms, cameras,
depth-of-field, basic lights (AE-style 2.5D). All transform maths is 4×4 from day one. The
long-term ambition (working "directly in 3D", importing Blender scenes) is tracked in the
roadmap as a post-parity phase; nothing in the core data model may preclude it.

**K-024 · DECIDED · Non-destructive always.** Nothing the user does modifies source media or
bakes irreversibly into the project. Baking/flattening exists only inside the export pipeline
(and internal caches), invisible to the project document.

**K-025 · PROPOSED · Keyframe maths is AE-compatible.** Bezier keyframes carry per-side speed
(units/sec) and influence (0.1–100%), hold and linear modes, spatial beziers with roving
keyframes. Rationale: lossless AE import (K-060) and zero relearning for the target audience.

**K-026 · PROPOSED · Per-comp colour bit depth (fp16 default, fp32 opt-in)** rather than AE's
project-global bit depth. Working space is scene-linear, premultiplied alpha.

## Architecture

**K-010 · DECIDED · Language: Rust.** Memory/thread safety is the best structural defence for
the never-crash requirement; ecosystem proven by Rerun, Gyroflow, Cap. C ABI interop covers
ffmpeg, OFX, CUDA.

**K-011 · DECIDED · GPU: wgpu** (DX12 backend on Windows, Metal on macOS). First-party
effects written in WGSL compute so NVIDIA and AMD both get acceleration without vendor lock.

**K-012 · DECIDED · UI: egui** (+ egui_dock/egui_tiles, winit, AccessKit), Rerun-style: a
custom wgpu renderer for the Viewer inside an egui panel shell. Known risk: text polish and
timeline-scale widget performance; the crate split must keep the UI layer swappable
(escape hatches: GPUI, Qt shell).

**K-013 · PROPOSED · Media I/O: ffmpeg via rsmpeg**; hardware decode via D3D11/12VA (and
VideoToolbox on the dev Mac) with one GPU→GPU copy into wgpu at v1; NVENC/AMF/QSV encode via
ffmpeg. Audio: cpal, audio-clock-master sync.

**K-014 · PROPOSED · CUDA is an optional per-node accelerator, not a pipeline.** The one
portable compute path is WGSL/DX12. CUDA (via cudarc + Vulkan interop) may accelerate specific
heavy nodes (optical flow) where measured wins justify it. Never a hard requirement.

**K-015 · PROPOSED · Layers in the UI, DAG underneath.** The layer stack compiles to an
immutable, content-hashed evaluation graph; Nuke-style split of a cheap metadata pass from a
cancellable pixel pass. Spec: [05-ARCHITECTURE.md](05-ARCHITECTURE.md),
[06-RENDER-PIPELINE.md](06-RENDER-PIPELINE.md).

**K-016 · PROPOSED · Three-tier content-hash cache** (VRAM → RAM → disk), keyed by
hash(node id+version, params, time, quality, input hashes) — never by timeline position.
Idle-time background rendering fills the timeline cache bar.

**K-017 · PROPOSED · The UI thread never evaluates anything.** Work-stealing job pool,
dedicated decode/IO/audio/GPU-submit threads, epoch-based cancellation on scrub,
latest-wins progressive previews.

**K-018 · PROPOSED · Degrade, never crash.** A central resource governor with an explicit
degradation ladder (pause background render → evict cache → drop preview res → tile → CPU
fallback); GPU device-loss is treated as routine and recovered; operation-journal autosave.
Spec: [13-PERFORMANCE-RULES.md](13-PERFORMANCE-RULES.md).

**K-019 · PROPOSED · Minimum spec: Windows 10 20H2+, any DX12-capable GPU, 16 GB RAM
recommended.** CPU-only operation must work (slowly) for every built-in effect: each WGSL
effect ships a CPU reference implementation, which doubles as its test oracle.

**K-033 · DECIDED · Metal/macOS is a supported future target, already carried by the
architecture.** The wgpu pipeline (K-011) compiles WGSL to Metal today — macOS builds run
the full compositing path natively on Apple GPUs with no separate render backend. A proper
Mac *release* (post-v1, demand-driven; refines K-001's "possibility, never a priority")
additionally needs: VideoToolbox hardware decode/encode promoted from dev-convenience to
first-class (zero-copy via IOSurface, [impl/media-io.md](impl/media-io.md) §4), ProRes
workflows (Mac editors' mezzanine norm), the Metal branch of the OFX 1.5 GPU render suite
([12-PLUGINS.md](12-PLUGINS.md) §2.4), and a notarised universal binary. Nothing in the
engine may assume DX12-only. Added 2026-07-13 at Mack's request.

**K-035 · DECIDED · Every effect gets a built-in strength matte.** Any effect instance can
select a per-pixel strength source — the layer's own masks or any other layer (same
dropdown model as layer mattes) — scaling the effect's influence at each pixel. The host
implements it once, uniformly: for colour-type effects as a per-pixel mix between input
and effected image; for warp/distort-type effects by scaling the displacement field where
the effect declares vector output (falling back to output-mix otherwise). No effect
author writes masking code; it composes with everything. AE needs per-effect "composite
on original"/precomp workarounds for this. Lands with the effect suite (phase 3). Added
2026-07-13 at Mack's request. Spec: [08-EFFECTS.md](08-EFFECTS.md) §effect model.

**K-036 · DECIDED · A node view is a planned lens over the evaluation graph.** Kiriko's
layer stack already compiles to a DAG (K-015), so a Nuke-style node editor is a *view*,
not a second engine: post-parity (phase 6 alongside the 3D ambitions), Kiriko exposes the
graph for node-based compositing, starting where nodes earn their keep first — a
Resolve-style grading node chain in the Colour workspace. Layers and nodes stay two lenses
on one document; neither is a mode you convert into. Added 2026-07-13 at Mack's request.

**K-037 · DECIDED · Share export: size-targeted clips for the community workflow.**
Editors share previews (usually Discord, 50 MB free-tier cap): a one-click export mode
takes the active playback area (work area; whole comp until it exists), computes the
bitrate from the size budget ((target bytes × 8 ÷ duration) less audio/container
overhead), optionally caps resolution, and writes a compressed H.264 clip. Presets:
Discord 50 MB (default), 10 MB, custom size, plus a quality-first slider for people who
prefer choosing compression over size. Added 2026-07-13 at Mack's request. Spec:
export sections of [06-RENDER-PIPELINE.md](06-RENDER-PIPELINE.md)/[07-UI-SPEC.md](07-UI-SPEC.md).

**K-034 · DECIDED · Perceptual colour operations happen in Oklab.** Two colour domains,
each doing the job it is correct for: **linear RGB** remains the compositing/working space
(light adds physically there — blending, exposure, glow are correct and stay put), while
**interpolation and hue-type operations** — gradient ramps, colour-property keyframe
interpolation, hue rotation, saturation adjustments — convert through **Oklab/OkLCh** so
gradients between two colours stay colourful instead of collapsing to grey, and altering
hue genuinely preserves perceived lightness. Users interact in ordinary RGB throughout;
conversion is engine-internal and cheap (two 3×3 matrices + three cube roots per
direction, identical constants in the Rust CPU reference and the WGSL snippet, guarded by
round-trip and hue-invariance tests). Effects declare which domain each parameter's maths
runs in ([08-EFFECTS.md](08-EFFECTS.md)). Added 2026-07-13 at Mack's request. Spec:
[06-RENDER-PIPELINE.md](06-RENDER-PIPELINE.md) §3.

**K-031 · DECIDED · Colour spaces are selectable; preview always matches export.** Working
colour space is selectable per comp (with app-level defaults, and OCIO joining post-v1 per
06), like AE — but with a hard parity guarantee: **what the Viewer shows at Full resolution
and full quality is bit-identical to what export produces** through the same transforms.
Export-only settings (encoder, bitrate, container, subsampling to 8/10-bit) sit strictly
after the parity point. Adaptive degradation and Realtime mode affect interaction only and
are always visibly indicated. Added 2026-07-12 at Mack's request. Spec:
[06-RENDER-PIPELINE.md](06-RENDER-PIPELINE.md) §3.

**K-032 · DECIDED · Resource and export controls are explicit settings.** RAM/VRAM budgets,
CUDA on/off, decoder pool, worker caps, cache root/size in Settings → Performance/Cache;
export dialogue exposes full custom controls (resolution, frame rate, format, codec,
encoder choice, rate control, audio, thread count and a background/balanced/fast priority)
alongside presets — and exporting never blocks editing (06 §7.1). Added 2026-07-12 at
Mack's request. Spec: [07-UI-SPEC.md](07-UI-SPEC.md) §Settings inventory.

**K-030 · DECIDED · Two preview modes: Cached (default) and Realtime-adaptive.** Cached
plays at full chosen quality from the render-ahead ring and cache. Realtime never waits:
every frame renders live at whatever resolution tier sustains the comp frame rate, adjusted
continuously with hysteresis — judge motion now at reduced resolution rather than full
quality after a wait. Clarified same day: the mode toggle is a **separate control** from
the Viewer bar's resolution picker (Full/Half/Third/Quarter/Auto) — it lives in the
transport and Settings → Preview, never in the resolution dropdown, and Cached always
honours the picked resolution. Added 2026-07-12 at Mack's request. Spec:
[06-RENDER-PIPELINE.md](06-RENDER-PIPELINE.md) §6.5.

## Persistence

**K-040 · DECIDED · Project file: hybrid container.** A single `.kir` file — a zip holding
a human-readable, versioned `project.json` plus small embedded assets (thumbnails, curve
data). Footage referenced by path with relink logic. Caches, proxies, and exports live in a
sidecar folder, deletable at any time. Autosave is journalled. Spec:
[10-FILE-FORMAT.md](10-FILE-FORMAT.md).

## Audio

**K-050 · DECIDED · v1 audio is a sync toolkit; the Composer comes later.** v1: import,
sample-accurate playback, timeline waveforms, manual + automatic beat markers, volume
keyframes, mute/solo, multiple audio layers per comp. Later: the **Composer** workspace —
sound design against the edit inside Kiriko (multiple sounds per layer, so editors stop
round-tripping to Vegas for audio). Spec: [09-AUDIO.md](09-AUDIO.md).

## Extensibility and interop

**K-060 · DECIDED · AE project import via an exporter panel, parser as best-effort backup.**
Primary: a free ExtendScript/CEP panel running inside After Effects that walks the scripting
DOM and emits Kiriko-schema JSON (comps, layers, transforms, keyframes with bezier params,
masks, mattes, retime, expression text, effect match-names). Secondary: best-effort direct
`.aep` (RIFX) parsing, structure only, no fidelity promises. Third-party AE effect internals
never map; they import as inert placeholders. Spec: [11-AE-IMPORT.md](11-AE-IMPORT.md).

**K-061 · PROPOSED · Kiriko is an OFX host.** OpenFX is BSD-3/open; Twixtor, RSMB, Sapphire
ship OFX builds already proven in Vegas/Resolve. This is the legal, practical route to the
gaming-edit plugin staples. Native `.aex` AE plugins will never load (technically and legally
infeasible — see research).

**K-062 · PROPOSED · Native plugin API "KFX": CLAP-shaped.** Stable C ABI core + versioned
typed extensions, host-owned animated parameters, out-of-process sandboxed execution with
shared-memory/shared-texture frames, MIT-licensed headers + a validator tool. Plugins ship
after the main application, but every engine interface is designed against KFX from day one.

**K-063 · PROPOSED · Expressions: JavaScript on QuickJS-ng**, exposing the AE expression
surface (`wiggle`, `loopOut`, `valueAtTime`, `time`, `seedRandom`, …) at ES2018 level, fully
deterministic (seeded random, no Date/IO/JIT variance) so distributed/export renders agree.

**K-064 · PROPOSED · Built-in effect suite covers the montage staples in-box** — optical-flow
retiming (Twixtor-class), optical-flow motion blur (RSMB-class), exposure-aware glow
(Deep Glow-class), parameterised camera shake, smooth-zoom presets, RGB split, flash/strobe,
colour grading with preset browser — so a new editor needs zero third-party plugins for the
core genre look. Spec: [08-EFFECTS.md](08-EFFECTS.md).

**K-065 · PROPOSED · Preset and project sharing is a first-class feature** (import/export of
presets and template projects), because shared project files and CC packs are how the montage
scene onboards. Nothing in the file format may make shared projects machine-specific.

**K-066 · DECIDED · Every plugin supports every colour depth and multi-frame rendering.**
KFX plugins MUST process fp16 and fp32 correctly (validator-enforced at both depths) and
MUST tolerate frames rendering in parallel, out of order, on any thread — the host renders
frame-parallel by default through instance pooling, and `kfx.thread-unsafe` is the sole,
discouraged opt-out. **The host owns the optimisation strategy**: instance counts and frame
scheduling are decided from declared traits plus measured cost under the governor's
budgets, exactly as for built-in nodes. OFX plugins are scheduled per their declared
render-thread-safety, with the host converting depth at the boundary. Added 2026-07-12 at
Mack's request. Spec: [12-PLUGINS.md](12-PLUGINS.md) §2.3, §3.3–3.4.

**K-067 · DECIDED · The engine's pillars carry Edo-kiriko craft names.** The render
pipeline as a whole — evaluation graph, GPU compositor, colour engine — is **Togi**
(研ぎ, the polishing stage that turns cut glass brilliant: it turns the project's cuts
into the picture). The three-tier cache is **Kura** (蔵, the storehouse). The audio
engine and master clock is **Hibiki** (響, resonance — everything syncs to it). The
names appear in user-facing surfaces (boot splash, settings, docs, marketing); crate
names stay `kiriko-*` and code identifiers stay plain English per the glossary. Future
subsystem names come from the same craft vocabulary and are logged here. Added
2026-07-13 at Mack's request.

**K-068 · DECIDED · AE-style Project panel with auto-filing and the composition
dialogue.** The Project panel is info-header-plus-tree: the selected item's details at
the top, the folder tree below, and everything moves by drag and drop — rows drag onto
folders to file them, onto the Timeline or Viewer to become layers (the "Add to comp"
buttons are gone). Solids are assets (`SolidDef`, per 03-DATA-MODEL §2): the first solid
creates a "Solids" folder and later ones follow it *by id* — renaming or nesting the
folder keeps the habit; deleting it just recreates it on next use. Compositions auto-file
the same way into "Compositions". Manual comp creation always shows the settings dialogue
(name, size, frame rate, duration); dropping footage with no comp open shows it
pre-filled from that footage; comps created implicitly inside an active comp (future
precompose) inherit the parent's settings silently; settings stay editable later
(Composition settings…, one invertible op). Multi-step creations commit as one
`Op::Batch` — one undo step. Added 2026-07-13 at Mack's request.

**K-069 · DECIDED · Working depth is one project-wide switch.** Supersedes the
per-comp fp32 opt-in in K-026. The project renders everything — comps, effects,
inter-node buffers — at a single depth: 8 bpc integer, 16 bpc float (default), or
32 bpc float. No per-comp override; switching the project switches everything (the AE
project-bit-depth model, which editors already understand). The control is a small
depth button at the foot of the Project panel; Application Settings holds only the
default for new projects. Kernel-internal accumulators may exceed the project depth
where the algorithm needs it, but node inputs/outputs never do. Depth remains part of
the cache key's quality field. Implementation lands with the depth-aware pipeline work
in the effects phase; until then 16 bpc float is the only rendering depth. Decided
2026-07-13 at Mack's request. Spec: [06-RENDER-PIPELINE.md](06-RENDER-PIPELINE.md) §3.1.

**K-070 · DECIDED · The graph editor is a general derivative-lens editor, in the
Timeline.** Three points from Mack (2026-07-13):

1. **Derivative lenses for every animatable property.** The value/speed views of §5.1
   generalise: any property (transform, effect parameter, mask, retime) can be viewed and
   edited as its **value**, its **speed** (first derivative), or its **acceleration**
   (second derivative) — the distance/velocity/acceleration analogy. Acceleration joins
   value and speed as a first-class lens (extends [07-UI-SPEC.md](07-UI-SPEC.md) §5.1). All
   three are views of the one keyframe/segment store; editing any of them round-trips
   losslessly. The lens-switch controls are **glyphs in the bottom-right of the graph
   editor** (alongside the ease-preset footer of §5.3). Retime's value/speed lenses (§5.2,
   [04-RETIMING.md](04-RETIMING.md) §9) are the retime-specific instance of this system.

2. **The graph editor lives in the Timeline area, not a separate panel** — a mode of the
   Timeline lane area with a header toggle, exactly as [07-UI-SPEC.md](07-UI-SPEC.md) §5
   already specifies. Kiriko's current implementation as a standalone dock tab
   (`Panel::GraphEditor`) is a temporary divergence to be corrected when the lens work
   lands.

3. **Frame-pinning invariant for Vegas-style speed edits (binding).** Changing a segment's
   speed pins the source position at the segment's **start** and ripples the change
   **downstream only** (the §4.1 boundary-consistency recompute already encodes this: sᵢ is
   fixed, sᵢ₊₁… are recomputed). Consequently a clip's first frame is always its own
   trim-in whatever its speed, so splitting a clip and re-speeding the second half never
   moves where it starts — and this holds after the layer's start/in-point is later
   adjusted, because `place` is layer-time and the retime domain is unchanged. Locked by
   `kiriko-core::sequence` tests (`re_speeding_a_cut_clip_keeps_its_start_frame`).

**K-071 · DECIDED · The sequenced layer is single-source, order-preserving, edited in its
own timeline tab.** Refines the Sequence layer (K-020) per Mack (2026-07-13):

- You **convert an imported-footage layer** into a *sequenced layer* (name pending — only
  footage sources qualify). It opens in its **own, visually distinct timeline tab** showing
  a **single row: that one source**. In the parent comp it reads as one layer — **a fancy
  precomp**: comp-level transform/effects/masks apply to its assembled output, and the
  layer's length **tracks the end of the assembled sequence** (the last piece's end).
  Opening it swaps the Timeline into a distinct single-source editing view (a new window/
  tab with a slightly different UI).
- **Single source only, for now.** Every clip in a sequenced layer references the same
  footage item. The general multi-source Vegas assembly (K-020's broader reading) is
  **deferred** and may return.
- **Operations**: cut, delete (with **gaps allowed** — a gap renders transparent), and
  **retime per piece**. **No reordering / "no mixing footage time":** reading the pieces
  left to right, source time never jumps backwards (`source_in` is non-decreasing by
  timeline position). You remove and space pieces; you do not shuffle them.
- **Why the order constraint**: it keeps comp-time -> source-time a clean forward mapping, so
  a **camera tracker** (its own tool, not an effect) can run once on the **full, unaltered,
  un-retimed** footage, and its track then **replays through the cuts and retimes** in the
  comp, linked to the layer. The clip-resolution model (`kiriko-core::sequence`) is exactly
  that mapping. If a track is linked, the ordering restriction may later be relaxed.
- **Invariants (binding for now)**: single source (`sequence::single_source`), source-ordered
  (`sequence::is_source_ordered`), gaps allowed, and the K-070 frame-pinning rule per clip.
- Note: the inline razor shipped this session operates on the general model in the main
  timeline; the dedicated-tab editing surface is the intended home and supersedes it.

**K-072 · DECIDED · Transform property rows: keyframable speed and linked scale.** Detail
for the property-row timeline restructure (07-UI-SPEC §5, K-070), from Mack (2026-07-13):

- **Speed is a keyframable property like any other**, in the regular (layer) timeline view
  as well as the graph view. The Speed row gets a stopwatch; keyframing it builds the
  retime's speed lens (Rate segments between speed keyframes), and its keyframes show as
  glyphs on its own row. A single un-keyframed value stays the constant-speed case.
- **Scale x / y share one row by default, with a ratio lock (default on)** — like the
  composition Size field. Linked: one Scale control edits both, preserving the x:y ratio.
  Unlocking lets you edit x and y separately and **splits them onto two rows**; a relink
  button stays available. **Relinking collapses to a single row and keeps one axis, losing
  the other's independent changes — unless one axis was never changed**, in which case the
  two merge losslessly and keep the ratio.
- Both land with the property-row restructure (each animatable property as its own timeline
  row: left column stopwatch + name + value, track shows its keyframes; clicking a row
  graphs that property). Keyframe-interpolation glyphs (bezier/linear/hold) on each key are
  a later refinement; the near-term requirement is that keyframes are *shown where set*, on
  the property's row rather than the layer bar.
- **Implemented 2026-07-14.** Per-property timeline rows, the Scale ratio lock, and
  keyframable speed (via `Retime::from_speed_keyframes`/`speed_keyframes`) all shipped. Two
  deliberate deviations from the above, both easy to revisit: (a) relinking scale keeps the
  current ratio and loses nothing, rather than discarding an axis — the combined row can
  represent any ratio, so the lossy rule was unnecessary; (b) keyframe-interpolation glyphs
  and live-preview while dragging a *speed* key are still outstanding (speed edits re-decode
  on commit). Clicking a transform property's name graphs it.
- **Speed-lens editing, increment 1 (2026-07-14):** the graph editor's Speed view is now
  editable for transform properties (K-070) — dragging a key's handle sets its bezier tangent
  (both sides), the derivative curve updates live, and the release writes back to the
  keyframes; the derivative you set is the derivative you read back (round-trip test in
  `kiriko-ui`). Still to come (increment 2): Retime wired as its own graph channel whose value
  lens reads the resolved source position as timecode and whose derivative lens reads speed %,
  with a Vegas-editor setting choosing the default lens (K-021).

**K-073 · DECIDED · v1 shell is a fixed native-panel layout, not a dock.** The Viewer is a
bare, full-bleed central area with **no tab bar**; the Project/effects panel (left), Scopes
(right) and Timeline (bottom) are resizable native panels around it. Chosen 2026-07-13 at
Mack's insistence that the viewport carry no "top bit": egui_dock (0.16) draws a tab bar on
every leaf and offers no per-leaf toggle, so the only way to give the Viewer a bare frame was
to leave the docking system. Consequences: egui_dock is dropped as a dependency; drag-to-dock,
tab rearrangement across regions, and floating panels are gone for now; the left panel keeps a
small Project / Effect controls / Effects & presets tab switcher so nothing is lost. Pop-out
returns later as real OS windows (egui viewports), a cleaner pop-out than dock floats. This
supersedes the docking mandate in [07-UI-SPEC.md](07-UI-SPEC.md) §1 for v1, which now documents
the eventual target. The `kiriko-ui` crate must keep the UI layer swappable regardless (K-012).

**K-074 · DECIDED · Dockable tiling shell with a bare Viewer (supersedes K-073).** The
window is a single tiling layout (egui_tiles): every panel except the Viewer carries a
title tab and can be dragged to re-arrange the workspace; the **Viewer alone is a bare pane
with no tab bar** (Mack, 2026-07-14: the viewport must have no top bit). This reverses
K-073's "fixed native panels, no docking" — that was a stopgap taken because egui_dock draws
a tab bar on every leaf; egui_tiles doesn't force a tab on a lone pane, so the Viewer can be
bare *and* the other panels fully dockable. Mechanism: the Viewer is inserted as a direct
child of a linear container (never a tab group) with `all_panes_must_have_tabs = false`;
`prune_single_child_tabs = false` keeps single panels (Timeline, Scopes) showing their tab.
Default layout: an upper band — Project/effect-controls/effects-&-presets tab group (left),
the Viewer (centre), Scopes (right) — above a **full-width Timeline** tab group along the
bottom (the Edit workspace of [07-UI-SPEC.md](07-UI-SPEC.md) §3; the Timeline is a direct
child of the vertical root so it spans the whole window). Pop-out into a panel's **own OS
window** is
implemented: a tab's ⇱ button hides its tile in the dock (`Tiles::set_visible`) and renders
it in an egui immediate viewport; closing that window docks it back. Supersedes the v1-status
note in [07-UI-SPEC.md](07-UI-SPEC.md) §1; keeps the UI layer swappable (K-012).

**K-075 · DECIDED · Retime is a graph-editor channel (footage layers): frame-timecode value
lens, speed-% derivative lens, Vegas default-lens setting; sequence-layer retiming lives in
the sequence view.** Confirmed by Mack (2026-07-14), building on K-021, K-070, K-071, K-072:

- **Footage layers — Retime graphs like any other channel.** A retimed footage layer exposes
  its Retime in the graph editor's left column beside the transform properties, using the same
  two-lens machinery (K-070). The value and derivative lenses are two views of the **one**
  retime store — the segment model of [04-RETIMING.md](04-RETIMING.md) stands; nothing is
  re-stored as keyframes.
  - **Value lens = source position as frame timecode** (`HH:MM:SS:FF` in the footage's own
    timebase) — "which source frame is showing here" — not seconds or a percentage.
    **Derivative lens = speed per cent** (Vegas-style). Editing either writes retime segments
    ([04-RETIMING.md](04-RETIMING.md) §9); switching lenses never converts data.
  - **A Vegas-editor preference picks the default lens.** On → the Speed channel opens to the
    per-cent (derivative) lens; off → the frame-timecode (value) lens. This generalises
    K-021's "opens the speed graph by default" into a user preference.
- **Sequence layers do NOT get an editable Speed channel.** Their retiming is done *inside*
  the sequenced-layer view (K-071): the view shows the single source as a layer you
  cut/splice/move, with an **optional graph pane below it** — the layer stays visible on top,
  so cutting/splicing continues while retiming, and the graph (the regular graph view)
  reflects the sequence's retime, respecting the gaps between pieces. Documented here;
  **implemented later** (a good candidate for a focused `fable` session, per Mack).
- **Increments:** *2a* (now) — footage Retime graphable, both lenses + the setting + the
  correct default lens; *2b* — the full [04-RETIMING.md](04-RETIMING.md) §9.2 in-graph segment
  editing (RateSegment endpoint drags, compensating edits, Rate↔Map conversions); *2c* (later)
  — the sequence-view graph pane.

**K-076 · DECIDED · The Retime graph channel is named by its lens: Time (value) and Velocity
(speed).** Confirmed by Mack (2026-07-14), refining K-075. The Retime channel — its outline
row and its graph — reads **Time** in the value lens (source position, "which frame is
showing") and **Velocity** in the derivative lens (the Vegas velocity-envelope heritage the
speed graph already invokes). This **reverses the glossary §9 "velocity → speed" ban for this
one UI label**: "speed" remains the term for the quantity everywhere else (percentages,
RateSegment speeds, prose, identifiers); "velocity" is permitted solely as this channel's
derivative-lens label. The channel also behaves like any other property — it carries a
stopwatch/keyframe control in the outline — and its **default lens is the value (Time) lens**
(the Vegas-preference of K-075 defaults **off**), so the channel opens to Time.

**K-078 · DECIDED · The Time (value) lens is a fully bezier-keyframed property, identical to
any transform channel.** From Mack (2026-07-14), extending K-025/K-070/K-075/K-076. The Retime
**Time** lens is not a special read-only view: it is the ordinary graph editor — draggable
keys, gold tangent handles, F9 easy-ease, marquee, auto-fit — operating on source position over
local time, exactly like Position or Scale. This is realised by mapping each pair of value
keyframes to a **`MapSegment`** (the AE cubic already specified in K-025): a segment's control
handles are the left key's out-tangent and the right key's in-tangent, using the *same*
control-point construction as `anim::CubicSpan::from_ae`, so a Time curve renders **bit-for-bit**
like the same keys on a transform property (regression-tested). The bridge is
`Retime::from_source_keyframes` (keys → store) and `Retime::source_keyframes` (store → keys).
Consequences and limits, for now:
- A **Linear** side lies on the chord (influence ⅓), matching `anim::side_params`.
- A **Hold** side is treated as Linear — a stepped Time Remap (freeze-then-jump) is future work,
  since a single monotone `MapSegment` cannot express a step while keeping boundary C0 exact.
- A **`RateSegment`** (an eased speed-lens ramp, or the identity store) displays as a straight
  Linear side in the Time lens; dragging any handle there recommits the whole channel as
  `MapSegment`s, so the eased *speed* shaping is replaced by explicit *value* tangents. The two
  native vocabularies (Rate/Vegas vs Map/AE) still don't losslessly interconvert — editing in a
  lens commits in that lens's vocabulary, which is the K-070 model working as intended.
- Source positions round onto the flick grid on commit; local-time boundaries stay exact
  (keyframe times are rational), so the beat-sync covenant (§4/§7) is unaffected.
The "which lens a channel opens to" preference (K-076) stays; per-project lens customisation is
still deferred.

**K-079 · DECIDED · The graph editor pans and zooms; it shares the timeline's time axis and
auto-fits vertically by default.** From Mack (2026-07-15). The curve editor previously mapped x
over the whole comp duration and framed y purely by auto-fit, so neither axis scrolled. Now:
- **Horizontal** follows the shared lane axis (07-UI-SPEC §4): the same pixels-per-second and
  scrolled left edge as the layer bars, so **Alt-wheel** zooms and **Shift/horizontal-wheel**
  scrolls the curve in step with the lanes. (This resolves the standing "share the lanes' zoomed
  time axis" increment.) The value lens draws across the visible window for full resolution when
  zoomed; the Velocity lens keeps a whole-duration axis for now.
- **Vertical** auto-fits the whole curve by default (a bezier overshoot stays on screen). A plain
  wheel over the graph pans the value range and **Ctrl-wheel** zooms it about the cursor, taking
  over with a manual range (`graph_view_y`); a **Fit** button in the bottom bar restores auto-fit.
  The manual range resets when the lens or graphed channel changes. Applies to the value lens
  only.
- **Independent scrolling:** the graph fills the lane area with the layer outline to its left, so
  a wheel over the graph moves the graph while a wheel over the outline scrolls the layer list —
  achieved by zeroing only `smooth_scroll_delta` (which the outline's ScrollArea reads) over the
  graph, leaving `raw_scroll_delta` for the graph. The graph also gets its own vertical scrollbar
  on its right edge when a manual range doesn't cover the whole curve.
Not yet done: relocating the layer list's own built-in scrollbar onto the outline's edge (it
still sits at the far right); that needs a custom outline scrollbar and is deferred.

**K-080 · DECIDED · The speed lens draws the exact derivative of the value bezier.** From Mack
(2026-07-15). The speed (derivative) view sampled its curve by central finite difference at
half-frame steps — a display stopgap that could smear the shape near steep handles. It now uses
`anim::evaluate_speed`, the closed-form `dv/dt = y′(u)/x′(u)` of the value-lens cubic (with the
`x′` floor at a 100%-influence handle), so the speed curve is precisely the slope of what the
value lens draws: bezier easing in the value view shows as the matching smooth speed curve, a
straight span as a flat speed, a Hold as zero. This is the value/speed "two views of one data"
promise (K-070) made exact.

**K-081 · DECIDED · Tangent handles are draggable in the speed lens too.** From Mack
(2026-07-15). The speed (derivative) lens showed one draggable speed point per key; it now also
carries the same gold tangent handles as the value lens for a selected key, so a curve can be
eased from either view. In the speed graph a handle's **height is that side's speed** and its
**horizontal reach is its influence** (After Effects' speed-graph ease bars); dragging writes the
same `SideInterp::Bezier` store through `apply_tangent`, so the value and speed lenses stay in
lock-step. Clicking a speed key selects it (as in the value lens) to reveal its handles. The
value lens keeps the unified partner-length behaviour (K-072 refinement); the speed lens mirrors
a unified drag but keeps the partner's own reach (no screen-length preservation — the speed lens
is about the speeds themselves).

**K-082 · DECIDED · Linux is a supported build target.** From Mack (2026-07-16), after outside
requests to run Kiriko on Linux. Kiriko remains **Windows-first** (that ordering is unchanged);
Linux joins macOS as a supported desktop target: the build must work from a plain
`cargo build` given the platform's usual dependencies, and the README documents them. On Linux
FFmpeg resolves through pkg-config (the same `link_system_ffmpeg` path as macOS), which needs
the **FFmpeg 7.x development packages**, `pkg-config`, and `clang` (for the binding generator).
Known constraint: distributions still shipping FFmpeg 6 (e.g. Ubuntu 24.04 LTS) cannot build
without a newer FFmpeg; that is documented, not worked around. A Linux CI job joins the matrix
when a maintainer can verify it; until then Linux support is best-effort docs + upstream-standard
code (no platform-specific code paths exist today).

**K-083 · DECIDED · The application is named Luminal; subsystems are Nova, Nebula and Pulsar.**
From the owner (2026-07-16). Kiriko is renamed **Luminal** (the owner's handle; of light and of
thresholds) across the entire application: UI strings, all living docs, crate names
(`kiriko-*` → `luminal-*`), the project file extension (`.kir` → `.lum`, safe pre-release with
no files in the wild), the brand asset filenames, and the GitHub repository
(`luminalmvm/Kiriko` → `luminalmvm/Luminal`; old URLs redirect). The K-067 subsystem names are
reversed in the same stroke — the Edo-kiriko craft register no longer fits — and replaced with
an astral register: **Nova** (render pipeline, was Togi), **Nebula** (cache, was Kura),
**Pulsar** (audio engine and its clock, was Hibiki). Historical records (this log's earlier
entries, `docs/research/`) keep the old names verbatim; the hexagon cut-glass mark stays as an
approved placeholder pending a Luminal redesign (noted in 15-DESIGN). The design-language
overhaul that accompanies the rename (rerun-io-style look, colour scheme kept) is its own
follow-up decision.

**K-084 · DECIDED · The visual system adopts rerun.io's structure, keeping Luminal's colours.**
From the owner (2026-07-16), with the K-083 rename. The look moves from the Aizome dark
adaptation's mid-dark ramp to the structure of rerun.io's viewer (`re_ui`, studied at source):
a near-black canvas (`surface_0` `#0b0c0e`), panels one small step above it, floating surfaces
(menus, inputs, tab bars) a clear step up, **borderless widgets** whose idle/hover/pressed
states are fill steps rather than stroke changes, crisp 1 px hairline separations as the only
panel elevation, floats on a real soft shadow (offset 0/15, blur 50), 4 px control / 6 px
float radii, thin solid 6 px scrollbars, 14 px indents and a 16 px interact height. Deliberate
deviations from rerun: the item-spacing grid stays Luminal-dense (6×4, not 8×8 — the timeline's
row pitch is part of the app's feel), and every hue is Luminal's own (clay accent, the cool
grey ramp, the K-004 strictly-neutral Viewer surround, now `#121212`). The accent carries
selection, punchier than before (50% fill). Embedding Inter (rerun's UI face) is a pending
follow-up awaiting the owner's decision on shipping the font file. The owner also wants a
sleeker "liquid glass" alternative theme later; that is not this decision. The hexagon mark
redesign (noted at K-083) remains open.

**K-085 · DECIDED · Icons are the Iconoir set, embedded as an icon font via `iconflow`.**
From the owner (2026-07-16). Reverses 15-DESIGN §5's hand-drawn-only iconography (and its "no
icon font" clause): the hand-drawn glyphs are replaced wholesale by **Iconoir** (MIT), embedded
through the `iconflow` crate (MIT, `pack-iconoir` feature only) as a font whose glyphs render
like text — theme-coloured, resolution-independent. The change also retires every raw Unicode
symbol the UI hoped the fonts carried and didn't (the pop-out `⇱`, the keyframe navigators'
`◄ ◆ ►` — all rendered blank): those are proper icons now (`open-new-window`, `nav-arrow-*`,
`keyframe`/`keyframe-plus`). What stands from §5: monochrome only, theme-coloured, and the
emoji ban — a glyph is from the set or deliberately painter-drawn (track keyframe diamonds),
never a hoped-for font character. A CI test resolves every mapped name against the embedded
pack, so a typo'd icon name cannot ship.

**K-086 · DECIDED · Solo panels render bare; the Timeline pops out from its comp strip.**
From the owner (2026-07-16): the default workspace showed a needless "Timeline" dock tab above
the Timeline's own comp-tab strip, and the only way to lose it was popping the panel out and
back. Now a panel that sits alone in its tile renders with **no tab bar at all** — the bare
look K-074 reserved for the Viewer, extended to every solo pane — and a tab bar appears only
where panels are stacked into a tab group. This partially supersedes K-074's mechanism note:
the dock's simplification sets `prune_single_child_tabs = true`, and because that pass runs on
every draw, a workspace saved under the old rule is tidied the first time it is shown
(single-child tab wrappers are pruned; layouts keep loading and panes keep their sizes).
Consequences: a bare pane has no tab to drag, so it is re-arranged by dropping tabbed panels
onto it (the Viewer's existing behaviour), and it loses the tab's pop-out button. The Timeline
gets a replacement — right-click an empty spot on its comp-tab strip for **Pop out timeline**
(the request travels through `AppState::pop_out_timeline`, consumed by the shell after the
dock draws); other panels pop out via the tab they grow when stacked. The default layout is
unchanged in substance, minus the two single-child tab wrappers (Scopes, Timeline).

**K-087 · DECIDED · The application is named Lumit (was Luminal); the astral register stays.**
From the owner (2026-07-16), same day as K-083. Luminal becomes **Lumit** (from *lumen*)
everywhere living: UI strings, docs, crate names (`luminal-*` → `lumit-*`, binary `lumit.exe`),
brand asset filenames, and the GitHub repository (`luminalmvm/Luminal` → `luminalmvm/Lumit`,
old URLs redirect). Explicitly retained from K-083: the subsystem names **Nova** / **Nebula** /
**Pulsar**, and the `.lum` project extension (it reads even better for Lumit). Historical
records (this log's earlier entries, `docs/research/`) keep their era's names verbatim.

**K-088 · DECIDED · Flow is a per-layer option, not an effect.** From the owner (2026-07-18).
docs/08 §3.1 placed the flow engine (retime interpolation) in the effect tier list; the owner
reverses that: flow is a property of how a footage layer *samples its source*, so it becomes a
**layer option** — a toggle in the layer's switch cluster, and when enabled, a **Flow** group
beside Transform and Effects in the expanded layer carrying its parameters (quality, and the
knobs 08 §3.1 already specifies). It engages only when it can help: when the footage's frame
rate (through any retime) is lower than the composition's, i.e. when the same source frame
would otherwise repeat across two or more comp frames. The frame-interpolation *policy*
storage (Retime.interpolation) remains the underlying model; the option surfaces it. The
"Flow" name stays pending a better one the owner may pick.

**K-089 · DECIDED · The native plugin API is LFX (was KFX).** From the owner (2026-07-18),
following K-087: Kiriko's initial is gone from the app, so it goes from the plugin API too.
`KFX` → `LFX` in every living doc, `EffectNamespace::Kfx` → `Lfx`, the future host crate
`lumit-kfx` → `lumit-lfx`. Historical entries keep the old name.

**K-090 · DECIDED · Effects do one thing; the menu is categorised; ranges may be one-sided.**
From the owner (2026-07-18), amending docs/08:
- **One effect, one job.** Multi-purpose effects split (the v1 Grade becomes separate colour
  effects); an all-in-one Lumetri-style grading suite MAY exist later as a deliberate
  exception, but singleness is the default shape.
- **The Add-effect menu groups by category** (Blur & sharpen, Colour, Distortion, Stylise,
  Temporal, Utility) — schemas carry a category.
- **Hard ranges may be one-sided** (§1.2 amendment): a parameter like a glow threshold clamps
  at zero below and is unbounded above.
- **Quality tiers where physical accuracy is optional**: chromatic aberration gains a
  wavelength-based mode behind a Bool beside its simple RGB-split mode (§3.6); the same
  pattern is welcome elsewhere.
- **Smooth zoom (§3.5) is dropped**; in its place a **Transform effect** — the transform
  properties as an effect — so an adjustment layer can transform everything below it.
- Per-effect bypass next to the name in the effects UI is confirmed as required (§1.5 already
  specifies it; the implementation carries it).

**K-091 · DECIDED · Adjustment layers stage the composite; collapse never bleeds them into
the parent.** The docs/06 §1.5 model is now the running behaviour: everything below a live
adjustment layer composites into an intermediate, the layer's effect stack runs on that, and
the result mixes back over the unprocessed composite by coverage — the mask raster times the
layer opacity, placed by the layer's transform (the coverage map moves; the picture never
does). Two render-semantics points are pinned:
- The mix is a straight per-channel lerp, alpha included, between the unprocessed and
  processed composites. Routing it through the compositor's premultiplied-over would inflate
  alpha wherever the composite is semi-transparent.
- A live adjustment layer inside a *collapsed* Precomp forces the intermediate (§1.4 force
  list). After Effects lets a collapsed precomp's adjustment layers process the parent's
  stack below them; Lumit deliberately diverges — the stack applies within the adjustment
  layer's own comp, always, so precomposing never changes what an adjustment layer sees.

**K-092 · DECIDED · Theme shape, mode and animation level ship as three independent settings.**
From the owner (2026-07-19): alongside the existing dark-ramp picker (`ThemeVariant`), Lumit
gains a light ramp and a second panel geometry, plus a UI-animation-level control — each its
own setting, not one combined picker, all in the Window menu for now (07-UI-SPEC.md §15's
future Settings window is their eventual home).
- **`ThemeMode` (Dark/Light)**: one light ramp (`Theme::light()`), not a light equivalent of
  every dark variant. `ThemeVariant` (Dark/DarkBlue) narrows to "which dark ramp" and is
  meaningless — hidden in the Window menu — under Light. Light mode ships with **one uniform
  panel colour** (white) on a soft neutral canvas; per-panel colour tinting is a wanted, but
  explicitly deferred, future customisation setting.
- **`ThemeShape` (Sharp/Round)**: Sharp is the existing edge-to-edge, hairline-elevated system,
  byte-identical to before. Round is a Figma-UI3-inspired floating-card system — visible gaps
  between panels and from the window edge, rounded corners, a soft shadow standing in for the
  hairline — carried as data (`ShapeTokens`) on `Theme` rather than hardcoded in `apply()`.
  This reverses two prior binding statements *for Round only*, Sharp keeping them as written:
  §7.3's "there are no gaps between docked panels", and §2.3's shadow_float being "permitted
  solely on" floating chrome — Round's ordinary docked cards join that list. Every panel,
  Viewer included, cards identically under Round; no exemption. A stated, permanent v1 limit:
  stacked tab-bar containers stay square-cornered under Round — `egui_tiles` 0.12.0's
  `Behavior` trait has no hook to round a tab bar's own container.
- **`AnimationLevel` (All/Minimal/None)**: a three-tier refinement of the existing
  motion/reduced-motion binary (15-DESIGN.md §8) — `None` is that same reduced-motion behaviour,
  `Minimal` is the new middle tier. Backed by one global lever over egui's own
  `Style::animation_time`, covering what egui's internals already animate (collapsing
  headers, resizable-panel expand/collapse, scrollbar fade, dialog fade-in). It does not reach
  Lumit's own menus/dropdowns, which have no animation today regardless of this setting.

Spec: [15-DESIGN.md](15-DESIGN.md) §2, §7.3, §8, §11; [07-UI-SPEC.md](07-UI-SPEC.md) §15.

**K-093 · DECIDED · The sub-frame position is content in the frame-cache key under a
synthesising interpolation policy.** Fixing a real bug (owner-reported "flow only changes
once in the middle"): `feed_source` keyed a retimed footage layer on the stamped *integer*
source frame plus the interpolation tag, but not the sub-frame fraction. Under Blend/Flow a
ramp from source frame N to N+1 crosses every fraction in between, each a different
synthesised morph, yet all collapsed onto the nearest integer frame's key — so the three-tier
cache computed one frame per integer span and held it. The key now also hashes the exact
retimed `source_time` whenever the policy is non-Nearest (both the Footage and Sequence
paths). Nearest still hashes nothing beyond the stamped frame, so the "Nearest keys like
no-retime" law is untouched and pre-existing Nearest keys stay shared. No `ALGO_VERSION`
bump: the new keys are strictly longer byte strings, so they cannot collide with the old
buggy keys — stale entries simply stop being addressed, per the Global-Performance-Cache
lesson.

**K-094 · DECIDED · Temporal effects read neighbour source frames; those frames are cache-key
content.** The machinery behind Echo (docs/08 §3.13) and the coming flow motion blur and
datamosh: an effect declares a frame-offset window (`EffectTraits.temporal`), and
`fx::stack_temporal_window` unions a layer's live stack into the offsets the render must
supply. For a footage layer with a temporal stack, the decode path (preview and export
alike, K-031) decodes the layer's source at each offset — mapped through the same retime and
comp frame step as the primary frame, nearest and unmasked — and hands them to the effect.
The frame-cache key hashes those stamped neighbour frames (a `temporal/` block in
`feed_source`'s caller), because the synthesised output depends on them: two comp times that
share a held leading frame can differ in their neighbours. Only footage layers with a live
temporal stack pay this; every other key is byte-for-byte unchanged, so no `ALGO_VERSION`
bump. v1 scope limits (echo's fixed 8-frame window and one-frame spacing, source-not-stack
input, footage-only) are recorded in docs/08 §3.13's status note.

**K-095 · DECIDED · Flow gains an input-rate (conform) override.** From the owner
(2026-07-19), after the K-093 flow fix: interpolating between adjacent frames of
high-framerate footage (e.g. 600fps, whose neighbours are ~1.7ms apart) produces almost no
motion, so flow slow-motion looks frozen. `FlowParams` gains `input_fps: Option<f64>` — the
rate the clip is *interpreted* at for flow. `None` = the source's native rate (adjacent
frames, unchanged behaviour). `Some(r)` with `r` below native conforms the clip to `r` fps:
`frame_pick` brackets the source frames spaced `1/r` apart and blends between *those*, giving
real motion to interpolate — the standard "interpret footage as N fps" trick. Applied
identically in preview and export (K-031); the frame-cache key hashes the conform rate
because the same source time synthesises from different frames under it (no `ALGO_VERSION`
bump — Native keys are byte-for-byte unchanged, and a conformed key gains a `conform` tag).
The Flow group's "Input rate" dropdown offers Native and common rates. (Manual on/off already
exists — the wind toggle forces Flow unconditionally.) Separate near/far-blur-style controls
belong to the future depth-of-field effects, not here.

**K-096 · DECIDED · Scopes v1 read the banked composited frame on the CPU; GPU-live scopes
deferred.** The Scopes panel (docs/07 §8) ships: `Panel::Scopes(ScopeKind)` carries the
scope each instance shows (waveform luma, RGB waveform, vectorscope, histogram), chosen in
its header, persisted with the workspace, so two Scopes panels can show different scopes.
§8 specifies scopes "GPU-computed from the Viewer's displayed frame … live during playback";
v1 narrows that: scopes are computed on the CPU from the composited frame Lumit already
banks in RAM (`comp_frame_cache`, the RAM tier of docs/06), which *is* the Viewer's displayed
frame. That frame is banked only while paused or scrubbing — during playback the readback is
skipped to protect the frame budget (docs/13) — so a v1 scope updates on every paused frame
and holds the last shown frame during playback, rather than tracing live. Live-during-playback
scopes wait on a GPU-side scope pass (a compute shader over the presented texture); recorded
as a v1 limit, not a reversal of §8's intent. Banked frames are always specified-resolution
(draft frames are never banked), so §8's "computed at Half" note never fires in v1. Scope
colours are one fixed `ScopeColours` set on the theme — a near-black graticule and bright
trace whatever the light/dark chrome, the same grading-accuracy reasoning that keeps
`viewer_surround` neutral (docs/15 §2.1). The frame cache gains a recency-neutral `peek`
(alongside `contains_key`) so a scope reading the current frame every paint does not distort
LRU eviction. The §8 tap-point open question (pre- vs post-display-transform) is untouched —
v1 has no display transform, so the banked sRGB frame is both.

**K-097 · DECIDED · Four community colour schemes join the theme as named, first-class
options.** From the owner: alongside Dark, Dark blue and Light, `Theme` gains `gruvbox_dark`,
`gruvbox_light`, `catppuccin_mocha` and `catppuccin_latte` — full constructors populating
every token, built the same way as the existing three (`dark()`/`light()`/`dark_blue()`).
A new `ColorScheme` enum (`Dark`/`DarkBlue`/`Light`/`GruvboxDark`/`GruvboxLight`/
`CatppuccinMocha`/`CatppuccinLatte`) supersedes the old `ThemeMode` × `ThemeVariant` split as
the thing a full theme picker selects from, with `ColorScheme::mode()` still reporting the
light/dark half for callers (e.g. `with_accent`'s hover-shift direction) that only need that.
`Theme::for_scheme(scheme, shape)` is the shape-inclusive composition entry point, sitting
alongside the pre-existing `Theme::for_settings(mode, variant, shape)` rather than replacing
it — both remain callable; wiring the Settings window's Appearance page onto `ColorScheme`
instead of the old two-axis picker is a follow-up change (K-098's window), not part of this
entry. Each new scheme maps its source palette onto Lumit's existing roles rather than
introducing new ones: surfaces follow that palette's own background ramp (monotonic
light→dark for the dark schemes; mirroring `light()`'s "elevation reads as a darker wash"
structure, `surface_4` below `surface_0`, for the two light schemes), text takes that
palette's foreground/muted ramp, `accent` is the scheme's usual signature hue (Gruvbox
orange, Catppuccin mauve), and `viewer_surround` and `scope` stay exactly as every other
theme's — strictly neutral and the one fixed `ScopeColours::STANDARD` respectively, never
palette-tinted, per the grading-accuracy rule in docs/15 §2.1/§11. Gruvbox's error role takes
the palette's *neutral* red rather than its bolder "bright red", a curation choice keeping it
a notch short of alarming in the spirit of docs/15 §3.1's no-punishment-red rule while
remaining an authentic Gruvbox hue. Spec: [15-DESIGN.md](15-DESIGN.md) §2, §11.

**K-098 · DECIDED · A Settings window replaces the Window-menu theme cluster; app-wide
params migrate onto it.** From the owner (2026-07-18): a proper application-settings surface,
macOS-System-Settings-shaped — a left sidebar of pages, each page a column of grouped
"cards" of label-plus-control rows — honouring the Sharp/Round shape like every panel (Round
gives cards a fill and rounded corners, Sharp a hairline frame). It opens from Window →
Settings… or Ctrl/Cmd+comma (`settings.rs`). This supersedes the plan note in docs/07 §15
that the K-092 theme toggles "live in the Window menu for now": Theme Mode, Background ramp,
Accent, Shape and Interface motion now live on the **Appearance** page, and the Window menu
keeps only Reset workspace and a Settings… opener. v1 also ships a **Performance** page
(RAM frame-cache budget and disk-cache cap, both applied live — `ByteLru::set_budget` and a
new `diskio::Cmd::SetCap` the disk worker remembers across project switches) and a **General**
page (reset workspace, version). Performance settings persist on `Shell` as
`PerformanceSettings`; defaults reproduce the previous hardcoded budgets (512 MiB RAM, 50 GiB
disk) exactly, so an existing install is unchanged until a slider moves. The Appearance page's
Mode-plus-Background pair is the old two-axis picker; folding it into a single K-097
`ColorScheme` dropdown (so Gruvbox and Catppuccin are selectable) is the immediate follow-up.
The fuller §15 inventory (VRAM/CUDA, decoder pool, worker cap, cache root/proxy, Preview,
Colour, Export, Keymap, Autosave, Plugins) fills in on this same surface as those systems gain
controls; a GPU-acceleration toggle was deliberately deferred rather than shipped half-wired
(the flow engine lives in the decode worker and needs its own control message). The window is
the `docs/07 §15` "Interface/Preferences" surface, not a second one.

**K-099 · DECIDED · Vignette and Chromatic aberration ship as two new single-frame effects
(docs/08 §3.14, §3.15).** Both are cheap, pointwise, `{0}` temporal, wired at the usual four
sites (schema in `lumit-core`, WGSL kernel + `FxEngine` method in `lumit-gpu`, `run_ops` arm
in `lumit-ui`). **Vignette** — Amount/Radius/Softness/Roundness (each a plain 0–1 fraction)
plus the host Mix — darkens toward black away from the frame centre; Category **Colour**,
matching where docs/08 §3.10's text already listed it as planned scope, not Stylise. Its
distance metric blends between a circle and a frame-aspect ellipse by Roundness, computed from
the raster's own width/height at kernel time, so Radius/Softness need no %-diag conversion
despite governing a spatial falloff — the metric is already resolution-relative by
construction. Amount 0 is the neutral point (bit-exact passthrough, pinned by test, mirroring
Glow's own Intensity-0 short-circuit); a Colour param to tint the vignette away from black was
scoped but deferred, v1 always darkening toward black. **Chromatic aberration** — Amount
(px@comp) plus Mix — is a dedicated, always-radial, single-purpose sibling of RGB split's own
Radial mode (docs/08 §3.6): same R-outward/B-inward shape, but with nothing else to configure,
the same one-thing shape rule that split the old Grade into Colour balance/Saturation (K-090).
Deliberate overlap, not a functional gap: RGB split's Radial mode already covers this exact
maths as one of its three modes, sharing an Amount currency (% diag) with Linear mode's
Angle-driven offset; this effect exists purely for the common one-click case. Because it has no
Angle to share a currency with, its Amount is authored in raw px@comp instead — scaled by the
preview factor like Glitch's Block size — and its ROI trait is `full-frame` rather than a
%-diag padding, since a fixed pixel offset cannot be statically bounded as a percentage of the
diagonal across every comp resolution; Category is **Distortion**, matching RGB split. Neither
the CPU reference nor the WGSL kernel needs an explicit Amount-0 short circuit — the radial
scale factor is an exact `0.0` at Amount 0, so every tap already collapses onto its own pixel,
the same un-guarded style RGB split's own kernel uses — asserted bit-exact by test rather than
built as a branch. Both oracles measured worst 1 fp16 ULP on the dev RTX (0 ULP at their
passthrough cases), within the cheap-class ≤ 2 ULP bound (§1.6).

**K-100 · DECIDED · The Performance page gains a video-memory (VRAM) budget and a
Clear cache action.** Extends K-098: `PerformanceSettings` gains `vram_cache_mb` (default
512, matching `GpuViewer`'s existing `VRAM_TIER_CAP`), applied live through a new
`GpuViewer::set_vram_cap` alongside the RAM and disk lines already wired in
`apply_cache_budgets`. `set_vram_cap` re-evicts the VRAM tier's oldest entries against the
new cap immediately, reusing the same `vram_evict_count` policy `present_keyed` already
applies on insert — no separate eviction logic. A **Cache** group joins the Performance page
with a single **Clear cache** button: it empties the RAM `comp_frame_cache` and the VRAM
tier (`GpuViewer::clear_vram`, which releases each texture's egui registration so nothing
leaks) and bumps `AppState::cache_epoch` so the cache bar and any live views notice the
tiers are now empty. This is the first row of the docs/07 §15 "Performance" inventory's VRAM
budget to ship; CUDA on/off, decoder pool size, worker thread cap and background cache fill
remain open.

**K-101 · DECIDED · Effects browser drag-to-apply lands on Timeline layer rows in v1, scoped
to footage and adjustment layers.** Implements the docs/07 §7 apply path "drag onto a layer
row in the Timeline": each built-in-effect entry in the Effects & Presets browser
(`effects_panel`) is a drag source carrying an `EffectDragPayload(&'static str)` — the
effect's stable `match_name` — kept distinct from the Project panel's `uuid::Uuid` item
payload so a drop target can tell them apart by type alone. In the Timeline, a layer row
accepts the drop only when `accepts_effect_drop` says its kind is Footage or Adjustment — the
effect stack's two ordinary homes; every other kind (Sequence, Precomp, Solid, Text, Camera)
still gains effects only through its own row's existing "Add effect" menu, unchanged. A
hovered drop paints an accent outline over the row's lane area; a release instantiates the
effect (`fx::instantiate`) and appends it to the layer's `effects` through the same
`Op::SetLayerEffects` the "Add effect" row commits, so applying by drag is one ordinary undo
step, then the preview refreshes the way other Timeline commits do. Double-click apply, drag
onto the Viewer, and presets/favourites — the rest of §7's inventory — remain later steps.

**K-102 · DECIDED · Command palette and a composition hierarchy panel ship as the first two
command/navigation surfaces.** Two self-contained UI surfaces, both `egui::Modal`/panel work
touching no engine code. (1) The **command palette** (docs/07 §12, `command_palette.rs`):
Ctrl/Cmd+Shift+P or Window → Command palette… opens a top-anchored modal with a focused
search box over a fuzzy-ranked command list (subsequence match; a label hit outranks a
keyword-only hit; earlier/contiguous matches rank higher — unit-tested). v1 covers the
commands category (save, undo/redo, new composition, add layers, reset workspace, open
Settings, colour-scheme and shape switches, export); the effects/comps/panels categories,
recent-first ranking and taught shortcuts are later. It is explicitly **not** the deferred
effects radial menu (Ctrl+Space, apply-to-clip) — that remains blocked on a from-scratch
build (no egui 0.31-compatible `egui_pie_menu`/`egui_node_graph`). (2) The **Hierarchy
panel** (`hierarchy.rs`, a new `Panel::Hierarchy` tabbed into the left group of the default
layout): a read-only, recursion-guarded tree of the active composition — its layers, with
precomp layers folding open to their nested composition's layers; clicking a row selects that
layer and switches to its composition. It is the simple tree form of the AE composition
flowchart; the full node-graph flowchart (the same deferred `egui_node_graph`-style view the
radial menu wants) grows from it. Both count as modals/panels that suppress the active-panel
focus edge while a modal is open, reusing the K-098 modal-gating.

**K-103 · DECIDED · Layer parenting (AE-style transform inheritance) — foundation first.**
`Layer` gains `parent: Option<Uuid>` (serde default `None`, so every existing project and
layer is byte-for-byte unchanged; a missing/deleted/cyclic parent degrades to "no parent" at
render time, the same invariant as `matte`). `Op::SetLayerParent { comp, layer, parent }`
sets or clears it, rejecting a self-parent, a parent not in the comp, or one that would form
a cycle (`OpError::InvalidParent`), with cycle-safety in two pure, tested helpers
(`model::layer_parent_chain`, `model::parenting_would_cycle`). This entry lands the **model +
op + validation** only; the transform is not yet inherited at render time. The render wiring
is planned to reuse the existing, proven primitives — `lumit_gpu::place_matrix` +
`concat_place` + the `CompLayerDraw.pre` field that precomp-collapse already uses — via a
shared parent-chain world-placement helper called by BOTH `draws.rs` (`build_comp_draws`,
preview) and `export.rs` (`render_comp_linear`, export) so preview/export parity holds
(K-031), gated on `parent.is_some()` so unparented layers keep their exact current path.
v1 scope composes the 2D affine (position/anchor/scale/rotation); inheriting the 2.5D axes
(`position_z`, `rotation_x/y`) is a follow-up. UI: a Parent picker in the layer's inspector
rows. Staged deliberately so the safe, fully-tested foundation ships before the render-path
change, which is best verified visually with the owner present.

**K-104 · DECIDED · Datamosh (Glitch's third section) ships, reusing Motion blur's flow
machinery rather than adding new plumbing.** Datamosh (docs/08 §3.12) was deferred at K-094
pending "machinery no effect has yet"; Motion blur (§3.2) built that machinery in the
meantime, and Datamosh turned out to need only a second frame pair through it, not new
infrastructure. `fx::stack_temporal_window`/`stack_is_temporal` gain the one case in the
registry where an effect's temporal reach depends on a param value, not just its static
schema trait: a live `glitch` instance's `datamosh_enabled` bool (new, off by default) adds
offset `-1` to the window. `stack_wants_flow_field` (bool) is replaced by
`stack_flow_neighbour` (`Option<i32>`): Motion blur wants neighbour `1`, Datamosh wants
`-1`. A layer carries only one flow field per frame in v1 (`CompLayerPixels::flow_field`
stays a single slot) — if a stack somehow has both a live Motion blur and a Datamosh-on
Glitch, the first one encountered in stack order wins the slot and the other's flow-
dependent behaviour degrades to its existing missing-field passthrough (pinned by test).
Datamosh itself is one GPU pass sharing Motion blur's `mb_layout`/`mb_pl` (three sampled
inputs — current frame, `-1` neighbour, flow field — plus storage-out and uniform): a single
bilinear tap per pixel (motion-compensated prediction), not a streak integral, blended
against the already block/scanline'd frame by the shared Intensity dial. Off by default
(unlike Block displacement/Scanlines, which have been on since Glitch first shipped) because
it is footage-only and adds a flow computation the moment it is live — existing Glitch
instances render byte-identically until an editor opts in. Operates on the layer's *source*
frames, the same v1 simplification Echo and Motion blur already made. Oracle: GPU matches
`lumit_core::fx::cpu::datamosh` at ≤ 2 fp16 ULP (measured 0–1).

**K-105 · DECIDED · Solo / isolate switch on layers.** `Switches` gains `solo: bool` (serde
default false, so every existing project is byte-identical). While *any* layer in a
composition is soloed, only soloed layers render — the standard After Effects isolate. The
gate is one shared helper, `model::any_solo(comp)`, applied identically in the preview
(`build_comp_draws`) and export (`render_comp_linear`) visibility checks so the two agree
(K-031): a layer renders iff `visible && in_span && (!any_solo || solo)`. `Op::SetLayerSolo`
toggles it as one undo step (mirroring `SetLayerVisible`). The control is a Solo checkbox at
the top of the Effect Controls panel, beside the Parent picker; a Timeline solo column is a
later refinement. Known v1 edge: a non-soloed layer used as a *matte* source for a soloed
layer is hidden like any other non-soloed layer (solo takes precedence over the matte-source
exemption) — acceptable until the Timeline surface makes solo state obvious per row.

**K-106 · DECIDED · Exposure ships as a new single-frame grade effect (docs/08 §3.16).**
A single scene-linear gain on RGB, `factor = 2^Stops`, computed host-side so the CPU
reference and the WGSL kernel multiply by the identical number (no per-pixel `exp2`, no path
divergence). Params Stops (default 0, slider −5..+5, unbounded) plus the host Mix; Category
**Colour**, alongside Colour balance and Saturation. Premultiplied — a scalar scales
premultiplied colour consistently, so no unpremultiply round trip and alpha is untouched.
Continuous (unlike a posterise/quantise, which would blow the ULP oracle at every
quantisation edge), so the §1.6 oracle holds to ≤ 2 fp16 ULP (measured 0–1 on the dev RTX).
`factor` 1.0 (0 stops) short-circuits to the input on both paths — the bit-exact neutral
point, pinned by test — and Mix 0 is likewise the identity. Distinct from Colour balance's
three-channel Gain: the single, animatable, photographic-stops brightness lever the montage
grade reaches for first. Wired at the usual four sites (schema in `lumit-core`, WGSL +
`FxEngine::exposure` in `lumit-gpu`, `run_ops` arm in `lumit-ui`).

**K-107 · DECIDED · Glitch splits into Block glitch, Scanlines and Datamosh; the combined
effect is removed (docs/08 §3.12).** Per the one-effect-one-job rule (K-090 — the same rule
that split the v1 Grade into Colour balance and Saturation, and split Chromatic aberration
off RGB split's own Radial mode): the old `glitch` effect did three things behind enableable
section toggles (Block displacement, Scanlines, Datamosh — the last added by K-104), so it
splits into three standalone schemas — `block_glitch`, `scanlines`, `datamosh` — and `glitch`
is deleted outright. Pre-v1, single user, no saved-project migration: existing `glitch`
instances simply stop resolving; no alias or upgrade path is built. `block_glitch` and
`scanlines` carry over their section's parameters unchanged (ids, labels, ranges, defaults),
minus the now-redundant `block_enabled`/`scanline_enabled` toggles — each is always on in its
own effect now. Stacking Block glitch → Scanlines, each at Mix 100%, reproduces the old
combined Glitch's look bit-for-bit, since the two sections never interacted beyond sharing one
kernel pass. `block_glitch` keeps `seeded: true` and `full-frame` ROI (the block hash can
displace a read from anywhere in the grid); `scanlines` drops Seed entirely and declares
`seeded: false` and `exact` ROI — it reads the input pixel directly, no hash, no neighbour tap.
Datamosh keeps its existing GPU pass and CPU oracle (`FxEngine::datamosh`, `cpu::datamosh`,
`fx_datamosh.wgsl`) byte-for-byte unchanged; only its schema, `Resolved` variant and stack
wiring are new. Its temporal reach is now **static** — schema `temporal: {0, -1}`, the same
shape Motion blur's own `{0, +1}` already has — which retires the one dynamic special case
`stack_temporal_window`/`stack_flow_neighbour` carried since K-104 (a live `glitch` instance's
`datamosh_enabled` param toggling whether the stack's temporal window and flow-field gate
reached back to -1); `stack_flow_neighbour` now recognises a live `datamosh` instance the same
static way it recognises `motion_blur`. Datamosh's Mix folds into its existing single-blend-
fraction `intensity` argument by multiplication at the call site (`run_ops`) rather than adding
a second uniform to the unchanged kernel — mixing the same two inputs (current frame, warped
neighbour) twice collapses algebraically to one mix by the product, so Intensity-0 and Mix-0
are both the identical bit-exact passthrough. All three new schemas declare Category
**Distortion**, matching Shake and RGB split (their closest siblings: a seeded positional
wobble; a channel split), not the additive-light Stylise pair (Glow, Flash) — unchanged from
the old combined Glitch. Landed as three green commits: Datamosh split out first (retiring the
dynamic special case on its own), then Block glitch/Scanlines split out and `glitch` deleted,
then docs.

**K-108 · DECIDED · Hue shift ships as a new single-frame grade effect (docs/08 §3.17).**
A constant-luminance hue rotation (the standard SVG `feColorMatrix` hue-rotate, Rec.709 luma
weights), a linear 3×3 colour matrix computed host-side (`fx::hue_matrix`) so the CPU
reference and the WGSL kernel multiply by identical `f32` coefficients — the nine travel as
individual uniform fields so their tight packing matches the Rust `[f32; 9]` (a uniform array
strides at 16). Params Angle (degrees, default 0) plus the host Mix; Category **Colour**,
beside Exposure and Saturation. Premultiplied — a linear matrix scales through alpha, so no
unpremultiply round trip and alpha is untouched. Continuous, so the §1.6 oracle holds to ≤ 2
fp16 ULP (0–1 on the dev RTX). 0° resolves to the exact identity matrix (the bit-exact neutral
point, pinned by test); Mix 0 is likewise the identity. The rotation runs in scene-linear
working space, consistent with the other grades. Wired at the usual four sites.

**K-110 · DECIDED · Contrast ships as a new single-frame grade effect (docs/08 §3.18).**
The fourth one-knob colour grade beside Exposure, Hue shift and Saturation: it expands or
compresses each RGB channel about a fixed pivot, `out = (in − pivot) × k + pivot`, with
`k = Contrast ÷ 100` (default 100 % = identity, slider 0–200, hard min 0 and unbounded above,
matching Exposure/Saturation's one-sided bound) and `pivot = 0.5`. The pivot is a plain
mid-grey 0.5, not the 0.18 scene-linear mid-grey, so the control behaves like a photo-editor
contrast slider (symmetric about 50 %) rather than a light-meter grey card — the one
substantive design call, flagged for the owner to review. Because the `− pivot` offset makes
this an affine grade, not a pure scale, it does not commute with premultiplied alpha: it
declares `premultiplied: false` and the host unpremultiplies → grades → re-premultiplies (like
Colour balance and Saturation), so matte edges do not shift — unlike Exposure, whose pure
multiply is alpha-safe. Alpha is untouched and the maths runs in the scene-linear working
space. Continuous everywhere (no round/clamp/quantize), so the §1.6 oracle holds (worst 1 fp16
ULP on the dev RTX, partial-alpha pixels tested); Contrast 100 % and Mix 0 are bit-exact
passthroughs. Resolve clamps `k` at `max(0.0)` to honour the schema's hard min; the kernel
itself clamps nothing, staying continuous. Wired at the usual sites, built in an isolated
worktree and merged.

**K-111 · DECIDED · File-reference parameter kind, animated by stepping (K-109 skipped).**
Effects can declare a `File` parameter (`ParamKind::File { filter, filter_name }`) whose value
is a `FileParam { paths: Vec<String>, index: Property }` — a set of referenced file paths plus
an f64 `index` selecting which is live at a given time. The inspector shows the file's basename
and a "Select …" button opening a native dialog filtered by the effect's declared extensions;
picking a file sets a single static path. It is animatable, but only by *stepping*: two paths
cannot be blended, so the index carries **Hold keyframes only** (the discrete keyframe that
landed just before this) and is rounded and clamped at evaluation, never landing between paths.
This deliberately reuses the whole existing keyframe / graph / expression machinery for the
index rather than adding a string-valued keyframe type; the common case is one path with a
static index. An empty `paths` is the unset state and resolves to identity, so a File-param
effect is a no-op until a file is chosen — a sanctioned exception to the no-no-op-default rule
(§1.2), since a file the user must supply has no tasteful default. The path string joins the
frame cache key (length-prefixed, the live path at the time), the same policy a footage source
path follows; file *contents* are re-read by the consumer's own path+mtime cache, not this
hash. First consumer is the coming LUT effect (§3.11). K-109 was reserved for this during
parallel work but Contrast took K-110 first, so K-109 is intentionally skipped to keep this log
ascending.

**K-112 · DECIDED · Gamma ships as a new single-frame grade effect (docs/08 §3.19).**
The fifth one-knob Colour grade: a per-channel power curve `out = pow(max(in, 0), 1 ÷ gamma)` in
scene-linear working space, alpha untouched. Float Gamma (default 1.0, slider 0.1–4.0, hard floor
0.01 to keep `1 ÷ gamma` finite, no ceiling — Contrast's open-topped shape). The input is clamped
to ≥ 0 before the power (scene-linear can dip negative and a power of a negative base is
undefined); the clamp is byte-identical on CPU and GPU so the §1.6 oracle holds (≤ 1 fp16 ULP on
the dev RTX). The exponent is `1 ÷ gamma`, so Gamma above 1 brightens mid-tones (the display-gamma
reading), the opposite direction from Colour balance's per-channel Gamma — noted in §3.19 to avoid
confusion. A power curve is non-linear, so it does not commute with premultiplied alpha:
`premultiplied: false`, host-wrapped unpremultiply → curve → re-premultiply like Contrast and
Saturation. Gamma 1.0 short-circuits to a bit-exact passthrough (not a reliance on `pow(x, 1)`
being `x`) and Mix 0 likewise, both pinned by test. Built in an isolated worktree and merged.

**K-113 · DECIDED · Temperature ships as a new single-frame grade effect (docs/08 §3.20).**
The sixth one-knob Colour grade: a warm/cool white balance as a per-channel gain in scene-linear
space, `gain_r = 1 + 0.5·k` and `gain_b = 1 − 0.5·k` for `k = Temperature ÷ 100` (green and alpha
held). Float Temperature (default 0, slider −100..+100, hard ±100). The two gains are host-computed
at resolve and passed as uniforms, so the CPU reference and the WGSL kernel multiply by
byte-identical f32 factors. A per-channel multiply commutes with premultiplied alpha (scaling a
premultiplied channel by a constant is exact, alpha untouched), so it declares `premultiplied:
true` and applies straight through like Exposure — unlike the affine Contrast and Saturation
grades, no unpremultiply round trip. Continuous everywhere (a linear scale, no round/clamp/quantize),
so the §1.6 oracle holds (worst 1 fp16 ULP, partial-alpha tested); Temperature 0 gives gains
exactly `(1.0, 1.0)` for a bit-exact identity, Mix 0 likewise, both pinned by test. REVIEW: the
±0.5 R/B strength (so ±100 → red/blue gains 1.5/0.5, green held) is a taste choice for the montage
warmth range, not a physical calibration; the fuller Bradford-adapted CCT white balance with a
Tint axis remains a Tier-2 job (§3.10). Built in an isolated worktree and merged.

**K-114 · DECIDED · The LUT effect ships (docs/08 §3.11), the File param's first consumer.**
A `lut` built-in in the Colour category, v1 subset: a File parameter (`.cube`, animatable by
hold-stepping between paths — K-111) plus the host Mix, applied 3D-trilinear in the compositor's
scene-linear working space **as-is** (no Input-space transfer), unpremultiplied. `Resolved::Lut
{ mix }` carries only Mix; because a file path is not `Copy`, the parsed-and-uploaded cube
travels **beside** the resolved op as a parallel `luts` slot on `fxops::run_ops`, exactly as the
flow field and neighbour frames do for the temporal effects. `CompLayerDraw.lut_files` carries a
layer's ordered enabled-builtin-`lut` paths; since a `lut` effect always resolves to exactly one
`Resolved::Lut`, that list is 1:1 and in order with the ops (the threading linchpin). Preview
(GpuViewer) and export (Renderer) both build the list with the identical filter and load it
through a path-keyed upload cache into the one shared `run_ops`, so they are pixel-identical
(K-031, reviewed by hand rather than by test since the wiring has no end-to-end oracle). An
unset, missing, 1D, or unreadable file is a labelled no-op, never a fault. `cpu::apply` is a
passthrough — a LUT is a GPU colour map, so the CPU degradation rung renders it as identity, and
the §1.6 oracle reference is `lut::Lut3d::sample` used directly in the lumit-gpu kernel test
(worst 1 fp16 ULP), the one effect whose reference lives outside `cpu::apply` because its
parameter is a file, not a number. The GPU uses the first 3D texture in the FxEngine
(`Rgba32Float` cube, manual `textureLoad` trilinear — not the hardware sampler — so the oracle
stays exact). Follow-ups (flagged): Input-space control, Tetrahedral interpolation, mtime cache
invalidation, a content-hash cache key, and embedding small LUTs in the project (K-040). Built
across three isolated worktrees (parser, GPU sampler, wiring) and merged.

**K-115 · DECIDED · The Performance page gains a Background fill toggle (K-109, K-114
skipped/reserved).** Closes the last named row of K-100's remaining list. `PerformanceSettings`
gains `background_fill: bool` (default `true`, matching today's unconditional behaviour) with a
struct-level `#[serde(default)]` so an older saved workspace missing the field falls back to the
default rather than failing to deserialize (the existing three fields relied only on the
field-level default on `Shell::settings`, which only covers a wholly-absent `settings` key, not
a `PerformanceSettings` missing one new field — this closes that latent gap for future fields
too). The Cache group's idle-fill loop (`shell/mod.rs`, the "Idle: fill the work area around the
playhead" block) is gated on the new flag alongside its existing playing/interacting/in-flight
checks; off means zero background decode/render work while idle, trading a colder cache for a
quieter machine. K-114 is reserved for the in-flight LUT effect and intentionally skipped here to
keep the log ascending without colliding with that session's work.

**K-116 · DECIDED · Hit-target compensation promoted from KD-2 (docs/15-DESIGN.md §1.2/§7.2).**
The household accessibility gate demands ≥44px touch targets everywhere; a Timeline showing
twenty layers at once cannot meet that on every row, so Lumit records a deliberate, scoped
exception rather than silently missing the gate. Toolbar, transport, dialog, and Viewer-toolbar
controls keep the full household ≥44px hit extent. Dense-surface controls — Timeline rows,
clips, keyframes, curve handles, property lanes, the cache bar — drop to ≥24px **visual** extent
on their smaller axis, but MUST still carry ≥32px of **interactive** hit-slop (e.g. a keyframe
renders at 9px but hit-tests at 32px, nearest-wins, with adjacent slop regions split at their
midpoint). Timeline rows default to 28px, 24px minimum at the densest zoom; nothing interactive
ever hit-tests below 32px in either axis. This was recorded as PROPOSED deviation KD-2 pending
promotion to the decision log (docs/15-DESIGN.md §Open questions); that question is now
resolved — KD-2 is promoted here as DECIDED, and docs/15-DESIGN.md is updated in the same commit
to point at K-116 instead of the stale "promote as K-006" note (K-006 was independently taken by
Migration-aware first run before this promotion happened).

**K-117 · DECIDED · Settings → Performance → Cache gains a cache root folder override
(docs/07-UI-SPEC.md §15).** Closes the last named row of the Cache group.
`PerformanceSettings::cache_root: Option<PathBuf>` (default `None`) keeps today's
`<project>-cache` sidecar-beside-the-project-file behaviour byte-for-byte, so existing projects
and saved workspaces are unaffected until the user picks a folder. When set, each project's disk
cache moves under the chosen root as `<stem>-<hash8hex>-cache`, the hash taken from the
canonicalized project path so same-named projects in different folders never collide while the
stem keeps folders eyeball-recognisable. `lumit_cache::disk::cache_root_for` carries the
override-aware lookup; the existing `sidecar_root` is untouched and still backs the `None` case.
The picker uses `rfd::FileDialog::pick_folder`, matching every other file/folder chooser in the
app. Applied live: `AppState::disk_sync_root` already polls once per frame and diffs the
computed root against the one in use, so a Settings change repoints the disk-cache worker on the
next frame with no restart. Trade-off, flagged for follow-up: old cache folders at a previous
root are not migrated or deleted when the root changes — orphaned, not corrupting, consistent
with the cache's "always safe to delete, never authoritative" design; worth a cleanup pass if
orphaned caches become a nuisance. Built in an isolated worktree and merged.

**K-118 · DECIDED · The Settings window gains an Interface page: UI scale and a tooltips
on/off switch (docs/07-UI-SPEC.md §15).** Closes two of the three named controls in the
Interface group; reduced motion already shipped separately as Interface motion on the
Appearance page (K-092) and is untouched here. UI scale is a 75–200% slider applied live
through egui's own `Context::set_pixels_per_point` — the same zoom primitive behind egui's
built-in Ctrl+=/Ctrl+- shortcut, here surfaced as a persisted preference applied at start-up as
well as on change, rather than a per-session nudge. Tooltips are suppressed globally by pushing
`egui::Style::interaction.tooltip_delay` to infinity rather than gating each `.on_hover_text()`
call site individually — confirmed against `Response::should_show_hover_ui` that this genuinely
prevents a tooltip ever showing, and confirmed the resulting infinite duration cannot panic the
repaint-scheduling path. "On" restores egui's own stock default delay rather than a hardcoded
guess. Both default to today's implicit behaviour (native scale, tooltips on), so no existing
install changes until the user visits the page. Trade-off, flagged for follow-up: tooltip
suppression rides on `tooltip_delay`'s current meaning in egui's style struct, which is worth
re-checking on any future egui upgrade. Built in an isolated worktree and merged.

**K-119 · DECIDED · The Settings window gains an Export page: a default preset and a filename
template (docs/07-UI-SPEC.md §15).** Closes two of the four named rows in the Export group;
export priority and encoder preference order stay unbuilt — no priority or encoder-order
concept exists anywhere in the export pipeline yet, so a control for either would be dead.
`ExportSettings::default_preset` (default `Custom`, matching `ExportPreset`'s own new `Default`)
is stamped by every generic "Export…" action — the File-menu entry and its native-menu twin —
while an explicit pick from the "Export preset" submenu always keeps its own preset regardless.
`ExportSettings::filename_template: Option<String>` (default `None`) substitutes `{comp}`,
`{preset}`, and `{date}` into the export dialogue's suggested name when set, sanitised against
characters Windows forbids in file names (a composition name is free text and can carry one)
and guaranteed to end in `.mp4`; `None`, or a template blank once trimmed, reproduces
`preset.default_file_name()` byte-for-byte, so no existing install's suggested name shifts until
the user visits the page. Today's date comes from a small hand-rolled UTC civil-date conversion
(Howard Hinnant's `civil_from_days` over `SystemTime`) rather than a new `chrono`/`time`
dependency. Built in an isolated worktree and merged.

**K-121 · DECIDED · Matte key ships as a soft chroma-key effect (docs/08 §3.21).**
A greenscreen keyer in the Utility category: alpha is driven down where a pixel's chroma is
close to a chosen key colour. The metric is Euclidean distance in the chroma plane — a
colour's chroma is `rgb − Rec.709-luma`, so distance ignores brightness and a green of any
exposure keys alike. The keep-factor is `smoothstep(tolerance, tolerance + softness, d)` —
fully keyed (alpha ×0) at/below tolerance, fully kept at/above tolerance+softness, smooth
between — so it is continuous everywhere (no hard step, which would blow the cheap-class ULP
oracle). It runs on straight colour (`premultiplied: false`, §2.2): unpremultiply → key +
despill → re-premultiply, like Saturation, so edges are judged by true colour not coverage.
Spill suppression removes a fraction of the pixel's projection onto the key-hue direction,
desaturating kept pixels toward their own luma along the key hue so green fringes fade (a grey
key has no hue, so spill is a no-op). The key colour is a `ParamKind::Colour` resolved to a
scene-linear array at frame time; CPU reference and WGSL kernel derive the chroma/hue from that
identical resolved colour, holding the §1.6 oracle to ≤ 2 fp16 ULP (measured 1). Default green
+ Tolerance 20 % key a typical screen out of the box (the tasteful-default rule, §1.2, so no
neutral no-op); Mix 0 is the bit-exact identity. Chroma-distance was chosen over a hue-angle
metric to avoid per-pixel trig and keep CPU/GPU byte-identical (trade-off: saturation-sensitive,
which Tolerance widens for). A viewer eyedropper to pick the key off the image, and a
matte-choker / luma-key companion, are noted follow-ups. Built in an isolated worktree and
merged. (Numbered after K-120 per-layer motion blur, which lands from a parallel worktree; the
two are independent, so the log briefly carries K-121 before K-120.)

**K-120 · DECIDED · Per-layer motion blur is transform-sampled multi-draw (docs/06 §4).**
With a composition's motion-blur master on (`Composition.motion_blur.enabled`), a layer whose
own `Switches.motion_blur` is set is drawn at N sub-frame placements across the open shutter —
offsets `phase/360 + (k + 0.5)/N · angle/360` frames, centred by the −90°/180° AE defaults
(`MotionBlur::sample_offsets`) — and averaged into one comp-space smear; the layer's blend,
opacity, matte and mask apply once to that average, not per sub-copy. The average is a **true
premultiplied mean** via a dedicated additive-on-both-channels accumulation pipeline (not
`Blend::Add`, whose `alpha: over` would leave a static opaque layer at ~63 % alpha), so a still
layer is unchanged and a moving one thins along its path. Preview (`realise_segment`) and export
(`render_comp_linear`) derive the sample times through one shared `motion_blur_samples` and
build the average through one shared `Compositor::motion_blur_average`, so a blurred preview
equals a blurred export (K-031, reviewed by hand — both call the one helper). Comp motion-blur
settings and the per-layer switch join the frame cache key. Only the layer's own transform is
sampled; **parent-motion blur** (a still layer under a moving parent) and per-layer blur on the
inner layers of a **collapsed Precomp** are deferred follow-ups. Numbered K-120 though it lands
just after K-121 (matte key), the two being independent parallel-worktree work. Distinct from
the flow `motion_blur` effect (footage-internal motion) and the coming accumulation MB (full
sub-frame re-render).

**K-122 · DECIDED · Timeline and effects-panel interaction pass (docs/07 §4/§6).**
A batch of timeline/effects-panel UX with two decision-sized parts. **Reorder by
drag:** a layer is restacked by dragging its name in the outline, committing one
`ReorderLayer { comp, layer, new_index }` (lift-and-reinsert, clamped, 0 = top,
its own inverse); an effect is restacked by dragging its name, committing the
existing whole-stack `SetLayerEffects` (its doc already designates it the
add/remove/reorder commit, so no dedicated `ReorderEffect`). Each move is one
undo step with an accent insertion line. **A single layer context menu:**
right-clicking a layer's name opens one menu — rename, add effect (BUILTINS
submenu), add mask, duplicate, delete, solo, enable, convert-to-sequenced,
trim-to-source — **replacing** the old lane-bar right-click menu, so a layer's
actions live in one place (right-clicking the bar no longer opens a menu).
Non-decision polish landing with it: double-click a name to rename inline
(`RenameLayer`); names are a frameless button so dragging never selects text;
opening a layer twirl no longer auto-opens the Transform sub-twirl; the Effect
Controls panel and layer area get themed separator bars per effect/section title;
a column-header icon row sits over the outline switches level with the ruler; and
the effect drag-drop onto a layer (outline or lane) and into the Effect Controls
panel is fixed — the old drop tested a lane-clipped rect, so the visible half
never registered; it now uses occlusion-proof `contains_pointer` full-row drop
zones. Layer-area width is session state, not persisted (like every timeline
preference). Built in an isolated worktree and merged.

**K-123 · DECIDED · Layer-reference effect parameter kind (docs/03 §8, docs/08 §1.2).**
Effects gain a parameter referencing **another layer** in the same composition as an auxiliary
picture — `ParamKind::Layer {}` / `EffectValue::Layer(Option<Uuid>)`, the shape a track matte's
`MatteRef` uses minus channel/invert (static in v1). The host renders that layer **alone,
source-only** (its own effect stack skipped) and threads its texture to the effect beside the
resolved ops via the one shared `fxops::render_layer_input`, exactly as the matte stage renders
a matte layer alone; preview and export call that one helper so they match (K-031). Source-only
rendering makes reference **cycles structurally impossible** (the depth render never re-enters an
effect stack). An unset or dangling reference resolves to **identity** — the sanctioned no-op
exception the File parameter also takes, since a layer the user must supply has no tasteful
default. The frame cache key hashes the referenced layer's source + transform (the matte block's
shape). The inspector **Layer picker** and an undoable set-param op are a follow-up; until then
an unpicked Layer renders as nothing via the inspector's existing wildcard. First consumer is
the DoF effect (K-124). Built in an isolated worktree and merged.

**K-124 · DECIDED · Depth of field ships as a depth-driven lens blur (docs/08 §3.22).**
A variable-radius disc blur whose per-pixel circle-of-confusion comes from a **depth pass**
supplied by a Layer-reference parameter (K-123) — the first effect to take a whole layer as
input. Params: Depth layer, Focus distance (0.5), Focus range (0.1), Aperture (px@comp, 8,
slider 0–40), Mix; premultiplied, Moderate cost, padded ROI, `{0}` temporal, Blur & sharpen
category. It drives the pre-existing `lumit_gpu::fx::dof` kernel and its §1.6 oracle (depth read
from the referenced layer's red channel, 0 near / 1 far, symmetric about Focus). v1: the depth
layer is rendered source-only and **resampled to the effect's working raster** `(w, h)` — not
comp size, since the kernel reads depth at the consuming layer's own grid, which shrinks under
reduced-resolution preview; a framing-matched depth pass is expected, and the depth layer must be
visible + in-span in preview (the decode-planner gate, a recorded follow-up to lift). Placement/
effects-aware depth and the shaped-bokeh "DOF PRO" second effect are post-v1. Preview == export
via the one shared render helper. Built in an isolated worktree and merged.

**K-125 · DECIDED · Matte "after effects" toggle (docs/03 §6 matte, docs/impl/layer-input.md).**
A matte reads the source layer's **source pixels** by default (its own effect stack irrelevant),
but a new `MatteRef::after_effects` bool (serde-default false, so old projects are unchanged) has
the source's **own effect stack run into the matte texture** before it gates the consumer — a
keyed greenscreen, a blurred or levels-adjusted edge. The matte source is uploaded, linearised,
`run_ops` applies its resolved stack, then it composites alone exactly as a source-only matte
does; preview (`shell::gpu`) and export both do this from the same resolve + `run_ops`, so they
match (K-031). This also **fixed a latent K-031 bug**: export had been feeding the matte source's
*post-fx* `prepared` texture while preview fed source-only, so a matte source with effects
diverged between the two; both are now source-only by default and post-fx only when the toggle is
set. The frame key folds the source's stack (via the shared `feed_effect_stack`) only when the
toggle is on, so a source-only matte keeps its keys and a keyed matte invalidates when its key
colour moves. **v1 boundary:** temporal inputs (echo neighbours, flow motion-blur field, a nested
depth reference) are **not** fed through an after-effects matte — the source's spatial and colour
stack applies, but an echo/flow effect on the matte source degrades to a still; the common cases
(colour key, blur, levels) are exact. The same toggle for a Layer-reference depth input (K-123)
rides as a `depth_after_effects` schema bool on each consuming effect, not a model field. Built on
the main branch alongside the effects sprint. *Follow-up landed same sprint:* the DoF depth input
gained `depth_after_effects` (default false); `render_dof_inputs`/`build_dof_inputs` run the depth
layer's stack before resampling, and the key folds it via `feed_effect_stack`'s Layer arm guarded
by a one-level `allow_after_effects_refs` (a referenced layer's own layer-inputs stay source-only,
matching the render where they render as passthrough).

**K-126 · DECIDED · Invert ships as a single-frame colour effect (docs/08 §3.23).**
A simple colour inverse — `out.rgb = 1 − in.rgb` per channel, alpha kept — with only the host
Mix. Because `1 − c` is affine (not a pure scale) it does not commute with premultiplied alpha,
so it declares `premultiplied: false` and the host wraps unpremultiply → invert → re-premultiply,
exactly like Contrast and Gamma (§2.2), so matte edges do not fringe. The inverse is taken in the
compositor's scene-linear working space as-is (the owner's "simple inverse"): values above 1.0
invert to honest negatives, never clipped, and there is no display-referred round trip — a
perceptual inversion is a possible later variant. Cheap cost, Exact ROI, `{0}` temporal, Colour
category (beside the other grades). Continuous everywhere, so the §1.6 oracle holds to ≤ 2 fp16
ULP (measured worst 1); there is no neutral no-op value (invert always inverts), and Mix 0 is the
bit-exact identity, both pinned by test. Built in an isolated worktree; not pushed.

**K-127 · DECIDED · Tint ships as a luminance-duotone colour effect (docs/08 §3.24).**
A gradient map: two colour params, Map black to (default black) and Map white to (default white),
and `out.rgb = black + (white − black)·luma(in)` with Rec.709 luma on the unpremultiplied colour,
alpha kept — every pixel's brightness picks a colour on the two-colour gradient, recolouring the
image while keeping its luminosity structure (the owner's "map all colours between two colours").
A luma-driven remap does not commute with premultiplied alpha, so it declares `premultiplied:
false` and the host wraps unpremultiply → map → re-premultiply, like Contrast and Gamma (§2.2).
The lerp is written `black + (white − black)·luma` (not the `mix()` form) so the CPU reference and
the WGSL kernel reduce in the same order. The default black→black / white→white maps every pixel
to its own luma — a greyscale, a visible tasteful default (§1.2), not a no-op. Cheap cost, Exact
ROI, `{0}` temporal, Colour category. Continuous everywhere, so the §1.6 oracle holds to ≤ 2 fp16
ULP (measured worst 1); Mix 0 is the bit-exact identity, pinned by test. The two colours render
through the inspector's existing `ParamKind::Colour` arm — no inspector change needed. The fuller
shadows/mids/highlights Tritone is a Tier 2 follow-up (§4). Built in an isolated worktree; not
pushed.
**K-128 · DECIDED · Depth of field gains depth invert, separate near/far blur, and Display views
(docs/08 §3.22).** Three owner-requested additions modelled on Frischluft / DOF PRO. (1) **Depth
invert** (bool, default off): inverts the depth (`d' = 1 − d`) before the circle-of-confusion,
swapping near and far. (2) **Near/Far blur** (px@comp, default 8, slider 0–40): per-side maximum
circle-of-confusion — depths in front of focus (`d < focus`) use Near, the far side Far. The
existing **Aperture** is retained as a **master** that scales both about its default 8 (unity:
`radius · Aperture / 8`), so the near/far select flips only where the smoothstep `s` is zero (at
`d = focus`) and the radius stays continuous. (3) **Display** (choice, default Rendered):
diagnostic views — Rendered (the blur), Depth map (post-invert greyscale), Focus map (the smooth
`1 − s` in-focus mask); Depth/Focus map short-circuit before the gather and ignore Mix. All three
are threaded through `Resolved::Dof` (still `Copy`), the resolve arm, the CPU oracle, `DofParams`,
`FxEngine::dof` and `fx_dof.wgsl`; the UI renders the new Bool/Float/Choice params automatically
and the frame key hashes them via the effect-stack feed with no change. **Back-compat:** old
`dof` instances lack the new params, so Depth invert reads off, Display reads Rendered, and
Near/Far fall back to Aperture (both sides `8 · Aperture/8 = Aperture`), rendering identically.
Every shipped mode is continuous, so the §1.6 ULP oracle covers invert on/off, asymmetric near/far,
and each Display mode with no exclusion (worst 1 fp16 ULP on the RTX). Built in an isolated
worktree.
**K-129 · DECIDED · User-preset library and browser (docs/07 §7).** Effect presets (K-065)
gain a browsable home: a **Presets** group at the top of the Effects & Presets panel lists the
`.lumfx` files in a single preset library — `directories::ProjectDirs::from("dev","Lumit","Lumit")
.data_dir().join("presets")`, i.e. the platform roaming app-data folder, shared across projects
(alongside the existing `media_index_dir`/`journal_path` helpers in `lumit-project`). The folder is
created lazily and scanned live each paint (cheap for a small library), so a just-saved preset
appears at once; a missing or unreadable folder yields a hint, never a panic. Each entry's label is
the preset's own `name`, falling back to the file stem when the file can't be parsed, and the list
sorts case-insensitively by that label for stability between paints. A **click** applies the
preset, appending its saved stack with fresh instance ids to the selected layer as one undoable
`SetLayerEffects` — the same append the inspector's "Load preset…" already commits (K-065); with no
layer selected the click surfaces a status hint. "Save stack as preset…" defaults its rfd dialogue
to this folder so saving and browsing share one home, while still allowing the user to navigate
elsewhere. The scan/label/sort and load-with-fresh-ids logic are pure helpers (`preset::list_presets`,
`preset::load_instantiated`) with unit tests. Drag-a-preset-onto-a-layer, favourites, and preset
thumbnails (§7) remain later steps. Built in an isolated worktree; not pushed.
**K-130 · DECIDED · Scopes trace the live frame during playback from the CPU cache (docs/07
§8, extends K-096).** K-096 shipped scopes that updated only while paused/scrubbing and held the
last frame during playback, deferring live tracing to a GPU-side scope pass. This lifts that for
the common case without a new readback or any change to the render loop: the Scopes panel reads the
composited frame **under the playhead** (`comp_frame_cache.peek(frame_key_for(preview_frame))`, the
same frame the eyedropper reads) **every paint**, and while `app.is_playing()` requests
`request_repaint_after(16ms)` so it re-samples at the playback cadence. Because playback already
banks frames ahead (prefetch) and warms the work area when idle, the frame under the playhead is
normally cached, so the scope tracks live end to end. When it is not yet banked — a frame the budget
readback skipped, or one still rendering — the pane **holds the last frame it showed** (its key kept
in egui temp memory, re-validated against the cache so an evicted key never dangles) instead of
blanking, matching §8's "degrade the update rate under load". `request_repaint_after` (not a bare
`request_repaint`) is used deliberately so the panel never shortens the frame delay to zero and
never busies an idle-paused UI (the `is_playing` guard) nor spins faster than playback. The frame
choice is a pure `shown_frame_key` helper with a unit test. Guaranteed every-frame tracing under all
conditions (a cold, unwarmed comp) still waits on the GPU-side scope pass K-096 named; this is a
strict improvement over "holds during playback", not that pass. No change to the playback loop,
banking, or GPU code. Built in an isolated worktree; not pushed.

**K-131 · DECIDED · Temporal re-render effects share one `render_below_at`; Posterize time
(everything-below) ships first (docs/08 §3.25, docs/impl/temporal-rerender.md).**
Posterize time and (next) accumulation motion blur are not per-pixel effects — they change
*what time the layers below them render at*, so they live at the frame-orchestration layer, not
`run_ops`. Both re-render the below-stack at a changed time through **one** shared helper,
`render_below_at` = `build_comp_draws` at the held/sample time (reusing the SAME held decoded
pixels — footage is held, only transforms/effects/camera re-resolve) → a shared `Realiser`
(the GpuViewer compositor factored behind a borrowed handle so export can drive it too). Both
the preview comp-render entry and export's `render_comp_linear` call it, so preview equals
export pixel-for-pixel (K-031). Proved by a still-scene identity test (a re-render at the same
time is bit-identical to no re-render) and a moving-scene test (a full-coverage posterised
frame equals a plain render at the held time). Posterize time is an **adjustment** effect
(Everything below scope) detected on the adjustment layer; a Posterize effect resolves to no
op, so the detection — not the resolved stack — keeps such an adjustment live, and its held
below composites in place of the plain below-composite before the coverage blend. **Held-time
maths** `floor((t − phase)·rate)/rate + phase` (rate ≤ 0 holds nothing, never divides by
zero). **Boundaries (v1):** temporal effects inside the held below-stack (echo, flow motion
blur, datamosh) degrade to stills (the held re-render carries no neighbour decode, matching the
after-effects matte, K-125); a Posterize adjustment inside a collapsed Precomp is a no-op (its
held draws are sized for the nested comp); *This layer's effects* scope and the held-time cache
dedup are tracked follow-ups (the schema and maths are already in place). Built in an isolated
worktree; not pushed.

**K-132 · DECIDED · A held/sub-frame temporal re-render honours the per-effect
`sample_temporally` flag (docs/08 §3.25, docs/impl/temporal-rerender.md §5).** In a Posterize
time (and, next, accumulation motion blur) re-render, an effect on a below-layer flagged
`sample_temporally == false` resolves at the true frame time `t`, not the held/sample time `τ`,
so a particle system or other costly/stochastic effect is not re-run per held sample while the
rest of the scene (transforms, camera and the sampling effects) moves to `τ`. Implementation:
`lumit_core::fx::resolve_stack_temporal(effects, sample_lt, frame_lt, …)` shares `resolve_one`
with `resolve_stack`, handing each effect `frame_lt` when its flag is false and `sample_lt`
otherwise — so `sample_lt == frame_lt` is byte-identical to `resolve_stack` and the ordinary
(non-temporal) render is unchanged. `build_comp_draws` is now a thin wrapper over
`build_comp_draws_at(doc, comp, t_comp, frame_t, …)`, which threads the playhead `frame_t`
through nested Precomps and into `posterize_below`/`below_draws_at`/`render_below_at`; each
layer's own stack resolves through `resolve_stack_temporal`. Preview and export drive the one
threaded path, so they stay identical (K-031). The after-effects matte/depth sources keep their
own K-125 temporal boundary. Concurrent-worktree risk: another agent may also claim K-132 —
renumber on merge if so. Built in an isolated worktree; not pushed.

**K-133 · DECIDED · Posterize time *This layer's effects* scope ships: a per-layer effect-time
hold (docs/08 §3.25, docs/impl/temporal-rerender.md §4).** The second Posterize scope holds only
the layer's **own effect stack** on the coarse grid — its transform and source stay live, so
the layer moves smoothly while its effect animation steps. No re-render of other layers, no
orchestration re-entry (the simple cousin of *Everything below*). The held effect time is
`lumit_core::fx::this_layer_effect_time(effects, fx_on, lt, start_offset)` — the grid computed
on comp time `lt + start_offset` (matching *Everything below*'s comp-time hold), mapped back
into the layer's own base, and `lt` unchanged when the stack has no live *This layer* Posterize.
Both `build_comp_draws_at` (preview) and export's `apply_fx` compute it and feed it to
`resolve_stack_temporal` as the sample time (with `lt` as the frame time, so a
`sample_temporally == false` effect still resolves at the live playhead, K-132), so preview
equals export (K-031). With no this-layer Posterize this is byte-identical to the previous
`resolve_stack`, so ordinary layers are unchanged. Concurrent-worktree risk: another agent may
also claim K-133 — renumber on merge if so. Built in an isolated worktree; not pushed.

**K-134 · DECIDED · Accumulation motion blur ships: the second temporal re-render effect
(docs/08 §3.26, docs/impl/temporal-rerender.md §3).** The expensive, correct motion blur — it
re-renders the whole scene below at N sub-frame times and averages the finished frames, so
footage motion, animated effects, depth passes and the camera are all correct per sample (no
blurred-depth artefact). An **adjustment** effect detected exactly as Posterize is; it resolves
to no per-pixel op, so the detection keeps the adjustment live. The sub-frame times reuse the
per-layer motion-blur shutter maths (`MotionBlur::sample_offsets`, so `τ_k = t + off_k·dt`) via
`lumit_core::fx::stack_accumulation_mb` → `AccumulationMbParams`. The combine is a **new** GPU
pass, `Compositor::accumulate(&[(&Texture, weight)])` over a premultiplied-passthrough fragment
`fs_accumulate` (the inputs are already-premultiplied comp composites, so — unlike per-layer
`motion_blur_average`, which premultiplies a straight-alpha source — it must NOT re-premultiply);
colour AND alpha add, so a static scene is unchanged. Preview (`Realiser::accumulate_below`) and
export both render the N sub-frames through the one shared `render_below_at`, average at `1/N`,
then blend the average against the frame-time below by Mix (a second weighted `accumulate`, a
pure linear interpolation), so preview equals export (K-031). Proved by a still-scene bit-identity
test (`1/N` is exact in fp16 for a power-of-two N, the N copies sum back exactly) and a
moving-scene coverage-widening test. Params: Samples N, Shutter angle, Shutter phase, Mix; cost
Heavy (≈ N× a full comp render). Honours the per-effect `sample_temporally` flag (K-132) via the
shared `below_draws_at` threading. **Boundaries (v1):** temporal effects inside the sampled
below-stack hold to stills (K-125); an accumulation adjustment inside a collapsed Precomp is a
no-op (its sampled draws are sized for the nested comp); it takes precedence over Posterize when
an adjustment somehow carries both; sub-frame sample-count reduction under draft/scrub is a
tracked follow-up (full N always on export). Concurrent-worktree risk: another agent may also
claim K-134 — renumber on merge if so. Built in an isolated worktree; not pushed.

**K-135 · DECIDED · Effect parameter ranges prefer real/pixel units with open ceilings over
0–1 or percentage caps.** From the owner (2026-07-19). Unless a parameter's name carries a `%`
or a 0–1 ratio is genuinely its natural unit (a "roundness" that is literally how-circular, an
opacity, a mix), a built-in effect parameter should read in real or pixel units with a
one-sided `0..∞` (or wider signed) hard range rather than a 0–1 or fixed-percentage cap — the
maths almost always extrapolates cleanly past the old cap, and an editor should not hit a wall
wanting more. This continues the K-090 one-sided-range amendment, applied as a sweep across the
shipped grade/stylise effects:
- **Saturation** (§3.10) — the hard ceiling is lifted (`hard: (Some(0.0), None)`, slider to
  400 %). The luma/colour mix already extrapolates past 200 %; the CPU reference and WGSL
  kernel never clamped it, only the resolver did.
- **Vignette Softness** (§3.14) — lifted to `hard: (Some(0.0), None)`, slider to 2, kept in the
  normalised distance metric (not converted to pixels). The metric itself is not capped at 1
  (a corner reaches ~√2 under circular roundness), so a Softness beyond 1 is a legitimately
  wider feather; Amount/Radius/Roundness keep their 0–1 caps.
- **Temperature** (§3.20) — slider widened to ±150, hard to ±200, and the per-unit gain
  strengthened from `0.5·k` to `0.75·k` (`k = Temperature ÷ 100`, clamped to ±2) so full
  deflection is a decisive orange/blue; the gains floor at 0 (`max(0, …)`) so an extreme never
  drives a channel negative. 0 stays the bit-exact neutral point; CPU/GPU parity is preserved
  (gains computed host-side, as before).
- **Glow** (§3.3) — default Threshold lowered to 0.8; the **Knee** parameter's UI label renamed
  to **Softness** (the stable id stays `knee`, so saved projects and expressions are
  unaffected); **Radius** converted from % diag to **px@comp** with `hard: (Some(0.0), None)`
  (slider to 200, default 24 px), scaled by the preview factor like every px@comp parameter;
  the effect's ROI becomes `full-frame` since an unbounded px radius cannot be bounded as a
  %-diag padding (mirroring Chromatic aberration's own px@comp choice).

The changes touch schema ranges/labels and the resolve step (clamps and the glow radius unit +
the temperature gain formula) only; the CPU oracles and WGSL kernels are unchanged (they never
clamped), so K-031 preview/export parity holds automatically. Regression tests widen to exercise
the un-capped values and the temperature floor. Concurrent-worktree risk: another agent may also
claim K-135 — renumber on merge if so. Built in an isolated worktree; not pushed.

**K-136 · DECIDED · Hue shift gains a Preserve-luminance toggle (default on).** From the owner
(2026-07-19). The Hue shift effect (§3.17) adds a `preserve_luminance` bool, defaulting **on**,
which keeps today's behaviour: a constant-luminance rotation weighted by Rec.709 luma, so
perceived brightness stays put as the hue turns (a project saved before the toggle reads it as
on). **Off** switches to a plain-RGB spin about the neutral grey axis with equal weights, which
preserves the raw R+G+B sum rather than perceived luminance, letting brightness ride with the
hue. Both modes are the same SVG-`feColorMatrix` construction differing only in the luma
weights, so the resolve step simply picks which host-computed matrix
(`lumit_core::fx::hue_matrix` vs `hue_matrix_rgb`) to carry; the matrix-general CPU reference
and WGSL kernel are unchanged and stay in lock-step (K-031). 0° is the bit-exact identity in
both modes. Note for the record: the preserve-on mode is a Rec.709-weighted **linear-RGB**
rotation — the *spirit* of K-034's "hue-type operations convert through Oklab" (hold lightness,
turn hue) reached cheaply, not a literal Oklab/OkLCh rotation; a true-Oklab hue mode remains
possible future work. Concurrent-worktree risk: another agent may also claim K-136 — renumber
on merge if so. Built in an isolated worktree; not pushed.

**K-137 · DECIDED · The Blur effect splits into three: Gaussian, Directional, Radial.** Applies
K-090's "one effect, one job" to the blur family: the single mode-driven "Blur" effect (a Mode
dropdown selecting Gaussian / Directional / Radial, with every mode's parameters present at
once) becomes three separate effects in the **Blur & sharpen** category — **Gaussian blur**,
**Directional blur** and **Radial blur**. The maths, WGSL kernels and CPU oracles are untouched
(the `Resolved::Blur` / `DirBlur` / `RadialBlur` variants and their `blur` / `dir_blur` /
`radial_blur` kernels stand); only the schema and the resolve arms that read it changed.
Consequences: **Gaussian keeps match_name `blur`**, so a project saved with the old combined
effect loads as Gaussian at its stored Radius (whatever Mode it saved — the now-unread
mode/length/centre params are ignored); Directional (`directional_blur`) and Radial
(`radial_blur`) are new match names. The Mode parameter is gone. **Length** (Directional) and
**Amount** (Radial) become **hard-unbounded above** (sliders to 200 and 100 respectively) now
each is its own effect rather than sharing the family's reach — cost stays bounded because the
tap counts clamp (`cpu::dir_blur_taps` / `radial_blur_taps`). The shared **Edges** control
(Transparent / Repeat / Mirror) is kept **only on Radial**; Gaussian and Directional resolve at
the old default, Repeat, so their look is byte-unchanged. Add-effect menu, command palette and
preset paths are all BUILTINS-driven, so the three appear automatically. Spec:
[08-EFFECTS.md](08-EFFECTS.md) §3.8. Built in an isolated worktree; not pushed.

**K-138 · DECIDED · The Sharpen effect is really an unsharp mask; a plain Sharpen joins it.**
The v1 "Sharpen" effect (§3.9) was an unsharp mask (gaussian-based detail lift with Radius /
Threshold / luminance-only). K-138 renames its **label** to **Unsharp mask** — match_name stays
`sharpen`, so saved projects are unchanged — and adds a separate, single-purpose **Sharpen**
(match_name `sharpen_simple`): a fixed 3×3 high-pass convolution scaled by one **Amount**
(`out = u + amount·(4·u − up − down − left − right)` per RGB channel, clamp-addressed
neighbours), on unpremultiplied colour (§2.2), alpha kept. Amount 0 (whatever the Mix) and Mix 0
are the bit-exact passthrough (the kernel and CPU reference both short-circuit). Full 4-site
build: schema (`builtins.rs`), `Resolved::SharpenSimple` + resolve arm (`resolved.rs`), CPU
reference `cpu::sharpen_simple` (the oracle), the `fx_sharpen_simple.wgsl` kernel dispatched
from `run_ops`, and the `wgsl_sharpen_simple_matches_the_cpu_oracle` parity test (cheap class,
≤ 2 fp16 ULP). Both effects sit in **Blur & sharpen**. Spec: [08-EFFECTS.md](08-EFFECTS.md)
§3.9. Built in an isolated worktree; not pushed.

**K-139 · DECIDED · The accumulation temporal effect is *the* "Motion blur"; it gains "Force on
all layers" (docs/08 §3.26).** The accumulation re-render effect (K-134) is renamed from
"Accumulation motion blur" to plain **Motion blur** — the correct, whole-scene kind takes the
user-facing name — and the optical-flow effect (§3.2) is renamed to **Fast motion blur** so the
two never collide (the per-layer transform motion-blur *switch*, K-120, is untouched — it is a
layer switch, not an effect). New bool parameter **Force on all layers** (default off): during
each sub-frame sample render every layer's own per-layer motion blur (K-120) is forced on, the
effect's own Shutter angle/phase/Samples standing in for the comp master and each layer's switch,
so one effect blurs every moving layer without toggling each one and each accumulation sample is
itself transform-smeared (smoother at low sample counts). Implemented WITHOUT mutating the comp:
`AccumulationMbParams::forced_layer_mb()` hands a `MotionBlur` to `below_draws_at`, which drops
it onto the sample render's cloned comp master and every layer switch — the document and the
live-below composite are untouched, and preview and export drive the identical forced sample
render (K-031). Boundary: the force reaches the top-level below layers; nested-Precomp inner
layers keep their own switches (a v1 follow-up). Renaming is label-only — the `accumulation_mb`
/ `motion_blur` match names and saved projects are unchanged. Concurrent-worktree risk: another
agent may also claim K-139 — renumber on merge if so. Built in an isolated worktree; not pushed.

**K-140 · DECIDED · Fast motion blur scales the streak by a smooth confidence, not a hard gate,
and gains a View enum (docs/08 §3.2, docs/impl/optical-flow.md §4).** The optical-flow motion
blur (§3.2, renamed to **Fast motion blur** in K-139) left hard un-blurred cut regions wherever
the patch-based flow was unreliable (occlusions, motion boundaries). Fix: the decode worker now
computes a per-pixel **confidence** in 0..1 alongside the flow — `lumit_flow::confidence(fwd,
bwd)`, the raw forward–backward consistency mapped 1 (agree) … 0 (disagree, at the same rel/abs
scale the binary occlusion cut uses; an invalid patch fully suspect), 3×3 box-blurred so the
taper has no seam — and the kernel scales each pixel's **streak length** by it (`sv = flow ·
shutter_frac · conf`). Suspect regions fade toward unblurred smoothly instead of cutting;
confidence 0 is a bit-exact passthrough for that pixel, composing with the existing zero-motion
and zero-shutter passthroughs. The confidence rides in a new `.z` channel of the flow texture
(now `rgba32float`, not `rg32float`; Datamosh shares it and reads only `.xy`, so it is
unaffected). New **View** enum parameter (*Rendered* | *Motion vectors* | *Confidence*, default
Rendered): the diagnostic views output the flow colour-coded or the confidence as greyscale.
Full CPU/GPU parity is kept — `lumit_core::fx::cpu::motion_blur` gains matching `conf`/`view`
arguments and stays op-for-op with `fx_motionblur.wgsl` at the cheap-class ≤ 2 fp16 ULP oracle
bound; preview and export compute confidence with the identical deterministic function (K-031).
Concurrent-worktree risk: another agent may also claim K-140 — renumber on merge if so. Built in
an isolated worktree; not pushed.

**K-141 · DECIDED · Comp playback audio is kept in step with the document by a per-frame
signature, not baked once (GEN-4 audio fixes).** The comp mix (`export::mixdown` of the
audible footage layers, laid on the strip by `lumit_audio::mix::place_on_timeline`) was baked
into one flat buffer when playback started and never revisited, so muting, moving, trimming or
deleting an audio layer had no effect on what played — the four owner-reported GEN-4 bugs.
Fix: beside the loaded mix Lumit stores a **signature** (`audio_jobs_signature`: the ordered
contributing layers with their in/out/offset, plus the comp length). Each UI frame
`sync_comp_audio` derives the current jobs from the live snapshot and, via the pure
`comp_audio_sync`, either leaves a matching mix alone, re-bakes a stale one, or **unloads** a
mix whose comp has fallen silent (every audio layer muted or deleted) so it stops sounding at
once. `toggle_play` replays the loaded mix only when its signature still matches; otherwise it
re-bakes. Deliveries from the background bake carry their signature and are dropped by
`poll_comp_audio` if a newer edit has superseded them, so a stale mix never lands. Muting stays
a decode-skipping filter in `comp_audio_jobs` (a muted layer is never decoded); the signature
machinery makes that filter, and the placement, take effect live. Cost: one cheap hash of a
handful of layers per frame while a comp's audio is managed (loaded, in flight, or playing);
idle comps are untouched. A full per-audio-block re-mix from cached decoded sources (so edits
apply with zero re-decode latency) is the natural next step but was deferred as a larger
refactor of the single-baked-buffer engine. Built in an isolated worktree; not pushed —
another agent may also claim K-141, renumber on merge if so.

**K-142 · DECIDED · Layer-input source is a three-way combobox, not a before/after bool
(revises K-125).** A track matte's source and an effect's Layer-reference input (the Depth of
field depth layer) each replace K-125's "after effects" bool with a **source** combobox beside
the layer picker offering **None** (the referenced layer's raw footage/solid — no masks, no
effects), **Masks** (its source plus its own masks, no effects) and **Effects and masks** (its
finished picture — the source's effects and masks run in first; K-125's `after_effects = true`).
A shared `LayerInputSource { None, Masks, EffectsAndMasks }` (lumit-core) carries the semantics:
`applies_masks()` gates the source's masks, `folds_effects()` runs its stack. `None` samples the
source with its masks **cleared** (a masks-stripped clone through the same `pixels_for`/`prepare`
the preview and export already share, so preview == export, K-031); `Masks` and `Effects and
masks` reuse the existing source-only and after-effects paths. Storage: the matte carries
`MatteRef::source` (replacing `after_effects`), migrated on load by a serde shim
(`after_effects: true` → `EffectsAndMasks`, `false` → `Masks`, absent → the default); a layer-input effect
carries a sibling `<id>_source` Choice, read by `EffectInstance::layer_source`, which falls back
to the legacy `<id>_after_effects` bool so old DoF projects still key and render correctly
(the removed `depth_after_effects` schema param). The frame key hashes the mode discriminant in
place of the old bool byte (0/1/2), so switching modes retires stale frames, and still folds the
source stack only for `EffectsAndMasks`. **Default and migration (owner-decided):** a new
matte/depth input defaults to **Effects and masks** — the most complete source is the sensible
default. Because the historical source-only path (`after_effects = false`) already applied the
referenced layer's *masks* (via the shared `pixels_for`), the faithful migration of the old bool
is `true → EffectsAndMasks`, `false → Masks` (so no masks are dropped); a matte predating both
fields takes the default. The v1 temporal boundary is unchanged (echo/flow on the source still
degrade to a still).

**K-143 · DECIDED · A reusable three-colour channel picker, and RGB split gains per-channel
amounts.** From the owner (2026-07-19), the P2 + FX-9 channel-split work.
- **The three-colour channel picker (P2).** A small reusable inspector widget shows three
  colour swatches (defaults red / green / blue), each opening the colour picker, for effects
  that split a picture into three tinted channels. It is convention-driven: any effect whose
  schema declares three `ParamKind::Colour` parameters named `channel_colour_1`,
  `channel_colour_2`, `channel_colour_3` renders them as one compact swatch row instead of
  three separate colour rows — the widget (`shell::inspector::channel_picker`) finds the group
  by those ids, so a future three-tinted-channel effect adopts it with no new UI code. The three
  colours are ordinary scene-linear Colour parameters, so they serialise and animate through the
  existing model unchanged. First adopter: Chromatic aberration (K-144).
- **RGB split per-channel amounts (FX-9).** RGB split (§3.6) gains three per-cent scales —
  **Red** / **Green** / **Blue** (defaults 100 / 0 / 100, hard-open both sides per K-135) — that
  multiply the overall Amount per channel: R and G displace along −offset, B along +offset, so
  the defaults reproduce the classic split bit-for-bit while letting R and B fringe by different
  amounts (or G leave its anchor). They apply to the classic (non-Wavelength) mode only.
- Build: `Resolved::RgbSplit` gains a `scale: [f32; 3]`; the CPU reference
  (`cpu::rgb_split`), the `fx_rgbsplit.wgsl` kernel and the `RgbSplitOp` carry it, and green
  is now read through the same `bilinear` sampler as R and B (at scale 0 it lands exactly on
  its own pixel, so the classic look is byte-identical). CPU/GPU parity and the
  `wgsl_rgb_split_matches_the_cpu_oracle` test hold (K-031). Built in an isolated worktree; not
  pushed — another agent may also claim K-143, renumber on merge if so.

**K-144 · DECIDED · Chromatic aberration adopts the channel picker and RGB split's Wavelength
machinery; the spectral dispersion becomes a user-controlled variable-sample count.** From the
owner (2026-07-19), the FX-10 + FX-9 spectral work.
- **Chromatic aberration (§3.15)** becomes three tinted radial taps at offset fractions −1 / 0 /
  +1, each sampled and multiplied component-wise by one of the K-143 channel colours and summed.
  Defaults red / green / blue keep only their own channel, reproducing the historical
  R-outward / B-inward / G-anchor split bit-for-bit; the three colours are edited through the
  reusable picker (K-143). It also gains a **Wavelength** Bool + **Samples** control that reuse
  §3.6 RGB split's own spectral machinery — turning Wavelength on resolves the effect to a radial
  `SpectralSplit`, so no second dispersion kernel exists. The channel colours apply to the
  non-Wavelength mode only.
- **Variable-sample spectral dispersion (FX-9/FX-10).** The Wavelength mode of both RGB split and
  Chromatic aberration carries a **Samples** count (`3..=64`, default 16, replacing the fixed nine
  taps). More taps fill the same `±offset` span more densely, so a large offset disperses as a
  smooth rainbow instead of a few discrete stacked copies. The taps — each a column-normalised RGB
  weight plus its offset fraction — are resampled from the nine `SPECTRAL_BASIS` anchors host-side
  (`fx::spectral_taps` / `spectral_basis_uniform`) and shared by the CPU reference and the WGSL
  kernel (which reads each tap's offset fraction from the vec4 `w` lane), so a uniform image still
  passes through unchanged and preview equals export (K-031). The floor is 3, not 2, because two
  taps (the red and blue ends alone) carry no green weight. Legacy Wavelength instances saved
  before the control existed read the default 16, a denser look than the old nine.
- Build: `Resolved::SpectralSplit` gains a `samples: i32` (staying `Copy`; the taps are rebuilt
  from it on both paths); `Resolved::ChromaticAberration` gains `tints: [[f32; 3]; 3]`. The
  `SpectralSplitOp`/`fx_spectral.wgsl` uniform carries a fixed 64-entry tap array plus a `count`;
  `ChromaticAberrationOp`/`fx_chromatic.wgsl` carries the three tints. Full 4-site + oracle
  (`wgsl_spectral_split_matches_the_cpu_oracle`, `wgsl_chromatic_aberration_matches_the_cpu_oracle`,
  cheap class, ≤ 2 fp16 ULP). Built in an isolated worktree; not pushed — another agent may also
  claim K-144, renumber on merge if so.

**K-145 · DECIDED · Two reusable effect-UI primitives: a shared Edges mode enum (P3) and
schema-driven collapsible parameter groups (P4).** Factored out so effects stop re-deciding
two recurring shapes:
- **`EdgesMode { Transparent, Repeat, Mirror }`** (`lumit-core::fx`) names the one edge
  policy a transform- or displacement-domain effect applies to the border its warp reveals.
  The blur family and Shake already spoke it as loose 0/1/2 `u32` codes plus an
  `EDGE_OPTIONS` string slice; the enum makes that vocabulary a type — `code()` /
  `from_code()` are the only bridge to the wire form the resolved ops and WGSL kernels read
  (the numbers are unchanged, so nothing re-serialises), and `EDGE_OPTIONS` is now
  `EdgesMode::OPTIONS`. Radial blur's resolve flows through it unchanged; new effects reuse
  it rather than inventing an edge meaning. The Transform *effect* itself stays
  transparent-only (it passes code 0), but its shared kernel — CPU `cpu::transform` and
  `fx_transform.wgsl` — gained an `edge` parameter so Shake can dispatch through it with any
  policy; `edge = 0` is bit-identical to the old transparent-only kernel (pinned by the
  transform oracle, which now sweeps all three modes).
- **`ParamGroup`** (a `label` + a contiguous run of member param ids + a `collapsed`
  default) is declared on `EffectSchema::groups`, and the Effect Controls panel renders each
  group under a disclosure "twirl" (reusing `group_header_row`, the same header a layer's
  Transform/Effects sections use), hiding its members when closed. Driven entirely from
  schema metadata, so any effect adopts a twirl by declaring a group — no per-effect UI
  code. Every existing schema declares `groups: &[]`. Spec: [08-EFFECTS.md](08-EFFECTS.md)
  §3.4/§3.8. Built in an isolated worktree; not pushed — another agent may also claim K-145,
  renumber on merge if so.

**K-146 · DECIDED · Shake reshaped: a per-axis wobble twirl, and Edges replaces Auto-scale
(FX-11).** The Shake effect (§3.4) keeps its master Amplitude / Frequency / Rotation amount
and gains a **Per-axis wobble** twirl (the K-145 P4 group) holding per-axis **x / y / z**
amount and frequency: x and y amount/frequency are dimensionless multipliers on the master
values (default ×1 reproduces the old uniform x/y shake bit-for-bit), and **z** is the
depth/scale shake — z amount is a scale-pump per cent that **replaces the old "Zoom pump"**
(same range and meaning), z frequency a rate multiplier. The **Auto-scale** bool is
**removed** and replaced by an **Edges** control (the K-145 P3 enum, default Repeat): the
resample's revealed border is now handled by the edge policy rather than by an automatic
cover-scale that zoomed in to hide it. Shake stays seeded and deterministic (§1.3/§2.4): the
generator (two octaves of value noise per axis) and the host-side affine → Transform-kernel
dispatch are unchanged, so with default per-axis values the resolved wobble is identical to
before; only the border treatment and the new z/frequency biasing differ. **Migration:** a
project saved before FX-11 has its `zoom_pump` read as the z amount and its `auto_scale`
read as the Edges control (on → Repeat, off → Transparent) via resolve-time fallbacks, so
saved shakes keep their pump and never sprout a transparent border unexpectedly; the
Auto-scale cover behaviour itself is gone (an intentional change — the wobble no longer
zooms to hide edges). CPU/GPU parity and the §1.6 oracle hold across all three edge modes.
Spec: [08-EFFECTS.md](08-EFFECTS.md) §3.4. Built in an isolated worktree; not pushed —
another agent may also claim K-146, renumber on merge if so.

**K-147 · DECIDED · Scanlines collapses to a single Intensity (FX-13).** The Scanlines
effect (§3.12) previously carried two darken controls — **Intensity** (0–1) and **Darkness**
(%) — that multiplied into one darken amount (`eff_mult = 1 − Intensity × Darkness` on the
dark half), so two dials did one job. They collapse into a **single Intensity** (0–1 = *how
dark the dark lines get*: 0 the bit-exact passthrough, 1 takes the dark half to black); the
bright half is untouched and Line period / Roll speed / Interlace / Mix are unchanged. The
schema drops `scanline_darkness` and bumps the effect version 1 → 2. **Migration:** a project
saved with the old pair still carries its `scanline_darkness` param; the resolve arm folds it
in — the single Intensity resolves to the old `Intensity × Darkness` product — so the loaded
look is unchanged (pinned by `scanlines_migrates_old_darkness_into_intensity`). The kernel is
simplified (the dark half's base is black, band 0, so `eff_mult = 1 − Intensity`), keeping
CPU/GPU parity and the §1.6 oracle; Intensity 0 stays a bit-exact passthrough via the
early-return. Spec: [08-EFFECTS.md](08-EFFECTS.md) §3.12. Built in an isolated worktree; not
pushed — another agent may also claim K-147, renumber on merge if so.

**K-148 · DECIDED · Datamosh gains Streak length and an open Intensity ceiling (FX-14).**
The Datamosh effect (§3.12) was too subtle at its one-frame reach. Two changes: (1) the
**Intensity** hard cap lifts (K-135 value-range policy) — clamped at zero below, open above,
so a value over 1 extrapolates past the moshed frame for a punchier tear (`mix()` does not
clamp in either the CPU oracle or the WGSL kernel; 0 stays a bit-exact passthrough). (2) a new
**Streak length** (frames, default 4, hard min 1, open above) scales the flow displacement the
single warp reaches, so it predicts that many frames of motion from the -1 reference — the
accumulated smear of a long P-frame run before a clean reference frame (longer = more
smearing). The shared optical-flow texture stays `rgba32float`; only its `.xy` is read (the
`.z` confidence lane is untouched). The clean I-frame "reset" is content-driven — where the
flow is zero/unmeasurable (a still, a cut) the warp lands on the pixel itself; a
**fixed-interval** I-frame reset was considered but deferred, as it needs the comp frame index
threaded through `resolve_stack` (a broad signature change for one parameter) and Streak length
already delivers the "how much accumulated smear" control without it. The schema bumps version
1 → 2. **Migration:** an old project (no `streak_length` param) folds to the default 4-frame
reach — a deliberate look change (the effect was too subtle), the sanctioned kind K-146 also
took. CPU/GPU parity and the §1.6 oracle hold (the oracle sweeps streaks 1–4 and an over-unity
intensity). The `match_name` and label stay "datamosh" for now; a rename is wanted but
unchosen (candidate names proposed to the owner). Spec: [08-EFFECTS.md](08-EFFECTS.md) §3.12.
Built in an isolated worktree; not pushed — another agent may also claim K-148, renumber on
merge if so.

**K-149 · DECIDED · Echo gains the standard blend modes (default Screen) and a 16-echo cap
(FX-17).** The Echo effect (§3.13) previously offered three combine modes (Add / Behind / Max)
and reached at most 8 frames back. Two changes: (1) **Mode** now mirrors the comp blend set —
Normal, Add, Multiply, Screen, Overlay, Soft light, Hard light, Lighten (the legacy Max),
Darken — plus the echo-specific **Behind** (ghosting), with the **default changed to Screen**.
Each mode folds the weighted echo tap into the trail **per channel in the working linear
premultiplied space** — not the compositor's perceptual sRGB domain, because Echo composites
light trails (linear is correct there) and a single arithmetic domain keeps the CPU oracle
(`cpu::echo_blend`) and the WGSL `echo_accumulate` bit-for-bit identical. The legacy Choice
indices 0/1/2 (Add/Behind/Max) are held and the new modes appended, so a project saved before
FX-17 loads unchanged; only new instances default to Screen. (2) The **echo-count cap rises
8 → 16**: the static `temporal` window and the resolved/kernel weight arrays grow to 16
(`[f32; 16]`), so up to 16 neighbour frames are decoded when Echo is live — a Spacing control
and a dynamic window (the eventual 1–32 of the spec's parameter line) remain later
refinements. The schema bumps version 1 → 2. CPU/GPU parity and the §1.6 oracle hold: the
oracle sweeps every mode (the additive trio two-tap at ≤4 fp16 ULP, the
multiplicative/perceptual modes single-tap at ≤8, the looser bound justified by their local
slope amplifying the fp16 quantisation of the current frame against HDR neighbours — still
orders of magnitude tighter than any formula error). Spec: [08-EFFECTS.md](08-EFFECTS.md)
§3.13. Built in an isolated worktree; not pushed — another agent may also claim K-149,
renumber on merge if so.

**K-150 · DECIDED · A new layer's transform centres its anchor on its own content (FX-20).**
A freshly added layer defaults its **anchor** (origin) to the centre of its *own* pixel
content and its **position** to the composition centre, so it appears centred and pivots
about its middle under scale and rotation — the After Effects default the glossary already
describes ([01-GLOSSARY.md](01-GLOSSARY.md) §2, "New layers default their anchor to the
centre of their content"). Sized per layer kind: **footage** by the footage's natural pixel
size (comp size until the probe lands), **precomp** by the nested comp's size, **solid** by
the `SolidDef`'s own size, **sequenced layer** by the comp (a "fancy precomp", K-071), and
comp-sized kinds (**adjustment**) by the comp. One private helper,
`AppState::centred_transform(nat_w, nat_h, comp_w, comp_h)`, is the single wiring point every
add-layer path routes through, so the rule cannot drift between kinds. Two deliberate
exceptions: a **camera** is a viewpoint, not a picture, so it keeps position at the comp
centre with no content anchor; a **text** layer keeps its origin at the text insertion point
(anchor 0,0) because its content size is only known after glyph layout, matching AE's
point-text convention. Only *new* layers default this way — saved projects load their stored
transforms unchanged (the transform is serialised in full). Added 2026-07-19 at Mack's
request. Built in an isolated worktree; not pushed — another agent may also claim K-150,
renumber on merge if so.

**K-151 · DECIDED · Blend modes gain Darken and Subtract (GEN-1).** The layer blend-mode set
adds **Darken** (`min(dst, src)` per channel) and **Subtract** (`dst − src` per channel,
clamped at black). Darken is domain-invariant (per-channel min commutes with the monotone
transfer function) and runs in linear alongside Lighten. Subtract runs in **linear light** —
it is Add's darkening twin, the physical removal of light — not in the encoded/perceptual
domain, and clamps at zero so it never produces negative light. Both take the compositor's
snapshot path (like Screen and the per-channel min/max modes), so layer opacity and mattes
mix by coverage correctly; the premultiplied-alpha maths is the shared
`rgb = mix(dst, blended, a)`, `a_out = a + dst_a·(1−a)` every snapshot blend uses. Darken was
already present in the enum, the UI dropdown and both GPU mappings when this work began; GEN-1
adds Subtract to match. CPU/GPU parity holds (the compositor's inline oracle tests pin each
mode's formula). Spec: [06-RENDER-PIPELINE.md](06-RENDER-PIPELINE.md) §3.5. Added 2026-07-19 at
Mack's request. Built in an isolated worktree; not pushed — another agent may also claim
K-151, renumber on merge if so.

**K-152 · DECIDED · Vibrancy, a saturation-aware colour effect (GEN-2).** A new **Colour**
effect complementing Saturation (§3.10): where Saturation scales colourfulness uniformly,
**Vibrancy** raises it *more* for less-saturated pixels and *less* for already-vivid ones, so
near-neutrals and skin tones lift while saturated regions are protected from clipping. One
**Amount** dial (per cent): 0 is the neutral, bit-exact identity; the slider reaches a heavy
200 and typing higher pushes further (value-range policy K-135, open above, floored at 0). The
maths, in linear light on unpremultiplied colour (§2.2) exactly like Saturation: measure each
pixel's HSV-style saturation `sat = (max−min)/max` (clamped to 0..1, scale-invariant), form a
per-pixel factor `1 + amount·(1−sat)`, and scale colour about Rec. 709 luma by it, clamped at
zero and re-premultiplied. Built to the four-site pattern (schema → Resolved + resolve → CPU
reference oracle → WGSL kernel → the `wgsl_vibrancy_matches_the_cpu_oracle` parity test), so
preview equals export (K-031). Spec: [08-EFFECTS.md](08-EFFECTS.md) §3.10. Added 2026-07-19 at
Mack's request. Built in an isolated worktree; not pushed — another agent may also claim
K-152, renumber on merge if so.

**K-153 · DECIDED · Layers sit freely across the comp boundaries (GEN-3).** From the owner
(2026-07-19). A layer in the lane area may start **before comp time 0** (`in_point` and
`start_offset` may be negative) and end **past the comp duration** (`out_point` may exceed
it); only `out > in` is still enforced. The engine renders and plays a layer solely where its
span `[in_point, out_point)` **intersects the comp window `[0, comp_end)`** — out-of-window
frames are never sampled — so an over-hanging head or tail is carried without data loss and is
recoverable by sliding the layer. This is already how presence is gated (`t ∈ [in, out)` for a
`t` that only ranges over the comp window) in the evaluator, the preview job collector and the
exporter, and how audio places (`place_on_timeline` + `mix_stereo` clip a negative-offset head
and a past-the-end tail to `[0, comp_end)`); GEN-3 removes the *authoring* clamps that stopped
the model reaching those states. Consequences:
- The lane **move drag** no longer clamps a layer's start to 0 (`moved_span` converts through a
  sign-preserving `rational_at_signed`, not the ≥ 0 `rational_at`); frame/marker snapping is
  unchanged. Trim-edge and keyframe times stay ≥ 0 (layer-local times never precede 0).
- **Import never trims a long clip to fit.** A footage layer keeps its full media duration and
  a Precomp layer its full nested duration, positioned from the comp start
  (`add_footage_to_comp` / `add_precomp_to_comp`), instead of clamping the out point to the
  comp — matching the "layers extend beyond bounds without data loss" invariant in
  [03-DATA-MODEL.md](03-DATA-MODEL.md) §5.1. Preview == export and determinism are unaffected
  (the render/decode/audio paths already only sample the intersection). Known v1 limit: the
  timeline view does not scroll to negative time, so a bar that starts before 0 is drawn
  clipped at the lane's left edge (its in-window body stays grabbable). Built in an isolated
  worktree; not pushed — another agent may also claim K-153, renumber on merge if so.

**K-154 · DECIDED · Matte key becomes a Keylight-style colour-difference keyer (docs/08
§3.21, FX-21).** The K-121 chroma-distance key is expanded (same `matte_key` effect, version
1 → 2) into a proper greenscreen keyer with the strength/balance/clip/despill controls a
colourist expects from Foundry's Keylight. The screen matte is a **colour difference**, not a
distance: the **Screen colour**'s largest channel is the *primary* axis (green for a green
screen, blue for a blue one — a general improvement over the hue-agnostic distance metric),
the two others are *secondaries* blended by **Screen balance** into a reference, and a
pixel's `primary − reference`, normalised by the screen colour's own difference, gives `raw`
(1 on the exact screen, 0 on a neutral); `matte = clamp(1 − gain·raw, 0, 1)` with **Screen
gain** scaling the fall-off. **Alpha bias** subtracts a bias-colour neutral (grey ⇒ no-op) so
a tinted bias re-defines neutral; **Clip black/white** remap the matte's ends and **Clip
rollback** eases them back toward the un-clipped matte to recover fine detail. **Despill**
pulls the primary channel down toward the (**Despill bias**-shifted) secondary reference by
the **Despill amount**, draining screen tint; **Replace method** (Source / Hard / Soft /
None, default Soft) then recolours where spill was removed, Soft scaling the **Replace
colour** by the pixel's brightness. A **View** enum (Final result / Screen matte / Status)
lets the user see the matte they are pulling; the Status view is a *continuous* heat
(`4·m·(1−m)` tint) so it stays oracle-safe. It still runs on straight colour (§2.2,
`premultiplied: false`) and stays `cheap`/`exact`/`{0}`. Every step is `clamp`/`min`/`max`/
`mix` — **continuous everywhere** — and the screen's primary axis and reference are derived
from the resolved Screen colour identically on the CPU reference (`cpu::matte_key`, the
oracle) and the WGSL kernel (`fx_matte_key.wgsl`), so preview == export (K-031) and the §1.6
oracle holds to ≤ 2 fp16 ULP (test `wgsl_matte_key_matches_the_cpu_oracle`, sweeping gain /
balance / clips / despill / replace / bias colours and all three views over a near-screen /
far-from-screen / partial-alpha / HDR corpus). Colour, bias and replace swatches render
through the existing `ParamKind::Colour` inspector arm (each with the eyedropper); the Screen
matte controls sit in a K-145 `ParamGroup` twirl. There is **no neutral no-op default** (the
default green + 100 % gain keys out of the box, §1.2); **Mix 0 is the bit-exact identity**,
pinned by test. **Migration:** a project saved before K-154 keeps its stored `key` (Screen
colour) and `spill` (now Despill amount); its now-unread `tolerance`/`softness` are superseded
by gain/balance/clip, and the new controls take their Keylight defaults — resolve reads every
new parameter with an `unwrap_or(default)`, so no old project faults and none re-serialises
until edited. Distinct from the Tier 2 §4 keying suite (luma/screen key) still tracked
separately. Builds on K-121 (which it supersedes without editing). Built in an isolated
worktree; not pushed — another agent may also claim K-154, renumber on merge if so.

**K-155 · DECIDED · The spatial and layer-input Keylight controls are a deferred follow-up
(docs/08 §3.21).** The pointwise K-154 landing deliberately leaves out the Keylight features
that are *not* a single pointwise pass, so each can arrive with its own oracle rather than
being half-implemented: the **spatial screen-matte controls** — Screen pre-blur, Screen
shrink/grow (morphological erode/dilate), Screen softness (blur), Screen despot black/white
(speck removal) — which need a multi-pass morphology/blur pipeline and a costlier oracle
class; the **Inside/Outside garbage masks**, a layer-input holdout reusing the DoF
layer-reference plumbing (`ParamKind::Layer`, docs/impl/layer-input.md) with per-mask softness
and invert; the **Colour correction** twirls (Foreground and Edge: enable + saturation /
contrast / brightness / colour balance, Edge adding hardness / grow); and the **Source crops**
(per-axis edge method — Colour / Repeat / Reflect / Wrap — an edge colour, and Left / Right /
Top / Bottom crop amounts). None is required for "properly key footage" — the K-154 core
(screen matte + clips + despill + views) is — so they are ordered after it and tracked here.
When they land, each keeps the K-031 preview==export and §1.6 oracle guarantees. Numbered
K-155, alongside K-154; renumber on merge if another agent also claims it.

**K-156 · DECIDED · "Save stack as preset" saves the current selection, not always the whole
stack (docs/07-UI-SPEC.md §7, UI-10).** The Effect Controls → Presets "Save stack as preset…"
now writes exactly what the user has highlighted, decided by the existing selection model — the
effect-row selection (`selected_prop`/`selected_props`) and the lane keyframe selection
(`lane_selection`), both restricted to the layer being saved. The rule (pure, tested in
`preset::selection_subset`): with **nothing highlighted** it saves the whole stack, so the old
behaviour is the fallback; otherwise it saves **every effect the selection touches** — a
highlighted parameter row, or a highlighted key — in stack order, and within each of those
effects any Float parameter that has highlighted keys is **trimmed to just those keys**. A
parameter with no highlighted keys keeps its value exactly as set, including any full animation
the user did not single a key out of; a stale selection (a key edited away, an effect removed)
simply matches nothing and is skipped rather than emptying a parameter. Key times match exactly
on their stored rational, which is what the lane selection carries. The `.lumfx` format is
unchanged (a preset is still a list of `EffectInstance`s); pre-release, no migration is needed.

**K-157 · DECIDED · The Project panel's selected-item info box is fixed-height and shows a
footage thumbnail reused from the Viewer (docs/07-UI-SPEC.md §3.1, UI-4).** The info box keeps a
constant height (`PROJECT_HEADER_HEIGHT`) whatever is selected — drawn into a reserved,
clipped rect — so choosing different items never shifts the tree beneath it. For footage it
shows a small thumbnail on the left: the **Viewer's own decoded frame**, passed through to the
panel and drawn aspect-fitted, guarded so it is used only when that texture really is the
selected item's picture (`preview_comp` unset and `preview_item` equal to the item). No new
decode path is added (a dedicated proxy/thumbnail cache and hover-scrub, spec §3.1, stay a later
step); when no frame is to hand — still probing, a pop-out with no texture, or a non-media build
— a neutral placeholder carrying the footage glyph stands in. Paired with the panel-wide search
field (UI-3), which filters the tree live by name (case-insensitive substring, subtree-aware so
the path to a hit stays visible) per the existing spec §3.1 and needs no separate decision.

**K-158 · DECIDED · Every property row in the layer area — transform, effect and Retime —
shares one selection, keying and navigator model (owner parity rule: transform and effect
properties look and behave the same unless specified otherwise).** Four threads land together:
(1) **UI-1 — linked pair rows no longer clip their value boxes.** The Anchor/Position/Scale
rows carry a chain-link control plus one or two value boxes in the narrow outline column; the
boxes were shaved at the column's right edge. The fix caps each pair value box at a fixed
width (`PAIR_VALUE_W`) and tightens the row's inter-widget gap and button padding
(`pair_row_tighten`), so `[x][link][y]` fits without clipping; single-axis rows keep their
full-width box. Pixel-layout only, no model change. (2) **UI-6 — effect parameter rows and the
footage Retime "Time"/"Velocity" row join the transform rows' multi-select model.** All three
route their name/row click through one shared gesture (`prop_click_select`): a plain click
single-selects (and, for transform/Retime, opens the curve), Ctrl/Cmd toggles, Shift ranges
over the frame's draw order — which now records transform, Retime and effect rows alike, so a
range or a mixed set can span all three. A new `PropRow::Retime` variant names the single
per-layer Retime channel. The Effect Controls panel builds and resolves its own draw order each
frame, mirroring the Timeline, so the two panels never tread on each other's range resolution.
(3) A command-palette action **"Key selected properties"** (`AppState::key_selected_props`)
keys every selected row at the playhead in one undo step, each holding its current value —
transforms as `SetTransformProperty`, effects folded per layer into one `SetLayerEffects`, and
the Retime channel as a velocity-lens speed key (lens-independent and media-free, so a mixed
keying is deterministic). (4) **One shared `◄ ◆ ►` keyframe navigator** (`keyframe_navigator`
returning a `KeyNavAction` the caller commits) replaces the four drifted copies used by
transform single props, transform linked pairs, the Retime row and effects — the
Position/Anchor and Retime rows had kept the older `Keyframe`/`KeyframeAdd` glyphs instead of
the effect navigator's `KeyframeFilled`/`Keyframe` look. The only per-row deviation the shared
navigator supports is the Retime lens's structural endpoint keys (removal disabled there).
(5) The **Retime "Time" value drag now drives the live preview** like transform (`prop_edit`)
and effect (`fx_edit`) drags: a new `AppState::retime_edit` field carries the provisional
retime store, and — because a retime change alters *which source frame* is on screen rather
than how an already-decoded frame composites — the decode job builder overrides the layer's
retime with it and re-decodes, rather than re-compositing. Backwards compatibility is not
required (pre-release). Built in an isolated worktree; not pushed — renumber on merge if
another agent also claims K-158.

**K-159 · DECIDED · The Timeline outline and lane/graph areas scroll together in the layers
view but independently in the graph view (UI-8).** In the ordinary **layers view** the layer
outline (the left column of property/layer rows) and the lane area to its right share **one**
vertical scroll: a single wheel or scrollbar moves both, synced, so a row's outline controls
and its bar never drift apart. In the **graph view** the lane area becomes the curve editor,
which pans and zooms its own value axis on the wheel (K-079); the outline is therefore given
its **own** vertical scroll, its scrollbar pinned to the **right edge of the outline column**
(not at the far right, over the curve). The two are then fully decoupled — a wheel over the
curve never scrolls the layer list, and the list scrolls on its own bar or on a wheel over the
outline column. Mechanically this is the one lane `ScrollArea` capped to the outline's width in
graph mode and spanning the whole panel in the layers view: an egui scroll area only reacts to
the wheel over its own rectangle, so once it stops at the outline's right edge the curve's wheel
never reaches it, and the earlier stop-gap (freeing the curve's wheel by zeroing the shared
scroll's `smooth_scroll_delta`) is removed. The wheel's destination is decided by a small pure
router, `timeline_wheel_route`, unit-tested per mode. In the speed lens — which has no vertical
pan — a plain wheel over the curve simply does nothing, consistent with the decoupling (the list
still has its own bar). Refines K-079 (which established that the curve and the layer list scroll
on separate wheels) without reversing it; no other decision changes. Built in an isolated
worktree; not pushed.

**K-160 · DECIDED · The Flow input rate is a keyframeable value field, not a preset
dropdown.** From the owner (UI-11): the Flow group's **Input rate** (the conform fps of
K-095) becomes a numeric field the user types any rate into — with the usual stopwatch and
◄ ◆ ► keyframe navigator — replacing the Native + common-rates dropdown. It is **keyframeable
like any other property**, so the conform rate can ramp over the clip. Storage changes cleanly
(pre-release, no migration): `FlowParams.input_fps` moves from `Option<f64>` to an
`anim::Property`, read at frame time through the new `FlowParams::input_fps_at(lt)`; `0` (the
default, and any value that rounds to it) means **Native** — the source's own rate — so a
keyframe ramp from Native to a real rate resolves without a discontinuity. A plain Native rate
stays out of the serialised file (`skip_serializing_if`), so an un-animated Native flow clip
writes exactly as before. The frame-cache key hashes the value the property reads at each local
time (superseding the K-095 single hashed fps), so an animated rate keys each frame distinctly
and preview still equals export (K-031). This supersedes the "dropdown offers Native and common
rates" detail of K-095 (which stays otherwise intact — the conform semantics are unchanged).
Built in an isolated worktree; not pushed — renumber on merge if another agent also claims
K-160.

**K-161 · DECIDED · RGB split becomes a linear tinted-tap fringe; Radial mode is dropped;
it gains the shared three-colour picker (T17).** From the owner (testing T17): §3.6 RGB split
loses its **Radial** mode entirely — the always-radial shape is already owned by §3.15
Chromatic aberration (K-143/K-144), so the mode was redundant. In its place RGB split gains the
same reusable three-colour picker chromatic aberration carries (`channel_colour_1/2/3`, default
red / green / blue), tinting its three offset taps. The classic behaviour is preserved
bit-for-bit: each tap is now sampled in **full colour** and multiplied by its tint before the
three are summed, and with the default primary tints (`[1,0,0]`/`[0,1,0]`/`[0,0,1]`) that
reduces exactly to the historical channel-separated split (`split.r = tap0.r`, `split.g =
tap1.g`, `split.b = tap2.b`). The per-tap **Red / Green / Blue** displacement scales (FX-9,
K-143) stay, now labelled as scaling their like-numbered tint. `Resolved::RgbSplit` drops
`radial` and gains `tints: [[f32;3];3]`; the GPU `RgbSplitOp`/kernel lose the radial branch and
`amount_px`, gaining the three vec4 tints. Wavelength mode still resolves to `SpectralSplit`,
now always `radial: false`. Pre-release, no migration: instances saved with a `radial` param
simply ignore it, and instances without the tint params fall back to the primaries. This
supersedes the "Mode (Linear / Radial)" and radial Centre/Falloff detail of K-090's §3.6 (the
Wavelength quality tier and per-tap amounts are otherwise unchanged). The A1 report — that the
picker colours do nothing in **Wavelength** mode — is not addressed here for the spectral path:
`SpectralSplit` still uses the physically-based `SPECTRAL_BASIS`, so the picker governs the
classic mode only; whether Wavelength should also be driven by the picker colours is left open
(see §3.6 Open questions). Built on `main`.

**K-162 · DECIDED · The full After Effects colour-blend set ships in v1 (T24).** From the
owner (testing T24, "add ALL After Effects blend modes"): `BlendMode` grows from the ten-mode
v1 subset to the complete AE colour set — adding Colour burn, Linear burn, Darker colour,
Colour dodge, Lighter colour, Linear light, Vivid light, Pin light, Hard mix, Difference,
Exclusion, Divide, Hue, Saturation, Colour, and Luminosity (16 new, 26 total). All run on the
existing snapshot path in the encoded (display-referred) domain — matching AE's 8/16-bit look
and the docs/06 §3.5 rationale — except the domain-invariant Darken/Lighten/Subtract, which stay
linear. The formulas are the W3C/PDF compositing set; the four HSL modes and Darker/Lighter
colour are non-separable (whole-pixel), the rest per-channel. `BlendMode::ALL` and
`BlendMode::name()` on the core enum are the single source of truth the layer dropdown and the
effect Mode param (T21) both consume, so the two never drift, and the AE group dividers come
from `blend_group_break`. `lumit_eval::blend_tag` gains stable cache-key bytes 10–25 (never
reused). A new GPU test (`perceptual_blend_modes_match_the_reference_formula`) verifies every
encoded-domain mode against a Rust reference of its formula — the compositor blends had no
oracle before. Deliberately deferred to post-v1: Dissolve / Dancing dissolve (need a dither
seed), the legacy "Classic" variants, and the alpha operators (Stencil / Silhouette / Alpha add
/ Luminescent premul, which modify alpha compositing, not colour). Extends docs/06 §3.5's own
list without reversing it. Built on `main`.

**K-163 · DECIDED · The Wavelength dispersion is driven by the three-colour picker, not a fixed
physical basis (A1).** From the owner (testing A1, resolving the §3.6 open question in favour of
"replace the basis"): the RGB split / chromatic aberration Wavelength mode no longer disperses
through the fixed physical `SPECTRAL_BASIS` (the 9-anchor CIE-derived table). Instead each
spectral tap is tinted by the effect's own three-colour picker sampled as a gradient — Colour 1
at the −offset end, Colour 2 at centre, Colour 3 at the +offset end (`tint_gradient`) — so the
picker now controls the fringe hues in Wavelength mode exactly as it does the three discrete taps
in the classic mode. The default red / green / blue reproduces the same red-at-−1 / blue-at-+1
direction the physical basis had, so the default dispersion still runs red→green→blue; other
colours re-tint it. Colour columns are normalised across the taps (guarded against a zero column)
so a uniform image passes through unchanged — the dispersion tints the fringe, never the
exposure. `Resolved::SpectralSplit` gains `tints: [[f32;3];3]`; `spectral_taps` /
`spectral_basis_uniform` take the tints; the basis is still built host-side and shared by the CPU
oracle and WGSL kernel (the kernel is unchanged, so preview == export holds, K-031). The physical
`SPECTRAL_BASIS` const and its column-sum test are retired. Pre-release, no migration. This
resolves the §3.6 open question and supersedes the "physically-based dispersion" detail of
K-090/K-144 (the smooth-many-tap machinery is otherwise unchanged). Built on `main`.

**K-164 · DECIDED · Datamosh is reimplemented as a flow-driven streamline melt with Bloom and
a periodic Reset (T19).** From the owner's test note T19 ("reimplement referencing the
well-known datamoshing technique; adjust params as needed"). The K-104/K-148 Datamosh (§3.12)
was a single motion-compensated tap — it warped the -1 source neighbour by that pixel's own
flow vector once and blended it over the current frame. T19 rebuilds it toward the genuine
datamosh look (removing I-frames so a frame's motion vectors keep being applied to the *wrong*
picture, dragging and blooming the moving regions). The new per-pixel kernel is a **streamline
walk**: starting at the pixel centre it follows the current→previous flow field out of the -1
neighbour, **re-sampling the flow at each step** (so the smear curves with the motion) and
advancing ~one frame of motion per step, then sampling the neighbour there; the samples
accumulate with a geometric weight into a melting prediction blended over the current frame.
Four params (schema version 2 → 3):
- **Intensity** (open ceiling, K-135) — blend strength; 0 the bit-exact passthrough.
- **Displacement** (frames, ≥ 1, open) — the walk's reach; the tap count is derived from it
  (~one tap per frame of motion, clamped 2–64). Supersedes K-148's `streak_length`, still read
  as a fallback so an existing instance keeps its reach (pre-release, no migration required).
- **Bloom** (0–1) — how much of the reach accumulates: 0 keeps the nearest step (a short,
  quickly-resetting trail ≈ the old single tap), 1 averages the whole walk (a long melting
  bloom). The "accumulates vs resets" dial.
- **Reset interval** (seconds, 0 = off) — the simulated I-frame period. When set, the melt
  ramps from a clean frame just after each reset up to full by the next (a sawtooth in layer
  time, computed in resolve and folded into the effective Intensity and Displacement), so the
  kernel stays time-agnostic and the frame-cache key already covers it (a param+time function —
  the K-093/K-094 reasoning; no `ALGO_VERSION` bump). It is in **seconds, not frames**, because
  the resolve step is frame-rate-agnostic — a frame-count interval needs the comp frame index
  threaded through `resolve_stack`, the broad signature change K-148 deferred, and this delivers
  the periodic-reset look without it. A **content-driven reset** still fires regardless (zero/
  unmeasurable flow at a still or cut holds the picture, where a real codec inserts its I-frame).

No new host plumbing: it keeps Datamosh's existing threaded inputs (current frame, -1 source
neighbour, one shared flow field) and its `temporal: {-1, 0}` static reach, so
`stack_flow_neighbour`/`stack_temporal_window` and the one-flow-field-per-layer rule (K-104) are
unchanged. Cost rises **cheap → moderate** (a multi-tap streamline like Motion blur's streak,
plus a flow re-sample each step); ROI stays `full-frame`, `seeded: false`. The GPU kernel
mirrors the CPU oracle (`lumit_core::fx::cpu::datamosh`) op-for-op — the same walk, tap order,
bloom weights and edge-clamp — measured worst **1 fp16 ULP** across a bloom/step sweep, within
the ≤ 2 bound. Sites: schema (`fx/builtins.rs`), `Resolved::Datamosh` variant + resolve arm
(`fx/resolved.rs`), CPU reference (`fx/cpu.rs`), WGSL kernel (`fx_datamosh.wgsl`) + `DatamoshOp`
(`lumit-gpu/src/fx/temporal.rs`) + UI dispatch (`lumit-ui/src/fxops.rs`); docs (§3.12, GUIDE).
Built in an isolated worktree; renumbered from K-161 to K-164 on merge (K-161-163 were taken by
the main session's T17 / T24 / A1).

**K-165 · DECIDED · The Shake effect's own motion blur is host-side sub-frame averaging over
a phase-domain shutter.** From the owner (T18): "Shake: add its own motion-blur twirl (toggle
+ amount), computed from inter-frame movement, applying only to this effect." Decisions:
- **Approach (a), true sub-frame averaging.** The shake wobble is a pure function of time
  (`shake_noise` at `local time × frequency`), so its motion blur samples the wobble at a
  fixed, odd count of sub-frame placements across the shutter (`SHAKE_MB_SAMPLES = 9`, the
  centre sample being the frame itself), resamples the input through each as a full
  transform-domain affine, and averages the premultiplied results — the same
  premultiplied-linear mean the accumulation motion blur uses (docs/06 §4). Translation,
  rotation and zoom all smear. This applies to **this effect's output only** — independent of
  the per-layer and comp motion blur. A dedicated one-pass kernel (`fx_shake_mb.wgsl`, up to
  9 bilinear taps) mirrors the new CPU reference `cpu::transform_average` op-for-op; the
  toggle off (or Shutter 0) is the bit-exact single resample, pinned by test.
- **The sub-frames are computed host-side.** The noise lattice uses `splitmix64`, and WGSL
  has no 64-bit integer (docs/08 §3.12), so the GPU cannot sample the noise. The resolver
  computes the 9 sub-frame `(offset, rotation, zoom)` states and the dispatch is handed ready
  affines — the same split the plain Shake already uses.
- **The shutter window is measured in the shake's own phase, not seconds.** The window spans
  `± SHAKE_MB_SPAN_BASE · amount / 2` in the noise base domain (`local time × frequency`),
  with `SHAKE_MB_SPAN_BASE = 1.0` and the Shutter amount a 0–1 fraction (default 0.5). This
  was chosen over threading a frame rate into the effect resolver: `resolve_stack` is
  deliberately frame-rate-agnostic (it carries only local time, the diagonal in pixels and
  the preview factor), and rewiring an fps through it and its many call sites for a cosmetic
  smear was not worth it. The consequence — a virtue — is that the smear is **frame-rate
  independent** (a shake motion-blurs identically at 30 or 60 fps) and still a genuine
  function of the shake's own inter-frame movement: a faster axis (higher frequency
  multiplier) advances further through its noise over the same window, so it smears more,
  exactly as real inter-frame movement would. If a seconds-anchored shutter is ever wanted,
  it is an additive change (thread fps, convert to base units at resolve).
- Two schema params in a **Motion blur** twirl (P4): `motion_blur` (Bool, default off) and
  `mb_amount` (the Shutter, 0–1, default 0.5). Off by default so existing shakes and the
  established look are unchanged; the old spec-table default of "on" (docs/08 §3.4) is
  superseded. Built in an isolated worktree against a base predating K-161–K-163; renumbered
  from K-164 to K-165 on merge (T19 Datamosh had already taken K-164).

**K-166 · DECIDED · Posterize Time loses its Scope parameter; reach is implied by the carrier
layer's kind (pass 5, T12).** The *Everything below* / *This layer's effects* choice duplicated
information the layer stack already expresses: an **adjustment layer's** effect input *is* the
composite of everything beneath it, and any **other layer's** effect input is its own source and
stack. So the parameter is gone and the hold simply covers whatever the carrier would feed its
effects anyway — Posterize on an adjustment layer steps the whole scene below (laid back by the
adjustment's coverage), Posterize on a plain layer steps that layer's own effects and source
sampling while its transform stays live. Both K-133 behaviours survive unchanged; only the
selector is removed. Orchestration sites (`posterize_below`, `posterize_sample_times`, export's
below-filter) key on `LayerKind::Adjustment` instead of the stored choice. Projects saved with a
Scope value still load (unknown params are ignored on read); the stored value is simply unread.
Pre-release, so no migration is owed (the standing backwards-compat policy).

**K-167 · DECIDED · Three-tap tint columns are normalised per output channel in the classic
split modes (pass 5, T17).** Owner report: changing the tap tints on RGB split / Chromatic
aberration shifted the whole image's exposure, not just the fringe. Root cause: the three taps
sum, so tints whose per-channel weights do not sum to 1 rescale even perfectly aligned regions.
Fix: `lumit_core::fx::normalise_tint_columns` rescales each output channel's column of tap
weights to sum to 1 (guarded below 1e-6) before resolve hands the tints to CPU or GPU — the
same rule the Wavelength gradient already applied host-side (K-163). Consequence: custom tints
only affect the parts of the picture where the taps disagree (the misaligned fringe); uniform
regions pass through at original exposure, and the default red / green / blue columns already
sum to 1, so the classic split stays bit-exact. Applied in both classic resolve arms; Wavelength
mode was already normalised.

**K-168 · DECIDED · The Timeline outline adopts After Effects' five column groups; lock and
label-colour switches enter the model (pass 5, TL2).** Left to right: **1** visibility · audio ·
solo · lock, **2** label chip · stack number · name, **3** flow-or-collapse · fx bypass · motion
blur · 3D, **4** matte · blend, **5** parent. New model surface: `Op::SetLayerLocked` and
`Op::SetLayerLabel`; `Layer.label: u8` (serde default 0, so old projects load). A locked layer's
bar, trims and stack order refuse edits (its property values stay editable — v1 lock protects
timing/order, the thing a stray drag breaks); the label chip cycles eight colours drawn from the
theme's existing roles via `Theme::label_colour` (no new hex, docs/15 §4). Neither `label` nor
`locked` feeds the frame cache key — both are organisational, never pixels. Deliberately not
built yet, each blocked on machinery it would misrepresent without: **shy** (needs an outline
filter row), **quality** (needs a bicubic sampler choice), **preserve underlying transparency**
(needs compositor support), and the **pick-whip** parent drag (the dropdown stands in, K-103).

**K-169 · DECIDED · The optical-flow engine is dense inverse search (DIS); resolves 08 Open
Question 1.** The flow field that feeds Retime's flow interpolation and Fast motion blur is
computed by **Dense Inverse Search** (Kroeger et al., ECCV 2016), not the "variational /
patch-match hybrid" the 08 §3.1 sketch first floated. DIS is the studied sweet spot: fast,
GPLv3-clean (no trained model to redistribute), and cheap enough to run per preview frame. The
exact structure — 8×8 patches on a stride-4 grid, a few Newton steps per patch, forward-backward
occlusion, box-blurred confidence — is pinned in `docs/impl/optical-flow.md` and implemented in
`lumit-flow` as a CPU oracle plus WGSL twin (K-019). A learned RAFT-class backend stays a
possible future FlowField producer behind the unchanged API (dense vectors + occlusion +
confidence); motion blur would keep using DIS vectors. This records a choice the impl note and
shipped code already made but the spec's open question still listed as pending.

**K-170 · DECIDED · The UI's worker-result channels are unbounded `std::sync::mpsc` by
deliberate choice; 14-ENGINEERING-RULES §5's "no unbounded queue without a decision entry" is
satisfied here.** The `lumit-ui` shell talks to its background threads over plain unbounded
`mpsc` channels — pre-mixed audio and comp-audio buffers, beat-detection results
(`app_state/mod.rs`), disk-cache load commands and their loaded frames (`app_state/diskio.rs`),
preview-render results (`app_state/preview.rs`), export-progress events (`export.rs`), and media
decode results (`app_state/media.rs`). None of these grows without bound in practice, for two
distinct reasons, and that — not oversight — is why they are unbounded:

- **Latest-wins mailboxes** (audio / comp-audio / beats / preview results): the UI drains the
  whole channel every frame and keeps only the newest message, so the standing depth is at most
  the handful of items a producer can emit inside one ~16 ms frame. A bounded channel would add
  `try_send`-and-drop plumbing to achieve the same effect the drain already gives for free.
- **Self-throttling work queues** (disk IO commands, media decode, export events): the UI issues
  at most one outstanding request per cache slot / per active job, so the number of in-flight
  messages is capped by the caller's own concurrency, not by the channel.

v1 therefore keeps the simpler unbounded type. The escape hatch: if profiling ever shows a
channel accumulating (a producer outrunning a stalled UI thread), the fix is a bounded
`sync_channel` with explicit latest-wins drop on the latest-wins ones, logged as a follow-up
decision — not a silent swap. The realtime audio callback stays lock-free ring-buffer reads only
and is unaffected by this entry.

**K-171 · DECIDED · Cached preview playback renders every frame and never skips; skipping is
Realtime mode's job alone.** The intended behaviour, stated by the owner (it predates this log
but was never written down): in the default **Cached** mode, playback advances to the next frame
only when that frame has rendered. When rendering is slower than realtime the playhead slows
down with it — audio pauses (v1) or timestretches to match (later) — and every frame lands in
the cache; once the span is cached, playback replays it at full speed from cache. The shipped
behaviour to date — a realtime clock that drops any frame not ready in time — is *not* Cached
mode; that clock-chasing, frame-dropping discipline belongs exclusively to **Realtime** mode
(K-030), where responsiveness is the point and resolution degrades instead. Consequences: the
playback tick gains a render-gated stepping path as the default; the audio clock is master only
while playback is actually realtime (cached replay, or Realtime mode); during slower-than-
realtime cached rendering the *frame counter* leads and audio follows or waits. 06 §6 and the
playback-scheduler impl note describe the ring/pre-roll machinery this stepping feeds.

**K-172 · DECIDED · Per-layer audio: the Volume property ships (−∞..+50 dB) and per-layer
waveform lanes replace the comp-wide strip (owner, 2026-07-21).** Three linked calls from
the owner's desk testing. (1) `Layer.volume_db` lands as the docs/09 §6 animatable dB
property — `Op::SetLayerVolume` (coarse-grained like SetTransformProperty), default 0 dB,
ceiling raised from the spec's +12 to +50, and −100 dB is the −∞ knee (gain exactly 0 at or
below; the value box reads "−inf"). A static volume is a constant gain on the placed clip;
a keyframed one bakes to a ~10 ms control-rate `GainEnvelope` read identically by the live
`MixPlan` callback and the baked export mixdown — playback == export, pinned by test.
(2) The timeline outline gains an **Audio** group (footage with an audio stream only):
the Volume row with the standard stopwatch / ◄ ◆ ► furniture, and a **Waveform** twirl
whose lane draws the layer's own decoded peaks mapped through its live in/out/offset every
paint — so dragging the layer carries its transients in realtime, the owner's report
against the comp strip (which only refreshed when the mix re-planned). (3) The comp-wide
waveform strip under the ruler is removed outright, along with its T25 toggles and the
background peaks bake (its `CompAudioMsg::Peaks` delivery). Lane keyframe diamonds for
Volume await the shared PropRow widening (the UI-11 note); fade commands and detach-audio
remain future §6 work.

**K-173 · DECIDED · A saved project never contains an absolute path; the absolute location is
session-state (TF-36, tester privacy report).** docs/10 §2 contradicted itself: it said every
reference stores "the last absolute path" AND that nothing machine-specific — "no local
usernames" — is ever written. The tester sharing a project found their username inside
(`/home/<name>/...` in every reference), which settles which half wins. `MediaRef.absolute_path`
is now `#[serde(skip_serializing)]`: it lives for the running session (probing, the resolver's
step-2 fallback) and never reaches the file; projects saved before K-173 still *load* theirs.
What the file carries instead: a **relative path rebased against the project's folder on every
save** (forward slashes, so a Windows save resolves on Linux; a cross-drive reference falls back
to the bare file name) and a **fingerprint stamped at save time** where one is missing. On open,
the previously built-but-unwired docs/10 §2 resolver now actually runs: relative path → legacy
absolute → fingerprint search across the project tree; found files repoint the session path
(this is what makes a moved project folder open intact — the tester's other half of the report),
and missing ones are named in a notice, the relink dialogue remaining future work.

**K-174 · DECIDED · A Flutter frontend alternative is built on its own branch, docs-first,
one-for-one before any redesign.** The owner wants to evaluate replacing the egui frontend
with Flutter (text rendering, motion, platform polish, widget ecosystem). The experiment
lives on `flutter-frontend-alternative`: a Dart application in `flutter_ui/` over the
unchanged Rust engine crates, specified by `docs/archive/flutter-port/` (strategy, full UI
inventory, bridge architecture, widget map, living parity checklist). Ground rules: the
first pass reproduces the shipped egui behaviour exactly — known rough edges are logged,
not fixed — so there is a truthful baseline; the glossary, no-hex-outside-theme and
tests-with-features rules bind the Dart tree as they bind Rust; engine crates never depend
on either frontend; `main` keeps shipping the egui frontend until the Flutter one reaches
parity and wins the side-by-side. The Viewer's frame path is the one piece of new systems
work (wgpu → shared D3D11 texture → Flutter texture registrar, docs/archive/flutter-port/03).

**K-175 · DECIDED · The bridge borrows lumit-ui's renderer through the headless seam until
the pixel pass moves into an engine crate.** The composited comp frame the Flutter Viewer
needs (every layer, transform, blend and effect — the pixels the egui Viewer and the
exporter show, K-031) is produced by the compositor that currently lives in `lumit-ui`
(`crate::export`'s window-free `Renderer`). To reach it without duplicating the compositor,
`lumit-ui` gains a small `headless` module (`HeadlessRenderer`, the export path made
reusable behind a GPU context it owns), and `lumit-bridge` gains a default-on `render`
feature that depends on `lumit-ui` and drives that seam through
`lumit_bridge_render_comp_frame`. This is a **deliberate, temporary** arrangement: the
bridge (a leaf, not an engine crate) depends on the UI crate here and nowhere else. The
docs/05 rule — *engine crates never depend on a frontend* — is unbroken; the bridge is not
an engine crate. When the pixel pass is extracted into an engine crate (the shared-compositor
work docs/archive/flutter-port/03 anticipates), the bridge will depend on that crate instead and the
`lumit-ui` dependency is dropped. Recorded so the dependency edge is understood as scaffolding,
not the destination.

**K-177 · DECIDED · The Viewer's zero-copy path is a D3D12 shared NT handle Flutter samples
directly, with the read-back path kept as the airtight fallback.** The recorded top
performance gap (K-176) was the Viewer's per-frame round trip: render on the GPU → read the
pixels down to the CPU → copy across FFI → upload back to the GPU. This closes it on Windows.
wgpu runs over D3D12; behind an **opt-in `shared-texture` feature** (off by default, so every
existing build and CI gate is byte-for-byte unchanged) the headless renderer reaches through
wgpu to its D3D12 device (`Device::as_hal`), creates a texture in a **shared heap**
(`D3D12_HEAP_FLAG_SHARED`, `DXGI_FORMAT_R8G8B8A8_UNORM`, `ALLOW_SIMULTANEOUS_ACCESS`), exports
an **NT handle** (`ID3D12Device::CreateSharedHandle`), and wraps the same resource back as a
`wgpu::Texture` (`create_texture_from_hal`). The finished, display-encoded frame is copied
GPU-to-GPU into it (a valid srgb-differing `copy_texture_to_texture`, no re-encode) and the
handle is handed across the bridge; the Windows runner registers it with Flutter as a
`kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle` external texture (the embedder opens the handle
on its own ANGLE/D3D11 device), and the Viewer shows a `Texture` widget. The pixels never
leave the graphics card. **Choice made — D3D12-direct, not a separate D3D11 device:** the
direct route is self-contained (no second device, no D3D11-on-12) and was verified to work end
to end on the dev machine (the `solid_comp_renders_to_a_stable_shared_handle` test creates the
shared resource, exports a non-zero handle, and re-uses it across frames). Under the feature
the headless renderer pins the **D3D12 backend** (the interop needs it); every non-feature
build keeps the all-backends instance. **Synchronisation:** after the copy we `poll(Wait)` so
Flutter never samples a half-written frame; a keyed-mutex / shared-fence handshake is the
recorded follow-up, worth adding only if tearing shows in practice (D3D12 uses fences, not
keyed mutexes, so a cross-API handshake is non-trivial — deferred until observed). **No new
runtime dependency:** the plumbing pattern (descriptor shape, the DXGI-shared-handle surface
type, the register / mark-frame-available dance) follows the MIT-licensed
`flutter_wgpu_texture` package as a *reference* — pattern borrowed with a code-comment credit,
not added as a dependency (it owns its own renderer/scene architecture and is very young). The
`windows` crate is pinned to **0.58** so its D3D12 types unify with the ones wgpu-hal already
uses. **Fallback is airtight and tested:** `lumit_bridge_shared_supported()` is false for an
old `.dll`, a non-Windows build, or a feature-less build; `render_to_shared` returns false (Dart
falls back for that frame) on no D3D12 adapter or any interop error; the platform channel
missing (an unwired runner) latches the controller off for the session — every seam falls back
to the read-back path, each covered by a fake in the Dart suite. **Scopes** still need CPU
pixels (the texture path moves none): a throttled read-back render (~10 Hz) feeds them while
the texture drives the Viewer. **Remaining after this:** the read-back path stays for scopes
and for every fallback; engine-side render cancellation and a rendered-frame cache (K-176)
are still open; the keyed-mutex handshake is the named follow-up.

**K-178 · DECIDED · The pixel pass moves into `lumit-render`, an engine crate both
frontends drive; the bridge's dependency on `lumit-ui` (K-175) is retired.** K-175 recorded,
as deliberate scaffolding, that `lumit-bridge` would depend on `lumit-ui` to reach the
compositor "until the pixel pass moves into an engine crate". This is that move. A new engine
crate `lumit-render` holds the whole pass: probing abstraction (`source`), decode planning
(`plan`), the decode worker and its decoded-frame cache (`decode`), draw-list building
(`build`) and its types (`draw`), the GPU compositor (`realise`), effect dispatch (`fxops`),
frame naming and the cache tiers (`cache`, `diskio`), export, and the headless seam. It
depends on no frontend and names neither egui nor Flutter; `lumit-ui` and `lumit-bridge` both
drive it. The docs/05 rule is not merely unbroken but strengthened — the bridge is no longer a
leaf hanging off a frontend, and the shipped Flutter `.dll` no longer links egui, `egui_tiles`,
`iconflow`, `rfd` or `muda`. Two pieces moved further down: `pixels` and `preset` are pure
data/maths with no media or GPU dependency and must survive a `--no-default-features` build, so
they live in `lumit-core`. **Why now, and what it bought:** the reason was performance, not
tidiness. The Flutter Viewer drove `export::Renderer`, which decodes every frame afresh at full
resolution and retains nothing, so *dragging a value re-decoded the whole composition on every
tick* — while the egui Viewer had long re-composited from the frame's retained per-layer pixels
and never re-decoded during a drag. Sharing one crate made it possible to give the Flutter path
that behaviour instead of building it a second time: `HeadlessRenderer::render_preview` plans
the decode, reuses the pixels it holds when the plan is unchanged (`plan::same_decode`), and
decodes at the preview resolution. `DecodePool::comp_decodes` counts real decodes so the drag
contract is a *test*, not a claim. The zero-copy shared-texture paths (K-177) were moved onto
the same walk, so the shipped build gets the fast path and cannot disagree with the read-back
path about a frame. **Frame naming:** the bridge's rendered-frame cache (K-176) keyed on
`(comp, frame, scale)` plus the identity of the document snapshot, so *any* commit — a rename,
a work-area nudge, a solo toggle — emptied it. It now keys on the content hash
(`lumit_eval::comp_frame_key`, already an engine crate), so picture-free edits discard nothing
and an edit to one layer retires only the frames that layer appears in. **Cost, recorded
honestly:** two comp walks still exist — `build_comp_draws` (interactive) and
`render_comp_linear` (export) — kept in step by hand and by tests, exactly as they were inside
`lumit-ui`. Unifying them by having export decode into a pixels map and share the draw walk is
the recorded next step (docs/TODO.md, Now), gated on a bit-identity matrix across precomps,
mattes, adjustments, collapse and motion blur; a solid-comp identity test is in place already.
This entry supersedes K-175's temporary arrangement; K-175 stays as the record of why the edge
existed.

**K-179 · DECIDED · flutter_rust_bridge is the only front/back seam; the hand-written
`extern "C"` bridge is deleted.** The interim transport ("bridge v0" in
[17-BRIDGE-CONTRACT.md](17-BRIDGE-CONTRACT.md)) passed whole documents as JSON text over 107
hand-written `extern "C"` functions. It was always described as a deliberate interim choice
with flutter_rust_bridge as the intended target once the command surface stabilised; this
entry records that arriving. Everything the frontend does now goes through
`crates/lumit-bridge/src/api/`, which hands Dart opaque reference handles
(`ProjectReference`, `CompositionReference`, `LayerReference`, `ItemReference`) with methods on
them, plus a scoped-change stream naming which reference an edit touched. **The reference types
are the identity**: there is no snapshot to diff, no mirror class to keep in step, and no id
lookup, which is what removes the whole-document JSON round trip per edit. Two shapes follow
from that and are binding: an op takes a **whole value** rather than a granular delta (a
keyframe drag that moves time *and* value is one write and therefore one undo step), and a
*staged* edit — a drag — renders through a patched clone engine-side and commits once on
release. The two bridges ran side by side while each panel moved across, then v0 was removed in
one sweep so the two never had to be kept in step; the migration's running order and the
capability gaps that remain are in [TODO.md](TODO.md). What survived the sweep is shared
infrastructure, not transport: the layer and asset defaults both frontends build from
(`edits.rs`), the scale-to-decode-size policy (`render::quality_for`), the rendered-frame cache,
the realtime controller, media probing/decoding, and the exporter — whose entry point now takes
the document as an argument rather than reading a process-wide bridge, which is what let one
exporter serve both frontends. This supersedes 17-BRIDGE-CONTRACT.md's "JSON over a C ABI"
transport section; the four binding rules in it (no panic crosses the boundary, no lock held
across the boundary, rational time crosses as integers, the engine never depends on the
frontend) are unchanged and still bind.

**K-180 · DECIDED · A composition's duration is a length of time, and the frame rate is only a
frame rate.** The Composition settings dialogue used to edit the duration as a *frame count* and
the rate as a visible numerator over a denominator, and `BridgeCompSettings` carried the count
across the bridge. That was a bug, not a presentation choice: a frame count means nothing
without the rate it was counted at, so pressing Save after changing 60 fps to 30 wrote
yesterday's 1800 frames back at the new rate and *doubled* the comp's real length, while every
layer kept the seconds it already occupied. On screen that looked exactly like the layers
speeding up or slowing down — reported by the owner, and the reason for this entry. **Binding
now:** the duration crosses the bridge as exact rational **seconds** (`BridgeCompSettings
.duration`), which is what the document has always stored, so changing the rate changes only how
finely the comp is counted — never how long it is, never where a layer sits, never how fast
anything plays. Frame counts are derived on demand from `CompositionReference::duration_frames`.
**The dialogue's shape follows from that:** the rate is one number in one field (`600`,
`23.976`) with the awkward rates on a Presets list, and the duration is `HH:MM:SS.mmm`. The
exact `num`/`den` pair still crosses the boundary — docs/14 §2's rational-time rule is
untouched, and 23.976 still reaches the engine as 24000/1001 — but the pair is worked out from
what was typed rather than typed by hand, because a denominator is an implementation detail of
NTSC and not a question to ask someone making a comp. **One dialogue, three doors:** the same
window is New composition (with a Create button) and Composition settings (with Save), reached
from the menu bar, the Project panel's footer button, and a right-click on a comp; creating is
one call and therefore one undo step, never "create then apply". **Footage dropped on the New
composition button** opens it prefilled from the media's own size, rate and length, and every
dropped item lands in the finished comp as a layer, which is what docs/07 §3.1 has always asked
for; that is also why the Project panel now multi-selects (`Ctrl` adds, `Shift` takes the run)
and why a drag carries the whole selection.

**K-181 · DECIDED · The frontend holds no logic — it displays values and forwards calls.**
K-017 says the UI thread never *evaluates*; 17-BRIDGE-CONTRACT says the engine owns the
document and the frontend never mutates it directly. Both were narrower than the rule actually
wanted, and the gap let a whole scheduler grow in Dart without breaking either: the Viewer's
playback loop mutated nothing and evaluated nothing, it merely *decided* — which frame to ask
for next, how many renders to keep in flight, whether the picture was stale, what frame the
audio clock implied. Reported by the owner as "we need to move the logic for handling playback
to the Rust side". **Binding now:** the frontend may own *interaction state* — where the
playhead is, the zoom, the selection, the pan — and must act on it immediately, without a round
trip; what it may not own is *policy*. It states facts to the engine ("the playhead is at 40",
"play from here", "the document changed") and paints what comes back. Anything that has to be
decided — scheduling, timing, invalidation, degradation, when work is worth doing — is the
engine's, because the engine is the half that holds the inputs to those decisions. **The test
of the rule:** if a Dart change would need a clock, a queue, a retry, a staleness flag, or a
count of work in flight, it is on the wrong side of the boundary. **First application:**
playback moved into `lumit-bridge`'s render worker, which now paces itself and publishes each
frame with its own frame number, so the frontend no longer has to track what it asked for. The
`Ticker`, the every-frame pump, the in-flight counter and the stale flag are all deleted.
The worker is not yet the full scheduler `docs/impl/playback-scheduler.md` §5 specifies — no
epoch tokens, no ring, no adaptive lookahead — and that gap is recorded in docs/TODO.md rather
than pretended away.

**K-182 · DECIDED · The egui frontend is deleted; git history is the parity reference.**
Supersedes the working stance (recorded in TODO.md after K-174) that the egui code stays in the
tree as the parity reference. Reported by the owner: after egui → Flutter → frb, the project
had "become bloated, over-engineered and far too complex", and a full over-engineering review
confirmed the bloat was almost entirely migration corpses, not the live code. **Deleted in one
sweep:** `crates/lumit-ui` (~30,600 lines) and `crates/lumit-app` — nothing else depended on
them; `crates/lumit-keymap` — zero dependents, existed only for an unbuilt settings page;
`packaging/flatpak` and its CI job — it shipped the egui binary; the never-wired pop-out
subsystem (`flutter_ui/lib/popout/`, the `desktop_multi_window` plugin and the dock's pop-out
chrome — `canPopOut` was hard-coded false, so all of it was unreachable); and the dead Dart the
port left behind (`scope_maths.dart`, `AutosaveScheme`, the settings structs nothing read, the
PowerShell RAM probe, the per-call bridge tracer). **Why deletion rather than keeping the
reference:** a parity reference you can `git show` is exactly as available as one you compile,
and the in-tree copy cost every CI run, every workspace build, and a standing invitation to
"fix it in the old frontend too". **The rule going forward:** when a feature is parked (as
pop-out is), it is *removed* and rebuilt from history when wanted — half-shipped code that
ships its dependencies but not its entry point is the worst of both. K-174's decision itself
is unchanged; this only deletes the superseded implementation.

**K-183 · DECIDED · Frames cross the bridge as GPU handles only, and reads cross grouped.**
Reported by the owner's collaborator: the Viewer should lose the ability to send pixel data
back to Flutter entirely ("forced to use shared texture everywhere"), and the panels should
stop paying a bridge call per field ("we don't have calls to things like .name() .id(),
grouping things into .get_info() that can be called once per widget rebuild"). **Transport:**
the CPU read-back frame path is deleted — `WorkerResponse::RenderedPixels`, the `zero_copy`
opt-out flag, the Dart `viewerImage` fallback machinery and the `useSharedTexture` setting are
gone, and `shared-texture` + `shared-texture-linux` are default cargo features (each inert off
its platform), so every build and every test exercises the shipped path. A failed zero-copy
render drops the frame rather than falling back; a platform with neither path (macOS, K-033)
has no Viewer picture until it grows its own. Thumbnails and the 256×256 scope traces still
cross as pixels, deliberately — bounded and rare. The rendered-frame cache is now filled only
by the scope path. **Grouped reads:** `LayerReference::get_info` returns name, kind, switches,
blend, the span already mapped to comp frames, clip split frames, and the parent id *and
name* in one crossing; `BridgeEffectInstance::get_info` returns id, name, enabled and every
parameter value. Panels read one info per widget rebuild, the parent picker builds its menu
lazily on click (it was O(layers) calls per row, O(layers²) per outline), and the transform
rows share one `get_transform`. Selecting a layer measured ~75 → 31 calls; the budget test
caps it at 64. The per-field getters remain for one-shot call sites — grouping is for what
rebuilds, not a ban.

**K-184 · DECIDED · The panels draw from a Rust-built read model; a rebuild costs one call.**
Follows K-183's grouping to its end, prompted by the owner: "why does selecting a layer take
31 calls?? Surely one or two is all it needs?" The answer was that selection changed nothing
in the document — the 31 were two panels repainting and re-asking for what they already knew.
**Binding now:** `CompositionReference::get_model` returns the whole fronted comp as the
panels draw it — every layer's handle plus name, kind, switches, blend, span as frames, clip
frames, parent and its name, the full transform, and every effect's every value — in ONE
crossing. Dart holds it in `CompModel` (state/comp_model.dart), and the panels (Timeline,
Hierarchy, Effect controls, the parent picker, the comp tabs) draw from it with no bridge
calls in build. **Freshness is a revision number, not faith:** `DocumentStore` counts every
published snapshot (commit, undo, redo, recovery — regression-tested in lumit-core), and the
model compares that one number per read, re-reading the world only when it moved. So any
rebuild for any reason shows the current document — the exact contract the old
read-everything-in-build code had — for one call instead of dozens, and the model needs no
trust in the async change stream to be correct (the stream just triggers repaints; panels
also nudge `refresh()` after their own ops so an edit is on screen without a round trip).
The model is plain data, never handles: edits still go through the references, and effect
ops fetch a fresh instance handle at click time (frb consumes handles passed by value).
`LayerBuilder` is deleted — per-row change scoping existed because rebuilds were expensive,
and rebuilds that cost one revision check need no scoping. Measured: selecting a layer is
now 11 calls (was ~75 pre-K-183, 31 after it); the budget test caps it at 24.

**K-185 · DECIDED · There is one comp walk; export drives the preview path.**
K-031 ("preview == export") was held together by hand: `build_comp_draws` + `Realiser` drew the
Viewer while `render_comp_linear` — a parallel ~1,400-line implementation of the same rules —
drew the file, kept identical by discipline and comments. The TODO's gate ran first: a
bit-identity matrix (blends/opacity, nested and collapsed precomps, all three matte source
modes, adjustment stacks, per-layer motion blur, posterize time, camera over 3D, plain footage,
Retime blend and Retime flow) proved the two walks byte-identical on every row **before**
anything moved. Then the export encode loop and `render_rgba` switched onto the preview path —
`HeadlessRenderer::render_preview` at full decode quality, the exporter on its own renderer and
device so it never contends with the Viewer — and `render_comp_linear`, its `Renderer` and every
private helper were deleted (export.rs: 2131 → 683 lines). K-031 is now true by construction:
there is no second walk to disagree. The matrix stays as the determinism gate for the one walk.

**K-186 · DECIDED · The composite runs at the preview scale; geometry stays logical.**
The realtime tier and Auto resolution used to shrink only the decode: the composite itself
always ran on a full comp-sized target (measured 59.7 ms/frame for a one-solid 1080p comp
shown at 0.42), so a coarser tier barely made frames cheaper. **Binding now:** the one walk
carries a render scale (`Realiser::render_scale`, a field so the nested/below/adjustment
recursions inherit it with no signature ripple). The split is logical-steers,
target-allocates: every placement matrix and the camera keep the LOGICAL comp dims —
geometry is in comp pixels — while `composite_seeded` / `motion_blur_average` allocate their
targets, dst snapshots and fp32 accumulators at the ACTUAL `lumit_gpu::scaled_size` dims and
feed those to the fragment's `target_size` uniform (which normalises the frag position to
comp UV for matte and snapshot sampling); NDC lands the same geometry on the smaller raster.
`scaled_size` is the ONE rounding both the target and the preview's final blit use. The
matte render-alone pass deliberately stays full-res (sampled by normalised comp UV, so any
size is correct); the adjustment stack, coverage and `adjust_blend` run at the actual raster
(texel-matched reads). The shared-texture registration sizes off the texture's actual dims,
so a tier change re-registers a genuinely smaller texture. Export builds the walk with scale
1.0 always, and the K-031 matrix pins that path bit-unchanged — the preview scale can never
leak into the file. Regression tests: `a_render_scale_shrinks_the_target_but_not_the_geometry`
(lumit-gpu) and `auto_resolution_composites_at_the_scaled_size` (lumit-render).

**K-187 · DECIDED · The VRAM final-frame cache and the idle fill: revisited frames are free.**
Docs/06 §5's top tier, built for the zero-copy transport that made the RAM frame cache
irrelevant to the Viewer (K-183): the renderer keeps finished display textures on the card,
keyed `(comp, frame, preview scale in thousandths, channel order)` under a byte-budgeted LRU
(default 512 MiB, Settings → Performance sets it). Playback, scrubbing and the ring all pass
through it — a warm span composites nothing. **Position keys carry two duties:** every
committed edit drops the whole tier (the same generation signal that drops the RAM bytes,
watched by the worker each loop turn), and a live drag's provisional renders pass
`cacheable: false` — they must neither be served stale nor bank half-committed pixels.
**Idle fill (§5.5, forward-biased):** after a 200 ms request lull the worker renders
uncached frames outward from the last-shown frame — two ahead for every one behind, bounded
by the work area and by the budget (it stops before the LRU would churn) — one frame per
wake so any request pre-empts it within one render. **The cache bar merges the tier**: the
worker publishes its holdings (packed exactly like `framecache`'s keys) and `cached_frames`
reports card-held frames as green — the bar means something on the zero-copy transport
again. The textures never leave the worker's thread; settings speak to it through three
atomics and a published mirror, so no lock ever spans GPU work. The disk tier (§5.4) and
content keying (K-178) remain open. Regression tests:
`a_cacheable_frame_is_served_from_vram_and_a_drag_never_is` (lumit-render),
`the_fill_order_is_forward_biased_and_complete` and `cached_tiers_merges_the_vram_mirror`
(lumit-bridge).

**K-188 · DECIDED · The Timeline header rework: four draggable column groups, open comp tabs, shy.**
Supersedes K-168's shipped five-cluster arrangement. The outline's columns sit in FOUR
groups, each draggable in the header to reorder as a unit — 1 visibility · audio · solo ·
lock · shy; 2 twirl · label chip · layer number · name; 3 flow-or-collapse · fx · motion
blur · 3D; 4 matte · blend · parent. The header icons are indicators only; the switches
live on the rows, and visibility/audio swap glyph when off (closed eye, muted speaker)
rather than only dimming. **Shy is a real engine switch** (`Switches::shy`, `SetLayerShy`):
it hides the layer from the Timeline's list while the toolbar's shy filter is on and never
changes what renders. **Comp tabs are open tabs now**, not the whole project: fronting a
comp opens its tab, the tab's × closes only the tab, and closing the fronted tab fronts
its nearest neighbour. **The toolbar lives inside the outline** (timecode `HH:MM:SS:FF`
plus a zero-based frame readout, the layer search, a master motion-blur button writing
`Composition::motion_blur.enabled` through the new `set_motion_blur_enabled`, the shy
filter, Lane/Graph view buttons, and a ⋯ menu holding the layer/work-area/marker
commands); the lane side gives that whole height to a taller labelled time ruler. The
fold-out's value cells span exactly the render group's width, so values line up under it
wherever the groups are dragged. The flow column is reserved: optical flow has no
per-layer engine backing yet (docs/TODO.md), so a Precomp shows collapse there and other
kinds leave the cell empty. Lock is enforced UI-side where the gestures live (bar
move/trim, razor, rename, reorder/delete); property-row edits on a locked layer are a
recorded gap. Master motion blur does NOT cascade into nested comps — each comp's own
master gates its own layers (lumit-eval reads `comp.motion_blur.enabled` per comp).
Regression tests: `timeline_panel_frb_test.dart` (group drag, switches, readouts, shy,
lock, master toggle), `timeline_extras_frb_test.dart` (tab open/close), and
`the_master_motion_blur_toggle_flips_only_the_enable` (lumit-bridge).

**K-189 · DECIDED · Timeline round two: label colours drive the bars, animated values stay editable, drags never scroll.**
Follows K-188 in the same rework. **Labels colour the lanes:** a layer's label chip and its
bar in the lane area are the same colour, from a dedicated bright eight-chip palette in the
theme (replacing TL2's role-colour chips, which were built to be quiet rather than tellable
apart), and each layer kind starts on its own chip (`base_layer` assigns it; the user's
pick simply overwrites). One palette for both themes. **Animated values stay editable
everywhere they show:** an outline value field on a keyframed property shows the value
under the playhead and an edit writes the key sitting there — or plants a linear one — via
`scalarWithValueAt`; a static write over a curve is no longer possible from a value field.
The keyframe controls read the *live* playhead (the ◆ diamond fills exactly while the
playhead sits on a key). **Keyframes show in lane view:** keyed rows draw their diamonds
on their lanes, and dragging empty lane space boxes them up with the shared `MarqueeSelect`
(the same widget the graph editor's lanes use). **Dragging never scrolls the timeline** —
the wheel and the scrollbars do: the outline and lanes share a linked vertical scroll (one
thumb on the lane side; two independent ones in graph view), and the lane bottom bar holds
− / + / Fit time zoom with a horizontal scrollbar. Lane painters decline hit-tests (a
`CustomPaint` background painter otherwise absorbs the marquee's drag). The graph editor's
command bar moved to the bottom and its lanes label their value axis. Regression tests:
`timeline_panel_frb_test.dart` (key-at-playhead edits, live diamond, lane marquee, zoom,
bar colour, tall-stack scroll), `effect_controls_frb_test.dart` (animated field edits the
key), `theme_test.dart` (distinct chips).

**K-190 · DECIDED · Timeline round three: row seams, key dragging, and the scroll gutters.**
Continues K-188/K-189. **Column metrics:** every gap *inside* a group is now the same
`cellGap` — the render switches pack left in ordinary switch cells (the rest of that
group's span is the fold-out's value column, not spare icon room) and matte · blend ·
parent sit a cell-gap apart. The compose group's header titles carry the dropdown's own
`dropdownTextInset`, so each title sits over the text in the cell below it. The group seam
is a hairline **in the header only** — the rows keep the same width as plain space,
because a rule down every row of a tall stack is noise. **Row seams** run the full width of
the lane area, drawn as ONE `IgnorePointer` overlay per lane column rather than as a border
per row: `RenderDecoratedBox.hitTestSelf` delegates to the decoration, so a `Container`
with a `decoration` **absorbs pointers** — a per-row border silently ate the keyframe
marquee under it (the same trap as a `CustomPaint` background painter, which needs
`hitTest => false`). Bars fill their whole row height and the seam draws over them.
**Lane keyframes drag in time**: each diamond is a handle, the gesture is held in Dart and
committed once (`moveLaneKey`), and a move onto a neighbour is refused rather than clamped.
The **magnet** (lane bottom bar, on by default) decides whether a dragged key lands on a
whole frame or between two; off, the time is quantised to a thousandth of a frame and built
from the comp's exact rate, so it stays rational (docs/14 §2). **Scroll gutters:** the
vertical thumb lives in a fixed-width gutter *outside* the horizontal scroller, pinned to
the viewport's right edge — it used to ride the scrolled content and drift off screen. The
outline reserves the same gutter, with a fixed undraggable block level with its toolbar and
column header (After Effects' reserved corner), so the columns do not shift when graph view
gives the outline its own thumb. **Wheel:** plain scrolls the rows (both halves, linked),
`Shift` scrolls sideways, `Ctrl` zooms time about the pointer — handled by a `Listener`
placed *inside* the scrollables so the pointer-signal resolver offers it the wheel first,
and left alone otherwise so a plain wheel still reaches the scrollable. Effect parameter
rows take the fold-out's zero row padding, matching the transform rows they sit beside;
the card keeps its own. Regression tests: `timeline_panel_frb_test.dart` (key drag with
magnet on and off, marquee, dividers via the passing marquee, zoom, bar colour).

**K-191 · DECIDED · A composition double-clicks open; an empty Timeline takes a drop.**
Two dead ends closed. **Double-clicking a comp row in the Project panel opens it in the
Timeline** rather than renaming it — what a double-click means in every editor. The panel's
click model is otherwise unchanged (a second click on the lone selected row still renames
footage, solids and folders in place, resolved on the raw pointer-up so there is no arena
delay); only compositions divert. Renaming a comp therefore moved to the row menu's new
**Rename** entry, which is offered for every item kind so nothing lost a rename path, and
its settings dialogue still carries the name field. **Dropping footage on a Timeline with
no composition open** raises the New composition dialogue seeded from the media — the same
gesture the Project panel's New composition button already took — and fronts the finished
comp; dropping a comp there simply opens it. The panel used to show a placeholder with no
drop target at all, so the drag lifted, showed its feedback and dropped into nothing.
Regression tests: `double-clicking a composition opens it in the Timeline`
(project_panel_frb_test.dart) and `footage dropped on an empty Timeline offers a new comp`
(timeline_panel_frb_test.dart).

**K-192 · DECIDED · Resizable column groups, property selection, and a keyframed drag as one undo step.**
**The undo bug first, because it was a real one:** [`DragValueField`] falls back to
`onChanged` on *every drag tick* when no `onChangeLive` is given, so a drag on a keyframed
value (K-189's editable animated cells) committed one op per pixel — the undo stack filled
with a step per tick and a single undo moved the value back by a hair instead of undoing the
gesture; a drag that planted a new key planted one per tick. `KeyedValueField`
(keyframe_controls_frb.dart) now stages the drag in Dart and commits exactly once on
release, and the transform rows, effect parameter rows and the Volume row all use it.
**Column groups resize:** each group carries its own width, the header seam between two
groups is a drag handle for the one on its left, and every other group keeps its width — so
the outline grows by exactly what the drag moved. The fold-out's value cells span the render
group *as it currently is*, and the compose group's three pickers share theirs
proportionally, so widening a group widens what sits in it. The identity group is a plain
width now rather than flexing. **Properties select:** every fold row has a hierarchical
path (`<layer>/effects/<fx>/<param>`, sharing its prefixes with the group paths), clicking a
property row selects it, and every row *containing* it — the effect's heading, the layer's
own row — marks itself a shade dimmer, which is what will tell the graph editor which curve
is meant. Boxing keyframes on a lane selects their property too. **Two Flutter traps, both
found the hard way and both now guarded:** `ScrollController.offset`/`.position` assert
when a rebuild momentarily leaves two views attached (a drop target lighting up was
enough) — read through `_positionOf`, which returns null unless exactly one is attached;
and `RawScrollbar` learns where its scrollable is from `ScrollNotification`s rising through
its *own* subtree, so one sat in a gutter beside the scroll view never repaints and its
thumb is simply invisible — replaced by `_GutterScrollbar`, which listens to the controller
and drags it directly. The outline's row seams are now one scroll-phased overlay across the
columns *and* the gutter, so they meet the lane area's. Regression tests: `a drag on a
keyframed value is one undo step`, `clicking a property selects it and marks its parents`,
`boxing keyframes on a lane selects their property`, `dragging a header seam resizes just
that group` (timeline_panel_frb_test.dart).

**K-193 · DECIDED · Layers reorder by drag, the Transform card is a choice, and Settings has pages.**
**Reordering:** a layer's name is its stack handle — drag it onto another row and it takes
that row's place, one op and one undo step. Layers were otherwise stuck in the order they
were added, movable only from the row menu one place at a time. A locked layer neither
drags nor accepts a drop. **The Transform card in Effect controls is off by default**
(Settings → Interface turns it on): the Timeline's fold-out already carries Transform, and
repeating it pushed the effect stack — what the panel is *for* — a screen down on a 3D
layer. It stays available because it is a habit After Effects users bring with them.
**Settings is paged** (General · Appearance · Interface · Performance), each page a stack
of named sections and each section a card of rows that read the same way: what it is, a
line saying what it does, its control on the right. That is the egui shell's arrangement,
restored; it replaces one scrolling column of five groups that had outgrown a window. The
rebuild also surfaces settings that existed but were never exposed — UI scale, tooltips,
the animation level, and the playback mode, all of which were being persisted while
unreachable. `Workspace.settingsChanged()` is the one call that makes an in-place edit to
`interface`/`performance` stick, since those are plain structs rather than a setter per
field. **Pages with nothing behind them are not listed:** Export defaults, the keymap
editor and colour management are unbuilt (docs/TODO.md), and an empty page is a promise
the window cannot keep. Regression tests: `dragging a layer by its name reorders the
stack` (timeline_panel_frb_test.dart) and `the pages divide the settings, and a choice
persists` (shell_frb_test.dart).

**K-194 · DECIDED · A test may not touch the real settings; budgets are typed; menus have submenus.**
**The settings-reset bug first.** `Workspace.save()` wrote to
`%APPDATA%\lumit\flutter-workspace.json` unconditionally, and every test that builds a
`Workspace` and touches a setter calls it — so a `flutter test` run wrote *defaults* over
the developer's own settings, every run. `Workspace.storeOverride` redirects the store, and
the frb test harness points it at a temp file. Machine state is not something a test run may
reach. **Cache budgets are typed numbers** (drag or type, in MB) rather than a pick from a
fixed list, capped at what the machine actually has: `system_memory_bytes()` via
`GlobalMemoryStatusEx` and `video_memory_bytes()` via the first DXGI adapter's dedicated
memory (`crates/lumit-bridge/src/api/system.rs`; both answer 0 off Windows and the frontend
falls back to a documented 16 GB ceiling rather than pretending). The old dropdown could not
express "3 GB on a 32 GB machine" and its options were a guess at what hardware would turn
up. The **Frame transport** row is deleted — it named an implementation detail the user
cannot act on. **Menus nest** (`SubmenuRow`, widgets/controls.dart): Window → Workspaces
holds the four presets and Reset, and Add effect → *category* → effect replaces one 380 px
scrolling list. The submenu opens *over* its parent rather than replacing it: closing the
parent first would take the row's `BuildContext` with it, and the overlay the submenu needs
is reached through that context. The Add-effect menu now drops from the **button** (a
`Builder` gives it its own context) instead of the panel's left edge. **Source and Retime
join Transform** behind the Settings → Interface toggle: all three describe the *layer*, and
this panel is about the effects on it. **Matte and layer-valued effect parameters offer only
layers with a picture** — `LayerReference::has_picture()`, the mirror of `has_audio`, false
for a camera and for an audio-only clip — and never the layer they sit on. Both pickers are
lazy, so the probe happens when a menu opens and never while drawing a row (K-184).
Regression tests: the settings/menu/effect tests in `shell_frb_test.dart`,
`menu_bar_frb_test.dart` and `effect_controls_frb_test.dart`.

**K-195 · DECIDED · macOS gets a Viewer picture: Metal/IOSurface is the third zero-copy
transport.** K-183 deleted the CPU read-back path and left macOS with no way to show a
frame at all — every render was composited and then dropped with "No zero-copy transport in
this build", so the Viewer was blank for a whole session while every other panel worked.
The macOS primitive for two parts of a program pointing at one piece of graphics memory is
the **IOSurface**: `lumit-gpu`'s `shared_metal` creates one (`IOSurfaceCreate`), asks Metal
for a texture backed by it (`newTextureWithDescriptor:iosurface:plane:`), and wraps that
`MTLTexture` back up as a `wgpu::Texture` the ordinary render path copies the finished frame
into. The runner (`macos/Runner/ViewerTextureBridge.swift`) looks the surface up by id,
wraps it in a `CVPixelBuffer` — a wrapper, not a copy — and registers it as a Flutter
external texture on the same `lumit/viewer_texture` channel with the same
`register`/`frameReady`/`unregister` methods the Windows and Linux runners implement.
**The payload is the Windows one, deliberately:** macOS reports `RenderedSharedTexture`,
because both platforms hand across one opaque integer naming a surface plus its size (an NT
handle there, an `IOSurfaceID` here) and neither side does anything with it but pass it on.
So there is no third bridge variant, no codegen change and no Dart change — only Linux, which
needs stride, offset and a DRM format, has its own. The surface is `'BGRA'`
(`kCVPixelFormatType_32BGRA`, the one format Flutter's macOS texture path accepts), so the
renderer is asked for BGRA display bytes there exactly as it is on Windows. Feature
`shared-texture-macos`, default-on and inert off macOS, matching its two siblings.
Regression test: `the_surface_yields_the_pixels_in_bgra_order` in `shared_metal.rs` writes
through the wgpu texture and reads back off the locked IOSurface, which is the channel-order
mistake that would otherwise cost a silent blank session (the Windows sibling's test exists
for the same reason). Extends K-177; supersedes K-183's "macOS has no Viewer picture until
it grows its own" — it has grown one. The rest of K-033's Mac release list (VideoToolbox,
ProRes, notarisation, the native menu bar) is untouched and still outstanding.

**K-196 · DECIDED · The graph editor is the AE graph, and the keyframe clipboard speaks
AE's format.** From Mack (2026-07-28), replacing the per-channel mini-lanes the frb port
shipped with the behaviour docs/07 §5 always specified. The graph is **one full-height
pane** sharing the Timeline's ruler, zoom and horizontal scroll; the curves it draws are
evaluated by a Dart port of the engine's own cubic (`flutter_ui/lib/panels/graph_maths.dart`,
pinned to `crates/lumit-core/src/anim.rs` by docs/impl/keyframe-eval.md §1–2 and held
together by golden tests), because a paint may not cross the bridge (K-184). Decisions
folded in: **(a)** property selection rides on the property's *name* in the outline —
`Ctrl` toggles, `Shift` ranges, across layers — and editing a value or keying a property
selects it too; a click elsewhere on the row selects nothing. Every selected property is a
coloured curve (the theme's `curve` palette, per axis — Position is AE's red/green pair)
and the outline label takes its curve's colour. **(b)** Wheel bindings match the lane view:
`Ctrl`+wheel zooms time about the pointer, `Shift`+wheel scrolls sideways; the value axis
auto-fits until the Auto fit toggle is off, and then a plain wheel pans it and `Alt`+wheel
zooms it. **(c)** Tangent handles are per side and joined by default: a drag swings the partner
**live and in screen space**, keeping the pixel length it had when the gesture began, and
`Alt` held at drag start flips broken/joined. Screen space, not value space, because the
two axes carry different units at independent zooms — mirroring in value space bends the
line the pair is supposed to draw and appears to stretch the partner as the tangent swings
toward vertical, which is the exact complaint that killed this in the egui frontend. For
the same reason the handles' hit targets never grow past their own reach: a handle sits a
few pixels from its key on a long composition, and a fixed target made which one you
grabbed a coin toss. The pixel length holds at *every* angle, with two supports rather
than a compromise: a tangent may never stand exactly upright (its reach is floored at a
thousandth of its span — sub-pixel at any sane zoom), because a vertical tangent covers no
time and so has no speed that describes it, which is the one state the geometry cannot
come back from; and each handle's drawn length is **remembered** per keyframe and side,
against the scales it was measured under, so swinging a pair out to near-vertical and back
returns both handles exactly as long as they went in. Reach in time is therefore allowed
to become very small at the extreme — that is what a near-upright tangent *is* — without
the length on screen following it down. One consequence is worth stating rather than
patching around: a joined partner moves when the pair **rotates**, so dragging a handle
straight out from an already-steep tangent lengthens it without turning it and the other
side barely stirs. That is the see-saw behaving, not sticking.
**(d)** The speed lens draws the exact derivative (K-080): each key is an independent
in-speed and out-speed dot, dragged vertically for that side's speed and **sideways to move
the keyframe in time**, with one influence handle each; editing either lens writes the same
speed/influence store losslessly (K-025). **(e)** The keyframe clipboard: in-app it keeps
full fidelity; the system clipboard simultaneously receives a tab-separated table headed
**`Lumit <version> Keyframe Data`** (the rate, the source size, then a property group per
copied property with a column per value) — extended with **two easing columns per value**,
`linear` / `hold` / `bezier(speed,influence)`, so shaping survives the round trip instead
of flattening. The easing columns come last, after every value, so a reader that does not
know them stops at the values it does; a foreign keyframe table with no easing columns
parses back as linear keys. Copy and paste are bound to the keyframe *selection*, not to
the graph, so they work from the lane view too. **(f)** The F9 family
(F9 / `Shift+F9` / `Ctrl+Shift+F9`) and the footer's Linear / Bezier / Hold act on the key
selection in *either* view — the lane marquee's catch included. Retime stays an ordinary
property here (per the standing TODO): no Retime channel, no §5.2 lenses yet; the
acceleration lens (K-070), numeric entry, transform-box scaling, beat-marker snapping and
waveform ghosting remain open in docs/07 §5.

**K-197 · DECIDED · Retime starts again as an ordinary keyframable property.** The segment
model (docs/04-RETIMING.md: Rate/Map segments, eases, boundaries with exact rational source
positions) is a fine *destination* and a poor starting point — it has cost more than it has
paid, and none of its editing affordances ever reached the frontend (docs/TODO.md lists a
dozen). So Retime restarts as the simplest thing that is honestly a retime: a
`lumit_core::anim::Property` on the **layer** (`Layer::retime`, `Option<Property>`) whose
value is the source time, in seconds, the layer shows at its own local time — the After
Effects Time Remap shape. It is a graph-editor channel like any other, which supersedes
K-196's "no Retime channel" — that clause meant no *segment* channel and no lenses, and
neither is what this is. Being an ordinary `Property` is the whole point: the stopwatch,
the ◄ ◆ ► navigator, the lane diamonds, the graph editor's lane, its handles and its interp
menu all work on it already, with no Retime-specific code anywhere. **No extras at all** —
no speed lens, no ease presets, no ramp editing, no freeze, no overrun band, no
interpolation policy on this path. Those return, if they return, on top of a property that
already works. `Option` rather than an always-present property because "not retimed" and
"retimed to exactly 1×" are different states in the file, and only the first skips the map:
a layer with no Retime shows **no row**, and Alt+Shift+T installs the identity map (two
linear keys, source running alongside local time) so switching it on changes nothing
visible. The row sits **above** Transform, outside every group, because it decides which
frame of the source the rest of the fold-out then transforms. `Layer::source_time_at` is the
single place the mapping is decided, so the render plan (`plan.rs`) and the frame-cache key
(`lumit-eval`) can never disagree about which source frame a layer shows; it prefers the
property and falls back to the old `LayerKind::Footage::retime` store for documents that
carry one. Supersedes K-194's "build the fold-out group and move the Source card's retime
rows into it" — the rows being moved would have been the segment card's, and this is a
different property with a different model; the Source card's speed/reverse/interpolation
rows stay where they are until the new path replaces them outright. Regression tests:
`retime_property_round_trips_and_maps_source_time` (lumit-core),
`the_retime_property_toggles_and_reads_back` (lumit-bridge), `Retime shows above Transform
only once the layer has one` (timeline_panel_frb_test.dart) and `Alt+Shift+T toggles the
selected layer's Retime` (shortcuts_frb_test.dart). The shortcut is **Alt+Shift+T**, the
owner's choice, replacing docs/07 §15's never-built `Ctrl+Alt+T`; that table is updated in
the same commit.

**K-198 · DECIDED · Retime keeps its chord and gains one the operating system cannot
take.** From Mack (2026-07-28), extending K-197 rather than reversing it. K-197's
**Alt+Shift+T** is unchanged and stays the shortcut the specs name. It also, on Windows,
collides with the system's **input-language switch**: left Alt with Shift is how Windows
cycles keyboard layouts, so on any machine with a second layout installed the OS consumes
the chord and the application never receives the T — the command appears simply not to
work, which is how this was found. Two additions, no removals: **Ctrl+Alt+T** does the same
thing (After Effects' own Time Remap chord, and the one K-197 had replaced — nothing
intercepts it), and **Composition ▸ Enable Retime / Disable Retime** carries the command in
the menus, naming what it will do to the selected layer and greyed out when there is none.
Both routes go through one `LumitState.toggleRetime`, so they cannot drift apart, and it
swallows a failed call rather than letting a menu click take the interface down. Covered by
`Ctrl+Alt+T toggles Retime as well` beside K-197's own shortcut test. The general lesson
outlives this shortcut: a chord the OS claims is not a chord the application has, so a
command whose only route is the keyboard has no route at all — every keyboard command
wants a menu or palette entry beside it.

**K-199 · DECIDED · The keymap is the engine's, the keyboard is the frontend's, and the
reveal cycle is three commands on one key.** From Mack (2026-07-29), restoring what K-182
removed and finishing what docs/07 §15 has promised since it was written. `lumit-keymap`
came back from git history unchanged — chords, contexts, conflict detection, the shipped
default and the After Effects preset, with its eight tests — because it was deleted as
unused rather than as wrong, and rewriting it would have been retyping.

**The split, and why it falls here.** Everything that has to be *decided* about a keyboard
lives in Rust: what a chord means, whether the focused panel outranks the app-wide binding,
whether two bindings clash, what the shareable file says. The frontend turns a real
`KeyEvent` into chord text (`Mod+Alt+Shift+Key`, with `Mod` resolving to Cmd on macOS and
Ctrl elsewhere), draws the table, and forwards the edits — it holds no opinion about any of
it, per K-181. The one thing it *does* decide is what counts as a gesture: the 500 ms
multi-tap window for `U` is a gesture like a double-click, and gestures are the platform's.

**Where the keymap is kept.** In the engine for the session, behind its own lock. The file
is the frontend's: `keymap_to_json`/`keymap_from_json` hand the whole map across as text and
the workspace file stores that blob verbatim, never looking inside it. One format serves
both the restore-on-launch path and the "Export keymap…" a user mails to a friend, so a
keymap that survives a restart is the same keymap that travels.

**A row shows every chord, not the first one.** An action can hold two — K-198 gives Retime
both `Alt+Shift+T` and `Ctrl+Alt+T` deliberately, and neither is removable — so
`BridgeKeyBinding` carries a list. A table that showed one of them would be lying about the
keyboard, which is the exact failure the page exists to prevent. Rebinding a row replaces
all of its chords with the one pressed; resetting restores all of them.

**Taking a chord someone else holds is never refused**, because refusing makes swapping two
actions' keys impossible — the swap needs a moment where one chord is claimed twice. Inside
one context the previous owner simply loses it and its row goes blank, which is visible;
across overlapping contexts both survive and the clash is reported for the user to resolve.

**Retime's chords moved from the Timeline context to Global**, with no change to the chords
themselves. The shell runs that command wherever focus is and the Composition menu carries
it too, so scoping it to one panel described something that was not true.

**`U` / `UU` / `UUU`** (docs/07 §4.3, and the third tap is After Effects' own behaviour
rather than a Lumit invention): animated properties, then everything modified, then shut.
Which groups qualify is answered by `LayerReference::reveal_groups` rather than worked out
in the panel — "does this hold a keyframe" and "is this changed from a fresh layer" are
facts about the document, and the second needs the layer-seeding rule that decides what
unchanged *means* for Position. The panel is told which groups to open and decides nothing
about why.

**What this does not do.** The Tools, Project, Panels and Effects contexts have bindings in
the table and no dispatch behind them yet — those commands do not exist on this frontend, so
the rows are honest about the keymap and silent in use. `docs/TODO.md` carries that.

**K-200 · DECIDED · Retime has one chord, like everything else.** From Mack (2026-07-29),
superseding the two-chord half of K-198. The owner's recollection behind K-197's
**Alt+Shift+T** was simply wrong — the After Effects chord being reached for was
**Ctrl+Alt+T** all along — so the collision K-198 worked around (Windows takes Alt+Shift
for its input-language switch) was a collision with a chord nobody should have shipped.
The remedy is now the removal: **Ctrl+Alt+T** (`Mod+Alt+T`) is Retime's one binding,
Alt+Shift+T is unbound, and no shipped action carries two chords. Retime is not special,
and with K-199's Settings → Keymap in, anyone who wants a second chord can bind one — a
per-user preference no longer needs to ship as a default. What K-198 *keeps*: the menu
route (Composition ▸ Enable/Disable Retime) and its general lesson, that every keyboard
command wants a menu or palette entry beside it. The bridge simplifies with the decision:
a keymap row carries one chord, not a list whose only customer was this pair.

**K-201 · DECIDED · The export dialogue grows the fields an export actually has, and image
sequences join the formats.** From Mack (2026-07-29). File ▸ Export… (the glossary bans
"render" for user-facing output, so the name was never a choice) now carries: a **format**
box — H.264/HEVC into `.mp4`, or a **PNG/TIFF image sequence**, one lossless RGBA still per
frame written through the same ffmpeg seam and the same frame walk as video, named
`shot.00001.png` beside the chosen path; a **frame rate** defaulting to the comp's own,
where a different rate resamples by nearest comp frame over the same wall-clock span and is
stamped exactly (`fps_rational` — 29.97 stays 2997/100, fixing the old path that rounded
every comp rate to a whole number); a **range** in comp frames defaulting to the work area
(K-037's rule stands as the default; the dialogue's explicit range wins over it, and always
sends what it shows so setting the range to the whole comp over a work area means the whole
comp); and the **AAC bitrate** when audio joins. Sequences carry no audio and no bitrate —
resolution strips both so the exporter never sees a contradiction — and a cancelled or
failed sequence deletes the frames it wrote. The dialogue's preset and codec lists now offer
only what the engine ships (the old list named `prores` and two presets that stamped
nothing). The preview-equals-export identity (K-031) is untouched: the range and rate choose
*which* comp frames render and how the file is stamped, never how a frame renders.

**K-202 · DECIDED · Themes are yours to make, and the Timeline gets a second ground.**
From Mack (2026-07-29). Four Appearance changes, one of which is a spec correction.

**Custom themes.** Settings → Appearance → **Customise…** opens every colour the theme
carries, one row each — name and a line saying what it does on the left, a swatch that
opens the picker on the right — seeded from the theme currently in use, previewing live as
you change it, because a colour you cannot see against the rest of the interface is a
colour you cannot judge. **Save** names it the first time and updates it in place after;
closing with unsaved edits asks rather than assuming, and discarding puts back exactly what
was there. A custom theme is stored as **a name, a light-or-dark base, and a bag of
colours** — not a copy of the struct — so a theme saved today still opens when Lumit grows
a token tomorrow, taking the new one from its base. Colours are written to the workspace
file as readable `#rrggbb`, so a theme can be hand-edited or pasted between machines.

The colours are declared once in `theme_tokens.dart`, each with the reader and writer that
reach its field; the editor and the stored theme both walk that list, and a test counts the
struct's colours against it so a token added and not listed fails rather than going
missing. **One colour is deliberately not offered**: the Viewer's surround, which is
strictly neutral by spec (15-DESIGN §2.1/§11) because a grade cannot be judged against a
tinted surround.

**The picker is grouped** — Dark, Light, then Custom. Seven built-ins plus a growing list of
user themes is a long flat menu, and light-or-dark is the first thing anyone chooses by.

**Scopes stop taking the theme's colours by default**, which is what 15-DESIGN §8 and §551
have said all along: a waveform is a measuring instrument, read on a near-black graticule
with a bright trace whatever the chrome, the same reasoning that keeps the Viewer surround
neutral. `ScopeColours.standard` was already in the Dart theme, correct and unused — the
panel simply never asked for it. Themed scopes remain available as an Appearance toggle,
off by default: off-spec, opt-in, and squarely a matter of taste.

**The Timeline gets two grounds, and selection its own colour.** The lane, layer and graph
areas were one long strip at a single value, which left a selected row almost nothing to
stand out against and left the span being delivered invisible below the ruler. Now the work
area keeps `surface1` and everything outside it is washed a step darker
(`timeline_out_of_range`), with a bigger step on light schemes because the same difference
reads as less on a bright ground. Selection moves off `surface2` onto its own
`selection_fill`, which lifts on a dark scheme and *drops* on a light one — a rule the
surface ramp cannot express, because it is a ramp. Both default from the mode rather than
being restated by seven schemes, and both are editable like any other token. The work
area's edges are **draggable on the ruler** for the first time on this frontend: it was
settable only from the menu, and a span you can see is one you expect to take hold of.

**K-203 · DECIDED · Selection you can get out of, a work area that exists, and a surround
that is grey.** From Mack (2026-07-29). Six defects reported against the K-199…K-202 work,
fixed together because four of them are one theme: the interface holding state the user
could no longer see or reach.

**Selection lets go.** A selected property survived its layer being twirled shut — invisible
but still the selection, so it came back lit when the layer reopened and went on colouring
that layer's row while the user worked on a different layer entirely. Closing a fold now
drops the selection inside it; clicking a layer clears the property selection, because "this
layer" means this layer and not also whatever was picked on the last one. And there is a way
out: **a click on empty ground in either half of the table deselects everything** — no
layer, no properties, no keyframes. Until now the only way to change the selection was to
pick something else, which left every command that reads it (Delete, the Retime chord, `U`)
stuck with whatever was picked last.

**`U` with nothing selected is the whole composition's.** "Show me what is animated" is a
question about the comp at least as often as about one layer; refusing to answer it unless
something was selected made the commonest use of the key the one it did not serve. The
`U`/`UU`/`UUU` cycle is unchanged — it simply runs over every layer instead of one.

**The work area is the whole comp until it is narrowed.** The engine stores "not narrowed"
as null, which is right. The *interface* has no such state: a comp that has not been
narrowed has a work area of the whole thing, which is what every editor shows and what
leaves the ends there to grab. Without it the K-202 drag handles had nothing to hang on,
the wash had nothing to shade, and `B`/`N` — bound since K-199 and dispatched by nobody —
did nothing at all, so the whole feature read as unimplemented. The two-shade ground now
runs the full height of the lane view **and the graph view**, and the ruler's ends are
draggable from the first frame. Clearing the work area no longer removes it; it widens it
back to the comp.

The read is in **frames, once per panel build**, handed down to the ruler, the lanes and the
curves rather than asked again in each — the first cut of this cost eighteen extra bridge
calls per twirl and broke the call-budget gate (docs/13).

**Ctrl+S saves.** `file.save` was in the keymap from the day the keymap came back and had no
case in the shell's dispatch, so the chord resolved to an action nobody ran and the status
line went on saying "Unsaved changes". The menu's save is now a free function both call, so
there is one path to disk rather than two to keep honest.

**The Viewer's surround is neutral again.** It was painting `surface0` — the theme's own
panel surface — where the theme has carried a neutral `viewer_surround` all along, for the
reason 15-DESIGN §2.1/§11 gives: a grade cannot be judged against a tinted surround. Neutral
is the default; taking the theme is an Appearance toggle, off by default, the same shape of
answer K-202 gave the scopes. This does not reopen K-202's decision to keep the surround out
of the theme editor: it is still not a token, it is a switch between the theme's neutral and
the theme's surface.

**The Scopes toolbar drops its frame readout.** The playhead's position is the Timeline's
and the Viewer's to state; a third copy above the trace only competed with it.

**K-204 · DECIDED · Installed memory is answerable on all three targets, and no tracked
file carries one platform's absolute path.** From two outside contributors (2026-07-29),
whose pull request is where both halves of this came from.

**The build fix first, because it was the real breakage.** `.cargo/config.toml` carried an
`[env]` block setting `FFMPEG_PKG_CONFIG_PATH` to the macOS Homebrew keg
(`/opt/homebrew/opt/ffmpeg@7/lib/pkgconfig`), because ffmpeg@7 is keg-only and pkg-config
cannot otherwise find it. Cargo's `[env]` has no per-target form, so every platform got it.
On Linux that directory does not exist, and rusty_ffmpeg's build script does not shrug and
fall back — it panics outright ("FFMPEG_PKG_CONFIG_PATH is set to `…`, which does not
exist"), so a fresh clone could not build at all until the line was deleted or overridden.
Two contributors independently deleted it. The `[env]` block is therefore **gone**, and each
platform is pointed at FFmpeg from outside the repo: macOS exports
`FFMPEG_PKG_CONFIG_PATH="$(brew --prefix ffmpeg@7)/lib/pkgconfig"` (per CI job, per
developer shell), Linux exports nothing because the distro's FFmpeg 7 development packages
already sit on pkg-config's default search path, and Windows keeps `FFMPEG_LIBS_DIR` /
`FFMPEG_INCLUDE_DIR` (rusty_ffmpeg's pkg-config branch is `cfg(not(windows))`, so it never
read the variable there). Moving the discovery into a build script of our own was
considered and rejected: the discovery lives in rusty_ffmpeg's build script, which is a
dependency of ours and therefore runs *before* anything we could write, and
`cargo::rustc-env` reaches our own compilation rather than a dependency's build script.
There is no seam without forking, so the fix is the honest one — the platform with the
unusual requirement states it, instead of every other platform undoing it.

**CI was masking the defect, which is the part that must not recur.** Both Linux jobs
exported `FFMPEG_PKG_CONFIG_PATH` themselves before building, and Cargo's `[env]` without
`force = true` does not override an already-set variable — so CI took rusty_ffmpeg's
explicit-override branch and stayed green while every real Linux clone failed. Contributors
were doing CI's job. The Linux jobs now export **`PKG_CONFIG_PATH`** instead, which is what
a distro install produces implicitly, so the branch a contributor actually takes is the
branch that gets tested, and re-adding the `[env]` line would now turn the Linux jobs red.
The pinned FFmpeg 7.1 tarball stays: the runner's own distribution still ships FFmpeg 6.
The standing lesson is the general one — a CI job that pre-sets what a contributor would
not have set is not testing the contributor's build.

**`system_memory_bytes()` now answers on Linux and macOS too**, extending the Windows-only
implementation K-194 recorded (that entry's "both answer 0 off Windows" is superseded for
this function only; `video_memory_bytes()` stays Windows-only and still answers 0
elsewhere). K-082 already makes Linux and macOS supported build targets, so this fills in a
target that was supported rather than adding one. `MemTotal:` from `/proc/meminfo` on
Linux, the `hw.memsize` sysctl on macOS, both falling through to 0 if the file, the field,
or the call does not yield a number. One honesty note recorded rather than corrected:
Linux's `MemTotal` is *usable* RAM, excluding what firmware and an integrated GPU reserved
before the kernel booted — about 15.5 GB on a 16 GB machine. It errs low, and low is the
safe direction for a cache-budget ceiling, which is the same reasoning K-194 already
applied to reporting the first adapter's video memory. Regression test:
`system_memory_bytes_reports_non_zero_on_supported_platforms` in
`crates/lumit-bridge/src/api/tests.rs`.

**K-205 · DECIDED · The renderer's backend is pinned on every platform, in every build.**
From Mack (2026-07-29), out of the Linux hybrid-GPU report. K-177 pinned the D3D12 backend
only under the opt-in `shared-texture` feature and said in as many words that "every
non-feature build keeps the all-backends instance"; the Linux and macOS siblings copied that
shape. This supersedes K-177 on that point. `GpuContext::headless` now selects **DX12 on
Windows, Vulkan on Linux and Metal on macOS unconditionally**, whatever the shared-texture
features are set to.

The reason is that the alternative no longer has a user. Zero-copy requires a pinned backend
— the hand-off reaches through wgpu to *that* backend's device — and K-183 deleted the CPU
read-back transport, so no build is left that shows frames without it. A mixed-backend
instance therefore buys nothing, and it costs something real: letting wgpu enumerate GL
alongside Vulkan on a hybrid iGPU+dGPU machine makes `PowerPreference::HighPerformance`
choose unreliably, and the reported case picked the integrated part driving the display and
then exhausted its memory during submission. Pinning is also simply honest about the
requirement, rather than leaving it implied by a feature flag that gates something else.

The pin is **not overridable from the environment**. The instance descriptor is built from
`from_env_or_default`, so `WGPU_*` still tunes the flags, the DX12 shader compiler and the
GLES version, but `backends` is set explicitly afterwards and wins: an environment variable
must not be able to put the Viewer on a backend the texture hand-off cannot use.

The three `shared-texture*` features keep their old scope — they gate the interop code, and
nothing else.

---

**K-206 · DECIDED · The Null layer ships, and the bridge enum spells it `NullLayer`.**
From Mack (2026-07-29). The Null layer (01-GLOSSARY §2, reserved in 03-DATA-MODEL §5.2 since
the model was written) is now a shipped kind: an invisible, source-less, size-less layer that
carries only a transform, so layers parent to it and move as a rig.

**The variant is `LayerKind::Null`.** `LayerKind` is serde-serialised by variant name, so the
spelling is what lands in every `.lum` file on disk; it had to be the name the docs already
reserve rather than a working name, because picking it later would mean a migration for
nobody's benefit.

**The bridge enum deviates, and only there.** `BridgeLayerKind` is code-generated into Dart,
where enum members are lower-camel-cased — `Null` would become a member called `null`, which
is a Dart reserved word and will not compile. The bridge enum therefore names the variant
`NullLayer` (Dart: `BridgeLayerKind.nullLayer`). This is a spelling forced by the target
language at the outermost edge of the system: `lumit-core` and every engine crate keep
`Null`, nothing serialised changes, and no user-facing string is affected. In the interface
the kind is named the way an Adjustment layer is named — **Null** in the Timeline's add-layer
menu, **Add null layer** in the Composition menu.

**The label palette grows to nine chips.** K-189 gave each layer kind its own starting label
colour from an eight-chip palette, and the eight were exactly taken by the seven earlier
kinds plus the neutral default at index 0. Rather than give the Null a chip that already
means something else — index 0 would have made every new Null read as "no colour chosen" —
the palette gains a ninth (coral). The chip picker now draws `LumitTheme.labelCount` chips
rather than a hand-kept literal, so the next kind costs one line in the theme.

**What a Null deliberately does not do.** It emits no node in the evaluation graph and draws
no pixels, and `has_picture` answers false for it, so it is not offered as a matte source or
as a layer-valued effect parameter — before this the catch-all arm handed it a picture it
does not have, and picking it silently produced nothing. Its transform still feeds the frame
key, so moving a Null retires the cached frames of the rig hanging off it. Two gaps are
recorded rather than closed (docs/TODO.md): a Null cannot be selected in the Viewer, because
unlike AE's 100×100 box it has no size to click; and effects added to a Null are accepted and
never run, harmless as on a Camera but neither refused nor labelled.

**CI re-runs codegen and diffs.** The checked-in Dart for this feature was stale on arrival —
the generated doc comment described wording the Rust source no longer had — because nothing
in CI ran `flutter_rust_bridge_codegen generate` and checked the tree came back unchanged. It
does now, on Linux, at the version the workspace pins. A generated file is an output, and an
output is checked by CI, not by a reviewer's eye.

**K-207 · DECIDED · The lane area is rows all the way down, the work area is a band you can
drag, and the playhead has a head.** From Mack (2026-07-29). Four defects reported against
K-202/K-203 while testing them.

**The lane area has no bottom.** The rows were laid out to their own height, so with one
layer in the comp everything below 22px was blank: no ground, no seams, and — since K-203
put deselect on the ground — nothing to click on to let go of a selection. The scrolled
content is now given at least the viewport's height, and the two-shade ground, the row
seams and the marquee run to the bottom of the panel whatever the comp holds.

**The work-area wash is drawn over the bars as well as under them.** K-202 put it under, so
it showed only in the gaps between layers — which is to say it disappeared exactly where
there was something to look at. The same wash is now painted again over the rows at reduced
strength: out of range reads as dimmed, not hidden.

**On the ruler the work area is a band in the lower half**, as 07-UI-SPEC §4.1's
top-to-bottom order always said it was, rather than a tint over the whole ruler competing
with the ticks and labels. Its handles keep the full height to grab.

**Dragging an edge no longer lags the pointer.** The handle was drawn from the work area the
*engine* returned, so every frame of the drag went out to the document and back before the
mark moved. The ruler now holds the dragged edge itself and draws from that, and commits
only when the drag crosses a frame — a pointer emits many moves per frame of travel, and
each commit costs a document write and a panel rebuild.

**Playback loops the work area** (07-UI-SPEC §10: loop work area is the default mode).
Reaching the end starts again from the start, restarted through `play` rather than by moving
the playhead, because the sound and the scheduler's clock both take their baseline from the
frame play was asked for. A comp that has not been narrowed plays to its end and stops, as
before.

**The playhead has a head** (15-DESIGN §6.5): an 11×8px accent triangle at the top of the
ruler with the line carried into it as a notch in `surface_0` — black on a dark scheme,
white on a light one. A 1px line alone reads as a row seam at a glance.

**K-208 · DECIDED · A layer drag moves both halves of the Timeline, and the two halves
measure the table once.** From Mack, reporting Airizz (2026-07-29). The Timeline's outline
and lane area are built as two columns of rows side by side, which is what makes their
horizontal scrolls independent and their layout easy to follow. Two things came out of that
which needed answering: an animation that cannot cross the seam, and a table that can be
misaligned by getting one height wrong.

**The drag state belongs to the panel, not to the outline.** The gesture is made in the
outline — the name is the stack handle — so only the outline knew a drag was in flight, and
only the outline could move: the names slid out of the way while the bars beside them sat
still. The lifted index and the index it would land on now live on the panel and are read by
both halves, which slide their blocks by one shared, tested function. In graph view there
are no lanes to move, so the outline animates alone. Transform only, ≤150ms, at the user's
animation level including zero (15-DESIGN §8).

**The row heights are worked out once per panel build and handed to both halves.** Two
measurements that must agree are two chances to disagree, which is exactly the failure
Airizz warned about: get one height wrong and the two sides of the table stop lining up.
The same walk now feeds the outline, the lanes and the drag maths.

**The outline's per-row seam is gone.** It drew a second hairline a fraction of a pixel from
the one K-192's overlay already draws, and the overlay is phased by the scroll offset — which
a trackpad leaves fractional — so the two lines pulled apart as the table scrolled and the
outline's rows read taller than the lanes.

**Zoom no longer slides before it settles.** Ctrl+wheel held the frame under the cursor by
correcting the scroll offset in a post-frame callback, which painted one whole frame at the
new width with the old offset. The jump is made in the same turn as the zoom: `jumpTo` does
not clamp, and the layout that follows already has the wider content, so the viewport clamps
it correctly on the way through.

**Not done: merging the two halves into one row widget.** Airizz's suggestion — one row
spanning outline and lanes — would make misalignment structurally impossible and any future
animation free. It also means the lane side's horizontal scrolling stops being a scroll view
and becomes an offset the rows apply themselves, taking the ruler, the cache bar, the
playhead, the work-area ground, the marquee and the graph view's scroll plumbing with it.
The requirement attached to this round was that both views behave exactly as they do now, so
the seam stays for the moment; this entry does not close the door on it.

**K-209 · DECIDED · Icons draw at 16px and land on the pixel grid.** From Mack, reporting
Airizz (2026-07-29): the icons read as crunchy, and the guess was that anti-aliasing was
missing. It was not — it was the mechanism. Iconoir's line art carries a 1.5-unit stroke on
a 24-unit grid, so an icon drawn at 12px has a 0.75px stroke, which the renderer can only
show as two part-lit pixels either side of where the line belongs. Panels had drifted to
10–13px against 15-DESIGN §5's stated 16 for panels and 20 for the transport; both are now
named constants, and 16 is recorded as a **floor** with the arithmetic that makes it one.

Icons are additionally offset half a device pixel when their stroke is an **odd** number of
device pixels wide, so a one-pixel stroke lands on a pixel centre rather than on the
boundary between two — the difference between one lit pixel and two half-lit ones, and it
applies to most of the geometry in an interface icon set. Not applied at even widths, where
the stroke already covers whole pixels and the nudge is what would blur it. At fractional
display scalings (150%) no offset makes a stroke whole; that is inherent and is stated in
the note rather than papered over.


**K-210 · DECIDED · The dropper reads a value at a pixel — not only a colour — and the
picker applies live.** From Mack (2026-07-30), asking for the egui build's two tools back in
Flutter, in the shape they had there.

**The dropper is a pixel tool, not a colour tool.** It is armed from whatever wants a value
at a point, and what it lifts is that thing's business: a colour for a Colour parameter, a
*depth* for the depth-of-field focal point. The armed state therefore carries what is being
read and a closure to write it, rather than naming a layer, an effect and a parameter index
to be re-resolved on the far side of the picture — which is what the egui build did, and the
source of its silent "the target has since moved" no-ops.

**The magnifier is fixed at 9×9 with the region inside it.** Nine pixels a side, dashed rules
between every pair, and a solid border round the pixels actually taken — the centre pixel
alone by default, grown by Shift+scroll through 3×3, 5×5, 7×7, 9×9. The ladder is odd
throughout so there is always one centre pixel, and never exceeds the grid, so the tool can
never average over pixels it is not showing. The border's corners take the theme's control
radius: rounded under the round shape, square under the sharp one, with no shape flag in the
widget. Shift+scroll no longer also zooms the Viewer — sizing the sample while the picture
moves out from under the pointer is not two features, it is one broken one.

**The magnifier belongs to the pointer being over the picture, and to nothing else.** It is
shown only while the pointer is over the drawn image — arming shows nothing until then, and a
fresh arm forgets where the last pick left the pointer, which it did not: the magnifier
appeared the instant the tool was armed, sitting where the previous pick had happened. And it
keeps one fixed offset from the pointer everywhere. It used to be clamped inside the Viewer,
so approaching the bottom-right corner it crept over the very pixels being aimed at and then
stopped following the pointer at all — a pick there is as ordinary as a pick anywhere else.
It is drawn in the application's overlay rather than in the panel's own stack, which is what
lets it hang over whatever is beside the Viewer and so need no clamp. (Both reported by Mack
on testing.)

The **window's** edge is the one exception, and it is answered by flipping rather than sliding
(Mack, asked for explicitly): the viewfinder goes to the other side of the pointer on whichever
axis would run off — above instead of below, left instead of right, each axis independently —
at the same distance, so it still never creeps over the pixel being read. Only a window with
room for neither side clamps, because half a magnifier beats none. The bound is the **window's
content area, not the display's**: an application cannot paint outside its own window, so a
magnifier past the screen edge is one the window would have clipped anyway — and where the
window sits on the display is not something Flutter reports without a windowing plugin, which
would buy no extra room.

**Living in the overlay means the panel's rebuilds are not the magnifier's.** Where it goes is
worked out when the **pointer moves** — the one moment both trees are settled — and used
afterwards as plain numbers. Asking render objects where they are from inside the overlay's own
build, and marking that overlay dirty from inside the panel's build, are both wrong for the
same reason, and an ordinary scroll over the Viewer did both: the wheel zooms the picture, the
panel relays out, and the magnifier tried to place itself against a tree mid-rebuild — a red
window and `'attached': is not true` (Mack, on testing). Nothing that places it touches a render
object now, and a redraw asked for during a build is deferred to after the frame.

**The strip under the grid says what is about to be taken, in the terms of the thing being
picked.** A colour pick shows the colour and its numbers. A pick reading something else shows
**the layer the numbers come from and the value found there** — a swatch of the composite
would be a colour nobody is choosing.

**A layer pick samples that layer rendered alone.** The egui build read the depth from the
composite's luma, or from a stashed copy of the layer's decoded pixels; the composite is
wrong (a depth pass is nearly always hidden, so it contributes nothing to it) and the stash
was a second path to keep in step. The worker instead renders the composition with that layer
soloed and visible, on a *patched copy* of the snapshot that never goes near `commit`, and
holds one such render against `(comp, frame, layer, cache generation)` so dragging the pointer
renders once rather than once per move. `depth_invert` is applied at the pick, so the caption
and the committed number cannot disagree.

**The pixels cross as a window, not a frame — and not a pixel.** A `sample_pixels` request
answers with a **129×129 square** of the picture (66 KiB) on the same stream the frames and
traces ride, and the frontend cuts the magnifier's own 9×9 out of it. Moving the pointer and
changing the sample size then cost nothing at all; a read happens only when the pointer nears
the window's edge, the playhead moves, an edit lands, or a different layer is being read. The
first cut of this asked per mouse move — a request, a cache lookup and a stream message at
pointer rate, each one cloning the whole eight-megabyte frame to copy 81 pixels out of the
middle (Mack, on testing: "a crazy number of calls"). Two fixes, both kept: the window, and
`framecache::with_best_frame`, which hands a reader the pixels **in place** under the cache
lock instead of cloning them — bounded, pure-CPU, nowhere near the GPU or the FFI boundary.

**A read is asked for as a fraction of the picture, never as a pixel.** The picture the engine
reads is a reduced-resolution preview whenever the Viewer is showing one, so its pixel grid is
neither the composition's nor anything the frontend can know in advance. The first cut of the
window asked in composition pixels and then indexed the reply with them: with a fitted Viewer
the two grids differ by the preview scale, every index fell outside the window, each one
clamped to the nearest edge — and the magnifier showed nine by nine of the *same* pixel, which
reads as a flat average of the area (Mack, on testing: "just an average of all the values in
it… and it might not be aligned"). The request now carries `(u, v)` in 0–1, the reply says
which raster it cut from, and every pixel either side names is in that raster; asking in the
wrong grid is no longer expressible. The clamp went too: a position outside the window answers
**nothing** rather than its nearest edge, so the next such mistake shows as blank cells instead
of a plausible colour. (Beyond the *picture's* border nothing changes — the window carries the
picture's own edge repeats, so those positions are inside it and answer normally.)

The size is chosen to sit between the two failure modes. Whole-picture-once — the obvious
answer — is 8 MiB at 1080p and 33 MiB at 4K, an 8.8 ms codec stall (35 ms at 4K) on arming and
that much held while armed, which is the very transport K-183 deleted, reintroduced through a
tool. A window is two orders of magnitude smaller, and one still lasts sixty pixels of pointer
travel in any direction. The cap is enforced engine-side rather than trusted from the caller,
so no request can turn this into a frame transport by the back door. It is a worker request
rather than a synchronous call because the pixels only exist where the renderer does, and the
renderer is owned outright by the worker thread — a sync call would have to render on Dart's
UI isolate or take a lock across GPU work, both of which docs/14 forbids.

**The picker's numbers are in the scale of the thing being edited, and a channel may exceed
1.** A display colour — a theme colour, a solid's swatch — is eight bits, so it reads 0–255 and
its hex is the same value said another way. A scene-linear colour in a float working depth
(fp16 today, docs/06 §3.1) reads 0–1 for black to white, as decimals, and may go **above 1** or
below 0 as far as the parameter's own declared range allows: several built-ins declare 0–4
precisely because HDR tints are legal in linear light, and one declares −1 for a lift. A 0–255
dial cannot express those at all, so the picker was silently clamping values the engine carries
happily (Mack, on testing). The square and the strip stay 0–1 — they are a chromaticity
picture — and an over-range colour is carried through them as a gain on its brightest channel,
so dragging about on the square does not quietly throw the overshoot away.

**The hex box stays, clipped, and says so.** Hex is an eight-bit display notation and cannot
say 1.8. Hiding the box on the float scale loses the one notation people actually exchange
colours in; showing a clipped hex silently would let it read as the truth. So it shows the
colour clipped into 0–1, typing one sets exactly those values, and a line under the swatches
appears whenever a channel is outside the range the swatch and the box can show. When the
project depth switch lands (docs/06 §3.1, not built), an 8 bpc project is what puts an effect
colour back on the 0–255 scale; nothing else needs to change.

**The picker applies to the document as it changes.** R, G and B sit above the graph, each
drag-scrubbable and typeable, and every edit — a number, the square, the strip, the hex box —
previews live and settles into one undoable edit, the same staged-drag shape the effect rows
use. Because the live value *is* the document's, closing the picker needs no decision:
clicking away from it keeps what is applied, and so does Apply. **Cancel** is the one button
that changes anything on the way out — it writes back the colour the picker opened with. A
plain "Close" was considered and rejected: with live application it would be indistinguishable
from Apply, so it would be a button that promises a choice it does not have.

**Not done here:** the x/y position pick for coordinate-valued parameter pairs. The magnifier
carries the mode, but no Flutter row pairs x and y into one control yet, so there is nothing
to arm it from; recorded in docs/TODO.md rather than half-wired.
**K-211 · DECIDED · A layer's ends are handles, and its source is the limit.** From the
owner (2026-07-30; numbered K-210 while it was in review, and renumbered on the merge that
gave that number to the dropper): the start and end of a layer must be draggable to change its length,
for every layer kind — and a Footage, audio or Precomp layer must not be draggable to show
what its source does not hold, unless it is retimed.

**Trimming for every kind.** Dragging either end of a bar trims that end; dragging its
middle moves it, as before. The grab zone at each end is 8px but never more than a third of
the bar, which is what makes a short bar draggable at all: at a flat 6px a two-frame bar was
entirely edge, so it could be trimmed but never moved. The pointer takes the horizontal
resize arrow over each zone, because an affordance nobody can see is one nobody uses — the
gesture existed before this entry and the report was that it did not.

**The source is the limit.** A layer whose source has a length of its own trims within it:
the in point stops at the source's first frame (the layer's own time zero, which is where
`start_offset` puts it on the comp timeline) and the out point stops at its last. That is
Footage — picture and sound alike — and Precomp, whose length is the nested comp's duration.
Every generated kind (Solid, Text, Adjustment, Null, Camera, Sequence) has nothing to run
out of and trims freely. **Retime takes both limits off** (docs/04-RETIMING.md): a retimed
layer maps its own local time onto source time, so its length stops being the source's
business and it stretches as far as it is dragged. Both routes to a retime count — the
Retime property (K-197) and the Source card's older speed map — because both make the same
promise. Moving a bar is never limited: `start_offset` travels with it.

**A bound never drags an edge that is already outside it.** A layer stretched while retimed
and then un-retimed keeps the length it has; the limit holds its end still rather than
snapping it back, and pulling back towards the source is always allowed. Anything else would
silently destroy work on a switch toggle.

**Media that will not read leaves the ends free.** A missing file, or a build with no media
feature, answers "no length" — and no length means no limit, never a limit guessed at. A
layer must never be cropped by the absence of an answer.

**The marks: a small triangle in the top corner of the bar** on the side that is at its
limit, drawn in the same ink as the clip splits so the bar keeps one vocabulary. Present
only on the kinds that have a source, absent the moment Retime is on — the mark and the
rule are the same fact, so they can never disagree on screen.

**Where the rule lives.** In the panel, not the engine. `SetLayerSpan` still accepts any
span that is not inverted: AE import, project load and `trim_to_source_end` all legitimately
write spans the drag would refuse, and an op that second-guesses its caller would break
them. The gesture is what is bounded, and the bound is a pure function with its own tests.

**What it costs per rebuild: nothing (K-184).** A footage length comes from probing the file,
so it is asked once per layer off the build and kept for the session, like the waveform
peaks. The rest — a precomp's duration, whether Retime is on, where the start offset sits —
is worked out once per *document revision* and cached; `CompModel` now exposes that revision
so a panel can cache anything derived from the model honestly. Frames come from exact
integer arithmetic on the comp's rate rather than a `frame_at` call per layer per frame.

**K-212 · DECIDED · Letting go of Retime re-hangs the layer on its source, and a
trimmed layer shows how far its media reaches.** From the owner (2026-07-30), refining
K-211. Two halves, both about the same thing: a layer's relationship with the material
behind it should be visible, and should survive being switched about.

**Switching Retime off re-anchors the layer.** While it is retimed a layer can be any
length, because it chooses which source moment each of its own frames shows; when the map
goes away it plays at source rate again and has to be given a length. Holding the stretched
length (K-211's first answer) was wrong: it left the layer showing material the source does
not have. The rule now is the frame already on screen. The layer keeps its **in point** and
shows the **same frame** there — so if that was the source's first frame it simply starts
from the beginning, and if it was some way in it carries on from there. From that anchor it
runs at source rate until either the source runs out or its own out point arrives,
**whichever comes first**. It never grows: a layer trimmed short stays short. One undo step
covers the removal and the span together.

The anchor is snapped to the **comp's** frame grid rather than kept at full precision. The
start offset it produces is what every later trim measures from, and an offset sitting
between two frames puts the layer's own zero between two frames for good; the timeline edits
in whole frames, so the anchor does too. Both routes to a retime behave identically — the
Retime property (K-197) and the Source card's speed map — because both make the same promise.

`unretimed_span` is a pure function in `lumit-core::ops`, next to `edit_layer_span`: this is
span arithmetic, and it is the kind of rule that must be provable rather than observed. The
bridge supplies the two facts it cannot derive — the source moment showing at the in point,
read through the map that is about to go, and the source's own length. No readable length
(missing media, a build without the media feature) re-anchors and leaves the out point
alone, the same "no length is never a guessed length" rule K-211 set.

**A trimmed layer shows its source's reach.** A Footage, audio or Precomp layer that is not
retimed and does not fill its source draws a **faint outlined rectangle spanning the whole
source**, behind the bar, in the layer's own label colour. What shows past each end is
exactly the material trimmed away, and because it is drawn behind, the layer reads as one
clip with the middle solid rather than as three objects. It is absent when the bar already
fills the source, absent on the kinds with no source, and absent under Retime, where "the
source's reach" is not a fact about the layer at all. It sits with K-211's corner triangles
in one vocabulary: a triangle says *this end can go no further*, the ghost says *this end
could go further, and this is how far*.

**Both marks travel with a move.** They are drawn from the source's reach, which moves with
the layer: sliding a bar along the timeline carries its start offset, so the bounds slide
with it. Drawn from the document's bounds alone, a bar being moved appeared to leave its
limit behind — the fix is one shift applied to both marks while a move is in flight.

**The trap the ghost set, recorded because it cost a working gesture.** The outline is a
second child of the bar's `Stack`, and it appears the moment a trim starts. Unkeyed,
Flutter matches a `Stack`'s children by position, so the ghost arriving took the bar's slot
and the bar's element — with it the recogniser holding the drag in the gesture arena — was
rebuilt from scratch mid-gesture. The bar moved by the first pointer event's worth of
frames and then went dead: "dragging a footage edge only moves one frame". Both children
carry keys now. It only ever bit the source-backed kinds, because they are the only ones
with a ghost to appear, and only when the pointer moved in more than one event — which is
why the first round of tests, each dragging in a single synthetic step, all passed.

**K-213 · DECIDED · Keyframes live in the layer's time and cross on the composition's
clock.** From the owner (2026-07-30): switching Retime on put its two keys "where the start
and end points would be if the layer's position was still at the start of the comp". They
were, and so was every other keyframe on any layer that had been moved — the report caught a
seam fault whose only unmissable face is the two keys Retime creates for you.

**The engine keys properties in layer-local time, and that is right.** Every evaluation
path — the render plan, the transform sampler, the cache-key hasher — reads a property at
`comp time − start_offset`, so a layer's animation travels with the layer when it is
dragged along the timeline. That is the behaviour an editor must have; nothing about it
changes.

**The frontend thinks in comp frames, and that is also right.** The ruler counts comp
frames, a lane is drawn against the comp's axis, and a key drag commits where the pointer
is. Asking the interface to hold two clocks would put the conversion in every row, lane,
curve and field that touches a key.

**So the bridge converts, and it is the only place that does.** `BridgeScalar::read_at`
carries each key out by the owning layer's `start_offset`; `animation_at` carries it back.
Both take the offset as an argument with no default, so a new reader cannot quietly forget
one — the compiler asked for it at all forty-odd call sites when the signatures changed.
Everything that crosses carrying keys goes through them: the transform group, the Retime
property, effect parameters, a camera's zoom, a volume curve, and the staged
`BridgeEffectInstance` — which now carries its layer's offset, because a handle read out of
a layer is the only place that fact is known. `BridgeEffectInstance::new` stopped being
exposed to Dart in the same move: it was never called from there, and a constructor with no
layer would have no honest offset to take.

**Retime's two keys span the layer's own in and out.** `Layer::identity_retime` took a
duration and keyed zero and that duration; it now takes the layer's local in and out points.
Two faults in one: on screen the keys sat at the start of the composition, and in the model
a trimmed layer's map stopped short of its tail — past the last key a property holds, so
everything beyond `duration` played one frame over and over. Spanning the real range fixes
both, and keeps the promise that switching Retime on changes nothing visible.

**Not done: the pre-K-197 speed map.** The Source card's segment store has the same
"identity across `0..duration`" shape and the same tail problem on a trimmed layer. It is
not keyframed, so nothing draws it in the wrong place, and it is the arm the ponytail
comment in `Layer::source_time_at` marks for deletion; it is left alone rather than being
half-migrated. Recorded here so the next person meets it deliberately.

**K-214 · DECIDED · The frame cache is named by content, and its three tiers are one ladder.**
Requested by Mack (2026-07-30), from two complaints that turned out to be the same one: "a lot
of things are resetting the cache when they shouldn't — moving the work area, adding audio to a
layer, changing the opacity of a hidden layer", and "when I undo, we shouldn't have to cache
from scratch again". Both are the cost of positional keying, which K-178 recorded as an interim
and this entry closes.

**Every tier is keyed by the content hash the specification always asked for** (docs/06 §5.2),
not by `(comp, frame, scale)`. A positional name does not change when the picture does, so the
only safe answer to a committed edit was to drop every held frame of every composition — and
the price was paid on exactly the edits that cannot change a pixel. There is now no
invalidation step anywhere: an edit renames the frames it changed and leaves the rest
addressable, so a rename keeps the bar green and an undo finds its frames still filed under the
names the restored document asks for. It also makes the disk tier honest, which is why the
TODO listed content keying as its blocker: a frame parked under a positional name would serve
the picture from before an edit, or from another day's document entirely.

**The key gained a layer's inherited parent chain, and `ALGO_VERSION` went to 2.** A hidden
layer contributes nothing — it draws nothing — but its children still follow it, so moving a
hidden Null changed the picture while leaving every name alone. Harmless while everything was
discarded on every edit; a stale-frame bug the moment names started surviving. K-206 makes it
the common case rather than a corner: a Null is the layer a user will most readily hide.

**The demotion ladder runs both ways, and the read-back is asynchronous.** A frame evicted from
the card is read back into memory and written behind to disk; a frame held below is uploaded
straight back into a texture instead of being composited again. The upward half is what makes
the lower tiers worth having at all — before it, nothing could turn held bytes into a picture
the Viewer shows.

**Deviation from docs/06 §5.3, recorded rather than hidden: there is no cost threshold on
demoting.** The specification says to read a frame back only when its recompute cost exceeds
the read-back's, which is the right idea; the number to compare is not available. A composite
is *submitted* to the graphics card and the call returns, so the wall-clock a renderer can
measure around it is the submit, not the work — a frame that costs the card 8 ms can measure
under one, and a threshold on that gates the ladder on noise. What bounds the traffic instead
is a ceiling of four read-backs in flight, which bounds it directly; the measured cost is still
used for eviction *ordering*, where a comparative number is good enough. Two derived rules: a
frame promoted up is never demoted again (it is already below), and a frame goes to disk on the
way down rather than when memory later forgets it.

**The disk cache lives in Lumit's own cache folder by default**, keyed by the document id,
rather than in the `<project>.lum-cache/` sidecar docs/06 §5.4 describes. The sidecar only works
once a project *has* a file, and a project should cache from the moment it is created; the
document id is in the `.lum` and survives every save. Both other options are offered in
Settings → Performance — beside the project (the per-project choice) and a folder the user picks
— and changing the setting moves nothing, since a cache folder is deletable at any time with no
correctness effect. A per-project override stored inside the `.lum` is left in the backlog.

**Clearing the disk tier asks first**; the other two do not. RAM and VRAM cost a re-render each,
while this one deletes files that may represent a night's work and there is nothing to undo.
With nothing parked it does not ask.

**The cache bar became a published strip rather than a query** (docs/06 §5.6's "lock-free bitmap
snapshot", which was always the design). Naming a frame needs the renderer's probe results and a
hash per frame, so the interface cannot answer its own question: the bar records what it is
drawing and the worker publishes the strip for it. Consequences stated rather than papered over —
up to ~150 ms stale, blank for a beat after a composition switch, and sampled on a composition
longer than about a thousand frames, because the stripe is a thousand pixels wide at most. Its
values grew from three to five: nothing, held-coarser, held, on-disk-coarser, on-disk, with
playable outranking promotable.

**The card's tier and memory's share one colour on the bar** (mint), because they answer the same
question — does this frame play now — and a frame in memory is one upload from the screen. Which
of the two holds it is the status line meter's business, where each tier has its own bar.

**K-215 · DECIDED · The three follow-ups K-214 left in the backlog are closed.** Requested by
Mack (2026-07-30): implement what the TODO named rather than leaving it. Each was a stated gap,
and each is a different kind of gap.

**The disk tier has an index, so it evicts by the same rule as the tiers above it.** It held
nothing beside its files, so the only thing it could sort by was the modification time a
filesystem happens to remember — it deleted the oldest frame even when that frame had cost half a
second to render and its neighbour two milliseconds. It now records size, recompute cost, last use
and quality per entry, so presence and the byte total cost nothing at run time and eviction is the
spec's stale × large ÷ cheap-to-remake (docs/06 §5.3) from the top of the ladder to the bottom.

Two files rather than one, which is the interesting part: a snapshot (`index.bin`) rewritten now
and then, and a log (`index.log`) with one fixed-size record appended per change. A snapshot
rewritten per change rewrites megabytes to record one frame; a snapshot rewritten only
occasionally loses what happened since, and those losses are *worse than forgotten* — the files
remain on disk taking up room nothing knows to reclaim. Opening replays the log over the
snapshot; a record torn by a crash is a partial trailing record and is discarded by length, which
is what fixed-size records buy. Either file missing or unreadable falls back to walking the
folder, which is §5.4's "rebuilt by scan if missing or corrupt".

**A deviation from §5.4, recorded rather than silent: not SQLite.** The spec says `index.db`. This
is a flat map of fixed-size rows read once at start-up and otherwise held in memory; SQLite would
put a C dependency into an engine crate to store it, and the media frame index (docs/10 §3)
already sets the house precedent of a plain binary sidecar.

**The cache bar converges on per-frame truth instead of staying sampled.** Naming a frame means
hashing the composition at that time, so a ten-minute composition is tens of thousands of hashes
and the first version sampled one frame in forty. Two passes now: the sampled pass still runs
first, because the bar owes an answer for the whole composition at once — a stripe filling in from
one end reads as the *cache* filling in from one end — and a refinement pass then walks the strip
in bounded chunks replacing each sample with the frames it stood for, starting at the frame last
shown and wrapping so the region under the playhead firms up first. A composition short enough to
name in one go has a stride of one and is exact on the first pass. Only a **held** sample paints
the frames it skipped: painting a stride green off one held frame and correcting it a moment later
would flash cache the user does not have.

**Where a project parks its frames can now be the project's own answer.** Application-wide is the
right default and was the wrong only-option: a project living on a scratch drive wants its frames
on that drive, and a project handed to someone else should carry the choice with it. So
`Document` gains `cache_location: Option<CacheLocation>` — `None` meaning "follow the
application", which is the ordinary case and stores nothing in the file — set through an ordinary
op, so it is undoable, journalled and saved like any other edit, and it travels with a copy of the
project in a way a settings-file entry could not. Settings → Performance gained an **Applies to**
row (*Everything* / *This project*); switching back to Everything clears the project's answer
rather than copying the application's into it, so the project follows along afterwards. A
project's answer overrides the application's, and changing either moves nothing — the frames in
the old folder simply stop being addressed, and that folder is deletable at any time.

**Not done, and deliberately: nothing about this is in the pull request for K-214.** Mack asked
for these on a branch of their own so the reviewable change stays the one that was reviewed.

**K-216 · DECIDED · The toolbar is one strip under the menu bar, and it ships with the whole
tool set whether or not each tool works yet.** From the owner (2026-07-31): the toolbar had
no counterpart at all on the Flutter frontend — the egui shell's tool row did not survive the
port, so the only tools that existed were the ones a panel happened to offer.

**Where it lives.** A single strip spanning the window below the menu bar and above the dock
(docs/07 §1.7). It is chrome: it cannot be closed, docked, tabbed or floated, and it is the
same strip in every workspace. Its right-hand end carries the two switches that belong to no
panel — snapping, and the workspace strip §1.4 has always required in the window chrome and
which until now existed only inside the Window menu.

**The tool set is After Effects', grouped as After Effects groups it.** Selection, Hand,
Zoom, Rotation, Anchor point, Razor, the five shape tools, the five pen tools, two type
tools, brush/clone stamp/eraser, roto brush/refine edge, four puppet pins, three camera
tools. A group is one button showing the member last used with a corner triangle; hold or
right-click for the rest; the shortcut arms the remembered member and, pressed again while
that group is armed, steps to the next and wraps. That last rule is why a tool chord is not
simply "select this tool": `Q` walking the shapes without opening a flyout is the gesture
the audience arrives with.

**Unbuilt tools are drawn, not hidden.** Only Selection and Hand do anything today; the rest
change the Viewer's pointer and nothing else. Shipping the strip with only those two would
have taught the wrong shape of the application and left no agreed place to put the rest as
they land — so the specified set is on screen, and each unbuilt tool's tooltip says plainly
that arming it changes nothing yet. The alternative — a tooltip that lies by omission — is
the one thing a toolbar must not do, because a toolbar is how a user learns what an editor
can do at all.

**The chords go through the keymap, and the Tools context is asked last.** The engine already
shipped `tool.select` … `tool.pen` in a `Tools` key context with nothing behind them (K-199);
this branch adds `tool.rotate`, `tool.type`, `tool.paint`, `tool.roto`, `tool.puppet` and
`tool.camera` beside them and gives all thirteen a frontend. AE's own chords wherever Lumit
has not already spent the key — `W` rotates, `Alt+W` is the roto brush — and `Shift+C` for
the camera group, because `C` was given to the razor in docs/07 §15 long before there was a
camera tool and moving either would break a keyboard people already have in their hands.
`Tools` is not a panel, so no focused pane ever *is* that context: a chord resolves against
the focused panel and the global table first, and reaches the `Tools` table only if both
decline. That ordering is what lets `C` cut a clip in the Timeline and arm the razor
everywhere else without either binding knowing about the other.

**The armed tool is session state.** Not project state — arming a tool changes no document —
and not workspace state either, so it is not written to the layout file; every session opens
on Selection, as AE does. It lives on the shell's UI state beside the dropper's arm, for the
same reason: it is set in one place and read in another, and no panel should have to be
mounted for either.

**K-217 · DECIDED · A layer is something you can see the edges of, point at, and take hold
of.** From the owner (2026-07-31), specifying the first two toolbar tools: the Selection tool
should drag the layer under the pointer, hovering one should say so before the click lands,
several should be selectable at once, and the Hand tool should move the picture and never
the layer. Everything here follows from that.

**The wireframe is the layer's own rectangle, put through its transform.** Not the comp's:
the box the Viewer drew before this was the comp rectangle for every kind, which is only
right when the layer happens to fill the frame. A layer's rectangle comes from what it is
made of — a clip's frame size, a solid's dimensions, a nested comp's size — and is
comp-sized for the kinds with no content of their own. A Null gets a 100×100 box of its own,
because "no pixels" must not mean "cannot be selected": rigging is exactly the job that
needs to grab one.

**Content sizes are the frontend's to cache, not the read model's to carry.** A clip's size
is a question about a *file*, and the honest answer needs FFmpeg — which is disk work and
asynchronous, so it cannot sit in `get_model`, which runs on every document change. So the
Viewer holds a small cache: cheap kinds are read from the document and dropped whenever the
revision moves; a clip is probed once per session, and the layer falls back to the comp's
size until the answer lands. This is the same fallback the engine itself uses when it places
a clip it cannot probe, so a missing file is a full-frame box rather than a box of nothing.

**Selection is a list, and `selectedLayer` is its first entry.** Almost everything in the
application acts on one layer and reads that notifier directly; teaching forty call sites to
take the head of a list would have been a large change with nothing to show for it. So the
list lives beside it, and setting the single one — which the Timeline and every test do —
makes that layer the whole selection. Delete now takes the whole selection: with several
boxes on the picture, deleting one of them would be a surprise every time.

**What a press means is decided by where it went down, not where the drag was recognised.**
Flutter reports a drag's start position *after* the pointer has travelled its slop, which is
already further than a 9px handle is wide — every handle drag would have been read as a drag
of the layer's body, and the first version of this was. The press point is recorded
separately, and the slop's travel is folded into the drag so a move does not lag the pointer
by it for the rest of the gesture.

**The marquee takes only what it wholly contains.** After Effects' rule, and the one that
makes a sloppy sweep predictable: a rectangle that merely clips a corner of a layer is far
more likely to be an accident than an intention.

**The layer-controls switch hides the marks, not the mouse.** The Viewer bar's new switch
governs drawing only — clicks and drags still select and move with it off. It exists because
a grade cannot be judged with a box and eight handles over the picture, which is the same
reason the surround is neutral (K-203); it is not a way of putting the tools down, and After
Effects' Show Layer Controls behaves the same.

**A preview may fail; a gesture may not.** The provisional picture during a drag is a
courtesy, and asking for it crosses the bridge, where anything can throw (a stopped worker,
a machine with no adapter). It threw out of the pointer handler and killed the drag
mid-stroke, commit and all. Every preview and every commit in the gizmo is guarded now: the
boxes follow the pointer and the edit lands whatever the renderer is doing.

**What is deliberately not built yet.** A multiple selection moves but grows no handles —
scaling a set about one shared box is different maths, not a smaller version of this one. A
keyframed position draws no box at all, because the read model carries the curve rather than
its value at the playhead, and a box in the wrong place is worse than none. The anchor
handle, snapping, parent-aware and 3D gizmos, and motion paths are unchanged from before
this entry: still specified, still absent, now listed in docs/TODO.md against §2.3.

**K-218 · DECIDED · Every zoom is anchored, and — except the wheel — every zoom is a
flight.** From the owner (2026-07-31), specifying the Zoom tool and asking for zooming across
the interface to stop jumping.

**One piece of arithmetic, three gestures.** The wheel, a click of the Zoom tool and a
dragged box are the same question — what magnification and pan put *this* where I want it —
so they go through the same two pure functions rather than each growing its own version. The
click doubles about the point clicked (`Alt` halves), which is After Effects' step and the
one the magnification menu's own list walks; the box fits its rectangle to the panel and
centres it, and `Alt`+box is the exact inverse, shrinking the whole view into the box's
footprint. Being an exact inverse is the point: `Alt` undoes the sweep you have just made
rather than being a differently-sized guess at it.

**Anchoring is the property worth testing.** "The comp point you aimed at does not move" is
what makes zooming feel like leaning in rather than teleporting, and it is a property a unit
test can state in one line for all three gestures. The tests assert exactly that, not a
table of expected numbers.

**Zooming animates, and the interpolation is geometric.** A magnification change is a *place*
changing, not a value being nudged: cutting from one magnification to another loses the
reader's place, which is the very thing anchoring exists to keep. So it travels, over the
shell's own motion duration (15-DESIGN §7), and cuts instantly under *No animation* — the
setting means what it says. The interpolation is on the logarithm of the magnification,
because magnification is a ratio: lerping the number itself makes the first half of a 1× → 8×
flight bolt and the second half crawl. The magnification and the pan are animated together
from one controller, because animating them separately lets the anchor point drift mid-flight
— which is the whole promise, broken in the middle where it is most visible.

**The wheel stays instant.** It already arrives as a stream of small steps; animating each of
them puts the picture behind the fingers. A gesture that is itself continuous does not want a
second continuity laid over it.

**The frame is re-asked for at the end of the flight, not during it.** The engine renders at
the size the picture is *shown* at, so the frame in hand is the wrong resolution once the
magnification has changed — but a render per frame of a 120 ms animation is a render per
frame for nothing, since the intermediate ones are stretched by less than the eye can hold.

**Not done: the same treatment everywhere else.** The Timeline's time zoom, the graph
editor's, and the Project panel's thumbnail scaling all still jump. They want the same
pattern — a target, a controller, a geometric interpolation, and the animation level deciding
whether it runs — and it should be lifted into one shared piece rather than written three
more times. Recorded in docs/TODO.md.

**K-219 · DECIDED · The Rotation tool turns the selection about each layer's own anchor, and
its pointer is drawn rather than picked.** From the owner (2026-07-31), specifying the fourth
toolbar tool: the cursor should be a curved arrow like After Effects', sharper at a corner
than along an edge, leaning the way the layer would turn — and the drag should turn only what
is selected, about the anchor, with `Shift` locking to 45°.

**The pointer is painted, and the system one is hidden under it.** No desktop platform ships
a rotate cursor, and Flutter can only ask for cursors the platform has — so this draws its
own over the picture. Hiding the real pointer is not a thing to do lightly, and it is worth
it here for one reason: a drawn pointer can *turn*. The arc faces away from the layer's
anchor, so it always curves round the pin the layer spins on, and it closes up towards a
corner and opens out along an edge — so the pointer says where you are on the layer without
your looking away from the picture. A cursor that could only sit there in one orientation
would not have been worth hiding anything for.

**Corner-ness is measured in the layer's own space.** The arc's width comes from how equally
far out the two axes are from the middle: equal is the diagonal, which is a corner; one alone
is square out from an edge. Measured through the layer's inverse map, so "the top-right
corner" stays the top-right corner of the *layer* when the layer is upside down — the same
reasoning as the wireframe's hit-testing (K-217), and the same one line of maths.

**A set turns as one gesture.** The angle is swept about the *first* selected layer's anchor
and applied to every selected layer, each of which still turns about its own anchor. The
alternative — each layer measuring its own angle from the same pointer — makes a multiple
selection fly apart the moment the anchors differ, which is not a rotation of anything.

**Clicking selects, as it does with the Selection tool.** After Effects' behaviour, and
without it every turn would mean a trip back to the toolbar to choose the next layer.

**The anchor is marked while the tool is armed.** A rotation about a point you cannot see is
a rotation you cannot predict, and the anchor is exactly the thing this tool is *about*. It
is drawn as the ring-and-cross the anchor-point tool's icon carries, so the two read as one
idea.

**The same slop trap as K-217, in a new place.** The turn is measured from where the pointer
went *down*, not from where the framework recognised the drag: recognition happens after ~18
pixels, and measuring from there took a fixed bite out of every turn — a quarter-turn drag
committed 45° instead of 90°. Recorded twice now because it will keep coming: any gesture
whose *meaning* depends on its start point has to record that start point itself.

**K-220 · DECIDED · The Anchor point tool pans behind, and the Razor cuts under the blade.**
From the owner (2026-07-31), asking what After Effects does with these two and for the same
behaviour here. The answers differ, because only one of them is an After Effects tool at all.

**Anchor point is AE's Pan Behind, and the name is the behaviour.** Dragging a layer's anchor
naively moves the layer, because Position places the anchor: change the anchor and the same
Position means somewhere else. The tool moves the anchor *and* compensates Position by
exactly the amount that cancels the jump, so the pivot slides while the picture stays still.
The maths is `pan_behind_position`, ported from the egui frontend's anchor overlay and
already unit-tested — this branch supplies the gesture round it, not new geometry.

Two modifiers, both AE's. `Shift` locks the drag to one **screen** axis (the lock is about
the hand's gesture, not the layer's axes, so it stays straight across the screen on a turned
layer). `Ctrl`/`Cmd` snaps the anchor to the layer's nine key points — corners, edge
midpoints, centre — measured in **screen** pixels, because a layer at 10% would otherwise
snap from half a screen away and one at 1000% would never snap at all. That is the same rule
docs/07 §4.5 sets for the Timeline: the distance a user can see is the distance that counts.

**One op for four properties.** The anchor pair and the position pair are only meaningful
together here — committing half of this edit *moves the picture*, which is the one thing the
tool promises not to do — so it goes through `set_transforms`, which exists for exactly this
and makes the drag one undo step.

**The Razor is not an After Effects tool, and copying Premiere is right.** AE has no razor:
it splits layers with `Ctrl+Shift+D` at the playhead, and the toolbar key `C` is its camera
cycle. Lumit has a razor because it has Sequence layers — the Vegas-style cutting surface
(K-071) — so the tool is Premiere's, and Premiere's razor cuts **where you click**, not where
the playhead is. The old behaviour (click a bar, cut at the playhead) made the tool a slower
way of pressing the shortcut; docs/07 §4.4 has always said "click a clip to cut it at that
time", and now it does. `Shift`-click cuts every layer that spans that moment, which is
Premiere's cut-all-tracks.

**Two kinds of cut, because there are two kinds of layer.** A Sequence layer holds clips, so
a cut makes an **edit point** inside it. Everything else **splits into two layers**, which is
what AE's `Ctrl+Shift+D` does — a new bridge op (`split_at`), one `Batch`, one undo step. The
halves keep everything (source, effects, masks, parent, label, keyframes) and — this is the
part that matters — the **same `start_offset`**, so each half shows exactly the frames it
showed before and every keyframe stays on the same comp frame (K-213). A cut at either end is
refused rather than making a layer of no length.

**One razor, two doors.** The Timeline's own "Arm razor" menu item now arms the *toolbar's*
tool rather than a flag of its own. Two pieces of state that both mean "the razor is armed"
is one too many: they would disagree the first time someone used the other door.

**Both pointers are drawn, for K-219's reason.** No platform ships a pan-behind cursor or a
razor. The anchor's pointer is the anchor's own ring-and-cross with a small arrow at its tail
(AE's pairing, and it says what the tool moves); the razor's is a blade with a full-height
line down the lanes marking where the cut will land — the line is the useful half, because a
cut you cannot aim is a cut you undo.

**K-221 · DECIDED · A cut through a retimed layer leaves a keyframe behind, and the gizmo's
centre handle pans behind.** From the owner (2026-07-31), two refinements to the tools that
landed with K-220.

**Why a cut needs a key.** Splitting a layer gives both halves the whole document — the same
source, the same effects, and the same Retime map. That is what makes the cut invisible, and
it is also what makes the two halves' speed ramps *one curve*: bend the first half's speed
afterwards and the second half bends with it, which is not what anyone means by cutting. So
the razor puts a keyframe at the cut, on both halves, giving each an end of its own to hold.
Premiere does the same to a speed ramp it cuts, for the same reason.

**And why the key must not change anything.** A cut that altered the speed ramp it was
cutting would be worse than no cut at all, so the insertion preserves the curve exactly. A
span is one cubic bezier (docs/impl/keyframe-eval.md §1); de Casteljau splits a cubic into
two cubics whose union *is* the original — not an approximation of it — so all that is left
is converting the control points back into the AE speed/influence pair each keyframe side
stores, which is the exact inverse of `CubicSpan::from_ae`. The test samples the span two
hundred times before and after and demands agreement to 1e-6. A held span is inserted flat,
because a hold has no shape to keep; a key outside the keyed range takes the held end value.

`Property::insert_key_preserving_shape` lives in `lumit-core::anim`, not in the bridge: it is
curve arithmetic, and the kind of rule that has to be provable rather than observed. The
razor calls it before cloning the layer, which is what puts the key on both halves.

**The centre handle.** The Selection tool's gizmo now has a ninth handle at the layer's
anchor, and dragging it pans behind exactly as the Anchor point tool does (K-220) — same
`Shift` axis lock, same `Ctrl`/`Cmd` snapping, same one-op commit. Its grab radius is 16px
against the other handles' 32, and that asymmetry is the whole design: the anchor usually
sits in the middle of the box, which is also the easiest place to grab a layer to move it, so
a generous slop there would turn every body drag into a pan-behind — the pivot sliding while
the layer stayed put, which reads as the drag being broken. The pivot has to be aimed at.

**K-222 · DECIDED · The shape tools draw masks, and a mask crosses the bridge as its path.**
From the owner (2026-07-31), choosing to build masks now and shape layers on a branch of
their own.

**The seam that did not exist.** `lumit-core` has had masks all along — bezier paths,
rectangle/ellipse/star constructors, and a renderer that applies them — and *no bridge API
exposed any of it*. The Flutter frontend could not see a mask, let alone make one. So the
first half of this is the seam: `get_masks`, `add_mask`, `set_mask`, `delete_mask`, and the
masks carried in the read model (K-184) so the Timeline's twirl-down draws a row per mask
without asking per frame.

**A mask crosses as its path, in layer space.** `BridgeVertex` is the engine's vertex — a
position and two tangent handles, each an offset from it — carried across unchanged, so a
path never changes meaning by crossing. Layer space, not comp space, because that is what
makes a mask travel with its layer's transform for free; the tool takes the pointer's screen
position and runs it backwards through the layer's map, the same inverse the wireframe
hit-tests with.

**Every edit is the whole mask.** The engine's op is `SetLayerMasks` — the whole list,
exactly invertible — so an add, a delete, a rename and an invert are all one shape of edit
and each is one undo step. The bridge refuses a path of fewer than two vertices: that is not
a shape, and a mask that gates nothing would be a Timeline row with nothing behind it.

**Two gestures, because there are two kinds of shape.** Rectangle, rounded rectangle, ellipse
and star are *boxes*: drag two opposite corners, `Shift` for square, and the drag reads the
same in all four directions because the box is normalised before the path is built. The
polygon is a *path*: click for a corner, click-drag for a vertex whose bezier handles mirror
each other as they grow, `Alt` to break that mirror, and a click on the first vertex closes
it — closing being what applies it. Escape abandons, Backspace takes back a point. (After
Effects calls this its Pen tool and gives its polygon tool a regular n-gon; the owner asked
for it on the polygon, and one path-building tool is better than two.)

**Masks sit above Effects in the fold-out**, because that is the order they are applied in: a
mask gates the layer's alpha *before* its effects run (docs/06 render order), so the
twirl-down reads top to bottom the way the picture is built.

**Nothing selected says so.** After Effects would make a shape layer; Lumit's `LayerKind` has
no Shape variant, so there is nothing honest to make. The tool posts a notice naming what to
do instead. Silence would read as a broken tool, and a solid-with-a-mask dressed as a shape
layer would be a lie in the layer list — one that would have to be untold when the real kind
lands.

**K-223 · DECIDED · The path-building gesture is the Pen's, and the polygon tool draws a
polygon. Supersedes K-222's placement of it.** From the owner (2026-07-31): "I think I
might've misunderstood the polygon tool — everything I said there applies to the pen tool."
They are right, and K-222 built it in the wrong place.

**What moved.** Click for a corner, click-drag for a vertex whose bezier handles mirror as
they grow, `Alt` to break that mirror, click the first vertex to close and apply, `Escape` to
abandon, `Backspace` to take a point back — all of that is now the **Pen** (`G`), which is
where After Effects puts it and where anyone arriving from AE will look for it.

**What the polygon is instead.** A shape you drag out like the others: the regular five-sided
figure inscribed in the drag's box, first point at the top, `Shift` for a regular pentagon in
a square box. It is the star without its notches, and the two now read as the pair they are.

**Why this was worth correcting rather than living with.** A tool that does something other
than its name is a tool that has to be explained every time; and the Pen sitting there doing
nothing while the polygon did the Pen's job would have been two wrong tools rather than one.
The code moved with the name: `PolygonDraft` is `PathDraft`, and it is documented as the
Pen's.

**And the five shape tools are marked built.** K-222 shipped them working while their
`ToolMode.ready` flags still said otherwise, so every tooltip claimed "not built yet" over a
tool that drew masks. `ready` is a promise about what a tooltip says (K-216) and it was
lying; a test now pins the set.

**K-224 · DECIDED · A mask's points are things you can aim at, sweep up and drag.** From the
owner (2026-07-31): "if you have the selection tool and wireframes enabled, if you have a
layer that's a shape or has a mask, you should be able to see the individual points that make
it up. And if you do the drag selection I mentioned it should select any point inside it so
you can alter and drag them about."

**What a press means, in one order.** Over the picture with the Selection tool the pointer
has more and more things under it, so the order they are tried in is the whole design: a
**scale or rotation handle** first (it sits on the box's edge, where the body also is), then a
**mask point** of a *selected* layer, then the **layer** under the pointer, then empty space.
Points come before the body because they are drawn on top of it and are much smaller; they
come after the handles because a handle is the coarser target and losing it would be worse.
Only *selected* layers' points are tried: a stray vertex of some layer underneath must never
steal a press meant for the picture.

**The marquee gathers points when there are points to gather.** A sweep from empty space that
catches any of the selected layers' vertices selects **those**, and the layer selection is
left alone; a sweep that catches none is the layer sweep it has always been. That is one
gesture doing two jobs, decided by what is actually under it — which is what After Effects
does, and what makes "select some points and move them" a single fluid thing rather than a
mode.

**Which forced the selection to be decided on release, not on press.** The old marquee cleared
the selection the moment it began. That is invisible when it is layers being swept, and fatal
when it is points: the press would drop the very layer whose points the sweep was about to
gather. So the band now leaves the selection alone while it is drawn and settles it on
release — which also keeps the boxes on screen while the user is aiming, and is the better
behaviour on its own terms.

**A drag moves each point in its own layer's space.** The pointer's travel is a *screen*
delta; each mask is written in its layer's coordinates. The delta is therefore mapped through
each layer's own inverse (two points on the picture, subtracted, so scale and rotation are
undone exactly) before it is added — so a selection spanning two layers with different
transforms still moves together on screen. One `set_mask` per mask, which is one undo step per
mask, the same rule the razor follows for a multi-layer cut.

**No live preview while points are dragged.** The dragged points follow the pointer as drawn
marks, and the picture catches up on release. The preview path (K-183) patches one layer's
*transform* into a clone of the document; a mask path has no room in it, and inventing one for
a gesture this short is not worth a second preview shape. The marks moving is enough feedback
to aim with.

**Handles are not points.** A vertex's two bezier handles cannot be dragged yet, and neither
can a mask path be keyframed. Both are in TODO.md. This decision is about the *positions* of
the points, which is the half that makes a drawn mask correctable.

**K-225 · DECIDED · The Type tool makes and edits text layers on the picture, and the
toolbar grows the options the drawing tools use.** From the owner (2026-07-31): "Now add
typing. These should also be their own layer type… along with this there should be the
options for fills/border colour pickers and pixel widths etc just like AE."

**Text is already its own layer kind**, so this is the interface catching up with the
engine: `LayerKind::Text` holds a document (one styled run, docs/03 §9.1), the renderer
rasterises it, and the only way to make one was a menu item that dropped "Text" in the middle
of the composition. The tool puts it where the user points.

**One click, two meanings.** On empty picture the tool makes a text layer *where the pointer
is* and starts typing into it; on an existing text layer it edits that one. Clicking
somewhere else ends the edit and begins the next, which is After Effects' behaviour and the
only one that lets a caption be typed without a trip to the Timeline.

**A stray click leaves nothing behind.** A layer this tool made that ends its edit with no
text is deleted. An empty line renders nothing, so what a stray click would otherwise leave
is an invisible row in the Timeline — the same reasoning as the bridge refusing a mask of one
vertex.

**The document is written once, and the picture keeps up through a preview.** Every document
edit is an undo step, so a `set_text` per keystroke would make undo walk back through a
sentence one letter at a time. So typing sends `render_frame_with_text_preview` — a third
member of K-183's preview family, beside the effects and transform ones, patching a document
into a *clone* the same way — and the layer is written when the edit ends. One typing
session, one undo step.

**The caret is drawn; the text is the engine's.** The keyboard is a real Flutter text field,
so arrows, selection, backspace, paste and IME all work — but it is invisible, because the
text the user should see is the engine's own rendering. What is drawn is the caret, placed by
the same rough estimate of a line's width the bridge uses to anchor a new text layer (half
the point size per character). Being wrong the same way on both sides is what keeps the caret
and the picture agreeing about where a line ends; the true advance widths live in the
rasteriser and are not on the bridge. When they are, both sums change together.

**A new layer's anchor is recentred when the edit ends, pan-behind.** It starts on the left
end of an empty line, because an empty line has no middle; once there is a line, the anchor
moves to its middle and Position compensates by exactly the amount that keeps the words where
they were (K-220's sum). So a typed layer scales and turns about itself without ever having
appeared to move.

**Vertical type is not built.** `lumit-text` lays out one horizontal line; the member stays
on the strip, marked unbuilt like every other, and says so if it is clicked.

**The toolbar grows a tool options area**, where After Effects has one: the fill swatch and
the point size while a type tool is armed, the fill and stroke swatches and the stroke width
while a drawing tool is. Fill and size are live — they set what the next text layer is made
with. **Stroke and stroke width are drawn disabled**, because nothing in the engine strokes
anything: a shape layer's outline and a paint stroke are both engine features that do not
exist. They are shown rather than hidden for the same reason unbuilt tools are shown (K-216):
the tool set is the specified one, and a control that is visibly not working yet says more
than a gap does.

**And a bug the Type tool found: arming a tool did not rebuild the Viewer's overlays.** The
panel listened to the tool only to change the *pointer*, handing the whole stage in as a
cached child — so every tool layer under it stayed armed for whichever tool was in hand when
the panel last rebuilt, and only happened to work because a tool is usually picked before
anything else redraws. The stage is now built inside the listener.

**K-226 · DECIDED · The tools that draw wear a drawn pointer: the eyedropper's crosshair
badged with the tool's own icon, a brush ring for the painting tools, and an I-beam for
type.** From the owner (2026-07-31): "for the shape and pen tools, they should use the same
cursor as the dropper has? And maybe have the icon for the shape or pen in use just slightly
offset to the bottom right of the cursor… For text I think it should use a text select type
cursor and rotate this depending on if the text is horizontal or vertical… make sure the
different brush options all have correct cursor icons for their function."

**Shape and Pen: crosshair plus badge.** The crosshair is the eyedropper's — the pointer that
means *this exact pixel* — because that is exactly what the first corner of a shape or the
first point of a path is. The tool's own icon sits down and to the right of it, out of the
way of the shape being dragged out, drawn twice: a halo copy a pixel across, then the ink one,
so it is legible on a white picture and a black one alike. This is After Effects' own badging
and it is what makes five shape tools that share a gesture tell each other apart.

**The painting tools get a ring, not a crosshair.** A brush is not a point, it is a *width*,
so its pointer is a circle the size of the stroke it would leave, with a dot at the centre for
where that stroke starts. The ring is drawn from the toolbar's stroke width through the
current magnification — a picture-pixel width shown at picture scale — clamped so a hairline
still has a visible pointer and a very wide brush does not fill the window. The badge under it
says which of brush, clone stamp and eraser is in hand. **Nothing is painted**: the layer
exists to wear the pointer and to say what is missing when clicked, since the engine has no
paint at all (docs/TODO.md).

**Type: the I-beam, turned when the type is.** Horizontal type takes the system's own I-beam
— every platform ships one and everybody already reads it as "you can type here". No platform
ships a *sideways* one, so vertical type has one drawn: the same beam a quarter turn round, so
the pointer says which way the line will run before a single letter is typed.

**And the click is where the words start.** A new text layer's anchor now begins at the left
end of its line's baseline rather than in the middle of an empty box, so what is typed runs to
the right of the pointer and sits on it instead of straddling it — the same relationship the
caret is drawn with. The anchor is still recentred on the finished line pan-behind (K-225), so
nothing appears to move.

**Why drawn rather than chosen.** A system cursor is a small fixed picture from the list the
platform ships, and none of these are on it. The three tools that already needed this —
Rotation, Anchor point and Razor — hide the system pointer over the picture and paint their
own; these do the same, through one shared pointer widget rather than a fourth private
painter.

**K-228 · DECIDED · A tool that is not built cannot be armed. It stays on the strip, drawn
disabled.** From the owner (2026-07-31): "I think we'd be better off just disabling that in the
toolbar for now… it'd be better to see what we still need to add rather than removing it and
forgetting about the code."

**Which is a correction to K-216's honesty rule, not a reversal of it.** K-216 put every
specified tool on the strip and had the unbuilt ones say so in a tooltip. That was right about
*showing* them and wrong about *arming* them: a tool you can pick that then does nothing reads
as a broken application, and the tooltip is only read by someone who already suspected. Shown,
disabled and labelled is the honest version of the same idea — the strip still teaches the
shape of the application, and nothing in it lies.

**Disabled means disabled everywhere.** `ToolsState.select` refuses an unbuilt tool, so the
button, the flyout row and the keyboard chord all decline together; a group's chord cycles only
its built members; and a group with nothing built in it takes no click at all. The state is the
gate rather than the widget, because there are three ways in and only one of them is a button.

**The flag is `ToolMode.ready`, which already existed.** No second list to keep in step: a tool
becomes armable the moment its behaviour lands, in the same commit, and the test that pins the
built set (K-223) now pins what is *arming-able* too. This is also what keeps the two branches
straight — paint is built on the engine branch and not on this one, and each branch's toolbar
follows its own flags without either being edited to suit the other.

**What is disabled today:** the Roto tools and the Puppet pins (both engine features of their
own size, at the owner's direction), the Pen's four editing siblings, and vertical type.

**K-229 · DECIDED · The camera tools move the composition's active camera by dragging on the
picture.** From the owner (2026-07-31): "Camera, make this like after effects implementation
along with any gizmo's etc and custom cursors if necessary."

**What Lumit's camera is, which decides what the tools can be.** A camera layer holds a
position, three rotations and a *zoom* — the focal distance in composition pixels. The plane at
the camera's own position renders 1:1 and centred, so **the position is the point the camera is
looking at**, and the eye sits `zoom` behind it along the camera's forward axis. Everything
follows:

* **Orbit** changes the rotations and leaves the position alone. Because the eye is derived
  from both, it swings round the point being looked at — a true orbit, with no separate pivot
  to store.
* **Track** slides the position along the camera's own right and up axes, so the eye travels
  with it and the picture slides under the pointer, the same sense the Hand tool has.
* **Dolly** slides the position along the forward axis, moving the eye and what it looks at
  together, in or out of the scene, by a fraction of the distance already in hand — so a dolly
  across a wide shot covers ground and one in a close-up creeps.

**The axes are built the compositor's way** (`Ry · Rx · Rz`, lumit-gpu's `camera_matrix`). This
is the one piece of frontend arithmetic that has to agree with the renderer exactly: a tool
that moved the camera along a different set of axes would send it sideways when asked for
forward. It is unit-tested against hand-computed cases rather than by dragging.

**Dragging up lifts the camera over the top** — which means tilting it to look *down*, a
negative x rotation in a frame where +y is down the screen. Getting that backwards is the
classic inverted orbit, so it has its own test. The pitch is clamped just short of the poles
rather than wrapped: past straight down the next pixel flips the picture over.

**The gizmo is the pivot.** While a camera tool is armed the point the camera is looking at is
marked, and while orbiting the circle it swings round is drawn faintly. That point projects to
the middle of the frame by construction, which is worth saying plainly: what the camera looks
at is the middle of the picture.

**They act on the active camera, not the selection.** The topmost visible camera layer whose
span covers the playhead — the one the renderer looks through — because the camera is what you
are looking *through* rather than a thing you have picked. With no camera at all the tool says
so. A camera whose placement is keyframed is left alone, the same rule the layer gizmo follows:
there is no single value for a drag to add to.

**No point of interest, and no unified camera tool.** After Effects' two-node camera has a
separate point of interest, and its Unified Camera tool switches between the three by mouse
button. Both are in TODO.md; neither changes the three tools above.

**K-230 · DECIDED · What the toolbar's tools were getting wrong, in one pass.** From the owner
(2026-07-31), on using the tools for the first time. Every item here is a correction to K-216 →
K-229 rather than a new capability, so they are recorded together.

**One gesture is one undo step.** Dragging a layer on the picture wrote Position x and Position
y as two ops, so `Ctrl+Z` put the layer back along one axis and left it half moved; scaling did
the same. Both write through `set_transforms` now — the batch op the Anchor point tool already
used — so a drag is one step. The Type tool was worse: making a layer was three ops (a layer
saying "Text" in the middle of the composition, an empty line written into it, a move to the
click) and finishing the edit was two more, so undo walked back through states nobody had ever
seen. Making a text layer is now one op (`add_text_layer_at`) and finishing a typing session is
one more (`set_text_placed`), so the first undo takes back the words and the very next removes
the layer. **The rule, stated once: an op is what the user would call an action, and a gesture
that writes several properties writes them in one `Op::Batch`.**

**A drag takes what is selected, whatever is on top of it.** A press inside an already-selected
layer moves *that* layer, even where a higher one overlaps the same spot; only a plain click
still takes the topmost, because that is how a layer underneath gets chosen with the mouse at
all. Without the rule, a layer chosen in the Timeline could not be dragged wherever anything
covered it — the press silently swapped the selection and moved the wrong thing.

**Windows ships neither a grab nor a magnifier, so the Hand and the Zoom draw their own.**
Flutter accepts `grab`, `grabbing`, `zoomIn` and `zoomOut`; the Windows embedder's table has
none of them and quietly answers with the ordinary arrow, which is why arming those two tools
looked like arming nothing. They join the Rotation, Anchor point and Razor tools in hiding the
system pointer and painting their own (K-219, K-226): an open hand that closes while it pans,
and a magnifier whose sign follows the Alt key. The Razor gives up its crosshair over the
*picture* — it cuts in the Timeline, and a precise pointer promised a gesture the Viewer does
not have — and its Timeline blade gains a marked hot spot, because the point where a leaning
blade actually bites is otherwise an unmarked corner of a drawing.

**The Rotation pointer settles on eight positions** — the four edges and four corners of the
layer's own box — rather than leaning by a continuously varying angle. The continuum was true
to the geometry and worse to read: a mark that is never twice the same shape is one the eye
re-reads every time. Eight shapes are eight things to recognise.

**A preview in flight is drawn in flight.** The wireframe is built from the document, so while
a turn was being dragged the picture rotated under a box that sat still until the button came
up. The angle in flight is published on the interface state and the layer that draws the boxes
reads it. The same rule covers the drawing tools' own pointers: a `MouseRegion` stops reporting
a hovering pointer the moment a button goes down, so every drawn pointer follows the *drag* as
well, and the Pen previews its next edge as the curve the placed vertex's handles make it,
not as a straight line that changes shape once the point lands.

**Zooming in must not cost the window.** The transparency board behind the picture was a widget
the size of the *picture*: at 800 % on an HD composition that is 15360 pixels across, and an
8-pixel grid over it is half a million rectangles a paint for the few thousand on screen. It is
bounded by the panel now, clipped to the picture and pinned to the picture's own grid, so it
costs the same at every magnification.

**Magnification is not resolution.** The scale reported to the engine follows the *panel* — a
Viewer docked small is cheap, which is the point of reporting anything — and not the zoom
inside it. Zooming out used to lower the preview resolution, which threw away every cached
frame and made the picture coarser for a gesture that only meant "let me see more of it".
Zooming in cannot raise it either: above composition resolution there is nothing to render.

**Panning, and hovering with a camera tool, must ask the engine nothing.** Both rebuilt their
panel on every movement of the pointer, and both re-read the document to do it — the Viewer
asked for the composition's settings, its size and every layer's source item; the camera layer
re-found the active camera, which reads a focal distance and a frame rate across the bridge.
Both answers are held until an edit lands. Budgets in `bridge_call_budget_test.dart`.

**The camera tools hold the pointer still while they drag.** Moving a camera is a gesture with
no place — nothing on the picture is being aimed at — so a pointer that wanders out of the
Viewer and finally into the corner of the screen is a drag that ends before the user does. The
pointer is pinned where it was pressed and only its movement is read (`freeze_cursor` /
`restore_frozen_cursor`, Windows-only; elsewhere the drag reads movement between events exactly
as before). Putting the pointer back is itself a movement, so the drag measures against the
anchor rather than against the last event, and the put-back reads as no movement at all.

**A text layer is as big as its line.** Text had no measured bounds on the frontend and fell
back to the composition's size, so a click with the Type tool drew a box the size of the frame
round twelve-pixel text. It measures the point size tall and the engine's own width estimate
wide; an empty line keeps one character's worth so a layer waiting to be typed into is still
visible and still says what size it will be set at.

**Escape ends a typing session, and so does `Ctrl+Z`.** The text field swallowed the undo
chord, so undo appeared to have stopped working while typing. The edit is written first and the
chord handed on, so there is one undo path in the application rather than two.

**The toolbar is 30px tall, and keeps its 44px buttons across.** 15-DESIGN §7.2's hit extent is
kept along the row — which is what the strip is read by — and given up down the page: the strip
runs the full width of the window, so a 44px band of mostly empty chrome is height taken from
the panels underneath for nothing.

**The snapping switch is removed.** Nothing in the application read it (docs/07 §1.7 said so
outright). A toggle that governs nothing is worse than a missing one: it makes the reader doubt
what snapping *is* here rather than what it is set to. It returns with the snapping it governs.

**K-231 · DECIDED · The second pass over the tools, from using them (2026-07-31).** Follows
K-230 in the same shape: corrections found by the owner in a working build, recorded together.

**A layer switched off is not on the picture at all.** It gets no wireframe and takes no click,
and a click over it falls through to whatever is underneath. Switching a layer's eye off is how
you get it out of the way; a box round something invisible, and a click that selected it, put
it straight back in the way.

**A scale in flight is drawn in flight, and a scale may be negative.** The wireframe follows a
scale drag exactly as K-230 made it follow a turn — one shared "the box as the gesture in
flight would have it" in the gizmo, which the rotation knob, the scale handles and the Rotation
tool all pass through. And the layer↔screen map no longer floors the factor just above zero: a
handle dragged past the anchor turns the layer over, which is how every editor mirrors a layer.
Only *zero* is barred, because the inverse map divides by it; the sign is kept.

**Drawing reads the copy in hand; only editing checks.** The read model (K-184) asked the
engine whether the document had moved before answering — once per frame while a frame was being
built, and *every time* outside one, which is where every pointer handler runs. So a tool that
redraws as the mouse moves asked that question at the rate a mouse reports, and the answer was
always no: moving a mouse changes no document. The paint path now reads `heldLayers` /
`heldRevision`, which ask nothing. That is safe precisely because a change refreshes the model
and notifies, and everything that draws is listening — but it means **a panel that commits an
edit must refresh the model itself**, which the Timeline and Effect controls already did and
the Viewer now does too. Checking-as-you-draw was covering for that, invisibly.

**The pointer a tool draws follows the mouse whichever button is held.** Recorded under K-230's
pointer rules in docs/07 §2.3.3, and worth naming here for the shape of the bug: `MouseRegion`
reports *hover*, which stops the moment any button goes down — including buttons the tool does
not answer to at all. So right-clicking froze the drawn pointer where it was pressed until the
button came up. The position comes from pointer *move* events now, through one shared
`DrawnPointerRegion` rather than seven copies of the tracking.

**A drawn pointer is one frame behind, and that is inherent.** The system pointer is composited
by the operating system; ours is painted by the application, so it arrives with the frame. The
cost is kept to a repaint rather than a rebuild, and a tool that can wear a system pointer
still does — which is why only the tools with no platform cursor draw their own.

**K-233 · DECIDED · The third pass over the tools, from using them (2026-07-31).** Follows
K-230 and K-231. (K-232 is the cache bar's own entry.)

**The Anchor point tool puts the pivot where you point.** It was a *nudge*: the drag was
measured from the press and added to the anchor the layer already had, so grabbing anywhere and
pushing moved the pivot by that much. That makes placing a pivot a matter of aim-then-correct —
you can push it towards somewhere, never put it anywhere. A **click** now places it, and a drag
keeps it under the pointer the whole way. Shift still locks to one screen axis, measured from
the press; Ctrl (Cmd) still snaps to the layer's own key points. Shift+click stays a *selection*
gesture and moves nothing: a click that both changed the selection and moved that layer's pivot
would be two edits nobody asked for at once.

**The Pen tells you when a click would close the path.** The closing tolerance is a fixed number
of screen pixels and nothing said how near "near enough" was — you clicked, and either the path
closed or it grew a point you did not want. The first vertex grows a ring and the pointer wears
a smaller one, so the question's two halves are both answered: *which* point closes it, and
whether the click about to be made is that one.

**The Pen previews the edge it is actually aiming at.** While the next vertex's handles are
being pulled out, that vertex is already placed — it is where the press landed — so the
preview runs to *there* and bends into it by the handle facing back along the path, which is
the mirror of the one under the pointer (or the vertex itself, when Alt has broken the pair).

**`Ctrl+Z` takes back one point while a path is being built.** The one place in the application
where undo means something narrower than "undo the last edit", and it has to be: the points are
not in the document — the path is applied in one op when it closes — so an undo pressed
mid-path sailed straight past every point placed and undid whatever the user had done *before*
picking up the Pen. It goes back to the document's own undo the moment the path is empty.

**A text box grows with the words.** The document holds the old line until the edit ends
(K-230's one-op rule), so a box measured from the document did not grow as the words did. What
is being typed is published for the boxes to measure, the same way a turn in flight is (K-230).

**The camera tools' chatter, finally.** K-230 cached the active camera and K-231 gave the paint
path an *unchecked* read of the model, but the camera layer's own cache key was still the
checking one — so it asked the engine for the document's revision on every frame of every mouse
movement, which is what it had been reported doing twice. It reads the held revision now.

**And the test that should have caught that could not see it.** `bridge_call_budget_test.dart`
pumped frames with `tester.pump()`, which does not advance the clock — so every frame carried
the same timestamp, the read model's own "once per frame" grouping saw *one* frame for a whole
gesture, and the budget measured zero while the running application was making a call per
frame. The budgets pump with time on the clock now. **A performance test that cannot reproduce
the conditions it is guarding is worse than no test: it certifies the bug.**
