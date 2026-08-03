# Lens flare — traced ghosts and Fourier starburst

**Status: authoritative implementation note** for the Lens flare effect
([08-EFFECTS.md](../08-EFFECTS.md) §3.27; K-256..K-261). Specs say *what*; this note is
the *how*: the optical model, the exact formulas, the GPU pass structure, and the test
plan. Sources: the FlareSim renderer (github.com/SeanBRVFX/FlareSim_Nuke_builded, itself
built on space55/blackhole-rt) for the optical model and the lens-file collection — its
model is reimplemented here from understanding, not translated; *Physically-Based
Real-Time Lens Flare Rendering* [Hullin et al. 2011] for the quad-grid energy method the
renderer keeps; *Temporal Glare* [Ritschel et al. 2009] for the starburst maths.

**In plain terms.** A camera lens is a stack of curved glass discs with an iris somewhere
in the middle. Most light goes straight through to the sensor — that is the picture. A
tiny fraction reflects off the *inside* of a glass surface, bounces backward, reflects off
another surface, and lands on the sensor anyway: that faint doubly-reflected image is one
**ghost**, and a lens with 20 surfaces has dozens of such two-bounce pairs — the train of
coloured blobs you see when a bright light is in shot. The **starburst** is different
physics: light diffracting around the iris blades, which is why its spikes match the blade
count. This effect simulates both — the ghosts by refracting a grid of rays through a real
lens prescription each frame, the starburst by a Fourier transform of the iris shape,
baked once. Nothing is a drawn sprite; every shape falls out of the physics.

---

## 1. The lens prescription (K-261)

Lenses are plain-text **.lens files** (the FlareSim / PhotonsToPhotos Optical Bench
format): metadata lines (`name:`, `focal_length:`), then `surfaces:` rows of

```
radius  thickness  ior  abbe  semi_ap  coating
```

front to back — signed sphere radius in mm (`0`/`inf` flat, `stop` marks the aperture
stop), axial gap to the next surface, refractive index and Abbe number of the medium
AFTER the surface (`1.0 0.0` = air), clear semi-diameter, and the AR-coating layer count
(0 bare glass, 1 single-layer MgF₂, 2+ multicoat). The last thickness is the back-focal
distance: the running z sum is the sensor plane. **1299 prescriptions are embedded** in
`lumit-core` (`lens_files/` + the generated `fx/lens_library.rs`), transcribed patent
data — each file cites its patent — sorted by name; the native f-number is parsed from
the collection filename (estimated from `focal / (2·front semi-aperture)` when absent).
`parse_lens` (no panics; malformed rows skipped, files under 3 surfaces rejected) turns
one into the flat `FlareSurface` table the trace consumes, with the (n_d, V) pair
pre-fitted to a two-term Cauchy model:

```
B = (n_d − 1) / (V · (1/λ_F² − 1/λ_C²))      λ_F = 486.13 nm, λ_C = 656.27 nm
A = n_d − B/λ_d²                              λ_d = 587.56 nm
n(λ) = A + B/λ²
```

This reproduces n_d and the Abbe number exactly, which is all the flare can see.

**Reflectance.** Bare glass is unpolarised Fresnel by incidence cosine. A coated surface
is the Airy two-interface summation for a single MgF₂ (n 1.38) quarter-wave layer tuned
at 550 nm; each extra layer quarters the residual (the FlareSim multicoat
approximation). The Coating dial blends bare → coated per surface, so 0 is a vintage
uncoated look and 1 the prescription's own character.

## 2. Ghost pairs: enumeration, filter, ranking

Every pair `(a, b)` with `a < b` is a candidate — including pairs straddling the stop
(the FlareSim rule; the stop is air-to-air and cannot reflect, which the interface filter
below removes naturally). At bake time:

1. **Interface filter**: both surfaces must change medium by ≥ 0.001 in n_d.
2. **Brightness probe**: one on-axis centre ray per pair at 650/550/450 nm with the
   file's coating fully on; the mean surviving weight must reach `PAIR_MIN_INTENSITY`
   (1e-7) or the pair is dropped.
3. **Ranking**: descending probe brightness, ties by pair order — deterministic. The
   frame renders the first `max_ghosts`.

No per-pair area boost (FlareSim's `ghost_normalize`) exists here: the quad-grid energy
term makes defocus dilution physical, so compensating it would double-count.

## 3. The per-frame trace (the FlareSim three-phase walk)

Rays launch from a **regular pupil grid**: `side²` corners over the pupil square (side
from the Quality ladder), at `z = front vertex − 20 mm`, all parallel to the light
direction `normalize(−x, −y, focal)` from the light's raster fraction (36 mm sensor
width, y up). The spray radius is the **entrance pupil** `focal / (2 · native f-number)
× 1.5` clamped to the front semi-aperture — spraying the whole front bezel instead
wastes most rays (the Master Prime's 63 mm bezel passes ~4% of a full-width spray), and
the ×1.5 margin keeps the ghost paths that accept rays the imaging pupil rejects.

Each corner carries an **iris mask weight**: the blade polygon's radial bound at the
corner's pupil angle, blended toward the unit circle by Roundness (plus the K-260
wide-open blend — at the native stop the iris retracts behind the circular bore),
feathered by Softness. Zero-mask corners never trace. The same `pupil_mask` renders the
aperture image the starburst FFT consumes, so the two agree by construction.

