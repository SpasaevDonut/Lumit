# 17 - Bridge contract (front/back boundary)

**Status: canonical.** This is the single source of truth for how the Flutter
frontend and the Rust engine talk to each other. It supersedes the scattered
descriptions that previously lived in the flutter-port notes (now archived
under [archive/flutter-port/](archive/flutter-port/)). If this doc and the code
disagree, fix one of them in the same commit.

## In plain terms

The application is two halves. The **frontend** is written in Dart and drawn by
Flutter: windows, panels, the timeline, dialogs, input. The **engine** is the
Rust workspace: the document, undo history, decoding, compositing, caching,
export. Dart cannot call Rust functions directly, so a **bridge** sits between
them. The bridge is one Rust crate (`lumit-bridge`) that compiles to a single
shared library (a `.dll` on Windows) which the Flutter runner loads at start-up.

Two kinds of information cross the boundary:

**Commands and readings** cross through generated bindings
([flutter_rust_bridge](https://github.com/fzyzcjy/flutter_rust_bridge), K-179).
Dart never holds a copy of the document. It holds **handles** — small opaque
tokens standing for one thing in it — and calls methods on them:
`layer.rename(name: 'hero shot')`. Rust pushes a small "something changed, and
here is which layer" message down a stream, so only the part of the interface
that actually changed is redrawn.

**Video frames** are far too large to send field by field, so they travel as
**raw pixel buffers** — or, on the fast path, are never copied at all and are
shared as GPU memory the frontend displays directly.

## The layering

```
flutter_ui/ (Dart)              widgets, layout, theme, input, dialogs
    |   dart: ffi
crates/lumit-bridge (Rust)      the C ABI surface: commands in, JSON/pixels out
    |   plain Rust calls
crates/lumit-core, -project,    the engine (unchanged by the bridge)
        -media, -eval, -gpu,
        -audio, -cache, -render
```

- `lumit-bridge` is a leaf crate. Engine crates never depend on it, and nothing
    in the engine depends on the frontend. The rule from
    [05-ARCHITECTURE.md](05-ARCHITECTURE.md) - engine crates never know the UI
    exists - is unbroken. The bridge is not an engine crate; it is the seam.
- The Viewer render path goes through `lumit-render`'s headless renderer
    (`lumit_render::headless`), an **engine** crate the egui frontend drives too.
    Until K-178 that compositor lived inside `lumit-ui` and the bridge had to depend
    on the egui frontend to reach it - a deliberate temporary edge logged as K-175,
    now retired. The bridge depends on no frontend at all.
- Long-running work (decode, export, beat detection) runs on worker threads with
    channels inside the engine; the bridge exposes progress through poll functions
    the frontend calls on a cadence.

## The transport: flutter_rust_bridge (K-179)

The seam is generated, not hand-written. `crates/lumit-bridge/src/api/` declares
the surface in Rust; `flutter_rust_bridge_codegen generate`, run from
`flutter_ui/`, writes the Rust glue (`frb_generated.rs`) and the Dart bindings
(`flutter_ui/lib/src/rust/`). **Never edit generated files** — change `api/**`
and regenerate, and check the output is idempotent before committing.

**The reference types are the identity.** Dart holds opaque handles —
`ProjectReference`, `CompositionReference`, `LayerReference`, `ItemReference` —
with methods on them: `layer.rename(name:)`, `item.delete()`. There is no
document snapshot crossing the boundary, so there is nothing to diff, no mirror
class to keep in step, and no id to resolve. Alongside them a `ScopedChange`
stream names *which* reference an edit touched, so a panel rebuilds its own
subtree rather than everything.

Two consequences are binding, because both exist to make one gesture cost one
undo step:

- **An op takes a whole value, not a granular delta.** `set_transform` takes an
    entire animation; `set_value` takes an entire `BridgeEffectValue`;
    `set_span` carries all three edges. A keyframe drag that moves a key in time
    *and* value is therefore one write. The predecessor's granular
    add/remove/shift ops are deliberately absent and should not be reintroduced.
- **A drag stages rather than commits.** `render_frame_with_preview` renders a
    patched *clone* of the document engine-side, so a hundred drag ticks produce
    pixels without producing a hundred commits, journal writes and undo entries.
    Only the release commits.

The predecessor — a hand-written `extern "C"` surface passing whole documents as
JSON text — was deleted once every panel had moved across (K-179). Its shape
explains the two rules above: it is exactly what they exist to avoid.

### The four binding rules

These are the contract. Three of them survived the change of transport unchanged
(K-179); the fourth did not, and the difference matters.

1. **No panic crosses the boundary.** A panic must never unwind into Dart —
    unwinding across languages is undefined behaviour
    ([14-ENGINEERING-RULES.md](14-ENGINEERING-RULES.md)). The generated handler
    enforces this: every call, sync and async, runs inside `catch_unwind`, and a
    second one wraps that in case the first's own error path panics. Nothing in
    `api/**` needs to repeat it.

    What a panic *becomes* is the part to know. It reaches Dart as a **thrown
    exception**, not as a value — where a well-behaved error is a
    `Result<_, BridgeError>` and arrives as an ordinary return. So every function
    on the surface returns a `Result` with a calm sentence fit for the status
    line, and a throw means a bug rather than a refusal. The
    `no-panics-in-frb-api` CI grep exists to keep it that way.

2. **Memory ownership is the generator's.** flutter_rust_bridge marshals every
    value; nothing is hand-freed on either side, and the raw-pointer discipline
    the previous transport needed is gone. The one thing that still crosses as
    bulk bytes is a rendered frame — see "The frame paths" below.

3. **One lock, held briefly.** Each open project's state lives behind its own
    `RwLock` in a process-wide registry. The lock is held only for the duration
    of one state transition, never across re-entry, an await, or a GPU call
    ([14-ENGINEERING-RULES.md](14-ENGINEERING-RULES.md)). The change observer is
    notified *after* the store's own lock is dropped, because it crosses into
    Dart and a lock held across that boundary is forbidden.

4. **The library is required, not optional.** The previous transport bound
    symbols by name and degraded to placeholder behaviour when the `.dll` was
    absent; flutter_rust_bridge compares a content hash at start-up and refuses
    to run against a mismatched or missing library. So `cargo build -p
    lumit_bridge` is a build dependency of the Flutter tests, and a stale library
    fails loudly rather than misbehaving quietly. Widget tests therefore drive
    the **real engine** — see `flutter_ui/test/frb/frb_test_support.dart` for why
    that is better coverage than a fake and not merely a constraint.

### Commands down, references up

The engine owns the document; the frontend never mutates it directly.

**And the engine owns the decisions (K-181).** The frontend holds *interaction
state* — where the playhead is, the zoom, the selection, the pan — and acts on it
the instant the user does, with no round trip to wait on. What it does not hold
is *policy*. It states facts ("the playhead is at 40", "play from here", "the
document changed") and paints what comes back; scheduling, timing, invalidation
and degradation are the engine's, because the engine is the half holding the
inputs to those decisions. The test: if a Dart change would need a clock, a
queue, a retry, a staleness flag, or a count of work in flight, it belongs on the
other side of this boundary.

- **Commands down.** Every user action becomes one call on a reference handle.
    Each edit maps onto a real, unit-tested `lumit_core` op (`AddLayer`,
    `SetTransformProperty`, `SetLayerEffects`, and so on), so undo/redo
    journalling is one clean step and is untouched by the existence of the
    bridge.
- **References up, not state.** Nothing returns a document. A reader asks the
    handle it already holds (`layer.getSwitches()`, `comp.getLayers()`), and a
    `ScopedChange` on the change stream names which reference an edit touched so
    only that subtree rebuilds. This is the whole difference from the previous
    transport, which returned a refreshed snapshot of the entire document after
    every edit.
- **Rational time crosses as integers.** Frame counts and rates cross as exact
    `{num, den}` pairs or integer frame indices derived from a composition's own
    frame rate, never as floating-point seconds
    ([04-RETIMING.md](04-RETIMING.md), [14-ENGINEERING-RULES.md](14-ENGINEERING-RULES.md)).
    `CompositionReference::time_of_frame`/`frame_at_time` exist so no frontend
    has to do that arithmetic itself: at 29.97 fps a frame is 1001/30000 s, and a
    keyframe placed in floating point does not land on the frame it was set on.

### Versioning

There is no ABI number to gate on. flutter_rust_bridge embeds a content hash of
the declared surface in both the Rust glue and the Dart bindings and checks them
at start-up, so a Dart side built against a different `api/**` than the loaded
library refuses to start rather than calling into the wrong function. The
practical rule that follows: **after any change under `api/**`, regenerate and
rebuild**, and check the generated output is idempotent before committing.

## The frame paths (pixels, not JSON)

A video frame is too large to marshal field by field, so frames have their own
path, documented beside the types in
[`api/state.rs`](../crates/lumit-bridge/src/api/state.rs).

- **Zero-copy shared textures are the ONLY frame transport (K-177, K-183).**
    The engine renders into a shared texture and hands the frontend a handle,
    which the runner registers as a Flutter external texture — no pixels ever
    cross the boundary. Default-on cargo features (`shared-texture` for D3D12
    on Windows, `shared-texture-linux` for Vulkan/DMA-BUF), each inert off its
    platform. The CPU read-back transport that serialised every pixel (8.8 ms
    per 1080p frame in the SSE codec alone) is deleted: a platform with no
    zero-copy path (macOS, K-033) has no Viewer picture until it grows one.
    Both publish variants are always *declared*, so the generated Dart is one
    shape on every platform and the Viewer holds one `switch` over the pair.
- **Small stills still cross as pixels**, deliberately: footage thumbnails
    (`BridgeRenderedFrame`) and the 256×256 scope traces. Both are bounded and
    rare, which is what makes the per-byte codec tolerable there.

## Feature gates

- **`media`** (default on) pulls `lumit-media` (FFmpeg) for probing and decoding.
    Without it, footage does not probe and thumbnails are absent.
- **Note.** `--no-default-features` does **not** currently build: the render
    worker is part of the API surface, which is deliberately identical whatever
    the features are so the generated Dart is one shape everywhere. Recorded in
    [TODO.md](TODO.md).
- **`render`** (default on) enables the composited-comp Viewer path and export
through the headless seam.
- **`shared-texture`** (default off) enables the zero-copy path above; the shipped
Windows .dll is built with it.

## Threading and long-running work

- **Export** runs on its own encode thread inside `lumit-bridge::export`, driving
    `lumit-render` (K-017). The bridge holds the handle and drains progress on
    `api::export::export_poll`.
- **Playback / realtime tier.** A genuine render reports its measured cost to
    `lumit-eval`'s realtime controller (K-171); the frontend reads the current tier
    and scale back through `api::shell::playback_tier` to drive the Auto
    resolution setting.
- **Known synchronous seams** (probing on import, beat detection) still run on the
calling thread and are honest follow-ups in [TODO.md](TODO.md); they function
today, the conversion is a threading refactor, not a missing capability.

## See also

- [05-ARCHITECTURE.md](05-ARCHITECTURE.md) - crates, threads, the dependency rule.
- [06-RENDER-PIPELINE.md](06-RENDER-PIPELINE.md) - how a frame is produced.
- [GUIDE.md](GUIDE.md) - the plain-English tour of the codebase.
- [archive/flutter-port/](archive/flutter-port/) - the historical record of the
    egui-to-Flutter port that produced this seam (frozen; not maintained).