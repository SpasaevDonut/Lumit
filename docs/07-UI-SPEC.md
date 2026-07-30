# Lumit UI specification

**Status: canonical.** This document specifies the structure and behaviour of every panel in
Lumit's interface. Terminology follows [01-GLOSSARY.md](01-GLOSSARY.md) exactly; locked
decisions in [02-DECISIONS.md](02-DECISIONS.md) are assumed. All colour, type, spacing, and
iconography specifics are deferred to [15-DESIGN.md](15-DESIGN.md) — this document says *what
exists and how it behaves*, never what it looks like.

RFC-2119 keywords (MUST, SHOULD, MAY) are used with their standard meanings.

**Implementation status (2026-07-24).** This is the **target** UI specification; the shipping
Flutter frontend (`flutter_ui/`) implements a subset of it. Broadly built: the docking shell,
workspaces, Project panel (relink/missing-footage), Timeline lanes + keyframes, the graph
editor (all lenses), Scopes, Hierarchy, Settings (General/Appearance/Interface/Performance/
Export), the command palette's Commands category, and a single-export dialogue. **Not yet
built / regressions** include: the whole **Audio panel** (§10), most of the **Viewer bar**
(§2.2 - magnification, channel view, guides, ROI, transparency grid, colour-management and
degradation indicators), the four **workspace presets** (§1.6), the **first-run setup** screen
(§13.1), the **transform gizmo / motion paths** (§2.3-§2.4, gated on comp rendering), and the
**Keymap / Colour-management / Preview-mode / CUDA / Plugins** settings pages (§15). The
concrete gaps and Flutter parity regressions are tracked in [TODO.md](TODO.md); read the
sections below as the design, not a claim of current state.

The base arrangement is deliberately After Effects-shaped, because the target audience arrives
from AE: Viewer in the centre, Project panel on the left, Effect Controls / Effects & Presets /
Scopes on the right, Timeline across the bottom. Everything beyond that shape is movable —
the interface is truly the user's.

---

## 1. Application shell and docking

> **v1 status (K-074, K-086, refined by owner request):** the shell is a tiling dock
> (egui_tiles). Panels stacked together form a tab group with a title tab per panel,
> draggable to re-arrange the workspace; a panel that sits alone renders as a bare pane with
> no tab bar — the Viewer's look on every solo panel — so the default workspace shows tabs
> only on the left Project/effects stack. A tabbed panel's pop-out button lifts it into its
> own OS window, and dragging its tab moves it; a bare pane, having no tab bar to carry
> either, gets both a different way — right-click anywhere empty in it for the same pop-out,
> and a small grip in its top-right corner to drag it (the Timeline's own comp-tab-strip
> right-click pop-out is this same mechanism, not a special case). Closing a popped-out
> window docks the panel back. This delivers the substance of the section below — tabs,
> drag-to-dock, re-arrangeable layouts, pop-out — though the exact five-drop-zone visuals and
> in-window frame trees described below are still approximated by egui_tiles' own
> affordances.

### 1.1 Frames, groups, tabs

- The main window is divided into a tree of **frames**. Each frame holds one **panel group**;
  a group is a tabbed set of panels with exactly one visible at a time.
- Every panel MUST carry a tab with its name. Dragging a tab MUST begin a docking drag.
  Dragging the group's tab-bar background moves the whole group.
- Each panel MUST have a panel menu (top-right of the group) containing panel-specific
  options plus the common entries: Undock (float), Close, Maximise, and Help for this panel.