Per (pair × wavelength), the walk is FlareSim's three phases: **forward** through
surfaces `0..=b` (transmitting with weight × (1−R), reflecting at `b` with weight × R),
**backward** through `b−1..=a` (reflecting at `a`), **forward** again through `a+1..end`,
then a final propagation to the sensor plane (shifted by the K-260 thin-lens focus term
`f²/(1000·d − f)` mm). Intersection picks the sphere solution closest to the surface
vertex; the clear semi-aperture clips with a **10% skirt** — rays inside the skirt stay
formally alive while the housing feather (`smoothstep` on the worst relative aperture
crossing, full inside 0.95, gone at 1.0) zeroes their weight, so bundle boundaries fade
instead of dying quad-by-quad. The working f-stop scales the stop surface's semi-aperture
and the pupil spray together by `native/f` (clamped 0.05..1).

## 4. Rasterising the ghosts (the energy-conserving quad grid)

Each live grid cell draws as two triangles whose density is `launch cell area ÷ landed
area` (both in flare-buffer px²) — a bundle focused small burns bright, spread large sits
dim, and fold caustics blow up exactly as real rims do. Per-corner colour = density ×
Fresnel weight × mask × the wavelength's CIE band RGB × the light's colour × the
exposure gain. Two guards:

- **Degeneracy floor**: landed area is floored at 1e-4 of the launch cell (a formality —
  the visual cap is the next guard).
- **Sub-pixel inflation (K-261)**: a quad below 4 px² would be dropped by any rasteriser
  as a zero-coverage triangle — deleting exactly the caustic flux that makes bright rims
  and fold lines. Such quads inflate about their centroid to 4 px² with colour scaled by
  true ÷ inflated area: flux exact, nothing dropped.

The additive raster (hardware, one-one blend, fp16 buffer; Draft at half resolution) is
followed by the **Ghost blur**: 3 separable box passes (≈ Gaussian) at a radius of
`Ghost softness × 0.01 × frame diagonal` — FlareSim's Ghost Blur, a touch of
out-of-focus softness that also hides quad facets at low qualities.

**Known limit**: a lens whose ghosts are ALL extreme frame-filling defocus (some process
lenses) resolves one pupil cell to tens of pixels; cull boundaries then show as
grid-aligned steps at low quality. Higher quality shrinks them; adaptive grid refinement
is the pinned follow-up (TODO).

## 5. The bake (CPU, cached by parameter hash)

Pure and deterministic: parse the prescription, filter and rank the pairs (§2), render
the aperture image from `pupil_mask` and bake the **starburst sprite** — the aperture's
Fourier amplitude under the Fresnel propagation term at λ_mid, spectrally integrated
(100 samples, sample position scaled by λ_mid/λ so diffraction grows with wavelength)
with CIE weights into linear RGB, peak-normalised. Amplitude |F|, not power |F|² — the
power spectrum's DC core buries the blade spikes.

The **auto-exposure gain** closes the loop (K-258): the bake renders the CPU reference
at thumbnail size (96×54, fixed frame-time settings so only bake-key inputs steer it)
with gain 1 and normalises the mean to `TARGET_PROBE_MEAN` (0.010). The gain ceiling is
**64** (K-261): a wash-only lens has almost no probe energy, and an unbounded loop would
amplify the residue into a lit-up artefact field — capped, such a lens renders honestly
dim, which is what that glass does. The bake key hashes lens, f-stop, blades, rotation,
roundness and iris softness; light position, intensities, dispersion, coating, Ghost
softness, focus, quality and mix are frame-time and never rebake.

**Wavelengths**: the ladder spreads `lambda_count` bands (3/8/16/32 by Quality) about
the 550 nm midpoint, scaled by the Dispersion dial; each band's RGB weight is the CIE
1931 integral over its band (2 nm steps), Y-normalised so the band count never changes
exposure. Point-sampling instead of integrating tints everything blue-green (found by
eye) — deviation D5, kept from K-256.

## 6. Matte source mode (shipped, K-257)

