# The flow engine: optical flow, frame synthesis, and flow motion blur

The hardest algorithmic component in Lumit, feeding Retime's flow interpolation
([04-RETIMING.md](../04-RETIMING.md) §10) and the flow motion blur effect
([08-EFFECTS.md](../08-EFFECTS.md)). This note commits to specific algorithms so
implementation is engineering, not research.

## 0. Strategy: two backends behind one interface

```rust
trait FlowBackend {
    /// Dense forward flow A→B, half or full res, in pixels of the full-res frame.
    fn flow(&mut self, a: &GpuFrame, b: &GpuFrame, quality: FlowQuality) -> FlowField;
}
```

1. **`dis` (v1, always available)**: Dense Inverse Search flow implemented in WGSL.
   Deterministic, no model files, ~2–4 ms at 1080p half-res on the reference GPU. Quality
   ≈ Twixtor's easy-80% on game footage (high-contrast, sharp, high-fps sources — the
   favourable case).
2. **`rife` (post-v1, optional)**: RIFE v4.x ONNX via `ort` with the DirectML execution
   provider (CoreML on the dev Mac). The community already pre-processes with RIFE
   (research: Flowframes), so this is a known-good ceiling. It synthesises frames directly
   (no explicit flow field), so it slots in at the *synthesis* level (§3) rather than as a
   FlowField producer; motion blur keeps using `dis` vectors. Keep it optional: model
   download, licence (RIFE is MIT), non-determinism across GPU/EP versions — export
   determinism rules mean the project stores which backend rendered.

Do not implement Farnebäck (too smeary), Horn–Schunck (too slow at quality), or RAFT-class
training pipelines (research project). DIS is the studied sweet spot: OpenCV's
DISOpticalFlow documents the algorithm; the paper is Kroeger et al., ECCV 2016.

## 1. DIS flow in WGSL — exact structure

All passes on grayscale (BT.709 luma of the linear frame, then **gamma-encode before
correlating** — flow works better on perceptual values; this matches OpenCV practice).

**Pyramid build**: `L0` = luma at working res (default **half** comp res; `FlowQuality`
selects), then box-downsample ×2 per level to ~24 px min dimension (≈ 5 levels at 1080p
half res). Any deeper and the 8×8 patches are frame-scale: every patch straddles every
motion boundary and whole strips of the coarsest field start as garbage the finer levels
cannot always heal (measured in the §6.1 occlusion test; originally ~16 px).
Also build Sobel gradients per level (v1: f32 storage buffers throughout, not fp16
textures — fp16 rounding would eat the §6.5 CPU-parity budget; textures return when
synthesis itself moves GPU-side).

**Per level, coarse → fine:**

1. **Init**: upsample flow from coarser level (bilinear, ×2 magnitude). Each patch
   samples the init at its centre, its four corners, **and one patch-length outside
   each edge**, and starts from the lowest-SSD candidate — near a blurred motion
   boundary only a sample from beyond the blur puts the true motion on the ballot
   (the data-parallel stand-in for OpenCV's sequential neighbour propagation).
2. **Inverse search (the core)**: for each 8×8 patch on a stride-4 grid, refine its flow
   vector by Lucas–Kanade-style Gauss–Newton, *inverse compositional*: the Hessian comes
   from patch A's gradients (precomputable per patch, once per level):
   `H = Σ [gx², gx·gy; gx·gy, gy²]` over the patch (2×2, invert analytically; if
   `det < 1e-6` mark the patch invalid — textureless). Then ≤ 12 iterations of:
   `residual r = Σ g·(A(x) − B(x+u))`, `Δu = H⁻¹ r`, `u += Δu`, stop when `|Δu| < 0.02 px`
   (sign note: the update must *reduce* the residual; the earlier draft had the residual
   reversed, which diverges — caught by the §6.1 tests). Track the best cost seen and
   revert a step that made matching worse (guards near-singular H). A patch whose final
   cost stays above `0.25 × its own variance + 0.05` never found its content — it is
   straddling a motion boundary or occluded — and is marked invalid too.
3. **Densification**: each pixel's flow = weighted average of the ≤ 9 valid patch vectors
   covering it, weight `exp(−‖B(x+u_patch) − A(x)‖² / σ²)` (σ ≈ 0.08 in encoded luma) —
   photometric-error weighting is what keeps edges crisp; plain bilinear here is the
   classic mistake that produces rubber-sheet output. Two refinements, both test-driven:
   average only the votes that agree (within ~2 px) with the best-matching vote —
   averaging *across* a motion boundary manufactures a vector belonging to neither
   motion — and when no covering patch explains a pixel, retry against the wider 5×5
   patch neighbourhood's hypotheses (photometrically gated, so nothing leaks across a
   content edge) before falling back to the init flow with the pixel marked invalid.
