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

That rule is also why `lumit-render` exists. The picture-making code used to live inside
`lumit-ui`, which meant the Flutter frontend had to reach *through* the egui frontend to
render anything at all — a dashboard wired into another dashboard. Pulling it into its own
crate (decision K-178) put it back where it belongs: both frontends now ask the same engine
for frames, so a comp cannot look different in one than the other.

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
- **Why that drop once died silently (the one-slot drag rule).** egui carries exactly
  one "thing being dragged" for the whole app, like a single hand that can hold one
  object. The catch: when any drop zone asks "was that released on me?", egui hands
  the object over *before* checking whether it is the kind that zone wanted — and if
  it is the wrong kind, the object is simply gone. The Timeline's whole-body zone
  (the one that accepts footage dropped from the Project panel) sits underneath every
  layer row, so it asked first, was handed the dragged *effect*, shrugged, and
  discarded it — the row you actually dropped on found the hand empty. The fix is a
  small shared reader (`dnd_release_of` in `panels.rs`) that peeks at the kind first
  and only takes a drop that matches; every drop zone in the app now reads through
  it, so a footage drag and an effect drag can never eat each other again.
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
- **Colour picker and eyedropper.** Every effect **Colour** parameter — a Flash tint, a Colour
  balance wheel, the Matte key's Key colour, and so on — now shows a **clickable swatch**. Click
  it and Lumit's colour wheel and sliders open, so you can pick a colour by eye instead of typing
  three numbers. Beside the swatch sits a small **eyedropper**: click it and the tool arms, then
  move the pointer over the Viewer and a **magnifier** follows the cursor. The magnifier shows a
  zoomed 9×9 grid of the pixels under the pointer, dotted lines between them and the centre pixel
  ringed; click to lift that colour into the parameter, or press **Escape** (or click off the
  Viewer) to cancel. **Shift+scroll** while it is up grows the sampled patch — 1×1, 2×2, 3×3, … —
  so you can average over a grainy area instead of grabbing one noisy pixel; the current size
  shows under the grid, and the committed colour is the average over that patch. Depth of field's
  **Focus** carries the same eyedropper, except it lifts *depth* rather than colour: click the
  part of the picture you want sharp and Focus jumps to it. The pixels are read straight from the
  frame shown in the Viewer — the very frame the Scopes read — and a picked colour is converted
  back into Lumit's internal light space so it matches what you sampled. Two honest notes: the
  wheel edits ordinary 0–1 colours, so a rare "brighter than white" tint is clamped by the picker
  (the number boxes still reach it); and the Focus pick uses the brightness of the clicked pixel
  as a stand-in for depth, since the depth layer's own picture is not separately available to the
  panel.
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
  drag it earlier and it plays faster. That is deliberately *all* it does for now: no speed
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
  As of the disk tier (`disk.rs`), frames also get **parked on disk**: once a project is
  saved, a `yourproject.lum-cache` folder appears beside it and rendered frames are quietly
  written there (compressed) by a background thread — so closing and reopening a project
  doesn't start the cache from zero, and frames squeezed out of RAM can come back without
  re-rendering. Each frame is one small file named by its content fingerprint; anything
  unreadable is silently deleted and re-rendered, so the folder is **always safe to delete**
  — it can make things faster, never wrong. The idle background fill now checks the disk
  before rendering: promoting a parked frame beats recomputing it. The timeline's cache bar
  grew a second colour for this: **mint** = in memory, plays right now; **blue** = parked on
  disk, ready to promote.
  The third tier is **VRAM**: the last few hundred megabytes of frames you actually looked
  at stay resident on the graphics card, so scrubbing back over them re-shows the exact
  texture with zero work — no upload, no colour maths. All three tiers answer to the same
  content fingerprint, so a frame is a frame wherever it lives.
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
  (a key's value and easing are shaped in the graph editor). Select several at once and they
  slide together as one undo step: **Shift-click** adds a key to the selection, **Ctrl-click**
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
  earlier or later in time (one undo per drag); drag its ends to trim. A layer twirled
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
  an egui quirk worth knowing if you touch this code: a region that senses dragging does not
  automatically step aside for an ordinary button drawn on top of it the way a plain click
  does — dragging is tracked per-widget from the moment the mouse is pressed, not by "whoever
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

FFmpeg comes from Homebrew: `brew install ffmpeg@7`. The repo's `.cargo/config.toml` already
points the build at it, and macOS ships the translator (libclang) as part of its developer
tools, so there's nothing else to set up — `cargo test --workspace` just works.

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

Two settings then have to be handed to the build, in the terminal you build from:

```sh
export LIBCLANG_PATH=/usr/lib/llvm18/lib          # Debian/Ubuntu: /usr/lib/llvm-18/lib
export FFMPEG_PKG_CONFIG_PATH=/usr/lib/pkgconfig  # wherever libavcodec.pc lives
```

The first says "use the *18* translator, not whichever one is the default" — only needed
where the default is newer than 18, which on Arch and Artix it always is. The second is an
accident of the repo: `.cargo/config.toml` sets that variable to a macOS Homebrew folder
for every platform, and Cargo gives no way to make it macOS-only, so on Linux it has to be
overridden with the folder that actually holds FFmpeg's `.pc` description files (ask with
`pkg-config --variable pc_path pkg-config` if `/usr/lib/pkgconfig` is not it). Put both
lines in your shell profile and every future terminal has them. Then `cargo test
--workspace`, and `flutter run` from `flutter_ui/` to launch the app.

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
shelf under a label that says *which* comp, *which* frame, at *what* preview
size, and *which version of the document* it belongs to — so scrubbing back and
forth is a shelf lookup with no drawing at all. The "which version" part matters:
the moment you edit anything, the document becomes a new version and every frame
on the shelf is thrown away, because they now show the old picture — you can
never be handed a stale frame. There is a size limit (a few hundred megabytes by
default, adjustable in Settings → Performance); when the shelf is full the
least-recently-seen frames are dropped to make room, and "Clear cache" empties it
on demand. A companion tidy-up: when you scrub quickly, a frame you have already
moved past no longer wastes a full draw finishing after you have gone — a newer
request tells the engine "that one is stale, skip it" before it starts.

