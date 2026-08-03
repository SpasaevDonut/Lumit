# Lens flare — traced ghosts and Fourier starburst

**Status: authoritative implementation note** for the Lens flare effect
([08-EFFECTS.md](../08-EFFECTS.md) §3.27, K-256). Specs say *what*; this note is the *how*:
the optical model, the exact formulas, the GPU pass structure, the deviations from the
reference implementation, and the test plan. Sources: *Physically-Based Real-Time Lens
Flare Rendering* [Hullin, Eisemann, Seidel 2011] and its supplemental; *Temporal Glare*
[Ritschel et al. 2009] for the diffraction maths; and the realflare renderer
(github.com/beatreichenbach/realflare, GPLv3), read end-to-end as the reference — its
pipeline is ported, not re-derived, with the deviations of §5.

**In plain terms.** A camera lens is a stack of curved glass discs with an iris somewhere
in the middle. Most light goes straight through to the sensor — that is the picture. A
tiny fraction reflects off the *inside* of a glass surface, bounces backward, reflects off
another surface, and lands on the sensor anyway: that faint doubly-reflected image is one
**ghost**, and a lens with 15 surfaces has dozens of such two-bounce paths, which is the
train of coloured blobs you see when a bright light is in shot. The **starburst** is a
different phenomenon: light bending (diffracting) around the iris blades, which is why its
spikes match the blade count. This effect simulates both — the ghosts by shooting a grid
of rays through the real lens geometry each frame, the starburst by taking the Fourier
transform of the iris shape once and stamping it at the light. Nothing is a drawn sprite;
every shape falls out of the physics.

---

## 1. The lens prescription

A lens model is an ordered list of surfaces, front to back, plus the iris position:

```rust
pub struct LensSurface {
    pub radius_mm: f32,      // signed sphere radius; 0 = flat (the iris plane)
    pub thickness_mm: f32,   // axial distance to the NEXT surface
    pub ior_d: f32,          // refractive index at the d-line (587.6 nm); 1.0 = air gap
    pub abbe_v: f32,         // Abbe number (dispersion); 0 for air
    pub height_mm: f32,      // aperture half-height of the element (housing clip)
}
pub struct LensModel {
    pub label: &'static str,
    pub focal_length_mm: f32,
    pub native_fstop: f32,
    pub aperture_index: usize, // which surface is the iris
    pub surfaces: &'static [LensSurface],
}
```

Prescriptions are **static data in `lumit-core`** (`fx/lens_data.rs`) — no files, no IO,
deterministic. They come from published patents (a patent's optical table is public
information; realflare bundles the same ones). v1 ships four, chosen for distinct
characters: a simple 6-element double-Gauss prime (clean, few ghosts), a fast 14-element
cine prime (rich ghost train — the Zeiss MP 50/T1.3 table from US patent 7446944 B2), a
telephoto (long, stretched ghosts), and a wide zoom section. The sensor is appended at
trace time as a final flat "surface" whose height is half the sensor diagonal, exactly as
realflare's `lens.elements()` does.

**Dispersion — deviation D1.** Realflare ships a glass catalogue and nearest-matches each
element's (n, V) to a real Sellmeier table. We compute the index directly from the
prescription's (n_d, V) with the two-term Cauchy model:

```
B = (n_d − 1) / (V · (1/λ_F² − 1/λ_C²))      λ_F = 486.13 nm, λ_C = 656.27 nm
A = n_d − B/λ_d²                              λ_d = 587.56 nm
n(λ) = A + B/λ²
```

This reproduces n_d exactly and the Abbe number exactly (it is the definition of V solved
for a two-term model), which is all the flare can see — the difference against a true
Sellmeier fit is in the third decimal at spectrum edges, far below visibility here, and it
deletes the whole catalogue + matching machinery.

## 2. Ghost enumeration and ranking