4. **Smoothing**: one 3×3 edge-aware blur of the flow field — bilateral on luma *and* on
   flow difference, so vectors from the two sides of a motion boundary never average into
   a phantom in-between motion.
5. **Variational refinement** — DIS part three, and **not optional** (K-269). This note
   previously said to skip it in v1 and "measure first"; the measurement happened and both
   halves of the reasoning were wrong. Untextured regions are not rare in game capture (smoke,
   sky, muzzle flash, water, darkness are most of a frame during the fast moments a montage
   slows down), and without refinement they fail *hard* rather than softly: densification
   leaves the coarse guess, flags the pixel invalid, §2 counts invalid as occluded, and §3
   crossfades it — patches of ghosted mush, the reported artefact.

   Per the paper (§3.3), minimise `E(U) = ∫ σ·Ψ(E_I) + γ·Ψ(E_G) + α·Ψ(E_S) dx` with
   `Ψ(a²) = √(a² + ε²)`, ε = 0.001, σ = 5, γ = 10, α = 10. `E_I` is intensity constancy,
   `E_G` gradient constancy — the term that survives a brightness step, which a muzzle flash
   is and which plain intensity constancy reads as motion everywhere — and `E_S = ‖∇u‖² +
   ‖∇v‖²`. Both data tensors are normalised by their own gradient energy plus ζ² (ζ = 0.1) so
   a high-contrast pixel cannot shout down a low-contrast one. Run once per pyramid level,
   `1·(s+1)` fixed-point iterations at scale `s` counting from the coarsest, each linearising
   about the current warp and solving for the increment with `θ_vi = 5` SOR sweeps at ω = 1.6.

   **Sweeps are red–black, not raster order.** Plain SOR wants each pixel to read its
   neighbours' just-updated values, which is strictly sequential. On a checkerboard every
   neighbour of a red pixel is black, so a whole colour updates with no pixel reading another
   of its own colour — the identical algorithm, reordered into something the WGSL can run in
   parallel. **The CPU oracle is written this way deliberately**: a sequential oracle would
   have condemned the shader to disagree with it by construction, and the §6.5 parity contract
   would have had to be abandoned rather than met.

   **Validity changes meaning.** It was "at least one patch covered me photometrically"; it
   becomes "the refined flow explains these pixels", from the residual after refinement
   (`VR_RESIDUAL_MAX`). A refined field has an answer everywhere, so the honest question is
   whether the answer is right, not whether one was found.

   **Cost, measured (960×540 pair, dev machine):** parts 1–2 on the CPU 456 ms, all three
   1.82 s — 4×. Parts 1–2 on the GPU 4.8 ms. The refinement therefore *must* reach WGSL: the
   CPU oracle at 1.8 s per pair is a correctness reference, not a preview path.

**Output**: the dense flow at working res plus a per-pixel validity mask (v1: one f32
storage buffer read back to the CPU, since synthesis still runs there; `Rg16Float`
texture + R8 mask when the GPU-resident synthesis path lands).

**Kernel shape (v1)**: one *thread* per patch rather than one workgroup — the sums then
run in the same sequential order as the CPU oracle (which makes the §6.5 parity bound
meaningful), the WGSL needs no shared-memory/uniformity choreography, and the whole
search is far inside budget (measured ~4 ms per 960×540 flow *pair* including readback
on the dev RTX). Revisit workgroup-per-patch with shared memory only if profiling ever
says the search dominates.

## 2. Occlusion: forward–backward consistency