- Pressing `` ` `` (backtick) with the pointer over a panel MUST toggle that panel between
  its docked size and maximised to the full window (AE's tilde behaviour; backtick and tilde
  share a key on the layouts our audience uses).

### 1.2 Drop zones

While a panel drag is active, the target frame MUST display five drop zones:

| Zone | Result |
|---|---|
| Centre | Join the target group as a new tab |
| Top / bottom / left / right edge of a group | Split the frame; insert the panel adjacent; siblings resize proportionally |
| Window edges | Dock against the whole window (full-height/full-width split) |

Docking MUST never overlap panels inside a window; only floating windows overlap. Drop zones
MUST be rendered as explicit highlighted regions during the drag (no invisible targets), and
the pending layout SHOULD be previewed as an outline before release.

### 1.3 Floating windows

- Dropping a panel outside any drop zone, choosing Undock, or holding `Ctrl` during the drop
  MUST create a floating window. Floating windows are true OS windows (egui multi-viewport)
  and MUST be placeable on any monitor.
- A floating window hosts its own frame tree: users MAY dock several panels into one floating
  window and split it like the main window.
- Closing a floating window closes its panels (recoverable from the Window menu, which lists
  every panel type; opening an already-open panel focuses it instead).

### 1.4 Workspaces

A **workspace** is a named, saveable arrangement of panels (glossary §7).

- Lumit MUST ship four workspace presets: **Edit**, **Effects**, **Colour**, **Audio**
  (§1.6). Preset workspaces MUST be restorable to their factory layout at any time
  (*Reset workspace*), individually, without touching user workspaces.
- Layout changes MUST persist automatically to the active workspace across sessions.
  *Save as new workspace…* creates a user workspace; user workspaces MAY be renamed,
  reordered, deleted, exported, and imported.
- Workspaces are stored per user in the configuration directory as individual
  human-readable files, so they can be shared (the montage scene shares everything —
  K-065). They are never stored in the project.
- A workspace switcher MUST be visible in the main window chrome (a compact strip of
  workspace names) and in the Window menu; `Alt+Shift+1…9` switches by position.
- Switching workspaces MUST NOT close, reload, or re-evaluate anything — it only
  rearranges panels. Panels open in the old workspace but absent from the new one keep
  their state in memory for the session.

### 1.5 Workspace state versus project state

The AE lesson: a viewer locked to a specific comp is a reference to *project content*, so it
cannot live in a workspace (AE silently drops such locks). Lumit splits state explicitly:

| Lives in the workspace (per user) | Lives in the project (`project.json` session block) |
|---|---|
| Frame tree, panel groups, tab order | Which comps are open, and the active comp |
| Panel sizes, floating window geometry | Viewer-to-item locks (§2.6) |
| Which panel types are open | Per-comp Viewer state: preview resolution, magnification, channel view, transparency grid, guide/ruler visibility |
| Timeline column visibility and widths | Per-comp Timeline state: twirl-down expansion, work area, playhead position, zoom range |
| Toolbar layout | Guides themselves, markers, region of interest |

Opening a project MUST restore the project-side state above regardless of which workspace is
active. A project opened on another machine therefore looks like the same *edit* even though
the panel arrangement is the local user's own.

### 1.6 Shipped workspace presets

Structure only; every preset uses the same panel inventory.

- **Edit** (default): Project panel left (Effect Controls tabbed behind it); Viewer centre;
  right column Effects & Presets above Preview and Audio; Timeline across the full bottom at
  roughly one-third window height.
- **Effects**: Effect Controls promoted to its own left column beside the Project panel;
  Effects & Presets expanded on the right with Scopes tabbed behind; Timeline slightly
  shorter than Edit.
- **Colour**: Scopes given a wide right-hand column showing waveform and vectorscope
  simultaneously (two panels stacked); Effect Controls left; Effects & Presets tabbed away;
  Viewer centre-dominant.
- **Audio**: Audio panel promoted to a tall right column; Timeline taller than Edit with
  audio waveforms expanded by default; Viewer reduced. This is the v1 audio surface — the
  future Composer workspace is specified in [09-AUDIO.md](09-AUDIO.md) and deliberately not
  here.

---

## 2. Viewer

The Viewer displays a comp, a footage item, or a single layer's source. One Viewer exists by
default; users MAY open additional Viewers (Window menu or comp context menu) and place them
anywhere, including other monitors.

### 2.1 Display modes

- **Comp mode** (default): the rendered composite at the playhead.
- **Footage mode**: a project footage item, pre-comp, with its interpretation applied — used
  for source review and setting source in/out before inserting into a Sequence layer.
- **Layer mode**: one layer's source before transform — the surface for slip edits, drawing
  masks on source, and (later) paint/tracking. Layer mode MUST show its own source-time strip
  for slipping a clip or layer under fixed in/out points.

### 2.2 Viewer bar

A single compact bar at the bottom of the Viewer holds, left to right:

1. **Magnification** dropdown: Fit, Fit up to 100%, then 25 / 33.3 / 50 / 100 / 200 / 400 /
   800 %. Magnification is display scaling only; it MUST NOT change render resolution.
   `Ctrl+scroll` zooms about the pointer; `Shift+/` fits.
2. **Preview resolution** dropdown: Full / Half / Third / Quarter / Auto (glossary §5).
   True raster downsampling — Half renders a quarter of the pixels. **Auto** renders only
   the pixels the current magnification can display. The setting is **stored per comp** in
   the project. Preview resolution MUST never affect export.
3. **Channel view**: RGB / Red / Green / Blue / Alpha (alpha as greyscale matte).
4. **Transparency grid** toggle (checkerboard behind transparent pixels instead of the comp
   background colour).
5. **Wireframe/overlay menu**: layer wireframes, motion paths, mask paths, gizmo visibility,
   and a full wireframe display mode (outlines only, no raster) for heavy comps.
6. **Guides menu**: rulers (`Ctrl+R`), guides (drag out of rulers; lock/clear), grid,
   title/action safe overlays, snapping-to-guides toggle.
7. **Region of interest**: drag a rectangle; the engine renders only that region for
   preview. MUST be clearable in one click and MUST never affect export.
8. **Colour management indicator**: the current display transform (e.g. working space →
   display). Read-only badge; clicking opens colour settings. Always visible so "what am I
   looking at" is never ambiguous.
9. **Degradation indicator**: a live badge that appears **only while adaptive degradation is
   active** (K-018), stating what is degraded (e.g. "preview at Half · glow skipped").
   It MUST disappear the moment the full-quality frame lands. Hovering lists the degraded
   steps. Users MUST be able to tell a degraded frame from a final one at a glance.
10. **Background colour** swatch: per-comp background (project state), plus quick black /
    grey / custom.
11. **Current time** readout in the comp's timecode; click to type a time.

The bar MUST remain one row; overflow collapses from the right into a chevron menu.

### 2.3 Transform gizmo

- Selecting a visual layer shows a combined gizmo in comp space: move (body drag), scale
  (corner/edge handles, `Shift` for uniform), rotate (just outside corners), and anchor
  point (distinct centre handle, `Y` tool to drag anchor without moving the layer).
- The gizmo MUST operate in the layer's transformed space (including parents) and respect
  3D orientation when the layer is 3D.
- Snapping while dragging: layer edges/centres to comp edges/centres, guides, grid, and
  other layers' anchors/edges. Snapping is on by default; holding `Ctrl` suspends it during
  a drag. Snap matches MUST be indicated visually at the moment of snap.

### 2.4 Motion paths

Position animation MUST draw its motion path in the Viewer for selected layers: keyframe
boxes, spatial bezier handles (editable in place), and per-frame dots so dot spacing shows
speed. Path editing writes to the same keyframe data as the graph editor.

### 2.5 Playback surface

The Viewer shows the render pipeline's current frame; everything about playback belongs to
the transport (§11) and cache system. During scrubs the Viewer shows latest-wins progressive
results (K-017); stale frames MUST never be presented as current without the degradation
indicator lit.

### 2.6 Viewer locks

Each Viewer MAY be locked to a specific item (padlock on its tab). A locked Viewer MUST NOT
switch items when the user opens another comp — this is how "comp here, precomp there"
two-Viewer workflows survive. Locks are project state (§1.5).

---

## 3. Project panel

The library of assets: footage items, audio items, comps, folders.

### 3.1 Structure

- A folder tree with drag-to-reorganise. Sorting per column; columns: name, type,
  dimensions, frame rate, duration, colour space tag, file path. Column set is configurable
  (workspace state).
- A persistent **search field** filters the tree live (name, type, extension). `Ctrl+F`
  focuses it when the panel has focus.
- Selecting an item shows a header readout: thumbnail, dimensions, fps, duration, codec,
  colour space tag, alpha interpretation.
- **Hover-scrub thumbnails**: hovering a footage item's thumbnail and moving horizontally
  scrubs a low-resolution preview. This MUST be served from proxy/thumbnail data only and
  MUST NOT trigger full decodes. Double-click opens the item in a Viewer (footage mode).
  **Shipped (owner request, 2026-07-28):** selection lands on the pointer's *down* stroke,
  and a click on the lone selected row opens the in-place rename immediately — so a
  double-click is "select, then rename" in one motion, on any row. Double-clicking empty
  panel space imports. The footage-Viewer double-click above is deferred until footage
  mode exists; comps front via the Timeline's comp tabs.
- Drag an item into a comp's Timeline or Viewer to create a layer; drag onto the
  **New comp** button to create a comp matching the footage (dimensions, fps, duration).
  **Shipped:** rows multi-select — `Ctrl`/`Cmd`-click adds or removes one, `Shift`-click takes
  the run between the last click and this one, a plain click goes back to one — and a drag from
  any selected row carries the whole selection, so several clips reach the Timeline, or the
  **New composition** button, in one gesture. A drop on that button opens the composition
  settings dialogue (§13.3) prefilled from the media: the size and rate of the first item that
  has a picture, and the length of the longest, because a comp shorter than what was dropped
  into it would clip the very thing that was asked for. Pressing Create makes the comp and
  places every dropped item in it as a layer.

### 3.2 Interpretation dialogue

Per footage item (context menu → *Interpret footage…*), stored in the project, never
touching the file (K-024):

- **Frame rate**: use file rate, or override to an exact rate (the 240 → 60 fps workflow is
  first-class; common capture rates offered as one-click choices).
- **Alpha**: ignore / straight / premultiplied (with matte colour), plus a *guess* action.
- **Colour space tag**: the footage's colour space for conversion into the working space.
- **Loop**: loop count for stills/sequences and short loops.
- **Fields/pulldown**: deliberately out of scope for v1 (gaming footage is progressive);
  the dialogue reserves space for it.

### 3.3 Proxies and relinking

- Each footage item shows a **proxy badge** when a proxy exists (glossary §5): states are
  *none / generating (progress) / ready / stale*. A global proxy toggle in the panel header
  switches all previews between proxy and original.
- **Missing footage** shows a distinct badge and renders as a placeholder slate in comps
  (never a crash, never a silent black). The **relink flow**: *Relink…* opens a file picker;
  on relinking one item, Lumit MUST scan the chosen folder for the project's other missing
  items by filename and offer to batch-relink the matches. A *Find missing footage* search
  filter lists all missing items in one view.
  **Shipped:** `MediaStatus::Missing` is its own state, distinct from an unreadable file —
  the project row wears a crossed-link glyph in the warning tint, the info header reads
  "missing" with a *Relink…* button, and the layer renders **generated colour bars**
  (`lumit_media::slate`, drawn at comp size, never a bundled image) in preview *and* export,
  so the mistake cannot hide in a delivered file (K-031). Relinking one item batch-relinks
  every other missing item whose name is found beside the chosen file, in a single undo step,
  each rebased relative and re-fingerprinted (K-173). **Find missing footage** is a toggle
  beside the search box — shown only while something *is* missing, with a count — and a
  right-click entry on any footage row; it narrows *with* the search text rather than
  replacing it, and unlike the plain search it is never widened by a folder whose own name
  matches, so every visible row is something to fix. An empty result reads "Every file is
  where the project expects it" rather than an error (§13's no-punishment rule). Still to
  build: a dedicated slate for a file that is present but **unreadable** — that state shows
  the row's "unreadable" note and no picture.

---

## 4. Timeline

One Timeline panel; one tab per open comp. Left: the layer outline. Right: time ruler and
lane area. The divider is draggable.

### 4.1 Time ruler region

Top to bottom: **markers ribbon**, **time ruler**, **work area bar**, **cache bar**, then
layer lanes.

- **Markers ribbon**: comp markers (point or span) with labels; double-click creates one;
  drag to move; markers snap. **Beat markers** (generated via the Audio panel, §12) render
  in the same ribbon, visually distinct, and behave as first-class snap targets. Layer
  markers render on the layer's own row.
- **Work area**: `B` and `N` set start/end at the playhead; drag the ends; double-click the
  bar to reset to the full comp. Work area is the preview range and default export range,
  and playback **loops** it (§10's default loop mode): reaching its end resumes from its
  start. On the ruler it occupies the **lower half** only, so the ticks and their labels
  keep the upper half; over the lane area the wash outside it is drawn both under the rows
  and again, lightly, over the layer bars — under them alone it was invisible along every
  row that had a layer in it (K-207).
  A comp that has never had one set **reads as the whole comp** (K-203) — the engine's
  "not narrowed" is null, but the interface has no such state, and a bar with no ends is
  a bar nobody can take hold of. Clearing the work area widens it back to the comp.
- **Cache bar**: a thin stripe showing cached frames per tier — VRAM, RAM, and disk caches
  as three distinguishable states (visual treatment in [15-DESIGN.md](15-DESIGN.md)).
  The bar MUST update live as background rendering fills the cache (K-016).

**Shipped header arrangement (K-188).** The comp tabs span the panel; each tab is an
*open* comp — fronting a comp opens its tab, its × closes only the tab, and closing the
fronted tab fronts its nearest neighbour. Below them the outline carries two header rows
of its own: the **toolbar** (the playhead as `HH:MM:SS:FF` timecode plus a zero-based
frame readout `f72`, the layer search, the master motion-blur button, the shy filter, the
Lane and Graph view buttons, and a ⋯ menu with the layer / razor / work-area / marker /
beat commands) and the **column-group header** (§4.2). The lane side gives those two
rows' height to a taller, labelled time ruler — a bigger playhead grab — with the cache
bar tucked under it. Markers currently draw on the ruler itself; the separate ribbon,
double-click-to-create and marker dragging are still to come.

### 4.2 Layer outline columns

Default column order, all reorderable and hideable per workspace:

**Opening a composition (K-191).** Double-clicking a comp in the Project panel opens it in
the Timeline, which is what a double-click means everywhere; a comp is therefore renamed
from its row menu (**Rename**) or its settings dialogue rather than by a second click on
the row — every other item kind still renames on that second click. Dropping footage on a
Timeline with nothing open raises the **New composition** dialogue, opened on the media's
own size, rate and length, and the dropped items land in the finished comp as layers.

1. **Index** (render order; bottom layer renders first).
2. **Name / source toggle**: click the column header to flip between the user-given layer
   name and the source name. Rename with `Enter` or double-click.
3. **Switches** (glossary §2): visible, audible, solo, lock, shy, quality (draft/full),
   motion blur, adjustment, 3D, collapse (Precomp layers). One icon each; the comp-level
   shy filter button lives in the Timeline header. `Alt`-click a switch applies it
   exclusively (solo-style) where that makes sense (visible, solo).
4. **Blend mode** dropdown.
5. **Matte** dropdown + pick-whip: choose any layer in the comp as this layer's matte
   (AE 2023 semantics — glossary §6), with alpha/luma and invert toggles. One matte layer
   MAY serve many layers. The menu offers only layers that *have* a picture to gate with —
   never a camera, an audio-only clip, or the layer itself (K-194). Layer-valued **effect
   parameters** (a depth map, a displacement source) are filtered the same way.
6. **Parent** dropdown + pick-whip.
7. Optional columns: in, out, duration, stretch.

**Shipped arrangement (K-188, superseding K-168's):** the columns sit in FOUR groups,
left to right — 1 visibility · audio · solo · lock · shy; 2 twirl · label-colour chip ·
layer number · name; 3 flow-or-collapse · fx bypass · motion blur · 3D; 4 matte · blend ·
parent (dropdowns; the pick-whips are a follow-up). **Dragging a group's header moves the
whole group**, which is how the column order is changed, and **dragging the seam after a
group resizes it** (K-192) — every other group keeps its width, so the outline grows or
shrinks by what the drag moved, and what sits inside a group grows with it: the fold-out's
value cells span the render group, and the compose group's three pickers share theirs. The
header icons are indicators only, and the switches live on the rows. Visibility and audio swap glyph when off (closed
eye, muted speaker) rather than only dimming. **Shy** is a real switch on the layer: it
hides the row from this list while the toolbar's shy filter is on, and never changes what
renders. **Lock** holds the layer still where the gestures live — bar move/trim, razor,
rename, reorder and delete all refuse — though property-row edits are not yet guarded
(docs/TODO.md). The flow cell awaits per-layer optical flow in the engine; a Precomp
shows collapse there and other kinds leave it empty. Quality and
preserve-underlying-transparency still await their backing machinery (K-168);
hide-per-workspace and the optional in/out/duration columns remain open. Right-clicking a
layer row opens the **layer menu** — duplicate, reorder, delete.

### 4.3 Layer lanes and property twirl-down

- Each layer row twirls open (`click` the caret, or property-reveal shortcuts, §15) into
  **property lanes**: Transform group, Masks, Effects (one group per effect), Audio, and
  Retime when enabled. Property groups nest with indentation. Opening a layer's twirl does
  not auto-open its Transform sub-group — it starts collapsed, so the twirl first shows a
  tidy list of section headings, each in its own subtle full-width bar, and you open only the
  group you want. In Effect Controls (and the Effects group here) an effect's name is a drag
  handle for reordering the stack.
- Each animatable property lane shows: stopwatch (keyframing on/off), value with
  **scrub-drag** and click-to-type numeric entry, expression toggle, and its keyframes as
  diamonds on the lane. Keyframe icons reflect interpolation (hold/linear/bezier), matching
  the graph editor.
- Keyframe interaction on lanes: click to select, box-select, drag to move in time,
  `Alt+drag` a selection's end to scale the group's timing, `Ctrl+click` a lane to add a
  keyframe at that time, right-click for interpolation and *Ease* commands.
- `U` reveals animated properties of selected layers; `UU` reveals all modified properties;
  a third `U` within half a second shuts the layer again (After Effects' own cycle).
  **Shipped (K-199).** The taps are counted in the panel — a multi-tap is a gesture, like a
  double-click — and *which* groups qualify is asked of the engine each time
  (`LayerReference::reveal_groups`), because "holds a keyframe" and "changed from a fresh
  layer" are facts about the document. A reveal starts from the layer shut, so it shows
  exactly what it says rather than adding to what was already open, and a layer with
  nothing to show stays shut rather than opening onto empty headings.

  **Shipped (partial):** the caret on each layer row opens onto the **section headings**, each
  with its own caret, and nothing under them until one is opened — the tidy-list behaviour
  above. Three groups exist, plus the Retime row above them:

  - **Retime**, only on a layer that has been given one with **Ctrl+Alt+T** or
    Composition ▸ Enable Retime (K-197, K-198, K-200): a single
    row, not a group, sitting *above* Transform and outside every group — it decides which
    moment of the source the rest of the fold-out then transforms. Its value is that source
    time in seconds, and it is an ordinary keyframable property: the same stopwatch, the same
    navigator, the same lane diamonds and the same graph lane as Position, with nothing
    Retime-specific attached. Switching it on installs the identity map, so the picture does
    not move; switching it off removes the property rather than flattening it.
  - **Transform**, always: one row per property group with the stopwatch, the ◄ ◆ ► navigator,
    the label, and a scrub-drag/click-to-type value per axis.
  - **Effects**, only when the layer has any: one row per effect, opening onto that effect's
    parameters — the same rows, with the same controls, that the Effect controls panel shows.
  - **Audio**, only when the layer's source actually carries sound (`LayerReference::has_audio`
    probes the container): the layer's **Volume** in dB, keyable like any other property. Every
    layer has a Volume in the model, but on a solid or a title it can never be heard, and a
    control that cannot do anything is worse than no control.

  The rows are one implementation shared with the Effect controls panel
  (`transform_rows_frb.dart`, `effect_param_row_frb.dart`) rather than a second copy, so a
  parameter behaves the same wherever it is shown. A drag stages the value, previews it through
  the engine's patched clone, and commits once on release: one undo step for the gesture. The
  fold-out is worked out once as a list of rows (`layer_fold_frb.dart`) that *both* halves of
  the table walk — the outline drawing each row, the lane side leaving its height — so bars
  cannot drift away from their names. Each property row leads with its keyframe controls —
  the stopwatch, and once animating the ◄ ◆ ► buttons, the ◆ filled exactly while the
  playhead sits on a key — then the name; the value cells all share the span of column
  group 3 (K-188), aligned to both its edges, so the numbers stack into one column wherever
  the groups are dragged. **An animated value stays editable** (K-189): the field shows the
  value under the playhead, and an edit writes the key sitting there — or plants a linear
  one — never flattening the curve. A drag on one is **one undo step**, staged in Dart and
  committed on release (K-192). **Clicking a property's name selects it** (K-196): the
  name, not the whole row, so grabbing a value field or a stopwatch never re-aims the
  graph — though *editing* a value or keying the property selects it too. `Ctrl`/`Cmd`-click
  toggles a property in and out of the selection and `Shift`-click takes the visible run of
  rows between, across layers; every selected property is a coloured curve in the graph
  editor and its label text takes its curve's colour. Every row containing a selected
  property — its group heading, its effect, its layer — marks itself a shade dimmer;
  selecting keyframes on a lane selects their properties the same way. **Keyed rows draw
  their keyframes as diamonds on their lanes**, and dragging empty lane space boxes them up
  for selection (the shared marquee the graph editor also uses); the F9 family and the
  bottom bar's easing buttons act on that selection in either view. **Selection lets go**
  (K-203): closing a fold drops the selection inside it, selecting a layer clears the
  property selection, and a click on empty ground in either half of the table selects
  nothing at all — no layer, no properties, no keys. `U`/`UU`/`UUU` reveal what is
  animated / what has been modified / nothing, on the selected layer or — with nothing
  selected — on every layer in the comp. Still to build here: moving/deleting a whole
  *lane* selection, the Masks group, and the expression toggle.

### 4.4 Sequence layers

A Sequence layer's row renders its clips back-to-back (glossary §2):

- Each clip block shows its source name, a **speed readout** (single percentage for constant
  speed, `100→20%` style for ramps), and thumbnail strips when row height allows.
- **Edit points** between clips are draggable (roll). Dragging a clip body slides it and its
  neighbours' edit points never overlap; clips never overlap by definition.
- **Overrun hatching**: when a clip's Retime requests source beyond the media (glossary §4),
  the affected span renders with a hatched overlay and the boundary frame holds. Overrun
  MUST never move edit points (K-022). Context menu offers *Trim to source end* explicitly.
- **Razor**: with the razor tool (`C`) click a clip to cut it at that time; `Ctrl+Shift+D`
  cuts the selected layer/clip at the playhead. Cutting a Footage layer converts nothing —
  it splits the layer (AE behaviour); cutting inside a Sequence layer creates an edit point.
- Per-clip context menu: frame interpolation mode (nearest / blend / flow), Retime reset,
  reveal in Project panel, replace source (preserves trim and Retime where durations allow).

### 4.5 Snapping

Snapping MUST cover, as sources and targets: edit points, layer in/out points, keyframes,
markers, **beat markers**, the playhead, and work area edges. On by default; a header toggle
plus `Ctrl`-hold to suspend during a drag.

**Shipped (K-190):** the **magnet** in the lane bottom bar, on by default, covering the
one snap that exists so far — a keyframe dragged on its lane lands on a whole frame. With
it off the key may sit *between* frames: the time is quantised to a thousandth of a frame
and built from the comp's exact rate, so it stays rational (docs/14 §2) rather than
becoming a rounded double. The other sources and targets, and `Ctrl`-hold, are still to
build. Snap distance is measured in screen pixels, not
time, so zoom level controls precision. The snapped-to target MUST be indicated at the
moment of capture. Beat-marker snapping is the beat-sync covenant's daily face: dragging an
edit point near a beat marker lands exactly on it.

### 4.6 Navigation, zoom, and scroll

- Plain wheel scrolls vertically. `Shift+wheel` scrolls horizontally. `Ctrl+wheel` zooms
  time about the pointer. The wheel MUST never zoom without a modifier (no scroll hijack).
- `=`/`-` zoom time in/out; `Shift+=` zooms to the work area; `\` toggles between full-comp
  zoom and the previous zoom (AE-compatible).
- Dragging in the ruler scrubs the playhead. Scrubbing previews video always; holding
  `Ctrl` while scrubbing also scrubs audio.
- The playhead MUST stay visible during playback via edge-follow scrolling (page-flip or
  smooth per user setting); the timeline MUST NOT recentre while the user is dragging
  anything.

**Shipped (K-189, K-190):** the outline and lanes scroll vertically as one table — one
linked scroll, the visible thumb on the lane side; in graph view each side scrolls alone
with its own thumb. Each thumb lives in a fixed-width **gutter** down the right of its
half, outside the horizontal scroller so it stays pinned to the viewport edge, and the
outline reserves the same gutter with an undraggable block level with its toolbar and
column header — so the columns never shift as the view changes. The lane bottom bar
carries − / + / Fit time zoom, the magnet, and the horizontal scrollbar. **The wheel
scrolls, dragging never does**: a plain wheel moves the rows, `Shift+wheel` scrolls
sideways, `Ctrl+wheel` zooms time about the pointer, and a drag on empty lane space is the
keyframe marquee. Still to build: `=`/`-`/`\`, and edge-follow during playback.

### 4.7 Editing behaviours

- Layer drag moves in time; vertical drag reorders the stack. `[`/`]` move the selected
  layer's in/out to the playhead; `Alt+[`/`Alt+]` trim in/out at the playhead.

  **Shipped (K-193):** dragging a layer's **bar** moves it in time, and dragging a layer's
  **name** in the outline moves it up or down the stack — drop it on a row and it takes
  that row's place, as one undo step. A locked layer neither drags nor accepts a drop.

  **Both halves move (K-208).** While the drag is in flight the stack shows where the drop
  would land: the lifted layer slides towards its slot and the layers it passes slide the
  other way — in the outline **and** in the lane area at once, from one drag state and one
  set of row heights, so a layer's bar never parts company with its name. In graph view,
  where there are no lanes to move, the outline alone animates. Micro-motion per
  [15-DESIGN.md](15-DESIGN.md) §8: transform only, ≤150ms, and it obeys the animation-level
  setting (at *None* the rows arrive without travelling).
- There is **no ripple mode anywhere** (K-022): nothing moves unless the user moves it.
- Multi-selection supports all of the above; relative offsets are preserved.
- Every destructive-feeling action (razor, delete, retime reset) is a single undo step.

---

## 5. Graph editor

The graph editor is a mode of the Timeline's lane area (toggle button in the Timeline
header, `Shift+F3`): the lanes are replaced by curves for the selected properties. The
outline stays; each property gains an *include in graph* toggle.

In graph mode the outline scrolls **independently** of the curve (UI-8): it keeps its own
vertical scrollbar at the outline's right edge, and a wheel over the curve pans or zooms the
curve (K-079) without ever scrolling the layer list. The ordinary layers view keeps the single
shared scroll of §4.6, where the outline and lanes move together.

### 5.1 Views

- **Value graph**: value against time, editable bezier tangents per keyframe side, following
  the AE-compatible keyframe maths of K-025 (per-side speed in units/second, influence
  0.1–100 % of the interval).
- **Speed graph**: the first derivative against time; handle height edits speed, horizontal
  handle reach edits influence. Value and speed are views of the same data (glossary §3) —
  editing either MUST round-trip losslessly.
- **Acceleration graph**: the second derivative against time (K-070) — the
  distance/velocity/acceleration analogy taken to its third view. Editing it shapes how
  speed itself ramps; like the others it is a view of the one keyframe/segment store and
  round-trips losslessly. Available for every animatable property, not only motion.
- **Auto view** picks the value graph for scalar properties and the speed graph for spatial
  ones; a per-property override menu offers value / speed / acceleration / stacked, with the
  inactive graphs optionally ghosted as a reference.
- **Lens switch**: value / speed / acceleration are selected by glyph buttons in the
  **bottom-right of the graph editor** (K-070), beside the ease-preset footer (§5.3).

### 5.2 Retime's two lenses

A **retimed footage layer** exposes its Retime as a channel in the graph editor's left column,
beside the transform properties (K-075). Sequence layers do **not**; their retiming is edited
inside the sequenced-layer view (K-071, §4.x) — see K-075.

- The **value lens** plots source position against layer/clip time, read as **frame timecode**
  (`HH:MM:SS:FF` in the footage's own timebase — "which source frame is showing here"), not
  seconds (AE-style editing).
- The **speed lens** plots speed percentage against time (Vegas-style semantics). It is
  drawn **in the graph pane, below or instead of the value lens — never overlaid on the
  clip** in the Timeline (K-021). The clip itself only ever shows the read-only speed
  readout and overrun hatching (§4.4).
- **Default lens**: a Vegas-editor preference chooses which lens the Speed channel opens to —
  on, the speed (per-cent) lens; off, the frame-timecode (value) lens (K-075, generalising
  K-021).
- Edits in either lens write retime segments; switching lenses never converts or degrades
  data. Overrun regions render in both lenses as hatched spans beyond the source range.

### 5.3 Editing behaviours

- **Box-select** keys by drag; add with `Shift`. A transform box around a multi-selection
  scales the group in time and value (corner drag; `Ctrl` tapers).
- **Handle editing** with per-side independence; `Alt+drag` breaks tangent continuity;
  a *Continuous* lock keeps in/out speeds equal.
- **Numeric entry**: double-click a keyframe for exact time/value/speed/influence fields.
- **Preset eases**: Ease (`F9`), Ease in (`Shift+F9`), Ease out (`Ctrl+Shift+F9`), hold,
  linear, auto-bezier — buttons along the graph editor footer and in the context menu.
- **Snap-to-beat-markers**: beat markers render as vertical lines in the graph; keyframe
  drags snap to them (same snapping rules as §4.5). This is how speed ramps land on kicks.
- **Auto-zoom fit** (`F`): frame the selected keys, or all keys of shown properties when
  nothing is selected. Manual zoom/pan matches Timeline conventions (§4.6).
- Audio waveforms MAY be ghosted behind curves (toggle) for sync work.

**Shipped (K-196):** the graph editor is one **full-height pane** over the Timeline's own
ruler, zoom and horizontal scroll (`Shift+F3` or the toolbar's Graph toggle), drawing every
selected property as its own coloured curve — a multi-axis property contributes one curve
per axis, and a static property draws as its flat value line. The curves are evaluated by a
Dart port of the engine's cubic (`graph_maths.dart`, pinned to `anim.rs` by
docs/impl/keyframe-eval.md and golden tests), so a paint costs zero bridge calls (K-184).
Landed from the lists above: the **value and speed lenses** (bottom-bar buttons; the speed
lens is the exact derivative, each key an independent in/out dot with one influence handle
each); **per-side tangent handles** with `Alt`-drag breaking and re-joining; **box-select**
with `Shift`/`Ctrl` add; the **preset eases** — F9 / `Shift+F9` / `Ctrl+Shift+F9`, and
Linear / Bezier / Hold buttons in the footer and the key context menu, acting on the lane
selection too; `Ctrl`+click planting a key on the curve under the pointer; **auto-zoom fit**
(`F`, and an Auto fit toggle — off, the wheel pans the value axis and `Alt`+wheel zooms it;
`Ctrl`/`Shift`+wheel stay the Timeline's time bindings); selection-key drags that move a
whole selection in time and value as one write per property; and **keyframe copy/paste**
(`Ctrl+C`/`Ctrl+V`, from the lane view as much as the graph) — full fidelity in-app,
mirrored to the system clipboard as a tab-separated `Lumit <version> Keyframe Data` table
whose per-value easing columns carry the shaping across, and which parses foreign
keyframe tables back in as linear keys. Still to build:
the acceleration lens and auto view (K-070), numeric entry, the transform-box scaling,
snap-to-beat-markers in the graph, waveform ghosting, and the Retime lenses of §5.2.

---

## 6. Effect Controls

Shows the **effect stack** of the selected layer (tab per recently viewed layer, like AE).

- Effects list top-to-bottom in application order. **Drag to reorder**; reordering re-renders
  live.
- Per effect: enable toggle, **solo** (preview this effect's output alone in the stack),
  delete, reset, rename, and a header twirl. `Ctrl+drag` an effect header onto another layer
  copies it.
- **Parameter widgets** by type: sliders with scrub-drag and click-to-type; **colour
  swatches** opening a picker with an eyedropper that samples the Viewer; **angle dials**;
  **point parameters** with a crosshair button that arms a click-in-Viewer pick (and a
  draggable on-Viewer handle while the effect is selected); dropdowns; checkboxes; curves
  where an effect defines one. OFX and LFX parameter types map onto these same widgets
  ([12-PLUGINS.md](12-PLUGINS.md)).
- Every animatable parameter carries the stopwatch and expression toggle inline, mirroring
  the Timeline lanes — the two surfaces edit the same properties.
- **Preset save/load**: save the selected effect (or whole stack) as a preset; presets
  appear in Effects & Presets (§7) and serialise per [10-FILE-FORMAT.md](10-FILE-FORMAT.md)
  for sharing (K-065).

  **Shipped: the panel's layout.** The panel is **one list, not a stack of cards** — the same
  reading as the Timeline's twirl-down (§4.3), which is where the same parameters also appear.
  Each section (Source, Transform, and one per effect) is a **heading bar that twirls**, with a
  hairline under every row beneath it. A section arrives open, so an effect shows its
  parameters the moment it is applied.

  Every row is **two columns, undivided**: the property's name left-aligned in a fixed-width
  name column, its control left-aligned in the rest. They read as columns because they line
  up down the panel, not because anything is drawn between them; the name column also reserves
  its keyframe-controls gutter on rows that cannot animate, so labels align whether or not
  the property is animatable (`flutter_ui/lib/panels/fx_section.dart`).

  The **heading row** runs: twirl, the effect's enable switch, the effect's name — all in the
  name column — then **Reset** at the top of the value column, because that is what it acts
  on. Reset writes every parameter's declared default and so drops any curve on it, as one op
  and therefore one undo step. The stack arrows and the close mark sit hard right, away from
  Reset: removing an effect is not an adjustment to it.

  **Round shape keeps its bubble** (K-092): the same rows, wrapped in floating-card chrome.
  The two shapes differ in chrome, not in layout.

  **Effects with their own display** — Levels' histogram, Curves' spline — are the expected
  exception. `customEffectRows` in `effect_controls_panel_frb.dart` is asked before the panel
  falls back to a row per declared parameter; it is the one place such an effect declares
  itself, so the first one does not become a special case in the middle of the layout. Nothing
  claims a display yet.

  Still to build here: drag-to-reorder by the effect's name, solo, rename, and the expression
  toggle.

### 6.1 The colour picker and the dropper (K-210)

**The picker.** A colour swatch opens the house picker: the **R, G and B numbers across the
top**, each drag-scrubbable and typeable, then the saturation/value square, the hue strip, a
was/now pair and a hex field. Every one of those edits every other — type a number and the
square moves; drag in the square and the numbers follow.

**The numbers are in the scale of the thing being edited**, which is not always 0–255:

- A **display colour** — a theme colour, a solid's swatch — is eight bits a channel, so it
    reads **0–255** and its hex is the same value said another way.
- A **scene-linear colour** in a float working depth (fp16 today, [06-RENDER-PIPELINE.md](06-RENDER-PIPELINE.md) §3.1)
    reads **0–1 for black to white, as decimals**, and a channel may go **above 1** or below 0
    as far as the parameter's own declared range allows — several built-ins declare 0–4 for
    exactly this reason ("linear light: HDR tints are legal"), and one declares −1 for a lift.
    A 0–255 dial cannot reach those values at all, which is what this scale is for.
    When the project depth switch lands (§3.1, not built), an 8 bpc project is what puts an
    effect colour on the 0–255 scale.
- **The hex box is display-referred**, so on the float scale it shows the colour **clipped**
    into 0–1, and the picker says so in a line under the swatches whenever a channel is
    outside that. Typing a hex sets exactly those 0–1 values. The alternative — hiding the box
    on the float scale — loses the one notation people actually exchange colours in.

The picker **applies to the document as it changes**. A drag inside it previews continuously
on the picture (the same live tick an Effect controls drag sends) and settles into one
undoable edit when released; a typed number, a hex entry or a preset click is one settled
edit on its own. So there is no state where the picker shows one colour and the composition
shows another, and **clicking away from the picker closes it keeping what is applied** —
nothing is waiting on a button. **Cancel** is the way back: it writes the colour the picker
opened with and closes. **Apply** closes keeping the current one.

**The dropper** is the pipette beside a swatch — and beside anything else that means "a value
at a pixel", which is not only colour: the depth-of-field **focal point** carries one, and it
reads *depth*, not colour. Clicking it arms the tool; clicking it again, pressing Escape, or
pressing away from the picture puts it away. It lights while armed, so a dropper armed and
forgotten is visible from across the panel.

While armed, the Viewer grows a **magnifier** that follows the pointer:

- a **9×9 grid** of the pixels under the pointer, one enlarged square each, with **dashed
  rules between every pair** so pixel boundaries are legible;
- a **solid border** round the pixels that will actually be taken — the **centre pixel alone**
  by default, its corners taking the theme's control radius, so it is rounded under the round
  shape and square under the sharp one;
- **Shift+scroll** steps the sampled region 1×1 → 3×3 → 5×5 → 7×7 → 9×9 and back, never
  wrapping and never exceeding the grid; the region is always odd, so there is always one
  centre pixel. Shift+scroll does not also zoom the picture.
- a **strip under the grid** saying what would be picked. For a colour pick that is the
  averaged colour and its numbers; for a pick that is reading something else it is **the layer
  the numbers are coming from and the value read off it** — a swatch of the composite would be
  a colour nobody is choosing.

Averages are taken in **scene-linear light**, not over display bytes, because that is the
space a Colour parameter stores and what "the average of these pixels" physically means.

A pick that reads a **layer** — the depth-of-field focal point reading its own depth pass —
samples that layer **rendered alone**, not the composite: a depth pass is nearly always
hidden, so what the composite shows at that pixel is not the number the effect uses. The
effect's `depth_invert` is applied at the pick, so the caption and the committed value cannot
disagree.

The pixels themselves come from the engine, a **window** at a time
(`CompositionReference::sample_pixels` → `WorkerResponse::Sampled`,
[17-BRIDGE-CONTRACT.md](17-BRIDGE-CONTRACT.md)): a 129×129 square of the picture, out of which
the magnifier cuts its own 9×9 as the pointer moves. Moving the pointer, and changing the
sample size, therefore cost **nothing** — no bridge call, no render, no message — and a new
read happens only when the pointer nears the window's edge, the playhead moves, an edit lands,
or a different layer is being read. A window is 66 KiB, so this does not reopen the read-back
frame transport K-183 deleted (a 1080p frame is 8 MiB and 8.8 ms in the codec); it is the
answer to a question about a few pixels, not a picture.

Still to build here: the x/y **position** pick for coordinate-valued parameter pairs (the
egui build's T14 viewfinder), and the on-Viewer crosshair handle for point parameters.

---

## 7. Effects & Presets

- A searchable tree: **built-in effects** by category ([08-EFFECTS.md](08-EFFECTS.md)),
  **OFX** and **LFX** plugins (labelled with their origin), **user presets**, and imported
  preset packs.
- Search is fuzzy, matches names and categories, and filters the tree live. `Ctrl+F`
  focuses search when the panel has focus.
- Apply by: double-click (applies to selected layers), drag onto a layer row in the
  Timeline, or drag onto the Viewer (applies to the topmost hit layer, which highlights
  before release).
  - **v1 (K-101)**: the drag-onto-Timeline-row path ships first, scoped to footage and
    adjustment layers (the effect stack's two ordinary homes) — dragging an entry there shows
    an accent hover outline over the row and appends the effect on release, one ordinary undo
    step. The drop target is the **whole row** (the layer outline as readily as the lane, since
    the browser's hit-test ignores whatever bar or switch sits under the cursor) and the
    **Effect Controls panel** (dropping anywhere in it appends to the shown layer). Double-click
    apply, drag onto the Viewer, and every other layer kind (which still gains effects through
    its own row's "Add effect" menu) remain later steps.
- **User presets (K-129)**: a **Presets** group at the top of the tree lists the `.lumfx`
  presets in the preset library — the roaming app-data folder `…/Lumit/data/presets`,
  scanned live so a just-saved preset appears at once. Each entry shows the preset's own
  name (or the file stem when the file can't be read), filters under the same search field,
  and **applies on a click**, appending its whole saved stack (fresh instance ids) to the
  selected layer as one undoable `SetLayerEffects` — the same append the Effect Controls
  → Presets "Load preset…" commits. "Save stack as preset…" defaults its file dialogue to
  this folder (created lazily), so saving and browsing share one home, and it saves **exactly
  the current selection** (K-156): the highlighted effects with their values as set, and — when
  specific keyframes are picked out on the lanes — only those keys. With nothing highlighted it
  falls back to the whole stack. A missing or empty folder shows a hint, never a failure.
  Drag-a-preset-onto-a-layer and preset thumbnails are later steps.
- **Favourites**: star any effect or preset; a Favourites group pins to the top of the tree.
- Hovering an entry SHOULD show a one-line description; presets show a thumbnail where the
  preset carries one.

---

## 8. Scopes

- One Scopes panel type; each instance shows one scope, chosen in its header: **waveform**
  (luma or RGB), **vectorscope**, **histogram** (per-channel/luma). Open several instances
  for side-by-side scopes (the Colour workspace does).
- Scopes are computed from the **Viewer's displayed frame** — after preview resolution
  and channel view, before display transform (so scopes read scene values, not the monitor
  transform). When preview resolution is below Full, the panel MUST show a small "computed
  at Half" style note, because downsampling changes distributions.
- Scopes MUST update live during playback; under load they degrade to a lower update rate
  before they degrade precision (they participate in adaptive degradation and light the
  Viewer's degradation indicator, §2.2).
- **v1 (K-096, extended by K-130)**: scopes are computed on the CPU from the composited
  frame Lumit banks in RAM — that banked frame *is* the Viewer's displayed frame. The panel
  reads the frame **under the playhead** from the cache **every paint** and, while playing,
  requests a repaint at the playback cadence, so the trace **tracks the live frame during
  playback** for every frame the cache holds (a warmed work area — idle fill, playback
  prefetch, or the paused readback — keeps the scope live end to end). When a playback frame
  isn't banked yet (one the frame-budget readback skipped, or one still rendering) the scope
  **holds the last frame it showed** rather than blanking, and catches up the moment the
  current frame is banked — the graceful degradation §8 asks for under load. Guaranteed
  every-frame tracing under all conditions (including a cold, unwarmed comp) still waits on a
  GPU-side scope pass. Banked frames are always specified-resolution, so the "computed at
  Half" note does not fire in v1. Colours come from the theme's fixed scope set (a near-black
  graticule and bright trace in both light and dark chrome, like the neutral Viewer surround,
  §2.1).

---

## 9. Preview panel and transport

A slim transport strip is docked beneath the Viewer bar by default; the same controls exist
as the dockable **Preview panel**.

- **Play/pause** (Space), stop-to-start toggle behaviour as a setting.
- **Loop modes**: loop work area (default) / play once / ping-pong.
- **Cache status**: a readout of how much of the work area is preview-ready (backed by the
  cache bar), plus a *fill cache* action that renders the work area ahead of playback while
  idle (K-016). Lumit has no separate "RAM preview" ritual — playback always plays, using
  whatever is cached and rendering the rest, degrading before dropping (K-018); uncached
  playback keeps audio sync by frame-skipping and reports skipped frames in this readout.
- **Audio mute** toggle.
- **Quality toggle**: full / draft preview quality (draft maps to the engine's reduced
  quality mode; independent of preview resolution).
- **Preview mode toggle** (K-030): **Cached** (default) / **Realtime**. Realtime renders
  every frame live, continuously choosing the resolution tier that sustains the comp frame
  rate instead of waiting on cache — the "just play it now" mode for heavy comps. The
  active tier shows in the Viewer's degradation indicator
  ([06-RENDER-PIPELINE.md](06-RENDER-PIPELINE.md) §6.5). This toggle lives here and in
  Settings → Preview, deliberately **not** in the Viewer bar's resolution dropdown: picking
  a resolution and picking a mode are different decisions, and the resolution picker stays
  the default way to work through a project.

---

## 10. Audio panel (v1)

The v1 sync toolkit (K-050); the Composer workspace is future work specified in
[09-AUDIO.md](09-AUDIO.md) and not here.

- **Waveforms in the Timeline**: every audible layer MAY show its waveform inside its row
  (twirl the Audio group, or a per-layer waveform toggle); the Audio workspace defaults
  them on. Waveform rendering MUST stay responsive at any zoom (mip-mapped peaks).
  **Shipped (K-172):** the Audio group (Volume + Waveform twirl) in the layer outline; the
  lane draws the item's 2048-bucket peak strip through the layer's live offset each paint.
  The earlier comp-wide strip under the ruler is gone — it was one mixed-down waveform for
  the whole comp, went stale during a drag, and stopped earning its row once every layer
  could carry its own.
- **Beat-marker generation**: pick a source audio layer; controls for **sensitivity**,
  detection **range** (whole layer or work area), and minimum beat spacing; *Generate*
  writes beat markers to the comp's markers ribbon; *Clear beat markers* removes only
  generated ones. Generated markers are ordinary markers thereafter — movable, deletable,
  snap targets everywhere (§4.5, §5.3). Manual beat tapping: pressing `8` during playback
  drops a beat marker at the playhead.
- **Volume keyframes**: each audio-capable layer has a Volume property (dB) with normal
  keyframe/graph-editor behaviour; the Audio panel shows the selected layer's volume and
  pan? — pan is deferred; v1 exposes volume and mute/solo only.
- **Level meters**: output meters for playback, peak-hold, in the panel header.

---

## 11. Export dialogue

`Ctrl+M` (or File → Export…) adds the active comp to the **export queue** and opens the
Export window. Export never blocks editing; the queue runs in the background.

- **Queue list**: each item shows comp name, range, preset, destination, status
  (queued / exporting with progress and time remaining / done / failed with reason /
  cancelled), and a **per-item cancel** button. Items are reorderable; failed items keep
  their settings for retry.
- **Per-item settings**: range (work area / full comp / custom in-out), **preset**, output
  folder, filename (tokenised template: comp name, date, preset) — and, expandable beneath
  the preset, the full custom controls: resolution (comp / half / custom), frame rate
  (comp rate or override), format/container, codec with encoder choice (hardware
  NVENC/AMF/QSV or software), rate control (VBR bitrate / CRF quality), colour output
  (Rec.709 default), audio codec/bitrate, and **resource allocation** — export thread
  count and a background/balanced/fast priority selector governing how much of the
  machine the queue takes while you keep editing. Editing a preset's controls offers
  "save as new preset".
- **Shipped presets**: *YouTube 1080p60* (H.264, high bitrate VBR), *YouTube 1440p60*
  (H.264; the scene's quality trick), *Vertical 1080×1920 60* (Shorts/TikTok/Reels), plus
  *PNG sequence + alpha* and a mezzanine intermediate. Preset details and encoder matrix
  live in the export spec; presets are user-editable and shareable files.
- **Progress**: overall queue progress in the window and on the OS taskbar icon; per-item
  progress bars; completion raises a non-blocking notification with *Reveal in folder*.
- Export uses full quality always — adaptive degradation and preview resolution MUST NOT
  leak into export (glossary §5).

---

## 12. Command palette

`Ctrl+Shift+P` opens the command palette from anywhere.

- Fuzzy search over: **commands** (every menu item and every remappable action, with its
  current shortcut displayed), **effects** (enter applies to the selected layers),
  **comps** (enter opens in the Viewer/Timeline), and **panels** (enter opens/focuses).
- Arrow keys navigate, `Enter` executes, `Esc` closes; the palette MUST be fully
  keyboard-operable and MUST show category badges so an effect is never mistaken for a
  command.
- Recently used entries rank first. Plugins (LFX) MAY contribute commands.
- The palette doubles as the discoverability layer: any command a user cannot find in the
  menus is one palette search away, with its shortcut taught in the result row.

**Shipped (v1, K-102):** the palette exists — Ctrl/Cmd+Shift+P or Window → Command palette…,
fuzzy search (subsequence; a label match outranks a keyword-only one), arrow keys navigate,
Enter/click runs, Esc closes, drawn as a top-anchored `egui::Modal`. v1 covers the
**commands** category (save, undo/redo, new composition, add layers, reset workspace, open
Settings, colour scheme and shape switches, export). The effects/comps/panels categories,
recent-first ranking, category badges and taught shortcuts fill in later.

## 12.1 Composition hierarchy

The **Hierarchy** panel (K-102) shows the active composition as an indented, foldable tree:
its layers, each precomp layer expandable to reveal the layers of the composition it nests,
recursion-guarded. Clicking a row selects that layer and switches to its composition. It is
read-only — the simple tree form of the AE composition flowchart; the full node-graph
flowchart (the deferred `egui_node_graph`-style view) grows from it.

---

## 13. Onboarding and empty states

### 13.1 First-run setup (K-006, post-v1 polish)

On the very first launch only, before any project opens, one calm screen asks a single
question: *"Where are you coming from?"* with four cards:

| Choice | What it sets |
|---|---|
| **Vegas for speed ramps and effects** | Graph editor opens Retime in the **speed graph** by default; ramp preset shelf (Linear/Slow/Fast/Smooth/Sharp) pinned in the graph editor; *New Sequence layer* promoted in the Timeline empty-state hints; Vegas-mapping tips enabled (e.g. "velocity envelope → Retime speed graph"). |
| **Vegas for speed ramps, AE for effects** | Speed graph default for Retime, **value graph** default for ordinary properties; AE-alternate keymap offered; both mapping tip sets enabled. The most common montage-scene split. |
| **After Effects for both** | Value graph default everywhere; AE-alternate keymap offered; AE-mapping tips (e.g. "time remap → Retime", "track matte → matte dropdown"). |
| **Neither / just starting** | Lumit defaults; beginner-leaning rich tooltips enabled. |

Rules: one screen, skippable (skip = Lumit defaults), no account, no telemetry, nothing
else asked. Every affected setting is an ordinary visible setting changeable later, and
the chooser can be re-run from the command palette (*First-run setup*). This MUST remain
a single screen — it is a preference primer, not a tour, and does not breach §13's
no-wizard rule below.

### 13.2 Empty states

- **Empty project**: the Viewer area shows a single calm card with three actions —
  *Import footage*, *New composition*, *Open project* — plus recent projects and a note
  that footage can be dropped anywhere in the window. Drag-and-drop import MUST work over
  every panel from first launch.
- **Comp with no layers**: the Timeline shows one line of hint text (drag footage here, or
  press the new-Sequence-layer / new-Solid shortcuts). Hints disappear at first content
  and never return unprompted.
- **Tooltips policy**: every icon control has a tooltip with its name and current shortcut,
  on a ~500 ms hover delay. Rich tooltips (a sentence + *Learn more* link) are reserved for
  concepts with Lumit-specific behaviour (Retime, overrun, matte, adaptive degradation).
  Tooltips MUST never block input, auto-play media, or step users through forced tours.
  A single setting disables all tooltips.
- No multi-step onboarding wizard or forced tour. The single first-run screen (§13.1),
  empty states, tooltips, and command palette are the entire onboarding surface.

### 13.3 The composition settings dialogue (K-180)

One window serves both **New composition** (Create) and **Composition settings** (Save); they
ask the same four questions and differ only in what the button does. It is reached from the
Composition menu, the Project panel's footer button, a right-click on a comp row, and a drop of
footage on that button (§3.1).

- **Name.**
- **Size**: width × height, with an aspect-ratio lock (on by default — editing one side carries
  the other) and the shape shown beside it in its smallest whole numbers (`40 : 17`).
- **Frame rate**: **one number**, in fps. `600` and `23.976` are both typed as they read; a
  **Presets** list offers the common rates including the NTSC family. The denominator is never
  shown. It still crosses the bridge as the exact `num`/`den` pair — 23.976 reaches the engine
  as 24000/1001 — but that pair is derived from what was typed (docs/14 §2 is unchanged).
- **Duration**: reads and edits as `HH:MM:SS:FF` timecode at the frame rate above (the same
  clock face the Viewer shows; the frames field widens with the rate, so 600 fps counts to
  `:599`). What is *written* is still a length of time in exact seconds, converted at the
  typed rate — never a frame count: a count means nothing without the rate it was counted at,
  and writing one back at a *changed* rate is what used to make the comp longer or shorter
  under layers that had not moved (K-180).

**Changing the frame rate MUST change only the frame rate.** The comp keeps its length, every
layer keeps its timing, and nothing plays faster or slower — the comp is simply shown at more
(or fewer) frames per second. This has a regression test on both sides of the bridge.

---

## 14. Interaction and accessibility rules

Binding, from the household mandate; these override convenience everywhere.

- **User controls tempo**: nothing auto-advances, auto-plays, or animates the user's
  viewport. No scroll hijack — the wheel never zooms or navigates without an explicit
  modifier (§4.6). Focus never jumps except as the direct result of a user action.
- **Keyboard reachability**: every control MUST be reachable and operable by keyboard.
  `Ctrl+F6`/`Ctrl+Shift+F6` cycle panel focus; `Tab` traverses controls within a panel;
  arrow keys operate lists, trees, and the Timeline outline. All functionality exposed
  through drag interactions MUST have a keyboard or numeric-entry equivalent (keyframes:
  numeric entry §5.3; docking: a *Move panel to…* command; gizmo: arrow-key nudging).
- **Focus visibility**: keyboard focus always shows a visible focus ring (treatment in
  [15-DESIGN.md](15-DESIGN.md)); focus is exposed through AccessKit with names, roles, and
  values for every control.
- **Hit targets**: controls in low-density surfaces (dialogues, transport, onboarding,
  Export window) MUST be at least 44 px in their smaller dimension. In the dense pro
  surfaces (Timeline switches, keyframe diamonds, lane carets) density wins — visual
  targets go as small as legibility allows, and the compensation is mandatory: an invisible
  hit-slop expanding every interactive element's hit area to at least 24×24 px (clamped so
  neighbouring targets never overlap), a UI scale setting (100/125/150 %), adjustable
  Timeline row heights, and a keyboard path to every switch.
- **Reduced motion**: when the OS requests reduced motion, spring animations do not mount —
  panel transitions, drop-zone previews, and palette entrances become instant or simple
  short fades. No parallax, no bounce. Playback of the user's own content is unaffected.
- **No punishment UI**: errors (missing footage, failed export, expression errors) are
  calm, factual, and never alarm-styled; an expression error disables that expression,
  shows a banner with the message, and renders the keyframed value — never a black frame,
  never a modal.
- **Voice**: UI copy is en-GB, sentence case, no exclamation marks (K-005).

---

## 15. Default keymap

### Settings inventory (K-031/K-032 anchors)

The Settings window groups, minimum set — every value here is machine-local (never in the
project file, [10-FILE-FORMAT.md](10-FILE-FORMAT.md) §2):

- **Performance**: RAM budget for Lumit (default 60% of system, slider + absolute),
  VRAM budget (default 70%), CUDA acceleration on/off (per K-014 it is only ever an
  optional per-node accelerator; off = WGSL path, identical output), decoder pool size,
  worker thread cap, background cache fill on/off.
- **Cache**: cache root folder, disk cache size budget, clear-cache actions (per tier),
  proxy generation policy.
- **Preview**: default preview mode (Cached/Realtime, K-030), Realtime tier bounds,
  adaptive-degradation aggressiveness, audio scrubbing on/off.
- **Colour** (K-031): working-space defaults for new comps, display transform selection,
  footage interpretation defaults. The preview–export parity rule is stated in this panel's
  header text so users understand what the app guarantees.
- **Export**: default preset, export priority default (background/balanced/fast), encoder
  preference order, filename template.
- **Keymap**, **Interface** (UI scale, tooltips, reduced motion follows OS or override),
  **Autosave** (interval, copies kept), **Plugins** (search paths, disabled list,
  per-plugin overrides).

**Shipped (v1, K-098; VRAM budget and Clear cache added K-100; Background fill added K-115;
Cache root folder added K-117; Interface page added K-118; Export page added K-119):** the
Settings window exists — a macOS-System-Settings-style surface, a sidebar of pages with grouped
cards, honouring the Sharp/Round shape. It opens from **Window → Settings…** or
**Ctrl/Cmd+comma**. Its v1 pages are a subset of the inventory above: **Appearance** (Theme Mode,
Background ramp, Accent, Shape, Interface motion — all migrated here out of the Window menu,
K-092), **Interface** (UI scale, 75–200%, applied live via egui's own zoom mechanism; a Show
tooltips switch that suppresses hover tooltips app-wide when off, K-118), **Performance** (RAM
frame-cache budget, disk-cache cap and VRAM frame-cache budget, all applied live, a Clear cache
action that empties the RAM and VRAM tiers at once, a Background fill toggle gating the idle-fill
loop, and a Cache root folder picker that redirects new project on-disk caches to a chosen folder
instead of always sitting beside the project file, K-117), **Export** (a default-preset dropdown
that a generic "Export…" action stamps — an explicit pick from the Export preset submenu always
overrides it — and a filename template with `{comp}`/`{preset}`/`{date}` tokens for the export
dialogue's suggested name, sanitised against illegal Windows filename characters, K-119; export
priority and encoder preference order are not built — no priority or encoder-order concept exists
in the export pipeline yet, so those two inventory rows would be dead controls), and **General**
(reset workspace, an **Autosave** group — interval in minutes and copies kept, defaulting to the
previous 5 min / 5 copies — and version). Reduced motion stays on the Appearance page as Interface
motion (K-092), not this Interface page — the inventory line above groups it with Interface
conceptually, but it shipped earlier under Appearance and stays there. The remaining groups (CUDA,
decoder pool size, worker thread cap, proxy generation policy, Preview, Colour, export priority,
encoder preference order, Keymap, Plugins) fill in on this same surface as those systems gain
their controls.

**Shipped in Flutter (K-193, K-194):** the paged surface is back, in the same shape — a
sidebar of pages, each a stack of named sections, each section a card of rows carrying what
the setting is, a line saying what it does, and its control on the right. Its pages are
**General** (reset workspace, version and build), **Appearance** (colour scheme, corners,
interface motion), **Interface** (UI scale, tooltips, and whether the Effect controls panel
repeats the layer's Source, Transform and Retime rows — off by default, since the Timeline's
fold-out already shows them), and **Performance** (playback mode, quality tier and reset,
and the RAM and VRAM frame-cache budgets with their readouts and Clear buttons). The two
budgets are **typed and draggable numbers capped at what the machine has** — installed RAM
and the adapter's dedicated video memory, asked of the engine — rather than a pick from a
fixed list of sizes (K-194). The egui build's
**Export** and **Autosave** groups are *not* rebuilt yet: neither has anything behind it on
this frontend (docs/TODO.md), and an empty page is a promise the window cannot keep.

All bindings are remappable in Settings → Keymap (search, conflict detection, per-context
display); the keymap serialises to a shareable file. An "After Effects" alternate preset
ships for muscle-memory cases where Lumit's default deviates. Notable deviations from AE:
`J/K/L` are shuttle transport (the audience's NLE habit, per the layout brief), so keyframe
navigation moves to `,`/`.`; Viewer zoom therefore lives on `Ctrl+=`/`Ctrl+-` and the wheel.

**Shipped (K-199).** Settings → Keymap is a table, grouped by the context a binding is live
in, with the action's name on the left and its chords on the right — click a chord cell and
press the keys you want, `Escape` to leave it, `Backspace` to clear it, `Reset` to put the
shipped chord back. Above it: a search box that matches what the table *shows* as well as
the ids underneath, the two presets, and Import / Export for the shareable file. A chord
another action already holds is taken rather than refused (refusing would make swapping two
actions' keys impossible) — within one context the previous owner's row simply goes blank,
and across overlapping contexts a banner names the clash. One row, one chord (K-200): no
shipped action carries two, and a user who wants a second spelling of a command binds it
themselves.

The model is `lumit-keymap` and the seam is `crates/lumit-bridge/src/api/keymap.rs`: the
engine decides what a chord means and the frontend only spells the keypress and draws the
answer (K-199). The keymap is stored in the workspace file as the engine's own JSON, so it
survives a restart in the same format it exports in.

Two honest gaps. The **Tools**, **Project**, **Panels** and **Effects** contexts have rows
in the table and nothing behind them — those commands are not built on this frontend, so the
bindings are real and pressing them does nothing. And the arrows step a frame alongside
`Page Down`/`Page Up`; the table below did not name them, which would have quietly taken
them away the day dispatch started going through the keymap.

| Context | Key | Action |
|---|---|---|
| Global | `Space` | Play / pause |
| Global | `J` / `K` / `L` | Shuttle reverse / pause / forward (repeat `J`/`L` steps ×2, ×4, ×8) |
| Global | `Page Down` / `Page Up` | Next / previous frame |
| Global | `Shift+Page Down` / `Shift+Page Up` | ±10 frames |
| Global | `Home` / `End` | Comp start / end |
| Global | `Shift+Home` / `Shift+End` | Work area start / end |
| Global | `I` / `O` | Go to selected layer's in / out point |
| Global | `,` / `.` | Previous / next keyframe on revealed properties |
| Global | `Ctrl+,` / `Ctrl+.` | Previous / next edit point or layer boundary |
| Global | `B` / `N` | Set work area start / end at playhead |
| Global | `*` (numpad or `Shift+8`) | Add marker at playhead (`8` during playback: beat tap, §10) |
| Global | `Delete` / `Backspace` | Delete the selection — keyframes when any are selected, else the layer (TF-6) |
| Global | `Ctrl+Shift+P` | Command palette |
| Global | `Ctrl+M` | Add active comp to export queue |
| Global | `Ctrl+K` | Composition settings |
| Global | `Ctrl+Z` / `Ctrl+Shift+Z` | Undo / redo |
| Global | `Alt+Shift+1…9` | Switch workspace |
| Global | `` ` `` | Maximise / restore panel under pointer |
| Tools | `V` | Selection tool |
| Tools | `H` | Hand (pan) — also held-`Space` drag in the Viewer |
| Tools | `Z` | Zoom tool (`Alt` to zoom out) |
| Tools | `Y` | Anchor point tool |
| Tools | `C` | Razor tool (Sequence layers and layer splitting) |
| Tools | `Q` | Shape/mask tool cycle |
| Tools | `G` | Pen tool |
| Timeline | `P` `S` `R` `T` `A` | Reveal position / scale / rotation / opacity / anchor |
| Timeline | `E` / `M` | Reveal effects / masks |
| Timeline | `U` / `UU` | Reveal animated / modified properties |
| Timeline | `Shift+L` | Reveal volume (audio) |
| Timeline | `[` / `]` | Move layer in / out to playhead |
| Timeline | `Alt+[` / `Alt+]` | Trim layer in / out at playhead |
| Timeline | `Ctrl+Shift+D` | Split layer / cut clip at playhead |
| Timeline | `Ctrl+D` | Duplicate selection |
| Timeline | `Ctrl+Shift+C` | Precompose |
| Global | `Ctrl+Alt+T` | Give the selected layer a Retime, or take it away (K-197, narrowed to this one chord by K-200 — AE's own, and one Windows cannot steal; the Composition-menu route is K-198) |
| Timeline | `=` / `-` | Zoom time in / out (`Ctrl+wheel` at pointer) |
| Timeline | `\` | Toggle full-comp zoom / previous zoom |
| Timeline | `Enter` | Rename selected layer |
| Timeline | `X` | Toggle selected layer visible switch |
| Graph editor | `Shift+F3` | Toggle graph editor |
| Graph editor | `F9` / `Shift+F9` / `Ctrl+Shift+F9` | Ease / ease in / ease out |
| Graph editor | `F` | Auto-zoom fit selection |
| Viewer | `Shift+/` | Fit magnification |
| Viewer | `Ctrl+=` / `Ctrl+-` | Zoom in / out |
| Viewer | `Ctrl+J` / `Ctrl+Shift+J` / `Ctrl+Alt+J` | Preview resolution full / half / quarter |
| Viewer | `Ctrl+R` | Toggle rulers |
| Viewer | `Ctrl+'` | Toggle transparency grid |
| Panels | `Ctrl+F6` / `Ctrl+Shift+F6` | Cycle panel focus forward / back |
| Panels | `Ctrl+F` | Focus the panel's search field (Project, Effects & Presets) |

macOS development builds map `Ctrl` to `Cmd` (K-001).

---

## 16. Visual language

Everything visual — colour tokens, dark-native Aizome variant, hairline borders, type stack,
icon set, spacing, cache-bar tier colours, marker styling, focus ring treatment — is
specified in [15-DESIGN.md](15-DESIGN.md) (K-004). This document intentionally contains no
colour or dimension beyond hit-target minima. Where this document names a state that needs
visual distinction (degradation badge, overrun hatching, beat vs ordinary markers, cache
tiers, proxy badges), 15-DESIGN.md MUST define exactly one treatment for it.

---

## Open questions

1. **Graph editor as a detachable panel** — v1 specifies it as a Timeline mode; should it
   also be dockable as a standalone panel locked to a comp (useful on wide monitors)?
2. **Snapshot/compare in the Viewer** — AE's snapshot slots (`Shift+F5…`) are useful for
   grading; deferred from §2.2. Ship in v1 or with the Colour workspace maturation?
3. **Align panel and Properties-style quick panel** — not specced; decide whether v1 needs
   an Align panel or whether gizmo snapping covers the need.
4. **Per-clip thumbnails in Sequence layers** — decode cost versus orientation value at
   small row heights; needs prototyping against the thumbnail cache.
5. **Keyframe navigation keys** — `,`/`.` deviates from AE (which uses them for zoom) and
   from AE's `J`/`K` keyframe navigation; validate with target users before locking the
   shipped default.
6. **Scopes tap point** — specced as pre-display-transform; colour-managed workflows may
   want a post-transform option. Revisit with [15-DESIGN.md](15-DESIGN.md) and the colour
   management spec.
7. **Touchscreen/pen support** — hit-slop rules assume mouse; whether pen scrubbing and
   touch panning are v1 or later is unowned.
8. **Workspace strip overflow behaviour** on narrow windows (menu versus scroll) — trivial
   but undecided.