A ghost is a pair `(b1, b2)` of surface indices with `b2 < b1`, both strictly inside the
element run, and **both on the same side of the iris** (a ray cannot usefully double back
through the iris; same rule as realflare's `ray_paths`). For n surfaces that is O(n²)
ghosts — the 14-element prime yields ~120.

At bake time every ghost is traced with a 5×5 probe grid (fixed off-axis reference light,
one wavelength) on the CPU; each probe cell scores the render's own energy term (launch
cell area ÷ landed cell area, min-area floored) and the ghost's brightness proxy is its
live cells' **median** energy. Ghosts rank by descending brightness, ties by pair order —
deterministic. The first `max_ghosts` survive at frame time. This is realflare's
preprocess cull, moved into the cached bake and upgraded from a bbox proxy to the real
energy term.

The **auto-exposure gain** closes the loop (K-258): the bake renders the actual CPU
reference at thumbnail size (96×54, fixed frame-time settings so only bake-key inputs
steer it) with gain 1, measures the mean, and normalises it to `TARGET_PROBE_MEAN`
(clamped 0.02..400). Two cheaper proxies were tried and killed: the per-ghost probe
median and the on-sensor probe flux both mispredicted real lenses by orders of magnitude,
because ghost energy depends on where a design's caustics land at the render framing —
the Petzval carried bright probe cells that never reached the frame and rendered 30× dim.
Relative brightness *between* a lens's own ghosts stays physical; only the overall
exposure is normalised.

The **launch square** rides the iris, not the front element: `2.6 × iris half-height`,
clamped to `1.6 × front half-height` — the iris is what gates the bundle, so this keeps
the grid dense where rays can pass whatever the front element's size (one bundled
prescription's front housing is listed at 450 mm, which a front-based rule turned into a
launch square that landed 5 rays in 3072).

## 3. The per-frame trace

Direct port of realflare's `raytracing.cl`, in WGSL and (as the oracle) Rust. Per
(ghost, wavelength): a `grid × grid` bundle of parallel rays over a launch square is aimed
at the front element along the light direction. The launch square is fixed per lens at
2.3 × the front element's half-height — the full clear diameter plus margin (K-258: an
undersized square shows in the picture as a rectangular ghost boundary, the bundle's own
clip instead of the housing's feathered vignette); cells whose rays miss are culled, so
overshoot costs only rays, never artefacts.

Light direction from the parameter position: `dir = normalize(px_frac·s, py_frac·ratio·s,
focal_length)` with `s` = half the sensor width, matching realflare's `update_direction` —
so a light at the frame corner enters at the true corner field angle.

