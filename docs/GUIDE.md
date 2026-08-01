# The plain-English guide to Lumit's code

**Who this is for:** the project owner — someone who knows editing software inside-out but
has never written Rust and hasn't worked with threads or GPUs directly. Read this once and
you'll be able to navigate the codebase, understand what each part does and why, and make
changes without fear. Everything here is explained with editing analogies where they help.
No prior programming knowledge in Rust is assumed; general "I've seen code before" level is.

This guide is **kept current by rule** (CLAUDE.md): whenever a new concept enters the
codebase, a plain-English section for it is added here in the same commit.

---

## 1. The 30-second map

Lumit is split into **crates** (Rust's word for a module/library — think of them as the
app's departments). They live in `crates/`:

| Crate | Job | Plain English |
|---|---|---|
| `lumit-core` | Time, the document, undo | The project file's brain: what a comp/layer *is*, and every edit that can happen to it |
| `lumit-project` | `.lum` files, autosave, recovery | Saving and loading, and the "never lose work" machinery |
| `lumit-render` | Making the picture | The whole path from "here is the project" to "here are the pixels" — decoding, compositing, caching, export |
| `lumit-media` | Decoding video | Turning an .mp4 into frames |
| `lumit-gpu` | The GPU pipeline | Drawing and processing frames on the graphics card |
| `lumit-audio` | Sound | Playback and the clock everything syncs to |
| `lumit-eval` | The render engine | Working out what each frame looks like |
| `lumit-cache` | Caching | Remembering rendered frames so they're never rendered twice |
| `lumit-flow` | Optical flow | Motion vectors for smooth-retime and flow motion blur |
| `lumit-text` | Text | Rasterising text layers |
| `lumit-keymap` | Keyboard shortcuts | What each key combination means, and what clashes with what |
| `lumit-bridge` | The Flutter seam | How the Flutter frontend talks to the engine (see [17-BRIDGE-CONTRACT.md](17-BRIDGE-CONTRACT.md)) |

Everything you actually *see* lives outside `crates/`, in `flutter_ui/` — the
Flutter application (panels, menus, the theme). The original egui shell
(`lumit-ui` + `lumit-app`) was deleted in K-182; if you ever need to look at how
the old frontend did something, it is one `git log` away. (`lumit-keymap` went
with it, as unused at the time, and came back unchanged in K-199 when the
shortcut editor was actually built.)

Three of these have proper names you'll see in the app and docs (decision K-083),
drawn from the same astral register as the app itself: **Nova** (a burst of new light) is
the render pipeline — `lumit-eval` + `lumit-gpu` working together to turn the project's
edits into the picture; **Nebula** (the cloud where material gathers) is the cache;
**Pulsar** (the cosmic clock) is the audio engine whose clock everything syncs to. Crate
names stay plain `lumit-*` — the names are for people, the identifiers are for code.

**One rule ties them together:** the engine crates never depend on the UI. The UI asks the
engine for things; the engine doesn't know the UI exists. That's why the UI could be
replaced entirely without touching the engine — like swapping a car's dashboard without
opening the engine bay.

That rule is also why `lumit-render` exists. The picture-making code once lived inside the
frontend, which meant anything wanting a frame had to reach *through* a user interface to
get one — a dashboard wired into another dashboard. Pulling it into its own crate (decision
K-178) put it back where it belongs: the Viewer and the exporter now ask the same engine for
frames, so what you preview cannot differ from what you export.

## 2. Rust in ten minutes, Lumit edition

You don't need to write Rust to read it. The handful of ideas that appear everywhere:

- **Ownership.** Every piece of data in Rust has exactly one owner, and the compiler
  enforces it. When you see code "cloning" a document, that's making an independent copy so
  two parts of the app can't fight over one. This is the language feature that makes the
  "never crashes" goal realistic — whole categories of crash (two threads corrupting the
  same memory) simply don't compile.
- **`Result` — errors are values, not explosions.** A function that can fail returns
  `Result<Thing, Error>`: either `Ok(thing)` or `Err(why)`. The caller *must* deal with
  both. You'll see `?` a lot — it means "if this failed, pass the error up to my caller".
  Lumit bans the shortcuts (`unwrap`/`panic`) that turn errors into crashes; the build
  literally fails if someone uses them in engine code.
- **`Option`** is the same idea for "might not exist": `Some(comp)` or `None`. No
  null-pointer crashes, ever.
- **Structs and enums.** A `struct` is a record (a Layer has a name, an in point, an out
  point…). An `enum` is a choice between shapes — `LayerKind` is Footage *or* Sequence *or*
  Text… and the compiler forces every `match` to handle every case, so adding a new layer
  kind makes the compiler point at every place that needs updating. That's why the strict
  glossary maps so well to code.
- **Traits** are capability contracts, like "anything that can decode frames". Code can say
  "give me anything that satisfies this trait" — that's how the engine will stay swappable
  (a CPU decoder and a GPU decoder behind the same trait).
- **`Arc<T>`** means "shared, read-only handle to T" (Atomically Reference Counted). Several
  parts of the app can hold the same document snapshot at once; it's freed automatically
  when the last holder lets go.
- **Crates and Cargo.** `Cargo.toml` files list dependencies (like a plugins list).
  `cargo build` compiles, `cargo run` launches, `cargo test` runs every test. Those three
  commands are 95% of what you'll ever type.

## 3. Threads, in editing terms

A thread is an independent worker inside the program. Lumit's design gives each worker a
fixed job (the full table is in [05-ARCHITECTURE.md](05-ARCHITECTURE.md)):

- **The UI thread** is front-of-house: it draws the interface and responds to your mouse.
  The golden rule — it **never** does heavy work. Every stutter you've ever felt in AE is
  some engineer breaking this rule. In Lumit it's structural: the UI thread hands work to
  others and carries on drawing.
- **Worker threads** are the render farm: they evaluate frames, run effects, do maths.
  There are roughly as many as your CPU has cores.
- **Dedicated threads** exist for decoding video, disk IO, and audio — because those jobs
  must never wait behind anything else (audio especially: if its thread is ever late, you
  *hear* it).

Two mechanisms make this safe, and you'll see them by name in the code:

- **Snapshots (`ArcSwap`).** When you edit, the UI thread produces a complete new immutable
  copy of the document and atomically swaps a pointer to it. Workers that were mid-render
  keep the old copy; new work uses the new one. Nobody ever sees a half-finished edit —
  like workers each getting their own printed copy of the script, and edits producing a
  fresh printing rather than scribbling on someone's pages.
- **Epochs (cancellation).** Every piece of work carries a ticket number. When you scrub,
  the global ticket number increments; workers check their ticket often ("is my work still
  wanted?") and quietly stop if it's stale. Nothing is force-killed — force-killing is how
  you corrupt state — everything checks and steps aside. Details in
  [impl/playback-scheduler.md](impl/playback-scheduler.md).
- **Channels** are how threads hand each other work: a conveyor belt with a fixed length.
  A full belt makes the sender wait — that's **back-pressure**, and it's deliberate: it's
  the mechanism that stops the app drowning itself under load (rule K-018, degrade never
  crash).

## 4. What exists today, file by file

- `crates/lumit-core/src/time.rs` — **Rational time.** Times are stored as exact fractions
  (`num/den`), never decimals, so frame maths is exact forever (a 3-hour NTSC timeline
  never drifts by a frame). The four "timebases" (source/clip/layer/comp time — glossary §4)
  are separate types, so mixing them up is a compile error, not a subtle bug.
- `crates/lumit-core/src/model.rs` — **What a project is.** Structs for the document,
  comps, layers, footage items. Each has an `extra` field that preserves anything a future
  Lumit version adds — so old and new versions can share project files.
- **Block glitch and Scanlines, the corrupted-video look, as two separate effects** (a third,
  Datamosh, is explained further down, once the flow-field machinery it needs has been
  introduced — the three used to be one "Glitch" effect with on/off sections, but each does
  one thing so each is now its own effect you drop on separately; stack Block glitch then
  Scanlines to get the old combined look back). **Block glitch**
  carves the frame into a grid (Block size) and, per block, reads its picture from a
  slightly different spot — a random-looking but fully repeatable jump, plus an optional
  colour-channel split and a "slice repeat" look where a thin strip of the block tiles
  instead of showing a plain shifted read. **Scanlines** darkens alternating bands of rows
  (Line period), optionally rolling them over time and alternating which half of
  each band darkens every other cycle for an interlaced-video feel — it has no hash and no
  Seed of its own, since it just reads straight down from each row rather than jumping
  around like Block glitch does. Each effect has its own Intensity dial that turns its own
  look up or down, and at 0 each is a guaranteed no-op — checked by a test — whatever Mix is
  set to. (Scanlines used to have *two* darken dials — Intensity and a separate Darkness —
  that multiplied together to do one job; they were merged into the single Intensity, which
  now simply means "how dark the dark lines get", 0 nothing and 1 fully black. An old project
  that still has the separate Darkness folds it into the one dial on load, so it looks the
  same.) The interesting engineering wrinkle, in Block glitch: which block "moves" and by
  how much has to be decided freshly for every pixel, on the GPU, from nothing but (seed,
  that block's row/column, a coarse time-step) — there's no way to precompute a lookup table
  for it up front, because a busy frame can have thousands of blocks. That means the effect
  needs its own hash function running *inside* the graphics-card program, not just on the CPU
  side like Shake's wobble does. Shake's existing hash is built on 64-bit numbers, which
  graphics-card programs (written in a language called WGSL) cannot represent — so Block
  glitch gets a sibling hash built entirely from 32-bit numbers instead, same design, both
  the CPU and the GPU version running the identical recipe so they always agree. Every
  "which block, how much, which look" answer comes from that one shared hash fed different
  small numbers, which is also why the same project glitches exactly the same way on every
  machine, every time. It reuses the same frame-cache lesson Shake taught the codebase:
  because Block glitch is seeded, the cache automatically knows a frozen frame still needs
  the *current* moment's local time to look right, with no Block-glitch-specific code needed
  for that part at all.
- **Echo / trails, and "temporal effects"** — the montage speed-line staple, and the first
  effect that needs *more than the current frame*. Until now every effect looked only at the
  single frame it was drawn on. Echo lays several earlier frames of the layer behind (or over)
  the current one, each fainter than the last, so a fast move smears into a trail. That means
  the app has to fetch those earlier frames and hand them to the effect — a new bit of
  plumbing. Each effect now declares, up front, which frames it needs (a little list of
  offsets like "this frame, one back, two back…"); the decode step reads the layer's footage
  at exactly those moments (following the retiming, same as the frame you're on), and both the
  live preview and the export do it the identical way so they still match. The picture cache
  learned about it too: an echo frame's identity now includes the neighbours it's built from,
  so — like the flow fix earlier — you never get a stale, frozen trail. Echo now reaches back
  up to sixteen frames one frame apart (it was eight), fades each by a Decay you set, and
  offers a Mode menu that starts with two echo-only choices — Behind (each echo tucked behind
  the trail, ghosting) and In front (over it) — then a divider, then the everyday light-combine
  blends: Add, Screen, Multiply, Overlay, Soft/Hard light, Lighten, Darken, Difference,
  Exclusion, Subtract, Divide (Screen is the default for bright glowing trails). The old "Max"
  is just Lighten now, and the old "Normal" is the clearer "In front". One nuance worth knowing:
  these blends run in
  the same "linear light" the compositor adds light in, on the see-through-aware (premultiplied)
  trail — the right space for stacking glowing copies, and it keeps the CPU and graphics-card
  versions matching to the last bit. Old projects keep whichever mode they had. Wider/looser
  trails (a Spacing control) are still a follow-up, and the other effects that want
  neighbouring frames — motion blur that follows real motion, and the datamosh look — build on
  this same machinery (both explained further down).
- **Fast motion blur — blur that follows real motion** — a temporal effect (called **Fast
  motion blur** in the menus, to set it apart from the whole-scene *Motion blur* of the
  accumulation kind) that turns game capture (which has no natural blur — every frame is
  pin-sharp) into footage that streaks the way a real camera would. It builds on two things
  already in the box: Echo's "fetch a neighbouring frame" plumbing, and the optical-flow engine
  that powers slow-motion. The trick is to look at the current frame and the *next* one, work
  out how far every pixel moved between them (that's the flow — a little arrow for each pixel
  saying where it went), and then smear each pixel along its own arrow. Fast-moving areas get
  long streaks; still areas stay crisp — exactly what real motion blur does, and what plugins
  like RSMB sell. The flow is worked out during decoding, where both frames are sitting in
  memory anyway (the same place slow-motion computes it), and passed to the blur as a little
  motion-map image; the preview and the export do it the identical way, so what you see is what
  you get. **The tricky bit — no more blocky cut-outs (the FX-19 fix).** Guessing motion is
  unreliable where things appear, disappear, or cross an edge, and the old version simply didn't
  blur those spots — leaving hard, obviously-wrong seams between blurred and un-blurred patches.
  The fix hands the blur a second little map alongside the arrows: a *confidence* from 0 to 1,
  worked out by checking the forward arrows against the backward ones (they should cancel out;
  where they don't, trust is low) and then softened so it fades rather than jumps. The streak
  length is simply multiplied by that confidence, so an unreliable area *eases* toward no blur
  instead of cutting. Three knobs plus a viewer: **Shutter angle** (how long the "shutter" stays
  open — 180° is the film-standard half-frame smear; higher blurs more, up to a full 720°),
  **Samples** (how many steps to take along each streak — more is smoother but slower), and a
  **View** picker — leave it on *Rendered* for the blurred picture, or switch to *Motion vectors*
  (the arrows, colour-coded) or *Confidence* (the trust map in grey) to see exactly what the
  effect is doing. A still frame, a shutter of zero, or zero confidence leaves the picture
  untouched. For now it follows the footage's own motion only (not, yet, motion you add with
  keyframes) and works on footage layers, the same starting scope Echo has.
- **Datamosh** — the corrupted-video "melting picture" look, rebuilt (T19) to follow motion
  properly. Real video codecs sometimes drop a frame's actual picture and just reuse the last
  one nudged by that frame's motion arrows; when this keeps happening, the old picture is
  dragged further and further along the motion and everything that's moving smears and *blooms*
  while the still parts stay put. This effect fakes that on purpose. For every pixel it takes a
  short **walk** along the motion arrows, starting from the previous frame: each step follows
  the arrow at the spot it's currently standing on (re-reading the arrow as it goes, so the
  smear *curves* with the motion instead of running dead straight), nudges along by about one
  frame's worth of movement, and picks up the previous frame's colour there. Those picked-up
  colours are blended together into a melting streak, which is then laid over the ordinary
  frame. Four dials shape it:
  - **Intensity** — how strongly the melt is laid over the true frame. It goes *above* full,
    which over-shoots past the moshed picture for a harder tear; at zero the effect does
    nothing at all.
  - **Displacement** — how far the walk reaches, measured in frames of motion. Higher reaches
    further along the arrows, so a longer smear piles up — the way a long run of "reused"
    frames drifts further from the last clean one. (This replaces the old "Streak length" dial;
    an older project's setting is read straight into it, so nothing changes on load.)
  - **Bloom** — how much of that reach actually accumulates. Turned down, only the nearest bit
    of the walk counts, so the trail is short and keeps resetting; turned up, the whole walk
    averages together into a long, drawn-out melt. It is the "does the smear pile up, or keep
    starting fresh" control.
  - **Reset interval** — an optional clock, in seconds, for the "clean frame" that a real codec
    inserts now and then. Leave it at zero and the melt just runs continuously. Set it, and the
    whole melt fades back to a clean picture at each tick and then builds up again until the
    next — the classic datamosh rhythm of clean, melt, melt, melt, clean. (It's in seconds
    rather than a frame count because, at the point in the pipeline where this is worked out,
    the effect doesn't know the project's frame rate; a frame-count version is a later job.) On
    top of that clock, a clean frame *also* happens by itself wherever there's no motion to
    follow — a still, or a hard cut — which is exactly where a codec would put one.

  It started life as a toggle inside Glitch, off by default, because turning it on means
  fetching an extra frame and running the motion-arrow calculation; when Glitch split into
  three separate effects it became its own, and T19 rebuilt its insides into the walk described
  above. One wrinkle worth knowing: the app can only carry one motion-arrow map per layer per
  frame right now, so if a layer somehow had both Motion blur and Datamosh turned on together,
  only whichever one is listed first in the effect stack gets its arrows this frame — the other
  quietly sits out, the same "missing data, do nothing" safety rule every temporal effect
  already follows.
- **Posterize time — the stop-motion "on twos" look, and a new kind of effect entirely.**
  Every effect so far takes a finished picture and paints on it. **Posterize time** does
  something different: it changes *what moment in time* the layers render at. Drop it on a
  full-frame adjustment layer, set a frame rate like 12, and the whole scene beneath updates
  only 12 times a second — the animation goes choppy and hand-made, the classic stop-motion
  look. The trick is simple arithmetic: the current time is rounded *down* to the nearest step
  on that coarser grid (so any moment between two steps shows the earlier one), and the scene
  below is re-rendered at that held moment. Because it re-renders rather than repaints, it
  cannot live where the other effects live (they only ever see a finished picture, not the
  layers or the clock). Instead it plugs in at the one place that holds the layers and the
  time — the render loop itself — and that place is the same in the preview and in an export,
  so they always agree (the whole point of the shared `render_below_at` helper: both the live
  viewer and the file are literally the same re-render code). Two honest details: the *video
  frame itself* also steps to the coarse grid (that was the FX-1 fix — a scene that is only
  footage playing back would otherwise look untouched, because only the animation was being held;
  now the app also picks the held moment's source frame, so playback visibly chunks along at, say,
  12 a second). Smoothing footage *between* those held frames — real motion blur on the streaks —
  is a different effect (the flow Motion blur); Posterize just quantises the playback grid. And a
  couple of exotic combinations (an echo *inside* the held part, or Posterize buried in a
  collapsed precomp) quietly do nothing rather than risk a wrong picture. There used to be a
  Scope switch choosing between "everything below" and "just this layer" — it is gone (K-166),
  because the layer you drop the effect on already answers the question: an *adjustment layer's*
  whole job is to affect everything beneath it, so Posterize there steps the whole scene; drop it
  on a *normal* layer and only that layer goes choppy — its effects and its footage playback
  step while the layer keeps *moving* smoothly. The per-layer form needs no re-render of the
  rest of the scene at all: the layer simply reads a "held" clock for its own effect stack and
  source frame while its position reads the live one. That is why it is the cheap, simple
  cousin of the whole-scene version.
- **"Don't re-sample this effect" — a per-effect opt-out for the choppy passes.** When
  Posterize time (and, soon, accumulation motion blur) re-renders the scene at a *different*
  moment, it normally re-runs everything at that moment. But some effects are expensive or
  random — a particle system, say — and you would not want them re-computed for every sample;
  it would look wrong and cost a fortune. So every effect now carries a quiet switch, **on** by
  default: leave it on and the effect moves in time with the rest of the scene; turn it **off**
  and that one effect stays frozen at the real playhead while everything around it is held or
  sampled. Behind the scenes this is just "which clock do I read?" per effect — with the switch
  on, both clocks read the same time, so an ordinary render (no posterise, no accumulation
  blur) is completely unaffected.
- **"Motion blur" — the expensive, correct motion blur (accumulation).** There are three kinds
  of motion blur in Lumit, and this is the heavyweight — the one simply called **Motion blur**
  in the menus. (The others: the per-layer transform *switch*, which smears one layer along its
  own movement, and **Fast motion blur**, which invents blur for game footage that never had
  any.) This kind does the honest, brute-force thing: it renders the *whole scene beneath it*
  several times at instants spread across a single frame — a few moments just before the frame,
  a few just after — and averages those finished pictures together. Because it re-renders the
  real scene each time, everything comes out right: moving footage, animated effects, a depth
  pass, the camera drifting — all correctly placed at each instant, then blended. The averaging
  is a neat trick with light: each of the N pictures is added in at one-Nth strength, so a part
  of the scene that didn't move averages back to exactly itself (nothing changes when nothing
  moves — a promise the tests check to the last bit), while anything that *did* move leaves a
  smear proportional to how far it travelled. You drop it on a full-frame adjustment layer to
  blur the whole scene; the Shutter angle sets how much of the frame the "camera" was open
  (180° is the film-standard half-frame), Samples sets how many in-between renders (more is
  smoother and slower — it is genuinely N times the work), and Mix fades the blur back toward
  the sharp original. There is also a **Force on all layers** switch: turn it on and every layer
  also smears along its *own* transform inside each of those in-between renders (the per-layer
  motion blur, forced on for the whole scene at once, using this effect's shutter — your project
  is never actually changed, only the temporary render is). It is a convenience — one switch
  instead of ticking motion blur on every layer — and it smooths the result at lower sample
  counts. It shares the very same re-render machinery as Posterize, so the preview and the
  exported file are, again, literally the same code.
- **Depth of field becomes a real effect — and effects can now read another layer.** Until
  now every effect took numbers, colours, a file. Depth of field needs a *second picture*: a
  "depth map" that says how far away each pixel is. The natural place to get one is **another
  layer** in your composition — a depth pass that matches your footage. So effects gained a
  new kind of control: a **layer reference**, "use *that* layer as my input." It works just
  like a **matte** (which already lets one layer point at another and borrow its shape): the
  app renders the pointed-at layer on its own and hands its picture to the effect. Depth of
  field reads the **red channel** of that picture as depth (dark = near, bright = far, though
  since you choose the focus distance it works either way), and blurs the footage more the
  farther a pixel's depth sits from focus. Two things are worth knowing. First, the depth
  layer is rendered *plainly* — its own effects are not applied — which, as a happy side
  effect, means a depth reference can never chase its own tail into an endless loop. Second,
  the picture you see while scrubbing and the picture you export go through the **one and the
  same** "render that layer on its own" helper, so the preview can never quietly disagree with
  the file (the house rule every effect follows). For now the depth pass should share your
  footage's framing (it is stretched to fit) and should be a *visible* layer; a depth built
  from effects, or hidden away, is a later refinement. The blur disc itself is the foundation
  kernel below, unchanged and still proven against its plain-Rust twin. One more piece the
  owner will add: the little dropdown in the effect controls that actually *picks* the depth
  layer — until that lands the effect is wired and correct but has no layer to point at yet.
- **Depth of field grows three lens controls.** Three tick-and-slide additions, all borrowed
  from the reference plugins. **Depth invert** is a tickbox that flips the depth map's reading
  (`near` becomes `far` and back), so if your depth pass is the wrong way round you fix it with
  one click instead of re-rendering it. **Near blur** and **Far blur** let you set *how much*
  blur the close side and the far side get *separately* — a shallow foreground and a soft
  distance, or the reverse — where before both sides shared one Aperture. Aperture now acts as a
  **master**: it scales both sides together (its normal value, 8, means "leave Near and Far as
  they are"), and turning it up or down blurs the whole picture more or less without touching the
  balance between the two. Old projects saved before this — which only had the one Aperture —
  open and look exactly the same, because Near and Far quietly start out matching it. **Display**
  is a small dropdown of *what you're looking at*: normally **Rendered** (the finished blur), but
  switch to **Depth map** to see the depth pass itself as a greyscale picture (handy for checking
  it is the right way round), or **Focus map** to see a white-where-sharp mask that shows exactly
  which parts of the frame are in focus. The two diagnostic views ignore the blur so you get a
  clean look. As always, the graphics-card program and its plain-Rust twin were checked to agree
  to the last bit across every one of these — invert on and off, lopsided near/far, and each
  display mode.
- **Depth-of-field, the foundation** — the first piece of a "lens blur" that keeps one
  distance sharp and softens everything nearer and farther, the way a real camera lens does.
  A photographic lens can only focus at one distance at a time; things off that plane spread
  each point of light into a little disc — the bigger the disc, the blurrier it looks — and
  the disc's size is called the *circle of confusion*. This kernel does exactly that: for
  every pixel it looks up how *deep* that pixel is (a plain 0-to-1 "depth map", near to far),
  works out how far that depth sits from the chosen focus distance, and from that picks a
  blur-disc size — nothing at all inside a sharp band around focus (set by Focus distance and
  Focus range), then easing up to a maximum (Aperture, the biggest disc in pixels) for the
  most out-of-focus depths. It then averages a disc of the source image that size around the
  pixel, so near-focus areas stay crisp and distant ones melt. Two honest limitations for
  now, and they are the whole reason this landed as a *foundation* rather than a finished
  effect: first, nothing in Lumit yet produces a real depth map — a proper version needs to
  read depth from another layer, which is a much larger plumbing change (the same kind Motion
  blur's motion-map needed), so for the moment the depth is something a test or a future
  source hands in; second, the bokeh is a plain flat disc, not the shaped, bright-rimmed
  highlights the eventual "DOF PRO" effect will add. What *is* finished and locked by a test
  is the maths: the graphics-card program and a plain-Rust copy of it compute byte-for-byte
  the same disc, tap for tap, so — exactly like every other effect — what the card draws
  provably matches the reference, and a zero Aperture (or a subject sitting right on the
  focus plane) leaves the picture untouched to the last bit.
- **Blur gains a Radial mode** — the third and final mode of the §3.8 trio, alongside
  Gaussian and Directional. Drop a Centre point anywhere on the frame (as two percentages,
  Centre X and Centre Y, of the frame's width and height) and pick a Type: **Spin** streaks
  every pixel along the arc it would trace if the frame span rotating about that point;
  **Zoom** streaks it along the straight line from the centre through it instead, like a
  camera punching in. Either way the streak grows the farther a pixel sits from Centre —
  right at Centre nothing moves at all, and the effect gets stronger toward the edges,
  reaching its full length (set by Amount, in the same "% of frame diagonal" units Radius
  and Length already use) at the frame's farthest corner. The clever bit is *how* those two
  streak directions get computed: rather than actually rotating anything (which needs
  trigonometry, and GPU trigonometry is allowed to be slightly imprecise — the same reason
  Transform's matrix arrives pre-computed from the CPU), both Spin and Zoom turn out to be
  nothing more than stretching the vector from Centre to the pixel by a plain number — along
  that vector for Zoom, sideways from it for Spin. No division, no sine or cosine anywhere,
  and — as a free bonus — every stretch is exactly zero at Centre itself, so there is no
  special case to write for "what happens exactly at the middle". Sideways-instead-of-rotated
  is a deliberate simplification (a straight sideways nudge closely matches a true curved arc
  for the modest sweep this effect targets) and is written down as a pinned choice in docs/08
  §3.8, alongside the other numbers the spec didn't pin down itself (the exact ranges and
  defaults for Centre and Amount). Old projects saved before Radial existed still read as
  Gaussian, byte for byte, and Amount 0 is an exact passthrough — both pinned by tests.
- **Blur becomes three separate effects** (the house rule: one effect, one job). Until now
  "Blur" was a single effect with a Mode dropdown — Gaussian, Directional or Radial — and all
  three modes' controls sat on it at once, most of them greyed-out and irrelevant depending on
  the mode. Now there are three effects you pick from the Add-effect menu directly — **Gaussian
  blur**, **Directional blur** and **Radial blur** — each showing only its own controls. Nothing
  about *how* each blur looks changed: the actual blur programs and their reference twins are
  the exact same code, only the menu and the little bit of glue that reads the controls moved.
  A few knock-on tidyings came with the split. The old effect had one **Edges** control
  (Transparent / Repeat / Mirror — what to pretend is beyond the frame's edge) shared by all
  three modes; it now lives **only on Radial blur**, where a spin or zoom most often sweeps past
  the border and you might want it to mirror or fade. Gaussian and Directional just use the old
  default (Repeat, which keeps full-frame footage from darkening at the edges), so they look
  identical. Directional's **Length** and Radial's **Amount** can now go past their old ceilings
  (bigger sliders, and you can type further still) since each is its own effect and no longer
  has to share one budget — the programs already cap how much work a huge value can ask for, so
  there's no runaway cost. And projects saved with the old combined Blur still open fine:
  whatever mode they were on, they come back as a Gaussian blur at the same radius (the effect
  kept its internal name, `blur`), which is the sensible common case.
- **Sharpen splits into "Unsharp mask" and a plain "Sharpen".** The effect that was called
  Sharpen was, under the hood, an *unsharp mask* — the photographer's technique of blurring a
  copy, subtracting it to find the fine detail, and adding that detail back, with knobs for how
  wide the detail is (Radius), how strong (Amount), a Threshold to leave flat areas alone, and a
  luminance-only option. That is still here, just honestly relabelled **Unsharp mask** (its
  internal name is unchanged, so nothing saved breaks). Sitting beside it is now a brand-new,
  much simpler **Sharpen**: a plain 3×3 sharpen — the classic one every image editor has — that
  looks at each pixel and its four immediate neighbours and pushes the pixel away from their
  average, with a single **Amount** dial for how hard (1 is the textbook strength, 0 does
  nothing). No radius, no threshold — just "sharpen it a bit". It works on the true colour
  (dividing out transparency first, like the other colour effects, so edges of a cut-out don't
  fringe), and turning Amount or Mix to zero leaves the picture untouched to the last bit. As
  always, the graphics-card version and a plain-Rust copy were checked to agree pixel-for-pixel.
- **Flash fires on the beat.** The Flash effect's Mode switch now has three positions.
  *Manual* is exactly the old behaviour — keyframed hits with an exponential fade — and
  stays the default, so nothing saved earlier changes by a single byte. *Trigger* lights
  the flash from the comp's beat markers themselves: on each beat the envelope jumps to
  full, then either cuts off after Duration frames (Shape: Hard) or ramps linearly to
  zero across them (Shape: Fade); Phase offset slides every hit earlier or later by
  whole frames. *Strobe* is Trigger that counts: only every Nth beat fires, which is how
  "flash on the kick, not the hi-hat" works when the detector marked both. All of this
  is worked out on the CPU while parameters resolve — the GPU kernel still receives one
  strength number, untouched, so the existing Flash oracle passes as it was. The frame
  cache learned the matching lesson in the same commit: a beat-driven flash's cache key
  now includes the frame's local time and the small window of triggers its envelope
  actually reads, so nudging a distant marker never re-renders frames it cannot affect,
  while a Manual-mode flash keeps its time-free keys.
- **Beat markers reach the effects engine** (the docs/08 §1.4 plumbing). When a layer's
  effect stack is resolved for a frame, it now receives a small *marker context*: the
  comp's beat-marker times, each translated into the layer's own clock (a layer that
  starts three seconds into the comp sees a beat at comp second five as “two seconds
  in”), plus the comp's frame rate so parameters authored in frames can become seconds.
  Nothing draws differently yet — this is the wiring the beat-driven effect modes
  (Flash first) plug into. Two details matter: the context is built by one shared
  constructor that preview and export both call, so the two can never disagree about
  where a beat falls (the K-031 promise); and a caller with no markers passes an
  obvious empty context, because a marker-driven effect must always degrade to doing
  nothing rather than misbehaving — a project with no music still renders.
- **Shake.** The beatshake workhorse: a virtual camera wobble. The layer is resampled
  once through the same kernel the Transform effect uses — never pixel noise — so the
  whole frame sways as one. The wobble comes from *seeded value noise*: a deterministic
  recipe that turns (seed, time) into a smooth wander between −1 and 1, so the same
  project shakes identically on every machine and every run — there is no real
  randomness anywhere, only maths that looks random (the engine's seeded-and-stateless
  rule). Amplitude sets how far it roams (as % of the comp diagonal), Frequency how
  fast, Rotation amount how much twist. A **Per-axis wobble** twirl (a collapsible
  sub-section, see below) tucks the finer controls away: X and Y amount/frequency let you
  bias each axis (they multiply the master values, so leaving them at 1 gives the plain
  even shake), and Z is a depth shake — the frame pumps a little bigger and smaller, the
  old "zoom pump" renamed. When the wobble drags the frame's edge into view, the **Edges**
  control decides what shows there: Transparent (a clear border), Repeat (the edge pixel
  held outward) or Mirror (the picture reflected) — the same three choices the blur effects
  offer (see "Edges control" below). This replaced an older Auto-scale toggle that quietly
  zoomed in to hide the border; a project saved before the change carries its old zoom-pump
  and auto-scale settings across automatically (auto-scale on becomes Repeat, off becomes
  Transparent). Seed is a new parameter type: an integer picking *which* wander you get —
  each new instance rolls its own so two shaken layers never move in sync, and the Reseed
  button rolls a fresh one. Shake also taught the frame cache a lesson: its parameters can
  sit constant while the picture moves every frame, so for effects that declare seeded
  randomness the cache key now includes the layer's local time — without that, a shaken
  solid would replay its first cached frame forever. A second twirl, **Motion blur**, gives
  the shake *its own* motion blur (separate from the layer and comp motion blur, and touching
  only this effect). Because the wobble is pure maths of time, the engine can ask "where was
  the shake a moment before, and a moment after this frame" and draw the picture at several of
  those in-between positions, then average them — so a fast shake smears along its own path
  instead of snapping frame to frame, the way a real camera blurs when it jolts. It is off by
  default; the **Shutter** dial (0 to 1) sets how long that smear is, and 0 (or the toggle
  off) is exactly the plain, un-blurred shake. The in-between positions are worked out on the
  CPU because the noise recipe needs 64-bit whole numbers the graphics card cannot do, then a
  small dedicated GPU program does the averaging. The smear's length is measured in the
  shake's own rhythm rather than in seconds, so it looks the same whether your project runs at
  30 or 60 frames a second (K-165).
- **Edges control (a shared effect building block).** Several effects move pixels around —
  a blur that smears sideways, a shake that slides the whole frame — and wherever the
  picture shifts, it can pull in area from *outside* the layer that has no pixels of its
  own. The Edges control names what to put there, with three settings shared by every
  effect that needs them: **Transparent** (leave it clear), **Repeat** (stretch the very
  edge pixel outward, so full-screen footage never grows a dark border) and **Mirror**
  (reflect the picture back on itself). It is one small reusable piece rather than each
  effect inventing its own, so it behaves identically everywhere it appears (in code it is
  a shared `EdgesMode` with three fixed options).
- **Collapsible "twirl" sub-sections in effect controls.** An effect's parameter list can
  hide its advanced controls behind a disclosure triangle — a little header you click to
  fold a group open or shut, exactly like twirling a layer open in the timeline. Shake's
  "Per-axis wobble" is the first: the everyday knobs (Amplitude, Frequency, Rotation) stay
  in plain view, and the per-axis fine-tuning tucks away until you want it. Any effect can
  ask for one just by declaring the group in its parameter schema — it is a reusable piece
  of the effect-controls panel, not something written afresh each time.
- **Glow.** The montage bloom: anything brighter than Threshold spills light. The
  pipeline is three steps — keep only the light *above* the threshold (with Knee
  easing the cut so it doesn't snap on), blur that leftover wide (Radius, measured
  like Blur's), then add it back on top, scaled by Intensity and coloured by Tint.
  Because Lumit works in scene-linear light, an HDR value of 4 has four times the
  energy of white and blooms accordingly — which is why Threshold is the first
  parameter with a *one-sided* hard range (design rule K-090): it clamps at zero
  below but you can type any value above the slider's 4, because HDR pixels really
  do sit up there. The halo carries alpha too: glow blooming past a layer's edge
  raises coverage there, so the spill reads as light over transparency instead of
  stopping dead at the matte. At Intensity 0 the effect passes pixels through
  bit-exactly — a test pins that promise.
- **RGB split gains a Wavelength mode** (K-090's quality-tier pattern: where the smooth
  look is optional, it hides behind a Bool next to the fast one). Off — the default —
  the split is three tinted samples: the first colour pulled one way, the third the
  other, the second in place. On, the kernel instead takes many samples (up to 64)
  spread along the same line and tints each by your three-colour picker blended into a
  smooth gradient — the first colour at one end, the second in the middle, the third at
  the other end (A1/K-163). So the fringe is a smooth graded band you control by colour,
  and the default red / green / blue gives the familiar red→green→blue dispersion.
  (Earlier this used a fixed physical spectrum table; the owner chose to let the picker
  drive it instead, so changing the colours changes the fringe.) The gradient is worked
  out once in `lumit-core` next to the CPU reference and handed to the GPU kernel through
  its parameter block, so both paths read literally the same numbers (the same trick as
  the host-computed sines). Its columns are normalised so a flat image passes through
  unchanged — the fringe is tinted, not the exposure — and alpha still refuses to move,
  so mattes never grow coloured rims in either mode. The classic three-tap mode now gets
  the *same* normalisation (K-167): because the three taps are simply added together,
  custom tints used to brighten or darken the whole picture, not just the fringe — each
  output channel's three weights are now rescaled to add up to one before the kernel sees
  them, so recolouring the split only recolours the parts where the taps disagree (the
  misaligned edges), and the default red / green / blue is untouched to the bit.
- **The Transform effect** (K-090, replacing the dropped smooth-zoom idea) is the layer
  transform group — Anchor, Position, Scale, Rotation, Opacity, same names and units —
  packaged as a stack effect. Why would you want a second transform? *Adjustment
  layers.* An adjustment layer's effects apply to the composite of everything below
  it, so a Transform effect on one is the montage punch-in or whip-pan gesture over
  the whole frame at once, without touching any individual layer's own transform.
  Under the hood it works backwards: for each output pixel the kernel asks "which
  input point would the forward transform have moved *here*?" (the inverse affine),
  takes one bilinear sample there, and shows transparent for anything that maps
  outside the frame. The matrix arrives pre-computed from the CPU (GPU trigonometry
  is allowed to be sloppy; ours must match the reference bit-for-bit), and at default
  parameters the effect is a *bit-exact* passthrough — a test pins that promise. A
  zero scale collapses the image to fully transparent rather than dividing by zero —
  engine code never faults. Its Anchor and Position are measured in comp pixels, so
  the resolver now carries the preview-resolution factor as well as the diagonal:
  half-resolution preview frames exactly like full, only softer (design rule §2.3).
- **Blur grows a Directional mode.** The Blur effect now has a Mode switch: *Gaussian*
  (the soft circular blur it has always been) or *Directional* — a streak along an
  angle, the speed-line look. Under the hood directional blur is a *line integral*:
  for each pixel, the kernel walks a short line through it (Length long, pointing
  along Angle), samples the image at evenly spaced points on that line, and averages
  them — as if the image slid past an open shutter in that direction. The two modes
  are separate GPU programs, so adding Directional changed nothing about Gaussian:
  the original blur maths, and the test that pins them to the CPU reference, are
  byte-for-byte what they were. Old projects saved before the switch existed simply
  read as Gaussian. (The third §3.8 mode, Radial spin/zoom, is still to come.)
- **Grade splits into Colour balance and Saturation** (K-090's one-thing rule: an
  effect does one job, so the young all-in-one Grade became two Colour-category
  effects; a deliberate all-in-one grading suite may return much later, but
  single-purpose is the default shape). **Colour balance** is lift / gamma / gain per
  channel — the trackball grammar every colourist tool shares. *Gain* multiplies
  (brightens everything proportionally), *lift* adds (raises the blacks — or crushes
  them, negative values are allowed), *gamma* bends the mid-tones without moving black
  or white. Each is a colour parameter, so warming the shadows while cooling the
  highlights is just different numbers per channel. **Saturation** does exactly one
  thing: it pivots colourfulness around proper Rec. 709 luma, so desaturating gives
  true greyscale, not the grey-green mush of naive averaging. The same two design
  rules shape both: they grade *unpremultiplied* colour (same reason as Sharpen —
  grading premultiplied pixels shifts matte edges), and they never clip highlights — a
  gain of 2 on an HDR value of 4 gives 8, and whatever glow comes later gets all of
  it. Neutral settings now short-circuit the *whole effect*: at defaults each passes
  pixels through bit-for-bit untouched (and there's a test holding it to that) rather
  than rounding them through power curves. The rest of §3.10 — exposure, white
  balance, curves, vignette, and the Looks-style preset browser — arrives as further
  single-purpose colour effects.
- **Vibrancy** (K-152) is Saturation's smarter cousin. Saturation scales *every* pixel's
  colourfulness by the same amount, so pushing it hard blows out the colours that were
  already strong (and turns skin an unnatural orange). Vibrancy looks at how colourful
  each pixel already is and lifts the dull ones more than the vivid ones — near-greys and
  skin tones come alive while the saturated bits are left roughly alone, so nothing
  clips. It has one **Amount** dial (0 does nothing; turn it up to taste, and it happily
  goes past 100). Same careful plumbing as Saturation — it works on unpremultiplied
  colour in linear light, pivots about proper luma, and never goes negative — with a GPU
  test holding it exactly to the CPU reference.
- **Flash.** The beat-strobe, in its manual form until beat markers exist. Its Trigger
  parameter reads unusually on purpose: *each keyframe is a hit*. Drop a keyframe with
  value 1 on a kick drum and the frame flashes to the flash colour, then fades out
  exponentially over Decay milliseconds — you author one keyframe per beat, not a
  spike-and-fall pair. (When the audio engine starts producing beat markers, they'll
  drive the same envelope automatically — that's why the effect declares "marker input:
  beat" in its traits already.) The flash respects the layer's own transparency: pixels
  outside the footprint never light up, so flashing a masked layer flashes the masked
  shape, not the whole rectangle. Flash also introduced the **colour parameter**: an
  effect can now declare a scene-linear RGBA colour (the Flash tint defaults to white),
  which the Effects group shows as R/G/B number fields plus a live swatch. Linear values
  above 1 are legal — a "4.0 white" flash carries real HDR energy into any glow that
  follows it in the stack.
- **RGB split.** The impact-frame staple: the red and blue channels slide apart while
  green stays put, like a lens fringing under stress. Keyframe a spike on Amount at a
  hit and you have the genre's signature punch. Two modes: *linear* shifts everything
  one way (set by Angle), *radial* grows the shift from the centre outward, like real
  lens aberration. Two details matter in the code: alpha stays glued to the green
  channel (if it moved with red or blue, every matte edge would grow a coloured rim —
  design rule §3.6), and the sines behind the shift direction are computed once on the
  CPU and handed to the GPU, because GPU trigonometry is allowed to be slightly
  imprecise and the CPU-vs-GPU agreement test demands better.
  *Two later additions (FX-9):* **per-channel amounts** — three sliders (Red / Green /
  Blue, defaults 100 / 0 / 100 per cent) that scale each channel's own shift, so you can
  fringe red harder than blue, or nudge green too; the defaults are exactly the classic
  split. And in **Wavelength** mode there is now a **Samples** knob: that mode makes a smooth
  graded fringe by taking many samples along the shift and tinting each from your three-colour
  picker's gradient (A1/K-163), and at big shifts too few samples showed a handful of separate
  copies — Samples (default 16, up to 64) fills the gap so it reads as a smooth band. The samples
  are worked out once on the CPU and handed to the GPU, the same trick as the sines, so preview
  and export agree to the last bit.
- **The reusable three-colour channel picker.** Some effects split a picture into three
  tinted channels; **Chromatic aberration** (below) is the first. Rather than three separate
  colour rows, those effects show one tidy row of three swatches (defaults red / green /
  blue) — click a swatch to open the colour picker. It is one small shared widget: any
  effect whose parameter list names three colours `channel_colour_1/2/3` gets the picker
  automatically, so the next such effect needs no new interface code. Chromatic aberration's
  three swatches tint its three taps, and leaving them red / green / blue gives the ordinary
  R-outward / B-inward / green-anchored fringe; recolour them for a stylised split.
- **Sharpen.** The second effect in the catalogue, following Blur's four-part template.
  It's an *unsharp mask* — the counter-intuitive classic: blur a copy of the image,
  subtract it from the original (what's left is the fine detail), then add that detail
  back on top, scaled by Amount. Two subtleties earn comments in the code. First, it
  works on **unpremultiplied** colour (design rule §2.2): footage with transparency
  stores its colours pre-multiplied by alpha, and sharpening those values directly would
  draw halos around every matte edge — so the kernel divides alpha out, sharpens, and
  multiplies it back in. Second, **Threshold** is a *soft* gate: detail weaker than the
  threshold (compression noise, mostly) is ignored, but rather than a hard on/off — which
  would leave visible contours where detail crosses the line — the gate shaves the
  threshold off everything, so the transition is seamless. "Luminance only" (the default)
  sharpens the brightness signal and leaves colour alone, because sharpening the colour
  channels of compressed game capture produces rainbow fringes.
- **Flow is a layer option** (K-088) — the wind toggle in a footage layer's switch
  cluster. On, it synthesises in-between frames with optical flow wherever the footage's
  rate (through any retime) undershoots the comp's — the moment a source frame would sit
  across two comp frames, flow takes over; footage already at comp rate costs nothing. A
  **Flow** group appears beside Transform and Effects with the engine's knobs (Quality:
  half-resolution fields, the fast default, or full). Under the hood it's the retime's
  frame-interpolation policy — an un-retimed layer quietly gains an identity retime to
  carry it, and loses it again when you switch off.
- **Effects are usable end to end.** Twirl a layer open, open its **Effects** group,
  and "Add effect" lists the catalogue. Each effect shows a bypass
  tick, a remove button, and one row per parameter — a Blur radius has a stopwatch
  and lane diamonds exactly like Position does, so effect animation and layer
  animation are one skill. The same stack renders in preview and in export through
  the same GPU passes, and cached frames re-render themselves when a parameter
  moves (the cache key already understood effects).
- **Dragging an effect on works too (K-101).** You don't have to open the "Add
  effect" menu: drag an entry straight out of the Effects & Presets browser and drop
  it on a footage or adjustment layer's row in the Timeline — the row outlines while
  you hover, and letting go appends the effect exactly as if you'd picked it from
  that layer's own menu, one undo step either way.
- **The one-slot drag rule**, worth knowing wherever drag-and-drop is written. If the
  toolkit carries exactly one "thing being dragged" for the whole app — a single hand
  holding one object — then a drop zone that asks "was that released on me?" may be
  handed the object *before* anything checks it is the kind that zone wanted, and a
  zone that shrugs at the wrong kind has already consumed it. Overlapping zones then
  eat each other's drops silently: the wide zone underneath asks first and discards
  what the row on top was waiting for. **Every drop zone must peek at the kind before
  taking the drop**, through one shared reader rather than each zone deciding for
  itself.
- **Effects, the pixel side.** The first real effect exists end to end: **Blur**
  (gaussian). Its life is the template every effect will follow (design rule §1.1's four
  parts): a catalogue entry in `lumit-core/src/fx.rs` declaring parameters and behaviour
  traits; a plain-Rust reference implementation there too (the *oracle* — slow but
  unarguably correct); a GPU program (`lumit-gpu/src/fx_blur.wgsl`) that does the same
  maths fast; and a test that renders a nasty little corpus (gradients, hard alpha edges,
  a brighter-than-white spike) through both and fails if they ever disagree. The radius is
  measured as a percentage of the comp's diagonal, so half-resolution preview looks the
  same as full — just smaller.
- **Effects, the data side (Phase 3 begins here).** Every layer now carries an ordered
  **effect stack** in the project model: each entry says *which* effect (a stable name +
  a version, so cached frames from older maths retire themselves), whether it's bypassed,
  and its parameters — which are real animatable properties like Position or Opacity, so
  keyframes and the graph editor work on a Glow radius exactly as they do on a scale. A
  layer-level **fx switch** mutes the whole stack. Edits go through ops (one op replaces the
  stack — add, remove, reorder and parameter changes are all undoable in one step), and the
  cache knows a live effect changes pixels while a bypassed one doesn't. The registry (a
  growing built-in catalogue — blur, sharpen, RGB split, glow, shake, colour balance and
  more, grouped by category), the GPU passes, and adjustment-layer staging (K-091) all run
  for real now, and the dedicated **Effect Controls** dock panel shows the selected layer's
  effect stack in a roomier home than the Timeline row — the same rows, the same undo, just
  reusing the Timeline's stack editor rather than being a second, divergent one. You can
  still edit the stack inline on the layer's own row in the Timeline; the panel is the same
  editor given more room. Saving a stack as a **preset** and loading one back (a small
  `.lumfx` JSON file, K-065) lives on that same add-effect row. **A preset library (K-129)**
  gives those saved looks a browsable home: the **Effects & Presets** panel now opens with a
  **Presets** group listing every `.lumfx` file in one shared folder (tucked away in Windows'
  roaming app-data area, next to Lumit's other saved data). Click a preset and its whole
  saved stack is added to the layer you have selected — one undo step, exactly as loading a
  preset by hand does. "Save stack as preset…" now points its save box at that same folder to
  begin with, so anything you save shows up in the list straight away; you can still save it
  elsewhere if you want. An empty folder just shows a gentle hint rather than an error.
  **A preset now saves whatever you have highlighted, not always the whole stack (UI-10,
  K-156).** Highlight one or more effects and it saves just those, with their settings as they
  stand; pick out specific keyframes on the lanes and it saves only those keys (the rest of the
  animation, and any effect you did not touch, is left out). Highlight nothing and it still saves
  the whole stack, as before — so the old behaviour is one click away when you want it.
  **Dragging an effect's value
  updates the Viewer live** — as you drag a Glow radius or a Blur amount, the picture re-runs
  the effect with the value under your cursor every frame, committing once when you let go (so
  a whole drag is one undo step). It reuses the same trick a transform-value drag already uses:
  the retained frame is re-composited with the provisional value patched in, no re-decode.
- **Two more single-frame effects (K-099).** **Vignette** darkens the frame toward black
  away from the centre (Amount/Radius/Softness/Roundness); **Chromatic aberration** fringes
  red and blue outward/inward from the centre by a set number of pixels — a simpler,
  always-on-the-corner sibling of RGB split's own Radial mode, for the common one-click case.
  It later grew two matching extras (K-143/K-144): the **three-colour channel picker** (recolour
  the three tinted taps; leaving them red / green / blue is the ordinary fringe) and RGB split's
  own **Wavelength/Samples** rainbow mode, reusing the very same spectral machinery.
- **Exposure (K-106).** The one-knob brightness lever, measured in photographic *stops* —
  each +1 doubles the light, −1 halves it. It is a straight multiply on the colour (done in
  the scene-linear light the compositor works in, so it behaves like a real camera exposure,
  not a washed-out lift), with 0 stops leaving the picture exactly untouched. Distinct from
  Colour balance's three-channel gain: a single animatable control for the whole image.
- **Hue shift (K-108, K-136).** Turn every colour's hue by an angle — reds toward orange,
  blues toward purple, and so on. 0° leaves the picture exactly as it was. Under the hood it is
  a small fixed colour-mixing matrix worked out once for the angle, so the preview and the
  export apply the identical numbers. A **Preserve luminance** tick (on by default) chooses how
  it turns:
  - **On** keeps how *bright* each colour looks unchanged as its hue moves — a
    "constant-luminance" rotation, the same maths web browsers use for their hue-rotate filter.
    This weights the calculation by how bright the eye finds each channel (green counts far more
    than blue).
  - **Off** does the plainer thing: it spins the red/green/blue values around like a colour
    wheel with every channel weighted equally. That can *change* how bright a colour looks as
    its hue turns (a green may go duller or brighter), which is sometimes exactly the punchy,
    less-careful look you want.

  A word on this and Oklab. Lumit's rule of thumb (K-034) is that hue-type work belongs in
  Oklab, the perceptual colour space where "keep the brightness, change the hue" is natural.
  Hue shift's preserve-luminance mode is that *idea* — hold brightness, turn the hue — but it
  reaches it with a cheaper Rec.709-weighted spin in ordinary linear RGB rather than a full
  Oklab conversion, which is plenty for a hue wheel and keeps the CPU and GPU trivially
  matched. The preserve-luminance-**off** mode is the honest "just spin the RGB numbers"
  version, weights and brightness-shifts and all.
- **Contrast (K-110).** The familiar contrast slider: push everything further from a middle
  grey (brights brighter, darks darker) or pull it toward that grey to flatten the image.
  100 % leaves the picture exactly as it was; below 100 % flattens, above 100 % punches. The
  middle grey it pivots around is a plain 50 %, like a photo editor's contrast control. One
  subtlety worth knowing: because it *shifts* colours toward or away from a fixed point rather
  than simply scaling them, it has to be done on the "straight" colour of a semi-transparent
  pixel — Lumit briefly divides the alpha back out, applies the contrast, then multiplies it
  back in, so soft edges keep their shape instead of fringing. Exposure does not need that
  step because a plain multiply already behaves the same with or without the alpha folded in.
- **Gamma (K-112).** A brightness curve for the mid-tones: it leaves pure black and
  pure white where they are but bends everything in between. A Gamma above 1 lifts the middle
  (a brighter, flatter look); below 1 pushes it down (darker, punchier). It is the classic
  "gamma" slider, where the number behaves like a monitor's gamma. Like Contrast it works on the
  "straight" colour of a semi-transparent pixel (Lumit divides the alpha out, curves, then
  multiplies it back in), so soft edges keep their shape. One safety detail: colours in the
  compositor's light space can dip a hair below zero, and raising a negative number to a power is
  meaningless, so Lumit nudges any such value up to zero before curving — done identically on the
  preview and the export, so the two never disagree. A Gamma of 1 leaves the picture exactly as
  it was.
- **Temperature (K-113).** The warm/cool slider: drag it positive to warm the picture (more
  red, less blue) or negative to cool it (more blue, less red), with green left alone. It is
  a plain per-channel multiply — red and blue each get their own gain worked out once from the
  slider (at +100, red is boosted by half and blue cut by half; 0 leaves the picture exactly
  as it was) — so, like Exposure, it needs no alpha round trip and semi-transparent edges stay
  clean. This is the quick one-knob warmth move, not a full colour-science white balance (that
  fuller version, which shifts the picture along real colour-temperature lines and adds a
  green/magenta Tint axis, is a later Tier-2 job); it is the everyday "make it feel warmer"
  control, and it animates like every other grade.
- **Matte key — greenscreen removal (K-154).** Drop this on green-screen footage and it makes
  the green vanish, leaving whatever was shot in front of it on a clean transparent background.
  It is modelled on the professional keyer *Keylight*: you tell it the **Screen colour** (a
  green by default, so it works the moment you add it — but its brightest channel decides the
  screen, so a blue screen keys just as well), and it measures each pixel's screen colour
  against the two *other* colours to decide how much is screen and how much is subject. The
  top-level dials are the ones you reach for first. **Screen gain** is the overall strength —
  turn it up if patches of green survive, down if the foreground starts thinning. **Screen
  balance** decides how the two non-screen channels are combined into the reference the screen
  is measured against; the middle setting suits most shots, and nudging it either way rescues
  awkward tints. **Despill amount** tackles the green *spill* a bright screen throws onto the
  subject's edges — it drains that green back out so shoulders and hair don't glow green
  against the new background. Two colour swatches, **Despill bias** and **Alpha bias**, let you
  tell the keyer what should count as "neutral" for the spill and for the matte respectively;
  left grey they do nothing, which is the usual starting point.
  - The **View** menu at the top is how you *see* what you are keying: **Final result** is the
    finished cut-out, **Screen matte** shows the transparency itself as a black-and-white image
    (white stays, black goes) so you can spot holes and grey patches, and **Status** tints the
    uncertain in-between areas so problem edges jump out.
  - The **Screen matte** twirl holds the clean-up controls. **Clip black** forces the nearly
    transparent parts fully transparent (killing background haze), **Clip white** forces the
    nearly solid parts fully solid (filling pinholes in the subject), and **Clip rollback**
    eases those two back off a touch to win back fine detail like stray hairs. **Replace
    method** (with its **Replace colour**) decides what colour fills the de-spilled edges —
    *Soft colour*, the default, tints them with the replace colour scaled to the edge's own
    brightness so it settles in naturally; *Hard colour* uses it flat; *Source* keeps the
    original edge colour; *None* leaves the plainly de-spilled colour.
  - Two design points worth knowing: every step is a *gradual blend* rather than a hard on/off
    switch (a hard switch would make the CPU and graphics-card versions disagree by a hair,
    which the agreement test forbids — same rule as everywhere else), and like the other colour
    tools it works on the picture's *straight* colours, undoing the alpha pre-multiply first, so
    it judges edge pixels by their true colour and doesn't leave a fringe. Any of the colour
    swatches can be set with the **eyedropper** beside it, sampling straight from the Viewer
    (see the colour picker and eyedropper note below). A project made before this expansion
    keeps its old screen colour and spill amount and simply re-keys with the new controls at
    their defaults. Some further Keylight refinements — blurring and shrinking the matte,
    garbage masks, per-region colour correction and edge crops — are noted for a later pass.
- **Invert (K-126).** The classic negative: every colour flips to its opposite — black becomes
  white, blue becomes orange, and so on (each channel is replaced by "one minus itself"). There
  are no dials except the shared **Mix**, so it always inverts; turn Mix down to blend the
  negative part-way back toward the original. Like Contrast and Gamma it works on the picture's
  *straight* colours (Lumit divides the alpha out, inverts, folds it back in) so soft edges don't
  fringe. It flips in the compositor's own light space, which keeps it simple and truthful — very
  bright (above-white) values honestly flip to negatives rather than being clipped, exactly as the
  owner asked for a "simple inverse".
- **Tint (K-127).** A two-colour recolour that keeps the *brightness* of the picture but swaps
  its *palette*. You pick two colours — **Map black to** and **Map white to** — and Lumit reads
  each pixel's brightness and places it on the gradient between those two: the darkest parts take
  the first colour, the brightest take the second, everything in between blends across. Left at its
  defaults (black→black, white→white) it turns the image black-and-white; set the two colours to,
  say, deep teal and warm cream and you get a duotone poster look while the shading of the original
  is preserved. Like the other colour tools it works on the straight colour under the alpha so
  edges stay clean, and **Mix** dials the whole effect in or out.
- **Layer-input source: None / Masks / Effects and masks (K-142, was K-125).** Some tools read
  a **second layer** for their shape or data: a **track matte** borrows another layer's brightness
  or transparency to decide where the layer below shows through, and **Depth of field** reads a
  **depth pass** layer to know how far each pixel is. For both, a little **Source** combobox sits
  beside the layer picker and decides *how much* of that other layer to read:
  - **None** — its **raw picture** only: no masks, no effects. The plainest input.
  - **Masks** — its picture **with its own masks** applied, but not its effects.
  - **Effects and masks** — its **finished picture**: the layer's effects and masks run first.
    This is the one you want when the *point* is the effect — a **keyed** greenscreen matte, an
    edge you **softened** with a blur, or a depth pass you **graded** before the lens blur reads it.

  This replaces the old two-way **After effects** on/off switch. A project saved with that switch
  loads correctly: on becomes **Effects and masks**, off becomes **None**. One limitation worth
  knowing (unchanged): "Effects and masks" applies the layer's *look* effects (keys, blurs, colour)
  but not its *time-based* ones — an Echo or motion-blur-from-movement on the referenced layer is
  treated as a still frame; the everyday cases are exact.
- **Colour picker and dropper (K-210).** Every effect **Colour** parameter — a Flash tint, a
  Colour balance wheel, the Matte key's Key colour, and so on — shows a **clickable swatch**.
  Click it and Lumit's own picker opens: the **red, green and blue numbers across the top**,
  each of which you can drag sideways or type into, then the big square (how vivid, how bright),
  the rainbow strip (which hue), and a hex box. Change any one of them and the rest follow.

  The picker **applies as you go**: whatever it is showing is what the composition shows, so
  there is no button standing between choosing a colour and seeing it. Dragging inside it
  previews continuously and settles into one undo step when you let go, exactly like dragging a
  number in Effect controls. **Clicking anywhere outside the picker closes it and keeps the
  colour**; **Apply** does the same from a button; **Cancel** puts back the colour you started
  with and closes.

  Beside the swatch sits the **dropper** — a small pipette. Click it and the tool arms (the
  pipette lights up so you can see it is armed), then move the pointer over the Viewer and a
  **magnifier** follows it. It appears only once the pointer is actually over the picture, and
  it sits the same distance from the pointer wherever you go — including the corners, where it
  simply hangs over whatever is next to the Viewer rather than shuffling out of your way and
  covering the pixel you were aiming at. At the edge of the *window* it hops to the other side
  of the pointer instead — above rather than below, or left rather than right — the way a
  tooltip does, at the same distance, so it stays out of your way there too. The magnifier shows a **9×9 grid** of the pixels under the pointer,
  each blown up to a square you can aim at, with **dashed lines between every pair** so you can
  tell one pixel from the next. A **solid border** rings the pixels that will actually be taken:
  **just the centre one** to begin with, and **Shift+scroll** grows it to 3×3, 5×5, 7×7 and 9×9
  so a grainy area averages out instead of grabbing one noisy pixel. Click to lift the value;
  press **Escape**, click the pipette again, or click away from the picture to put the tool away.
  Under the grid a strip says what you are about to take — the colour and its numbers, and the
  size of the patch.

  **The dropper is not only for colour.** It means "the value at this pixel", whatever value the
  thing you armed it from is after. Depth of field's **Focus** carries one: click the part of the
  picture you want sharp and Focus jumps to it. There the strip does not show a colour swatch —
  a colour would be meaningless — but **the name of the depth layer it is reading and the number
  it found there**, so you can see where the value is coming from. That pick reads the depth
  layer **rendered on its own**, not the composite: a depth pass is nearly always hidden, so what
  the composite shows at that pixel is not the number the effect uses. If the effect's **Depth
  invert** is ticked, the picked number is inverted to match, so what the strip says and what
  lands in Focus are the same thing.

  **The numbers are in the scale of what you are editing.** A theme colour or a solid's swatch
  is an ordinary eight-bit display colour, so it reads **0–255** and its hex is exactly the same
  value written another way. An effect's colour is not: Lumit works in **linear light at float
  precision**, where **0–1 is black to white** and a channel is free to go *above* 1 — a tint
  brighter than white, which is a real thing in this kind of maths and something several effects
  explicitly allow (up to 4, and one goes down to −1 for a lift). So those read as decimals, and
  you can drag or type a channel past 1 as far as that parameter allows. A hex is an eight-bit
  notation and cannot say "1.8", so on that scale the box shows the colour **clipped** into
  0–1, and a line under the swatches tells you when that is happening — rather than the box
  quietly claiming to be the whole truth.

  **How the pixels get there.** The Viewer's picture normally never leaves the graphics card
  (that is what makes playback cheap), so the dropper cannot simply look at what is on screen.
  Instead it asks the engine for a **window** of the picture — a 129-pixel square around where
  you are pointing, about 66 KB — and then cuts the nine-by-nine it shows out of that window
  itself. It asks by *where in the picture* you are pointing rather than by pixel number,
  because when the Viewer is showing the picture smaller than full size the engine is working
  on a smaller grid than the composition's, and only the engine knows which; its answer says
  which grid it used. That is why moving the pointer feels free: it is reading pixels it already has, and
  it only asks the engine again when you get near the edge of that window (or move the playhead,
  or edit something). Sending a whole 1080p frame across that boundary would cost about eight
  milliseconds every time, which is why nothing does it. The averaging is done in **light**, not
  in screen values, which is why one white pixel among nine averages to a ninth of the light
  rather than to mid-grey — and it means a picked colour matches what you sampled.

- **LUT (K-114).** Drop this on a layer and press its **Select Cube LUT…** button to pick a
  `.cube` file — a colour recipe a colourist baked elsewhere (the loader below reads it) — and
  the whole picture is regraded through it; the **Mix** slider dials the look back toward the
  original. Until you pick a file it simply passes the picture through unchanged (so does a file
  that is missing, unreadable, or the older one-dimensional kind — it never errors, just shows
  as doing nothing). Because a colour look is a whole file, you cannot smoothly *blend* from one
  LUT to another; you *step* between them with hold keyframes (the picture snaps to the new look
  at each key). One honest limitation to know: the file is applied to the picture in Lumit's own
  internal light space exactly as written, without first translating it into whatever space the
  LUT was authored for — a proper "input space" control is a later job — so a LUT built for a
  very different encoding may look off. This grade runs **only on the graphics card**: unlike
  Contrast or Gamma there is no slow CPU stand-in, so if Lumit ever has to fall back to
  CPU-only drawing a LUT layer shows through ungraded. Under the hood the cube of sample points
  is handed to the card as a **3D texture** — an ordinary image has width and height, a 3D
  texture adds a third dimension (depth), so the card can look a colour up by its red, green and
  blue coordinates in one fetch — the first effect in Lumit to need one. The preview and the
  export load and apply the LUT the same way, so an exported file matches what you saw.
- `crates/lumit-core/src/lut.rs` — **reading a colour LUT (`.cube` file).** A LUT
  (look-up table) is a colour recipe a colourist bakes elsewhere: feed it a red/green/blue
  and it hands back a graded red/green/blue. The common `.cube` text format stores that as a
  cube of sample points — a 3D LUT is a grid (say 33×33×33) of "this colour in, that colour
  out", a 1D LUT is three separate curves, one per channel. This file reads such a file into
  memory and answers the one question the LUT effect (docs/08 §3.11) will ask millions
  of times a frame — "what does this LUT turn *this* pixel into?" — by **trilinear
  interpolation**: it finds the eight grid points around the input colour and blends them by
  how close the input sits to each, so colours between the baked samples come out smooth
  rather than blocky (a 1D LUT just blends along each channel's own curve). That blending is
  deliberately the simplest continuous maths there is, because the identical recipe has to run
  again on the graphics card later and the two must agree to the last decimal — the
  CPU-reference-as-oracle rule (docs/08 §1.6). The reader is strict about broken files (a
  missing or repeated size, the wrong number of rows, non-numbers, a size of 0 or 1) and
  returns a plain typed error rather than ever crashing, and it refuses an absurd cube (over
  256 points per axis) instead of trying to allocate gigabytes for it. Nothing is wired to an
  effect yet — this is just the load-and-sample building block.
- `crates/lumit-core/src/ops.rs` — **Every possible edit, as data.** An edit is an `Op`
  (AddLayer, SetLayerSpan…). Applying an op returns its exact inverse — that pair is what
  makes undo *provably* correct instead of hopefully correct.
- **Layer parenting** (K-103) — a layer can name another layer as its **parent**, so moving,
  rotating or scaling the parent carries the child with it (the After Effects null-object
  rig). Pick a parent from the **Parent** dropdown at the top of the Effect Controls panel;
  the list hides any choice that would make a loop, and "None" clears it. Under the hood the
  child's picture is placed inside the parent's coordinate space by multiplying the parent's
  transform in front of the child's — reusing the very same machinery a collapsed precomp
  already uses — computed identically for the preview and the export so they always match.
  A layer with no parent (every layer, until you set one) renders exactly as before. For now
  it inherits the flat 2D move/rotate/scale; inheriting the 2.5D depth/tilt is a later touch.
- **Solo (isolate)** (K-105) — tick **Solo** on a layer (top of the Effect Controls panel,
  next to Parent) and the composition shows only that layer; solo a few and it shows just
  those, hiding everything else, so you can look at one thing without deleting or hiding the
  rest. It is a view aid, not a permanent change — untick to bring everything back. The rule
  ("if anything is soloed, only soloed layers draw") is applied the same way in the preview
  and the export, so what you isolate is what you'd get. Nothing is soloed by default, so
  existing projects look identical.
- `crates/lumit-core/src/anim.rs` — **the keyframe engine.** Between two keyframes the
  value follows a bezier curve shaped by AE-style *speed* (units per second) and
  *influence* (how far each handle reaches). The subtle part: the curve is parametric, so
  "value at time t" first requires solving "where on the curve is x = t?" — done with a
  solver that combines Newton's speed with a bracket it mathematically cannot escape.
  That solver quality is exactly what makes handles feel right in a graph editor at the
  extremes (AE's 100% influence "spike" case is a test here). Property tests fire
  thousands of random curves at it per CI run.
- **Retime, restarted as an ordinary property (K-197).** There are now *two* answers to
  "which moment of the source does this layer show?", and the new one is the simple one.
  A layer carries a `retime` field that is just an animatable number — the same kind of
  number Position and Opacity are — and its value *is* the source time, in seconds. Press
  Ctrl+Alt+T on a layer and it gains one; press again and it loses it (K-200 — it briefly
  had a second chord, Alt+Shift+T, which turned out to be a misremembering and which
  Windows steals for its keyboard-layout switch anyway; the command is in the Composition
  menu too, which nothing can intercept). While it has one, a
  **Retime** row appears in the Timeline's twirl-down above Transform, with the same
  stopwatch, the same diamonds and the same graph-editor lane as every other property,
  because it genuinely *is* every other property — there is no Retime-specific code in any
  of those places. Switching it on installs two keys running source time alongside layer
  time, so the picture does not move; drag the second key later and the clip plays slower,
  drag it earlier and it plays faster. **The two keys land on the layer's own start and
  end** — where it currently sits on the timeline, and where its ends currently are if you
  have trimmed it (K-213). That sounds obvious and was not: keyframes are stored in the
  layer's *own* clock, which is what makes a layer's animation travel with it when you slide
  the layer along the timeline, and the Timeline draws in the composition's clock. The two
  are converted for each other in exactly one place, at the engine boundary; before that,
  every keyframe on a layer that had been moved was drawn as though the layer still began at
  the start of the composition, and Retime's own two keys made it impossible to miss. That is deliberately *all* it does for now: no speed
  ramps, no ease presets, no freeze command. `Layer::source_time_at` is the one function
  that answers the question, so what the renderer decodes and what the frame cache files it
  under can never drift apart. The older, much larger machinery below still answers for
  documents that carry it.
- `crates/lumit-core/src/retime.rs` — **the Retime maths.** One store per clip answers
  "when the clip's clock reads t, which moment of the source shows?". Speed ramps,
  freezes and slow motion are all segments of that one curve, and the editor's speed
  graph and value graph are two views of the same store — never two systems. Every
  segment boundary keeps its source position as an exact fraction, so cutting and
  re-editing a ramp never drifts: a frame synced to a beat stays on the beat. The map
  only chooses *which* source moment shows; how in-between moments become pixels
  (nearest, blend, optical flow) is a separate per-clip policy. **All three are wired up now**:
  a retimed footage layer's twirl-down has a Frames toggle — Nearest shows the closest real
  frame (crisp, a touch stuttery in deep slow-mo), Blend crossfades the two neighbouring frames
  by how far between them the moment falls (smoother, slightly ghosted), and **Flow** invents a
  genuine in-between frame by working out how everything *moved* between the two and dragging
  each halfway (the real slow-mo trick). Flow lives in its own crate (`lumit-flow`) and uses
  **DIS — Dense Inverse Search** — the algorithm the specs pin for it (same family OpenCV
  ships). In plain terms: the frames are stacked into a pyramid of ever-smaller copies;
  starting from the smallest, thousands of little 8×8 tiles each hunt for where their bit of
  picture went (a few quick "am I getting warmer?" refinement steps each); every pixel then
  takes a vote among the tiles covering it, trusting only tiles whose answer actually *looks
  right* at that pixel — that mistrust is what keeps the motion crisp at object edges instead
  of rubber-sheeting. Pixels visible in only one frame (things being covered or revealed —
  where slow-mo artefacts live) are found by checking the two directions of motion against
  each other, and the synthesis quietly falls back to a plain crossfade wherever both frames
  lost sight of something. It ships as **two backends behind one door**: a pure, deterministic
  CPU implementation — the "oracle", also the export path on machines with no usable GPU
  (K-019) — and a GPU compute version (`gpu.rs` + `dis.wgsl`) that runs the identical
  algorithm as shader code, thousands of patches at once instead of one after another. The
  shader mirrors the CPU maths operation for operation, and a test holds the two to agreeing
  within a thousandth of a pixel; another proves the GPU gives bit-identical answers run to
  run. Callers hold a `FlowEngine`, which picks the GPU when one is available and quietly
  drops to the CPU if anything about the GPU ever fails — flow never crashes a preview, it
  just slows down. On the dev machine the GPU solves a 1080p flow pair in about 4 ms where
  the CPU takes about 400 ms — the difference between slow-motion preview being usable and
  not. Both are tested against scenes with mathematically known motion (translations,
  rotations, checkerboards, a sliding square's occlusion) and against a plain crossfade
  (sharper on textured motion). The
  frame-pick and each interpolation are shared functions used by *both* preview and export, so a
  slow-mo frame is identical in each — the preview-equals-export promise holds for interpolation
  too. The same Frames toggle appears per-clip on Sequence layers (next to Clip speed %), so a
  single slowed clip can flow-interpolate while its neighbours stay crisp.
  One knob worth knowing about lives in the Flow group: **Input rate**. High-speed footage —
  say a 600fps phone clip — is a trap for flow, because its frames are so close together in
  time (under two thousandths of a second apart) that there's essentially no motion between
  neighbours to interpolate; flow slow-mo of it looks frozen. Input rate fixes that: tell
  flow to *treat* the clip as, say, 24fps, and it interpolates between frames a real
  twenty-fourth of a second apart instead — actual motion, actual slow-motion. You type the
  rate straight into the box (0 means Native — the clip's own rate), and it's keyframeable
  like any other property: it has a stopwatch, so the conform rate can ramp over the clip if
  you want the slow-motion to ease in. It's the same "conform to N fps" idea editors know from
  interpreting footage in other tools, and because it changes which frames get blended, it's
  folded into the picture cache's identity so you never see a frame flowed at the wrong rate.
  **This is wired up for
  Footage layers now**: a Speed % box in a footage layer's twirl-down retimes it (50% =
  half speed, and so on), and the same Retime map feeds preview, export, and the cache
  key — so a retimed clip previews, exports, and caches consistently. The Speed box is a
  ramp: a start speed → an end speed with an ease (Linear/Slow/Fast/Smooth/Sharp), so a
  clip can rush in and settle — the core montage gesture — not just play at one flat rate.
  When a retime speeds a clip up so much that it runs out of footage, `overrun_local_time`
  reports the exact moment it runs dry — the point where the last frame gets held rather
  than inventing more footage. The Timeline draws that held tail on the layer's bar: a
  faint kraft wash with diagonal hatching over the span, a thin kraft line at the exact
  frame the source runs out, a small `HOLD` tag when there's room, and a tooltip when you
  hover it ("Source ends here — holding the last frame"). Kraft, never a red alarm — house
  rule: a held frame is legal and well-defined, you just need to see it. Right-clicking the
  clip offers **Trim to source end** to cut it there. It never trims for you (boundaries must
  stay put so cuts keep landing on the beat). Sequence layers, the graph-editor lenses, and
  per-beat cutting come next.
- `crates/lumit-core/src/sequence.rs` — **Sequence layers (the model).** A Sequence layer
  is one timeline row holding clips laid end to end — Lumit's Vegas-style editing surface.
  Each clip points at a source, carries its own trim and its own Retime ramp, and sits at
  an exact place on the row; clips never overlap and a gap shows through transparent. This
  file answers the one question the renderer asks — "which clip is under the playhead, and
  which moment of its source does that map to?" — and checks the no-overlap rule. Drawing
  those clips is now wired: a Sequence layer (Composition → Add sequence layer — it starts
  from the selected footage as one clip) renders whichever clip is under the playhead
  through the same footage decode path as a plain footage layer, so its clips preview,
  export, and cache like any other source. You can **cut** a clip at the playhead
  (Composition → Cut clip, or ⌘⇧D / Ctrl+Shift+D) — it splits into two clips whose
  speed ramps exactly partition the original, and neither clip moves (the beat-sync
  covenant). Crucially, a clip's first frame is always its own trim-in whatever its
  speed, so splitting and re-speeding the second half never shifts where it starts.
  Cutting through a *curved* (eased) ramp works too: behind the scenes each half is converted
  to the exact After Effects-style bezier curve form (docs/04-RETIMING.md §5.1/§5.3), so the
  motion is preserved to the frame — only a constant-speed or straight linear ramp stays a
  plain speed ramp after the cut.
  You can also **delete the clip under the playhead** (Composition → Delete clip at
  playhead), which leaves a gap — the Vegas surface allows gaps, and a gap simply renders
  transparent. **Click a clip to select it** (it highlights in clay) and set its **Clip speed
  %** in the layer's twirl-down: the clip keeps its exact place on the layer — its edit points
  don't budge, honouring the beat-sync covenant — and only the stretch of source it consumes
  changes (that maths is `Clip::with_speed`, unit-tested). A non-100% clip shows its speed on
  its bar. Dragging more clips in and per-clip trimming are the next steps.
  You can also **right-click a footage layer → Convert to sequenced layer** (K-071): it
  becomes a single-source layer bound to that one clip — a "fancy precomp" you'll soon
  open in its own editing tab to cut and retime, where a camera track (run once on the
  full footage) can follow the edits. For now it converts in place, keeping the layer's
  id, transform, masks and any speed you'd set.
- `crates/lumit-core/src/store.rs` — **The document store**: applies ops, publishes
  snapshots, keeps the undo/redo stacks.
- `crates/lumit-project/src/lib.rs` — **`.lum` files.** A `.lum` is a zip containing
  readable JSON (rename one to `.zip` and look inside — genuinely). Saves are atomic:
  written to a temp file, flushed to disk, then renamed over the old file, so a crash
  mid-save can never destroy the previous save. The **journal** logs every edit to a side
  file the instant it happens; after a crash, replaying it restores your work.
- `crates/lumit-media/` — **reading media files** (via FFmpeg, the industry-standard
  media library). Two jobs so far: the *probe* (a file's vital statistics — resolution,
  frame rate, duration — shown under each item in the Project panel) and the *frame
  index* — a scan of the whole file that records where every frame and keyframe sits, so
  scrubbing can land on exactly the right frame. Indexing runs on a background thread
  (the UI never waits) and the result is cached on disk, keyed by a *fingerprint* of the
  file's content — change the file and the stale index is ignored automatically.
- `crates/lumit-gpu/` — **the colour foundation.** All engine maths happens on
  "light-linear" values (where adding two lights behaves like real light); files and
  screens use sRGB encoding. This crate owns the only two crossings between those worlds
  — decode-side linearise and display-side encode — and a "golden" test proves every
  possible 8-bit value survives the round trip within one step. That test is what makes
  the washed-out/too-dark "double gamma" class of bug impossible to reintroduce, and it's
  the bedrock of the preview-equals-export promise (K-031). The clever part: the shader
  contains no gamma maths at all — the GPU's texture formats do the conversions in
  hardware, so decode and encode can never drift apart.
- `crates/lumit-gpu/src/composite.rs` — **the compositor seed.** Each layer is a picture
  on glass; the compositor stacks the glass on the GPU. Position/scale/rotation move each
  sheet (already as full 4×4 matrices, so 3D later needs no rewrite), opacity fades it,
  and stacking happens in linear light where combining images behaves like combining real
  light — a test proves the result differs from the naive approach by exactly the amount
  physics predicts. This is the beginning of the evaluator: the thing that will one day
  render whole comps with effects.
  **Per-layer motion blur** lives here too (`motion_blur_average`). Turn the composition's
  motion-blur master on and flip a layer's motion-blur switch — the **MB** toggle in the
  layer's switch cluster on the right of its Timeline row (or the "Motion blur" line in its
  right-click menu) — and that layer is drawn not
  once but many times — its *same* picture, nudged to where the layer sat at a spread of
  instants across the "shutter" (a slice of the frame, 180° = half a frame by default) —
  and those copies are averaged. A still layer averages back to itself exactly; a
  fast-moving one turns into a translucent smear along its path, thinning out where it only
  passed briefly, which is what real motion blur looks like. The averaging adds the copies
  up (each at 1/N strength) including their transparency, so a covered patch stays solid
  and a half-covered one goes half-transparent — a plain "Add" blend would wrongly keep
  transparency high, so there's a dedicated add-everything blend just for this. The layer's
  real blend mode, opacity, matte and mask are applied *once*, to the finished smear, not to
  each copy. Crucially the Viewer and the file export call this one shared routine with the
  same sub-frame instants, so a blurred preview and a blurred export match (K-031). Two
  follow-ups are noted in the code: a layer that blurs because its *parent* moves isn't
  covered yet (only the layer's own motion is sampled), and an inner layer of a
  *collapsed* precomp doesn't blur (so the Viewer and export can't disagree about it).
- `crates/lumit-gpu/src/oklab.rs` — **perceptual colour.** Two colour worlds, two jobs:
  linear RGB is where *light* combines correctly (layering, glow, exposure), and Oklab is
  where *perception* behaves — a gradient interpolated in Oklab stays vivid where an RGB
  gradient sags into grey, and rotating a hue in Oklab keeps its brightness. Lumit
  converts on the fly (a handful of multiplications per pixel), users never see anything
  but normal RGB values, and tests pin both promises: round-trips are exact and hue
  rotation provably never changes lightness.
- `crates/lumit-cache/` — **the cupboard with a size limit.** Rendered and decoded
  frames get remembered so they're never computed twice; when the cupboard is full,
  whatever was used longest ago gets thrown out first. The limit is in bytes, not item
  counts — one 4K frame costs what sixty thumbnails cost, and budgeting any other way is
  how apps balloon.
  As of the disk tier (`disk.rs`), frames also get **parked on disk**: a cache folder — in
  Lumit's own app-data area by default, or beside the project file or somewhere you choose
  (Settings → Performance) — collects rendered frames, written there compressed by a
  background thread, so closing and reopening a project doesn't start the cache from zero,
  and frames squeezed out of memory can come back without re-rendering. Each frame is one small file named by its content fingerprint; anything
  unreadable is silently deleted and re-rendered, so the folder is **always safe to delete**
  — it can make things faster, never wrong. The idle background fill now checks the disk
  before rendering: promoting a parked frame beats recomputing it. The timeline's cache bar
  grew a second colour for this: **mint** = in memory, plays right now; **blue** = parked on
  disk, ready to promote.
  The third tier is **VRAM**: the last few hundred megabytes of frames you actually looked
  at stay resident on the graphics card, so scrubbing back over them re-shows the exact
  texture with zero work — no upload, no colour maths. All three tiers answer to the same
  content fingerprint, so a frame is a frame wherever it lives — and a frame pushed out of
  one tier falls into the next rather than being lost (K-214; the long section at the end of
  this guide walks the whole ladder).
- **Timeline guide lines** — the faint vertical lines through the lanes have a mode picker
  in the bottom bar ("Grid"): **beats** (the default — detected beats shine through every
  layer so cuts land on the music), **time** (a neutral second grid that subdivides as you
  zoom in, down to 10 ms), or **off**. The bright ruler ticks up top stay regardless.
- `crates/lumit-render/src/export.rs` — **writing video files.** Every frame of a comp is
  rendered through the *exact same* colour engine and compositor the Viewer uses, then
  compressed to an .mp4. Using one shared path isn't laziness — it's the design's central
  promise (what you preview IS what you export), and it runs on its own worker so the app
  stays responsive while exporting, with live progress and a real cancel. The **export
  dialogue** offers presets — *YouTube 1080p60*, *YouTube 4K60*, *Vertical 1080×1920p60* —
  which are just rows of numbers (frame size, codec, bitrates) stamped into fields you can
  still edit, so the custom path is always open. Presets are pinned by a unit test, so a
  stray edit can't quietly change what "YouTube 1080p60" means. When the comp's shape
  differs from the preset's, Lumit fits the picture keeping its proportions and adds black
  bars (a wide comp gets bars top and bottom in a vertical export); the fitting maths
  (`fit_contain` / `letterbox_resize` in `lumit-core`'s `pixels.rs`) is unit-tested. **Sound comes too**:
  the comp's audio is mixed by the very same code that plays it back (one shared `mixdown`
  — playback, beat detection, and export literally cannot hear different things), then
  written as an AAC track fed to the file in step with the picture, a video frame's worth
  of samples at a time, so players never see sound and image drift. Exports now **queue**:
  ask for another while one runs and it waits its turn, each item frozen exactly as the
  project stood when you queued it — later edits never sneak into a queued export. The
  status bar shows which file is exporting, how far along it is, which encoder is doing the
  work, and how many items wait; one failed item never stalls the rest.
- `crates/lumit-media/src/encode.rs` — **compressing the file, and how export picks an
  encoder.** Compressing video is heavy work, and every GPU vendor ships a dedicated chip
  for it: NVIDIA calls theirs NVENC, AMD has AMF, Intel has Quick Sync. They are far faster
  than doing it on the CPU, but temperamental — a machine can have the NVIDIA *software*
  installed with no NVIDIA card present, or the card can refuse because too many programs
  are already encoding. So Lumit works down a ladder: try NVENC, then AMF, then Quick Sync,
  then plain software (x264/x265, always works). And it doesn't just ask "are you there?" —
  it *proves* each rung by encoding sixteen blank frames at the export's exact size before
  trusting it, because these chips are notorious for saying yes and failing a moment later.
  Whichever rung passes first does the export, and the finished dialogue tells you which
  ("Encoded with NVENC"). The ladder order and the fallback rule are plain data plus a tiny
  pure function, so the "hardware exists but won't open" cases are ordinary unit tests, and
  one integration test runs the real ladder on whatever machine the tests run on. The same
  module now also writes **HEVC** (H.265 — newer, smaller files than H.264 at the same
  quality) and an **AAC audio track**, interleaved with the video the way streaming players
  expect, with a `+faststart` flag so the file's table of contents sits at the front and
  playback can begin before the download ends.
- `crates/lumit-audio/` — **playback and the clock.** The sound card asks for samples on
  its own strict schedule through a "realtime callback" — a tiny function that must never
  wait for anything (if it's ever late, you hear a glitch). The count of samples it has
  played *is* the playback clock: video asks "what time is it?" every frame and shows
  whatever frame matches. One clock, owned by the audio hardware — that's why picture and
  sound can't drift apart, and it's the same design the full engine keeps forever.
- **Composition audio and playback** (`lumit-audio::mix`) — pressing Space on a comp now
  plays it. A comp can have many layers that make sound, each starting at its own moment;
  to play it, Lumit decodes each one and lays them on a single strip at the right offset
  and trim, then adds them together (a mixing desk summing channels — `mix_stereo`). That
  one mixed track goes to the sound card, and its clock drives the picture, so a comp's
  video and audio stay locked exactly like a single clip's. The mixing happens on a
  background thread so pressing Space never stalls; a silent comp just plays on a plain
  timer instead. This retires the old stopgap where comp playback guessed the time from a
  wall clock.
  The mixed track is kept **in step with the comp**: each frame Lumit works out a small
  fingerprint of what the comp should sound like (which layers make sound, and where each
  sits on the timeline). If you mute a layer, slide it, trim it, or delete it, the
  fingerprint changes and the track is re-mixed from the new state — and if muting or
  deleting leaves nothing audible, the track is dropped so it stops sounding at once. Before
  this, the track was mixed once when you pressed Space and never revisited, so those edits
  had no effect on what you heard (the GEN-4 audio fixes). The fingerprint is a plain,
  tested function, so "a muted layer is silent" and "a moved layer's sound moves with it"
  are checked without needing a sound card.
- **The live mix plan (`lumit-audio::mix::MixPlan`)** — how audio edits became instant, and
  how a feature film stopped eating all the memory. Originally, playing a comp *baked* one
  giant pre-mixed track the length of the whole comp — for a two-hour film that single
  track is gigabytes, and every solo/mute/move re-decoded and re-baked the lot (minutes of
  waiting, and the out-of-memory the owner hit). Now each footage file is decoded **once**
  into a shared, byte-budgeted store (it stays within the one Memory budget in Settings →
  Performance, half your machine's RAM by default), and the comp's audio is just a *plan*:
  "this file's samples play here, that file's there". The sound card's callback adds up the
  few numbers it needs for each moment as it goes — a handful of multiplications, nothing a
  sound card notices. Soloing, muting, moving or trimming a layer swaps in a new plan and is
  heard on the very next callback, about ten milliseconds later, with the clock untouched.
  A test proves the plan sounds *sample-for-sample identical* to the old baked mix, another
  proves a mid-play swap keeps the clock running.
- **Per-layer Volume and the waveform in the layer's own row (K-172)** — every audio-carrying
  layer now has an **Audio** group in its timeline twirl, next to Transform and Effects. Inside:
  a **Volume** value in dB — 0 is the file's own loudness, positive boosts (up to +50), and
  −100 or below reads "−inf", true silence. It keyframes like any other property (stopwatch,
  the ◄ ◆ ► arrows), which is how fades work: two keyframes, loud to silent. Under the volume
  sits a **Waveform** twirl that draws *that layer's* sound in its own lane — and because the
  drawing reads the layer's position fresh every screen refresh, dragging the layer slides its
  transients along with it, live. The old single waveform strip under the ruler is gone: it
  showed the whole comp's mixed sound in one place, went stale mid-drag, and told you nothing
  about *which* layer a spike belonged to. When a volume is keyframed, the fade is baked into a
  little list of loudness levels every ten milliseconds (a "gain envelope") that both the live
  player and the export mixer read — the same numbers, so what you hear is what you export;
  changing a volume re-plans the mix instantly, like every other audio edit above. Precomps
  carry their sound out with them: a nested comp's audio layers are walked recursively into
  the same mix (spans mapped onto the outer timeline, mutes and solos respected per comp),
  and a precomp layer's own Volume scales everything inside it — the gains multiply down the
  chain, so it has the Volume row too. And a purely-audio layer (a music file) shows no eye
  in the outline at all: there is no picture to hide.
- **Your project remembers where you were** — reopening a saved project no longer lands on a
  blank Viewer waiting for a playhead nudge. Which comp tabs were open, which one was in
  front, where the playhead sat, which layer was selected, and which twirls were unfurled all
  come back, and the first frame renders immediately. The mechanism is the same one that
  remembers the timeline column width: small notes in the app's own settings store, keyed by
  the project's file path — nothing is written into the project file itself, so sharing a
  `.lum` never leaks your window arrangement.
- **Project files carry no absolute paths (K-173)** — a tester about to share a project
  noticed their username sitting inside it: every media reference stored a full path like
  `/home/Their Name/projects/clip.mp4`. No longer. A saved project stores each file's
  location *relative to the project folder* (recomputed every save, with forward slashes so
  a Windows save opens on Linux) plus a small **content fingerprint** — the file's size and
  a hash of its first and last chunks. Where the file sits on *your* machine lives only in
  memory while the app runs. Opening a project finds each file by walking: is it where the
  relative path says? (This is why moving the whole project folder now just works.) If not,
  does an old save's absolute path still point somewhere real? If not, the fingerprint
  search combs the project's folder tree for a file with the same content — so footage that
  was reorganised into a subfolder is found by what it *is*, not where it was. Anything
  still missing is named in a notice and its reference kept intact.
- **When footage goes missing, you see colour bars** — the broadcast test pattern, the same
  one a television shows with no signal. The reasoning is that the alternative is worse: a
  missing layer that renders *black* looks exactly like a deliberate edit, so the mistake
  can survive all the way into an exported file. Bars cannot be mistaken for anything but
  "there is nothing here". They appear in the Viewer and in exports alike, for the same
  reason. In the Project panel the item wears a crossed-link icon and a **Relink…** button;
  pointing it at the file's new home also relinks every *other* missing file sitting in that
  same folder, in one undo step — losing a folder of footage is then one dialogue rather
  than twenty. The pattern itself is drawn by arithmetic at whatever size is needed, not
  loaded from a bundled image, so it is crisp at any resolution and adds nothing to the
  download. When something *is* missing, a toggle appears beside the Project panel's search
  box (and on any footage row's right-click menu) that filters the panel down to just the
  broken files and the folders leading to them — the "what else is broken?" view. It works
  alongside the search box rather than replacing it, so you can hunt for one missing clip by
  name; and when nothing is missing it tells you so plainly instead of showing an empty
  panel that looks like a fault.
- **Beat detection** (`lumit-audio::beat`) — the groundwork for cutting to the music. It
  slides a short window along the track and, at each step, measures how much *new* energy
  appeared since the last step (the "spectral flux"); a kick or snare makes that number
  spike, and the spikes are the onsets. Autocorrelating the spikes recovers the tempo (BPM),
  preferring the sensible 70–180 range so a fast track doesn't report double-time. A
  sensitivity dial trades more markers for fewer. It's the standard, well-understood
  approach done carefully — no AI guesswork — and it's tested against synthetic clicks at a
  known tempo (every beat found, tempo within 2 BPM). A **grid assist** (`snap_to_grid`) then
  nudges any beat that's within ~45 ms of the tempo grid exactly onto it — the grid's phase
  is worked out from the beats themselves — which tidies away the small, unavoidable delay in
  raw onset detection so markers land where a musician would tap. Onsets that fall well off
  the grid (syncopation, fills) are left where they are.
- **Markers** (`lumit-core::markers`) — a marker is a labelled flag at a moment on a
  composition's timeline. Three kinds: ones you place (User), chapter divisions, and the
  Beat markers Lumit detects from the music (each with a confidence). Re-running beat
  detection replaces only the Beat markers, so cues you dropped by hand are never disturbed.
  `snap_time` returns the nearest marker within a threshold (else the original time) — the
  basis for cuts landing exactly on the beat. All of this is exact-rational and unit-tested.
  In the app, **Composition → Detect beats** mixes the comp's audio on a background thread,
  runs the detector, and drops a Beat marker on every onset (re-running replaces only those,
  never your hand-placed cues). The markers show as clay ticks on the timeline ruler — faint
  or bright by confidence — and scrubbing the playhead snaps to a nearby marker, so you land
  on the beat.
- **The timeline waveform** — a strip under the ruler draws the composition's mixed audio as
  a min/max envelope on the same time axis, so the beats sit right above the transients that
  made them. It's built by `waveform_peaks` (in `lumit-audio::mix`), which buckets the mono
  mixdown into (min, max) pairs — a pure, tested down-sample — computed once when the comp's
  audio is mixed for playback.
- The **graph editor** — the curve view of the Timeline, like After Effects' graph button
  (the Graph toggle in the Timeline toolbar, or `Shift+F3`). Switching it on keeps the layer
  outline on the left and swaps the lane area for **one full-height pane of curves**, under
  the same time ruler, zoom and horizontal scroll as the lanes — a frame sits at the same
  x whichever view you are in, and the playhead line runs through both.
  **Choosing what to graph.** Click a property's *name* in the outline (twirl the layer
  open first) and its value-over-time appears as a line — even a property with no keyframes
  shows as a flat line of its value. **Ctrl+click** more names to add them, **Shift+click**
  to take a whole run of rows, across layers; each curve gets its own colour from the
  theme's curve palette, and the property's name in the outline is tinted to match, so you
  always know which line is which. A property with more than one axis shows every axis —
  Position is an x curve and a y curve, like AE's red/green pair, with a coloured dot per
  axis beside the label. Selection rides on the *name* on purpose: clicking a value field
  or a stopwatch never re-aims the graph, but *editing* a value or adding a keyframe does
  select that property, so the curve you see is the one you just touched.
  **Reading the curve.** Each key's glyph tells you its interpolation at a glance — a
  diamond is linear, a circle is eased (bezier), a square is a hold. The curve between keys
  is drawn by a Dart copy of the *engine's own* evaluator (`graph_maths.dart`, pinned to
  `anim.rs` by docs/impl/keyframe-eval.md and golden tests), so the shape on screen is
  exactly the motion that renders — and drawing it costs no bridge calls at all.
  **Editing keys.** Drag a key to move it in time *and* value at once — one undo step per
  property, even when a drag moves a whole selection. Drag a box over empty pane (the
  *marquee*) to select many keys; Shift or Ctrl adds to the selection; a plain click on
  the background clears it; **Ctrl+click** on a curve plants a new key right on it;
  Delete removes the selected keys (the last key of a curve leaves a static value holding
  what it held). Keys may pass each other in a drag — the curve just re-sorts — but two
  keys can never share a frame: a drag that would collide simply stops, nothing is lost.
  The magnet in the bottom bar decides whether dragged keys land on whole frames.
  **Shaping a key (bezier handles).** New keys are linear. Select some and press **F9**
  (or the **Bezier** button in the bottom bar) to *easy-ease* them — AE's smooth default:
  the curve arrives and leaves flat, and the key grows two **tangent handles**, one
  reaching toward each neighbour. Drag a handle to shape the curve: its steepness is the
  **speed** there (units per second) and its reach is the **influence** (how much of the
  gap the ease covers). The two handles are **in sync** by default — they behave as one
  straight line through the key, so dragging one swings the other round to stay opposite it
  and motion glides *through* the key. The partner keeps the length it *looks* on screen
  rather than its length in values, at every angle — so it never appears to shoot out as
  the pair steepens, and swinging one handle out to near-upright and back brings the other
  home exactly as long as it started. Two small things make that hold. A tangent can never
  be made *perfectly* vertical, only a hair off it: an upright tangent spans no time at
  all, and there is no speed that describes such a thing, so it is the one shape the editor
  could not undo (the difference is well under a pixel — no ease you shape can tell). And
  each handle's length is remembered as you leave it, rather than worked back out of the
  ease, which at that extreme is where the arithmetic gets thin. (One thing worth knowing
  about the see-saw: the partner moves when the line *rotates*. Dragging a handle straight
  out from an already-steep tangent lengthens it without turning it much, so the other side
  barely stirs — that is the geometry, not a stuck handle.) Hold **Alt** as you start a
  drag to break the two apart and shape a corner; Alt-drag again re-joins them. `Shift+F9`
  eases only the way *in*, `Ctrl+Shift+F9` only the way *out*, and the **Linear** and
  **Hold** buttons put selected keys back to straight lines or steps.
  **Value and speed.** The bottom bar's **Value / Speed** buttons switch what the pane
  plots (docs/07 §5.1). The speed graph is the value curve's *exact derivative* (K-080) —
  an eased key reads as a smooth dip to zero, a straight run as a flat line, a hold as
  zero. Here each key is really **two dots** — the speed coming *in* and the speed going
  *out* — that drag up and down independently, each with a single horizontal **influence
  handle**; this is AE's speed graph, and both views edit the same store, so shaping one
  always updates the other losslessly.
  **Framing and the wheel.** Vertically the pane **auto-fits** by default: the curves,
  every handle tip and any bezier overshoot stay in view, and the framing holds still
  during a drag so the curve isn't sliding under your cursor. Toggle **Auto fit** off in
  the bottom bar to take the vertical axis yourself: a plain wheel pans it, **Alt+wheel**
  zooms it about the cursor, and **F** re-frames whenever you want. **Ctrl+wheel** zooms
  time about the pointer and **Shift+wheel** scrolls sideways — the same bindings as the
  lane view, because it is the same axis. A y-axis of faint gridlines down the left edge
  labels the values.
  **Copy and paste.** `Ctrl+C` copies the selected keys and `Ctrl+V` pastes them into the
  selected properties, the earliest key landing on the playhead. It is not a graph-only
  gesture: keys boxed up on a *lane* copy and paste exactly the same way. The in-app
  clipboard keeps everything — times, values, both sides' easing. The *system* clipboard
  gets the same keys as a **tab-separated table** headed `Lumit <version> Keyframe Data`:
  the rate and source size, then a row per frame with a column per value — and, after
  those, two more columns per value carrying that key's easing (`linear`, `hold`, or
  `bezier(speed,influence)`). So a copied ramp can be read by a script, dropped into a
  spreadsheet, or carried into another tool *with its shaping intact*, which is the part
  a plain values table always loses. Reading is deliberately forgiving: a keyframe table
  from another editor — same shape, no easing columns — pastes in as linear keys rather
  than being refused.
  **A file parameter** (K-111) — some effects need a *file* rather than a number, a colour LUT
  being the first. Its row in Effect Controls shows the chosen file's name and a **Select…**
  button that opens the usual file picker, filtered to the kind the effect wants (a LUT shows
  only `.cube` files). Until you pick one the effect does nothing — a LUT with no file loaded
  simply passes the picture through. A file can even be *animated*, but only as a **hold** step:
  you keyframe which of a few files is showing when, and it switches at each key rather than
  trying to cross-fade between two files (which would be meaningless) — it reuses the very same
  hold keyframe described just above, so a file animates with the same tools as everything else.
  The **marquee works in both views**: drag a box over the speed view's background and the
  speed points inside it are selected, just like value keys.
  The **Retime channel's Velocity lens** can now edit *eased* ramps too: a ramp shaped with
  the Slow/Fast/Smooth/Sharp presets shows a small **square handle** where two ramps join —
  drag it up or down to set the speed at that join, and both neighbouring ramps re-aim to
  meet it while keeping their easing shapes. (Round handles remain the plain keyframes of
  un-eased ramps, as before.)
  A **footage layer** also carries a **Retime channel** here, named for the lens you are in
  (K-076): **Time** in the value view, **Velocity** in the speed view. In the **Time** lens it
  is now *exactly* an ordinary property graph (K-078): the curve is the source position (in
  seconds of footage) over the clip's own time — "which moment of the footage is on screen
  here", After Effects' *Time Remap* — and it edits with the same tools as Position or Scale.
  Keys drag, double-click adds one, and you can shape each with the same **gold bezier
  handles** and **F9** easy-ease as any property; the view auto-fits to the curve. A straight
  line is a constant speed, a curve is a speeding-up or slowing-down. A stopwatch turns
  keyframing on (adding a key that holds the source frame showing at the playhead); enabling it
  always yields at least the start and end keys — press the stopwatch with the playhead at the
  layer's very start or end and those endpoint keys simply appear (the stopwatch still lights;
  nothing is silently skipped). In the **Velocity** lens the same channel reads playback speed
  per cent, and dragging a point authors a ramp — the Vegas gesture, still its own bespoke
  editor with the ramp presets. They are two views of one store: shaping the Time curve with
  handles re-expresses the whole channel in After Effects terms, so any eased speed ramp you
  built in the Velocity lens is replaced by explicit value tangents once you drag a Time
  handle. The channel opens to the Time view by default; a "Vegas" tick makes it open to
  Velocity. (Time values show as plain seconds for now, like any property's axis — a proper
  `HH:MM:SS:FF` timecode readout is still to come. A *held* Time key — freeze then jump — also
  isn't distinct yet; a Hold there reads as a straight line.)
  (Frame interpolation — how in-between frames are synthesised, Nearest / Blend / Flow — is a
  per-layer retime setting in the data model, but is not surfaced in the timeline for now; it
  will return in a dedicated place.)
- **Property rows in the Timeline** (K-072) — twirl a layer open and each of its animatable
  properties (Position, Scale, Rotation, Opacity, and the 3D ones) gets its own row: on the
  left a stopwatch to turn animation on or off, the property's name, and its current value;
  on the right, along the same time ruler as the layer bars, a little diamond at each of that
  property's keyframes — so you can see *which* property is keyed *when*, not just that the
  layer has keys somewhere. Click a property's name to open its curve in the graph view.
  Once a property is animated its row also carries a **keyframe navigator** — `◄ ◆ ►` — where
  the middle button adds a key at the playhead (or removes the one already there) and the
  arrows jump the playhead to the previous or next key, so you can walk a property's keys
  without hunting for them by eye. (Effect parameters get this same navigator now too — an
  animated Glow radius or blur amount steps and adds/removes keys from its row exactly as a
  transform property does.)
  **The diamonds on the lane are live, not just a picture (notes 2.1/2.6).** Click a keyframe
  diamond to select it — it wears a ring — and **drag it left or right to change its time**;
  while the **magnet** (the bottom-bar toggle, on by default) is lit it snaps to the nearest
  whole frame, exactly like a key drag in the graph editor. On the lane only the *time* moves
  by dragging — a key's *value* is shaped in the graph editor — but its **easing is not graph
  work**: **F9** and its family (and the bottom bar's Linear / Bezier / Hold buttons) act on
  whatever keys are selected here, so easing a key never means opening the graph. The easing
  chords are bound in the graph context in docs/07 §15; the Timeline honours them because the
  two views are one panel with one key selection between them. (Touching a diamond is what
  selects it — the same gesture that drags it, which is why a click with no movement still
  counts: the lane's drag recogniser is alone in its arena, so it wins on release either way.
  That matters more than it sounds: a lane at fit zoom is a third of a pixel per frame, and a
  competing tap recogniser would swallow every drag short of twenty frames.) **Shift-click** adds a key to
  the selection, **Ctrl-click**
  toggles one, and dragging over empty timeline space draws a **marquee** box that selects
  every key it covers — *across different property rows*, so you can grab, say, a Position key
  and a Rotation key together and nudge them in step. Hold **Shift** while you drag the
  marquee to add to the current selection instead of replacing it. A drag that begins on a
  layer bar still moves the bar, and one that begins on a key drags the key — the marquee only
  opens on genuinely empty space. Every key you move commits through the normal document
  edit, so it is one undo step and the preview re-renders exactly as the export will. (A
  linked Position/Anchor/Scale row shows the union of both axes' keys as one diamond per time;
  dragging it moves *both* axes' keys at that time, keeping the pair in step.)
  You can also **highlight several property rows at once** by their names, the usual list way
  (note 2.6b): **Ctrl-click** a name to add or remove that one row, **Shift-click** to select
  the whole run of rows between it and the last one you clicked. A plain click still picks a
  single row and opens its curve; a Ctrl/Shift-click only changes the highlight and leaves the
  graphed channel alone. This works the **same for every kind of row** (UI-6): transform
  properties, effect parameters and a footage layer's Retime "Time"/"Velocity" row all select
  and multi-select alike, and one selection can mix all three (a plain click on an effect or
  Retime row single-selects it, exactly like a transform row). Once you have a set highlighted,
  the command palette's **Key selected properties** adds a keyframe to every one of them at the
  playhead in a single undo step — so you can key several channels at the same point at once,
  each holding its current value.
  **Copy and paste keyframes (note 2.2).** With keys selected, **Ctrl/Cmd+C** copies them —
  bezier handles and all — remembering each key's time relative to the earliest one in the
  set. Move the playhead and **Ctrl/Cmd+V** drops them back down at the playhead, keeping their
  spacing and their easing, and **overwriting** any key that already sits at the same time. A
  paste is one undo step. (Copying a key on a linked Position/Scale/Anchor row carries both
  axes, so the pair pastes back together.) These only fire when no text box is focused, so
  typing still copies and pastes text as normal.
  (When the layer is twirled shut, the layer bar still shows a summary of all its keys.)
  Scale is special: by default x and y are locked together on a single "Scale %" row that
  keeps their ratio as you drag; the 🔓 button unlocks them into two separate rows for
  independent editing, and 🔗 re-locks. (Re-locking keeps whatever ratio the two currently
  have and loses nothing — a small, friendlier deviation from the original "relinking may
  discard one axis" idea.)
  **Position and Anchor come linked by default too, but in a different sense**: one
  "Position" row (and one "Anchor" row) carries *two* value boxes, x then y, exactly as
  After Effects shows a 2D position. Unlike Scale there is no ratio lock — dragging x never
  moves y; the link only merges the row's furniture. The shared stopwatch animates or
  freezes both axes together as a single undo step, the shared keyframe navigator walks the
  union of both axes' keys (its diamond adds a key to *both* axes at the playhead, or clears
  whatever keys sit there on either axis), clicking the name opens the x channel in the
  graph, and the lane shows both axes' diamonds. The chain button splits them into the old
  separate "Position x" / "Position y" rows when you want to walk one axis's keys on its
  own, and a "Link position" row underneath joins them back up. The choice is remembered
  per layer for the session, and nothing about the project file changes either way — it is
  purely how the rows are drawn. A selected sequence clip's **Speed %** is a full ramp — a start
  and end speed with an ease (Linear/Slow/Fast/Smooth/Sharp), equal ends being a plain
  constant — so a single clip can rush in and settle; cut a clip into pieces and ramp each to
  build the classic ramp-freeze-ramp velocity edit, edit points staying on the beat
  (`Clip::with_ramp`, tested). Footage layers also get a **Speed %** row with the same stopwatch:
  turn it on and speed becomes keyframable, so you can slow-mo one moment and speed through
  another. Under the bonnet each speed keyframe becomes a segment of the retiming curve (a
  straight speed ramp between keys); the frame-accurate maths that keeps cuts on the beat is
  the same engine described above. Curved (eased) speed ramps are still the graph editor's job.
  In its **Time** lens the row shows a source timecode you can scrub, and the viewer now
  **updates live as you drag it** — because changing the retiming changes *which frame of the
  footage* is on screen, the preview re-fetches that frame while you drag rather than waiting
  for release (the same instant feedback a transform or effect value already gives). Every
  keyframe row across the whole layer area — transform properties, the Retime Time/Velocity
  row and effect parameters — also shares **one** `◄ ◆ ►` add/step navigator now, so they look
  and behave identically wherever you meet them.
- **Getting around the Timeline** — the panel is split into the **layer outline** on the left
  (the stack of names, stopwatches and toggles) and the **lane area** on the right (the time
  ruler with each layer's bar on its own *lane*). Each bar wears its layer's **label
  colour** — the same chip its outline swatch shows (K-189) — so a tall stack reads at a
  glance and picking a new label recolours the bar. Drag a layer's bar body to slide it
  earlier or later in time (one undo per drag); drag its ends to trim — the pointer turns
  into the horizontal resize arrow over the last few pixels of each end, which is where
  the trim grab lives. **The ends know what the source holds** (K-211): a Footage, audio
  or Precomp layer stops where its media does — you cannot drag its head earlier than the
  clip's first frame or its tail past the last, and when an end is sitting on that limit a
  small triangle appears in that top corner of the bar to say so. Every generated kind —
  Solid, Text, Adjustment, Null, Camera — has no source to run out of, so both its ends go
  wherever you drag them and neither wears a triangle. Switch **Retime** on and the limits
  come off (and the triangles go): a retimed layer chooses which source moment each of its
  own frames shows, so it can be stretched to any length you like. Sliding a bar along the
  timeline is never limited — moving carries the content with it, so a clip that fits its
  source still fits it wherever it lands.
  **Trim one back and you can see what you cut off**: a faint outline runs behind the bar
  as far as the media reaches, so the trimmed-away head or tail shows as an empty extension
  of the clip — drag the end back out and the bar fills it again. It appears only when there
  is something to show, and never while Retime is on.
  **Turning Retime off puts the layer back on its source.** A retimed layer can be any
  length, so when you switch the retime off Lumit has to give it one again, and it does that
  from the frame you are already looking at: the layer keeps its start, still shows that
  same frame there, and plays at normal speed from there until the footage runs out (or
  until where the layer already ended, if that came first — it never gets longer than it
  was). So a clip that started on its first frame simply plays from the beginning again,
  and one parked half-way in carries on from half-way in. It is one undo either way.
  A layer twirled
  open shows its **keyframes as diamonds on the lanes**: drag a diamond to move that
  keyframe in time, or drag a box on empty lane space to select the diamonds inside it.
  Dragging never scrolls the timeline — the wheel and the scrollbars do: a plain wheel
  moves the rows, **Shift + wheel** scrolls sideways, and **Ctrl + wheel** zooms time
  around wherever the pointer is. The two halves scroll vertically **as one table**, with
  the shared scrollbar on the lane side's far right (in Graph view each side gets its
  own, and the outline keeps that strip reserved either way so the columns never jump).
  Along the bottom of the lanes sits a small bar: `−`, `+` and **Fit** with the current
  zoom per cent, the **magnet**, and the horizontal scrollbar that moves the view once
  you are zoomed in. The magnet — on by default — is what makes a dragged keyframe land
  on a whole frame; switch it off and a keyframe can sit between two frames, which is
  occasionally what a fast move needs.
  The Lane/Graph view buttons live in the Timeline's toolbar; Graph is only a change of
  what the right side *draws* — the outline stays identical between the two, so twirling
  a layer open shows the same rows either way.
- **Working the layer outline** — a few habits from other editors now work the way you
  would expect. The outline's columns sit in **four groups** (K-188), left to right:
  first the **eye, speaker, solo star, padlock and shy** switches; then the **twirl, a
  small label-colour chip, the layer's stack number and its name**; then the
  **flow-or-collapse glyph, an fx bypass switch, motion blur and 3D**; then the **Matte,
  Blend and Parent** dropdowns (Parent is the same parent-and-inherit link the Effect
  Controls tab offers — pick another layer and this one rides its transform). The row of
  tiny icons over the columns names each group — and it is also a handle: **drag a
  group's header to move the whole group**, which is how you reorder the columns, and
  **drag the little line after a group to make it wider or narrower**. Only that group
  changes; the others keep the width you gave them, so the whole layer area grows or
  shrinks to suit. Whatever lives in a group grows with it — widen the switches group and
  the value boxes under it widen to match, so a long number always has room.
  **Drag a layer by its name** to move it up or down the stack — drop it on another
  row and it takes that row's place, in one undo step. (Dragging its *bar*, over in the
  lane area, moves it in time instead.)
  **Clicking a property** (a Position, an effect's Radius, a Volume) selects it, and
  everything it belongs to — its effect, its layer — lights up faintly behind it, so you
  can see at a glance whose property you are looking at. That is also what the graph view
  will use to know which curve you meant. The eye
  and speaker swap to a closed eye and a muted speaker when off, so a hidden or silent
  layer reads at a glance. **Shy** is list housekeeping borrowed from After Effects: mark
  the layers you are done fiddling with as shy, press the shy filter in the Timeline's
  toolbar, and they vanish from the *list* — never from the picture — until you press it
  again. The padlock freezes a layer: while locked, its bar will not slide, its ends will
  not trim, it will not rename, reorder or delete. The label chip opens a small
  eight-colour picker, and the colour you pick is also the colour of the layer's **bar in
  the lane area** — each kind of layer starts on its own bright chip (footage azure,
  solids amber, precomps violet, text mint, cameras teal, sequences indigo, adjustments
  magenta), so a fresh stack is tellable apart before you name anything. It changes
  nothing about the picture itself. The toolbar above the columns shows the playhead twice —
  as `HH:MM:SS:FF` timecode and as a plain frame count like `f72` (both start at zero,
  so frame 0 is 00:00:00:00) — plus the layer search, and a **master motion blur**
  button: the comp-wide shutter switch that decides whether the layers whose own motion
  blur switch is on actually blur. The master is per comp — a nested comp inside a
  Precomp layer has its own master and follows that one, not the parent's. The
  thin line between the
  outline and the lanes is a handle — drag it to widen or narrow the outline; if you drag
  it hard against a limit and keep pushing, it now waits for the cursor to travel back to
  where the handle actually is before it starts moving again, rather than lurching the
  instant you reverse. **Double-click
  a layer's name** to rename it in place (Enter or clicking away keeps the change, Escape
  throws it away); **drag a name up or down** to reorder the stack (top = renders last, one
  undo per move, with an accent line showing where it will land); and **right-click a name**
  for the layer menu — rename, add an effect (by category) or a mask, duplicate, delete, and
  the solo and enable toggles, all in one place. Names are plain labels now, so dragging over
  one never smears a text selection across it. Opening a layer's twirl no longer also unfurls
  its Transform group — Transform starts closed, so you see a tidy list of section headings
  (Transform, Effects…) each sitting in its own faint bar, and open only the one you want.
- **Reordering effects** — in the Effect Controls panel (or a layer's Effects group in the
  Timeline) each effect's name is a drag handle: drag it up or down to restack the effects,
  one undo step. Each effect's title sits in its own subtle bar so it is obvious where one
  ends and the next begins. Dragging an effect out of the **Effects & Presets** browser now
  drops onto the *whole* layer row — the name side as readily as the lane — and onto the
  Effect Controls panel too, not just the sliver of lane past the bar.
- The **2.5D camera** — the parallax tool. Every layer has a z position and x/y
  rotations alongside the flat transform; they sleep until you switch the layer to 3D
  (the "3D" toggle in its twirl-down) *and* the comp has a Camera layer
  (Composition → Add camera layer). The camera follows the After Effects model: its
  *zoom* is a focal distance in comp pixels, and a layer sitting at z = 0 draws
  pixel-for-pixel exactly as it did flat — so turning the system on changes nothing
  until you actually move something in depth. Push a layer back (positive z) and it
  shrinks by zoom ÷ (z + zoom); move the camera and near layers slide faster than far
  ones — that's parallax, the flow style's second-most-used trick after speed ramps.
  The topmost visible Camera layer wins when there are several (AE's rule), everything
  on it keyframes like any other property, and the maths lives in one place
  (`camera_matrix` in the GPU crate) shared by preview and export, so a camera move
  can't look different in the exported file. A regression test proves both promises:
  z = 0 maps 1:1, and depth scales exactly as the formula says.
- **Adjustment layers** (Composition → Add adjustment layer) — a comp-sized layer with no
  picture of its own: its effects apply to *everything beneath it* on the stack, so one
  colour balance or blur can treat a whole composite at once (K-091). How it works, in
  kitchen terms: when the render reaches an adjustment layer, it takes a snapshot of
  everything cooked so far, runs the layer's effect stack on that snapshot, and then blends
  the treated and untreated versions back together. What controls the blend is *coverage* —
  draw masks on the adjustment layer and only the masked region gets the effects; lower the
  layer's opacity and the effects fade partway; move or scale the layer and the affected
  *region* moves, never the picture itself. Add the Transform effect to one and you can pan,
  rotate or zoom the whole composite below — the punch-in trick the effect was built for.
  Both the preview and the export walk the exact same staging code (and every effect runs
  through one shared "run the stack" routine, `fxops`, so a new effect wired up once works
  in the preview, in exports, and on adjustment layers with no extra plumbing). One honest
  limit: a live adjustment layer inside a collapsed precomp quietly turns the collapse off
  for that precomp (the switch dims) — its effects must see only its own comp's contents,
  which splicing into the parent cannot honour. It still reuses the solid's glyph for the
  moment; a distinct icon is a small later touch.
- **Null layers** (Composition → Add null layer) — an invisible layer that is nothing but a
  transform: no source, no size, no pixels, and it never appears in the picture. Its whole
  job is to be something to parent *to*. Park a null in a comp, parent five layers to it,
  and moving, rotating or scaling the null moves all five together while each keeps its own
  animation on top — the standard rig for a camera-style push or a group that has to travel
  as one. Change your mind about the move and you re-animate one layer, not five.
  Mechanically it is the emptiest kind in the model: the evaluation graph skips it entirely
  (it emits no node, so it costs no drawing pass), the renderer returns no pixels for it,
  and it answers "no" when asked whether it has a picture — so it is never offered as a
  matte source or as a layer-valued effect parameter, where picking it would have quietly
  produced nothing. It is *not* invisible to the frame cache, though, and that distinction
  matters: the transform still feeds the key that decides which cached frames are still
  good, so nudging a null correctly throws away the cached frames of everything hanging off
  it. Two honest limits for now. You cannot click a null in the Viewer — After Effects draws
  its null as a grabbable 100×100 box, whereas Lumit's has no size at all, so you move it
  from its Timeline property rows. And effects added to a null are accepted and then never
  run, since there are no pixels for them to touch; harmless, the same as on a camera, but
  not yet either refused or labelled.
- **The window layout** (K-074, refined by K-086) — the picture (the Viewer) fills the middle
  with nothing above it: no tab, no strip, just the image. Around it sit the other panels:
  Project and the effect panels stacked as tabs on the left, scopes on the right, the
  Timeline along the bottom. A panel only shows a little title tab when it shares its spot
  with other panels; a panel sitting alone — the Timeline, scopes — is as bare as the Viewer,
  so there is no needless "Timeline" label above the timeline any more (K-086). Stack two
  panels together and the tab bar appears by itself; drag a tab to move a panel somewhere
  else — beside another panel, stacked as tabs, above or below — and drag the edge between
  two panels to resize. Tabbed panels keep the small pop-out button that lifts them into
  their own separate window, and dragging a tab does the moving; a bare panel has no tab bar
  to carry either, so it gets its own pair of affordances (owner request): **right-click
  anywhere empty in it** for a "Pop out into its own window" menu (the Timeline's existing
  right-click-the-comp-strip pop-out still works exactly as before — it is the same
  mechanism, just no longer a special case), and **a small grip in its top-right corner** to
  drag it to a new spot, the same as dragging a tab would. The grip sits in its own tiny
  corner rather than spreading the drag gesture across the whole empty top strip, because of
  a trap worth knowing wherever drag regions are written: a region that senses dragging does
  not automatically step aside for an ordinary button drawn on top of it the way a plain
  click does — dragging is tracked from the moment the mouse is pressed, not by "whoever
  is visually on top" at release, so a wide drag-sensing strip sitting *underneath* a panel's
  own buttons could reach in and steal an ordinary click-and-slightly-move as a pane-drag
  instead. Keeping the grip small, and adding it *after* (visually on top of) the panel's own
  content, keeps it out of that trap. Closing any popped-out window drops the panel back
  where it was. A workspace saved before this change tidies itself the first time it loads.
  Under the bonnet this uses a "tiling" layout engine that, unlike the docking library we
  tried first, is happy to leave any lone pane without a tab bar.
- **The Scopes panel** (`shell/scopes.rs`, K-096) — the colourist's instruments. Instead of
  showing the picture, a scope plots its numbers: the **waveform** shows how bright each
  column of the image is (bright at the top, dark at the bottom), the **histogram** counts
  how many pixels sit at each brightness, and the **vectorscope** plots colour on a circle
  (hue as the direction, how vivid as the distance from the middle — a grey picture is a dot
  in the centre). Each Scopes panel shows one of these, picked from the little row of buttons
  at its top, so you can open a few side by side. It reads the frame you are looking at in
  the Viewer — the one under the playhead — and re-reads it every time it redraws, so the
  scope now **follows the picture while it plays** (K-130): each time you press play, Lumit
  keeps a little run of frames ready in memory (it warms them ahead of the playhead and while
  you sit paused), and the scope traces whichever one is on screen. If a frame hasn't been
  kept in memory yet — Lumit skips saving some frames during playback to stay fast — the scope
  simply holds the last frame it had rather than going blank, and snaps back to live the
  instant the current frame is ready. The counting itself now runs on the graphics card (the
  GPU scope pass, K-096 v1 — `crates/lumit-gpu/src/scope.rs`), so tracing every frame costs
  almost nothing; the CPU counting in `shell/scopes.rs` remains as the fallback for a machine
  with no adapter. See GUIDE §9 for the plain-English tour of the GPU pass. The scope's
  own colours (the near-black background, the green trace, the red/green/blue channel
  colours) are fixed and the same in light or dark mode, for the same reason the Viewer's
  surround is a fixed neutral grey — you cannot judge an image against a background that
  keeps changing brightness.
- **The command palette** (`shell/command_palette.rs`, K-102) — press **Ctrl/Cmd+Shift+P**
  (or Window → Command palette…) and a search box appears with a list of commands under it:
  save, undo, new composition, add a layer, switch the colour scheme or panel shape, open
  Settings, export. Start typing and the list narrows to what matches — you don't have to
  type the words in full or in order, just the letters in sequence ("nc" finds "New
  composition"). Arrow keys move the highlight, Enter or a click runs the highlighted one,
  Escape closes. It is the fast way to reach anything without hunting through menus. It is
  not the effects radial menu (that is a separate, still-to-come tool for dropping an effect
  onto whatever is under the cursor) — this is the plain app-wide command list.
- **The Hierarchy panel** (`shell/hierarchy.rs`, K-102) — a foldable outline of the
  composition you are working on: its layers, and where a layer is itself another
  composition (a precomp), a little triangle folds it open to show that composition's own
  layers, and so on down. It is the map of a nested project — which composition is built
  from which — and clicking any row jumps you to that layer. It only shows the structure, it
  never changes it. It is the simple tree version of the fuller node-graph flowchart that
  comes later.
- The **Project panel** — AE-shaped (K-068): a **search box** across the top, the selected
  item's details just under it, the folder tree below, and drag-and-drop everywhere. The
  search box filters the tree live by name as you type (case-insensitive; a folder stays
  visible when anything inside it matches, so you always see the path down to a hit), and
  clearing it shows everything again (UI-3). The details box now keeps a **fixed height**
  whatever you select, so the tree beneath it no longer jumps around as you click between
  items; and when the selected item is footage it shows a small **thumbnail** of the frame on
  the left — reusing the very frame the Viewer already decoded rather than decoding a fresh
  one, with a plain placeholder shown until a frame is to hand (UI-4, K-157). **Double-click
  a composition to open it** in the Timeline; double-clicking anything else renames it where
  it sits, and a comp is renamed from its right-click menu or its settings dialogue instead.
  Drag footage onto the Timeline or Viewer to make a layer; with no comp open yet, dropping
  it on the empty Timeline raises the composition dialogue already filled in from that
  footage, and the clips land in the comp it makes. Solids are proper assets now — one "White solid"
  in the project can back fifty layers, and the first one you make creates a Solids
  folder that future solids follow even if you rename it or tuck it inside another
  folder (Lumit remembers the folder itself, not its name). Compositions do the same
  with a Compositions folder. Multi-step creations like that land as a single undo
  step — a batch operation whose inverse is just the reversed inverses of its members.
- **The evaluation graph (`lumit-eval::graph`)** — before rendering, Lumit lowers a
  composition into a wiring diagram: for each layer a short chain of typed steps — fetch the
  source, retime it, mask it, place it (transform), then blend it over everything beneath —
  ending in a single "comp output". It is built bottom layer first, exactly the order the
  picture is stacked up. The neat part is *folding*: a layer with no masks gets no mask step, a
  footage layer with no retime gets no retime step, so the renderer never spends a moment on a
  no-op. It also shares work: two layers on the same footage compile to a *single* decode step
  (keyed by the source, never the layer), so a duplicated clip is fetched once, not twice. The
  diagram is rebuilt whenever you edit, and every render already in flight keeps the
  diagram it started with, so an edit can never half-apply to a frame mid-render. Today this
  builds the render's *shape* (tests prove the folding and the bottom-first order); turning each
  step into pixels on the GPU is the next slice. This is the front half of **Nova**.
- **Epochs (`lumit-eval::epoch`)** — the cancellation mechanism the whole scheduler
  will stand on. Every scheduled job carries a ticket stamped with the number that was
  on the wall when it started; scrubbing or stopping turns the wall number over, and
  workers glance at the wall between small steps and quietly stop if their ticket is
  stale. Nothing is ever force-killed. A test proves a deliberately slow job stops
  within 15 milliseconds of the number changing.
- **The worker pool (`lumit-eval::pool`)** — the crew of threads that will do the
  rendering, so the interface thread never has to. Picture a small workshop with two
  in-trays: an *urgent* tray (the frame under your cursor, a scrub) and an *everything
  else* tray (warming the cache, thumbnails). Whenever a worker finishes a job it always
  takes from the urgent tray first, so scrubbing never queues behind housekeeping. Both
  trays have a fixed size on purpose: if one fills up, new work is refused on the spot
  and the caller decides what to drop — work can never silently pile up behind a stall.
  The pool never kills a running job; jobs stop *themselves* by glancing at the epoch
  wall (previous bullet). The crew size is your machine's core count minus three — one
  core each left free for the interface, the GPU feeder, and the operating system.
  Tests prove the urgent-first rule, the fixed tray sizes, and that a misbehaving job
  can't take a worker down with it.
- **The pixel-pass walker and its plug sockets (`lumit-eval::exec`)** — the piece that
  walks the wiring diagram (two bullets up) and turns it into an ordered list of actual
  work. It starts at the final "comp output" box and works backwards: to blend a layer
  you first need its placed pixels, to place them you first need the source frame. Each
  box is done exactly once — two layers sharing a clip share the one fetched frame — and
  the real pixel work is done through three *sockets* it doesn't look inside: "fetch me
  this source's frame", "run this one step", and "have we rendered this exact frame
  before?" (the cache, checked before doing anything and filled afterwards). Because the
  sockets are plug-shaped, the tests plug in cardboard fakes — no GPU, no codecs — and
  prove the order, the sharing, the cache behaviour, and that a scrub landing mid-walk
  abandons it cleanly. A second proof goes further: a *walking skeleton* test in
  `lumit-gpu` plugs the **real GPU compositor** into the sockets, renders solid-colour
  layers through the walker, reads the pixels back, and checks the colours are exactly
  right — including that two layers blend in linear light and that a cache hit does zero
  GPU work. So the sockets are proven to fit the real machinery; what remains is teaching
  the adapters the full layer vocabulary (transforms, masks, retimes, effects) and then
  switching preview and export over. Until then the shipped renderer in `lumit-render` keeps
  drawing the picture.
- **Two ways to play back (`lumit-eval::schedule::cached_step`, K-171)** — the important
  distinction between the two preview modes. In **Cached** mode (the default), Lumit shows you
  *every* frame and never skips: the playhead only moves on to the next frame once that frame
  has finished rendering, and no faster than real time. So if a comp is heavy and rendering is
  slower than real time, playback simply slows down to match — you see every frame, just not at
  full speed — and once a stretch is rendered it plays back at true speed from the cache. Sound
  pauses while a frame is being waited for (so it never runs ahead of a frozen picture) and
  plays during smooth realtime replay. One subtlety a tester caught: the app only gets to move
  the playhead when the screen refreshes, and refreshes never land exactly on a frame boundary —
  if the pace timer restarted "from now" at each step, the few spare milliseconds were thrown
  away every frame, the picture crept along slower than true speed, and the sound (which runs on
  the audio hardware's own clock) drifted ahead and kept getting yanked back. The fix is the
  metronome trick (`cached_pace_carry`): the leftover is *carried into the next frame's window*,
  so over any stretch the picture holds exactly true speed and stays with the sound. A genuine
  freeze (dragging the window, say) is not "repaid" — the timer re-anchors rather than
  fast-forwarding. And the rule for *when sound runs* is readiness, not history (the owner's
  second report — audio used to sit out a quarter-second "warm-up" even on a fully cached run):
  sound plays exactly when the coming quarter-second of frames is already cached, so a ready
  run has audio from its very first frame, a still-rendering stretch stays silent rather than
  flapping on and off at the render's crawling edge, and after a stall it rejoins the moment
  the road ahead is paved. In **Realtime** mode, the opposite trade: the clock never
  waits, and when frames can't keep up Lumit drops the preview *resolution* to stay in time
  rather than slowing down. The stepping decision — advance, or hold and render, and whether
  sound should be playing — is a plain tested function; the messy wiring (the audio clock, the
  render requests) lives in the UI and just asks it what to do each screen refresh.
  The way realtime keeps from freezing is a small but important rule: it renders **one frame
  at a time and never throws that render away just because the clock moved on**. It asks for a
  frame, lets it finish however long it takes, shows it, times it — and only *then* asks for
  the next one, at wherever the clock has reached by that point (skipping the frames in
  between). The timing of each finished frame is what tells the resolution controller to drop a
  notch when things are slow. The earlier version re-asked for a new frame every screen refresh,
  so under load each render was abandoned before it finished: nothing ever completed, the
  controller was never told how slow things were, and the picture sat frozen. Rendering one
  un-abandoned frame at a time fixes both — the picture always moves forward, and the
  resolution actually adapts. (A cached frame still shows instantly and for free, without
  waiting on any render.) The "how slow was that frame" measurement is taken on the worker
  thread as the actual decode time, *not* as the time from asking to seeing — the latter
  would fold in how often the screen happens to refresh (~16 ms), making even a cheap comp
  look exactly one refresh slow and walking the resolution down for no reason. One honest
  limit worth knowing: dropping the preview resolution makes the *compositing and effects*
  cheaper, but video *decoding* costs about the same whatever size you view it at (the whole
  frame is decoded, then shrunk). So on a comp whose cost is mostly raw footage decoding,
  realtime can still look a little choppy even at a low resolution — the smooth path there is
  Cached mode, which renders ahead and then replays from memory. Truly smoothing realtime for
  decode-heavy comps needs *rendering ahead* (a shelf of frames prepared before their time
  comes), which is the `FrameRing` machinery that is built and tested but not yet wired in.
- **The frame scheduler's brain (`lumit-eval::schedule`)** — the decision rules for
  smooth playback, written as plain arithmetic so tests can prove them. During playback
  Lumit renders frames ahead of the playhead onto a small shelf; each screen refresh
  takes the newest shelf frame whose time has come, quietly binning ones the clock has
  passed, and simply holds the last picture if rendering falls behind (sound never
  waits). How far ahead to render adapts to how slow frames have actually been, between
  8 and 16 frames. And in realtime mode, frames too slow for the frame budget drop to a
  coarser preview resolution within a frame or two, earning it back only after a
  sustained cheap stretch — quick to worsen, slow to improve, so the picture never
  flickers between qualities. None of the real machinery (threads, the audio clock, the
  GPU) lives here yet; this is the referee, and the players arrive later.
- **Preview resolution never changes where things are.** To keep the picture responsive,
  Lumit can decode footage smaller than its true size — and "Auto" resolution decodes at
  exactly the size the layer is shown on screen, so it gets sharper as you zoom in. That is
  purely a quality choice: a layer's *position and size in the composition* are always
  worked out from the footage's real pixel dimensions, not the shrunk-down preview copy. If
  they were ever worked out from the preview copy, a layer would appear to grow as you
  zoomed in — which is exactly the bug this rule exists to prevent.
- **Scrubbing shows a draft instantly, then sharpens.** While you drag the playhead (on the
  timeline ruler or the footage scrub bar), Lumit decodes a small, quick version of each
  frame so the picture keeps up with your cursor — the same "keep moving, drop quality" idea
  the playback engine uses. The instant you let go, it reloads that one frame at whatever
  resolution you've chosen (Full, Half, Auto…). The quick draft frames are shown but never
  saved into the frame cache, so the cache only ever holds full-quality frames, and the
  background pre-rendering pauses while you scrub so it doesn't compete for the disc and CPU.
- **Dragging a value — or a keyframe — updates the picture live.** When you drag a value like
  Position or Scale, the viewport follows your drag immediately, before the edit is written
  down. Dragging a keyframe in the graph editor does the same: the picture shows what the curve
  now gives *at the current frame* as you move the key. It can do this cheaply because moving or
  scaling a layer doesn't change *which* frame of the footage is shown — only where it sits — so
  Lumit keeps the last decoded frame and simply re-arranges it with your in-progress value each
  tick, no re-decoding. The moment you let go, the edit is committed as a single undo step and
  the frame re-renders normally.
- **Idle time is spent pre-caching nearby frames.** When you stop on a frame and aren't
  playing or dragging, Lumit quietly renders the frames around the playhead into the cache
  at your chosen resolution, so stepping or scrubbing to them is instant instead of waiting
  each time. It works outwards from the playhead but favours the frames *ahead* — roughly
  three ahead for every one behind — because that's usually where you're going next. It fills
  one frame at a time and any real request (a scrub, an edit) immediately takes priority.
  During playback it keeps warming *ahead of itself* too: the audio card's clock decides which
  frame to show and never waits, so whenever the frame under the playhead is already cached
  Lumit spends the spare moment decoding the next uncached frame a short way in front of the
  clock (about a dozen frames' lookahead). That's why the first pass over a cold section can
  stutter but the work-area loop settles into perfectly smooth playback once round.
- **The cache has to know when a file's *identity* changed, not just the project.** Every
  cached frame is filed under a "frame key" — a short fingerprint of everything that
  decides what the picture looks like, worked out from the project. Ask for the same frame
  again, get the same key, and Lumit can hand back the picture it already has instead of
  re-rendering. That works because the project is the whole story… almost. Checking a file
  is really on disk happens on a background thread, so for a moment after opening a project
  Lumit genuinely does not know whether a clip exists, and draws that layer as nothing. The
  project hasn't changed when the answer arrives — but the picture has: the layer now shows
  colour bars. Same key, different picture, which is exactly the thing a cache must never
  allow.
  Throwing away the cached frames when the answer lands is half the fix, and the half that
  isn't enough: the pre-cacher above has *already sent off* renders of the neighbouring
  frames, and those come back a moment later, drawn without the colour bars, and get filed
  under keys that now promise colour bars. That was a real bug — the missing-footage bars
  showed on the frame you were sitting on and every other frame in the composition went
  black. So Lumit keeps a counter, the *media epoch*, which ticks whenever an answer changes
  what a file is. Every render request is stamped with the counter's value, the finished
  frame carries the stamp home, and anything stamped with an old value is thrown away rather
  than shown or filed. It is the render-queue equivalent of binning work that was started
  from an out-of-date brief.
- **Mask editing in the Viewer** — select a layer with masks and its outlines draw
  over the picture in clay, with a square handle on every vertex. Drag a handle and
  the outline follows your cursor live; let go and the pixels update — one undo step
  per drag, like every other edit. The maths mirrors the layer's transform both ways
  (screen position → layer space and back), so handles stay glued to the picture at
  any zoom, pan, scale or rotation. The Pen button in the Viewer bar arms
  click-to-place drawing: each click drops a vertex, clicking the first one (it grows a
  ring once closable) closes the shape into a mask, Escape cancels, right-click on any
  handle removes a vertex. Curved tangent handles are the remaining slice.
- **Origin (anchor point)** — every layer's transform now starts with Anchor x / Anchor y:
  the point the layer scales and rotates *about*, and the point Position places in the
  comp. New layers default it to the centre of their content and sit centred in the comp
  (the After Effects default), so a fresh clip spins about its middle rather than its
  top-left corner. The selected layer shows its origin as a small clay crosshair in the
  Viewer, and you can **drag that crosshair to move the origin** — the layer stays put
  while its pivot shifts (After Effects' "pan behind", position compensates automatically),
  committed as one undo step.
- **The tool strip** — the row of buttons under the menu sets what a Viewer drag does,
  the way every editor's toolbar does. Select (V) and Hand (H) both pan the view for
  now (object selection comes with the object tools); Shape (Q) rubber-bands a new mask
  — right-click the Shape button to choose rectangle, ellipse or star; Pen (G) is the
  click-to-place mask drawing above. The mode is one value (`ToolMode`) the Viewer reads
  each frame, so the whole app agrees on what the mouse is doing.
- **Masks on Precomp layers** — a masked transition can now wipe a whole nested comp,
  the flow staple. Pixel layers (footage, solids, text) get their masks applied on the
  CPU before upload; a Precomp's pixels only ever exist on the GPU, so its mask stack
  is rasterised into a little coverage texture instead and the compositor multiplies
  it in per-fragment. Same maths, two routes — a GPU test pins the texture route to
  the CPU one.
- **Collapse transformations (Precomp layers)** — normally a nested comp renders to its
  own little picture first, and the parent then moves/scales that picture: two rounds of
  resampling, and anything poking outside the nested comp's edges gets cut off. The
  **collapse switch** (the sunburst on a Precomp layer's row) removes the middle step:
  the inner layers composite straight into the parent, their transforms multiplied into
  one matrix, so content is resampled once and nothing clips at the nested bounds — the
  quality move AE users expect for scaled-up precomps. Some things genuinely need the
  middle picture (a mask on the Precomp layer, a blend mode, opacity below 100%, using
  it as a matte) — then the switch dims to say "set, but overridden". The undoable
  switch lives in ops like every edit; the cache knows collapse changes pixels, so
  toggling it re-renders.
- **Pre-composing (`Ctrl+Shift+C`)** — the opposite move to collapse: take layers you
  already have and wrap them in a comp of their own, which then sits in their place as
  a single Precomp layer. Useful when a group has grown into one thing you want to
  treat as one thing — blur it, mask it, move it, all at once.

  A dialogue asks first, because two of the choices genuinely change what you get. The
  first is where the **attributes** go: a layer's transform, effects and masks can
  travel into the new comp with it, or stay behind on the Precomp layer standing in its
  place. Staying behind is the one you want when you are wrapping a layer so that
  something can act on it *from the outside* — but it only makes sense for a single
  layer, since a group of layers has no one layer for the attributes to stay on, so with
  several selected the option greys out. The second is whether the new comp is as long
  as the one it came out of, or trimmed to just the stretch the selected layers cover.
  Either way nothing moves in time: trimming shifts the packed layers back by exactly as
  much as it moves the Precomp layer forward. Your answers are remembered for next time.
- **Blend modes** — the full After Effects colour set (T24): Normal; the darken group
  (Darken, Multiply, Colour burn, Linear burn, Darker colour); the lighten group (Add,
  Lighten, Screen, Colour dodge, Lighter colour); the contrast group (Overlay, Soft light,
  Hard light, Linear light, Vivid light, Pin light, Hard mix); the comparative group
  (Difference, Exclusion, Subtract, Divide); and the component group (Hue, Saturation,
  Colour, Luminosity). The dropdown groups them with dividers exactly as AE does. Two
  families under the hood: Add, Subtract and Multiply are physical light maths and run in
  linear; the rest are the Photoshop-era formulas people know by eye, so Lumit runs them on
  encoded values (running them in linear is tidier maths and the wrong look). Add pours
  light in; **Subtract** is its mirror — it takes the top layer's light away and stops at
  black, never going negative (K-151). Lighten and Darken are a simple per-channel max/min
  where the distinction doesn't matter; **Darker/Lighter colour** compare the whole pixel by
  brightness instead of each channel. The four component modes borrow one property (the hue,
  the saturation, the colour, or the brightness) from the top layer and keep the rest from
  below. Every mode is pinned to its textbook formula by a GPU test. (Dissolve and the
  stencil/silhouette alpha modes are still to come.)
- **Colour depth, in one paragraph.** Lumit's frames are "half float" (fp16) in linear
  light. Unlike AE's 16bpc — which is integer maths that clips at 1.0 — half float
  keeps brightness above 1.0 (a glow can genuinely overshoot) and negatives, which is
  what people switch AE to 32bpc for. Depth is one project-wide switch (8 / 16 float /
  32 float — K-069): flip it and every comp and effect in the project renders at that
  depth, AE-style, via a small button at the foot of the Project panel. Full float
  doubles every frame's memory and roughly halves compositing throughput, so 16-float
  stays the default; the heavy maths inside effects can run wider internally either way.
- `flutter_ui/lib/theme/theme.dart` — **the design tokens.** The only file allowed to contain
  colour values. Change a colour here, it changes everywhere. As of K-084 the look follows
  the *structure* of rerun.io's viewer (a data-tools app whose interface the owner likes):
  the app's background is nearly black, panels sit just above it, and menus float a clear
  step higher on a soft shadow; buttons have no borders — you can tell idle from hovered
  from pressed purely by how light their fill is; scrollbars are thin and solid; panel
  edges are single crisp 1px lines. The colours themselves (the clay accent, the cool grey
  family) are still Lumit's own — we borrowed the skeleton, not the skin.
  *(A note on the Settings window paragraphs below: they record the full design as the
  egui shell shipped it. The Flutter Settings window is now the same shape — a sidebar of
  pages, grouped cards, a setting's name and a line about it on the left of each row and
  its control on the right — but carries four pages rather than five: **General**,
  **Appearance**, **Interface** and **Performance**. Export and Autosave have nothing
  behind them on this frontend yet, and a page with no working controls would be a promise
  the window cannot keep; they are tracked in [TODO.md](TODO.md).)*
  Five appearance controls live in the **Settings window** (K-098) — open it from
  **Window → Settings…** or **Ctrl/Cmd+comma**. That window is Lumit's application-settings
  surface, shaped like macOS's System Settings: a list of pages down the left (General,
  Appearance, Interface, Performance, Export), and on the right the chosen page's settings in grouped
  cards, a label on the left of each row and its control on the right. It follows the
  Sharp/Round look like everything else — rounded filled cards under Round, hairline-framed
  under Sharp.
  The **Appearance** page carries the theme controls (they used to sit in the Window menu):
  **Mode** switches the whole app between Dark and a new Light theme — one
  plain white for every panel on a soft neutral canvas, not a tinted panel per section (that
  idea is wanted, but saved for a future setting rather than built now); **Background**
  (only shown under Dark, since there's nothing to pick under Light) switches between the
  near-black ramp and the previous bluer one; **Accent** lets you pick any colour for the
  app's single accent — selection, the playhead, active states all follow it, since they are
  one token; **Shape** switches between the existing sharp, edge-to-edge look and a new
  Round shape — panels float as rounded cards with real gaps between them and the window
  edge, Figma-inspired, no blur or bevel, just a soft shadow standing in for the border; and
  **Animation** picks how much motion the UI's own chrome shows (All / Minimal / None) —
  this reaches things like a collapsing section's arrow or a dialog's fade-in, not (yet) the
  app's own dropdown menus, which don't animate at all today regardless of this setting. All
  five persist with your workspace; Reset returns the clay default for Accent.
  The **Performance** page of the same window is where you tell Lumit how hard to work your
  machine: how much memory its frame cache may hold, how much disk the on-disk cache may use,
  and how much video memory (VRAM, the graphics card's own memory) the cache of
  already-drawn frames on the GPU may hold. All three apply the moment you change them —
  nudge a budget down and the matching cache trims itself to fit at once. The defaults match
  what Lumit used before the page existed, so nothing changes until you move a slider. A
  **Clear cache** button underneath empties the memory and video-memory caches straight away
  (handy after a big edit, or if you just want a clean start) — the on-disk cache is left
  alone since clearing it would mean re-decoding footage from scratch. Beside it, a
  **Background fill** switch controls whether Lumit spends its idle moments quietly decoding
  the frames around wherever the playhead sits, so scrubbing nearby feels instant — switch it
  off and Lumit does nothing until you actually ask for a frame, trading that warm cache for a
  quieter machine when you're doing something else at the same time. On by default, matching
  what Lumit always did. Underneath that, a **Cache root folder** row shows where the on-disk
  frame cache currently lives — "Default (next to the project file)" until you change it — with
  a **Choose…** button that opens a folder picker and a **Use default** button that puts it
  back. This is for moving the cache off a slow or crowded drive: point it at a fast NVMe (or
  any other drive with room) and every project's on-disk cache is parked there instead of
  beside the project file, which also keeps a slow network or removable drive holding your
  project files from also taking the brunt of cache writes. Each project still gets its own
  cache folder under whatever root you choose — two differently-named projects, or even two
  projects that happen to share a file name in different folders, never collide. Changing this
  takes effect straight away, the next time Lumit notices the setting changed (well under a
  second): it does not require a restart or a re-open of the project. (More performance
  controls — CUDA acceleration, worker counts — arrive on this page as those systems gain their
  knobs.)
  The **Interface** page holds two controls that don't belong to a theme. **UI scale**
  is a slider from 75% to 200% that makes the whole app — panels, text, icons, everything —
  draw larger or smaller than your display's native scale, for a hi-DPI screen that reads too
  small or a projector that needs everything bigger; it applies the moment you move it, using
  egui's own zoom mechanism (the same one behind its built-in Ctrl+= / Ctrl+- zoom shortcut,
  here exposed as a persistent, saved preference instead of a one-off per-session nudge).
  **Show tooltips** is a single switch for every hover tooltip in the app at once — the icon
  names and shortcuts that pop up when you rest the pointer on a button. Both default to
  today's behaviour (native scale, tooltips on), so nothing changes for anyone until they visit
  this page.
  The **Export** page (K-119) holds two defaults for the export dialogue. **Default preset**
  is the preset that a plain "Export comp…" action starts from — pick a specific preset from
  the File menu's "Export preset" submenu instead and that always wins, regardless of what's
  set here. **Filename template** lets you write the suggested file name yourself instead of
  taking whatever the preset would otherwise call it, using three tokens: `{comp}` for the
  composition's own name, `{preset}` for the preset's usual file name, and `{date}` for
  today's date. Leave it blank (the default) and nothing changes — you get exactly the file
  name each preset always suggested. Whatever comes out is checked for characters Windows
  won't allow in a file name (like `:` or `/`, which a composition name could easily contain)
  and those get swapped out automatically, and the name always ends in `.mp4` even if you
  forgot to type it. Two rows from the fuller Export plan aren't here yet — export priority
  and which encoder to prefer — because nothing in Lumit today has a concept of either one to
  control; they'll appear once that machinery exists.
  The **General** page holds an **Autosave** group: how often Lumit quietly saves a spare copy
  of a saved project (in minutes) and how many timestamped copies it keeps, so a crash or a
  mistake never costs more than the interval. The defaults are the same 5 minutes / 5 copies
  Lumit always used; they are just adjustable now.
  The **focused panel** also wears a thin accent edge: whichever panel you last clicked is
  where keyboard shortcuts land, and the edge keeps that visible at a glance (the After
  Effects convention) — it follows the Round shape's card rounding too, when that's picked.
  Four more complete colour schemes live in `theme.rs` alongside Dark, Dark blue and
  Light (K-097): Gruvbox dark, Gruvbox light, Catppuccin Mocha and Catppuccin Latte, each a
  well-known palette from outside Lumit re-mapped onto its existing surfaces, text, accent and
  so on, rather than a new set of rules. All seven are picked from a single **Colour scheme**
  dropdown on the Settings window's Appearance page — the old separate light/dark and
  background-ramp rows folded into it. An older save that used the two-row picker migrates its
  choice into the new one automatically, so nobody's theme resets on upgrade.
- `flutter_ui/lib/icons/icons.dart` — **the icons: Iconoir** (K-085).
  Little pictures like the play triangle or the padlock come from Iconoir, a free
  professionally drawn icon family, so every glyph stays crisp at any size and always
  takes the theme colour (dimming on hover, turning accent when active) exactly like text
  does. Emoji are banned: a glyph is either from this set or deliberately drawn, never a
  character we hope the user's fonts carry — that's how the invisible stopwatch/arrow bugs
  happened. To add one, add a name to the `LumitIcon` list and its Iconoir widget in the
  lookup.
- `flutter_ui/lib/main.dart` + `lib/shell/` — **the window**: panels, menus, shortcuts,
  and the state glue (current project, selection, the render worker's reply stream).
- **Layers can hang over the edges of the composition** (K-153, GEN-3). Think of a
  composition as a fixed-length window of time — say ten seconds. A layer used to be forced to
  live entirely inside that window: you could not slide it so it *started before* the comp's
  zero mark, and importing a clip longer than the comp chopped it down to fit. Now a layer sits
  wherever you drag it. Its start may be a negative time (it begins "off to the left", before
  the comp starts) and its end may run past the comp's end. The program only ever *shows and
  plays the part that overlaps the ten-second window* — the bit hanging off either edge is
  simply never asked for — but nothing is thrown away, so sliding the layer back brings the
  hidden footage straight back. Two everyday wins: a long clip keeps its whole length on
  import (you position it, the window trims the view, not the clip), and you can push a layer
  left so an earlier moment of it lands on the very first frame. Under the bonnet this needed
  almost nothing in the engine — the picture and the sound were already built to render only
  the overlapping slice — so the change was really just *removing* the old "snap it back inside
  the comp" rules from the drag and the import. One rough edge for now: the timeline can't
  scroll to show negative time, so a layer that starts before zero is drawn tucked under the
  left edge (you can still grab the part that's on screen).
- **Finding footage that moved (`lumit-project` fingerprint + relink)** — a project doesn't
  hold the video and audio files inside it; it *points* at them on disc. Move or rename a
  file and the pointer goes stale. Lumit now records, next to each pointer, a small
  **fingerprint** of the file: its size and a quick hash of the first and last chunk (never
  the whole thing, so it stays instant even on a feature-length movie). When a project opens,
  each pointer is resolved in order — first the path relative to the project, then the last
  full path it was seen at, then, if both miss, a **search by fingerprint** through folders
  you've told Lumit to look in — so a clip that was simply moved is found again by its
  *content*, not its name. Relink one file and its neighbours that moved the same way are
  offered automatically (the "it all went into a new folder" case). Nothing is a blocking
  error: a file that can't be found shows a placeholder and waits for you to relink it.
- **Collect for sharing (`lumit-project::collect_for_sharing`)** — one command copies the
  project and every file it uses into a single folder, rewriting the pointers to sit next to
  the copies. Nothing machine-specific is written (no "C:\Users\me\…" paths), so the folder
  opens cleanly on someone else's computer — the mechanism behind sharing a project with the
  community. Two clips that happen to share a name are copied under distinct names so neither
  overwrites the other, and anything that can't be found is listed rather than silently
  dropped.
- **Opening older projects (`lumit-project` schema migrations)** — the file format will
  change over time. So a saved project carries a version number, and when a newer Lumit opens
  an older file it walks it up through a chain of small **migration** steps — each one nudging
  the raw saved data from one version to the next — before the program ever tries to
  understand it as a real project. Today the chain is empty (this is the first format), but
  the machinery is in place, so future changes have a home and old files keep opening. A
  current-version file skips all of it and loads directly, so ordinary saves are untouched.
- **The frame cupboard decides what to drop (`lumit-cache`, docs 06 §5.3)** — the store of
  rendered frames has a strict size limit (a budget in megabytes, not a count — one big frame
  costs as much as many small ones). When it's full and a new frame arrives, it throws out the
  frame that's the *best bargain to lose*: one you haven't looked at in a while, that's large
  (frees the most room), and that's cheap to recreate — the "stale × big × cheap" rule. Two
  frames it will **never** throw out are ones that have been **pinned**: the picture on screen
  and the handful of frames either side of the playhead, so playback can't accidentally bin
  the very frame it's about to show. If the whole cupboard is pinned it simply runs a touch
  over budget for a moment rather than dropping something you need — the pins clear on their
  own as the playhead moves on.
- **Undo doesn't remember forever (`lumit-core::store`)** — every edit is remembered so you
  can undo it, but that memory can't be allowed to grow without end over a long session. So
  the undo history keeps at most a few hundred steps; once it's full, the *oldest* step falls
  off the back. You can't undo past that point any more, but nothing about your current
  project changes — dropping old history only limits how far back you can rewind. (Crash
  recovery is separate and unaffected: every edit is also written to a journal on disc as it
  happens, independently of this in-memory limit.)
- **Playback keeps time on a grid, not a stopwatch (`lumit-bridge::playback`)** — in
  every-frame mode each picture used to be allowed out "one frame period after the last one
  actually went out". That sounds right and is quietly wrong: every present is a little late
  (the thread wakes a moment after its alarm, the loop has bookkeeping), and measuring from
  the *actual* last present meant each frame's lateness was added to the next frame's
  schedule, forever. A 60 fps comp could never truly play at 60 — it settled around 55,
  cached or not, and the faster the comp the worse the shortfall. Now the due times sit on a
  fixed grid, one period apart: a present that goes out a millisecond late leaves the next
  one due at the *grid* time, so the small latenesses are absorbed instead of accumulating.
  Only a genuine stall (more than a whole period late) moves the grid, and then playback
  carries on at rate from where it is — every-frame still never skips a picture and never
  fast-forwards to catch up. The last two milliseconds before each due time are also waited
  out precisely (a busy wait) rather than slept, because an operating-system sleep is only
  as accurate as its timer, and oversleeping by one timer tick is a whole frame at 100 fps.
  On Windows that timer matters even before the busy wait: its default tick is about
  16 milliseconds — *twice* a 120 fps frame — so every paced sleep overshot its due time and
  a 120 fps comp could only manage ~85. The playback thread now asks Windows for
  1-millisecond timing when it starts (`timeBeginPeriod`, the request every media
  application makes), which is also what stops presents jittering by several milliseconds
  at 60 fps. That jitter had a second victim: the sound. The audio minder stops the sound
  when a picture arrives "late", and its allowance was a quarter of the frame period —
  2 ms at 120 fps, inside ordinary scheduler noise, so the sound kept stopping over
  pictures that looked perfectly smooth. The allowance now never shrinks below a few
  milliseconds, because the ear judges slip in milliseconds, not in frames.
- **Frames get their names from a memo (`lumit-bridge::names`)** — every cached frame is
  filed under a fingerprint of everything that goes into it, and computing that fingerprint
  means walking the whole composition at that frame's time. Cheap once; not cheap when the
  cache bar names hundreds of frames per redraw and playback names every frame it looks
  ahead to. The memo remembers each answer, keyed by composition, frame and preview size,
  and forgets everything the instant an edit lands (an edit renames an unknown set of
  frames, so remembering across one would be guessing). The result: during playback of an
  unchanged project, naming a frame costs a lookup instead of a walk — which is most of what
  made the timeline's cache stripe expensive to keep fresh while playing.
- **The disk cache is asked early, and given a moment (`lumit-bridge` worker)** — a frame
  parked on disk takes a few loop turns to come back (read the file, decompress it), so a
  frame asked for at the instant it's needed *always* arrives too late, and used to be
  re-rendered from scratch even though a perfect copy sat in a file. Two fixes. First,
  pressing play now asks the disk for the first stretch of frames *before* the first render
  starts, so the reads run while playback is still warming up. Second, in every-frame mode,
  if the next frame's copy has been asked for and is on its way, the renderer waits up to a
  twentieth of a second for it rather than re-rendering — every-frame promises every frame,
  not any particular arrival time, and the copy is far cheaper than the render. (Adaptive
  mode never waits; it keeps chasing the clock.) And a frame that comes back off disk now
  keeps a copy in the memory tier too, so the *next* pass over the same span climbs from
  memory instead of reading the same files again — before this, a comp bigger than the
  graphics card's cache re-read its files on every single pass, and the disk's speed became
  the playback speed.
- **The cache stripe redraws without stealing playback's deadline (`lumit-bridge` worker)** —
  the coloured stripe over the timeline is computed on the same thread that renders playback
  frames. It used to restart its full sweep every half-second during playback (because every
  promoted frame changes what the caches hold, and any change restarted it), naming up to a
  thousand frames in one go — a visible hitch, rhythmically, all through playback of cached
  material. Now a sweep in progress finishes before any restart, the per-turn chunk is
  smaller while playback runs, and most names come from the memo above anyway. While
  playing, a frame already known to be parked on disk at the right size also skips the
  three extra "is a coarser version held?" checks — the stripe may briefly show blue where
  dimmed green was strictly truer, and it firms up the moment playback stops. The stripe
  also greens **live** now: the sweep walks forward from the playhead, so the frames
  playback had just banked — always just behind it — were the last thing it reached, and
  the stripe sat frozen until you paused. Banking a frame now paints its own slot in the
  strip directly (the bank knows exactly which frame it filed), and each publish of the
  strip nudges the interface to redraw — the old wiring only nudged it when the *idle*
  cache fill banked something, which is precisely the thing that never happens during
  playback.
- **The frame-rate readout in the Debug View (`flutter_ui/lib/panels/performance_view.dart`)** —
  a small counter showing how fast the interface itself is drawing, which is how you tell "the
  engine is presenting at rate" from "the window is keeping up with it". It **watches** frames
  rather than asking for them: the engine reports what each finished frame cost, after the
  fact, and the counter reads those reports. The first version instead asked to be woken after
  every frame and redrew itself each time, which quietly pinned the whole interface at full
  drawing rate whatever the editor was doing — the meter became a large part of what it was
  measuring. It also hung every automated test that waits for the interface to go still,
  because "still" was the one state it made impossible. Watching costs nothing when nothing is
  moving, and the numbers on screen refresh five times a second rather than per frame, because
  a readout redrawn per frame is one more thing drawing per frame.
- **The stress project and speed benchmarks (`lumit-project::fixtures`, docs 13)** — the
  promise that Lumit stays responsive on huge projects needs something huge to test against.
  There's now a builder that makes a deliberately enormous project on demand — hundreds of
  compositions, thousands of layers, a quarter of a million keyframes — always *identical*
  down to the last byte, so a speed measurement means the same thing every time. Alongside it,
  a set of **benchmarks** time the everyday operations on that project (open it, save it, make
  one edit, undo). They run when a developer asks (`cargo bench`), and they'll later become
  pass/fail speed budgets in the automated checks.

## 5. Making a change safely (the recipe)

1. **Find the doc first.** Specs (`docs/00–16`) say what the behaviour should be; impl
   notes (`docs/impl/`) say how the hard parts work. If your change disagrees with a doc,
   the doc gets updated in the same commit — docs are canonical.
2. **Make the change.** The compiler is your ally: in Rust, most mistakes fail to compile
   rather than fail at runtime. Read its messages — they're unusually helpful and usually
   tell you exactly what to fix.
3. **Run `cargo test`.** Everything green? Your change didn't break any promise that's
   been made so far.
4. **Add a test for what you changed.** New behaviour = new test proving it. Fixed a bug =
   a regression test that fails without your fix (that bug can now never return unnoticed).
5. **Commit with a message saying what and why.** CI re-runs everything on every push.

Even if you never write the change yourself, this recipe is how you *direct* a model to do
it and check it did it right: point at the doc, ask for the change plus its test, look at
the test.

## 6. The testing philosophy (and your regression-coverage rule)

Standing policy, enforced in CI ([14-ENGINEERING-RULES.md](14-ENGINEERING-RULES.md) §tests):

- **Every feature lands with tests.** Not after — with. A feature without tests is not done.
- **Every bug fix lands with a regression test** that reproduces the bug first. The suite
  is a museum of every bug ever fixed, and none of them can come back silently.
- **Property tests** generate thousands of random inputs looking for edge cases humans
  don't think of (the time maths runs under these).
- **Golden tests** compare output against a known-correct reference — later, whole rendered
  frames get compared pixel-by-pixel, which is how "preview equals export" stays true.
- **Coverage is measured in CI** and the engine crates must stay above the threshold —
  it can only be raised, never lowered.

One budget deserves its own mention because it's the project's founding grievance: **the
interface must stay responsive with thousands of layers and hundreds of thousands of
keyframes** (the "stress document" budgets in
[13-PERFORMANCE-RULES.md](13-PERFORMANCE-RULES.md) §2.1). Two design rules deliver it: the
UI only ever draws what's visible on screen (so a 5,000-layer timeline costs the same as a
20-layer one), and the UI thread never does engine work. One known shortcut exists today —
saving a snapshot currently copies the whole document per edit, which is fine now and will
be replaced with "copy only what changed" before Phase 1 ends; it's recorded in the
performance rules so it can't be forgotten.

What the suite guards *today*: time maths exactness (6 property suites), undo/redo
symmetry, journal replay, the crash-recovery drill both ways, file-format round-trips,
unknown-field survival, autosave rotation, version refusal.

## 7. Words you'll meet in the code

| Term | Meaning |
|---|---|
| `fn` | A function |
| `pub` | Public — usable from other files/crates |
| `let` | Create a variable |
| `&thing` / `&mut thing` | Borrow it read-only / borrow it with permission to change |
| `impl X` | "Here are X's functions" |
| `#[derive(...)]` | Auto-generate boilerplate (comparisons, serialisation) |
| `#[serde(...)]` | Instructions for JSON conversion |
| `mod` / `use` | Declare / import a module |
| `Vec<T>` | A growable list of T |
| `HashMap<K, V>` | A dictionary/lookup table |
| `match` | A switch that must handle every case |
| `async` | Not used in Lumit's engine — we use threads and channels instead, deliberately |

When you hit something not covered here, ask any session "explain X in GUIDE.md terms and
add it to the guide" — that's the standing arrangement.

## 8. Building and running it on your machine

To turn the source into a running app you need the Rust toolchain and one outside
dependency: **FFmpeg**, the library that actually decodes and encodes video and audio.
Lumit doesn't reinvent that wheel; `lumit-media` talks to FFmpeg. So the build needs
FFmpeg present, and everyday `cargo` commands need to know where it is.

There are two moving parts, and it helps to know why each exists:

- **FFmpeg itself** — the video/audio engine. We use version 7.1. On Windows it comes as a
  folder with three important sub-folders: `lib` (the "how to call in" stubs the build links
  against), `include` (the description of what's callable), and `bin` (the actual `.dll`
  files the finished app loads while it runs, plus the `ffmpeg` command-line tool the tests
  use to make sample clips).
- **libclang** — a translator. FFmpeg is written in C, and something has to read FFmpeg's
  C descriptions and generate the matching Rust ones automatically. That translator is a
  piece of the LLVM toolchain called libclang. One gotcha, learned the hard way: use
  **LLVM 18**. A much newer LLVM makes the translator quietly produce nonsense (it turns
  whole data structures into blanks), and the build fails with confusing errors. Pinning 18
  avoids it.

### On Windows (the shipping platform)

1. Download `ffmpeg-n7.1-latest-win64-gpl-shared-7.1.zip` from the
   [BtbN FFmpeg builds](https://github.com/BtbN/FFmpeg-Builds/releases) page and unzip it
   under your user folder, e.g. `C:\Users\you\ffmpeg\`. (GPL because Lumit is GPL; "shared"
   because we want the `.dll` files.)
2. Install LLVM 18 and the Rust toolchain: `winget install LLVM.LLVM --version 18.1.8` and
   `winget install Rustlang.Rustup`. Rust's default Windows setup links with Visual Studio's
   C++ build tools, so having Visual Studio (or the standalone Build Tools) installed matters.
3. From the repo root, run `. .\scripts\win-dev-env.ps1 -Persist`. That one script finds the
   FFmpeg folder and LLVM, points the build at them, and (`-Persist`) remembers the settings
   so every future terminal already knows. The leading dot is required — it means "apply
   these to my current shell", not "run and forget".
4. Now the normal commands work: `cargo test --workspace` runs the engine's test suite,
   and `flutter run` from `flutter_ui/` launches the app.

### On macOS

FFmpeg comes from Homebrew: `brew install ffmpeg@7`. That formula is *keg-only* — Homebrew
deliberately does not put it where the system looks by default, because it is an older
version than the plain `ffmpeg` formula and linking it would shadow that. So the build has
to be told where it went, once, in the terminal you build from:

```sh
export FFMPEG_PKG_CONFIG_PATH="$(brew --prefix ffmpeg@7)/lib/pkgconfig"
```

Put that in your shell profile and every future terminal has it. macOS ships the translator
(libclang) as part of its developer tools, so there is nothing else to set up — then
`cargo test --workspace` works.

This line used to live in the repo's `.cargo/config.toml` instead, so nobody had to type
it. It was removed (K-204) because Cargo offers no way to make such a setting apply to one
platform only: the macOS folder was being handed to Linux builds as well, where it does not
exist, and the FFmpeg binding generator stops with an error rather than falling back. One
platform's convenience was the other's broken build, and macOS is the one with the unusual
requirement, so macOS is the one that says it out loud.

### On Linux (K-082)

Linux finds FFmpeg the same way macOS does — by asking the system's package registry
(`pkg-config`) where the libraries live — so the setup is: install the FFmpeg 7
*development* packages (the ones ending `-dev`, which carry the headers the binding
generator reads), plus `pkg-config` and `clang`. On Debian 13 or Ubuntu 24.10 and newer
that is one line: `sudo apt install pkg-config clang libavcodec-dev libavformat-dev
libavutil-dev libswscale-dev libswresample-dev libavfilter-dev libavdevice-dev`. On Arch
or Artix: `sudo pacman -S ffmpeg pkgconf clang18 llvm18` — note the **18**: those
distributions' plain `clang` package is a much newer LLVM, and as explained above a newer
LLVM makes the translator produce nonsense, so the versioned packages are the ones to
install.

Nothing about FFmpeg then has to be handed to the build: the packages put their `.pc`
description files where `pkg-config` already looks, which is where the build asks. One
setting may still be needed, and only on the distributions whose default translator is
newer than 18:

```sh
export LIBCLANG_PATH=/usr/lib/llvm18/lib          # Debian/Ubuntu: /usr/lib/llvm-18/lib
```

That says "use the *18* translator, not whichever one is the default" — on Arch and Artix
the default always is newer. Put it in your shell profile and every future terminal has it.
Then `cargo test --workspace`, and `flutter run` from `flutter_ui/` to launch the app.

Linux used to need a second export here, to undo a macOS folder the repo's
`.cargo/config.toml` handed to every platform. That setting is gone (K-204) and Linux is
plain again; if you are looking at an older checkout, deleting the `[env]` block from
`.cargo/config.toml` is what the fix amounted to.

One honest caveat: the build needs FFmpeg **7**, and some distributions still ship
FFmpeg 6 — Ubuntu 24.04 LTS is the big one. On those, `cargo build` will complain about
"ffmpeg stuff" (a version the binding doesn't accept, or missing headers). The fix is a
newer distribution release, or building FFmpeg 7.1 from source and letting `pkg-config`
find it.

(There used to be a **Flatpak** here — a ready-to-install Linux bundle. It packaged the
old egui application and was retired with it in K-182; Linux packaging for the Flutter
app is tracked in [TODO.md](TODO.md).)

One Linux-only difference worth knowing, because it looks like a bug otherwise: on Windows
and macOS Lumit *starts as* the little splash card — that small frameless window you see
during boot is the real window, and it grows into the editor when loading finishes. On Linux
it can't. Under Wayland an application isn't allowed to resize its own window (the desktop
decides), so the "now grow to full size" instruction was simply ignored and the editor stayed
trapped at splash size, unable to be dragged bigger. So on Linux the window opens at working
size straight away and the splash card is drawn in the middle of it.

### What the robots check

Every push, CI rebuilds and retests everything on **macOS, Windows and Linux**, media
included, so "it builds on my machine" can never quietly drift from "it builds for real".
The platform recipes above are exactly what CI does, written out by hand in
`.github/workflows/ci.yml`. The Linux job goes a little further than the others: it installs
Mesa's *lavapipe*, a Vulkan driver that renders on the CPU, so the GPU tests actually run on
a machine with no graphics card in it. And a sixth job builds the Flatpak, which is how we
know the packaging works and not just the code.

A rule the FFmpeg episode above taught, worth stating on its own: **a CI job that sets up
something a contributor would not have set up is not testing the contributor's build.** The
Linux jobs used to hand the build an explicit FFmpeg location before compiling, which meant
they never took the route a person with FFmpeg installed normally takes — and so they
stayed green for weeks while nobody could actually clone the repository on Linux and build
it. The jobs now leave that route alone and let the build find FFmpeg the ordinary way. If
a step exists purely to make CI work, ask who else has to run it.

### How Lumit knows how much memory your machine has (K-194, K-204)

Settings → Performance lets you type a cache size in megabytes, which means the engine
needs a real ceiling to check it against — offering to cache 64 GB on a 16 GB machine is
just a way to make everything swap to disk and crawl. So the bridge has two small
questions it can ask the operating system: how much RAM is installed, and how much memory
the graphics card has.

There is no one way to ask, because each operating system answers differently. Windows has
a single call for it. macOS has a general-purpose "ask the kernel a named question"
mechanism, and the question is called `hw.memsize`. Linux does not have a call at all: it
exposes a plain text file, `/proc/meminfo`, whose first line reads something like
`MemTotal: 16264532 kB`, and you read the number out of it. Three implementations, one
answer, and — this is the important habit — **every one of them returns 0 rather than
guessing** if the answer does not come back. The interface treats 0 as "not known here" and
falls back to a documented ceiling of its own, which is honest, where a made-up number
would quietly be wrong.

One oddity you will notice: on a 16 GB Linux machine the number comes back as roughly
15.5 GB, not 16. That is not a bug and it is not worth correcting. Linux reports the memory
*the kernel can actually use*, and some was already taken before the kernel started — by
the firmware, and by an integrated graphics chip carving out its share. The 16 GB is what
you bought; the 15.5 GB is what is there to spend. For deciding how big a cache may be, the
smaller of the two is the one you want, so reporting slightly low errs in the safe
direction. The video-memory answer leans the same way for the same reason: on a machine
with both an integrated and a discrete graphics chip it reports whichever the system lists
first, which may be the smaller one — again, a ceiling that is too low costs you some
speed, while one that is too high costs you the session.

## 9. The Flutter frontend, in plain terms

*(K-174. Flutter is now Lumit's frontend; the earlier egui code remains only as
the parity reference. The front/back boundary is specified in full in
[17-BRIDGE-CONTRACT.md](17-BRIDGE-CONTRACT.md).)*

**What Flutter and Dart are.** Flutter is Google's toolkit for building user
interfaces; Dart is the programming language it uses, roughly as readable as
TypeScript. Where egui redraws the whole window every frame from immediate
drawing commands, Flutter keeps a *widget tree* — a description of the
interface — and redraws only the parts whose description changed. That buys
polished text rendering, smooth built-in animation and a huge widget ecosystem,
at the cost of a second language in the repository and a *bridge* between the
interface and the engine.

**What moves and what stays.** Everything that opens files, decodes video,
composites frames, caches, mixes audio and exports stays exactly where it is,
in the Rust crates — the Flutter interface is a new front door on the same
house. The Dart code lives in `flutter_ui/` and is a stand-alone application:
you can build and run it without touching the Rust build, and vice versa.

**How they talk.** Dart cannot call Rust directly, so a bridge crate
(`lumit-bridge`) sits between them. Its shape is described further down (§9,
"The generated bridge"): Dart holds small *handles* naming things in the
engine — a project, a composition, a layer — and calls methods on them, rather
than passing whole documents back and forth. The Viewer is special: video frames
are too large to pass through function calls sixty times a second, so the engine
draws each frame into a piece of GPU memory that Flutter displays directly — the
picture never takes a detour through ordinary memory. The full contract is in
[17-BRIDGE-CONTRACT.md](17-BRIDGE-CONTRACT.md).

**The picture now stays on the graphics card (K-177).** For a while the Viewer
took exactly that detour: the engine drew the frame on the graphics card, copied
it down into ordinary memory, passed the bytes across to Flutter, and Flutter
copied them *back up* onto the card to show them — three copies of a full-size
picture, every frame. That was the biggest thing making scrubbing feel heavier
than the old egui app. On Windows this is now removed. The engine asks the
graphics card for a special *shared* texture — a piece of GPU memory Windows can
lend by name to another part of the program — draws straight into it, and hands
Flutter only the name (a small number, an "NT handle"). Flutter opens that name
and shows the texture directly with a `Texture` widget; no pixels are copied at
all. It is switched on with a build flag (`--features shared-texture`) and is
Windows-only, so it can be turned off without touching anything else. If the flag
is off, the machine has no suitable graphics card, or the runner is an old build,
everything quietly goes back to the copy-the-bytes way — nothing breaks, it is
just a little slower. One detail: the Scopes (the waveform/vectorscope displays)
still need the actual numbers, and the fast path deliberately keeps the picture
*off* ordinary memory, so the engine also does a slow copy a few times a second
just to feed the Scopes, while the fast texture drives the Viewer itself.

**Linux gets the same fast path, via DMA-BUF (K-177).** Windows shares GPU memory
by an "NT handle"; Linux's equivalent is a **DMA-BUF** — a file descriptor (a
small number the operating system uses to name an open resource) that names a
piece of graphics memory. The Linux build does exactly what the Windows one does,
with that primitive instead: the engine (running on Vulkan rather than Direct3D)
makes a special *exportable* image, draws the finished frame into it, and asks
the graphics driver for a descriptor naming its memory. It hands Flutter that
descriptor plus a few numbers describing the buffer's layout (its width, how many
bytes each row takes — the "stride" — and a code naming the pixel format). The
Linux runner imports that descriptor into an OpenGL texture (through a mechanism
called EGLImage) and shows it with the same `Texture` widget — again, no pixels
copied. It is switched on with its own build flag (`--features
shared-texture-linux`) and, exactly like the Windows path, degrades to the
copy-the-bytes way whenever it cannot be used: an old library, no capable
graphics card, or the specific graphics-memory-sharing features not being
available. The Settings kill-switch and the GPU/CPU transport indicator work
unchanged — the same controls cover both platforms. One honest caveat: the
authoring machine for this code runs Windows and *cannot build or run the Linux
half at all*, so CI only proves it **compiles** (both the Rust Vulkan code and the
GTK plugin). Whether the picture actually appears is the Linux collaborator's
check — the verification recipe is in §9.

**The DMA-BUF format we ship.** The exported image is 8-bit RGBA holding the
already-display-encoded bytes (byte-for-byte the same pixels the Windows path and
the slow copy path produce), laid out with plain "linear" tiling — no vendor-
specific memory scrambling. That keeps the graphics-driver requirements minimal:
we do not use the more advanced "format modifier" route the reference
implementation took, only the widely-supported external-memory feature. The
format is reported to Flutter as the DRM code `DRM_FORMAT_ABGR8888` (which, in
DRM's little-endian naming, means bytes in memory order red, green, blue, alpha —
matching what Flutter samples) with a "linear" modifier.

**Who owns the descriptor: the one rule the DMA-BUF path lives by.** A file
descriptor is just a small number — an index into a table the operating system
keeps for the program, saying "slot 7 is this piece of graphics memory". Closing a
descriptor means giving that slot back. The catch is that the number itself
carries no ownership: two parts of the program can hold the same number, and if
both close it, the second close frees a slot that has *already* been handed out
again — after which whoever now owns slot 7 finds someone else reading and writing
it. That class of bug is miserable to find, because nothing fails at the moment of
the mistake.

Lumit's rule is therefore: **each side of the boundary owns its own descriptor.**
The engine's Rust side owns the one it exported, and closes it when the shared
image is thrown away. What crosses to Flutter is only the *number*, to look at.
The Linux runner, when it registers the texture, immediately calls `dup()` — the
operating system call that means "give me my own second descriptor pointing at the
same thing" — and from then on it owns and closes only that copy. Neither side can
close the other's, and neither has to know when the other is finished. It costs one
table slot.

The corollary is that a failed `dup()` is not something to shrug at. If it fails
and the runner carries on with an invalid descriptor, the import quietly produces
nothing and the Viewer is black for the whole session with no error anywhere. So
the runner checks it and refuses the registration, which the Dart side reads as
"this path is not available" — a visible fallback instead of an invisible failure.

**macOS gets it too, via IOSurface (K-195).** The third platform, the third name
for the same idea. Apple's primitive for "two parts of a program pointing at one
piece of graphics memory" is an **IOSurface**, and it comes with something the
other two do not: a plain number that names it, so nothing awkward has to cross
the boundary at all. The engine (running on Metal, Apple's graphics interface)
creates a surface, asks Metal for a texture backed by it, draws the finished
frame into that, and sends Flutter the number. The Mac runner looks the number
up, wraps the surface in a `CVPixelBuffer` — a wrapper, not a copy, the same
memory seen through the type Apple's video machinery speaks — and hands it to
Flutter as a texture. Same `Texture` widget, same no-copy result.

Because that payload is one number plus a size, it is *exactly* the Windows one,
so macOS reuses the Windows message, the Windows channel call and the Windows
Dart code unchanged; only what the number means differs. Linux is the odd one
out, needing the stride and format alongside its descriptor. The one wrinkle is
colour order: Flutter's Mac texture path accepts a single pixel format, "BGRA"
(blue, green, red, alpha), so the renderer is asked to write its display bytes in
that order there — which it already knew how to do, because Windows wants the
same thing for its own reason. As with Linux, the authoring machine cannot build
or run the Mac half, so CI proves it compiles and one test checks the colour
order end to end; whether the picture appears on a real Mac is the collaborator's
check.

**The Scopes are computed on the graphics card now (the GPU scope pass, K-096
v1).** A scope reads the picture's brightness and colour — a waveform, a
histogram, a vectorscope. Both frontends used to work those out on the ordinary
processor, walking a quarter-million pixels of the frame every time the scope
redrew; with a scope open while scrubbing, that is what made it feel laggy (the
owner's report). The engine now does that walk on the graphics card instead. It
is three tiny GPU programs: one drops each sampled pixel into a counting bin
(many threads counting into the same bin safely, an "atomic add"), one finds the
tallest bin, and one paints the little 256×256 trace picture from the bins in the
scope's fixed colours. Only that tiny trace picture — a quarter of a megabyte —
comes back to ordinary memory; the frame it read stays on the card. We
deliberately did *not* give the scope its own fast shared texture like the Viewer
has: the trace is so small that the fast hand-off would save nothing, while
costing a second registered texture and its memory — the honest win here is the
counting, not the delivery. The scope traces the very same comp frame the Viewer
shows (same composition, frame and preview size), served from the frame cache
below, so the numbers and the picture never disagree, and the comp is not
re-drawn just to scope it. When the loaded engine is an older build without this
pass — or on a machine with no suitable graphics card — the Scopes quietly fall
back to counting on the processor, exactly as before. This lives in the engine
(`crates/lumit-gpu/src/scope.rs` + `scope.wgsl`), so both the Flutter and the
egui frontend can use it.

**Re-scrubbing a frame is now free (the frame cache, K-176).** Drawing one
composited comp frame — every layer, transform, blend and effect — is the most
expensive thing the Viewer does, and until now the Flutter app re-did it *every*
time you passed over a frame, even one you had just seen. The old egui app never
did that: it keeps a shelf of already-drawn frames in memory and, when you scrub
back over one, just takes it off the shelf. The bridge now has the same shelf
(`crates/lumit-bridge/src/framecache.rs`). Each finished frame is filed on the
shelf under a label, so scrubbing back and forth is a shelf lookup with no
drawing at all.

*What the label says has since changed, and it matters — see "The three-tier
cache" at the end of this guide (K-214).* As first built it said which comp, which
frame, at what preview size, and which version of the document — and because a
label like that does not change when the picture does, the only safe thing to do
on any edit was to throw the whole shelf away. The label is now a hash of what is
actually in the frame, so an edit that cannot change a pixel keeps every frame,
and an undo finds its frames still on the shelf. There is a size limit (a few hundred megabytes by
default, adjustable in Settings → Performance); when the shelf is full the
least-recently-seen frames are dropped to make room, and "Clear cache" empties it
on demand. A companion tidy-up: when you scrub quickly, a frame you have already
moved past no longer wastes a full draw finishing after you have gone — a newer
request tells the engine "that one is stale, skip it" before it starts.

**Seeing what is on the shelf (the cache bar).** A thin green strip now runs
along the bottom of the timeline ruler, over the frames whose picture is already
on that shelf — so at a glance you can see how much of the comp is ready to play
back instantly, exactly as the old egui app shows it. (At this point the Flutter
side kept its own note of which frames it had driven onto the shelf, because the
engine reported only *how many* were cached; the engine answers per frame now, and
the strip gained a steel-blue state for frames parked on disk — again, see the
K-214 section at the end.) The strip is scoped to the current preview size — which matters,
because the **resolution picker** (Full / Half / Third / Quarter in the transport)
now genuinely renders a smaller picture rather than a full-size one relabelled:
choosing Half asks the engine for half-resolution pixels, which are faster to
draw and get their own place on the shelf.

**Panels that keep their place.** A panel now remembers where it was scrolled to,
which twirl-downs were open, and a drag you had half-begun — even as you click
around between panels. This sounds obvious, but it took care to get right, and the
reason is a quirk of how Flutter decides whether to keep a piece of the screen or
throw it away and build it afresh. The clicked panel wears a thin accent outline so
you can see which one the keyboard is talking to; the trouble was that Flutter was
adding that outline by *changing the shape* of the panel's on-screen scaffolding —
and whenever the scaffolding's shape changes, Flutter can no longer line the old
version up against the new one, so it discards the whole panel and rebuilds it from
scratch, losing everything it remembered. The very click that lit the outline was
the click that wiped the panel's memory — which is why a scrolled list jumped back
to the top when you clicked elsewhere, and why the *first* attempt to drag a slider
in an unfocused panel did nothing (the click that focused it tore out the drag
before it could take hold; only the second try worked). The fix is to give every
panel that outline *all the time* and simply make it invisible (fully transparent)
when the panel isn't the focused one — the shape never changes, so Flutter keeps
the panel and its memory intact, and only the colour of the outline flickers
between accent and clear. The same care now covers **tabs**: stack a few panels
together and switch between their tabs, and the ones you flip away from stay exactly
as you left them, rather than resetting each time — the hidden tabs are kept alive
off to one side, doing no drawing and no per-frame work but holding their place,
the way the old egui interface remembered them.

**Where things are.** `docs/archive/flutter-port/` holds the historical port
notes: `01` the strategy
and phases, `02` an inventory of every surface the egui interface ships (the
port's shopping list), `03` the bridge design, `04` a table mapping each egui
mechanism to its Flutter counterpart, `05` the living checklist of what is
ported. The first phase rebuilds the *chrome* — theme, settings, dock, menus,
panels as placeholders — on a pretend engine, so the interface can be judged by
eye before any bridge work is spent.

**The bridge crate, and how F1 starts it.** The first real Rust↔Dart link is a
new crate, `crates/lumit-bridge`. It builds into a single shared library (a
`.dll` on Windows) that the Flutter app loads when it starts. The catch is that
Dart cannot yet call Rust functions with rich types directly, so this first
version — "bridge v0" — keeps the conversation deliberately plain: Dart calls a
handful of C functions (`lumit_bridge_new_project`, `lumit_bridge_snapshot`,
`lumit_bridge_new_composition`, `lumit_bridge_undo`, and so on), and each one
answers with a piece of **text in JSON format** describing what happened —
either `{"ok":true, …the document…}` or `{"ok":false,"error":"a calm sentence"}`.
Dart reads that text, hands the memory straight back to Rust to free
(`lumit_bridge_free_string`), and turns the JSON into ordinary Dart objects the
Project panel can draw. Later, once the set of calls has settled, a code
generator (`flutter_rust_bridge`) will write this glue for us; hand-writing it
now keeps the build simple while the shape is still moving. Two promises hold
whichever way the glue is written: a crash inside Rust can never tip over into
Dart (every function catches its own panics and reports them as an ordinary
error), and if the library is missing the app simply runs on its placeholders,
exactly as it did before the bridge existed — nothing breaks, the Project panel
just shows its "arrives with the engine bridge" hint again. `lumit-bridge`
depends only on the engine crates, and nothing depends on it, so it stays a leaf
that the rest of the project never has to know about.

**The code generator that is now replacing that glue.** The "later" above has
arrived: the generator is in the tree, and the two bridges run side by side while
the work moves across. It is worth understanding what changed, because it changes
how the panels are written.

*What the generator does.* `flutter_rust_bridge` — "frb" for short — reads the
Rust functions in `crates/lumit-bridge/src/api/` and writes, automatically, both
halves of the plumbing: the Rust side that packs values up
(`crates/lumit-bridge/src/frb_generated.rs`) and the Dart side that unpacks them
(`flutter_ui/lib/src/rust/`). Those generated files are checked in but never
edited by hand — the command `flutter_rust_bridge_codegen generate`, run from
`flutter_ui/`, rewrites them from scratch, so any manual change is simply lost
next time. If you add a Rust function and Dart cannot see it, that command is
almost always what is missing. Forgetting it has its own quiet failure mode: the
checked-in Dart goes on describing the engine as it used to be, and nobody
notices because it still compiles. So CI now runs the generator itself and fails
if the result differs from what is committed (the `codegen-fresh` job) — the
generated files are an output, and an output is something a machine checks, not
something a reviewer is expected to spot. A second tool, **cargokit**, sits under
`flutter_ui/rust_builder/` and does an unglamorous but useful job: it compiles
the Rust library automatically as part of the normal `flutter run`, so there is
no separate build step to forget.

*Why this is a rewrite and not a translation.* Bridge v0 worked the way a website
does: Dart asked one big question (`lumit_bridge_snapshot`), got the entire
document back as text, and rebuilt its own copy of everything from it. To change
one layer's name, Dart looked the layer up by its identifier, sent an edit, then
asked for the whole document again to see the result. That is simple, but it
means every small edit costs a full document read, and Dart has to keep its own
mirror of the document faithfully in step.

frb allows something better: Rust can hand Dart a **handle** — a small opaque
token standing for one thing in the document. So Dart holds a `LayerReference`
rather than a layer's identifier and a copy of its data, and renaming becomes
`layer.rename(name: 'hero shot')` — a method on the layer itself. There is no
snapshot to re-read, no mirror to keep in step, and no identifier to look up,
because *the handle is the identity*. Alongside that, Rust pushes a small
"something changed, and here is which layer it was" message down a **stream** (a
tap Dart listens to), so only the part of the interface that actually changed is
redrawn instead of all of it.

That message is worked out in one place, `op_scope` in
`crates/lumit-bridge/src/api/state.rs`: it looks at the edit that just happened
and says which composition it touched, which layer inside it, and whether the
project's *list of items* changed at all. Getting that last part wrong is
expensive rather than merely untidy — the Project panel has to ask the operating
system whether each footage file is still where it was, and that is slow enough
that it caches the answers. Before the scope told it otherwise, it threw those
answers away on every edit of any kind, so nudging a value in the Timeline sent
it back to the disk to re-check every clip in the project. Now it only listens
for edits that add, remove, rename, refile or relink an item.

**How an effect edit avoids a hundred undo steps.** Dragging a blur's radius
produces something like a hundred values a second, and each one is a real change
to the document — so done naively you get a hundred undo entries and a hundred
disk writes for what the user thinks of as one adjustment. The Effect controls
panel avoids that by working on a *copy*: it asks the engine for the layer's
effects, edits the copy as the pointer moves, and asks for a picture of "the
document, but with this copy substituted" — which the engine renders without
changing anything it keeps. Only when the pointer is released does it hand the
copy over to be committed, once. If some other part of the interface changed the
same stack while the drag was happening, the engine refuses the commit rather
than overwriting that change, and the panel re-reads instead.

One rule in that panel is worth knowing because it looks like a missing feature.
A parameter that is *animated* — following a curve of keyframes rather than
holding one value — shows the word "animated" instead of a number field. That is
deliberate: the only way to write a value at the moment replaces the whole curve,
so offering a field would let a small nudge silently delete every keyframe on it.
The field comes back when the keyframe editing arrives with the graph editor.

*Where to look for the pattern.* Every panel now works this way, and the whole
older bridge has been deleted — there is one way to talk to the engine, not two.
`flutter_ui/lib/panels/project_panel_frb.dart` reads a list through handles,
`viewer_panel_frb.dart` is fed by the frame stream, `effect_controls_panel_frb.dart`
shows the live-drag path that renders a preview without ever committing an edit,
and `shell/menu_bar_frb.dart` simply calls actions. `docs/TODO.md` records what is
still missing.

*Why the app opens with a project already made.* Every document command — import,
new composition, save — needs somewhere to put the result, so each is greyed out
while no project is open. Starting the app with *nothing* open therefore greyed
out the entire File and Composition menu, and left no way to make it live: the
first thing anyone does needs something to do it to. The shell now makes an empty
project as it boots, exactly as opening a word processor gives you a blank page.
Opening a file from disk replaces it wholesale, so nothing is left over from the
one that was made for you.

*The workspace remembers itself again.* The panel arrangement, the colour
scheme, the interface scale and the tooltip setting all live in one object
(`Workspace`) that writes itself to a small settings file and reads it back at
launch. During the port the shell briefly kept its own separate copies of the
layout and the scheme, which is why a rearranged workspace did not survive a
restart and why the scale slider moved nothing: the shell was reading one copy
and the Settings window writing the other. There is one copy now. Two smaller
things came back with it — the window's backdrop is the theme's own darkest
surface rather than Flutter's stock Material grey, and the whole interface is
drawn through the scale setting so text and hit-targets grow together.

*Why playback froze on its first frame.* A rendered frame arrives from the
engine as raw pixels, which Flutter turns into an image object that has to be
explicitly thrown away — nothing collects it for you. The Viewer was throwing the
*previous* frame away the instant the new one arrived, but the part of Flutter
that actually draws had not caught up yet and was still holding the old one. It
then tried to draw a picture that no longer existed, which fails, and once
drawing fails the Viewer stops updating. Scrubbing by hand left enough time
between frames to get away with it; playback did not, which is why pressing play
showed one frame and then nothing. The old frame is now thrown away one frame
later, when nothing can still be holding it.

*The cache bar, and the bug finding it uncovered.* The stripe under the time
ruler shows which frames have already been rendered and kept, so you can see at a
glance what will play. Mint means the frame is held at the resolution you are
watching — it plays now. A dimmed mint means it is held only at a coarser
resolution: there is something, but it would be rendered again to show at this
size. Nothing drawn means nothing kept. The design language reserves a blue for
frames kept on disk; there is no disk cache in this engine yet, so that state
cannot happen and is not drawn.

Building it meant asking the engine a question it could not answer. The bridge
reported only totals — how many megabytes, how many hits — never *which* frames,
so the old frontend had guessed by watching what it had asked for. The engine now
answers directly.

Asking that question exposed something worse. Each kept frame was filed under
*where* it was — which composition, which frame number, at what size — rather
than what was in it. An edit does not change any of those, so after changing a
layer the cache happily handed back the picture from before the edit, byte for
byte. Confirmed by rendering a frame, setting the layer to five per cent opacity,
scrubbing away and back, and getting an identical picture. A committed change now
retires that composition's kept frames.

That fix is blunter than it should be: renaming a layer cannot change a pixel, and
it throws the frames away all the same. The better answer — already written down
as the design — is to file each frame under a fingerprint of what is actually in
it, so an edit simply produces different names for the frames it changed and
everything else survives untouched. That needs machinery the bridge does not have
yet, and is in the backlog. A cold cache is a nuisance; a cache that lies is a
bug.

One more thing that could not be right and was: a frame rendered *during* a drag,
showing values not yet committed, was being filed as though it were the
document's own. It is no longer kept at all.

*One place decides what the picture shows.* The playhead is a number several
things can move: the Timeline's ruler, an arrow key, the transport, playback
itself. Rendering, though, was the transport's own private business — so dragging
the Timeline's playhead moved the playhead and left the Viewer on the old frame,
and the arrow keys had the same problem the moment they were added. The Viewer
now watches the playhead and renders whenever it changes, whoever moved it. Adding
a fourth way to move it needs no new rendering code at all.

*Asking once, rather than sixty times a second.* Playback asked for a new frame
on every tick — about sixty a second — while a frame takes far longer than that
to render, so roughly ten requests piled up per finished frame and the worker
threw all but the newest away. Each of those discarded requests still cost a lock,
a copy of the document and a message across the boundary, on the very thread
drawing the interface. The Viewer now keeps exactly one request outstanding and
asks again only when that one is answered, for whichever frame the playhead has
reached by then — the same pictures, a fraction of the work.

There is one subtlety worth naming, because getting it wrong is silent and
expensive: what is wanted has to be *cleared* once it arrives. An earlier version
asked again whenever anything was wanted, which meant every delivered frame asked
for itself, and the engine re-rendered the same picture forever at full speed.

*The Timeline was redrawing itself sixty times a second for no reason.* Moving
the playhead rebuilt every layer row and every bar — and rebuilding a row means
asking the engine again for that layer's name, its span, its switches. During
playback that happened for every frame, and the cost grew with the number of
layers, so the more work you had in a composition the worse playback got. Only
two things actually care where the playhead is: the line itself, and the razor,
which reads it at the moment you click. Both now listen for themselves and the
rows sit still. Measured on a playhead move: with five layers, 6.4 ms down to
1.3 ms; with twenty, 1.8 ms where the old shape would have cost around 19.

*Why the zero-copy Viewer showed nothing, and how it was found.* The fault could
not be seen from inside the program: the engine made its texture, Flutter
accepted it and asked for it every frame, and the panel stayed empty. It was
found by driving the real application window from a test and photographing it —
the first run showed the checkerboard, the last shows the rendered picture
arriving through the shared texture.

The cause was two mismatches with the component inside Flutter that opens the
texture (ANGLE). First, the *kind of handle*: Windows has two ways of naming a
shared texture — an older "share handle" and a newer "NT handle" — and ANGLE
only accepts the older kind, while the engine was exporting the newer, because
Direct3D 12 can only make the newer. The engine now crosses that gap itself: the
picture is copied, still on the graphics card, into a texture made the older way
by the older API, and that texture's handle is what Flutter gets. Second, the
*channel order*: ANGLE only opens blue-green-red-alpha surfaces, and the engine
shared red-green-blue-alpha. The proving colour in the test is orange on
purpose — with the channels swapped it would show blue, where the earlier
magenta (whose red and blue are equal) would have hidden the mistake.

*"Submitted" is not "finished", and what a fence is.* Telling a graphics card to
do something is like handing a note through a hatch. The moment the note is
accepted, your side is free to carry on — the work itself happens later, out of
sight, at the card's own pace. This is the whole reason graphics are fast, and
it is also a trap: the call that copies the picture into the shared texture
returns long before a single pixel has moved. If you announce the frame at that
moment, whoever opens the texture next may be looking at it *while* it is still
being filled, or before it has been touched at all.

A **fence** (Direct3D calls the small one used here an *event query*) is the
answer: a marker dropped into the queue of work behind the copy. Because the card
does the queued work in order, when the card reports that it has reached the
marker, everything before the marker — the copy — is genuinely done. So the
engine drops a marker after the copy and then asks, over and over, "reached it
yet?" until the answer is yes. That is the only honest way to turn "I have asked"
into "it has happened".

Not waiting was a real bug, and a nasty kind: the test that opens the texture the
way Flutter does passed almost always and failed perhaps one run in fifty, with
every pixel reading as empty — the reader simply won the race that time. It broke
a build that had nothing to do with it. The wait is bounded: if the card has not
reported the copy finished after a quarter of a second, the engine gives up,
prints a line saying so, and shows the frame regardless. One stale frame is a
blink; a render thread waiting for ever on a wedged card is a frozen application.

*Every-frame playback now keeps two frames in motion.* One frame used to be
requested, rendered, delivered, shown — and only then the next requested, so the
renderer sat idle while the interface caught up, and the interface sat idle
while the renderer worked. In every-frame mode the Viewer now asks for the next
frame while the current one is still crossing, which is safe there because that
mode's requests are never discarded. Measured on the real window with 1080p60
footage: 56 frames a second serial, 64 pipelined — which is what makes a 60 fps
composition play in real time in the mode that renders and keeps every frame.

*Catching a failure that reports nothing.* The zero-copy Viewer's failure had no
symptom you could act on: the engine made its texture, Flutter accepted it
without complaint, and then simply never drew it — an empty panel for the whole
session while the playhead ran and every other panel updated. Nothing in that
chain says "this is not working".

So the runner now counts something it can only know by being asked: how many
times Flutter has actually come back for the texture in order to draw it. A dozen
frames announced and none drawn is proof the picture is not reaching the screen,
whatever the reason, and the Viewer quietly goes back to copying pixels — with
Settings saying why, rather than leaving you to guess whether it is the picture
or the plumbing that is broken.

*A fast path that fails silently is worse than no fast path.* Turning the
zero-copy Viewer on in the shipped build had an ugly result: the Viewer drew
nothing at all — just its checkerboard — while the playhead ran and the Scopes
updated, which reads as the picture being broken rather than the *transport*
being broken. Two things had to change. The engine now falls back to copying the
pixels when it cannot make a shared texture, instead of dropping the frame: a
frame by the slow road beats no frame. And the frontend now says, with each
request, whether it can actually display a texture — asked rather than assumed,
because if it cannot, it draws nothing and the engine has no way to find out.

The path is therefore off by default and opted into from Settings → Playback →
Frame transport, until it has been seen working on a real window. It had never
run in a shipped build before, so there was no evidence it did. Which transport
is in use shows in Settings and in the playback-mode tooltip, so it is never a
guess.

*The Scopes were secretly doubling the cost of playback.* The waveform and
vectorscope displays read the numbers in a frame — how bright it is, what colours
are in it. To get those numbers they were building the whole composition a second
time, from scratch, for a frame the Viewer had just finished building. Several
times a second, for as long as playback ran, whenever that panel was open. They
now reuse the picture already in hand, at whatever resolution it happens to be:
any size answers the question a waveform asks.

*Why the Viewer froze while the Scopes kept moving.* One background worker
serves both: the Viewer asks it for a picture, the Scopes panel asks it for a
trace of the same frame. When it finishes a job it takes everything that piled up
meanwhile and keeps only the newest, because a frame nobody will ever see is not
worth rendering — that is what keeps dragging feel attached to the pointer.

The flaw was that "newest" ignored what kind of job it was. During playback the
Viewer asks about sixty times a second and the Scopes panel about eight, so a
trace request regularly landed at the back of the queue and threw away every
picture behind it. The scopes updated, the playhead moved, and the picture sat on
its first frame. It now keeps the newest of *each* kind — a trace and a picture
are different jobs, and neither is a replacement for the other.

*The keyboard works again.* The shell that the port replaced had a key handler —
space to play, the arrows to step, Ctrl+Z to undo — and the new one had none at
all, so nothing on the keyboard did anything. It is back, with one correction and
one addition. The correction: a field with focus has to keep its own keys, or
typing a layer name would also run commands; the old check looked at the wrong
widget and would not have caught it. The addition: focus now falls back to the
shell when a field gives it up, without which every shortcut stopped working
after the first rename.

*Two small things that made the interface feel wrong.* A hint that stuck on
screen, and controls that twitched when the pointer crossed them. Neither was
cosmetic in origin.

The hint waits half a second before appearing, so the interface is not covered in
labels the moment the pointer moves. Nothing was cancelling that wait: move onto
a control and straight off again, and the hint appeared *after* the pointer had
already gone — and since it is dismissed by the pointer leaving, and the pointer
had already left, it stayed there. Hovering the control would clear it and moving
away would bring it back, which is the loop it was stuck in. The wait is now
cancelled on leaving.

The twitch was a border. In Flutter a border drawn as part of a box's decoration
takes up room *inside* the box, so a border that only exists while hovered makes
the control two pixels bigger in each direction the instant the pointer arrives —
and everything beside it shifts to make room. The border is now always there and
merely transparent when it should not be seen, so the space it occupies never
changes.

*Where the transport sits.* Under the picture, where a transport goes. In the
rounded theme it is a detached bar floating over the bottom of the frame — the
rounded language treats it as an object sitting on the picture — while the sharp
theme keeps it welded to the panel edge, so the two read as two deliberate
designs rather than one with a gap.

*Dropping footage onto the Timeline.* Dragging a footage item out of the Project
panel and letting go over the Timeline adds it as a layer. The drag was only ever
half-built: the Project panel lifted the item and drew it under the cursor, but
the Timeline had nothing that accepted a drop, so the item fell into nothing.
What the drag carries is the footage *handle* itself, not a name or a number to
look it up by — on this bridge the handle is the identity, so the drop hands the
engine exactly what it was given.

*Menus that are taller than the window.* A menu is drawn in a floating layer over
everything else, and until now it was simply placed and allowed to be whatever
height it liked — so a long menu on a short window ran off the bottom with its
last few rows unreachable. Every floating popup is now capped at the room below
its own top edge and scrolls inside that if it needs to, which fixes the dropdown
lists at the same time and for the same reason.

*Two ways to reach the same two commands.* Import and New composition sit on the
menu bar and on a small footer strip along the bottom of the Project panel, and
double-clicking the Project panel's blank space imports as well. That is not
duplication worth removing: the Project panel is where you are looking when you
want either of them, and the double-click is the gesture people reach for before
they go hunting through a menu. All three routes call the same two methods on
`LumitState` (`importFootagePaths` and `newComposition`), so there is one
implementation and three doors onto it.

The older bridge is worth one paragraph of history because its shape explains
several decisions above. It passed whole documents as JSON text over a plain C
interface, so every edit meant serialising the project, sending it across, and
parsing it back — which is why so much of the design here is about *not* doing
that: handles instead of copies, one scoped message instead of a fresh document,
a whole value instead of a granular op. It was deleted once every panel had
moved across, in one sweep, so the two never had to be kept in step with each
other.

**The safety net, and why every edit costs a disk write.** Two things stand
between a session ending badly and losing work, and they are not the same thing.
An **autosave** is a whole copy of the project written beside it on a timer —
open one and you get everything up to that copy, and nothing after it. The
**journal** is the list of edits themselves, appended one line at a time as you
make them; replayed onto the last saved file it gets you back to the moment
things stopped.

The journal is why an ordinary edit waits for the disk. That is a real cost
(measured at about 2.3 ms), and it is exactly why dragging a value does *not*
commit on every tick — a hundred ticks a second would be a hundred disk waits
for something the user thinks of as one adjustment. Dragging shows you a picture
without recording anything, and records once when you let go.

One detail worth knowing because it looks odd from the outside: saving *deletes*
the journal. That is deliberate. The journal only ever describes work done since
the last save, so once the file on disk contains that work, replaying it again
would add it twice.

**Staging versus committing, and why dragging used to lag.** This one is worth
understanding, because it explains a whole class of sluggishness.

Every ordinary edit is a **commit**: the engine copies the document, applies the
change, files the old version so Undo can get back to it, appends a line to the
crash journal **and waits for the disk to confirm it**, then serialises the entire
document to text and hands it to the interface, which reads all of it back. That
is the right amount of ceremony for "the user changed something" — it is what makes
Undo and crash recovery trustworthy.

It is entirely the wrong amount of ceremony for one tick of a mouse drag. Dragging
a value produces something like a hundred ticks a second, and the disk wait alone
was measured at 2.3 ms — so a second of dragging spent roughly a quarter of a
second just waiting for the disk, and left a hundred separate entries in the undo
history for what the user thinks of as one adjustment.

So a drag **stages** instead. `preview_transform` and `preview_effect_param` put
the provisional value in memory beside the document, touching neither the document,
the undo history, nor the disk. The Viewer renders the document *with that value
laid over the top* — and because the value does not change which frames of video
have to be decoded, it re-composites from pictures the renderer is already holding
rather than decoding anything again. When the mouse is released, the ordinary
commit runs exactly once, so the whole drag is a single undo step. A drag that is
abandoned rather than released — the gesture cancelled, or the pointer released
without ever having moved far enough to change the value — discards the staged
value instead, and the picture returns to where it was. (Cancelling with the
Escape key is *not* wired up; the value fields have no key handling yet.)

The tell that this has broken, if it ever does: dragging feels heavy and Undo has
to be pressed many times to get back past one adjustment. Both symptoms have the
same cause — something on the drag path is committing when it should be staging.
That is now a test rather than a hope (`preview_effect_param_never_touches_undo_or_journal`).

**Testing a panel that waits for the engine: one real turn, one fake flush.**
Worth reading before writing a test for any panel that calls something slow.

Flutter's widget tests run in a *pretend* clock, so a test can advance time
instantly instead of waiting. That pretend clock is why they are fast — and it is
also why anything genuinely asynchronous appears never to finish inside one: a
reply arriving from Rust needs a real turn of the event loop, and the pretend
clock does not provide any. `tester.runAsync` hands back a slice of real time for
exactly this, but it is only half the answer, because the *reply* arrives in real
time while the *code waiting for it* is parked in the pretend clock. Neither
alone makes progress.

The shape that works is to alternate: one slice of real time so the reply can
arrive, then one flush of the pretend clock so the waiting code notices. Repeat
until the screen shows what you were waiting for. The test helper
`settleFrb` in `flutter_ui/test/frb/frb_test_support.dart` does precisely that,
and its comment records the traps found the hard way:

- **Never `await` an engine call *inside* `runAsync` unless you also started it
  there.** It deadlocks outright rather than failing — the real-time slice cannot
  end until the thing it is waiting for completes, and that thing is waiting for
  the pretend clock, which cannot run until the slice ends.
- The same trap applies to **anything else asynchronous, not just the engine.**
  One test hung for eight minutes on an ordinary "create a temporary file" call.
  Use the synchronous file operations in tests.
- **Settling has to repeat.** The engine also pushes document-change messages, and
  one of those arriving can discard the answer that just came in, so a single
  round is not enough.

The symptom of getting this wrong is a test that *hangs* rather than fails, which
is worse than a failure: it stalls the whole file behind a long timeout and reads
as "slow" rather than "broken".

*One caution worth knowing.* The Rust functions in the frb layer are marked with
a small annotation (`#[frb(...)]`) that tells the generator to include them. An
unfortunate side effect is that the automatic checker which normally forbids
crash-prone shortcuts in Rust cannot see inside those functions — so the usual
safety net does not cover exactly the code the interface calls. A plain
text-search check in CI (`no-panics-in-frb-api`) stands in for it: nothing in
`src/api/` may take those shortcuts, and every call must report a problem as an
ordinary error instead of crashing.

**Reading and writing an effect's parameters.** An effect's controls are not all
numbers. A blur has a radius, a fill has a colour, a tile has a centre point, a
noise has a random seed, a dropdown has a chosen option, a displacement effect
has a file to point at, and a depth blur points at another layer. Any of the
number-shaped ones can also be *animated* — following a curve of keyframes rather
than holding one value.

The first version of this part of the new bridge could only say "a number", so
seven of the eight kinds, and every animated value, came back blank: the panel had
nothing to draw them with. There is now one type that can be any of them
(`BridgeEffectValue`), with one variant per kind, and an animated value arrives as
its actual keys — their times, values and easing — rather than as whatever number
it happens to equal at the start.

The rule the type is built around is that **reading and writing are exact
opposites**: whatever comes out can go straight back in, and the document is left
exactly as it was. That sounds obvious, but it is what makes the panel's ordinary
way of working safe, which is "read the value, change one part of it, write the
whole thing back". If reading an animated radius gave back only "12", writing it
again would delete the animation, and a user would lose work by nudging a slider.
Two smaller consequences of the same rule: keyframe times cross as exact
fractions (a key at half a second is "1 over 2", never 0.5, so it lands back on
the frame it was set on), and any field written by a *newer* version of Lumit that
this one does not understand is carried through untouched rather than quietly
dropped.

Writing the **wrong kind** is refused rather than applied. What kind a parameter
is belongs to the effect, not to the panel: a colour turned into a number would be
an effect the engine can no longer draw, and the damage would be undoable but not
obvious on screen.

**Changing which effects a layer has.** Adding, removing, reordering and bypassing
an effect are four calls on the layer, and each becomes exactly one entry in the
undo history — pressing Undo once puts the whole stack back as it was. Dragging a
parameter is the staged path described above: the panel holds its own copy of the
stack, changes values on that copy, renders previews from it, and commits the copy
once when the mouse is released. A copy that no longer matches the document — some
other action removed an effect while the drag was in progress — is refused rather
than committed, so releasing a slider cannot bring a deleted effect back.

**File dialogues, and why importing doesn't watch the video yet.** Choosing a
file to open, a place to save, or footage to import needs a real "open file"
window from the operating system. Flutter doesn't draw those itself — it borrows
the system's own dialogue through a small add-on called a *plugin*
(`file_selector`), which bundles the Windows piece that pops the familiar file
browser. The frontend asks the plugin for a path, then hands that path to the
bridge: opening and saving reuse the existing calls, and importing footage uses
a new one (`lumit_bridge_import_footage`). Importing only *records* that a media
file belongs to the project — it stores the path and stops there. It does not
open the file, read its size, count its frames, or make a thumbnail, because all
of that needs the video-decoding library (FFmpeg), and wiring that into the
Flutter build is a later phase (F2). So after an import the Project panel shows
the file's name straight away, and the picture and details fill in once decoding
is connected. One more practical note for the tests: a file dialogue can't pop
open inside an automated test, so every dialogue call goes through a small
swappable hook — the real app uses the plugin, the tests slot in a pretend path
— which is why the whole import-and-save flow can be tested without a single
real window appearing.

**Verifying the Linux zero-copy Viewer (the collaborator's checklist, K-177).**
CI proves the Rust Vulkan/DMA-BUF code and the GTK plugin *compile*; whether the
picture actually reaches the screen can only be checked on a real Linux machine
with a GPU. If you are that collaborator, here is the recipe (it mirrors how the
Windows path was proven):

1. **Build the engine with the flag.** From the repo root, build the bridge
   library with the Linux zero-copy feature on:
   `cargo build -p lumit_bridge --features shared-texture-linux --release`. This
   is the `.so` the Flutter app loads. Then build and run the app:
   `cd flutter_ui && flutter run -d linux --release` (the runner links EGL +
   GLESv2 for the DMA-BUF import — the CI `flutter-linux` job installs
   `libgles-dev`/`libegl-dev` for this).
2. **Open a composition and scrub the Viewer.** The picture should look identical
   to the CPU path — same colours, same framing. A washed-out, too-dark, or
   swapped-channel picture means the DRM format is wrong (report it — see below).
3. **Check the GPU/CPU transport indicator** (Settings, the same indicator the
   Windows path added in round 3). On the zero-copy path it should read **GPU**.
   If it reads **CPU**, the DMA-BUF path declined and fell back — that is safe but
   means the fast path is not active; note what the console logged.
4. **Toggle the Settings kill-switch off and on.** Off must drop the Viewer to the
   CPU path (indicator reads CPU) with the picture unchanged; on must return it to
   GPU. This proves the fallback is reachable without a rebuild.
5. **What to report if the Viewer is blank or wrong.** A blank Viewer on the GPU
   path most likely means the exported image did not import: capture any console
   line mentioning `eglCreateImageKHR`, `dma-buf`, `vkGetMemoryFdKHR`, or
   `device_from_raw`. The two most likely causes are (a) the GPU/driver did not
   enable the external-memory Vulkan extensions (the engine then falls back to a
   plain device and the indicator should read CPU, not blank), or (b) the DRM
   format/stride does not match what the driver produced. Report the GPU model,
   the Mesa/driver version, and whether the indicator read GPU or CPU — that is
   enough to tell a format mismatch from an extension-support gap.

**Verifying the macOS zero-copy Viewer (the Mac collaborator's checklist,
K-195).** CI proves the Rust Metal/IOSurface code and the Swift plugin
*compile*, and one unit test (`the_surface_yields_the_pixels_in_bgra_order`)
proves the bytes come back off a real surface in the right channel order on a
unified-memory Mac. Whether the picture reaches the screen needs a Mac with a
window:

1. Build the bridge and run: `cargo build -p lumit_bridge`, then `flutter run -d
   macos` from `flutter_ui/`. No flag — `shared-texture-macos` is default-on.
2. Open a composition. A picture in the Viewer *is* the proof: there is no
   fallback transport left, so a working picture can only have come through the
   surface.
3. A blank Viewer with everything else working is the failure this path is
   watched for, and it reports itself: after a dozen announced frames with none
   drawn, the Dart side gives up and says so. Capture any console line mentioning
   `IOSurfaceCreate`, `newTextureWithDescriptor`, `IOSurface \d+` or "not running
   on the Metal backend".
4. Report the Mac's chip (Apple silicon or Intel, and on Intel whether it has a
   discrete GPU — that decides the texture's storage mode, and the discrete case
   is the one corner this path knowingly does not synchronise).

**What the bridge carries.** The surface the frontend and engine share is
specified in [17-BRIDGE-CONTRACT.md](17-BRIDGE-CONTRACT.md) - the single source
of truth for it. It is generated from `crates/lumit-bridge/src/api/`, so the
declaration and the document are the two things to read; neither this guide nor
any other file carries a second copy of the list.

**Placing footage and restacking layers.** You can now build a composition from
the Flutter side: double-click a footage clip in the Project panel (or drag it
onto the timeline) and it becomes a new layer at the top of the stack — sized and
centred exactly as the egui app would place it — and you can drag a layer row's
name up or down to restack it, just like moving a track in any editor.

**The Scopes.** The colourist's instruments that plot brightness and colour instead of
the picture (a waveform, an RGB waveform, a vectorscope and a histogram) read the very same
pixels the Viewer is showing, so the trace always matches what is on screen. Each scope is
drawn on a fixed near-black background rather than the interface theme, because a measuring
instrument must be read against the same neutral whatever colours the chrome wears, and it
holds the last trace for a beat rather than blinking to blank when a frame is momentarily
unavailable.

**The headless renderer (K-175).** The Viewer shows the *whole* comp — every layer
stacked, each one's position and effects applied, blended into the finished
picture. The piece that makes it possible is the **headless renderer**, where
"headless" just means "no window": drawing a comp to an offscreen picture needs
only a graphics device, the video decoders and the document, so it needs no
interface at all. It holds the graphics device (slow to set up, so created once
and kept), the compiled drawing programs and the open video decoders, and each
time it is asked for a frame it composites the comp and hands back the pixels.

Because it is **the very same code the exporter runs**, the Viewer and the
exported file cannot disagree about what a comp looks like (K-031). That is the
whole reason it exists. A missing layer comes back already painted as colour bars
*inside* the finished frame, so the Viewer needs no separate "missing" card. Where
no suitable graphics card exists the renderer reports itself unavailable once,
and the Viewer degrades rather than crashing.

**The picture-making crate (K-178).** That renderer used to live inside the
frontend, so anything wanting a frame had to reach *through* a user interface to
get one. It is now a crate of its own, `lumit-render`. The engine no longer
contains a dashboard.

It is worth understanding what that code actually does, because the shape of it
is what fixed a real performance problem. Making one frame is five steps:

1. **Probe** — what is this video file: is it there, how fast does it run, how
   many frames does it have?
2. **Plan** — walk the composition at this moment and write down *which layer
   needs which frame of which file, at what size*. This is quick: it opens no
   files and does no drawing. It is just a list.
3. **Decode** — actually read those frames out of the video files. This is the
   slow step, by a wide margin.
4. **Build** — turn the project plus those decoded frames into a **draw list**:
   a plain description of every layer's picture, where it sits, how transparent
   it is, which blend mode, and what its effects work out to as plain numbers.
   Still no graphics card involved.
5. **Realise** — hand the draw list to the graphics card and get the frame.

Now the point. When you drag a blur radius, what changes? Only step 4. The video
frames underneath are *exactly the same ones* — you have not moved the playhead.
So the honest thing is to keep the decoded frames from last time and re-run only
steps 4 and 5, which are fast.

That is what the egui Viewer had always done. The Flutter Viewer did not: it went
through the *exporter's* path, which sensibly decodes everything afresh every time
(that is right for writing a file, where each frame is visited once). So every
single tick of a drag re-read the whole composition off disk, and dragging
stuttered. Sharing one crate is what made it possible to give the Flutter path the
good behaviour rather than writing it a second time and hoping the two stayed in
step.

The mechanism is simple enough to state in a sentence: before decoding, compare
the *plan* with the plan that produced the frames already in hand; if they ask for
the same pixels, skip the decode entirely. The comparison deliberately ignores
placement and effects — those are precisely what the drag is changing. One live
edit is the exception and gets handled properly rather than glossed over: dragging
a **Retime** "Time" value genuinely moves to a different frame of the source, so it
is applied to the plan rather than after it.

This is measured, not asserted. The decoder counts the frames it actually decodes,
and a test drives ten drag ticks and requires the count not to move — then moves
the playhead and requires that it *does*, so a broken version that simply never
decodes cannot sneak through.

Two other things came with it. Footage is now decoded at the size it will be
*shown* rather than always at full size and thrown away — so the second honesty in
the paragraph above is gone: a smaller scale now reduces real work, not just the
size of the answer. And finished frames are now filed under a **name derived from
their content** — a fingerprint of everything that went into them. Before, the
Flutter frame cache threw away every frame in the project whenever the document
changed at all: renaming a layer or nudging the work area, neither of which can
change a single pixel, emptied it. Now those produce the same names, so nothing is
discarded, and editing one layer retires only the frames that layer appears in.

One piece of untidiness is left, deliberately and in writing rather than quietly:
there are still **two** routes through a composition — the interactive one just
described, and the exporter's older one — doing the same job by different paths,
kept in agreement by hand and by tests. Merging them is the next job on the
backlog, and it is gated on a set of tests proving the two produce identical
pixels across precomps, mattes, adjustment layers and motion blur before the old
one is deleted.

**The editors starting to come alive (F4, first slice).** Three of the editing
surfaces move off their placeholders. The **Hierarchy** panel draws the active
composition as an indented outline: the comp at the top, then its layers, each
with the little coloured symbol for its kind; a layer that is *itself* another
composition (a "precomp") gets a fold-out triangle you can open to see the
layers inside it, and so on down. Clicking a row picks that layer. (One honest
limitation: the bridge does not yet tell us *which* composition a precomp layer
points at, only that it is one, so we match it up by name for now — a later
bridge version will carry the exact link.) The **Effect controls** panel can show
the picked layer's **Transform** values — its anchor point, position, scale,
rotation and opacity — as editable number boxes in the same card style as the
Settings window; typing or dragging a box sends the change straight to the
engine as one undoable step. That card is **off unless you ask for it**
(Settings → Interface), along with the layer's Source and Retime rows: the
Timeline already shows all three when you twirl a layer open, and repeating
them here pushed the effects — what the panel is actually for — a screen
further down. The **Add effect** button drops its menu underneath itself, one
row per category, each opening onto the effects in it. Those boxes now read the **current** values back
from the engine (the em-dash placeholder is gone), each row carries a stopwatch
to start or stop animating that value and a ◄ ◆ ► navigator to step between or
add and remove its keyframes, and below the transform sits the layer's stack of
**effects** — one card each, with an on/off tick, a remove button, and editable
rows for the numeric and colour settings (the other kinds are shown read-only
until the engine gains a way to set them); a companion **Effects & presets**
panel lets you search the built-in effects and apply one to the selected layer.
Finally, the **Composition settings** and **New composition** windows
are real dialogues now — name, size, frame rate and duration — opened from the
Composition menu; every field reaches the engine, and the two windows have since
become one piece of code with two buttons (see "the composition settings window"
at the end of this section for what each field means and the frame-rate bug that
reshaped two of them). Saving effect presets to a `.lumfx` file, and masks, are later waves.

**The Timeline coming to life (F3).** The Timeline panel — the strip along the
bottom that shows time running left-to-right and the stack of layers — is now
live. Across the top sits a row of tabs, one per composition in the project;
clicking one makes that comp the active one everywhere. Below the tabs is the
*time ruler*: a tall band marked with seconds, thicker on the numbers and
thinner in between, with little flags where you have dropped markers; clicking or
dragging anywhere along it moves the playhead (the line that says "show me this
moment"), which appears as a bright vertical line running down through all the
layers. Each layer gets a row: on the left, a name and a cluster of little
toggle switches (show/hide the picture, mute the sound, solo, lock, effects on,
motion blur, 3D, and a fold-out for nested comps) — every switch flip is a real,
undoable change sent to the engine. When the panel is made narrow, the switches
don't pile up on top of each other the way the old interface's did; they drop
away in a set order (the least-important first), so the name and the eye always
stay readable — a deliberate improvement the owner asked for. On the right of
each row is the layer's *clip bar*, tinted with the layer's colour, showing where
in time it starts and ends; you can drag the middle of a bar to slide the whole
layer earlier or later (its length preserved), or grab either end to trim just
that edge, and with the magnet on, drags snap to whole seconds and to markers.
The zoom, magnet and graph-editor buttons live along the bottom. A second wave now
adds the fold-out twirl on each layer (revealing its transform property rows, each
with a stopwatch, the ◄ ◆ ► keyframe navigator and a value you can drag — the
keyframes themselves are drawn in the graph editor rather than as diamonds on the
lane, which is still to come), the work-area band on the ruler with
draggable edges, a right-click menu on each layer, a search box that filters the
layers by name, and a scrollbar to slide left and right once you have zoomed in.
The **graph editor** landed too: the bottom-bar toggle turns the lane into a curve
editor, with the lens chosen in its header. The **value graph** draws a layer's
chosen (or first animated) transform property as a smooth curve — sampled from the
same bezier the engine evaluates, so it never fakes the shape with straight lines
between keys — with the keyframes as shape-coded glyphs you drag in time and value,
gold **bezier handles** on a selected key, a right-click menu (easy-ease / linear /
hold / delete) and a double-click to add a key. A **retimed footage layer** adds two
more lenses: the **speed** lens (the speed-over-time ramp, with its presets and
→Rate) and the **Time** lens (where the source frame sits over comp time, whose
boundary joins you drag in time). Drags snap to beats and whole frames with the
magnet on. It shares the timeline's own zoom and scroll, so the curve stays lined up
with the lanes underneath.

**The Retime graph, in the timeline.** Turning on the graph lens swaps the
timeline's lane area for a curve of the selected clip's *speed* over time: each
straight or eased ramp is drawn from its start speed to its end speed, a bent
(mapped) segment shows the speed its curve implies, and the join points between
segments sit as vertical lines you can drag left or right; a small row up top
lets you ease the ramp under the playhead (Lin/Slow/Fast/Smth/Shrp) or flatten a
curved segment to a plain rate, and every number the curve needs to be drawn is
worked out by a small, separately tested piece of plain maths so the picture is
never guesswork.

**Exporting (the dialogue and the queue, K-201).** Choosing File → Export opens
a small settings window. The first box is the **format**: an H.264 or HEVC
video file, or a **PNG or TIFF image sequence** — one lossless still per frame,
so choosing `shot.png` writes `shot.00001.png`, `shot.00002.png`, … beside it
(handy for taking frames into other tools; a sequence has no sound and no
bitrate, because a folder of stills has neither). For video you can pick a
delivery preset (which fills in the codec and bitrate for you) and an audio
quality. Every export also carries a **frame rate** — already filled in with
the composition's own, and changeable, so a 60 fps comp can go out at 30 or at
29.97 without the file quietly claiming a different rate — and a **range**,
already filled in with the work area you set in the Timeline (or the whole comp
when you set none), as "from frame / to frame" boxes you can change. Choose
where to save, press Export, and the same window shows the frame count as it
goes, with Cancel beside it; a cancelled image sequence tidies away the frames
it had written rather than leaving what looks like a finished folder. The
"share" shortcuts (Discord 50 MB / Small 10 MB) skip the dialogue and work the
bitrate out from the size you are aiming for, using the same tested piece of
plain maths the desktop app uses.

**Reaching the last columns, and the app remembering where you were.** The
right-click menu on a layer now does the real work for its blend mode, its matte
and its parent, and for dropping a starter mask (rectangle, ellipse or star) —
the desktop app packs these into narrow dropdowns across a wide row, but the
Flutter panel's layer column is too slim for that, so they live in the menu
instead, each opening a small picker; the composition's motion-blur master
switch sits on the timeline's bottom bar for now. The Composition-settings and
New-composition windows now apply for real (editing an existing comp fills the
boxes from it and commits the whole set as one undoable change; creating one
makes the comp and then applies its size, rate and duration). Two conveniences
mirror the desktop app: the interface now **remembers each project's session** —
which comps were open, where the playhead sat and which layer was picked, saved
per project file and restored when you reopen it — and it **autosaves** a
rotating copy beside the project every few minutes while you have unsaved
changes, in an `autosaves` folder next to the file, never touching the file
itself (three copies are kept, oldest dropped first).

**Making the Viewer smooth: the render isolate (the perf pass).** The interface
felt laggy because it did the heaviest job — asking the engine to composite the
whole picture and copy it back — on the same thread that draws the interface, so
the window froze for the length of every render. A *thread* in Dart is called an
*isolate*, and the fix is a dedicated background one: a long-lived worker that
opens its own handle to the same engine library and does nothing but render
frames when asked. Because both handles are the same file loaded once into the
same program, they see the very same engine (the engine guards itself with a
lock, so the worker's render and the interface's edits take turns rather than
collide). The interface now *asks* the worker for a frame and carries on drawing;
when the picture comes back it is shown. Two manners keep it feeling live: only
one render runs at a time, and if you scrub past several frames while one is
still rendering, the worker is asked only for the newest one you landed on (the
in-between frames are skipped, not queued up) — and the last real picture stays
on screen the whole time, so the Viewer never flashes blank. If the worker
cannot be started, or there is no engine library (as in every test), the old
behaviour is kept as a fallback and the picture is simply rendered inline. Two
smaller changes came with it: the playhead now has its own private
change-signal, so moving it repaints just the picture, the time readouts and the
playhead line rather than rebuilding every layer row and panel at the frame
rate; and remembering the session (which project, playhead, selection) now waits
for a half-second lull instead of writing to disk on every single frame of a
scrub.

A later testing round found the same freeze sneaking back in through side
doors: a few smaller engine calls were still made on the interface thread, and
each of them has to wait its turn behind the engine's render lock — so if the
worker was mid-render on an uncached frame, the whole window stopped until that
render finished. The worker now serves those too: the Scopes panel's trace
(which reads the engine every time a new frame lands, so with the panel open
every uncached frame used to freeze the window for the length of its render)
and the Project panel's little footage thumbnails both rode the same background
worker, ask-and-carry-on style with the same "only the newest request matters"
manner. (The thumbnail half of that has since gone: the Project panel moved to
the new bridge, where asking for a thumbnail is simply an ordinary background
request, so the hand-built worker route for it was deleted rather than kept in
two versions.) Beat detection — which listens through the whole composition's audio
and can take seconds — now runs in its own short-lived background worker: a
quiet "Detecting beats…" note shows while it listens, and the markers appear
when it is done, with the window live the whole time. And the colour
eyedropper, which used to render a whole full-size frame on the interface
thread the moment you moved the pointer over the picture, now simply reads the
pixels the Viewer has already copied back — sampling is free — only asking the
worker for a frame in the rare case where none has arrived yet.

**Finishing the chrome: the splash log, the recovery prompt, and making the
whole interface bigger (section E).** Three of the remaining chrome pieces are
now wired up. The **splash** — the little card that appears while the app starts
— used to list four made-up steps ("workspace store", "theme"…); it now shows
the engine's *own* honest boot lines (its version, which features it was built
with) when the real library is present, and falls back to the old canned list
only when it is not. The **recovery prompt** answers a simple worry: if the app
closed unexpectedly last time, did you lose work. When Lumit opens a project and
notices its automatic spare copies (the *autosaves*) are newer than the file
itself — the tell-tale of a session that ended without saving — it puts up a
small window offering three choices: replay the interrupted changes, keep the
last saved version, or open one of the spare copies. Two honesties are written
into it: the engine can only replay the interrupted changes by actually applying
them (there is no way to peek first and count them), so the window is triggered
by the "spare copy is newer" signal rather than by counting changes; and opening
a spare copy loads its contents while still remembering the real project as the
one you are working on. Finally, the **UI scale** slider in Settings now does
something: dragging it makes the entire interface draw larger or smaller. The way
this works is worth a sentence, because the obvious approaches are traps —
telling Flutter a fake "pixel density" changes nothing, and simply blowing the
picture up leaves the buttons in the wrong places for the mouse. Instead the
whole app is *scaled like a drawing* (a `Transform`), but first given a smaller
imaginary canvas to lay itself out on, so that once it is scaled back up it fills
the window exactly — and because Flutter applies that same scaling to where your
mouse clicks land, the buttons stay clickable and the text stays sharp. (The one
genuinely seamless way, matching what the old egui app does internally, needs an
experimental Flutter feature the pinned version keeps switched off — so this is
the best available, and it is a good one.) The last piece of section E —
**popping a panel out into its own desktop window** — was first judged
impossible, then reopened when half of that judgement turned out to be wrong.
Half stands: the pinned Flutter version only offers built-in multi-window behind
an experimental, switched-off flag our checks forbid using, so we do not touch
it. The other half was a misread. The add-on package we use
(`desktop_multi_window`) does give each extra window its *own* Flutter engine
with its own private memory — but crucially those engines all live inside the
*same running program*. And the one thing a popped-out panel actually needs is
not the main window's memory but the **document**, which the engine keeps in one
shared place for the whole program (the single `lumit_bridge.dll` loaded once).
So a popped-out panel simply opens its own door to that same shared engine —
exactly the trick the picture-drawing helper already uses — and edits land in the
same undo history everyone sees. What travels to the new window is a short note
saying which panel to show and which colours to wear; the panel then reads the
shared document and pushes its edits straight back. A few panels are offered this
way (Project, Hierarchy, Effect controls, Effects & presets, Scopes); the Viewer
and Timeline stay put because they lean on machinery that only makes sense in the
main window. The new window checks the document about twice a second so an edit
made in the main window shows up; the reverse — the main window noticing an edit
made in a popped-out one — waits until you next touch the main window, an honest
rough edge written down rather than papered over. The parts that actually open a
real window can only be *built* on the owner's Windows machine (the tool that
compiles them does not run in the assistant's environment), so the checks for
this feature are run there.

**Audio playback in the Flutter frontend.** Until this change, pressing play in
the Flutter window moved the picture but made no sound at all — the playhead
was advanced by an ordinary interface timer. Now the same audio machinery the
egui application uses is wired through the bridge, and it works the way all
good playback works: **there is exactly one clock, and the sound card owns
it.** The sound card asks for its next slice of samples on a strict schedule it
controls; counting how many samples it has consumed *is* the playback time.
Every screen refresh, the Viewer asks the engine "what time is it?" and shows
the frame for that answer — the picture chases the sound, which is why the two
can never drift apart.

When you press play, the engine walks the composition for every audible layer
that carries sound, decodes those files once (they are kept for the session),
lays each one on a long strip at its own start time and volume — the *mix
plan* — and hands the plan to the sound card's thread. All of that happens in
the background: the play press returns instantly, and until the sound is ready
the picture simply runs on the old interface timer, then hands over to the
audio clock the moment it is loaded.

Editing while playing is the nice part. Mute a layer, drag a clip, trim it,
nudge a volume — the interface tells the engine "the comp changed", the engine
compares a fingerprint of what the mix *should* be against what is loaded, and
if they differ it builds a fresh plan and **swaps** it in without touching the
clock or stopping the sound. You hear the edit on the next slice the sound card
asks for, about a hundredth of a second later. If nothing that affects sound
changed, the fingerprint matches and nothing happens at all.

A machine with no speakers or sound device is handled calmly: the engine notes
"no audio" once and playback simply runs silent on the interface timer, exactly
as before — no errors, no retries. The same is true for a composition with no
audio layers, and for the loop: when playback wraps around the work area, the
audio is asked to jump back to the loop start and keep going. Two known
remainders are named rather than built: output-latency compensation (the few
milliseconds between the clock and the speaker cone — within the ±half-frame
tolerance the performance rules allow) and the per-layer waveform lanes the
egui timeline draws.

**The transform-preview fast path (dragging a numeric field, ABI 11).**
Dragging a Position/Scale/Rotation/Opacity field used to lag badly, and the
render isolate above is not what was slow — the *engine call itself* was. Every
tick of the drag ran the exact same path a single, deliberate edit does:
push an undo entry (a full copy of the document), write a line to the
crash-recovery journal on disk, and turn the whole document back into JSON
text for Dart to read. That is the right amount of work for one edit; it is
far too much for every pixel of mouse movement, and Dart then re-parsing that
whole JSON string threw away the Viewer's entire warm picture cache on every
single tick, so the picture went cold and had to redraw from scratch each
time too.

The fix keeps a drag's *live* value somewhere much cheaper than the document:
a small note on the engine side saying "while you're drawing, treat this one
property as this value" — no undo entry, no disk write, no text conversion.
The Viewer asks for one picture under that note and shows it; nothing is
banked into the picture cache, because a preview picture is only ever true
for the instant of one drag tick and gets thrown away the moment the next one
(or the real edit) arrives. Only when you *let go of the mouse* does the
real, permanent edit happen — the same single undo-worthy edit dragging
always should have been, exactly once, right at the end. Letting go of a
linked Scale pair still commits both axes as two edits, undoing back one axis
at a time, precisely as before this fix — only the felt smoothness of the
drag changed, not what Undo does afterwards. A drag that is cancelled rather
than released — the gesture interrupted, or the pointer let go without the
value ever having moved — throws the live note away with nothing committed at
all, so the picture and the number both snap back to wherever they were before
you started dragging. (Cancelling with the Escape key is not wired up: the
value fields have no key handling yet. This paragraph used to claim otherwise.)

An older engine library that predates this simply does not offer the live
note, and the interface notices and quietly falls back to the old,
tick-by-tick full-edit behaviour — slower, but correct, and nothing breaks.

**The composition settings window, and why changing the frame rate used to
speed everything up.** This is one window doing two jobs: pressed from the
Project panel's *New composition* button (or the Composition menu) it says
"New composition" and its button reads *Create*; opened by right-clicking a
composition it says "Composition settings" and reads *Save*. They ask the same
four questions, so there is one piece of code and one appearance rather than
two that drift apart.

Two of those questions changed shape, and the second one was a real bug the
owner reported.

*The frame rate is now one number.* It used to be shown as two — a top and a
bottom, 24000 over 1001 — because some broadcast rates genuinely are fractions
(what everyone calls "23.976 fps" is exactly 24000/1001, and a number written
out as 23.976 is a rounding that can never be turned back into the exact one).
That is true, and the engine still stores and receives the exact pair; but it
is *our* problem, not yours. So the field takes the number you would say out
loud — `60`, `600`, `23.976` — and works the fraction out behind the window,
with a **Presets** list beside it holding the awkward rates so nobody has to
remember that 1001 exists.

*The duration is now a length of time, not a count of frames — and that is the
fix.* Think about what a comp actually is. Underneath, the project stores "this
composition is thirty seconds long" and "this layer runs from second two to
second twelve" — real time, the kind a clock measures. The frame rate is only
how finely that time gets chopped up for display: at 30 fps thirty seconds is
900 slices, at 60 fps it is 1800 slices of the same thirty seconds. Nothing
about the *content* changes when you change it, any more than a film gets
shorter when you count it in half-frames.

The old window asked for the duration as a slice count. So it would open on a
thirty-second comp at 60 fps, show you "1800", and if you changed the rate to
30 and pressed Save, it dutifully wrote back "1800 frames" — which at 30 fps
means **sixty seconds**. The comp quietly doubled in length while every layer
inside it stayed exactly where it was, occupying the seconds it always had.
On screen that reads as everything suddenly running at half speed, which is
precisely what was reported. Changing the rate the other way looked like a
speed-up for the same reason.

Now the field reads `00:00:30.000` — hours, minutes, seconds, thousandths —
which is the thing the project actually stores, so it passes through a rate
change untouched. Change 60 to 30 and the comp is still thirty seconds long,
every layer is still where you left it, and the only difference is that the
timeline counts 900 frames instead of 1800. That promise has a test on each
side of the boundary, so it cannot quietly come undone: one in Rust that
checks the comp and its layers after a rate change, and one in Flutter that
drives the real window and presses Save.

The size row gained a padlock, on by default, that keeps the shape when you
change one side, with the ratio spelled out beside it (`40 : 17`).

**Picking more than one thing in the Project panel.** The panel used to allow
exactly one selected row. It now behaves like every file list: plain click
picks one, `Ctrl`-click adds or removes one, `Shift`-click takes the whole run
between your last click and this one. Dragging any row that is part of a
selection brings the whole selection with it — dragging an unselected row is
about that row alone — so four clips can be dropped onto the Timeline in one
go and each becomes a layer.

The useful destination for that gesture is the **New composition** button
itself, which now accepts drops. Dropping footage on it opens the settings
window already filled in from the media: the size and rate of the first item
that has a picture in it, and the length of the longest one (a comp shorter
than what you dropped into it would cut off the very thing you asked for).
Press Create and you get the comp *and* every dropped clip in it as a layer.
Reading those numbers off a file means opening it with FFmpeg, which is slow
enough that it must not happen on the interface's own thread, so it happens
before the window appears rather than making the window rearrange itself a
moment after you see it.

**Twirling a layer open in the Timeline, and why the picture now keeps up.**
Two things landed together here, and the second one is the reason the first
looked broken.

*The fold-out.* Every layer row in the Timeline has a little arrow beside its
number. Click it and the layer opens to show its **Transform** properties —
anchor point, position, scale, rotation, opacity — one row each, with the
stopwatch and the ◄ ◆ ► keyframe navigator on the left and the numbers on the
right. The numbers are *scrub-draggable*: press on one and move sideways and
the value follows your pointer, or click it and type. Dragging is one undoable
change for the whole gesture, not one per pixel: while you drag, the engine
renders a *copy* of the composition with your in-progress value patched into
it and never touches the real document, and only letting go writes the change.
Clicking the arrow again folds it away.

These are the same rows the Effect controls panel has always shown. Rather
than write a second set that would slowly drift out of step with the first,
the rows moved into their own file that both panels use — the Effect controls
panel now just draws its section around them. So a fix to how a value behaves is
a fix in both places, which is the whole point.

The lane to the right of an open property row is deliberately empty for now:
the keyframes themselves are edited in the graph editor. What matters is that
the Timeline *leaves room* for those rows on both sides — if the names moved
down and the bars did not, every layer below an open one would sit beside the
wrong name. (While making that true, a two-pixel drift between the names and
their bars turned up and was fixed: the outline was clearing the ruler but not
the thin cache stripe under it.)

*The picture keeping up.* The Viewer used to ask for a new frame only when the
playhead moved. Nothing else. So if you changed a value with the playhead
sitting still — typed an opacity, added an effect, anything another panel
committed — the picture on screen stayed as it was, showing the composition as
it used to be, until you nudged the playhead or pressed play. Playing was the
accident that fixed it, which is exactly how it was reported: "the Viewer does
not update until I play."

Now the Viewer also listens to the engine's stream of document changes, and
asks for the frame again whenever one arrives. There is one subtlety worth
knowing, because it is the kind of thing that looks fixed and is not: the
Viewer keeps exactly one render in flight, and it used to decide whether a
delivered frame was still wanted by comparing frame *numbers*. An edit does
not change the number — frame 40 is still frame 40 — so an edit that landed
while frame 40 was being rendered was "answered" by the picture already on its
way and never asked for again. So the Viewer now also carries a flag saying
"the document changed since I asked", and re-asks when a frame arrives under
it.

Two smaller repairs came with it. Pressing play with the playhead already
parked on the last frame used to do nothing whatsoever — the clock said "past
the end" on its first tick and stopped again, and in every-frame mode there
was no frame left to ask for — so it now rewinds to the start and plays, which
is what every other editor does. And a frame that comes back with no pixels in
it (a render that failed) now still counts as an answer: before, it left the
Viewer waiting for a reply that was never coming, which stopped it updating
for the rest of the session.

**The fold-out grows sections, and effect values become draggable.** Three
things that belong together.

*Sections, not one long list.* Twirling a layer open in the Timeline now shows
a short list of **headings** — Transform, Effects, Audio — each with its own
little arrow, and nothing under them until you open one. That is deliberate:
a layer has eleven transform properties before you have added a single effect,
and opening a layer straight onto all of them turns a busy composition into a
wall of numbers. **Effects** only appears once the layer has an effect on it,
and opens onto one row per effect, each of which opens onto that effect's own
settings. **Audio** only appears when the layer's source can actually be heard
— we ask the file itself whether it has a sound track — and holds the layer's
**Volume** in decibels. Every layer has a volume in the underlying model, but
on a coloured rectangle or a title it can never do anything, and a control
that cannot do anything is worse than no control.

*Effect values can be dragged now, and the reason they could not is worth
knowing.* You could type into an effect's number but not scrub it. The cause
was a piece of book-keeping across the language boundary. When Dart holds a
Rust object it holds a *handle* to it, and some of the engine calls take that
object **by value** — meaning the handle is handed over for good and the Dart
side of it is emptied. The panel was keeping a whole stack of effect handles
for the length of a drag and passing it to the engine on every tick to draw
the preview: the first tick gave the handles away, and every tick after it was
using something that no longer existed, so the drag died on its second frame.
Typing worked because a single edit is one call and never reuses anything.

The fix is a rule rather than a patch: **never hold a handle you have already
handed over.** What is kept during a drag is the *edit* — which effect, which
setting, what number — and fresh handles are made for each call that consumes
them. The same rule is now written down beside the code that has to follow it.

*One set of rows, two panels.* The rows the Timeline shows under a layer are
literally the same widgets the Effect controls panel shows, moved into their
own files so both use them. Writing a second set would have been quicker today
and wrong by next month, when a fix to one quietly failed to reach the other.

**One texture, never pixels (K-183).** There used to be two ways a finished
frame could reach the window: the fast way (the engine draws into a piece of
graphics-card memory that Flutter shows directly — a "shared texture", nothing
copied) and a slow fallback (copy every pixel off the card, hand them across
one byte at a time, and have Flutter upload the same pixels straight back to
the card — four trips for a picture that never needed to leave). The fallback
is now deleted. Every frame arrives as a handle to graphics memory, on every
build, and the one toggle that could turn it off is gone with it. What still
crosses as actual pixels is only the small stuff: the little footage
thumbnails in the Project panel and the 256×256 scope pictures — both tiny,
neither per-frame. One honest consequence: a platform with no shared-texture
code of its own (macOS today) shows no Viewer picture at all until it grows
one, rather than quietly taking a slow road.

**Ask once per change, not once per redraw (K-183, K-184).** Every question
the interface asks the engine — "what is this layer called?", "which switches
are on?" — crosses the Rust/Flutter boundary, and each crossing costs a
little. The panels used to ask one question per fact per redraw: a single
timeline row asked seven times, and its parent dropdown asked once per *other*
layer, every time anything redrew. Two steps fixed it. First the engine
learned to answer everything about a layer in one go (`get_info`). Then came
the **read model** (`state/comp_model.dart`): ONE call returns the whole
fronted comp as the panels draw it — every layer's name, switches, bar
position, transform and effect values — and Dart simply keeps that copy.
Panels draw from the copy for free; the copy is re-read only when the document
actually changes. How they know it changed is one number: the engine counts
every committed edit (and undo, and redo), and a rebuilding panel asks "what's
the count?" — one cheap call — re-reading only when the number moved.

Even that question is asked at most once per drawn frame. The copy is read
through several getters — the layers, the length, the rate — and each of them
used to ask for the count on its own behalf, so twirling one layer open still
cost a dozen crossings for an answer that cannot change part-way through a
frame being drawn. The model now remembers which frame it last asked in and
answers the rest from that; anything editing the document calls `refresh()`
directly, so nothing waits on the next frame to see its own change. Clicking a
layer went from about 75 crossings to five, and twirling one open from eighteen
to six — tests fail the build if either creeps back up.

**One walk from project to pixels (K-185).** For a long time there were two
separate pieces of code that could turn your project into a picture: one drew
the Viewer, and a second, fourteen-hundred-line near-copy drew the exported
file. They were kept identical by care and comments — every new feature had
to be built twice, and any slip meant the file you rendered could differ from
the preview you approved. Before touching it, a test matrix rendered ten
different kinds of composition (blends, nested comps, mattes, motion blur,
retimes, cameras…) down both paths and compared every byte: they agreed on
all of them. Then the export was pointed at the Viewer's own path — running
at full quality, on its own renderer so exporting never fights the Viewer for
the graphics card — and the copy was deleted. "What you preview is what you
export" is no longer a promise anyone keeps; it is true because there is
nothing else the export could draw with. The matrix test stays behind as the
tripwire.

**The preview scale is real (K-186).** When playback falls behind, Lumit drops
the preview to Half or Quarter resolution so it can keep the beat. For a while
that was half a lie: the footage was *decoded* smaller, but the compositing —
stacking the layers, running the effects — still happened on a full-size
canvas, which was the dominant cost of every played frame. The fix rests on a
neat property of how graphics cards draw. Layer positions are described in
composition pixels ("this layer sits at x = 800"), but before anything is
drawn, those numbers are converted into a card-native coordinate system that
always runs from −1 to +1 across the target, whatever size the target is. So
the engine keeps all the geometry maths in full-size comp pixels — nothing
about the layout changes — and simply allocates a smaller canvas for the
result; the −1..+1 step lands the same picture on the smaller canvas
automatically. One rounding function decides what "half of 1920×1080" means
everywhere, so no two parts of the pipeline can disagree about the size by a
pixel. Export never uses a scale (it always renders full size), and the
one-walk matrix above pins that path unchanged — which is exactly why shrinking
the preview cannot quietly shrink your exported file.

**Playback renders ahead and presents on time.** For a while playback was a
strict lockstep: render a frame, show it, wait for the next one to be due,
render again. That made every frame's deadline personal — one expensive frame
(a heavy effect, an unlucky decode) blew its own budget and the picture
stuttered, even if the thirty frames around it were cheap. Now the worker keeps
a small queue — the ring — of frames it has already rendered but not yet shown.
Rendering runs as far ahead as the ring allows; *showing* a frame (a single
cheap GPU copy) happens only when that frame's moment arrives. The gain is
slack: a stretch of cheap or cached frames fills the ring, and an expensive
frame can then take several frames' worth of time without anyone noticing,
because the ring keeps presenting on schedule while it works. How far ahead to
render is not a guess — the worker measures what frames have recently cost and
sizes the ring from the slow end of those measurements, so a struggling comp
gets more slack and a cheap one is not hoarding graphics memory. The two
playback modes keep their promises: every-frame still shows every frame in
order at the comp's own rate (a full ring is not a licence to rush), and
adaptive still keeps to the clock, now by showing the newest queued frame the
clock has reached. Pressing stop, or seeking, simply throws the ring away —
frames rendered ahead for a future that was cancelled are dropped unshown.

**The graphics card decodes the video too.** Modern graphics cards carry a
dedicated video unit — separate silicon whose only job is undoing H.264/HEVC
compression — and on Windows Lumit now hands the compressed stream straight to
it (the D3D11VA interface). The decoded picture is brought back to ordinary
memory and joins the pipeline exactly where a software-decoded frame would, so
nothing downstream can tell the difference. That indifference is enforced, not
assumed: video decoding is defined so precisely that hardware and software must
produce identical pixels, and a test decodes the same frames both ways and
compares every byte. (Finding that test's tolerance needed one real fix: the
converter library treats the hardware's pixel layout slightly differently at
sharp colour edges, so the hardware frame is first repacked into the software
layout — pure shuffling, no values change — and then converted identically.)
Anything about the hardware path failing — an unsupported codec, no video
unit, a driver quirk — quietly falls back to software decoding, which now also
uses every processor core rather than the single core the library defaults to.

**Finished frames stay on the graphics card (K-187).** Once a frame has been
fully composited and colour-managed, throwing it away and redoing all that
work the next time the playhead lands there is pure waste — so the renderer
now keeps finished frames in the graphics card's own memory, up to a budget
you set in Settings (default 512 MB). Revisit a frame — scrub back over it,
replay a span — and it is shown without compositing anything at all. Two
rules keep this honest. First, these frames are filed by *where* they are
(composition, frame number, preview size), not by what is in them, so the
moment you commit any edit the whole store is dropped — a stale picture is
never worth a saved render. Second, the frames you see while *dragging* a
value are provisional — the document hasn't committed them — so drag renders
deliberately never read from or write into the store. The Timeline's cache
bar now includes these card-held frames in its green, which is what makes the
bar meaningful again on the zero-copy Viewer.

**The editor fills the cache while you think.** When you stop interacting for
a fifth of a second, the worker starts quietly rendering the frames around
the playhead into that on-card store — two frames ahead for every one behind,
because you are more likely to press play than to rewind, staying inside the
work area when one is set. It renders exactly one frame per wake, so the
instant you scrub, drag or press play, your request pre-empts the filling
within a single render. It also knows when to stop: when everything nearby is
held, or when the budget is full, it goes back to sleep entirely rather than
burning the GPU on frames it would immediately have to evict. The effect is
simple to feel: pause anywhere, wait a moment, and the stretch of timeline in
front of you plays back instantly.

**Decoding runs ahead on its own thread.** Even with the ring, one worker used
to do everything for a frame in sequence: decode the source video, then
composite it, then move to the next frame. But playback always knows which
frames come next, so a separate decode thread now works on the NEXT few
frames' source video while the worker composites the current one. Finished
pixels are filed into the decoded-frame cache under exactly the name the
worker's own decode would look up, so when the worker gets there the expensive
half of its job is already done — a frame then costs whichever is larger of
decode and composite, not the two added together. There is no shared state to
fight over: the decode thread has its own decoders, and the hand-off is a
one-way delivery of finished pixels. A stop or seek marks everything in flight
as unwanted, and late deliveries are dropped on arrival.

**The bottom strip tells you where you stand.** The thin bar under the panels
now answers three quiet questions at a glance. On the left, whether your work
is on disk: the document store stamps every committed change with a running
revision number, a save records which revision it wrote, and "Unsaved changes"
simply means the two no longer agree — which is why undoing back to how things
looked still reads as unsaved: only a save proves the file matches. (A brand
new, untouched project says "Not saved yet" instead, because there is nothing
to lose.) Next to that sits the cache meter — how full the rendered-frame
store is, with the exact megabytes beside it; clicking it empties the store.
And after that comes the notice area: one line of feedback at a time ("Saved
to…", or "Could not open…" in the warning tint for a genuine error), each with
a × to dismiss it. Notices live in the frontend for now — the engine has no
message stream of its own yet — so only things the interface itself does can
post one.

**One clock face for every length.** Durations and positions read as
`HH:MM:SS:FF` timecode everywhere — the Viewer's readout, the Project panel's
info header, the Composition settings duration box — from one tiny shared
module (`state/timecode.dart`), so a length can never print two different ways
in two panels. The `FF` part is "frames past the last whole second", counted
at the rate rounded up (29.97 fps counts thirty to the second, as every
editor does), and the field grows with the rate: a 600 fps comp counts to
`:599`, so it gets three digits. Typing a timecode into the duration box is
read at the rate typed above it and converted to exact seconds before it is
stored — the document itself never stores a frame count (K-180).

**Frames and times, remembered rather than re-asked.** Inside the document a
keyframe sits at an exact *time* — a fraction of a second — not at a frame
number (K-180), so the interface is forever converting between the two: "the
playhead is on frame 30, what time is that?", "this key is at 1/2 second, which
frame is that?" Both conversions belong to the engine, because frame-rate
arithmetic done twice in two languages is frame-rate arithmetic done two
slightly different ways. But asking is a crossing of the boundary, and every
animated row was asking for itself: clicking a new spot on the timeline made
sixty-seven crossings, sixty of which were the same handful of questions asked
over and over by rows that all happen to be looking at the same playhead.

The fix is a notebook (`state/comp_time.dart`). The engine still works out each
answer; Dart writes it down and reads it back the next time the same question
comes up. Only one thing can make an old answer wrong — changing the
composition's frame rate — so the whole notebook is torn up whenever the engine
reports a committed change to the document, which covers a settings edit and an
undo of one alike. The same click now costs seven crossings, and the bridge-call
budget test fails the build if it climbs back past twenty.
**The Effect controls panel reads as one list.** For a while each effect on a
layer sat in its own bordered box, and a layer with four effects on it looked
like four unrelated cards stacked up. But a layer's effects *are* one list —
they run in order, each feeding the next — and they are already drawn as one
list in the Timeline when you twirl a layer open. So the panel draws them that
way too, and the two surfaces now agree.

Each part of the panel — Source, Transform, one per effect — is a **heading
bar you can twirl**: click it and its rows fold away, click it again and they
come back. Under the heading, every row sits on its own line with a hairline
between it and the next, so a long list stays readable. A newly applied effect
arrives open, because the moment after you apply one is exactly when you want
its controls.

Every row is **two columns**. The property's name is on the left, its control
is on the right, and there is deliberately no line drawn between them: they
read as columns because they *line up* down the whole panel — which is all a
column really is. Making that true takes one small trick. The stopwatch that
starts a property animating lives to the left of the name, but some
settings — a dropdown, a filename — can never animate and so have no
stopwatch. If those rows simply left it out, their names would start further
left than everyone else's and the column would wobble. So a row with no
stopwatch leaves an empty space exactly the stopwatch's width instead.

The heading row follows the same two columns. On the left: the twirl, the
effect's on/off tick, and its name. Then, at the top of the *value* column,
**Reset** — placed there because that is what it acts on, the values below it.
Reset puts every setting of that effect back to the value it shipped with,
which also means any animation you put on it goes away; that is one single
undo step, not one per setting. The buttons that move the effect up and down
the stack, and the × that removes it, stay hard against the right-hand edge,
away from Reset: removing an effect is not an adjustment to it, and the two
should not sit side by side where a slip costs you your work.

If you have the interface set to the **round** shape rather than the sharp
one, the same rows come wrapped in the soft floating-card chrome. The two
shapes differ in their chrome, never in their layout — the same names in the
same column either way.

One thing this layout knows it cannot cover: a handful of effects want a
*picture* rather than a list of numbers. Levels wants a histogram with handles
under it; Curves wants a spline you bend with the pointer. Neither is a stack
of labelled rows, and squeezing them into one would be the wrong control for
the job. So the panel asks a single question first — does this effect bring
its own display? — and only draws rows when the answer is no. Nothing answers
yes yet. The point of asking now is that when the first one arrives it says so
in one place, rather than becoming a special case wedged into the middle of
the layout.

### Themes you can edit (K-202)

Settings → Appearance has a **Customise…** button under the colour scheme. It
lists every colour the interface uses — its name, a line saying where it shows
up, and a swatch you click to change. It opens on the colours you are currently
using and every change shows immediately, because a colour you cannot see
against everything else is a colour you cannot judge.

**Save** asks for a name the first time and adds the theme to the scheme list;
saving again updates it. What is stored is deliberately *not* a copy of the whole
theme — only a name, whether it is light or dark, and the colours you actually
set. That is what lets a theme saved last year still open after Lumit gains new
colours: anything new comes from the light or dark base underneath. The colours
are written into your settings file as ordinary `#rrggbb` text, so you can read
one, paste one in, or send a theme to somebody.

The scheme list is grouped into Dark, Light and Custom, because light or dark is
the first thing anyone picks by.

**Two surfaces stay neutral whatever your theme says.** The Viewer's surround
and the scopes are measuring instruments, not decoration: you cannot judge a
grade against a tinted surround, and a waveform is read as a bright trace on
near-black. Each has one opt-in switch in Settings → Appearance, off by default,
and neither is offered in the customise window. The general rule and its two
switches are [15-DESIGN.md](15-DESIGN.md) §2.1.

**The Timeline has two background shades.** The part inside the work area keeps
the normal panel colour; everything outside it is washed slightly darker, so the
span you are actually going to export is visible at a glance. On a light theme
the wash is a bigger step, because the same difference reads as less on a bright
background. Selected rows have a colour of their own that brightens on a dark
theme and *darkens* on a light one — a selection has to stand out from whichever
background it lands on, which a simple light-to-dark ramp cannot express.

### The keyboard, and why the engine owns it (K-199)

Everybody arrives with different muscle memory, and sometimes the operating
system takes a key from under you — on Windows, left Alt with Shift switches
keyboard layouts, so a chord bound there never reaches Lumit at all. So Lumit has
a **keymap**: a list saying "this key combination, in this place, runs this
command", and a Settings page where you can change any of it.

Four words. A **chord** is a key with its modifiers (`Space`, `Ctrl+D`). A
**context** is where you are: the whole app, or one focused panel. An **action**
is a command named by a short stable string like `playback.toggle`. A **binding**
ties a chord in a context to an action.

**The engine decides what a chord means.** Working out that the Timeline's own
`D` beats the app-wide `D` while the Timeline is focused, that two bindings now
clash, or that this JSON is a keymap and that one is not — those are rules, and
rules living in the frontend are rules nobody can test without a window.
`crates/lumit-keymap` is the rulebook, with no windowing code in it at all.

The frontend keeps two jobs, both genuinely its own:

1. **Spelling the keypress** — writing what Flutter reports as text the engine
   reads, `Mod+Alt+Shift+T`, where `Mod` is Cmd on a Mac and Ctrl elsewhere. That
   translation is why a keymap written on a Mac still reads on Windows.
2. **Recognising a gesture** — telling three quick taps of `U` from three presses
   over a minute is the same judgement as spotting a double-click, and belongs
   with the keyboard rather than with the document.

Your keymap lives in the engine while Lumit runs and in your workspace settings
file between runs; the frontend stores it as an opaque lump of text it never
reads. So "the keymap that survives a restart" and "the keymap you email to a
friend" are one format, and Export and Import are the same code as save and
restore.

Three behaviours in Settings → Keymap are deliberate rather than accidental:

- **One row, one key** (K-200). No shipped command has two chords; bind a second
  spelling yourself if you want one.
- **Taking a key another command already has is allowed.** It has to be — a swap
  needs a moment where one key is claimed twice. If both could fire at the same
  time you get a warning naming the clash; if they could not, the old command
  loses the key and its row goes blank where you can see it.
- **Reset is per row**, and restores every chord the shipped keymap gives that
  command.

`U` in the Timeline opens the properties you have animated on the selected
layer; again straight away opens everything you have *changed*, animated or not;
a third press shuts the layer. With nothing selected it asks the same question of
the whole composition. The panel counts the taps; the engine answers which groups
qualify, because "has a keyframe" and "differs from a fresh layer" are questions
about the document.

Some rows are bindings for commands this frontend has not built. The keys are
really bound and pressing them does nothing. They are listed rather than hidden
so the table describes the keymap truthfully; [TODO.md](TODO.md) carries the gap.

### Selection you can get out of, and a work area that is really there (K-203)

**There is always a way to select nothing.** Clicking empty ground in either half
of the Timeline deselects everything — no layer, no properties, no keyframes. A
name, a switch, a property row, a bar or a keyframe still takes its own click.
Closing a fold forgets what was selected inside it, and clicking a layer's name
clears the property selection: "select this layer" ought to mean this layer and
not also whatever was picked on the last one. Without this, every command that
reads the selection is stuck with whatever was picked last.

**The work area exists from the start.** The engine stores "this comp has not
been narrowed" as nothing at all, which is honest, but the interface has no such
state: a comp nobody has narrowed has a work area of the whole comp. That is what
leaves two ends there to take hold of, gives the darker out-of-range wash
something to shade, and gives `B` and `N` something to set. "Clear work area"
widens it back to the whole comp rather than making it vanish.

**One path to disk.** File → Save is an ordinary function that both the menu and
the keyboard call, rather than two paths that have to agree.

### Why a layer drag moves both halves of the Timeline (K-208)

The Timeline is a table in two halves — the outline on the left, the lane area on
the right — built as two columns of rows with their vertical scrolls tied
together. That is what lets each half scroll horizontally on its own.

The drag gesture lives in the outline, because the name is the handle you grab.
So the knowledge of a drag must not belong to either half. Two values live on the
panel itself and are handed to both: **the drag in flight** (which row was
lifted, which row it would land on) and **the row heights** (how tall each
layer's block is, counting open fold-out rows). Each half wraps every layer's
block in the same small widget, which asks one shared function "how far does
block *n* move right now?". Both halves ask the same question of the same
numbers, so they answer identically. That function is ordinary arithmetic with no
widgets in it, so it is tested directly.

Two details. The blocks are moved with a **transform**, not by changing the
layout, so nothing reflows underneath a gesture in progress and the drop lands
where the document says it should. And the movement runs at the duration from
Settings → Interface → Animation level, including zero — an animation the user
cannot turn off is a bug, not a flourish.

One overlay draws the row seams for each half. Drawing them per row *and* in a
full-height overlay makes the two disagree by whatever fraction of a pixel the
scroll offset sits at.

### Hairlines, icons, and the pixel grid (K-209)

Icons are line art on a 24-unit grid with strokes 1.5 units thick. Drawn at 24
pixels the lines are 1.5 px; at 16 px they are exactly 1; at 12 px they are 0.75.
A three-quarter-pixel line does not exist, so the renderer lights the pixels
either side at partial brightness and one clean stroke becomes two grey ones.
That is what "crunchy" is — anti-aliasing doing its job on geometry that does not
fit. **16px is the smallest size at which these icons have a whole pixel to put a
line in**, which is what [15-DESIGN.md](15-DESIGN.md) asks for.

The second rule applies to any hairline anywhere. A stroke is centred on its
path, so a 1-pixel line drawn along a pixel boundary covers half of each
neighbour and comes out grey and doubled. Shifting by half a pixel puts it back
on a pixel centre — but **only when the stroke is an odd number of screen pixels
wide**. On a high-DPI display where the line is a full 2 pixels it already covers
whole pixels, and shifting is what would blur it. At scalings like 150% a stroke
is 1.5 screen pixels and there is no whole number to land on; that is the nature
of the thing, not something left undone.

### Keeping the preview up with the pointer

Three separate mechanisms keep a dragged value's picture level with your hand,
and they are the three places this can go wrong: the asking, the showing, and the
remembering.

**The asking.** A drag produces values far faster than the engine draws frames,
so the frontend must choose which to ask for. Dropping any tick that arrives too
soon after the last one throws away exactly the wrong ones — you slow down, you
stop, you let go, and those final positions all arrive within a few
milliseconds. `lib/state/preview_throttle.dart` instead sends the first tick
immediately and, while the interval runs, *holds* the newest tick rather than
dropping it. Nothing is discarded without its replacement in hand, and the rate
is still bounded. The engine does the same on its side — the worker drains its
queue and keeps only the newest request — so at most one superseded render is
ever in flight. **The rule: throttle by holding the newest, never by dropping it.**

**The showing.** On a zero-copy path the engine names a piece of GPU memory. When
the size changes it makes a new one, and the frontend registers the replacement
**before** letting go of the old one — the other order leaves the Viewer with
nothing to draw for a round trip to the platform runner, which is a blank flash.
The general rule: **never show less than you were showing a moment ago.**

**The remembering.** Frames are held under content hashes (below), and a cache
that is dropped on a schedule but read on demand has a window exactly as long as
that schedule. So retirement is checked immediately before serving anything,
never only at the top of a loop turn. The engine counts any serve that happens
with retired caches still in place (`stale_serves`, visible in the cache
readout): **a counter that must stay at zero is far easier to test than a picture
that is sometimes stale.**

### Why the sound waits a moment before it starts (the pre-roll)

Press play and two things must begin. The sound starts instantly — hand the mix
to the operating system and it plays. The first frame has to be composited, which
takes as long as it takes. Starting both at the same instant therefore starts
them at different *times*, and since the sound is the clock everything follows,
adaptive playback dutifully skips forward to the frame the clock has reached.

So playback banks a few frames first. The worker holds the mix aside, renders
ahead into its ring, and starts the sound when either three frames are banked or
150 ms have passed — whichever comes first, because a comp too heavy to bank
three frames quickly must not sit in silence. The clock's zero is taken at that
moment rather than when the request arrived, so the pre-roll is not mistaken for
playback time the picture must catch up on.

### The three-tier cache (K-214, K-215)

The most expensive thing Lumit does is composite a frame, and everything about
how the editor feels comes back to how rarely it has to do that twice. The
normative specification is [06-RENDER-PIPELINE.md](06-RENDER-PIPELINE.md) §5;
the reasoning is K-214 and K-215 in [02-DECISIONS.md](02-DECISIONS.md). What
follows is the idea.

**A frame's name is a hash of what is in it.** Before rendering, Lumit hashes
everything that could affect the picture — every layer's evaluated transform, its
effects and their values, masks, blend mode, switches, which file each footage
layer reads and which frame of it, the transforms inherited from its parents, and
the preview resolution — into one 128-bit number. Two frames with the same number
are the same picture. Nothing about *where* the frame sits goes into the name, and
three behaviours you can feel fall out of that one decision:

- **An edit that cannot change a pixel costs nothing.** Renaming a layer, nudging
  the work area, moving a marker, changing the opacity of a hidden layer: same
  hashes, so every held frame is still held.
- **Undo is instantly warm.** The restored document asks for the names it asked
  for before the edit.
- **There is no invalidation code at all.** No dirty flags, no reasoning about
  which frames an edit could have reached — a genuinely hard question once a
  precomp means editing one composition changes every composition containing it.
  Values change, hashes change, old entries stop being asked for and age out.

**The catch content keying forces you to get right:** a hidden layer contributes
nothing to the hash, but a layer *parented* to it still follows it. Each layer's
contribution therefore includes the transforms of its whole parent chain.

**Three places a frame can live**, cheapest to reach first: on the graphics card
as a display texture, in memory as the same frame's bytes, and on disk as a small
file. Only the disk tier outlives the session. A frame pushed off the card is
read back and written down rather than dropped, and can be promoted straight back
up — without that upward half the lower tiers would be bookkeeping with nothing
to show for it.

Read-back does not stutter the preview because it is never performed on the
thread the picture is waiting on: the worker *asks* the card for the copy and
collects the bytes a turn or two later. A bounded number may be in flight at
once, and anything past that is dropped, costing a re-render and nothing else.

Two rules keep the ladder from wasting work. **A frame that came back up is not
sent down again** — it is already below, so copying it twice is pure traffic.
And **a frame is written to disk on the way down**, not when memory later forgets
it, so a session that ends unexpectedly has still banked what it made.

**Filling the disk tier does not wait for eviction.** A cache big enough never to
fill would otherwise never push anything out, so the tier whose only job is to
make tomorrow start warm would stay empty — and the more memory you gave it, the
more certain that became, silently, because the frames really were held on the
card. So each time the editor has been idle a moment, one held frame not yet on
disk is copied down. It runs *alongside* the fill that renders new frames: on a
long composition the fill has work for as long as memory lasts, so "after the
fill" would have meant never.

**The idle fill never re-renders a frame it already has somewhere.** It has no
deadline, so a frame in memory or in a file is fetched rather than made.
Otherwise opening yesterday's project walks a full disk cache and renders every
frame of it again.

**Climb the ladder before the frame is due.** Fetching an existing frame at the
moment it is wanted costs that frame's own budget for a memory upload, and is
useless from disk — the bytes come back from another thread after the frame has
gone past, so it gets composited from scratch anyway. Promotions and disk reads
now go out over the same window of coming frames that source decodes use.

**Why the cache bar is a photograph rather than a question.** Answering "is this
frame held?" means *naming* it, which needs the renderer's knowledge of the
footage files and is far too much work for the thread that paints the interface.
So the bar leaves a note saying which composition and scale it wants, the render
worker computes the strip and publishes it, and the bar draws what was last
published. On a long composition a first pass samples so the bar owes an answer
for the whole composition immediately — a stripe filling in from the left looks
like the *cache* filling in from the left — and a refinement pass then walks it in
bounded chunks, starting under the playhead. Only a *held* sample paints the
frames it stood for; painting a stride green off one held frame and correcting it
a moment later would flash cache the user does not have.

**The disk tier keeps an index** of each parked frame's size, cost, last use and
preview scale, because a filesystem remembers only when a file was written — so
without one it deletes the frame that took half a second to render in favour of
the one that took two milliseconds. It is two files, and the reason is a pattern
worth knowing: a single file rewritten on every change rewrites megabytes to
record one frame, and a single file rewritten occasionally loses whatever
happened since — and those frames are *worse than forgotten*, because the files
are still on disk with nothing knowing to reclaim them. So there is a snapshot
plus an append-only log of fixed-size records. Fixed size is what makes a
half-written record at the end detectable; it is discarded and the whole ones
still count. If either file is unreadable the folder is walked once and the index
rebuilt.

**Where a project caches is the project's business if it wants it to be.** The
location setting is application-wide by default, with an **Applies to** row
offering *This project*, which stores the choice inside the `.lum`. Two things
fall out of it being in the document: it travels with a copy of the project, and
it is an ordinary undoable, journalled edit. A project that never set one stores
nothing. The paths themselves are [10-FILE-FORMAT.md](10-FILE-FORMAT.md) §3.

**One number cannot answer "what is cached" for three tiers**, so the meter draws
a bar each with the megabytes beside it, and clicking one empties that tier
alone. The disk bar asks before it deletes, since that tier holds files rather
than a re-render's worth of work.

**Three shapes of bug a cache invites**, all worth recognising elsewhere:

- **Never seed "what I have already done" from "what was asked."** Seed it from a
  value that cannot be mistaken for done, or the first comparison agrees by
  accident and the change is never applied.
- **Giving up is not a policy.** A fill that refuses to render once the cache is
  nearly full sticks wherever it first filled. Keeping a *window* around the
  playhead and letting the LRU decide what leaves is a policy.
- **If you mirror a collection, mirror something that changes when its contents
  do**, not only when its size does. A cache at its budget trades one frame for
  another and both the byte count and the entry count stay put while every frame
  in it changes.

**A frame in memory is handed over, not copied.** A 1080p frame is 8 MB, and the
cache must not hold its lock while the card works. A shared handle (Rust's `Arc`)
lets the cache and the uploader point at the same bytes, so handing a frame over
costs adding one to a number. **Textures that promotion made are pooled and
written over** rather than reallocated per frame; the shared handle also answers
"is anybody still using this?" without bookkeeping — if the pool holds the only
remaining share, nothing else can be showing it. Only textures a promotion made
are reused, because a texture a composite drew into cannot have bytes written
into it.

**The decode width and the frame's name must round the same way.** A frame's name
includes how coarsely it was made, kept to 1% steps for Auto resolution so a hair
of zoom returns the same frame. Footage carries a second thing in its name — the
width it was decoded at — and computing that from the *exact* scale rather than
the rounded one gives two names for what the first rule calls one step. The cache
bar asks by a rounded scale, so it computed a different name for every frame,
found none, and drew an empty stripe over a composition that was fully cached.
Compositions of solids were unaffected, which is why every test of the bar
passed: they were all built from solids.

### Playback, the sound, and keeping time

Every-frame playback shows every frame however long it takes, so on a heavy
stretch the picture stops keeping time and the sound must stop rather than run
over a picture out of step with it.

What is measured is **the gap between one picture going out and the next** —
that gap *is* the rate you are watching. One picture arriving late stops the
sound immediately; **eight in a row arriving on time start it again**. The
asymmetry is the point: one picture landing on time by chance says nothing about
the next, so stopping takes the evidence of one and starting takes the evidence
of many. When it starts, it starts **at the picture** — the sound is moved to the
frame on screen first, so the two are together by construction rather than by
hope.

Three earlier rules failed in ways worth keeping: measuring how far *ahead* the
sound had got cannot restart it, because the clock stops reporting when the sound
stops; waiting for the picture to reach the sound's position cannot work, because
the sound stopped ahead by however long the slow frame took; and restarting as
soon as finished frames are waiting stutters, because frames are usually waiting
even when the run is nowhere near full speed.

### The toolbar and the tool model (K-216, K-228)

**A tool is an answer to one question: what does dragging do?** Not what the
button does — the button only arms it. One tool is armed at a time for the whole
application, so there is never a question of which panel thinks it is holding
what.

**Groups and the little triangle.** Thirteen buttons cover about thirty tools;
tools doing the same sort of job share a button as After Effects shares them. The
button shows the one you last used and wears a triangle to say there is more
underneath; hold or right-click it for the rest. The keyboard does the same
without the flyout — `Q` arms the shape tool you last had, and `Q` again steps to
the next and comes round. That "press again to cycle" rule is the one bit of a
toolbar people notice immediately when it is missing.

**The chords come from the engine, not the strip.** The toolbar knows only which
*action name* arms which group, so rebinding a tool in Settings → Keymap changes
nothing here. Tools sit in a keymap context of their own called `Tools`, which is
not a panel, so no panel is ever "in" it: a keypress is offered to the focused
panel first, then to the app-wide table, then to the tools. That ordering lets
`C` cut a clip when the Timeline has focus and arm the razor everywhere else,
without either binding knowing the other exists.

**Unbuilt tools are shown, greyed and unpickable.** The whole specified set is
drawn, because shipping only the working tools would teach a wrong idea of what
the application is and leave nowhere agreed for the rest to appear. The refusal
lives in the state that holds the armed tool rather than in the button — there
are three ways to arm a tool and only one is a button. A group with nothing built
in it cannot be pressed; a mixed group opens on one that works and cycles only
through those. The `ready` flag driving this is the same one the tooltips use, so
a tool becomes pickable in the commit that makes it do something, and a test pins
the whole set.

### Wireframes, and what "selected" means on the picture (K-217)

**A wireframe is a rectangle that knows what it is round.** Every layer has a
size of its own, and the box is that rectangle pushed through the layer's
transform — so it moves, stretches and *turns* with the layer rather than staying
square to the screen. A Null has no picture, so it is given a 100×100 box by
convention; without one you could never grab the very layers rigs are built out
of.

Sizes arrive late, because asking how big a video file is means opening it. The
Viewer keeps a small notebook: easy answers are read from the document and
dropped whenever it changes, a clip is measured once and remembered for the
session, and until the measurement lands the layer is treated as comp-sized — the
same guess the engine makes when it cannot read a file.

**Hit-testing runs backwards through the transform.** Asking whether the pointer
is inside a rotated, scaled quadrilateral is fiddly; running the *pointer*
backwards into the layer's own coordinates and asking whether it is between 0 and
the width is one subtraction and one rotation, exact at any zoom. It is why there
is no polygon geometry in the code at all. The mask tools use the same inverse.

**The handles.** Eight squares on corners and edge midpoints; dragging one asks
what scale would put that corner under the pointer. Shift takes the same factor
both ways. A bar stands off the top edge with a knob on the end for rotation,
measuring the angle swept about the anchor; Shift snaps to 45°. A ninth handle is
the anchor point itself, which pans behind. It grabs from 8 pixels where the
scale handles grab from 16, and that asymmetry *is* the design: the anchor sits
in the middle of the layer, which is also where you naturally grab to drag it, so
a generous target would turn every move into a pan-behind.

**Remember where the pointer went down.** Flutter does not report a drag until
the pointer has travelled about 18 pixels. Ask "what did they grab?" at that
moment and it has already left a nine-pixel handle; measure a rotation from there
and a quarter-turn comes out as 45°. Record the press position separately and
measure from it, adding the distance already travelled so nothing lags. **Any
gesture whose meaning depends on where it began has to remember where it began.**

**Selecting several.** Shift-click adds or removes; dragging from empty space
rubber-bands and takes every layer *wholly* inside — a layer merely clipped is
more likely an accident than an intention. The band settles the selection when
you let go rather than clearing it on press, which is what lets the same gesture
gather mask points belonging to an already-selected layer without dropping that
layer first. If it catches no points it is the layer sweep it always was, which
is why there is no "point mode" to switch into.

**The Hand tool is the same picture with the editing taken out** — boxes of
whatever is selected, no handles, no hover highlight, and every drag moves the
view. That is the entire difference between the two tools.

### Zoom, and why it flies (K-218)

Three gestures change magnification — the wheel, a Zoom-tool click, and dragging
a box — and they are one question in different clothes, so they go through the
same two small functions.

**Anchoring: the point you aimed at does not move.** Work out which comp point is
under the cursor, then solve the pan that puts it back under the cursor at the
new magnification. It is the difference between leaning in and teleporting, and
it is what the unit tests check, one line each.

Alt inverts every gesture: click halves instead of doubling, and an Alt-drag
shrinks everything visible into the box you drew, still centred on it — the exact
inverse, so Alt-dragging the same box undoes the zoom you just did. A drag of a
few pixels is treated as a click, or a wobbling hand would fit a three-pixel box
to the panel and throw the picture into orbit.

**The travel is geometric, not linear.** Magnification is a ratio: 1× to 8× is
three doublings, not seven units. Interpolating the number itself makes the first
half bolt and the second half crawl; interpolating the *logarithm* makes it one
steady move, for the same reason volume sliders are in decibels. Magnification
and pan travel from one clock, or the anchor drifts mid-flight where it is most
visible.

**The wheel is left alone** — it already arrives as a stream of small steps, and
a gesture that is already continuous does not want a second continuity on top. A
fresh frame is asked for when the flight *lands*, not per animation frame.

**Magnification is not resolution.** Magnification is how big the picture is
drawn and costs nothing. Resolution is how many pixels the engine is asked to
make. The render scale follows the *panel* — a Viewer docked into a corner is
genuinely cheap — and must not follow the zoom inside it. Lowering it on zoom-out
throws away every cached frame for a gesture that only meant "let me see more",
and raising it on zoom-in is impossible above the composition's own resolution.

**Anything drawn per unit of area must be bounded by what is on screen, not by
what is being looked at.** The transparency checkerboard is a loop of small
rectangles: fine over a panel, half a million rectangles per frame over an HD
picture at 800%. It is bounded by the panel and clipped to the picture, with the
pattern pinned to the picture's corner so panning slides the board with it.

### Drawn pointers (K-219, K-226, K-230)

Operating systems ship a short, inconsistent list of cursors. Flutter offers
names for a grabbing hand and a magnifier that Windows does not have; ask there
and the embedder quietly returns the ordinary arrow — nothing errors, and the
tool simply looks like no tool at all. So tools that need a pointer the system
lacks hide the system one over the Viewer and paint their own.

That trouble buys something a system cursor could never do: a drawn pointer can
*change*. The rotation arc leans round the anchor, drawn square to the line from
the anchor out to your pointer, and tightens towards the corners — measured in
the *layer's* own coordinates, so a layer on its side still has its corners where
its corners are. Shape tools and the Pen wear the eyedropper's crosshair, meaning
*this exact pixel*, with the tool's icon tucked down and to the right so it does
not sit on the shape you are dragging out; it is drawn twice, a dark copy under a
bright one, so it reads on white or black. Painting tools get a ring the size of
the stroke they would leave, following the magnification between a visible
minimum and a sane maximum, because it is a pointer, not the paint.

**Draw from pointer movement, not from hover.** A `MouseRegion` reports hovering,
which by definition stops the moment *any* button goes down — including the right
one, which these tools do not use. A pointer drawn from hover freezes where you
pressed, inside the very shape you are dragging out. `DrawnPointerRegion` listens
for movement instead, which is reported whatever the buttons are doing.

**Holding the pointer still.** Some drags aim at a place; some are pure movement,
like turning a camera. For the second kind, letting the pointer travel is pure
loss — it wanders into the corner of the screen, stops, and the drag stops with
it while your hand is still going. There is no "lock the pointer" call on
Windows, so: remember where it was on button-down and put it straight back after
each movement. The subtlety is that **putting it back is itself a movement**,
reported with a delta that exactly cancels the real one — so the drag measures
each event against the anchor it is pinned to rather than against the previous
event, and the put-back reads as no movement at all. Where the platform cannot do
this, the freeze reports that it failed and the drag falls back to reading
movements between events.

### Pan behind, and the razor (K-220, K-221)

**The Anchor point tool moves the pivot without moving the picture.** The anchor
is what a layer spins and scales about and also what Position places, so moving
it alone makes the layer jump. This tool moves the anchor *and* shifts Position by
exactly the amount that cancels the jump. After Effects calls it **pan behind**,
and the name is the idea: you are sliding the layer behind its own pivot. Shift
locks to one axis measured on the *screen*, because it is about the gesture your
hand is making; Ctrl snaps the pivot to the layer's corners, edge midpoints and
centre, with the snap distance measured in screen pixels so it is as fussy as
your zoom allows. The whole drag commits as **one** edit: land half of it and the
picture moves, which is the one thing this tool promises not to do.

**The Razor cuts where you click**, as Premiere's does — After Effects has no
razor at all. Shift-clicking cuts every layer under that moment. What a cut does
depends on the layer: a Sequence layer gets an **edit point** and stays one
layer; anything else **splits into two layers**, both keeping the source,
effects, masks, parent and keyframes. What makes that invisible is `start_offset`
— where the layer's own time zero sits on the comp's clock — which both halves
keep, so each shows exactly the frames it showed before and every keyframe stays
on the comp frame it was on.

**Cutting a retimed layer leaves a keyframe at the cut, on both halves.** The two
halves' speed ramps are not two curves that look alike, they are the same curve,
so bending one would bend the other. The key changes nothing because of **de
Casteljau's algorithm**: a cubic bezier splits at any point into two cubics whose
union is the original curve — not an approximation, the same curve. The shape
survives by construction; the code only converts the pieces back into the
speed-and-influence numbers a keyframe stores. The test samples the curve two
hundred times, inserts the key, samples again, and demands the lists agree.

**There is one razor.** The Timeline's "Arm razor" menu item arms the toolbar's
tool rather than a flag of its own — two bits of state meaning the same thing
will disagree the first time somebody uses the other one.

### Masks (K-222, K-223, K-224)

A mask is a shape drawn on a layer deciding which of its pixels show. The engine
has always had them; what was missing was a way for the interface to read and
change them.

**A mask crosses the bridge as its path** — a list of vertices, each a position
plus two handles, one for the curve arriving and one for the curve leaving. A
corner has both handles zero; a smooth vertex has them pointing opposite ways.
That is exactly how the engine stores it, so the numbers cross unchanged.

**The coordinates are the layer's own**, not the composition's. That is what
makes a mask travel with its layer under any transform without anything
recalculating it.

**Two kinds of drawing gesture.** Rectangle, rounded rectangle, ellipse and star
are *boxes*: drag two opposite corners, Shift keeps it square. The Pen is a
*path*: each click plants a corner, a click-and-drag pulls out a mirrored pair of
curve handles unless you hold Alt, clicking the first point closes the shape, and
closing is what applies it. Escape discards; Backspace takes back the last point.
The polygon tool drags out a regular polygon, the star without its notches — the
path gesture is the *Pen's*, which is what a pen tool is everywhere.

**Every edit is the whole list.** The engine's mask op replaces a layer's entire
mask list at once, which sounds wasteful and is exactly right: adding, deleting,
renaming, inverting and reordering become the same operation, each trivially
reversible (the old list is the undo) and each one undo step. The effect stack
makes the same choice.

**Moving points.** Every vertex of a selected layer's mask is a small square you
can click, Shift-click, or sweep. Travel is put through each layer's inverse map
before being added to the point, so a selection spanning two layers with
different transforms still moves together under the pointer. The picture catches
up on release rather than following live: the live-preview path patches a layer's
*transform* into a copy of the document, and a mask path does not fit through it.

**Masks appear above Effects** in a layer's twirl-down, because masks are applied
before effects, so the list reads top-to-bottom in the order the picture is
built. The heading appears only once there is a mask.

**Drawing with nothing selected posts a notice rather than inventing a layer.**
After Effects would make a shape layer; Lumit's engine has no such layer kind.
Making a solid and putting a mask on it would be a lie in the layer list, and one
that would have to be untold the day the real thing arrives.

### Typing on the picture (K-225)

The **Type tool** makes a text layer where you point, or edits the one you click.
A layer you never typed into is removed when the edit ends — an empty line draws
no pixels, so a stray click would otherwise leave an invisible row.

**Why the words appear before the layer changes.** Writing the layer on each
keystroke would make undo take a sentence apart one letter at a time. So while
you type the Viewer shows a *preview* — the same trick a dragged layer uses,
where the engine renders a copy of the project with one value changed — and the
layer is written once, when you stop. One session of typing is one undo step.

**The caret is ours, the text is the engine's.** Underneath is a real invisible
text field, which is why arrows, selection, backspace, paste and accented
characters behave as they do everywhere. The caret's position is a guess — half
the point size per character — and it is *the same guess the engine makes* when
placing a text layer's anchor. Two guesses that agree keep the caret at the end
of the line; the real letter widths live in the rasteriser and have never crossed
the bridge. When they do, both guesses get replaced together.

**The anchor trick.** A new layer holds an empty line with no middle to be
anchored in, so its anchor sits at the line's left end. When the edit ends the
anchor moves to the middle of what you typed and Position moves by exactly the
amount that cancels it — the same pan-behind sum. The words never appear to
shift, and afterwards the layer scales and turns about itself.

**Tool options.** The toolbar shows what the armed tool draws with: a fill swatch
and size for type, fill, stroke and stroke width for shapes and the Pen. The
stroke controls were disabled when they first appeared, because nothing in the
engine stroked anything; a shape layer's outline (K-237, below) is the thing that
made them mean something, and they paint now.

### Moving the camera by dragging (K-229)

A camera has a position, three rotations and a *zoom* (focal distance in comp
pixels). The plane at the camera's own position renders 1:1 and centred, which is
another way of saying **the camera's position is the point it is looking at**;
the eye sits `zoom` behind that. Once you see that, the three tools are almost
trivial:

- **Orbit** changes only the rotations. The eye is derived from position *and*
  rotations, so turning swings the eye round the point being looked at — a real
  orbit with no extra pivot stored anywhere.
- **Track** slides the position along the camera's own left-right and up-down
  axes.
- **Dolly** slides it along the way the camera points. A pixel of drag moves a
  fraction of how far away things already are, so a wide shot covers ground and a
  close-up creeps.

**The axes are built in the same order the compositor builds its matrix**
(`Ry · Rx · Rz`). Get that wrong and "forward" sends the camera sideways, so the
axes have tests against hand-computed cases. **Dragging up lifts the camera over
the top, which means tilting it to look down** — every application that gets this
backwards is described as having an inverted camera, so it has its own test. The
pitch stops just short of straight down rather than wrapping, because one pixel
past the pole flips the picture over.

Still missing: a separate point of interest (AE's two-node camera), the Unified
Camera tool, and depth-of-field handles on the picture.

### Painting: what a brush stroke actually is (K-227)

Drag a brush over the picture and Lumit keeps **the drag, not the paint**. What
goes into the project is the path your pointer took — in the layer's own
coordinates — with the colour, the width, how hard the edge is, how opaque the
mark is, and which tool made it. Every time that frame is drawn, the stroke is
stamped again at whatever size the frame is being rendered at.

That one decision buys three things. Painting on a quarter-size preview and
exporting at full size gives a *full-size* stroke, not a blurry small one.
Changing a stroke's colour next week is a number, not a repaint. And undo removes
one stroke, because a stroke is one thing rather than a smear of changed pixels.

**The three tools.** The brush lays down the toolbar's fill colour. The eraser
takes the layer's transparency away — the colour underneath is untouched, which
is why lowering an erase's opacity later brings the picture back. The clone stamp
copies from somewhere else on the same layer: `Alt`-click sets the place it
copies *from*, and then painting carries that offset along with you. It is how a
boom mic or a blemish gets painted out.

**The trap in cloning, and how it is avoided.** A clone that read the picture as
it is being painted would sample its own output a few dabs back and smear it
across the frame. So a clone reads a copy of the layer taken *before any stroke
in that pass was stamped*. The copy is only made when something actually clones —
copying a 4K layer is not free.

**Why the brush is a chain of dabs.** A round brush is stamped along the path
every quarter of its radius, and where two dabs overlap the coverage takes the
*greater* of the two rather than adding them. Adding would make the middle of a
slow stroke solid and its ends thin — the classic wobbly-line artefact. The
stroke's own opacity is applied once, at the end, so a half-opaque stroke is
evenly half-opaque all the way along.

**Where paint sits in the picture.** Strokes go into the layer's own pixels
*before* its masks gate them and before its effects run. So a mask can cut away
part of what you painted, and a blur blurs it — both the obvious meanings. Two
side effects fall out of that: a plain solid, which is normally stored as a tiny
8×8 tile and stretched, gets rasterised at its real size once it has paint on it
(a brush needs pixels to mark); and paint on a collapsed precomp layer forces the
precomp to be rendered separately, exactly as a mask already does.

**Where to find your strokes afterwards.** In the Timeline, a painted layer grows
a **Paint** heading in its twirl-down, between Masks and Effects — the order the
picture is built in. Each row is named for the tool that made it, carries its
opacity, and its menu deletes it. `Backspace` while painting takes the last stroke
back; `Escape` abandons one mid-drag.

**What is not built.** Pressure and tilt from a tablet, brushes that are not
round, spacing and scatter, write-on (a stroke that draws itself on over time),
per-stroke blending modes, and painting in Layer view. There is also no GPU path
yet — the stamping is a plain loop over pixels on the CPU, next door to the mask
rasteriser. That last one is the only one that would change the code rather than
add to it, and it changes how a stroke is *drawn*, not what a stroke *is*, which
is why the storage was settled first.

### Shape layers: art that is numbers, not pixels (K-237)

Until now the shape tools could only draw a **mask** — a path *on* another
layer, deciding which of its pixels show. Drag one with nothing selected and it
apologised. Now it makes a **shape layer**: a layer whose picture *is* the path.
A rectangle, an ellipse, a drawn path, filled and outlined, stored as numbers, so
it stays crisp at any size and every part of it stays changeable.

**Nothing about the drawing changed.** The path a shape tool produces is exactly
the path it always produced — the same maths, the same vertex type across the
bridge. A mask's path and a shape's path differ in what they *do*, not in what
they are, which is why this landed without touching the tools' geometry at all.

**How it is drawn.** A fill goes through the *mask* rasteriser: the same
scanline walk that decides which pixels a mask gates decides which pixels a fill
covers. An outline goes through the *paint* rasteriser: an outline is a brush run
along the path, which is precisely what a paint stroke is. Two pieces of the
engine that already existed, each doing the job it was written for, instead of a
third one that could disagree with both.

**The trap, which was known in advance.** Every other kind of layer has a size
fixed by whatever it came from: a clip's frame size, a solid's dimensions, a
comp's. A shape layer's size is the box its art fills — and that box *moves the
moment you edit the art*. The cache that remembers layer sizes keys on the
document's revision, so it follows; the note that planned this feature flagged it
as the thing to watch, and it was.

Both sides measure that box the same way: by the paths' **control points**
rather than the curves themselves. A curve never leaves the hull of its own
control points, so the box is always correct and occasionally a little generous —
a few transparent pixels, and never a shape clipped by its own frame.

**Where the art goes.** A new shape layer lands exactly where you drew it, at the
top of the stack, and becomes the selection — so drawing a second shape while the
first is still selected draws a *mask on it*, which is what After Effects does
and what makes the two halves of the gesture feel like one tool. The art lists in
the Timeline under a **Contents** heading, above Masks and Effects, because that
is the order the picture is built in.

**And the stroke swatches finally do something.** They were on the toolbar and
greyed since the Type tool landed, because nothing in the engine outlined
anything. A shape layer's art does, so they paint now: set a width of zero and
you get a fill with no outline.

What is missing: nested groups and the shape modifiers (repeater, trim paths,
wiggle), gradient fills, dashed strokes, joins and caps other than round, animated
paths, and dragging a shape's points on the picture the way mask points can be
dragged.

### A picture that would not change, and why (K-238)

Painting worked. The stroke crossed the bridge, the renderer drew it, and the
tests said so. It simply never appeared on screen — and nothing you did brought
it back.

The cause is worth understanding, because it will come up again. Lumit gives
every finished frame a **name**: a hash of everything that went into it, so two
frames with the same name are guaranteed to be the same picture and one can
stand in for the other. That is what makes scrubbing feel light — you are mostly
looking at frames that have already been drawn. It also means that if the name
does not notice a change, the change is invisible: the application looks at the
name, finds a frame already filed under it, and shows you that one.

The name knew about a layer's masks. Nobody had told it about a layer's **paint**.
So a brush drag changed nothing as far as the name was concerned, every cached
frame stayed valid, and the mark you had just made was never drawn. Moving
something else in the composition would have brought it back, because that
changes the name for other reasons — which is why it looked so arbitrary.

Two things follow from the fix. The clone stamp and the eraser were never broken
either; all three painting tools were writing strokes that were then hidden by
the same cache. And the hashing is done **only when a layer actually has paint**,
so every layer that has none keeps the name it already had and no frame banked by
an earlier version is thrown away.

### Drawing what you are about to make (K-238)

A shape tool used to show you the outline of what you were dragging — but only
when a layer was selected, because it asked *that layer* where to put the points
on screen. With nothing selected there was no layer to ask, so it drew nothing at
all. That is precisely the case that makes a **shape layer**, which is most of
the reason to pick up a shape tool: you dragged blind and the shape appeared when
you let go.

The preview asks for a **space** now rather than a layer — a pair of maps, one
each way — and there is always a space, because the composition has a placement
of its own. Same drawing, same geometry; the only question was ever which
coordinates the path is built in.

While that was open, the preview started showing the **shape** rather than its
outline: filled in the toolbar's own fill, outlined in its stroke, at half
opacity. The swatches now answer "what colour is this going to be?" before the
shape exists, which they could not do when the only thing on screen was a thin
accent line. Half opacity and not full, because a solid preview looks exactly
like a shape that is already there, and this one is not — nothing is in the
document until you let go.

A drag on a layer that *is* selected still previews in the accent colour. That
one is making a **mask**, and a mask has no colour: it decides which pixels show.
Filling it in the shape colour would promise something that never arrives.

### Selecting something that is no longer there (K-238)

A selection looks like a highlight. It is really the answer to a question every
tool asks: *which layer am I acting on?*

Draw a shape layer and it becomes selected, so the next drag draws a mask on it —
that is the whole gesture, and it is what After Effects does. Now press undo. The
layer goes, but its name stayed in the selection, so the next drag still believed
a layer was selected, tried to draw a mask on one that no longer existed, and did
nothing whatsoever. The tool had stopped working and there was nothing on screen
to say why.

The rule now is that the selection cannot name a layer the composition does not
have. It is answered in one place, from the list of layers itself, rather than at
each of the several points where a layer can disappear — undo is only the easiest
way to reach that state; deleting a layer gets there too.

### Showing a value you are dragging, without writing it (K-239)

Two things are wanted from a dragged value and they pull against each other.
Undo should treat the whole drag as **one** action — not one step per hair of
pointer movement — and the picture should move **while** you drag, or you are
guessing.

Committing on every tick gives you the second and ruins the first: `Ctrl+Z` then
walks back one percent at a time, which reads as undo being broken. Committing
only on release gives you the first and ruins the second: the picture sits still
until you let go. Lumit had just traded one for the other on a paint stroke's
opacity, which is how this got noticed.

The answer is that the two are different jobs. Every tick asks for a **preview**:
the frame is drawn from a *copy* of the project with that one value replaced, so
nothing is written, no undo step exists, and those pixels are never cached —
they are of a value the document never held. The release writes once, for real.

That path already existed for effect parameters, for a dragged transform and for
what is being typed. Paint strokes and shape layers' art now use it too. Anything
that can be dragged but must not be committed per tick needs the same thing, so
expect the list to grow; what matters is that there is one path rather than one
per feature.

One small thing falls out of it. If a drag is cancelled — the gesture is
interrupted, or you release without ever moving — the screen is showing a value
nobody committed, so the row asks for the document's own value back rather than
waiting for something else to redraw it.

All three of the Timeline's whole-list rows work this way now: a mask's opacity,
a paint stroke's and a shape item's (K-240). They are the same row with a
different noun, and the third one joining without anything new having to be
designed for it is the sign the shape was right.

### One gesture, one undo step (K-230)

The document is a stack of small, exactly reversible **ops**, and `Ctrl+Z` undoes
one. That design carries one obligation: **an op has to be what a person would
call an action.** Position is two numbers in the model — which is what lets them
animate apart — so writing them as two ops made one drag two undo steps, and the
first undo moved the layer back along one axis only.

`Op::Batch` carries several edits and undoes them together, and it is the answer
everywhere: a drag writes both axes at once, a scale writes both axes at once,
and making a text layer is one op rather than three, so it arrives already saying
what it should, where it should be. The first undo takes back the words and the
next removes the layer, which is the whole of what a person means.

### Asking the engine nothing in a rebuild path (K-230, K-231)

**If a rebuild can be caused by moving the mouse, nothing in it may cross the
bridge.** The Hand tool and the camera tools redraw on every pointer movement —
they have to, something is following your mouse — so anything their build method
asks is asked at the rate a mouse reports, a hundred times a second or more.
Answers that cannot change without an edit landing are worked out once and held.

There is a subtler layer. The held copy of the document — the read model — used
to *check* with the engine that the document had not moved before answering. That
grouped to once per frame while a frame was being built, but outside a frame it
checked every single time, and "outside a frame" is exactly where mouse handlers
run. Drawing does not need the check at all: when the document changes, the model
is refreshed and everything drawing from it repaints anyway. The catch is that
the check was quietly covering for something else — a panel that commits its own
edit and then draws saw its own edit only because the check happened to notice.
**Every panel that commits refreshes the model itself: tell the model, do not
make drawing ask.**

The standing bridge-call budget tests are what hold this line.

### Who gets the Delete key (K-234)

Flutter calls **every** registered key handler, in registration order, and does
not stop at the first that says it dealt with the key. So a panel cannot claim a
key simply by handling it. That is harmless while handlers disagree about which
keys they care about, and a bug the moment two want the same one: `Delete` in the
shell means "remove the selected layers", `Delete` in the Timeline with a mask
row picked means "remove that mask", and both fired — the mask went, and so did
the layer it was drawn on.

`LumitUiState` holds one nullable `deleteClaim`. The Timeline points it at its
own handler while it is on screen, and the shell's `Delete` calls it first: `true`
means it was dealt with and the shell stands down. **When two parts of the
application want the same key, do not race them — have the broader one ask the
narrower one first.** A selection inside a layer is narrower than the layer.

### A performance test that cannot see the bug (K-233)

A budget test hovered the mouse over the Viewer with a camera tool in hand and
asserted that no calls crossed to the engine. It passed. The application was
making a call on every frame.

`await tester.pump()` draws a frame but does **not** move the clock, so every
frame in the test carries the same timestamp. The read model groups its work once
per frame by comparing that timestamp, so the whole twenty-move gesture looked
like one frame and the work happened once. In a running application every frame
has a new timestamp.

The fix is one argument — `tester.pump(const Duration(milliseconds: 16))` — and
the lesson is bigger: **a performance test that cannot reproduce the conditions
it is guarding does not merely fail to catch the bug, it certifies that the bug
is not there.** When a budget reads zero, check that it can read non-zero: break
the thing on purpose and watch the number move.

### Precompose, and why the new comp is the same length as the old one

**Precompose (`Ctrl+Shift+C`) takes some layers out of a composition, puts them
in a composition of their own, and drops that composition back in their place.**
It is how a shot with forty layers becomes a shot with four, and it is how you
give a group of layers one blur, one fade, one anything — the effect goes on the
layer that stands for the group.

The whole move happens in the engine, as one batch, so one press of undo puts the
layers back exactly where they were. That matters more than it sounds: the move
is really four edits (make a comp, file it in the Compositions folder, take the
layers out, put a new layer in), and an undo that only reversed the last of them
would leave the project in a state the user never asked for.

**The new composition is as long as the one it came out of, and every packed
layer keeps the exact in point, out point and start offset it already had.** That
is the whole trick to precompose not disturbing anything: because the inner comp
runs on the same clock as the outer one, and the layer standing for it spans the
whole thing, the picture at any frame is the picture that was there before the
key was pressed. It is tempting to trim the new comp to the span the selected
layers actually occupy — it looks tidier — but that moves every packed layer to a
different moment inside its new home, and then the two have to be shifted back
against each other to look the same. After Effects does not do it either.

A packed layer might be parented to a layer that stayed behind. Nothing is done
about that on purpose: the engine already reads a parent it cannot find in the
comp as no parent at all, so the link simply stops mattering, which is the same
thing clearing it would achieve with more code.

### Reveal keys, and the difference between a label and a name

**`P`, `S`, `R`, `T` and `A` open one property of the selected layers and nothing
else** — Position, Scale, Rotation, Opacity, Anchor point, the shortcuts every
After Effects user has in their fingers. `E` and `M` do the same for Effects and
Masks, `Shift+L` for the sound. Pressing the key again shuts the layer.

The Timeline remembers which fold-outs are open as a set of **paths** — strings
like `<layer>/transform/positionX` — and the reveal keys work by putting exactly
one of those in the set. The path is built from the *engine's* name for the
property (`positionX`), never from the words on screen ("Position"). This is a
small thing that would have been an annoying bug: labels are user-facing text and
get reworded, and a reveal key keyed to the wording would have quietly stopped
working the day someone renamed a row, with nothing failing to say so.

One row and nothing else also means the Retime row above Transform steps aside
while a reveal is in force. "Show me Scale" that showed Scale *and* Retime would
be answering a question nobody asked.

### Windows you can move, and how one remembers where it was (K-242)

The Settings window, Export, Composition settings and the rest all float over the
shell, and they all come from a **single function** — `showLumitModal` in
`flutter_ui/lib/widgets/controls.dart`. Each one only says what goes *inside* the
window; the frame around it, the dimmed backdrop behind it, and now the moving and
resizing, are that one function's job. That is why "make the windows movable" was a
change in one file rather than in eleven: the funnel already existed.

**Moving.** The window sits in the centre of the screen and carries an *offset*
from there — "40 pixels right, 20 up" — rather than an absolute position. Dragging
adds to the offset. Storing it that way means the window needs to know nothing
about how big it is in order to open in the middle, and a position saved on your
1440p monitor still opens on screen if the app is later run on a laptop. The offset
is clamped so the *middle* of the window can never leave the app window: however far
you fling it, there is always something left to grab.

There is no title bar to drag by. Instead the whole window is draggable, and
Flutter's **gesture arena** sorts out the conflict: when a pointer press could
belong to several things, they compete, and the more specific one wins. Press on a
slider and the slider wins, so it slides; press on a scrolling list and the list
wins, so it scrolls; press on empty chrome and nothing else wants it, so the window
moves. This is also why the resize grip in the corner is built as a *sibling* of the
window rather than as something inside it — two drag handlers nested one inside the
other both join the arena for the same press and, in this case, neither ended up
moving anything at all. As siblings the topmost one simply takes the corner.

**One trap worth knowing**, because it is the kind of thing that looks like it works
until it does not: several pointer movements can arrive between two drawn frames. A
handler that adds the movement to *the value it was drawn with* would use the same
stale starting point for all of them, and the window would travel a fraction of the
distance you dragged. Each movement has to be added to the live value instead. The
regression test drags by a known amount and insists the window moved by exactly
that, which is what caught it.

**Remembering.** Each window has an id — `settings`, `export`, `comp-settings` — and
where it was left is written into the workspace store, the same machine-local JSON
file that holds the panel layout and the theme. It is written when a drag ends, not
while it is happening, so a move costs one small file write rather than one per
frame. Nothing about this is in the project file: where you like your Settings
window is about your machine, not about the film.

Only the Settings window can be *resized* so far. It asked for it — it was fixed at
a size chosen for a small laptop — and it is the one window with enough inside it
for the extra room to matter.
