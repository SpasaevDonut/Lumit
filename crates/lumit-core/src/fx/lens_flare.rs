//! Lens flare — the physically-based built-in (docs/08-EFFECTS.md §3.27,
//! docs/impl/lens-flare.md; K-256..K-261).
//!
//! In plain terms: a camera lens is a stack of glass surfaces with an iris
//! somewhere in the middle. A tiny fraction of the light reflects off the
//! inside of one surface, bounces backward, reflects off another, and lands
//! on the sensor anyway — one faint "ghost" per such two-bounce pair. This
//! module simulates that literally, in the FlareSim manner (K-261): for each
//! light source it fires a quasi-random spray of parallel rays across the
//! front of a real lens prescription, refracts each ray surface by surface
//! (reflecting at the pair's two surfaces), and SPLATS every survivor onto
//! the sensor as a point of light. Brightness is ray density — where the
//! optics focus rays into folds and rims, many rays land on the same pixel
//! and it burns bright; nothing is a drawn shape. The starburst is separate
//! physics (diffraction at the iris) and stays a baked Fourier sprite.
//!
//! The bake (pure CPU, cached by [`bake_key`]) parses the selected
//! prescription, enumerates and ranks every ghost pair, measures each pair's
//! defocus spread, renders a thumbnail to close the auto-exposure loop, and
//! bakes the starburst. The per-frame splat runs on the GPU with this CPU
//! implementation as its reference (§1.6 staged oracle, K-114 pattern for
//! the CPU rung).

use super::cie;
use super::fft::{fft2_inplace, fftshift2, Cx};
use super::lens_library::LENS_LIBRARY;

/// Resolved Lens flare parameters (docs/08 §3.27).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LensFlareParams {
    /// Light position in RASTER PIXELS (px@comp converted through the §2.3
    /// preview factor at resolve, the Transform-anchor convention — K-260;
    /// point parameters are pixels, never % of frame). May leave the frame —
    /// an off-frame light keeps flaring.
    pub light: [f32; 2],
    /// Master gain on everything the effect adds; 0 is the neutral point
    /// (bit-exact passthrough, pinned by test).
    pub intensity: f32,
    /// Index into [`LENS_LIBRARY`] (clamped by the resolve step).
    pub lens: u32,
    /// The working f-stop: stops the iris down from the lens's native
    /// f-number (scales the stop and the pupil mask together).
    pub fstop: f32,
    /// Focus distance, metres (K-260): shifts the sensor plane by the
    /// thin-lens image shift `f²/(1000·d − f)` mm. Real flares change shape
    /// dramatically with focus. Frame-time (animatable, no rebake); large
    /// values are infinity.
    pub focus_m: f32,
    /// Iris blade count, 3..=16 (host-rounded).
    pub blades: u32,
    /// Iris rotation, degrees.
    pub aperture_rotation_deg: f32,
    /// 0..1: blends the blade polygon toward a circle.
    pub roundness: f32,
    /// 0..1: softens the iris edge (feathers the pupil mask and with it
    /// every ghost's rim).
    pub aperture_softness: f32,
    /// Gain on the ghost train alone.
    pub ghost_intensity: f32,
    /// Softens the rendered ghosts (K-261): a box-blur radius as a
    /// percentage of the frame diagonal (3 passes approximate a Gaussian).
    /// This is FlareSim's Ghost Blur — a touch of out-of-focus softness
    /// that also hides the point-splat grain at lower qualities.
    pub ghost_softness: f32,
    /// How many of the brightest-ranked ghost pairs render, 0..=200.
    pub max_ghosts: u32,
    /// Scales each traced wavelength's offset from the spectrum midpoint:
    /// 0 = monochrome trace (no fringing), 1 = physical, 2 = doubled.
    pub dispersion: f32,
    /// 0..1: blends every reflection from plain Fresnel (uncoated, bright
    /// neutral ghosts) toward the prescription's own anti-reflective
    /// coating (K-261: per-surface MgF₂ layer counts from the lens file).
    pub coating: f32,
    /// Gain on the starburst alone.
    pub starburst_intensity: f32,
    /// Scale of the WHOLE flare about the optical centre (ghost train and
    /// starburst together); 1 is natural size.
    pub scale: f32,
    /// Where the light comes from: 0 Manual (the light point above),
    /// 1 Matte (bright sources detected in a referenced layer), 2 Lights
    /// (prepared for light layers; resolves as Manual until they land).
    pub source: u32,
    /// Matte mode: linear luma at/above which a detected source flares fully
    /// (open above; a soft gate, see `threshold_softness`).
    pub threshold: f32,
    /// Matte mode: half-width of the soft gate around the threshold.
    pub threshold_softness: f32,
    /// Scene-linear RGB multiplying every light's colour, in every source
    /// mode (K-259): in Manual it *is* the flare's colour (the light is
    /// otherwise white); in Matte it tints what the sources contribute.
    pub light_tint: [f32; 3],
    /// Matte/Lights: whether a detected source's own colour tints its flare.
    /// Off, every source flares white through [`Self::light_tint`] alone —
    /// what a matte used purely as a position mask wants. Ignored in Manual
    /// (there is no source colour to take).
    pub use_source_colour: bool,
    /// Horizontal stretch of the whole flare about the frame centre
    /// (1 = spherical, 1.33/2 = anamorphic looks).
    pub anamorphic: f32,
    /// 0 Draft, 1 Normal, 2 High, 3 Ultra (pupil sample density and
    /// wavelength count; Draft renders the flare buffer at half resolution).
    pub quality: u32,
    /// 0 Transparent (the layer's own alpha carries the flare — today's
    /// behaviour), 1 Black (the output is made opaque, the flare-element-
    /// over-black export the Screen/Add workflow wants). Applies only while
    /// the effect is live: the Intensity-0 / Mix-0 passthroughs stay
    /// bit-exact whatever this holds.
    pub background: u32,
    /// 0..1.
    pub mix: f32,
}

/// Per-quality pupil grid side, traced wavelength count, and flare-buffer
/// scale divisor (docs/08 §3.27's Quality ladder). The pupil grid is the
/// Halton candidate count's square root — the accepted sample count is a
/// little under `side²` after the aperture mask.
pub fn quality_ladder(quality: u32) -> (u32, u32, u32) {
    match quality {
        0 => (24, 3, 2),
        2 => (80, 16, 1),
        3 => (128, 32, 1),
        _ => (48, 8, 1),
    }
}

/// The full-frame sensor the trace projects onto, mm (fixed: the lens
/// prescriptions are all full-frame stills/cine designs).
pub const SENSOR_MM: [f32; 2] = [36.0, 24.0];

/// Baked starburst sprite side (power of two — the FFT needs it).
pub const STARBURST_RES: u32 = 256;
/// Spectral samples integrated into the starburst bake.
pub const STARBURST_SAMPLES: u32 = 100;
/// Aperture-image side for the starburst FFT.
pub const APERTURE_RES: u32 = 256;

/// Most flare sources a frame renders (Matte mode's top-K cap; Manual is one).
pub const MAX_LIGHTS: usize = 8;
/// Detection tile side, raster pixels (impl note §6).
pub const DETECT_TILE: u32 = 32;
/// Non-max suppression radius, in tiles (Chebyshev): one highlight must not
/// spend the whole light budget on its own neighbouring tiles.
pub const SUPPRESS_TILES: i64 = 2;

/// Ghost pairs dimmer than this on the on-axis probe are dropped at bake
/// (FlareSim's `min_intensity`).
pub const PAIR_MIN_INTENSITY: f32 = 1e-7;
/// Rays start this far in front of the first surface, mm.
pub const START_Z_BACKOFF_MM: f32 = 20.0;

/// One flare source: where it sits (raster fraction) and its colour already
/// multiplied by its gate weight. Manual mode is one white light at the
/// parameter position; Matte mode is the detected top-K.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FlareLight {
    /// Position as a fraction of the raster (x right, y down).
    pub pos: [f32; 2],
    /// Source colour times gate weight; all-zero entries are dead slots.
    pub rgb: [f32; 3],
}

/// Manual mode's light list: one source at the parameter position (raster
/// pixels over the raster `w × h` — the fraction the trace consumes),
/// carrying the Light tint (white by default).
pub fn manual_light(p: &LensFlareParams, w: u32, h: u32) -> Vec<FlareLight> {
    vec![FlareLight {
        pos: [p.light[0] / w.max(1) as f32, p.light[1] / h.max(1) as f32],
        rgb: p.light_tint,
    }]
}

/// The sensor shift for a focus distance (K-260): the thin-lens image shift
/// from the infinity position, `f²/(1000·d − f)` mm, clamped so a degenerate
/// distance cannot fling the sensor. Shared by the CPU reference and the GPU
/// uniform fill.
pub fn focus_shift_mm(focus_m: f32, efl_mm: f32) -> f32 {
    if focus_m <= 0.0 {
        return 0.0;
    }
    let denom = (1000.0 * focus_m - efl_mm).max(efl_mm);
    (efl_mm * efl_mm / denom).clamp(0.0, efl_mm)
}