Per surface, in order (walking forward, then backward after the first bounce, then forward
again after the second — realflare's `delta` walk):

- **Intersect**: flat plane for radius 0, else ray–sphere with the centre at
  `z = −(offset + radius)`; a miss kills the ray. `incident = acos(clamp(dot(−dir, n)))`.
- **Iris surface**: record `uv = hit.xy / iris_height` (the ghost-disc texture
  coordinate; no refraction — the iris is an absorber, not glass). The **f-stop scales
  the ghost disc at sampling time**, not the trace: the fragment reads the disc at
  `uv / ghost_scale` with `ghost_scale = clamp(1 − fstop/32, 0.05, 1)` (realflare's
  rule), so stopping down shrinks every ghost's disc while the trace stays f-stop-free —
  which is also what lets the bake cache ignore per-frame f-stop animation for the trace
  tables (only the disc's FRFT ringing rebakes).
- **Everywhere else**: track `rrel = max(rrel, |hit.xy| / height)` — a ray that ever
  leaves the housing (`rrel > 1`) is vignetted; the fragment fades it by
  `smoothstep(1.0, 0.95, rrel)`.
- **Refract** by Snell in vector form (`refract()`), with `n1/n2` from the Cauchy model at
  this ray's λ; total internal reflection kills the ray (dir.z == 0 sentinel, as in
  realflare).
- **Reflect** at the ghost's two surfaces, multiplying the ray's reflectance by:
  - uncoated: the plain Fresnel average `(r_s² + r_p²)/2`;
  - coated: `fresnel_ar(θ, λ, d, n0, nc, n2)` — the Ritschel supplemental single-layer
    interference formula, with coating index `nc = max(√(n1·n2), 1.38)` (MgF₂ floor) and
    quarter-wave thickness `d = λ_c / (4·nc)` tuned at `λ_c`, the element's coating
    wavelength;
  - the **Coating** parameter lerps between the two, so 0 is a vintage uncoated lens
    (bright neutral ghosts) and 1 a modern multicoat look (dim, strongly colour-cast).

  **Coating wavelengths — deviation D2**: realflare lets the user list a λ_c per element;
  we assign them deterministically, cycling `{480, 510, 540, 570, 600} nm` by surface
  index — the variety is what matters visually, and a per-element editor is UI the effect
  does not need. (Custom prescriptions later can carry their own list.)

**Wavelengths.** `quality` picks the count (4 / 8 / 16 / 32 for Draft / Normal / High /
Ultra, grids 16/48/80/128 — K-258's photo-real ladder; three bands read as a
stacked RGB split at ghost rims, and the extreme tier is deliberately
expensive while Normal stays real-time); λ_k = centred steps over [390, 730] nm, exactly realflare's `wavelength_array`.
Each traced λ's RGB weight is its **band's integral** of the CIE colour-matching
functions (sampled at 2 nm), not a point sample — deviation D5 from realflare's per-λ
point sampling: with only 3 traced wavelengths, point-sampling red at 673 nm weighs it at
a tenth of its true band energy and tints every flare blue-green (found by eye on the
first renders).
The **Dispersion** parameter scales each λ's *offset from λ_mid* before the trace, so 0
collapses the spectrum onto 560 nm (a monochrome trace — cheap and fringe-free) and 2
doubles the fringing; the CIE colour weights (§4.3) keep reading the *unscaled* λ so
tinting stays honest.

Ray output (a storage buffer, one struct per ray): sensor `pos.xy` (mm), iris `uv`,
`rrel`, `reflectance` (NaN = dead ray).

## 4. Rasterising the ghosts

Realflare hand-rolls a binned software rasteriser because OpenCL has no raster pipeline —
**wgpu has one, so we use it** (deviation D3, the big simplification). Structure:

1. **Quad pass** (compute, one thread per grid cell per ghost×λ): read the cell's four
   corner rays; a cell with any dead corner is culled. Cell energy
   `E = area_launch / max(area_landed, min_area)` where `area_landed` is the shoelace area
   of the landed quad and `min_area` stops edge cells burning to infinity (realflare's
   `min_area`, fixed at 1% of the launch cell). Store per-cell E.
2. **Vertex pass** (compute, one thread per cell corner): write a duplicated-vertex
   buffer — 4 vertices per cell, each carrying sensor position (→ NDC via
   `screen_transform = raster_width / sensor_half_diag`, so framing is
   resolution-independent and Half preview matches Full), iris uv, rrel, reflectance, and
   an intensity that **averages the energies of the ≤ 4 live cells sharing that corner**
   (realflare's neighbour smoothing, kept — without it cell edges band visibly). A culled
   cell's four vertices park off-screen at zero intensity, which is what makes duplicated
   vertices worth their memory: per-cell culling without dynamic index buffers.
3. **Draw** (render pass): one static index buffer (two triangles per cell), one
   instanced-style concatenated vertex buffer for all ghosts × λ, additive blend
   (ONE/ONE) into an fp16 flare buffer cleared to black. Fragment:
   `ghost_disc(uv) · smoothstep(1.0, 0.95, rrel) · intensity · reflectance · cie_rgb(λ) ·
   ghost_intensity / n_λ`.
4. **Combine** (compute, the Glow-combine shape): `out = orig + master_intensity ·
   (flare(p′) + starburst(p″))` where `p′` applies the anamorphic squeeze about the frame
   centre and `p″` the starburst sprite's inverse placement affine (position at the
   light, scale, rotation, squeeze). Alpha saturates at `min(1, a + …)`; Mix lerps
   against `orig`. Intensity 0 (or Mix 0) short-circuits to the bit-exact input, the
   standard neutral-point contract, pinned by test.

Draft quality renders the flare buffer at half raster size and the combine upsamples
bilinearly — the flare is all soft gradients, so half res is visually free and quarters
the fill cost.

## 5. The bake (CPU, cached)

Everything below is a pure function of (lens_model, fstop, blades, roundness,
aperture_rotation, aperture_softness, starburst params, quality), rebuilt only when one
of those changes, cached in the `FxEngine` behind a short-held mutex (never held across a
submit; on a miss the bake computes outside the lock — a racing double-bake is harmless
because the function is pure). Animating the *light position or intensities* never
rebakes; animating *blades* does (documented: the aperture group is cheap to animate at
256², but it is a per-keyframe rebake).

- **Aperture image** (256² f32): the blade polygon as `sdf = max_i(dot(axis_i, p))` over
  `blades` axes, a sine bulge `+ roundness · sin(blade_gradient · π)`, and
  `1 − smoothstep(1 − softness, 1 + softness, sdf)`. Realflare's `aperture_shape` kernel,
  on the CPU.
- **Ghost disc** (512² f32): the fractional Fourier transform of the aperture at order
  `α = 0.15 · (λ_mid/400) · (fstop/18)` — [Ritschel 2009] §3.3's "ringing pattern", the
  softly diffraction-ringed disc a defocused iris projects. FRFT per Ozaktas: normalise α
  into [0.5, 1.5) with whole FFT/flip steps, then the chirp-multiply / FFT / chirp
  decomposition (realflare's `frft.py`, ported). Needs one in-house complex radix-2 FFT
  (`fx/fft.rs`): power-of-two sizes only, iterative Cooley–Tukey, ~80 lines, tested
  against DFT identities — no dependency for a bake that runs on parameter change.
- **Starburst sprite** (256² RGB f32): per [Ritschel 2009] §4: `F = FFT(A · e^{iπ/(λd)
  (x²+y²)})` at λ_mid, pattern `= |F|` — the **amplitude**, not the power `|F|²`
  (deviation D6: the power spectrum's DC core sits orders of magnitude above the blade
  streaks, so after normalisation the spikes vanish; amplitude keeps them at a displayable
  ~1e-2 of the core, which is how reference starbursts read — the core clips to white
  either way) — then per output pixel integrate ~100 spectral samples — each sample reads the pattern at the pixel scaled by `λ/λ_mid` (diffraction
  grows with wavelength → rainbow rim), accumulated with the CIE XYZ weight of its λ (the stochastic Softness
  jitter and Rotation smear were removed with their parameters, K-257 — the
  spectral integration is the smear), then
  XYZ→working-RGB. The jitter hash is the fixed `fract(sin(dot))` lattice realflare uses —
  deterministic, no seed parameter, identical on every machine.
- **CIE tables** (`fx/cie.rs`): the 1931 2° observer at 5 nm over [390, 730], and the
  XYZ → linear-Rec.709 matrix (the working space's primaries — realflare targets ACES AP1
  instead; deviation D4, ours must match the compositor).
- **Ghost list**: §2's enumeration + probe ranking.

The GPU consumes the baked buffers as uploaded textures; the CPU reference reads them
directly. One bake, two consumers — the textures cannot disagree.

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

## 7. Traps (learned from the reference, do not rediscover)

- **`min_area` is load-bearing.** Without it, a caustic-focused cell's energy `1/area`
  explodes into fireflies. Realflare clamps at `min_area · area_launch`; keep 0.01.
- **Vignette clip must be smooth.** A hard `rrel > 1` cut aliases along the clip edge;
  the `smoothstep(1.0, 0.95, rrel)` feather is the fix (realflare's `fragment_shader`).
- **Dead rays are NaN, not zero.** A zero-reflectance ray still carries a valid position
  (a legitimately dark ghost); death is positional (missed a surface, TIR). Realflare
  poisons `reflectance = NaN` and culls in the prim shader; we cull whole cells in the
  quad pass. Never let a NaN position reach the vertex buffer — park culled vertices at a
  finite off-screen constant.
- **The iris skips refraction.** It is a stop, not a surface; realflare `continue`s past
  it. Refracting there doubles up the medium walk and bends the whole trace.
- **Backward walks index the *previous* medium by direction.** `n1` comes from
  `lens[id − 1]` going forward but `lens[id + 1]` going backward (realflare's `n_index`
  select on `dir.z`); getting this wrong looks *almost* right, which is why it is listed.
- **fp16 accumulation is fine, fp16 trace is not.** The flare buffer is rgba16float
  (peaks ~10³, well under 65504) but every trace quantity is f32 — a 14-surface refract
  chain in half precision visibly warps ghosts.
- **The aperture roundness bulge must peak at the CORNERS.** The blade-polygon SDF is a
  max-of-dots; roundness adds a per-blade sine bulge, and realflare's `+ 0.5` phase lands
  that bulge mid-edge — which *pinches the iris into a star* instead of rounding it
  (realflare defaults roundness to 0 and never sees it; found by bake dump). Drop the
  phase offset so the bulge pulls the corners in.
- **The FRFT branches on α.** Ozaktas normalisation changes the transform applied for
  small α (extra inverse FFT); the ghost-disc α at ordinary f-stops sits near 0.1–0.5, so
  the branch *is* exercised — test both sides.

## 8. Test plan

Alongside the feature (docs/14 §10.2), in `lumit-core` unless noted:

1. **FFT**: forward-then-inverse round-trips within 1e-5; a known 8-point DFT matches the
   direct sum; Parseval's identity holds.
2. **FRFT**: α = 1 equals the plain FFT (through the normalisation); the branch below
   α = 0.5 runs and round-trips.
3. **Optics units**: Cauchy reproduces n_d exactly and n_F − n_C = (n_d − 1)/V within
   1e-6; `refract` matches Snell at normal and 45° incidence; `fresnel` at normal
   incidence equals ((n1−n2)/(n1+n2))²; `fresnel_ar` with coating thickness 0 degrades
   to plain Fresnel within 1e-4; sphere intersection hits a known circle at the exact
   analytic point.
4. **Ghost enumeration**: the 6-element model yields the closed-form pair count with no
   pair straddling the iris; ranking is deterministic across two runs.
5. **Trace oracle (lumit-gpu)**: the WGSL trace's ray buffer read back agrees with the
   CPU trace ray-for-ray — mean sensor-position error < 0.02 mm and 99th-percentile
   < 0.5 mm — deliberately no absolute max: near a caustic fold a few-ULP difference
   legitimately lands a single ray on the other branch, millimetres away (measured on the
   dev RTX: mean ~2e-3, single-ray worst ~9 on the 26-surface cine prime) — UV and rrel likewise at
   the 99th percentile (1e-3 / 0.02), reflectance at the 99th percentile within 5% relative (2e-2 absolute floor) — the coating formula runs through tan() poles at grazing incidence, where a physically invisible reflectance is hugely sensitive — over light
   positions × lenses × wavelengths, with live/dead agreement on ≥ 99% of rays. Not
   ULP-exact: GPU transcendental builtins (sin, asin, acos, tan) are not correctly
   rounded, Fresnel runs through them, and a 26-surface f32 walk compounds rounding — a
   porting bug moves the MEAN by orders of magnitude, which is what the bound pins; the
   frame oracle (below) is the visual-agreement gate.
6. **Frame oracle (lumit-gpu, the K-256 staged bound)**: GPU frame vs CPU scanline
   reference at 128²: mean |Δ| ≤ 2e-3 linear and total energy within 1%, on ≥ 3 light
   positions × 2 lenses. Not per-pixel ULP — hardware fill rules differ legitimately at
   triangle edges.
7. **Neutral points**: Intensity 0 and Mix 0 are bit-exact passthroughs on both paths
   (the standard pin); a zeroed Ghost intensity + Starburst intensity likewise.
8. **Determinism**: two renders of one frame are byte-identical (no wall-clock anywhere;
   the bake cache warm/cold paths produce identical output).
9. **Resolution independence**: the flare at 128² up-sampled matches the flare at 256²
   structurally (positions scale, per §2.3 — a loose perceptual assertion, not ULP).
10. **Regression net**: the resolve arm defaults (a fresh instance resolves to the
    documented defaults); schema/version participate in the cache key.