Compute flow both directions (F: A→B, B: B→A — reuse everything; it is 2× cost).
Pixel x is **occluded in B** (i.e. visible only in A) when
`‖F(x) + B(x + F(x))‖ > max(1.5, 0.05·(‖F‖+‖B‖))` (the standard consistency test with a
relative term for large motions). Output an occlusion mask per direction (R8: 0 = ok,
1 = occluded, plus the invalid-patch bits from §1). Dilate by 1 px — consistency tests
under-detect at exact boundaries.

## 3. Frame synthesis at phase φ ∈ (0,1) between A and B

Backward-warp both endpoints and blend with occlusion-aware weights (the RSMB/Twixtor
family approach; avoids forward-splatting's holes and z-fighting):

```
uA(x) = −φ · F_scaled(x)        // sample A at x + uA   (F scaled: flow A→B over Δt=1)
uB(x) = (1−φ) · B_scaled(x)     // sample B at x + uB   (B_scaled: the *forward* velocity
                                //  at B's grid, i.e. the negated B→A field)
wA = (1−φ) · (1 − occB(x)) + ε ;  wB = φ · (1 − occA(x)) + ε
out = (wA·A(x+uA) + wB·B(x+uB)) / (wA + wB)
```

- The flow sampled for warping at x should ideally be the flow *at the destination*;
  approximate with one fixed-point iteration: sample F at x, then re-sample F at
  `x − φ·F₀(x)`, use that. Two lines in the shader, visibly reduces edge doubling.
- Where **both** endpoints are occluded/invalid (revealed background with no source):
  fall back to blend `lerp(A, B, φ)` — soft failure identical to Frame-Mix, which is the
  documented graceful-degradation behaviour ([08-EFFECTS.md](../08-EFFECTS.md): confidence-
  gated fallback). Also expose the per-pixel confidence as an optional debug view; editors
  mask flow failures by hand today and will want to see them.
- Everything here operates on **linear premultiplied fp16** (warping/blending is where
  linear matters most); only the *correlation* in §1 used encoded luma.

Phase quantisation for cache keys: per [04-RETIMING.md](../04-RETIMING.md), φ rounds to
1/1024. Flow fields themselves are cached per (A,B, quality) pair in the sidecar `flow/`
tier — they are the expensive part; synthesis is ~free.

## 4. Flow motion blur (RSMB-class)

Given the frame N and flow to its neighbours (F₋ to N−1, F₊ to N+1), per-pixel blur along
the motion trajectory with shutter s ∈ (0,1] (from shutter angle/360) and amount k:

```
v(x) = k · s · 0.5 · (F₊(x) − F₋(x))          // central-difference velocity, px/frame
S = clamp(ceil(‖v‖ / 2), 1, 64)               // adaptive taps, ≤ 2 px per tap
out = (1/W) Σ_{i=−S..S} w_i · frame(x + v·(i/(2S)))   // w_i = 1 (box) — a shutter is a box
```

- Iterate the same destination-flow fixed-point trick per tap for long streaks; without it,
  streaks curve wrongly around rotating objects.
- Occluded taps (mask from §2) drop out of the sum (renormalise by W) — this is what stops
  foreground smearing across revealed background, the visible difference between cheap and
  good motion blur.
- Respect the no-double-blur rule: when the host already applied transform multi-sampling
  to a layer, the effect receives a flag and must not add transform-derived velocity
  ([06-RENDER-PIPELINE.md](../06-RENDER-PIPELINE.md) §motion-blur).

**Shipped v1 (labelled "Fast motion blur", FX-19).** The v1 effect measures the single forward
neighbour (+1) and streaks each pixel with a fixed centred box of `Samples` taps. Crucially it
does **not** drop occluded taps from the sum (a per-tap on/off gate showed as hard blurred /
un-blurred cut regions). Instead the *streak length* is scaled smoothly by a per-pixel
**confidence** in 0..1: `lumit_flow::confidence(fwd, bwd)` — the raw forward–backward consistency
mapped to 1 (agree) … 0 (disagree, at the same rel/abs scale the binary occlusion cut uses, an
invalid patch fully suspect), then 3×3 box-blurred so the taper has no seam. The confidence
rides in the flow texture's `.z` (an `rgba32float` field), and the kernel does `sv = flow ·
shutter_frac · conf`; confidence 0 collapses the streak to the pixel (a passthrough there). A
**View** enum outputs the finished blur, the flow colour-coded, or the confidence as greyscale.
CPU oracle (`lumit_core::fx::cpu::motion_blur`) and WGSL stay op-for-op (§1.6). Adaptive per-tap
counts, the ±1 central difference and the destination-flow fixed point remain follow-ups.

## 5. Parameters and defaults (user-facing, per [08-EFFECTS.md](../08-EFFECTS.md))

Resist adding more knobs — Twixtor's manual is a warning, not a target. The set is closed at
the §3.1 table, which ships in full as of K-268.

**Engine-side (`lumit_flow::FlowSettings`).** `lumit-flow` is an engine crate and knows
nothing of the document, so the stored `FlowParams` are translated into plain numbers by
`lumit_render::decode::flow_settings` — one function, so preview, export and the flow cache
cannot translate the same parameters into two different measurements.

| Setting | From | Effect on the algorithm |
|---|---|---|
| `divisor` | Flow resolution | 1/2/4 on the source dims before §1's pyramid. Repeated box-halving, never a second resampler, so the WGSL mirrors it. A source under `8·d·2` px stays whole rather than starving the pyramid |
| `iterations` | Vector detail | §1 step 2's cap: 6 / 12 / 20 / 32 (Medium is the paper's ≤ 12) |
| `min_level_dim` | Vector detail | §1's pyramid floor: 48 / 24 / 24 / 16. Below ~24 the 8×8 patches go frame-scale — the failure §6.1 measured |
| `smoothness` | Smoothness | Scales `FLOW_SIGMA2` in §1 step 4's bilateral, quadratically over a 4× span each way, clamped. 50 is exactly the tuned constant, so the default is bit-identical to the pre-parameter engine |
| `refine_iters` | Vector detail | §1 step 5's fixed-point iterations per level: 1 / 1 / 2 / 3. `0` disables DIS part three and is **not user-reachable** — it is the two-part engine K-269 replaced, kept only so the A/B test and the GPU parity test can address it |
| `occlusion` | Occlusion handling | §3's weights: Visible-only keeps the `(1 − occ)` terms, Blend drops them |
| `fallback` | Fallback | §3's both-occluded branch: crossfade or the nearer endpoint |
| `hud_guard` | HUD guard | Runs §3.1 step 5's `hud_weights` and mixes synthesis back toward the plain blend by it |

**Every setting has a GPU path.** The iteration cap and the smoothing sigma ride in the
per-level `Params` uniform; the pyramid floor shapes the plan, which is rebuilt when the
settings change (`Plan::set`). The refinement is seven kernels — `vr_warp`, `vr_init_duv`,
`vr_deriv`, `vr_sor_red`/`vr_sor_black`, `vr_apply`, `vr_validity` — reusing the existing
eight-binding layout: `duv` packs `(du, dv, u, v)` into one vec4 so the solver needs no fifth
read slot, the increment travelling with the flow it is an increment of. `FlowError::Unsupported`
therefore no longer fires for any real setting, and the parity test covers all three parts of
the algorithm again.

**Measured (960×540 pair, dev machine):** GPU parts 1–2 4.3 ms, all three **8.9 ms**; CPU all
three 1.9 s. The refinement roughly doubles GPU cost and is comfortably inside budget.

## 5.5 Measured quality (the harness, K-269 follow-up)

`crates/lumit-render/tests/flow_quality.rs` scores the engine on real footage by
rebuilding a frame from its two neighbours and comparing against the frame that
was actually there — ground truth out of ordinary film. It reports against
**nearest** (hold the previous frame) and **blend** (crossfade). Blend is the one
that matters: flow costs far more, and its failure is tearing rather than a soft
double image, so losing to a crossfade makes it worse than useless.

**Three measures, and the third is the one that matters.** PSNR scores an error
by size, SSIM by shape, and the **5th-percentile block SSIM** by the worst
twentieth of the picture. Flow does not go uniformly slightly wrong: it goes
badly wrong in a few places and stays right everywhere else, which over a 1080p
frame averages to a rounding error. A clip that looks unusable can score level
with a crossfade on the mean and be a fifth of a point worse on the worst blocks.

**Triplets where any two of the three frames are held are excluded**, compared
loosely because a held cel is not bit-identical after encoding. Animation drawn
on 2s and 3s holds most of its frames — 78% of neighbouring pairs on the clip
below — so a middle frame that duplicates an end is the norm rather than the
exception, and leaving those in scores every method against a target one of its
own inputs already is. An earlier run of this harness did leave them in and
concluded that *holding* was the best method on animation; it is not, it is
comfortably the worst, and the difference was entirely the sampling.

| footage | rate | nearest | blend | flow | Δ PSNR | Δ worst |
|---|---|---|---|---|---|---|
| gameplay 600 fps | native | 29.02 / 0.8688 | 31.86 / 0.9012 | **35.62 / 0.9707** | +3.77 | — |
| gameplay | 60 (÷10) | 22.20 / 0.6530 / 0.033 | 24.35 / 0.6871 / 0.083 | **26.93 / 0.8208 / 0.342** | +2.58 | **+0.259** |
| gameplay | 24 (÷25) | 20.38 / 0.6012 | 21.49 / 0.6170 | **22.00 / 0.6663** | +0.51 | — |
| anime on 2s | stride 2 | 32.74 / 0.9532 / 0.666 | 37.08 / **0.9536** / **0.699** | 37.07 / 0.9506 / 0.681 | −0.00 | −0.018 |
| anime | stride 3 | 31.52 / 0.9511 / 0.671 | 35.99 / **0.9541** / **0.712** | **36.87** / 0.9519 / 0.697 | +0.88 | −0.015 |

(PSNR dB / SSIM / worst-5% where measured.)

**What it says.** On game capture flow is not marginally better than a crossfade,
it is holding structure together where a crossfade falls apart: +0.26 of
worst-block SSIM at a 60 fps effective rate, against a blend that has essentially
collapsed there (0.083). This is the footage the project exists for (K-002) and
the engine is doing its job on it.

On cel animation flow is level with a crossfade on PSNR and consistently *worse*
on both structural measures. Interpolation itself is clearly worth doing — nearest
is far behind — so this is not "the content cannot be interpolated". It is that
warping introduces localised damage a crossfade does not, and the damage lands on
line art where it is most visible. Cel animation is flat regions bounded by hard
edges: no photometric evidence across most of the frame, and a smoothness term
that diffuses motion straight over boundaries it should stop at.

**Two corollaries.** Parameters do not decide this — the full sweep spans about
0.2 dB on either clip, so whatever fixes animation is not a knob. And a
confidence-weighted bias toward the fallback, written to stop flow ever losing to
a crossfade, was measured and removed: it cost gameplay 0.036 of worst-block SSIM
to gain animation 0.012 and changed neither verdict.

**Content is separable, cheaply.** `clip_cadence.rs` reports held-frame fraction
and flat fraction: 78% held and 67% flat on the animation clip, 0% held and 23%
flat on the game capture. Either statistic alone separates them, which is what
makes choosing an engine automatically (§0's `rife` backend) a tractable thing
rather than a guess.

## 6. Test plan

1. Analytic: translating/rotating checkerboard and Perlin textures with known flow —
   endpoint error < 0.3 px mean at half res on translation ≤ 32 px; occlusion mask matches
   the analytic occlusion of a sliding square to ≥ 90% IoU (measured on the raw §2 mask —
   the 1 px safety dilation is for synthesis, and its perimeter alone would exceed the
   IoU budget; the square must slide off-axis, as a motion-parallel silhouette edge is
   aperture-blind).
2. Real-footage goldens: 5 clips (slow pan, fast strafe, rotation, particle spam,
   smoke/gradient sky) — synthesis at φ=0.5 compared visually once, then pixel-locked as
   regression goldens (deterministic by construction).
3. Round-trip: φ=0 and φ=1 return A and B bit-exactly (degenerate-path correctness).
4. The Gate-2 criterion ([16-ROADMAP.md](../16-ROADMAP.md)): 240→60 fps ramp on reference
   game footage, side-by-side against Twixtor output — comparable on clean shots, no
   crash/garbage on the hostile ones (fallback engages instead).
5. Perf: flow pair ≤ 4 ms half-res 1080p, synthesis ≤ 0.5 ms, blur ≤ 2 ms at defaults on
   the reference GPU; CPU reference implementation (required by K-019) matches WGSL within
   1e-3 on the analytic tests — it is the oracle, speed is irrelevant.