/// The soft threshold gate: 0 at `threshold - softness`, 1 at `threshold +
/// softness` (smoothstep-shaped); softness 0 is the hard step. Shared by the
/// CPU reference and mirrored op-for-op in the WGSL detection.
pub fn threshold_gate(luma: f32, threshold: f32, softness: f32) -> f32 {
    if softness <= 0.0 {
        return if luma >= threshold { 1.0 } else { 0.0 };
    }
    let t = ((luma - (threshold - softness)) / (2.0 * softness)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

/// Matte-mode source detection (impl note §6), the CPU twin of the WGSL
/// kernels: tile the matte into [`DETECT_TILE`]-sided cells, keep each cell's
/// brightest pixel (Rec. 709 luma of the premultiplied buffer; ties break to
/// the lowest linear index), then pick the top [`MAX_LIGHTS`] cells by luma
/// (ties to the lower cell index) with [`SUPPRESS_TILES`] Chebyshev
/// suppression, gating each through [`threshold_gate`]. Deterministic by
/// construction — no float reduction order depends on threading.
///
/// Each light's colour is `(use_source ? source rgb : white) × gate × tint`
/// (K-259), so the same function serves both "the practical's own colour
/// flares" and "this matte only says *where*".
pub fn detect_lights(
    matte: &[f32],
    w: u32,
    h: u32,
    threshold: f32,
    softness: f32,
    use_source_colour: bool,
    tint: [f32; 3],
) -> Vec<FlareLight> {
    if w == 0 || h == 0 || matte.len() < (w * h * 4) as usize {
        return Vec::new();
    }
    let tx = w.div_ceil(DETECT_TILE) as usize;
    let ty = h.div_ceil(DETECT_TILE) as usize;
    // Per-tile brightest pixel: (luma, linear index).
    let mut tiles: Vec<(f32, u32)> = vec![(-1.0, 0); tx * ty];
    for y in 0..h {
        for x in 0..w {
            let i = ((y * w + x) * 4) as usize;
            let luma = 0.2126 * matte[i] + 0.7152 * matte[i + 1] + 0.0722 * matte[i + 2];
            let t = (y / DETECT_TILE) as usize * tx + (x / DETECT_TILE) as usize;
            if luma > tiles[t].0 {
                tiles[t] = (luma, y * w + x);
            }
        }
    }
    let mut suppressed = vec![false; tx * ty];
    let mut out = Vec::new();
    for _ in 0..MAX_LIGHTS {
        let mut best: Option<usize> = None;
        for (t, &(luma, _)) in tiles.iter().enumerate() {
            if suppressed[t] || luma <= 0.0 {
                continue;
            }
            match best {
                Some(b) if tiles[b].0 >= luma => {}
                _ => best = Some(t),
            }
        }
        let Some(b) = best else { break };
        let (luma, idx) = tiles[b];
        let weight = threshold_gate(luma, threshold, softness);
        if weight <= 0.0 {
            // Cells are visited brightest-first, so nothing dimmer passes.
            break;
        }
        let (px, py) = (idx % w, idx / w);
        let i = (idx * 4) as usize;
        let src = if use_source_colour {
            [
                matte[i].max(0.0),
                matte[i + 1].max(0.0),
                matte[i + 2].max(0.0),
            ]
        } else {
            [1.0, 1.0, 1.0]
        };
        out.push(FlareLight {
            pos: [(px as f32 + 0.5) / w as f32, (py as f32 + 0.5) / h as f32],
            rgb: [
                src[0] * weight * tint[0],
                src[1] * weight * tint[1],
                src[2] * weight * tint[2],
            ],
        });
        let (bx, by) = ((b % tx) as i64, (b / tx) as i64);
        for sy in (by - SUPPRESS_TILES)..=(by + SUPPRESS_TILES) {
            for sx in (bx - SUPPRESS_TILES)..=(bx + SUPPRESS_TILES) {
                if sx >= 0 && sy >= 0 && (sx as usize) < tx && (sy as usize) < ty {
                    suppressed[sy as usize * tx + sx as usize] = true;
                }
            }
        }
    }
    out
}

// ---------------------------------------------------------------------------
// The lens prescription (K-261: parsed from the embedded .lens library).
// ---------------------------------------------------------------------------

/// One optical surface, flattened for the trace and mirrored field-for-field
/// by the WGSL struct. The Cauchy pair describes the medium AFTER this
/// surface (1.0/0.0 = air); `coating_layers` is the .lens coating column
/// (0 bare glass, 1 single-layer MgF₂, 2+ multicoat).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FlareSurface {
    /// Signed sphere radius, mm; 0 = flat.
    pub radius_mm: f32,
    /// Surface vertex z, mm (front vertex at 0, increasing toward sensor).
    pub z_mm: f32,
    /// Clear semi-aperture, mm — rays beyond it die.
    pub semi_ap_mm: f32,
    /// Cauchy A of the medium after this surface (1.0 = air).
    pub cauchy_a: f32,
    /// Cauchy B, µm²; 0 for air.
    pub cauchy_b: f32,
    /// AR coating layer count (as f32 for the POD mirror).
    pub coating_layers: f32,
    /// 1.0 on the aperture-stop surface, else 0.0 (the f-stop scales it).
    pub is_stop: f32,
    /// Padding (POD mirror alignment).
    pub _pad: f32,
}

/// Everything the bake produces: pure function of the bake-relevant subset
/// of [`LensFlareParams`] (see [`bake_key`]), consumed by the GPU (uploaded
/// once, cached) and by the CPU reference directly.
#[derive(Debug, Clone)]
pub struct FlareBaked {
    /// The trace surface table, front to back (no appended sensor row — the
    /// sensor plane is `sensor_z_mm`).
    pub surfaces: Vec<FlareSurface>,
    /// Sensor plane z, mm (the prescription's back focal chain).
    pub sensor_z_mm: f32,
    /// The prescription's stated focal length, mm (light direction, focus).
    pub focal_mm: f32,
    /// Native f-number (from the collection filename; estimated from the
    /// front aperture when unknown).
    pub native_fstop: f32,
    /// Front-element clear semi-aperture, mm.
    pub front_semi_ap: f32,
    /// The pupil spray's radius, mm (K-261): the entrance pupil
    /// `focal / (2 · native_fstop)` with half again as margin (ghost paths
    /// accept rays the imaging pupil rejects), clamped to the front
    /// element. Spraying the whole front bezel instead wastes most rays —
    /// the Master Prime's 63 mm bezel passes ~4% of a full-width spray.
    pub pupil_mm: f32,
    /// Ray start z, mm (in front of the first surface).
    pub start_z_mm: f32,
    /// Ranked ghost pairs, brightest first; the frame renders the first
    /// `max_ghosts`.
    pub pairs: Vec<[u32; 2]>,
    /// The auto-exposure gain (closed loop, K-258): multiplies every splat
    /// so all bundled lenses read comparably at default Intensity.
    pub energy_gain: f32,
    /// The starburst sprite, `STARBURST_RES`² × RGB, peak-normalised.
    pub starburst: Vec<f32>,
}

/// A parsed .lens prescription before flattening.
pub struct Prescription {
    /// The stated focal length, mm.
    pub focal_mm: f32,
    /// Surfaces front to back with running vertex z.
    pub surfaces: Vec<FlareSurface>,
    /// Sensor plane z (the thickness chain's end), mm.
    pub sensor_z_mm: f32,
}

/// Parse a .lens text (K-261, the FlareSim/PhotonsToPhotos format): metadata
/// lines (`name:`, `focal_length:`), then `surfaces:` rows of
/// `radius thickness ior abbe semi_ap coating` with `stop`/`inf` keywords.
/// Malformed rows are skipped; a file with under 3 surfaces is rejected.
pub fn parse_lens(text: &str) -> Option<Prescription> {
    let mut focal = 0.0_f32;
    let mut in_surfaces = false;
    let mut rows: Vec<(f32, f32, f32, f32, f32, f32, bool)> = Vec::new();
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if !in_surfaces {
            if let Some(v) = line.strip_prefix("focal_length:") {
                focal = v.trim().parse().unwrap_or(0.0);
            } else if line.starts_with("surfaces:") {
                in_surfaces = true;
            }
            continue;
        }
        let mut it = line.split_whitespace();
        let radius_tok = it.next().unwrap_or("");
        let is_stop = radius_tok.eq_ignore_ascii_case("stop");
        let radius = if is_stop || radius_tok.eq_ignore_ascii_case("inf") {
            0.0
        } else {
            match radius_tok.parse::<f32>() {
                Ok(r) => r,
                Err(_) => continue,
            }
        };
        let mut f = |d: f32| it.next().and_then(|t| t.parse::<f32>().ok()).unwrap_or(d);
        let thickness = f(0.0);
        let ior = f(1.0);
        let abbe = f(0.0);
        let semi_ap = f(0.0);
        let coating = f(0.0);
        if semi_ap <= 0.0 {
            continue;
        }
        rows.push((radius, thickness, ior, abbe, semi_ap, coating, is_stop));
    }
    if rows.len() < 3 || focal <= 0.0 {
        return None;
    }
    let mut z = 0.0_f32;
    let mut surfaces = Vec::with_capacity(rows.len());
    for &(radius, thickness, ior, abbe, semi_ap, coating, is_stop) in &rows {
        let (a, b) = cauchy_from_abbe(ior, abbe);
        surfaces.push(FlareSurface {
            radius_mm: radius,
            z_mm: z,
            semi_ap_mm: semi_ap,
            cauchy_a: a,
            cauchy_b: b,
            coating_layers: coating.max(0.0),
            is_stop: if is_stop { 1.0 } else { 0.0 },
            _pad: 0.0,
        });
        z += thickness;
    }
    Some(Prescription {
        focal_mm: focal,
        surfaces,
        sensor_z_mm: z,
    })
}