Shipped in the K-257 pass as the **Matte** source mode (docs/08 §3.27): the flare
sources itself from a referenced layer's picture. A compute reduction tiles the matte
into a 32 px grid (max Rec. 709 luma + argmax per tile; ties to the lowest linear index;
fixed-order partial merges, so it is deterministic), then a single-thread pass picks the
top-8 tiles by luma with a 2-tile Chebyshev non-max suppression, each gated by the soft
Threshold and written as a light: position at the source pixel, colour = `(use source ?
the pixel's RGB : white) × the gate × the Light tint` (K-259 — one expression shared by
the CPU reference and the WGSL detection, so the oracle covers both settings). Every downstream stage runs per light on the dispatch z axis — the trace
computes each light's direction in-shader, the vertex build tints by the light, and the
combine stamps one starburst per live light. Manual mode is the same pipeline with one
CPU-written light carrying the tint (white by default). The CPU twin is `lens_flare::detect_lights`, held to the GPU by
the matte-mode frame oracle. The original design sketch (kept for the record): top-K
tie-breaking, and the trace runs per detected light with that sample's colour × energy as
its tint — all on-GPU, no readback, K ≤ 16. The CPU reference runs the identical
reduction. Everything downstream (trace → raster → combine) is unchanged, which is why
the mode can land later without moving any shipped parameter. Full-image convolution
(every pixel a light source, the batch-tool approach) is a recorded non-goal: it is a
seconds-per-frame offline technique, not an interactive effect; the top-K model is what
fits a compositor.

## 7. Traps (learned the hard way — do not rediscover)

- **Sub-pixel quads are silently dropped by every rasteriser.** The caustic flux that
  makes a flare's bright rims lives exactly there. The inflation of §4 is load-bearing;
  measured without it, the frame's dynamic range collapsed from ~116× to 6.6×.
- **Do not spray the front bezel.** Prescriptions list housing semi-apertures far wider
  than the entrance beam; a full-width spray wastes ~96% of its rays on some lenses and
  the survivors render as noise. Size the spray to the entrance pupil (§3).
- **Point splatting cannot reach reference smoothness at photographic ghost sizes.**
  The Monte-Carlo variant of this model (tried first for K-261) needs orders of
  magnitude more rays than the quad grid for the same smooth rim; the quad-grid energy
  term is the noise-free integral of the same physics. Splats were kept only as history.
- **The exposure loop amplifies whatever survives rendering.** Any attempt to fade an
  artefact that also carries the lens's probe energy is undone by the gain; suppress
  artefacts geometrically (feather, skirt) or cap the gain, never by scaling energy the
  probe can see.
- **Roundness must be an SDF lerp to the circle, not an additive bulge** (K-260): the
  sine-bulge form pinches into a flower near 1, and the wide-open blend drives it there.
- **The backward walk's media indices flip.** Travelling backward through surface s, the
  ray leaves the medium AFTER s and enters the medium BEFORE it; reflecting at the far
  bounce restores the forward convention. Get one wrong and every ghost lands wrong by
  centimetres — the pair filter's on-axis probe catches it instantly.

## 8. Test plan (all shipped; names in `fx/tests.rs` and lumit-gpu `fx/tests.rs`)

1. **FFT**: round trip, 8-point DFT match, Parseval (ortho).
2. **Optics units**: Cauchy reproduces (n_d, V); Snell at 45°; TIR returns None;
   normal-incidence Fresnel = ((n1−n2)/(n1+n2))²; the MgF₂ quarter-wave cuts bare-glass
   reflectance and each extra layer cuts it further; Coating 0 is bare glass exactly.
3. **Library**: all 1299 files parse with sane focal lengths (2..2000 mm), surface
   counts (3..64) and positive semi-apertures; the bake is deterministic (pairs, sprite,
   gain bit-equal across runs); every ranked pair indexes real surfaces.
4. **Trace**: the top pairs land a solid live population with finite positions and
   weights in [0, 1]; the pupil mask is 1 at centre, 0 far outside, and passes less area
   as a hexagon than as a circle.
5. **GPU trace oracle** (§8.5 shape, K-261 bounds): corner-for-corner against
   `trace_splat` across two lenses × two lights — mean position error < 0.2 px, p99
   < 3 px (a few-ULP difference near a fold legitimately lands a ray on the other
   branch), p99 relative weight error < 5% (2e-4 absolute floor), live/dead flips < 1%.
6. **GPU frame oracle** (§8.6): full pipeline vs the CPU reference at mean |Δ| < 2e-3
   with total energy within 1%, visible energy floor, bit-stable across runs, and
   Intensity-0 / Mix-0 bit-exact passthroughs.
7. **Matte mode**: GPU detection + per-light flare against the CPU reference at the
   frame bound; the shared MAX_LIGHTS / DETECT_TILE constants pinned.
8. **Neutrals and background**: Black background flips alpha only while live; the
   passthroughs ignore it.
9. **Focus**: the thin-lens shift is 0 at infinity, `f²/(1000·d − f)` near, ≤ f always.
