# Handover: bokeh — what is in the tree, and what is wanted next

**Status: handover note, not canonical. Delete it when the work lands.** Written 2026-07-31
because a session ran out, not because this belongs in the repo. Where this and `docs/` disagree,
`docs/` wins and this note is stale.

**The tree is dirty on purpose.** ~1900 lines across 15 files are uncommitted. They are complete
and green — `cargo fmt`, `cargo clippy --workspace --all-targets -D warnings`, and the whole test
suite pass — but nobody has committed them, and the owner has since asked for a different shape
(§1). Do not `git checkout` anything before reading §4.

Also uncommitted and **not** part of this work: `flutter_ui/pubspec.lock` was rewritten by a
`flutter pub get` that ran against a Chinese mirror, so 91 entries now point at
`mirrors.tuna.tsinghua.edu.cn` instead of `pub.dev` and seven transitive packages moved version.
**That file must not be committed** — `git checkout -- flutter_ui/pubspec.lock`. The three
`flutter_ui/macos/` files are Flutter tooling scaffolding from the same run; harmless, unrelated.

**Read first:** `CLAUDE.md`, `docs/01-GLOSSARY.md` (§9's banned words are CI-enforced),
`docs/08-EFFECTS.md` §1–2 and §3.22, `docs/14-ENGINEERING-RULES.md`.

---

## 1. What the owner wants next

**The brief, verbatim, in the owner's own words** (2026-07-31). Read this rather than any
paraphrase of it — including the paragraph underneath, which is only my reading:

> 看起来效果不错，不过体感没有和我 ae 操作上一样,你先总结一个技术文档,干了什么,我去和另一个
> ai 交接工作看他能不能改成和 ae 的面饭一样(单独搞一个 bokeh,就别在 lensblur 上改了)

("面饭" is a typo for 面板 — panel.)

My reading: the *render* is right — verified on the owner's own footage, hexagonal balls on a
muzzle flash and on scene highlights at Exposure ≈ 20. What is wrong is the **panel**: the
parameter surface, and how it feels to operate next to After Effects' **Crossphere Bokeh**,
which is what the owner actually edits in. So the job is a new built-in effect whose
Effect-controls panel mirrors Crossphere's, reusing the maths that already exists in the tree —
and **Lens blur is to be left alone**.

The owner is not a Rust developer and is an expert editor (K-007). "体感" — how it *feels in the
hand* — is the acceptance criterion here, not a pixel comparison. Where this note's technical
detail and that goal pull apart, the goal wins; ask rather than optimise for the maths.

### Crossphere Bokeh's panel, transcribed from the owner's screenshots

```
Blur Radius            70.0
Vertices               6
Roundness              0.00        ← goes NEGATIVE (Vertices 5 + negative = star)
Concentration          0.00        ← not implemented here
Deform                 0.00        ← not implemented here
Rotation               0x+90.0°
Custom Blur Shape      None | Source          ← any layer as the aperture image
  Custom Layer Channel (R+G+B)/3
Exposure               30.0        range −30.0 … 30.0
Threshold              0.00
Edge Behavior          ☑ Repeat Edge Pixels
Depth Map
  Layer                37. d1.n | Source
  Channel              (R+G+B)/3
  Placement            Center Map
  Resolution           6
  Focal Distance       1.00        (greyed out while Use Focus Point is on)
  ☑ Use Focus Point
  Focus Point          1321.1, 898.3          ← click a point in frame to focus there
  Profile              0.00
  ☐ Invert Depth Map
  Composite Mode       Normal
  Remove Edge Leak     0.00
  Detect Edge Threshold 0.10
```

### 1.1 The binding requirement: replicate the control surface

The owner, asked directly what "matching AE" means here (2026-07-31):

> 不管怎么样，我想这个 effect 的操控**完全复刻 crossphere**（我给你的截图上的操作逻辑，就算不是
> 复制也得很像）

**This is the acceptance criterion.** Not "inspired by", not "covers the same ground" — the
control surface and the way it operates should be a replica, or as close to one as Lumit's
schema can express. Parameter names, defaults, ranges, order, grouping, and the interaction
behaviour. What is being replicated is the *panel*; the implementation underneath is our own and
was derived from observing behaviour, never from the plugin's code (§6).

**Get the screenshots from the owner before starting.** The table above is complete for names and
defaults, but the interaction details below are far easier to see than to read, and there are
five panel captures plus two parameter sweeps in the conversation this note came out of.

Interaction behaviour visible in those captures:

- **`Focal Distance` greys out while `Use Focus Point` is ticked.** Conditional enablement.
- **`Custom Layer Channel` greys out while `Custom Blur Shape` is None.** Same mechanism.
- **`Depth Map` is a collapsible group** holding Layer / Channel / Placement / Resolution /
  Focal Distance / Use Focus Point / Focus Point / Profile / Invert Depth Map / Composite Mode /
  Remove Edge Leak / Detect Edge Threshold.
- **`Rotation` draws an angle dial** under its number, not just a scrub field.
- **`Exposure` and `Threshold` twirl open into inline sliders** with their endpoints labelled
  (−30.0 … 30.0).
- **`Edge Behavior` is a checkbox carrying its own label** ("Repeat Edge Pixels") rather than a
  row label plus an unlabelled box.
- **`Focus Point` is a point parameter with a crosshair picker** — arm it, click in the Viewer,
  and focus lands at that point's depth. Much better than a Focus distance slider, and the reason
  `Focal Distance` is greyed out above.
- Most numeric rows carry a stopwatch (animatable); `Custom Blur Shape`, `Custom Layer Channel`,
  `Edge Behavior`, `Layer`, `Channel`, `Placement`, `Use Focus Point`, `Invert Depth Map` and
  `Composite Mode` do not.

### 1.2 What Lumit's schema can and cannot express today

Checked against `crates/lumit-core/src/fx/schema.rs`:

| Needed | Status |
|---|---|
| Collapsible **Depth Map** group | **Exists.** `ParamGroup` (K-145) — label, a contiguous run of param ids, `collapsed` flag. `matte_key` already uses one; copy that. |
| Choice / Bool / Float / Layer params | Exist. |
| **Angle dial** for Rotation | **Missing.** `ParamKind` is Float / Choice / Bool / Colour / Seed / File / Layer. `docs/07-UI-SPEC.md` §6 names "angle dials" as a widget type, so the spec wants one; it has never been built. Either add a `ParamKind::Angle`, or let Rotation be a plain Float and record the deviation. |
| **Conditional enablement** (grey out X while Y) | **Missing entirely.** Nothing in the schema expresses one parameter's availability depending on another's value. This affects `Focal Distance`/`Use Focus Point` and `Custom Layer Channel`/`Custom Blur Shape`. Needs a schema addition — and it is general, so design it for every effect, not for this one. |
| Point parameter with a Viewer crosshair picker | **Missing.** Radial blur's Centre is split into `centre_x`/`centre_y` Floats precisely because there is no point kind (see its schema comment). `docs/07-UI-SPEC.md` §6 wants "point parameters with a crosshair button that arms a click-in-Viewer pick", and `docs/TODO.md` lists the pixel picker as unbuilt. |

Three of those five are schema work that lands *before* the effect can look right. They are
general improvements, each wants its own decision entry, and none of them is bokeh maths.

**Also flag before writing any code: Crossphere's Bokeh already contains the depth model.** It is
not "bokeh without depth" — hence the whole Depth Map group. So the new effect is depth-aware too,
and §4 records how that squares with Lens blur.

---

## 2. What is in the tree

`dof` (label was "Depth of field", now **"Lens blur"**; match name unchanged, the K-138/K-139
relabel-without-re-keying pattern) gained five parameters and one behavioural change.

| id | label | kind | default |
|---|---|---|---|
| `blades` | Blades | Choice: Circle / Triangle … Octagon | Hexagon |
| `blade_curvature` | Blade curvature | Float 0–1 | 0 |
| `blade_rotation` | Blade rotation | Float degrees, unbounded | 0 |
| `bokeh_exposure` | Exposure | Float stops, ±30 | **0 (neutral)** |
| `bokeh_threshold` | Threshold | Float linear light, ≥0 | 0.5 |

Behavioural change: **an unset Depth layer now defocuses the whole frame uniformly at Aperture**
instead of passing the effect through.

### 2.1 The maths, and why it is this shape

**Aperture** — a regular polygon *inscribed* in the circle-of-confusion circle. Inscribed because
the kernel scans a `ceil(coc)` box for taps, and that only bounds an aperture fitting inside the
circle. Inside test:

```
(1 − c)·m²  +  c·k²·r²   ≤   k²·coc²
```

`m` = largest projection of the tap offset onto any blade normal, `k² = cos²(π/N)`, `c` =
curvature. Multiplicative on purpose: no division, no square root, therefore **no guard needed at
`coc = 0`** (both sides collapse to zero and the centre tap stays in). `blade_count == 0`
short-circuits to `r2 <= coc2`, so Circle is bit-identical to the pre-change gather.

**Tonal gather** — each tap splits at Threshold; the excess is raised to a power, averaged,
rooted back:

```
p   = 2^(Exposure / 6)
out = mean( min(c, t) )  +  mean( max(0, c − t)^p ) ^ (1/p)
```

The `x^p` → average → `x^(1/p)` half is the **power mean** (generalised mean) — search under that
name, or under "changing gamma before and after the transform", which is how Auminal described it
in `#general` when reviewing this ("I think the 'proper' way to do it is changing gamma
before/after transformations to achieve it, but whatever you're doing seems to work"). He is
describing the same thing. **At Threshold 0 the formula collapses to exactly his pure form**, since
`min(c,0) = 0` and `max(0, c−0) = c`. The threshold split is the only addition, and it exists to
model Crossphere's Threshold control.

This was **fitted to four observed behaviours of Crossphere**, each read off a screenshot sweep
the owner produced. Only this shape satisfies all four:

1. Blur Radius 0 → the untouched picture, whatever Exposure says
2. Exposure 0 → an ordinary blur
3. Threshold above everything in frame → an ordinary blur however far Exposure is pushed
4. Threshold 0 → the whole picture expands

Splitting rather than gating gives (1) and (3) for free, since `min(c,t) + max(0,c−t) ≡ c`.
`the_tonal_gather_is_an_ordinary_blur_at_its_neutral_ends` pins all four.

**The 6 in `2^(Exposure/6)` is the only fitted constant.** It sets how fast the balls come up
along the slider, estimated from two screenshot sweeps and never checked numerically against
Crossphere. If the onset feels early or late, turn this — `EXPOSURE_STOPS_PER_DOUBLING` in the
`"dof"` arm of `resolve_one`.

### 2.2 Files

| File | What |
|---|---|
| `crates/lumit-core/src/fx/builtins.rs` | Five new params; label → "Lens blur"; `default_param` extracted from `instantiate`; new `fill_missing_params` (§3.3) |
| `crates/lumit-core/src/fx/maths.rs` | `MAX_BLADES` (8) and `aperture_blades(count, rotation_deg)` — the **only** place the aperture's trig happens |
| `crates/lumit-core/src/fx/resolved.rs` | `Resolved::Dof` gained 7 fields; the `"dof"` arm computes `depth_bound`, the uniform-radius fallback, the blade normals, the power |
| `crates/lumit-core/src/fx/cpu.rs` | `TONAL_FLOOR`; `pub fn dof(...)` — the real CPU implementation, now both the §1.6 oracle **and** the degradation rung for the unbound case; private `in_aperture`; the `cpu::apply` arm |
| `crates/lumit-gpu/src/fx_dof.wgsl` | 192-byte `Params`; `coc_radius` unbound branch; `in_aperture`; two-accumulator gather; in-focus short-circuit |
| `crates/lumit-gpu/src/fx/dof.rs` | `MAX_BLADES` mirror, `pub struct DofOp`, `DofParams`, `FxEngine::dof` now takes `&DofOp` |
| `crates/lumit-gpu/src/fx/mod.rs` | `pub use dof::*;` (was missing) |
| `crates/lumit-render/src/fxops.rs` | The `Resolved::Dof` arm calls unconditionally; binds `src` into the depth slot when nothing is bound |
| `crates/lumit-bridge/src/api/effect.rs` | `BridgeEffectInstance::new` and `read_instance_info` fill missing schema params (§3.3) |
| `docs/08-EFFECTS.md` | §3.22 rewritten; Tier-1 table row renamed |
| `docs/02-DECISIONS.md` | **K-210** appended |
| `docs/GUIDE.md` | Plain-English section (K-007 requires one in the same commit) |
| tests | `wgsl_dof_matches_the_cpu_oracle` widened; `the_aperture_shape_reaches_the_picture`, `the_tonal_gather_is_an_ordinary_blur_at_its_neutral_ends`, `max_blades_matches_the_core_constant`, `an_old_instance_reaches_a_parameter_its_schema_grew_later` added |

---

## 3. Traps — every one of these was hit, none anticipated

### 3.1 WGSL and Rust transcendentals do not agree to the bit

`docs/08-EFFECTS.md` §1.6 makes every effect prove its GPU kernel matches a CPU reference (≤2
fp16 ULP here). `cos`/`sin`/`atan2` carry no cross-language guarantee, so **the aperture's trig
is computed host-side once** (`aperture_blades`) and travels in the uniform; the kernel only
multiplies and adds. Precedent: K-136's host-computed hue matrix, K-137's host-side single
division, and `fx_dof.wgsl`'s longhand smoothstep — which exists for exactly this reason.

Any new aperture maths must follow this. Put the trig in `maths.rs` beside `aperture_blades`,
`rgb_split_offset` and `shake_affine`.

### 3.2 Denormal flush-to-zero — the floor is load-bearing

At `p = 32`, `0.05^32 = 3e-42`, **below f32's smallest normal**. A GPU flushes that to zero; a
CPU keeps the denormal. Rooting the two apart turns "0" into "0.056", visible in the dark parts
of the frame. **Measured 110 fp16 ULP before the fix, 1 after.**

Both paths treat an averaged excess under `TONAL_FLOOR = 1e-30` as zero. Not tidying — without it
the effect is numerically unstable, and a single implementation would never have revealed it.
This is the case for the CPU oracle existing, in one example.

### 3.3 A schema that grows does not reach existing instances

`instantiate` copies the schema's parameters when an effect is created. **Nothing ever brought an
older instance up to a schema that grew afterwards.** A parameter added later *rendered* fine (the
resolve step falls back to the declared default) but was **uneditable**: the read that draws the
row and the write behind it both looked only at what the instance carried, so the row drew as a
blank `—` and the write returned `InvalidParam`.

Pre-existing — K-128 hit it and accepted it — and this work made it fatal, since the five
unreachable controls *were* the feature. Fixed by `lumit_core::fx::fill_missing_params`, called
from **two** entry points:

- `BridgeEffectInstance::new` — the handle path (`get_info` / `get_value` / `get_parameters` /
  `set_value` all read that one field)
- `read_instance_info` — the K-184 comp read model, which hands raw `EffectInstance`s in without
  a handle

The first attempt patched only `read_instance_info`, and `get_value` walked straight past it. A
new effect with new parameters is already covered; the two entry points are the thing to know.

### 3.4 The in-focus short-circuit is a correctness fix, not an optimisation

Once taps are weighted at all, a single-tap gather computes `(c·w)/w`, and blending a result
against itself computes `o·(1−t) + o·t` — **neither is an identity in IEEE 754**. Every sharp
pixel drifted an ULP as soon as Exposure was non-zero. `coc <= 0` now writes the original straight
out, skipping both the gather and the Mix blend. Found by a zero-aperture assertion, not by
looking.

### 3.5 Cost — and an open performance report

The gather is O(r²) and **not separable** — inherent to a shaped aperture. `MAX_APERTURE_PX = 128`
(raster px) in the resolve arm bounds it; that cap predates this work (someone hit "quadrillions
of taps and hangs the GPU"). At 1080p, radius 128 is ~5×10⁴ taps per pixel.

**There is an unfiled report against this — and the owner has deferred it.** In `#general`,
2026-07-31:

> "I notice for blur effect it is extremely laggy on mac (or on my device) just a little issue you
> might wanna aware cuz **we are aiming for faster than ae**"

and, when asked whether to weigh it against the panel work: **"性能问题等做完了再说"** — finish the
effect first. So **do not optimise ahead of §1**. Build the control surface, get it accepted, then
come back here. Auminal has separately said they will look at macOS performance.

Recorded now so it is not rediscovered. Two concrete suspects, and it is worth establishing
*which effect* before anyone optimises — "blur effect" is ambiguous between them:

1. **Gaussian blur** (`blur`) is a plain O(radius) separable loop with **no cap at all**. Hard max
   radius is 100 % of the comp diagonal — ≈ 2200 px at 1080p, ~8800 taps per pixel per axis, two
   axes. `docs/08-EFFECTS.md` §3.8 promises "large radii switch to mip-assisted sampling"; that is
   **not built**. This is the stronger suspect and it is a pre-existing problem, not from this work.
2. **Lens blur** (`dof`) — O(r²), capped at 128 px, so bounded but genuinely expensive at large
   apertures.

A **reduced-resolution gather** is the open optimisation and would serve both, which is the
argument for doing it once rather than twice. Bokeh is inherently low-frequency, so computing it
at half or quarter raster and upsampling is close to free visually — but it would break the strict
≤2 ULP oracle bound, so it needs `docs/08-EFFECTS.md` §1.6's looser `moderate`/`heavy` perceptual
epsilon and a separate test that the cheap path stays within a stated bound of a full-resolution
reference. Decide that before writing it.

### 3.6 Others

- **`lumit-gpu` does not depend on `lumit-core`** in production, only as a dev-dependency. Hence
  `MAX_BLADES` declared twice, pinned equal by `max_blades_matches_the_core_constant`.
- **Uniform array stride is 16 bytes** whatever the element type, so `blade_normals` is
  `array<vec4<f32>, 8>` with only `.xy` read. Packing two per vec4 saves nothing.
- **`cargo build -p lumit_bridge`** — underscore. `-p lumit-bridge` matches nothing.
- Engine crates deny `unwrap`/`expect`/`panic`; the frb API surface has its own CI grep because
  clippy cannot see through the `#[frb]` proc macro.
- macOS needs `export FFMPEG_PKG_CONFIG_PATH="$(brew --prefix ffmpeg@7)/lib/pkgconfig"` (K-204 —
  deliberately not in `.cargo/config.toml`).
- A test fixture in `crates/lumit-bridge/src/api/tests.rs` borrowed the real match name `"blur"`
  for a synthetic parameter set; §3.3's filling then added blur's own parameters to it and two
  tests failed. Renamed to `"test_every_value_kind"`. Watch for the same trap elsewhere.

---

## 4. Decisions to revisit, stated honestly

**K-210 merged bokeh into Lens blur rather than shipping a second effect.** The argument: splitting
puts the wanted combination out of reach, because shaped highlights on a depth-driven defocus need
both at once and stacking two effects is blur-upon-blur. Airizz made the same call independently
("they should be the same effect, just if there is no depth layer provided it blurs uniformly").

**K-210's merge stands. Do not revert it.** The separate Bokeh of §1 is an *addition*, not a
replacement — this was settled in `#general` on 2026-07-31 between the owner and Auminal:

> **Randy:** yea directly add it to dof
> **Auminal:** That's great. I think that's kinda everything in the base dof plugin done in that
> case. **Would like to have a more advanced one but can do that later**

So: Lens blur (`dof`) is now the finished *base* depth-of-field, and §1's Crossphere-shaped
`bokeh` is the "more advanced one". Two effects, both depth-aware, differing in depth of control
— not one effect being split in half. An earlier draft of this note said the owner's request
"supersedes K-210", which would have invited exactly the wrong move; it does not.

What *is* still open is whether Lens blur keeps the aperture and tonal controls once `bokeh`
exists, or hands them over and goes back to a plain depth blur. Reverting them there is cheap:
**Circle at Exposure 0 is bit-identical to the pre-K-210 gather, pinned by test.** That is a
decision for the owner, and it wants a new entry in `docs/02-DECISIONS.md` — never edit K-210
(`CLAUDE.md`'s append-only rule).

**Three behaviour changes ride on the current tree**, under the pre-release no-migration policy
(`docs/03-DATA-MODEL.md` §12): an instance with no depth layer now blurs where it passed through;
an instance's aperture becomes hexagonal (Blades defaults to Hexagon); the label changed. Exposure
defaults to 0, so the tonal gather is inert until asked for.

If `bokeh` becomes its own effect, whether Lens blur keeps the aperture controls at all is open.
Reverting them there is cheap and restores the old look exactly — **Circle at Exposure 0 is
bit-identical to the pre-change gather, pinned by test.**

## 5. Not built, deliberately

- **Concentration** and **Deform** — no implementation, and no guess at their maths
- **Custom Blur Shape** (any layer as the aperture) — the machinery exists: K-123's
  layer-reference parameter, the `layer_inputs` parallel slot, `fxops::render_layer_input`. Same
  plumbing the Depth layer already uses.
- **Use Focus Point** (click a point in frame; focus lands at that point's depth) — genuinely
  better than a Focus distance slider, and cheap
- **Roundness going negative** (star apertures) — `blade_curvature` is 0..1 today; the inside test
  would need to handle a concave polygon
- **Edge weighting** (cat's eye toward the corners, onion rings) — cut to keep the parameter count
  and the test matrix honest
- **HDR flares** — Crossphere advertises them; nothing here
- The `Placement` / `Resolution` / `Profile` / `Composite Mode` / `Remove Edge Leak` /
  `Detect Edge Threshold` depth refinements

## 6. Provenance — how the maths was arrived at, and a line not to cross

Everything in §2.1 came from **observing Crossphere's output**: five panel captures and two
parameter sweeps the owner produced on request, reasoned about until one formula satisfied all of
them. The power mean is a standard, published technique, not Crossphere's invention. Matching a
competitor's parameter surface and independently implementing a known method is ordinary product
work, and it is what got us here — the decisive clue was an Exposure sweep, not a disassembly.

**The owner offered the plugin binary; it was declined, and it should stay declined.** Crossphere
Bokeh is a paid, licensed plugin whose terms almost certainly forbid reverse engineering. Lumit is
a public GPLv3 repository whose stated purpose is to put this class of effect in the box — which
makes provenance more load-bearing here, not less. A shipped implementation traceable to a
competitor's binary would be a real problem for the project, and "we only had a look" is not a
defence. It would also not have helped much: the shaders are compiled, and recovering intent from
bytecode is long and uncertain work.

If something cannot be worked out from behaviour, **ask the owner to run the experiment**. That
has been fast and accurate every time: a Threshold sweep settled the split-versus-gate question in
one round after a guess had already got it wrong. Two questions are still open and are cheap for
someone who owns the plugin (§5): whether Threshold is a hard split or a soft knee, and what
`Profile` does.

## 7. Verifying anything you change

```bash
export FFMPEG_PKG_CONFIG_PATH="$(brew --prefix ffmpeg@7)/lib/pkgconfig"
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace --exclude lumit-gpu
cargo test -p lumit-gpu -- --test-threads=1          # GPU oracles, single-threaded by convention
```

In the app: `cargo build -p lumit_bridge`, then `flutter run -d macos` from `flutter_ui/`. The
owner's machine is Apple silicon; the Viewer's zero-copy path is Metal/IOSurface (K-195) and is
confirmed working there as of 2026-07-31 — which retires `docs/TODO.md`'s claim that nobody has
launched the .app.

The four behaviours in §2.1 are what to check by eye. **Blur Radius 0 with Exposure at maximum
must change nothing** is the cheapest way to catch a broken tonal path.