/// The library entry a params bundle selects (index clamped).
pub fn lens_entry(lens: u32) -> &'static super::lens_library::LensFile {
    let i = (lens as usize).min(LENS_LIBRARY.len() - 1);
    &LENS_LIBRARY[i]
}

/// The stop-down scale for the working f-stop against the lens's native
/// f-number: 1 wide open, smaller stopped down. Scales the stop surface's
/// semi-aperture and the pupil mask together.
pub fn fstop_scale(native_fstop: f32, fstop: f32) -> f32 {
    if native_fstop <= 0.0 || fstop <= 0.0 {
        return 1.0;
    }
    (native_fstop / fstop).clamp(0.05, 1.0)
}

// ---------------------------------------------------------------------------
// Optics primitives — the exact maths the WGSL splat kernel mirrors.
// ---------------------------------------------------------------------------

/// Cauchy dispersion pair from a prescription's (n_d, V) — impl note §1
/// deviation D1. Returns (A, B[µm²]); air (n ≤ 1 or V ≤ 0) is (n_d, 0).
pub fn cauchy_from_abbe(n_d: f32, v: f32) -> (f32, f32) {
    if n_d <= 1.0001 || v <= 0.1 {
        return (n_d.max(1.0), 0.0);
    }
    let lam_f = 0.486_13_f64; // hydrogen F line, µm
    let lam_c = 0.656_27_f64; // hydrogen C line, µm
    let lam_d = 0.587_56_f64; // helium d line, µm
    let inv = 1.0 / (lam_f * lam_f) - 1.0 / (lam_c * lam_c);
    let b = (n_d as f64 - 1.0) / (v as f64 * inv);
    let a = n_d as f64 - b / (lam_d * lam_d);
    (a as f32, b as f32)
}

/// Refractive index at `lambda_nm` from a Cauchy pair.
pub fn cauchy_ior(a: f32, b: f32, lambda_nm: f32) -> f32 {
    let um = lambda_nm * 1e-3;
    a + b / (um * um)
}

/// Unpolarised Fresnel reflectance at a dielectric interface, by incidence
/// cosine (K-261, the FlareSim formulation the WGSL mirrors).
pub fn fresnel_cos(cos_i: f32, n1: f32, n2: f32) -> f32 {
    let cos_i = cos_i.abs();
    let eta = n1 / n2;
    let sin2_t = eta * eta * (1.0 - cos_i * cos_i);
    if sin2_t >= 1.0 {
        return 1.0; // total internal reflection
    }
    let cos_t = (1.0 - sin2_t).sqrt();
    let rs = (n1 * cos_i - n2 * cos_t) / (n1 * cos_i + n2 * cos_t);
    let rp = (n2 * cos_i - n1 * cos_t) / (n2 * cos_i + n1 * cos_t);
    0.5 * (rs * rs + rp * rp)
}

/// Single-layer thin-film reflectance (Airy summation): coating index
/// `coating_n`, physical thickness `d_nm`.
pub fn coating_reflectance(
    cos_i: f32,
    n1: f32,
    n2: f32,
    coating_n: f32,
    d_nm: f32,
    lambda_nm: f32,
) -> f32 {
    let cos_i = cos_i.abs();
    let sin2_c = (n1 / coating_n) * (n1 / coating_n) * (1.0 - cos_i * cos_i);
    if sin2_c >= 1.0 {
        return fresnel_cos(cos_i, n1, n2);
    }
    let cos_c = (1.0 - sin2_c).sqrt();
    let delta = 2.0 * std::f32::consts::PI * coating_n * d_nm * cos_c / lambda_nm;
    let r01 = (n1 * cos_i - coating_n * cos_c) / (n1 * cos_i + coating_n * cos_c);
    let sin2_2 = (coating_n / n2) * (coating_n / n2) * (1.0 - cos_c * cos_c);
    if sin2_2 >= 1.0 {
        return fresnel_cos(cos_i, n1, n2);
    }
    let cos_2 = (1.0 - sin2_2).sqrt();
    let r12 = (coating_n * cos_c - n2 * cos_2) / (coating_n * cos_c + n2 * cos_2);
    let cos_2d = (2.0 * delta).cos();
    let num = r01 * r01 + r12 * r12 + 2.0 * r01 * r12 * cos_2d;
    let den = 1.0 + r01 * r01 * r12 * r12 + 2.0 * r01 * r12 * cos_2d;
    (num / den).clamp(0.0, 1.0)
}

/// Reflectance of one lens surface: uncoated Fresnel blended toward the
/// prescription's AR coating by the Coating dial. `layers` is the .lens
/// coating column: 1 = single-layer MgF₂ quarter-wave at 550 nm; each extra
/// layer quarters the residual (FlareSim's multicoat approximation).
pub fn surface_reflectance(
    cos_i: f32,
    n1: f32,
    n2: f32,
    layers: f32,
    lambda_nm: f32,
    coating_mix: f32,
) -> f32 {
    let plain = fresnel_cos(cos_i, n1, n2);
    if layers < 0.5 || coating_mix <= 0.0 {
        return plain;
    }
    const MGF2_N: f32 = 1.38;
    const DESIGN_NM: f32 = 550.0;
    let qw = DESIGN_NM / (4.0 * MGF2_N);
    let mut coated = coating_reflectance(cos_i, n1, n2, MGF2_N, qw, lambda_nm);
    let extra = (layers - 1.0).clamp(0.0, 8.0).round() as u32;
    for _ in 0..extra {
        coated *= 0.25;
    }
    (plain + (coated - plain) * coating_mix.clamp(0.0, 1.0)).clamp(0.0, 1.0)
}

/// Snell refraction in vector form: incidence `i` and normal `n` (opposing
/// the ray) unit vectors, `o = n1/n2`. Total internal reflection returns
/// None.
// Negated comparison deliberate: NaN reads as dead (see `intersect`).
#[allow(clippy::neg_cmp_op_on_partial_ord)]
pub fn refract3(i: [f32; 3], n: [f32; 3], o: f32) -> Option<[f32; 3]> {
    let cos_i = -(i[0] * n[0] + i[1] * n[1] + i[2] * n[2]);
    let sin2_t = o * o * (1.0 - cos_i * cos_i);
    if sin2_t >= 1.0 {
        return None;
    }
    let k = o * cos_i - (1.0 - sin2_t).sqrt();
    let v = [
        o * i[0] + k * n[0],
        o * i[1] + k * n[1],
        o * i[2] + k * n[2],
    ];
    let sq = v[0] * v[0] + v[1] * v[1] + v[2] * v[2];
    if !(sq > 1e-18) || !sq.is_finite() {
        return None;
    }
    let inv = 1.0 / sq.sqrt();
    Some([v[0] * inv, v[1] * inv, v[2] * inv])
}

/// Mirror reflection of incidence `i` about unit normal `n`.
pub fn reflect3(i: [f32; 3], n: [f32; 3]) -> [f32; 3] {
    let d = 2.0 * (i[0] * n[0] + i[1] * n[1] + i[2] * n[2]);
    let v = [i[0] - d * n[0], i[1] - d * n[1], i[2] - d * n[2]];
    let len = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt().max(1e-12);
    [v[0] / len, v[1] / len, v[2] / len]
}