**Seeing what is on the shelf (the cache bar).** A thin green strip now runs
along the bottom of the timeline ruler, over the frames whose picture is already
on that shelf — so at a glance you can see how much of the comp is ready to play
back instantly, exactly as the old egui app shows it. The engine only tells the
bridge *how many* frames are cached, not *which* ones, so the Flutter side keeps
its own note of the frames it has driven onto the shelf and draws a band over
each; editing anything (which throws the shelf away) or clearing the cache wipes
the strip too. The strip is scoped to the current preview size — which matters,
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
almost always what is missing. A second tool, **cargokit**, sits under
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

**Running it.** Install the Flutter SDK (`git clone -b stable
https://github.com/flutter/flutter`, put its `bin` on PATH — it fetches its own
Dart on first run; the Windows build also wants the same VS 2022 C++ tools the
Rust build uses). Then, from `flutter_ui/`: `flutter run -d windows` to launch,
`flutter test` for the tests, `flutter analyze` for the lint pass. The bridge
library builds separately with `cargo build -p lumit_bridge`, which drops
`lumit_bridge.dll` in `target/debug/` where the Flutter app looks for it.

**Running it on Linux (for the Linux collaborator).** The Flutter frontend now
builds and runs on Linux, not only Windows. You need three things installed
once: the FFmpeg 7.1 "shared" build the engine links (see §8's Linux notes — the
BtbN `n7.1 ... linux64-gpl-shared` tarball, with `FFMPEG_PKG_CONFIG_PATH`,
`LD_LIBRARY_PATH` and `LIBCLANG_PATH` pointed at it and LLVM 18); the Flutter
desktop toolchain (`sudo apt-get install clang cmake ninja-build pkg-config
libgtk-3-dev`); and the same X11/Wayland/ALSA/GL dev libraries the engine's own
Linux build wants (the `libasound2-dev libgl-dev libegl-dev libxkbcommon-dev …`
list in §8). Then, from `flutter_ui/`: build the engine bridge with `cargo build
-p lumit_bridge` — on Linux this produces `liblumit_bridge.so` in `target/debug/`
(the loader looks there, then `target/release/`, then beside the executable, then
the system library path; the `lib` prefix and `.so` suffix are Cargo's Unix name
for the same crate that becomes `lumit_bridge.dll` on Windows). Run the app with
`flutter run -d linux`, the tests with `flutter test`, the lint pass with
`flutter analyze`. If a run or test complains it cannot fetch packages offline,
add `--no-pub` after a successful `flutter pub get` to reuse the resolved
packages. Two things behave differently on Linux by design, both degrading
cleanly rather than failing: the Viewer's zero-copy Viewer path uses **DMA-BUF**
rather than the Windows DXGI shared handle (built behind
`--features shared-texture-linux`, K-177 — see the DMA-BUF sections in §9 above);
there is **no CPU fallback behind it**, because K-183 deleted the copy-the-bytes
path outright — so on a machine whose driver cannot export the shared image (a
software rasteriser such as Mesa's lavapipe, which is what CI has), every frame
is dropped at the publish step and the Viewer simply stays empty. It says so on
stderr and nothing crashes, but it does not draw. That is why the six Flutter
tests that wait for a frame skip on CI (`LUMIT_NO_ZERO_COPY_VIEWER=1`, in
docs/TODO.md); and **popping a panel out into its own OS window works** —
the `desktop_multi_window` plugin ships a first-class Linux (GTK) implementation,
so pop-out is *not* gated off Linux. Because this box cannot build
Flutter-for-Linux, the Linux build is proven by the CI `flutter-linux` job, not
locally — treat a green run of that job as the gate.

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

**Running it on macOS.** The Flutter frontend now has a `macos/` platform
folder too, scaffolded with `flutter create --platforms=macos .` (K-033 names
Metal/macOS a supported future target; this is the first concrete step
towards it, not the full pass — see below for what is still deferred). You
need Xcode installed (the full app, not just the Command Line Tools — `flutter
doctor` will say so plainly if only the tools are present) and CocoaPods
(`brew install cocoapods`). Build the bridge library the same way as the other
two platforms: `cargo build -p lumit_bridge`, which drops
`liblumit_bridge.dylib` in `target/debug/` (Cargo's Unix cdylib naming, same as
Linux's `.so` but with the macOS suffix). Then, from `flutter_ui/`: `flutter
run -d macos` to launch, `flutter test` for the tests, `flutter analyze` for
the lint pass. The generated Xcode project's App Sandbox is switched off and
library validation disabled in both entitlements files — a sandboxed,
hardened-runtime process cannot `dlopen` an unsigned, locally-built dylib from
an arbitrary Cargo target path, which is exactly what the bridge loader does
(matching the unsigned, unsandboxed posture Windows and Linux dev builds
already have; a signed macOS release is a later decision). The Viewer's zero-copy
path now exists here too (`shared-texture-macos`, Metal/IOSurface, K-195), so the
picture appears; it is default-on and needs no flag. The native macOS menu bar
(muda) stays deferred with
the rest of the "macOS pass" named in `docs/archive/flutter-port/01-STRATEGY.md` — the
in-window menu bar renders instead, same as it does today.

**What the bridge carries now (v0.2).** The first bridge only described the
project as a tree of item names. It now also carries the *inside* of things, so
the Viewer, Timeline and property editors have something to draw. Ask for the
document and each composition comes back with its size, frame rate, total frame
count, its stack of layers (each with a name, a kind, the frames it starts and
ends on, and its row of switches — visible, locked, solo and the rest), and any
markers on its timeline. Each piece of footage comes back with its resolution,
rate and length once Lumit has *probed* the file (read its vital statistics),
plus a plain status word — `ok`, `missing` (the file has moved), or `unprobed`
(not looked at yet). The frontend can also make small edits — flip a switch,
nudge a layer's start or end to the playhead, set a transform value, drop a
marker — and each goes through the same undo machinery the egui app uses, so one
press of undo takes it back. All of that is still ordinary text (JSON) crossing
the bridge. The one exception is the actual picture: a single video frame is far
too big to send as text, so when the Viewer asks to decode a frame the engine
hands back a raw block of pixels instead. Dart *copies those pixels out
immediately and then hands the block straight back to the engine to free* — the
same "borrow it, copy it, give it back" manners the text replies already use, so
neither side is left holding memory the other owns. Reading video needs FFmpeg,
which is bundled behind an on-by-default switch (the `media` feature); turn it
off and the app still builds and runs, footage just reads as "unprobed" and no
frames decode.

**What the bridge carries now (v0.3).** v0.2 could *set* a layer's position or
opacity but never *read* it back, so the property editors could only show what
you had changed this session. v0.3 fills that gap and adds the rest of the verbs
a real editor needs. Now every layer also reports its whole transform — for each
property, its current value, whether it is animated, and (when animated) its
keyframes with their frames and easing — plus what it points at (the footage or
comp it shows, or a solid's colour) and its stack of effects. Each composition
reports its work area (the in/out span the transport loops). And the frontend
can now *do* far more, every action going through the same undo machinery the
egui app uses: add a layer of any kind (solid, text, camera, adjustment,
sequence), delete or duplicate one, change a composition's settings in one
undoable step, click the *stopwatch* to start or stop animating a property, add
or remove or slide keyframes, move the work-area edges, and apply, remove or
tune effects. The rule stays the same as before: every one of these mirrors
exactly what the egui frontend does under the hood (the same defaults, the same
op), so the two front doors can never drift apart, and every reply is still the
whole document as text (JSON) so the panels just re-read it.

**Placing footage and restacking layers.** You can now build a composition from
the Flutter side: double-click a footage clip in the Project panel (or drag it
onto the timeline) and it becomes a new layer at the top of the stack — sized and
centred exactly as the egui app would place it — and you can drag a layer row's
name up or down to restack it, just like moving a track in any editor.

**The Viewer showing real frames, and the scopes reading them (F2).** The Viewer
now shows actual pictures. It works out which footage the playhead is sitting
over — the topmost visible footage layer whose span covers the current frame —
asks the engine to decode that one frame to raw pixels, turns those pixels into
an image Flutter can draw, and fits it onto the neutral grey pasteboard. A small
shared helper (the *preview source*) does this work once and keeps the last
eight decoded frames in memory, so scrubbing back and forth is cheap and it
never decodes more than one frame per drawn frame. An important honesty: this is
a **single-layer** preview. The real *compositor* — the part that stacks every
layer, applies each one's position and effects, and blends them into the
finished picture — still lives only in the Rust egui application; it has not been
lifted out into a shared piece yet. So Flutter can show one footage frame
straight, but not the composited comp; that (and the faster shared-GPU-texture
path) waits on the compositor being extracted. When footage is *missing* the
Viewer draws the same broadcast colour bars a comp shows — unmistakably "no
signal here" rather than a black frame that hides the mistake — with the file's
name written across the bottom; an unreadable file shows a dark "unreadable"
card instead. Pressing play advances the playhead in time with the comp's frame
rate and loops back to the start at the end, mirroring the egui transport. The
**Scopes** panel — the colourist's instruments that plot brightness and colour
instead of the picture (a waveform, an RGB waveform, a vectorscope and a
histogram) — reads the very same decoded pixels from the shared preview source,
so the trace always matches what is on screen. Each scope is drawn on a fixed
near-black background rather than the interface theme, because a scope must be
read against the same neutral whatever colours the chrome wears, and it holds the
last trace for a beat rather than blinking to blank when a frame is momentarily
unavailable.

**The Viewer showing the REAL composited comp (K-175).** The single-layer
preview above was the honest stop-gap; the Viewer now shows the *whole* comp —
every layer stacked, each one's position and effects applied, blended into the
finished picture — the same pixels the egui Viewer shows and the same pixels an
export writes to a file. Here is the trick that made it possible without a big
rebuild. The compositor lives in the Rust egui crate, but the part that draws a
comp to an offscreen picture (the one the *exporter* already uses) never needed
a window or the egui interface — it only needs a graphics device, the video
decoders and the document. So that path is wrapped in a small reusable object, a
**headless renderer**: "headless" just means "no window". It holds the graphics
device (which is slow to set up, so it is created once and kept), the compiled
drawing programs and the open video decoders, and each time the Viewer asks for
a frame it composites the comp and hands back the finished pixels. Because it is
the very same code the exporter runs, the Viewer, the egui preview and the
exported file cannot disagree about what the comp looks like (K-031). The bridge
holds one of these renderers for the session and offers a new call,
`lumit_bridge_render_comp_frame`, that takes a comp and a frame and returns the
composited pixels with the same borrow-copy-return manners as the single-frame
decode. On the Dart side the Viewer prefers this whole-comp call whenever the
engine offers it, and quietly falls back to the old single-layer decode when a
render can't be produced — for instance on a machine with no suitable graphics
card, where the renderer reports itself unavailable once and the Viewer simply
stays on the single-layer path (never a crash). A missing layer inside the comp
comes back already painted as colour bars *inside* the finished frame, so the
Viewer needs no separate "missing" card on this path. (Both honesties this
paragraph used to end on — the bridge depending on the egui crate, and a smaller
scale shrinking the returned picture without reducing the work — are dealt with
in "The picture-making crate" below.)

**The picture-making crate, and why dragging a value used to stutter (K-178).**
The paragraph above ended on a wrinkle: to draw anything, the Flutter frontend
had to reach *through* the egui frontend, because that is where the picture-making
code lived. That has now been pulled out into a crate of its own, `lumit-render`,
which both frontends use. The engine no longer contains a dashboard.

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

**What the bridge carries now (v0.4): export, Retime and the last columns.** The
biggest addition is **export** — writing the finished comp to an `.mp4`. Rather
than teach the bridge to encode video from scratch, it borrows the egui
application's exporter through the same headless seam the Viewer uses (K-175):
the seam gathers the footage and audio the export needs and lends a graphics
device, and the exporter does the rest on its **own thread**, exactly as the
egui app does, so the interface never freezes while a file is written. The
conversation is a simple loop: Dart calls "start" with the composition, an
output path, and a small description of the settings; then it calls "poll" on a
timer to learn how far along the encode is (which frame of how many, which
encoder the machine settled on) until the reply says *done* (with the file's
path) or *failed* (with a calm reason); a "cancel" call stops it cleanly. Only
one export runs at a time — asking to start a second while one is running
answers "an export is already running", and the interface queues it. Two pieces
of the export dialogue are worked out on the Rust side so the two frontends
cannot disagree: **stamping a preset** (choosing "YouTube 1080p60" fills in the
codec, size and bitrate, keeping the preset's own peak bitrate while its numbers
stand unedited and falling back to a 1.5× peak once you change them) and
**naming the file** (a template with `{comp}`, `{preset}` and `{date}` slots,
cleaned of characters Windows forbids, always ending in `.mp4` — and a blank
template reproduces each preset's own suggested name exactly). Alongside export,
v0.4 finishes the read-back and the editing verbs a real timeline needs. A
keyframe now reports its **Bezier** handle on each side (the tangent's slope and
reach) and the frontend can set a keyframe's interpolation (hold, linear or
bezier). A footage layer now reports its **Retime** — the map from the clip's
own clock to which moment of the source is on screen, told as a chain of
segments (a constant-or-eased *speed* run, or a value curve) meeting at
boundaries — and the frontend can set a constant speed, change a segment's ease
preset, convert a curved segment to a plain speed one (the reply tells you how
much the fit drifted), and drag a boundary. (The word is *Retime* and the
quantity is *speed*, never "time remap" or "velocity" — the house glossary.)
Finally the last timeline **columns** are wired: a layer's blend mode (with the
full list to choose from), its matte (borrowing another layer's alpha or
brightness to cut it out), its parent (so moving one layer moves another), the
composition's motion-blur shutter, and dropping a starter mask shape (rectangle,
ellipse or star) onto a layer. As always, each of these mirrors exactly what the
egui frontend commits, one undoable step, and the reply is the whole document as
text so the panels just re-read it. Nothing engine-side is needed to remember
which comps are open or where the playhead sits — that is the frontend's own
state — so restoring a session stays a Dart concern.

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

**Filling in the edit commands (bridge v0.7).** By this point the bridge could
show the whole document and do the common edits, but a scatter of menu items and
editors still had nowhere to send their instruction — the engine simply had no
"command" for them yet. This round adds the missing ones, each a thin, tested
Rust function that routes through the engine's own undo-able operation (so the
Flutter app and the old egui app can never disagree, and one press is one undo):
the *razor* that cuts or deletes a clip under the playhead on a sequence layer;
*beat detection* (listen to the composition's audio, drop a marker on every
beat) and clearing those markers; the project-panel actions (delete, rename, drag
back to the top level, and *relink* a moved-away video file to its new place on
disk, siblings in the same folder coming along); the layer commands (rename,
convert a footage layer into an editable sequence, trim a slowed-down clip to
where its source runs out); the two remaining speed switches (play a clip in
reverse; choose how in-between frames are made — nearest, blend or optical flow);
editing what a text layer *says* and a solid's colour and size and a camera's
zoom; the four remaining effect-knob kinds (dropdowns, checkboxes, random seeds
and point pickers) plus reordering effects and moving a linked x/y keyframe pair
as one undo step; and three housekeeping calls — a proper *autosave* that writes
a spare copy beside your project **without** quietly making that copy the file
you are editing (the old shortcut had that bug), a list of those spare copies and
a "replay the crash journal" recovery, and an honest *boot log* the splash screen
can show (the library's version and which features it was built with — no made-up
lines). On the Dart side these all live on a new optional capability the real
library offers (`EditOpsBridge`), kept separate so the test stand-ins need no
changes; the interface calls them through plain pass-throughs that show any calm
error in the status line. Two honest caveats are written down rather than
hidden: beat detection runs in one go here (the old app did it on a background
thread — fine for short clips, a later change if long songs feel slow), and the
crash-journal recovery can replay a journal a previous session left but the
Flutter side does not yet *write* one on every edit (a named follow-up).

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

**The "engine-surface close" wave (bridge v0.9), in plain terms.** A run of
small gaps all came down to the same thing: the engine *knew* something the
Flutter side could not yet *see* or *ask for*. This wave closed those.

- The picture-description the Flutter side reads (the "snapshot") learned to
  carry a few more facts it had been leaving out: the clips laid along a
  sequence row; where each layer's own clock sits on the timeline (so the
  Timeline can draw the little "held frame" hatch when a slowed clip runs out of
  footage); which markers are the music beats the app found versus ones you
  dropped by hand; the words, size and colour of a text layer, a solid's size,
  a camera's zoom; and, for each effect, exactly which effect it is and whether
  each of its dials is animated. All of this was *already* in the engine — the
  snapshot just wasn't repeating it — so adding it is safe and an older reader
  simply ignores the new fields.
- Drawing a mask by dragging a box in the Viewer now sends the box's real size
  and position to the engine, instead of dropping a fixed starter shape in the
  middle and ignoring where you drew.
- Effect dials got a stopwatch and keyframe navigator, just like the transform
  rows already had — turn animation on, drop a key at the playhead, nudge or
  remove one — by reusing the very same machinery the transform keyframes use.
- "Save these effects as a preset" and "load a preset onto this layer" now work:
  the engine hands the Flutter side a small text file (a `.lumfx`) that is
  byte-for-byte the same as the one the egui app writes, so presets pass between
  the two apps; the Flutter side only has to pop up the file picker.
- A **crash journal** is now written on every edit. The journal is a running
  list of the edits you have made since the last save, kept in a little file
  beside the app's cache; if the app ever stops unexpectedly, reopening the
  project replays that list so your unsaved work comes back. The egui app has
  always done this; now the Flutter bridge does too.
- The **realtime tier** got wired up. During playback, if the machine can't
  keep up at full resolution, a small controller (built and tested long ago but
  never plugged in) drops the preview to half, a third, or a quarter resolution
  and earns it back when things calm down — quick to worsen, slow to improve, so
  the picture doesn't flicker between qualities. The Viewer can now ask the
  bridge "what resolution are we at?" to show a readout, and in *Auto* mode it
  renders the next frame at whatever the controller chose. Picking a fixed
  resolution by hand simply overrides it.

**The "final UI wave", in plain terms.** The wave above taught the engine to
*tell* the Flutter side more; this one is the Flutter side actually *drawing and
using* those new facts, so the windows now look and behave like the older egui
app in these places:

- **Beat markers look different from your own markers.** The music beats the app
  detects show up as faint ticks that fade with how sure the app is about each
  one, sitting low on the ruler; the markers you drop by hand stay full-height
  and solid. (Before, everything looked the same.)
- **A sequence row shows its cut lines.** When one timeline row holds several
  clips end-to-end, thin dividers now mark where one clip stops and the next
  begins — the same lines the razor tool cuts on.
- **The "held frame" hatch.** If you slow a clip down so much that it runs out of
  its own footage before the row ends, the leftover stretch is washed and
  striped in a calm amber with a small "HOLD" tag — a quiet warning that the clip
  is repeating its last frame there, never a red alarm. Working out *where* that
  stretch begins meant copying a piece of the engine's time-mapping maths into
  the Flutter side (in `graph_maths.dart`), which is covered by its own tests.
- **The Text, Solid and Camera editors now read the truth.** They fill their
  boxes from what the engine actually holds (a text layer's words/size/colour, a
  solid's dimensions, a camera's zoom) instead of only remembering what you typed
  this session.
- **The `.lumfx` preset buttons.** "Save preset" and "Load preset" now sit under
  the effects list and open a normal file picker; the effect dials' stopwatches
  (from the wave above) also make animating effects match animating a transform.
- **"Auto" is now in the resolution menu.** Alongside Full/Half/Third/Quarter you
  can pick Auto; a small readout beside the menu shows which resolution the
  realtime controller has settled on while you play.

One big piece is deliberately *not* in this wave: the **value graph editor** —
the curve-with-handles view for animating an ordinary property, and the
source-position ("Time") lens for retimed clips. The Flutter graph editor draws
the *speed* curve for retimed clips today; the value curve is a large, separate
build, and drawing it at low fidelity (straight lines where real curves belong)
would look wrong, so it is left as an honest, named remainder rather than
half-built (see `docs/archive/flutter-port/06-REMAINING-WORK.md` §C).

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

### Making your own theme, and the Timeline's two grounds (K-202)

**Themes you can edit.** Settings → Appearance has a **Customise…** button under
the colour scheme. It opens a window listing every colour the interface uses —
what it is called, a line saying where it shows up, and a swatch you click to
pick a new one. It opens on the colours you are *currently* using, and every
change shows in the app straight away, because a colour you cannot see against
everything else is a colour you cannot judge.

**Save** asks for a name the first time and makes it a theme of your own, which
then appears in the scheme list. Select it later, press Customise… again, and
Save updates that theme rather than making another. Closing with unsaved
changes asks whether to keep them; discarding puts back exactly what was there.

What gets saved is deliberately *not* a copy of the whole theme — it is a name,
whether it is a light or a dark theme, and the colours you set. That matters
because Lumit gains colours over time: a theme you saved last year still opens,
and anything new simply comes from the light or dark base underneath. The
colours are written into your settings file as ordinary `#rrggbb` text, so you
can read them, paste one in by hand, or send a theme to somebody.

One colour is not offered: the **Viewer's surround**, the neutral grey around
the picture. It stays a fixed neutral on purpose — you cannot judge a colour
grade against a tinted background, so this is the one place the interface's
taste has to give way to being able to see straight.

**The scheme list is grouped** into Dark, Light and Custom, because light or
dark is the first thing anyone picks by.

**Scopes.** A waveform or vectorscope is a *measuring instrument*: it is read on
a near-black background with a bright trace, whatever colour the rest of the app
is. That is what the design docs have always said, and the panel now does it.
If you like the look of scopes matching your theme — and it does look good —
there is a switch for it in Settings → Appearance, off by default.

**Why the Timeline has two background shades now.** The lane and layer areas
used to be one flat colour end to end. Two things suffered: a selected row had
almost nothing to stand out against, and the **work area** — the span you are
actually going to export — was invisible unless you looked at the thin band on
the ruler. So the part inside the work area keeps the normal panel colour and
everything outside it is washed slightly darker, which tells you at a glance
what you are delivering. On a light theme the wash is a bigger step, because the
same small difference reads as less on a bright background.

Selected rows got their own colour at the same time, rather than borrowing one
from the general set of greys. It brightens on a dark theme and *darkens* on a
light one — a selection has to stand out from whichever background it lands on,
and that is not something a simple light-to-dark ramp can express. Both of these
are ordinary colours in the customise window, so you can set them yourself.

And the work area's two edges can now be **dragged on the ruler**. Until now you
could only set them from the Timeline menu, which was precise but roundabout —
a span you can see is one you expect to be able to grab.

### The keyboard, and why the engine owns it (K-199)

**The problem it solves.** Every editor lets you change its shortcuts, because
everybody arrives with different muscle memory — and because sometimes the
operating system steals a key from under you (that really happened to us: on
Windows, left Alt with Shift is how the system switches keyboard layouts, so
the chord Retime briefly shipped on never reached Lumit at all — K-198 tells
that story, and K-200 finished it by moving Retime to Ctrl+Alt+T outright). So
Lumit has a **keymap**: a list saying "this key combination, in this place,
runs this command", and a page in Settings where you can change any of it.

**Three words.** A **chord** is a key with its modifiers — `Space`, `Ctrl+D`,
`Shift+F3`. A **context** is *where you are*: the whole app, or one focused
panel. An **action** is a command, named by a short stable string like
`playback.toggle`. A **binding** ties a chord in a context to an action. When
you press keys, something has to answer "what does that mean, here?" — and
that something is the engine.

**Why the engine and not the frontend.** This is the same rule as everywhere
else in the port: the frontend shows and forwards, the engine decides. Working
out that the Timeline's own `D` beats the app-wide `D` while the Timeline is
focused, or that two bindings now clash, or that this JSON is a keymap and that
one is not — those are *rules*, and rules that live in the frontend are rules
nobody can test without a window. `crates/lumit-keymap` is the rulebook (about
600 lines, thirteen tests, no windowing code at all) and
`crates/lumit-bridge/src/api/keymap.rs` is the window onto it.

The frontend keeps exactly two jobs, and both are genuinely its own:

1. **Spelling the keypress.** Flutter tells it a key was pressed; it writes that
   down as text the engine can read — `Mod+Alt+Shift+T`, where `Mod` means Cmd
   on a Mac and Ctrl everywhere else. That translation is why a keymap written
   on a Mac still reads on Windows.
2. **Recognising a gesture.** Pressing `U` three times quickly is three
   different commands, and telling "three quick taps" from "three presses over
   a minute" is the same kind of judgement as spotting a double-click. That
   belongs with the mouse and the keyboard, not with the document.

**Where your keymap is kept.** In the engine while Lumit is running; in your
workspace settings file between runs. The frontend stores it as an opaque lump
of text it never reads — the engine hands it out with one call and takes it back
with another. The nice consequence is that "the keymap that survives a restart"
and "the keymap file you email to a friend" are the same format, so Export and
Import are the same code as save and restore.

**The table in Settings → Keymap.** One row per command, grouped by where it is
live, with the name on the left and the keys on the right. Click the keys and
press what you want. A few behaviours are worth knowing because they are
deliberate rather than accidental:

- **One row, one key** (K-200). No shipped command has two chords; if you want
  a second spelling of one, bind it yourself — that is what the page is for.
- **Taking a key another command already has is allowed.** It has to be: if it
  were refused, you could never *swap* two commands' keys, because a swap needs
  a moment where one key is claimed twice. What happens next depends on whether
  both could fire at the same time. If they could, you get a warning naming the
  clash and you sort it out. If they could not (same context), the old command
  simply loses the key and its row goes blank, where you can see it.
- **Reset is per row**, and puts back *every* chord the shipped keymap gives
  that command.

**`U`, `UU`, `UUU`.** In the Timeline, `U` opens the properties you have
animated on the selected layer; pressing it again straight away opens everything
you have *changed*, animated or not; a third press shuts the layer. This is
After Effects' behaviour and the reason it is worth having is that a layer with
forty properties usually has three you care about. The panel counts the taps;
the engine answers which groups qualify, because "has a keyframe" and "differs
from a fresh layer" are questions about the document — and the second one needs
to know what a fresh layer's Position would have been, which is a rule the
engine owns.

**One honest gap.** Some rows in the table — the Tools, Project, Panels and
Effect controls groups — are bindings for commands this frontend has not built
yet. The keys are really bound; pressing them does nothing, because there is
nothing on the other end. They are listed rather than hidden so the table
describes the keymap truthfully, and `docs/TODO.md` carries the gap.