/// Intersect a ray with one surface (K-261, the FlareSim rule): flat plane
/// at the vertex z, else ray–sphere picking the intersection closest to the
/// vertex. The clear semi-aperture clips with a 10% skirt: rays inside it
/// stay formally alive (the housing feather zeroes their weight), so quads
/// at a housing boundary fade instead of dying corner-by-corner — a
/// frame-filling defocused ghost otherwise shows its cull boundary as giant
/// staircase rectangles. Returns (hit position, normal opposing the ray) or
/// None. `semi_ap` is passed separately so the f-stop can scale the stop
/// surface without touching the table.
// The negated comparisons are deliberate: `!(t > eps)` is false for NaN, so
// a degenerate ray reads as dead instead of propagating NaN (the FlareSim
// guard style the WGSL twin mirrors).
#[allow(clippy::neg_cmp_op_on_partial_ord)]
fn intersect(
    pos: [f32; 3],
    dir: [f32; 3],
    radius: f32,
    z_mm: f32,
    semi_ap: f32,
) -> Option<([f32; 3], [f32; 3])> {
    if radius.abs() < 1e-6 {
        if dir[2].abs() < 1e-12 {
            return None;
        }
        let t = (z_mm - pos[2]) / dir[2];
        if !(t > 1e-6) {
            return None;
        }
        let hit = [
            pos[0] + dir[0] * t,
            pos[1] + dir[1] * t,
            pos[2] + dir[2] * t,
        ];
        let skirt = semi_ap * 1.1;
        if hit[0] * hit[0] + hit[1] * hit[1] > skirt * skirt {
            return None;
        }
        let n = if dir[2] > 0.0 {
            [0.0, 0.0, -1.0]
        } else {
            [0.0, 0.0, 1.0]
        };
        return Some((hit, n));
    }
    let centre = [0.0, 0.0, z_mm + radius];
    let oc = [pos[0] - centre[0], pos[1] - centre[1], pos[2] - centre[2]];
    let a = dir[0] * dir[0] + dir[1] * dir[1] + dir[2] * dir[2];
    let b = 2.0 * (oc[0] * dir[0] + oc[1] * dir[1] + oc[2] * dir[2]);
    let c = oc[0] * oc[0] + oc[1] * oc[1] + oc[2] * oc[2] - radius * radius;
    let disc = b * b - 4.0 * a * c;
    if disc < 0.0 {
        return None;
    }
    let sd = disc.sqrt();
    let inv2a = 0.5 / a;
    let t1 = (-b - sd) * inv2a;
    let t2 = (-b + sd) * inv2a;
    let t = if t1 > 1e-6 && t2 > 1e-6 {
        let z1 = pos[2] + t1 * dir[2];
        let z2 = pos[2] + t2 * dir[2];
        if (z1 - z_mm).abs() < (z2 - z_mm).abs() {
            t1
        } else {
            t2
        }
    } else if t1 > 1e-6 {
        t1
    } else if t2 > 1e-6 {
        t2
    } else {
        return None;
    };
    let hit = [
        pos[0] + dir[0] * t,
        pos[1] + dir[1] * t,
        pos[2] + dir[2] * t,
    ];
    let skirt = semi_ap * 1.1;
    if !(hit[0] * hit[0] + hit[1] * hit[1] <= skirt * skirt) {
        return None;
    }
    let inv_r = 1.0 / radius.abs();
    let mut n = [
        (hit[0] - centre[0]) * inv_r,
        (hit[1] - centre[1]) * inv_r,
        (hit[2] - centre[2]) * inv_r,
    ];
    if n[0] * dir[0] + n[1] * dir[1] + n[2] * dir[2] > 0.0 {
        n = [-n[0], -n[1], -n[2]];
    }
    Some((hit, n))
}

/// The light direction for a light at `light` (raster fraction, y down) on
/// a lens of `focal_mm`, aspect `h/w`. Sensor y is up, so the y fraction
/// flips sign; a light at the frame corner enters at the true corner field
/// angle.
pub fn light_direction(light: [f32; 2], aspect_h_over_w: f32, focal_mm: f32) -> [f32; 3] {
    let half_w = SENSOR_MM[0] / 2.0;
    let x = (light[0] * 2.0 - 1.0) * half_w;
    let y = -(light[1] * 2.0 - 1.0) * aspect_h_over_w * half_w;
    let v = [-x, -y, focal_mm];
    let len = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt().max(1e-12);
    [v[0] / len, v[1] / len, v[2] / len]
}

/// Trace one pupil sample through one ghost pair at one wavelength — the
/// FlareSim three-phase walk (K-261), the CPU twin the WGSL splat kernel
/// mirrors op-for-op. `origin` is the ray start (mm), `dir` the unit beam
/// direction; the ray transmits through every surface except the pair's
/// two, where it reflects (weight × R; transmits weight × (1−R)). Returns
/// the sensor landing (mm, y up) and the accumulated Fresnel weight.
#[allow(clippy::too_many_arguments)]
// Negated comparisons deliberate: NaN reads as dead (see `intersect`).
#[allow(clippy::neg_cmp_op_on_partial_ord)]
pub fn trace_splat(
    baked: &FlareBaked,
    pair: [u32; 2],
    lambda_nm: f32,
    origin: [f32; 3],
    dir: [f32; 3],
    coating_mix: f32,
    stop_scale: f32,
    sensor_shift_mm: f32,
) -> Option<([f32; 2], f32)> {
    let surfs = &baked.surfaces;
    let n = surfs.len();
    let (a_idx, b_idx) = (pair[0] as usize, pair[1] as usize);
    if n < 3 || a_idx >= b_idx || b_idx >= n {
        return None;
    }
    let mut pos = origin;
    let mut rdir = dir;
    let mut weight = 1.0_f32;
    let mut current_ior = 1.0_f32;
    // Worst relative aperture crossing along the walk: rays that graze a
    // housing edge fade smoothly (the 0.95..1 feather below) instead of the
    // hard clip alone — without it, a defocused ghost's cull boundary shows
    // as giant staircase quads (K-261, the K-256 rrel feather reinstated).
    let mut rrel = 0.0_f32;

    let semi_of = |s: &FlareSurface| -> f32 {
        if s.is_stop > 0.5 {
            s.semi_ap_mm * stop_scale
        } else {
            s.semi_ap_mm
        }
    };
    let ior_at = |s: &FlareSurface| cauchy_ior(s.cauchy_a, s.cauchy_b, lambda_nm);
    let ior_before = |idx: usize| -> f32 {
        if idx == 0 {
            1.0
        } else {
            ior_at(&surfs[idx - 1])
        }
    };

    // Phase 1: forward through 0..=b, reflecting at b.
    for (s_idx, s) in surfs.iter().enumerate().take(b_idx + 1) {
        let semi = semi_of(s);
        let (hit, norm) = intersect(pos, rdir, s.radius_mm, s.z_mm, semi)?;
        pos = hit;
        rrel = rrel.max((pos[0] * pos[0] + pos[1] * pos[1]).sqrt() / semi.max(1e-6));
        let n1 = current_ior;
        let n2 = ior_at(s);
        let cos_i = (norm[0] * rdir[0] + norm[1] * rdir[1] + norm[2] * rdir[2]).abs();
        let r = surface_reflectance(cos_i, n1, n2, s.coating_layers, lambda_nm, coating_mix);
        if s_idx == b_idx {
            rdir = reflect3(rdir, norm);
            weight *= r;
        } else {
            rdir = refract3(rdir, norm, n1 / n2)?;
            weight *= 1.0 - r;
            current_ior = n2;
        }
    }

    // Phase 2: backward through b-1..=a, reflecting at a.
    for s_idx in (a_idx..b_idx).rev() {
        let s = &surfs[s_idx];
        let semi = semi_of(s);
        let (hit, norm) = intersect(pos, rdir, s.radius_mm, s.z_mm, semi)?;
        pos = hit;
        rrel = rrel.max((pos[0] * pos[0] + pos[1] * pos[1]).sqrt() / semi.max(1e-6));
        let n1 = current_ior;
        let n2 = ior_before(s_idx);
        let cos_i = (norm[0] * rdir[0] + norm[1] * rdir[1] + norm[2] * rdir[2]).abs();
        let r = surface_reflectance(cos_i, n1, n2, s.coating_layers, lambda_nm, coating_mix);
        if s_idx == a_idx {
            rdir = reflect3(rdir, norm);
            weight *= r;
            current_ior = ior_at(s);
        } else {
            rdir = refract3(rdir, norm, n1 / n2)?;
            weight *= 1.0 - r;
            current_ior = n2;
        }
    }

    // Phase 3: forward through a+1..n.
    for s in surfs.iter().skip(a_idx + 1) {
        let semi = semi_of(s);
        let (hit, norm) = intersect(pos, rdir, s.radius_mm, s.z_mm, semi)?;
        pos = hit;
        rrel = rrel.max((pos[0] * pos[0] + pos[1] * pos[1]).sqrt() / semi.max(1e-6));
        let n1 = current_ior;
        let n2 = ior_at(s);
        let cos_i = (norm[0] * rdir[0] + norm[1] * rdir[1] + norm[2] * rdir[2]).abs();
        let r = surface_reflectance(cos_i, n1, n2, s.coating_layers, lambda_nm, coating_mix);
        rdir = refract3(rdir, norm, n1 / n2)?;
        weight *= 1.0 - r;
        current_ior = n2;
    }

    // Propagate to the (focus-shifted) sensor plane.
    if rdir[2].abs() < 1e-12 {
        return None;
    }
    let t = (baked.sensor_z_mm + sensor_shift_mm - pos[2]) / rdir[2];
    if !(t > 0.0) {
        return None;
    }
    let x = pos[0] + rdir[0] * t;
    let y = pos[1] + rdir[1] * t;
    if !x.is_finite() || !y.is_finite() || !weight.is_finite() {
        return None;
    }
    // Housing feather: full inside 0.95, gone at 1.0 (smoothstep).
    let ft = ((1.0 - rrel) / 0.05).clamp(0.0, 1.0);
    weight *= ft * ft * (3.0 - 2.0 * ft);
    Some(([x, y], weight))
}

// ---------------------------------------------------------------------------
// Pupil sampling (K-261): deterministic Halton spray over the front element,
// masked by the iris polygon with roundness and softness.
// ---------------------------------------------------------------------------

/// The pupil mask weight for a unit-disc point: 1 inside the iris shape,
/// feathering to 0 at the edge over `softness`. The polygon bound blends
/// toward the circle by `roundness`. Shared by the pupil grid and the
/// aperture image bake so the starburst and the ghosts agree.
pub fn pupil_mask(u: f32, v: f32, blades: u32, rot_rad: f32, roundness: f32, softness: f32) -> f32 {
    let r = (u * u + v * v).sqrt();
    let blades = blades.clamp(3, 16);
    let sector = std::f32::consts::TAU / blades as f32;
    let apothem = (std::f32::consts::PI / blades as f32).cos();
    let angle = v.atan2(u) - rot_rad;
    let mut a = angle % sector;
    if a < 0.0 {
        a += sector;
    }
    // Polygon radial bound at this angle, blended toward the unit circle.
    let poly_bound = apothem / (a - sector * 0.5).cos();
    let bound = poly_bound + (1.0 - poly_bound) * roundness.clamp(0.0, 1.0);
    let soft = (softness.clamp(0.0, 1.0) * bound).max(1e-4);
    let t = ((r - (bound - soft)) / soft).clamp(0.0, 1.0);
    1.0 - t * t * (3.0 - 2.0 * t)
}

/// The effective iris roundness for a working f-stop (K-260): wide open a
/// real iris retracts behind the housing's circular bore, so ghosts go
/// round whatever the blade count; two stops down the polygon is fully
/// back.
pub fn effective_roundness(roundness: f32, fstop: f32, native_fstop: f32) -> f32 {
    let native = native_fstop.max(0.7);
    let wide_open = (1.0 - (fstop / native - 1.0).clamp(0.0, 2.0) / 2.0).clamp(0.0, 1.0);
    roundness.max(wide_open)
}

// ---------------------------------------------------------------------------
// Bake
// ---------------------------------------------------------------------------

/// The bake-relevant parameter subset hashed into the cache key: everything
/// the baked tables depend on, quantised through `to_bits` so equal floats
/// key equally. Light position, intensities, dispersion, coating, quality
/// and mix are frame-time inputs and deliberately absent — animating them
/// never rebakes.
pub fn bake_key(p: &LensFlareParams) -> u64 {
    let mut h = 0xcbf2_9ce4_8422_2325_u64; // FNV offset basis
    let mut fold = |v: u32| {
        h ^= v as u64;
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    };
    fold(p.lens);
    fold(p.fstop.to_bits());
    fold(p.blades);
    fold(p.aperture_rotation_deg.to_bits());
    fold(p.roundness.to_bits());
    fold(p.aperture_softness.to_bits());
    h
}

/// The aperture image for the starburst FFT: the pupil mask rendered into a
/// texture (iris at 0.75 of the half-extent, leaving rim room for the
/// diffraction spread).
pub fn bake_aperture(p: &LensFlareParams, native_fstop: f32, res: u32) -> Vec<f32> {
    let n = res as usize;
    let mut img = vec![0.0_f32; n * n];
    let rot = p.aperture_rotation_deg.to_radians();
    let roundness = effective_roundness(p.roundness, p.fstop, native_fstop);
    let softness = (p.aperture_softness * 0.25).max(0.004);
    let size = 0.75_f32;
    for y in 0..n {
        for x in 0..n {
            let ndc_x = 2.0 * (x as f32 / (n - 1) as f32) - 1.0;
            let ndc_y = 2.0 * (y as f32 / (n - 1) as f32) - 1.0;
            img[y * n + x] = pupil_mask(
                ndc_x / size,
                ndc_y / size,
                p.blades,
                rot,
                roundness,
                softness,
            );
        }
    }
    img
}

/// The starburst sprite: the aperture's Fourier amplitude under the Fresnel
/// propagation term, integrated over the visible spectrum with the chromatic
/// scale `λ_mid/λ`, CIE-weighted into linear working RGB ([Ritschel 2009]
/// §4–5). Peak-normalised so blade edits keep overall brightness.
pub fn bake_starburst(aperture: &[f32], res: u32) -> Vec<f32> {
    let n = res as usize;
    // Pattern: |fftshift(fft(A · e^{iπ/(λd)(x²+y²)}))|, λ_mid, d = 1 m.
    let lambda_mm = cie::LAMBDA_MID as f64 * 1e-6;
    let d_mm = 1.0e3_f64;
    let mut cx = vec![Cx::ZERO; n * n];
    for y in 0..n {
        let ny = 2.0 * (y as f64 / (n - 1) as f64) - 1.0;
        for x in 0..n {
            let nx = 2.0 * (x as f64 / (n - 1) as f64) - 1.0;
            let arg = std::f64::consts::PI / (lambda_mm * d_mm) * (nx * nx + ny * ny);
            cx[y * n + x] = Cx::cis(arg).scale(aperture[y * n + x] as f64);
        }
    }
    fft2_inplace(&mut cx, n, n, false);
    fftshift2(&mut cx, n, n);
    // Amplitude, not power: |F| instead of |F|² — the power spectrum's DC
    // core sits orders of magnitude above the blade streaks, so after
    // normalisation the spikes vanish; the amplitude spectrum keeps them at
    // a displayable ~1e-2 of the core, which is how the reference apps'
    // starbursts read (the core clips to white either way).
    let pattern: Vec<f32> = cx.iter().map(|z| z.norm_sq().sqrt() as f32).collect();

    // Spectral integration into RGB.
    let samples = STARBURST_SAMPLES;
    let mut out = vec![0.0_f32; n * n * 3];
    let range = cie::LAMBDA_MAX - cie::LAMBDA_MIN;
    let bilinear = |u: f32, v: f32| -> f32 {
        if !(0.0..=1.0).contains(&u) || !(0.0..=1.0).contains(&v) {
            return 0.0;
        }
        let fx = u * (n - 1) as f32;
        let fy = v * (n - 1) as f32;
        let x0 = fx.floor() as usize;
        let y0 = fy.floor() as usize;
        let x1 = (x0 + 1).min(n - 1);
        let y1 = (y0 + 1).min(n - 1);
        let (tx, ty) = (fx - x0 as f32, fy - y0 as f32);
        let a = pattern[y0 * n + x0] * (1.0 - tx) + pattern[y0 * n + x1] * tx;
        let b = pattern[y1 * n + x0] * (1.0 - tx) + pattern[y1 * n + x1] * tx;
        a * (1.0 - ty) + b * ty
    };
    for y in 0..n {
        for x in 0..n {
            let ndc_x = 2.0 * (x as f32 / (n - 1) as f32) - 1.0;
            let ndc_y = 2.0 * (y as f32 / (n - 1) as f32) - 1.0;
            let mut xyz = [0.0_f32; 3];
            for k in 0..samples {
                let step = k as f32 / samples as f32;
                let lambda = cie::LAMBDA_MIN + step * range;
                // Chromatic scale: diffraction grows with wavelength, so the
                // sample position shrinks by λ_mid/λ.
                let s = lambda / cie::LAMBDA_MID;
                let px = ndc_x / s;
                let py = ndc_y / s;
                let val = bilinear(px * 0.5 + 0.5, py * 0.5 + 0.5);
                let w = cie::xyz_at(lambda);
                xyz[0] += w[0] * val;
                xyz[1] += w[1] * val;
                xyz[2] += w[2] * val;
            }
            let rgb = cie::xyz_to_linear_rgb(xyz);
            let i = (y * n + x) * 3;
            out[i] = rgb[0].max(0.0);
            out[i + 1] = rgb[1].max(0.0);
            out[i + 2] = rgb[2].max(0.0);
        }
    }
    // Peak-normalise: the brightest texel becomes 1, the intensity dials
    // own the rest.
    let peak = out.iter().fold(0.0_f32, |m, &v| m.max(v)).max(1e-9);
    for v in out.iter_mut() {
        *v /= peak;
    }
    out
}

/// The mean flare-buffer brightness the auto-exposure steers every lens
/// toward, measured by actually rendering the CPU reference at thumbnail
/// size inside the bake (K-258). Cheaper proxies mispredicted real lenses
/// by orders of magnitude; the closed loop cannot.
const TARGET_PROBE_MEAN: f32 = 0.010;

/// Run the full bake for a params bundle — pure, deterministic, CPU-only
/// (K-261): parse the prescription, enumerate and rank the ghost pairs,
/// measure per-pair defocus boosts, bake the starburst, close the exposure
/// loop.
pub fn bake(p: &LensFlareParams) -> FlareBaked {
    let entry = lens_entry(p.lens);
    let lens = parse_lens(entry.text).unwrap_or_else(|| Prescription {
        // A degenerate fallback biconvex singlet: the library is regression-
        // tested to parse in full, so this exists only to keep the engine
        // panic-free if a future import breaks a file.
        focal_mm: 50.0,
        surfaces: vec![
            FlareSurface {
                radius_mm: 50.0,
                z_mm: 0.0,
                semi_ap_mm: 15.0,
                cauchy_a: 1.5,
                cauchy_b: 0.004,
                coating_layers: 0.0,
                is_stop: 0.0,
                _pad: 0.0,
            },
            FlareSurface {
                radius_mm: 0.0,
                z_mm: 4.0,
                semi_ap_mm: 12.0,
                cauchy_a: 1.0,
                cauchy_b: 0.0,
                coating_layers: 0.0,
                is_stop: 1.0,
                _pad: 0.0,
            },
            FlareSurface {
                radius_mm: -50.0,
                z_mm: 8.0,
                semi_ap_mm: 15.0,
                cauchy_a: 1.0,
                cauchy_b: 0.0,
                coating_layers: 0.0,
                is_stop: 0.0,
                _pad: 0.0,
            },
        ],
        sensor_z_mm: 55.0,
    });
    let front_semi_ap = lens.surfaces[0].semi_ap_mm;
    let native_fstop = if entry.native_fstop > 0.0 {
        entry.native_fstop
    } else {
        (lens.focal_mm / (2.0 * front_semi_ap.max(0.1))).max(0.7)
    };
    let pupil_mm = (lens.focal_mm / (2.0 * native_fstop) * 1.5).clamp(1.0, front_semi_ap);
    let mut baked = FlareBaked {
        pupil_mm,
        start_z_mm: lens.surfaces[0].z_mm - START_Z_BACKOFF_MM,
        sensor_z_mm: lens.sensor_z_mm,
        focal_mm: lens.focal_mm,
        native_fstop,
        front_semi_ap,
        surfaces: lens.surfaces,
        pairs: Vec::new(),
        energy_gain: 1.0,
        starburst: Vec::new(),
    };

    // Enumerate every a<b pair where both surfaces actually change medium
    // (a reflection needs an interface; the stop is air-air and drops out),
    // probe each on-axis, rank by probe brightness.
    let n = baked.surfaces.len();
    let ior_at =
        |i: usize| baked.surfaces[i].cauchy_a + baked.surfaces[i].cauchy_b / (0.587_56 * 0.587_56);
    let has_interface = |i: usize| {
        let before = if i == 0 { 1.0 } else { ior_at(i - 1) };
        (before - ior_at(i)).abs() >= 0.001
    };
    let centre = [0.0, 0.0, baked.start_z_mm];
    let axis = [0.0, 0.0, 1.0];
    let mut ranked: Vec<([u32; 2], f32)> = Vec::new();
    for a in 0..n {
        if !has_interface(a) {
            continue;
        }
        for b in (a + 1)..n {
            if !has_interface(b) {
                continue;
            }
            let pair = [a as u32, b as u32];
            // On-axis brightness probe at the R/G/B wavelengths, full file
            // coating (the Coating dial is frame-time).
            let mut est = 0.0_f32;
            for nm in [650.0, 550.0, 450.0] {
                if let Some((_, w)) = trace_splat(&baked, pair, nm, centre, axis, 1.0, 1.0, 0.0) {
                    est += w;
                }
            }
            est /= 3.0;
            if est < PAIR_MIN_INTENSITY {
                continue;
            }
            ranked.push((pair, est));
        }
    }
    // Descending probe brightness; ties by pair order (deterministic).
    ranked.sort_by(|a, b| {
        b.1.partial_cmp(&a.1)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(a.0.cmp(&b.0))
    });
    baked.pairs = ranked.iter().map(|&(g, _)| g).collect();

    let aperture = bake_aperture(p, native_fstop, APERTURE_RES);
    baked.starburst = bake_starburst(&aperture, STARBURST_RES);

    // Closed-loop auto exposure (K-258): render the reference thumbnail with
    // gain 1 at FIXED frame-time settings — only bake-key inputs may steer
    // the gain, or animating a frame-time dial would rebake — and normalise
    // the mean to the target. Deterministic, and a few milliseconds.
    baked.energy_gain = 1.0;
    let probe_frame = LensFlareParams {
        // Raster pixels of the 96×54 thumbnail (the 0.33/0.30 framing).
        light: [31.7, 16.2],
        intensity: 1.0,
        lens: p.lens,
        fstop: p.fstop,
        focus_m: 100.0,
        blades: p.blades,
        aperture_rotation_deg: p.aperture_rotation_deg,
        roundness: p.roundness,
        aperture_softness: p.aperture_softness,
        ghost_intensity: 1.0,
        ghost_softness: 0.3,
        max_ghosts: 32,
        dispersion: 1.0,
        coating: 0.6,
        starburst_intensity: 0.0,
        scale: 1.0,
        source: 0,
        threshold: 1.0,
        threshold_softness: 0.25,
        light_tint: [1.0, 1.0, 1.0],
        use_source_colour: true,
        anamorphic: 1.0,
        quality: 0,
        background: 0,
        mix: 1.0,
    };
    let (pw, ph) = (96u32, 54u32);
    let thumb = cpu_flare(
        &probe_frame,
        &baked,
        pw,
        ph,
        &manual_light(&probe_frame, pw, ph),
    );
    let mean: f32 = thumb.iter().sum::<f32>() / thumb.len().max(1) as f32;
    // The gain ceiling matters (K-261): a lens whose every ghost is an
    // extreme defocused wash has almost no probe energy after the
    // giant-quad fade, and an unbounded loop would amplify the residue into
    // a lit-up artefact field. Capped, such a lens renders honestly dim —
    // a bright star and little else, which is what that glass does.
    baked.energy_gain = if mean > 1e-12 {
        (TARGET_PROBE_MEAN / mean).clamp(1e-2, 64.0)
    } else {
        1.0
    };
    baked
}

// ---------------------------------------------------------------------------
// Frame-time shared derivations (CPU reference and GPU uniforms).
// ---------------------------------------------------------------------------

/// The traced wavelengths with their linear-RGB weights. Each traced λ
/// *represents its whole band* of the visible range, so its weight is the
/// band's INTEGRAL of the colour-matching functions (sampled at 2 nm), not a
/// point sample — a 3-band ladder point-sampled at 673 nm would weigh red at
/// a tenth of its true energy and tint every flare blue-green (found by
/// eye). Brightness-normalised by ΣY so the wavelength count (a quality
/// setting) does not change exposure.
pub fn lambda_weights(count: u32, dispersion: f32) -> Vec<(f32, [f32; 3])> {
    let ladder = cie::wavelength_ladder(count as usize, dispersion);
    let band = (cie::LAMBDA_MAX - cie::LAMBDA_MIN) / count.max(1) as f32;
    let band_xyz: Vec<[f32; 3]> = (0..ladder.len())
        .map(|k| {
            let lo = cie::LAMBDA_MIN + band * k as f32;
            let mut acc = [0.0_f32; 3];
            let steps = (band / 2.0).ceil().max(1.0) as usize;
            for i in 0..steps {
                let nm = lo + band * (i as f32 + 0.5) / steps as f32;
                let w = cie::xyz_at(nm);
                acc[0] += w[0];
                acc[1] += w[1];
                acc[2] += w[2];
            }
            let inv = 1.0 / steps as f32;
            [acc[0] * inv, acc[1] * inv, acc[2] * inv]
        })
        .collect();
    let sum_y: f32 = band_xyz.iter().map(|w| w[1]).sum();
    let norm = 1.0 / sum_y.max(1e-6);
    ladder
        .iter()
        .zip(band_xyz)
        .map(|(&(traced_nm, _), xyz)| {
            let rgb = cie::xyz_to_linear_rgb(xyz);
            (
                traced_nm,
                [
                    rgb[0].max(0.0) * norm,
                    rgb[1].max(0.0) * norm,
                    rgb[2].max(0.0) * norm,
                ],
            )
        })
        .collect()
}

/// Raster pixels per sensor mm for a `w`-wide target: resolution-independent
/// framing (§2.3), matching [`light_direction`]'s half-sensor convention.
pub fn screen_transform(w: u32) -> f32 {
    w as f32 / SENSOR_MM[0]
}

// ---------------------------------------------------------------------------
// CPU reference renderer (the §1.6 staged oracle's frame side; not a
// production path — the CPU degradation rung renders the effect as identity,
// the K-114/K-256 pattern).
// ---------------------------------------------------------------------------

/// One rasterisation vertex (matches the WGSL vertex buffer): raster
/// position, RGB-weighted intensity.
#[derive(Debug, Clone, Copy)]
struct FlareVertex {
    pos: [f32; 2],
    rgb: [f32; 3],
}

/// Minimum screen area a drawn quad may have, px² (K-261). A caustic-folded
/// quad shrinks below a pixel, and a rasteriser drops triangles that cover
/// no pixel centre — deleting exactly the flux that makes a flare's bright
/// rims and fold lines. Quads below this inflate about their centroid to
/// this area with their colour scaled by (true / inflated) area, so the
/// deposited flux is conserved and every quad reliably covers samples.
pub const MIN_QUAD_PX: f32 = 4.0;

/// Floor on a landed quad's area as a fraction of its launch cell — a
/// guard against a fully-degenerate fold burning to infinity; the visual
/// cap is the screen-space inflation, not this.
pub const MIN_AREA_FRAC: f32 = 1e-4;

/// Flux-conserving screen-space floor on a quad's size (K-261, mirrored by
/// the WGSL build): a quad smaller than [`MIN_QUAD_PX`] on screen inflates
/// about its centroid to that area, its colour scaled by the true ÷
/// inflated area ratio.
fn inflate_quad(v: &mut [FlareVertex; 4]) {
    let e = |a: [f32; 2], b: [f32; 2], c: [f32; 2]| {
        (a[0] - b[0]) * (c[1] - a[1]) - (a[1] - b[1]) * (c[0] - a[0])
    };
    let a0 = e(v[0].pos, v[1].pos, v[2].pos);
    let a1 = e(v[0].pos, v[2].pos, v[3].pos);
    let area_px = ((a0 + a1) / 2.0).abs();
    if area_px >= MIN_QUAD_PX {
        return;
    }
    let eps = MIN_QUAD_PX * 1e-4;
    let s = (MIN_QUAD_PX / area_px.max(eps)).sqrt();
    let cx = (v[0].pos[0] + v[1].pos[0] + v[2].pos[0] + v[3].pos[0]) / 4.0;
    let cy = (v[0].pos[1] + v[1].pos[1] + v[2].pos[1] + v[3].pos[1]) / 4.0;
    let scale = area_px.max(eps) / MIN_QUAD_PX;
    for c in v.iter_mut() {
        c.pos[0] = cx + (c.pos[0] - cx) * s;
        c.pos[1] = cy + (c.pos[1] - cy) * s;
        for ch in &mut c.rgb {
            *ch *= scale;
        }
    }
}

/// Scanline-rasterise one triangle with barycentric colour interpolation
/// into the additive RGB buffer — the CPU twin of the hardware fill
/// (agreeing to the impl note perceptual bound, not per-pixel ULP).
fn raster_triangle(out: &mut [f32], w: u32, h: u32, v: [FlareVertex; 3]) {
    let min_x = v[0].pos[0]
        .min(v[1].pos[0])
        .min(v[2].pos[0])
        .floor()
        .max(0.0) as i64;
    let max_x = (v[0].pos[0].max(v[1].pos[0]).max(v[2].pos[0]).ceil() as i64).min(w as i64 - 1);
    let min_y = v[0].pos[1]
        .min(v[1].pos[1])
        .min(v[2].pos[1])
        .floor()
        .max(0.0) as i64;
    let max_y = (v[0].pos[1].max(v[1].pos[1]).max(v[2].pos[1]).ceil() as i64).min(h as i64 - 1);
    if min_x > max_x || min_y > max_y {
        return;
    }
    let edge = |a: [f32; 2], b: [f32; 2], px: f32, py: f32| {
        (b[0] - a[0]) * (py - a[1]) - (b[1] - a[1]) * (px - a[0])
    };
    let area = edge(v[0].pos, v[1].pos, v[2].pos[0], v[2].pos[1]);
    if area.abs() < 1e-9 {
        return;
    }
    for y in min_y..=max_y {
        for x in min_x..=max_x {
            let (px, py) = (x as f32 + 0.5, y as f32 + 0.5);
            let w0 = edge(v[1].pos, v[2].pos, px, py) / area;
            let w1 = edge(v[2].pos, v[0].pos, px, py) / area;
            let w2 = 1.0 - w0 - w1;
            if w0 < 0.0 || w1 < 0.0 || w2 < 0.0 {
                continue;
            }
            let i = ((y as u32 * w + x as u32) * 3) as usize;
            out[i] += w0 * v[0].rgb[0] + w1 * v[1].rgb[0] + w2 * v[2].rgb[0];
            out[i + 1] += w0 * v[0].rgb[1] + w1 * v[1].rgb[1] + w2 * v[2].rgb[1];
            out[i + 2] += w0 * v[0].rgb[2] + w1 * v[1].rgb[2] + w2 * v[2].rgb[2];
        }
    }
}

/// Render the ghost train alone into an RGB flare buffer (`w × h × 3`),
/// mirroring the GPU chain (K-261): a REGULAR grid of rays over the pupil
/// square is traced through each ranked pair per wavelength (the FlareSim
/// optics), and each live grid cell draws as two triangles whose density is
/// the energy-conservation ratio `launch cell area ÷ landed area` — smooth
/// noise-free ghosts, with sub-pixel fold quads inflated so caustic flux
/// survives. The iris mask (blades, roundness, softness) weights each
/// corner, which is what shapes the ghosts. Used by tests and small enough
/// to read as the spec of the GPU path.
pub fn cpu_flare(
    p: &LensFlareParams,
    baked: &FlareBaked,
    w: u32,
    h: u32,
    lights: &[FlareLight],
) -> Vec<f32> {
    let mut out = vec![0.0_f32; (w * h * 3) as usize];
    if w == 0 || h == 0 || p.ghost_intensity <= 0.0 {
        return out;
    }
    let (side, lambda_count, _) = quality_ladder(p.quality);
    let side = side.max(2) as usize;
    let weights = lambda_weights(lambda_count, p.dispersion);
    let roundness = effective_roundness(p.roundness, p.fstop, baked.native_fstop);
    let rot = p.aperture_rotation_deg.to_radians();
    let stop_scale = fstop_scale(baked.native_fstop, p.fstop);
    let sensor_shift = focus_shift_mm(p.focus_m, baked.focal_mm);
    let aspect = h as f32 / w.max(1) as f32;
    let st = screen_transform(w);
    let gain = p.ghost_intensity * baked.energy_gain;
    let pair_count = baked.pairs.len().min(p.max_ghosts as usize);

    // The pupil grid: corner (i, j) at unit coords, masked by the iris.
    let unit = |i: usize| (i as f32 / (side - 1) as f32) * 2.0 - 1.0;
    let cell_mm = 2.0 * baked.pupil_mm * stop_scale / (side - 1) as f32;
    let cell_area_px = cell_mm * cell_mm * st * st;

    // Per-corner trace results for one (pair, λ): landing px and weight
    // (Fresnel × mask); None = dead.
    let mut corners: Vec<Option<([f32; 2], f32)>> = vec![None; side * side];
    for light in lights {
        if light.rgb[0] <= 0.0 && light.rgb[1] <= 0.0 && light.rgb[2] <= 0.0 {
            continue;
        }
        let dir = light_direction(light.pos, aspect, baked.focal_mm);
        for pair in baked.pairs.iter().take(pair_count) {
            for &(nm, rgb_w) in &weights {
                for j in 0..side {
                    for i in 0..side {
                        let (u, v) = (unit(i), unit(j));
                        let mask = pupil_mask(u, v, p.blades, rot, roundness, p.aperture_softness);
                        corners[j * side + i] = if mask <= 0.0 {
                            None
                        } else {
                            let origin = [
                                u * baked.pupil_mm * stop_scale,
                                v * baked.pupil_mm * stop_scale,
                                baked.start_z_mm,
                            ];
                            trace_splat(
                                baked,
                                *pair,
                                nm,
                                origin,
                                dir,
                                p.coating,
                                stop_scale,
                                sensor_shift,
                            )
                            .map(|(pos, wt)| {
                                (
                                    [pos[0] * st + w as f32 / 2.0, h as f32 / 2.0 - pos[1] * st],
                                    wt * mask,
                                )
                            })
                        };
                    }
                }
                for j in 0..side - 1 {
                    for i in 0..side - 1 {
                        let c = [
                            corners[j * side + i],
                            corners[j * side + i + 1],
                            corners[(j + 1) * side + i + 1],
                            corners[(j + 1) * side + i],
                        ];
                        let [Some(c0), Some(c1), Some(c2), Some(c3)] = c else {
                            continue;
                        };
                        // Energy conservation: launch cell area ÷ landed
                        // area (in px² both), floored against degeneracy.
                        let e = |a: [f32; 2], b: [f32; 2], q: [f32; 2]| {
                            (a[0] - b[0]) * (q[1] - a[1]) - (a[1] - b[1]) * (q[0] - a[0])
                        };
                        let a0 = e(c0.0, c1.0, c2.0);
                        let a1 = e(c0.0, c2.0, c3.0);
                        let landed = ((a0 + a1) / 2.0).abs().max(MIN_AREA_FRAC * cell_area_px);
                        let density = cell_area_px / landed * gain;
                        let mut v: [FlareVertex; 4] = [
                            FlareVertex {
                                pos: c0.0,
                                rgb: [0.0; 3],
                            },
                            FlareVertex {
                                pos: c1.0,
                                rgb: [0.0; 3],
                            },
                            FlareVertex {
                                pos: c2.0,
                                rgb: [0.0; 3],
                            },
                            FlareVertex {
                                pos: c3.0,
                                rgb: [0.0; 3],
                            },
                        ];
                        for (vert, corner) in v.iter_mut().zip([c0, c1, c2, c3]) {
                            let b = density * corner.1;
                            vert.rgb = [
                                b * rgb_w[0] * light.rgb[0],
                                b * rgb_w[1] * light.rgb[1],
                                b * rgb_w[2] * light.rgb[2],
                            ];
                        }
                        inflate_quad(&mut v);
                        raster_triangle(&mut out, w, h, [v[0], v[1], v[2]]);
                        raster_triangle(&mut out, w, h, [v[0], v[2], v[3]]);
                    }
                }
            }
        }
    }
    blur_flare(&mut out, w, h, ghost_blur_radius(p.ghost_softness, w, h), 3);
    out
}

/// Separable box blur over an RGB buffer/// Separable box blur over an RGB buffer, `passes` times (3 passes
/// approximate a Gaussian) — FlareSim's Ghost Blur (K-261), shared by the
/// CPU reference and mirrored by the WGSL blur kernel. `radius_px` 0 is a
/// no-op.
pub fn blur_flare(buf: &mut [f32], w: u32, h: u32, radius_px: u32, passes: u32) {
    if radius_px == 0 || w == 0 || h == 0 {
        return;
    }
    let (w, h, r) = (w as usize, h as usize, radius_px as usize);
    let norm = 1.0 / (2 * r + 1) as f32;
    let mut tmp = vec![0.0_f32; buf.len()];
    for _ in 0..passes.max(1) {
        // Horizontal into tmp.
        for y in 0..h {
            for x in 0..w {
                let mut acc = [0.0_f32; 3];
                for dx in -(r as i64)..=(r as i64) {
                    let sx = (x as i64 + dx).clamp(0, w as i64 - 1) as usize;
                    let i = (y * w + sx) * 3;
                    acc[0] += buf[i];
                    acc[1] += buf[i + 1];
                    acc[2] += buf[i + 2];
                }
                let o = (y * w + x) * 3;
                tmp[o] = acc[0] * norm;
                tmp[o + 1] = acc[1] * norm;
                tmp[o + 2] = acc[2] * norm;
            }
        }
        // Vertical back into buf.
        for y in 0..h {
            for x in 0..w {
                let mut acc = [0.0_f32; 3];
                for dy in -(r as i64)..=(r as i64) {
                    let sy = (y as i64 + dy).clamp(0, h as i64 - 1) as usize;
                    let i = (sy * w + x) * 3;
                    acc[0] += tmp[i];
                    acc[1] += tmp[i + 1];
                    acc[2] += tmp[i + 2];
                }
                let o = (y * w + x) * 3;
                buf[o] = acc[0] * norm;
                buf[o + 1] = acc[1] * norm;
                buf[o + 2] = acc[2] * norm;
            }
        }
    }
}

/// The Ghost-softness blur radius in pixels for a buffer size: the dial is
/// a percentage of the frame diagonal (0.3 ≈ FlareSim's suggested 0.003).
pub fn ghost_blur_radius(softness: f32, w: u32, h: u32) -> u32 {
    let diag = ((w * w + h * h) as f32).sqrt();
    (softness.clamp(0.0, 2.0) * 0.01 * diag).round() as u32
}

/// The combine stage, mirrored by the WGSL combine kernel: `out = orig +
/// intensity · (flare(scaled · squeezed) + starbursts)`, alpha saturating
/// toward 1, Mix lerping against the untouched input. The Scale parameter
/// scales the WHOLE flare about the optical centre — the ghost buffer is
/// sampled through it, and each light's starburst sprite grows by it while
/// staying anchored on its light. `flare` is the ghost buffer at `fw × fh`
/// (Draft renders it at half size; sampling is resolution-relative so both
/// agree). Operates on the premultiplied working buffer in place.
#[allow(clippy::too_many_arguments)]
pub fn cpu_combine(
    rgba: &mut [f32],
    w: u32,
    h: u32,
    p: &LensFlareParams,
    baked: &FlareBaked,
    flare: &[f32],
    fw: u32,
    fh: u32,
    lights: &[FlareLight],
) {
    if p.intensity <= 0.0 || p.mix <= 0.0 {
        return;
    }
    let squeeze = p.anamorphic.clamp(0.25, 4.0);
    let fscale = p.scale.clamp(0.05, 20.0);
    let sb_res = STARBURST_RES as usize;
    let sb_half = 0.6 * fscale * w.min(h) as f32;
    let sample_flare = |x: f32, y: f32| -> [f32; 3] {
        // Resolution-relative bilinear tap of the flare buffer.
        let u = (x / w as f32) * fw as f32 - 0.5;
        let v = (y / h as f32) * fh as f32 - 0.5;
        let x0 = u.floor().max(0.0) as usize;
        let y0 = v.floor().max(0.0) as usize;
        let x1 = (x0 + 1).min(fw as usize - 1);
        let y1 = (y0 + 1).min(fh as usize - 1);
        let x0 = x0.min(fw as usize - 1);
        let y0 = y0.min(fh as usize - 1);
        let (tx, ty) = (
            (u - u.floor()).clamp(0.0, 1.0),
            (v - v.floor()).clamp(0.0, 1.0),
        );
        let mut rgb = [0.0_f32; 3];
        for (c, out_c) in rgb.iter_mut().enumerate() {
            let a = flare[(y0 * fw as usize + x0) * 3 + c] * (1.0 - tx)
                + flare[(y0 * fw as usize + x1) * 3 + c] * tx;
            let b = flare[(y1 * fw as usize + x0) * 3 + c] * (1.0 - tx)
                + flare[(y1 * fw as usize + x1) * 3 + c] * tx;
            *out_c = a * (1.0 - ty) + b * ty;
        }
        rgb
    };
    for y in 0..h {
        for x in 0..w {
            // Whole-flare scale plus the anamorphic squeeze (x only), both
            // about the frame centre.
            let cx = w as f32 / 2.0;
            let cyc = h as f32 / 2.0;
            let sx = cx + (x as f32 + 0.5 - cx) / (squeeze * fscale);
            let sy = cyc + (y as f32 + 0.5 - cyc) / fscale;
            let f = sample_flare(sx, sy);
            // One starburst sprite per live light, anchored on the light,
            // sized by Scale, stretched by the squeeze, tinted by the light.
            let mut sb = [0.0_f32; 3];
            if p.starburst_intensity > 0.0 && sb_half > 0.0 {
                for light in lights {
                    if light.rgb[0] <= 0.0 && light.rgb[1] <= 0.0 && light.rgb[2] <= 0.0 {
                        continue;
                    }
                    let light_px = [light.pos[0] * w as f32, light.pos[1] * h as f32];
                    let rel_x = x as f32 + 0.5 - light_px[0];
                    let rel_y = y as f32 + 0.5 - light_px[1];
                    let u = rel_x / (sb_half * squeeze) * 0.5 + 0.5;
                    let v = rel_y / sb_half * 0.5 + 0.5;
                    if !(0.0..=1.0).contains(&u) || !(0.0..=1.0).contains(&v) {
                        continue;
                    }
                    let fx = u * (sb_res - 1) as f32;
                    let fy = v * (sb_res - 1) as f32;
                    let x0 = fx.floor() as usize;
                    let y0 = fy.floor() as usize;
                    let x1 = (x0 + 1).min(sb_res - 1);
                    let y1 = (y0 + 1).min(sb_res - 1);
                    let (tx, ty) = (fx - x0 as f32, fy - y0 as f32);
                    for (c, out_c) in sb.iter_mut().enumerate() {
                        let a = baked.starburst[(y0 * sb_res + x0) * 3 + c] * (1.0 - tx)
                            + baked.starburst[(y0 * sb_res + x1) * 3 + c] * tx;
                        let b = baked.starburst[(y1 * sb_res + x0) * 3 + c] * (1.0 - tx)
                            + baked.starburst[(y1 * sb_res + x1) * 3 + c] * tx;
                        *out_c += (a * (1.0 - ty) + b * ty) * p.starburst_intensity * light.rgb[c];
                    }
                }
            }
            let add = [
                (f[0] + sb[0]) * p.intensity,
                (f[1] + sb[1]) * p.intensity,
                (f[2] + sb[2]) * p.intensity,
            ];
            let i = ((y * w + x) * 4) as usize;
            let o = [rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3]];
            let luma = 0.2126 * add[0] + 0.7152 * add[1] + 0.0722 * add[2];
            let flared = [
                o[0] + add[0],
                o[1] + add[1],
                o[2] + add[2],
                (o[3] + luma).min(1.0),
            ];
            rgba[i] = o[0] * (1.0 - p.mix) + flared[0] * p.mix;
            rgba[i + 1] = o[1] * (1.0 - p.mix) + flared[1] * p.mix;
            rgba[i + 2] = o[2] * (1.0 - p.mix) + flared[2] * p.mix;
            rgba[i + 3] = o[3] * (1.0 - p.mix) + flared[3] * p.mix;
            // Black background (K-258): the output is made opaque — laying
            // the premultiplied result over black changes nothing but alpha.
            // Only while live: the Intensity-0/Mix-0 early return above keeps
            // the passthroughs bit-exact.
            if p.background == 1 {
                rgba[i + 3] = 1.0;
            }
        }
    }
}
