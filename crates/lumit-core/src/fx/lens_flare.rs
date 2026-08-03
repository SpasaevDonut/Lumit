//! The Lens flare effect's engine-pure core (docs/08 §3.27,
//! docs/impl/lens-flare.md, K-256): the optics maths (the exact CPU twin the
//! WGSL trace must match ray-for-ray), the parameter-change bake (aperture,
//! FRFT ghost disc, spectral starburst — all CPU, cached by the GPU side),
//! and the CPU reference renderer the §1.6 staged oracle compares against.
//!
//! In plain terms: this file is the physics. It knows how a ray bends at a
//! glass surface, how much of it reflects (and in what colour, once the
//! anti-reflective coating interferes with itself), which two-bounce paths
//! through a lens produce ghosts, and what the iris does to light that
//! diffracts around it. The GPU runs the same maths fast; this is the
//! readable copy that the tests hold it to.

use super::cie;
use super::fft::{fft2_inplace, fftshift2, frft2, Cx};
use super::lens_data::{LensModel, LENS_MODELS};

/// The resolved Lens flare parameter bundle (docs/08 §3.27): plain numbers
/// both the CPU reference and the GPU pipeline consume, so preview and
/// export match (K-031). Positions are fractions of the processed raster
/// (0..1 inside frame; off-frame values are legal and meaningful).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LensFlareParams {
    /// Light position as a fraction of the raster (x right, y down);
    /// 0.5, 0.5 is frame centre. May leave [0, 1] — an off-frame light
    /// keeps flaring.
    pub light: [f32; 2],
    /// Master gain on everything the effect adds; 0 is the neutral point
    /// (bit-exact passthrough, pinned by test).
    pub intensity: f32,
    /// Index into [`LENS_MODELS`] (clamped by the resolve step).
    pub lens: u32,
    /// The working f-stop: scales the ghost discs (wider = bigger) and the
    /// ghost disc's diffraction ringing.
    pub fstop: f32,
    /// Iris blade count, 3..=16 (host-rounded).
    pub blades: u32,
    /// Iris rotation, degrees.
    pub aperture_rotation_deg: f32,
    /// 0..1: bulges the blade edges toward a circle.
    pub roundness: f32,
    /// 0..1: softens the iris edge (and with it every ghost's rim).
    pub aperture_softness: f32,
    /// Gain on the ghost train alone.
    pub ghost_intensity: f32,
    /// How many of the brightest-ranked ghosts render, 0..=200.
    pub max_ghosts: u32,
    /// Scales each traced wavelength's offset from the spectrum midpoint:
    /// 0 = monochrome trace (no fringing), 1 = physical, 2 = doubled.
    pub dispersion: f32,
    /// 0..1: blends every reflection from plain Fresnel (uncoated, bright
    /// neutral ghosts) toward quarter-wave coating interference (dim,
    /// colour-cast ghosts).
    pub coating: f32,
    /// Gain on the starburst alone.
    pub starburst_intensity: f32,
    /// Scale of the WHOLE flare about the optical centre (ghost train and
    /// starburst together); 1 is natural size.
    pub scale: f32,
    /// Coating character preset (docs/08 §3.27): the lambda-c assignment
    /// pattern. 0 Modern multicoat, 1 Vintage single coat, 2 Warm bias,
    /// 3 Cool bias. A bake input.
    pub coating_preset: u32,
    /// Where the light comes from: 0 Manual (the light point above),
    /// 1 Matte (bright sources detected in a referenced layer), 2 Lights
    /// (prepared for light layers; resolves as Manual until they land).
    pub source: u32,
    /// Matte mode: linear luma at/above which a detected source flares fully
    /// (open above; a soft gate, see `threshold_softness`).
    pub threshold: f32,
    /// Matte mode: half-width of the soft gate around the threshold.
    pub threshold_softness: f32,
    /// Horizontal stretch of the whole flare about the frame centre
    /// (1 = spherical, 1.33/2 = anamorphic looks).
    pub anamorphic: f32,
    /// 0 Draft, 1 Normal, 2 High, 3 Ultra (ray grid and wavelength count;
    /// Draft renders the flare buffer at half resolution).
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

/// Per-quality ray-grid side, traced wavelength count, and flare-buffer
/// scale divisor (docs/08 §3.27's Quality ladder).
pub fn quality_ladder(quality: u32) -> (u32, u32, u32) {
    match quality {
        0 => (16, 4, 2),
        2 => (80, 16, 1),
        3 => (128, 32, 1),
        _ => (48, 8, 1),
    }
}

/// The full-frame sensor the trace projects onto, mm (fixed: the lens
/// prescriptions are all full-frame stills/cine designs).
pub const SENSOR_MM: [f32; 2] = [36.0, 24.0];

/// Baked texture side for the ghost disc and aperture (power of two — the
/// FFTs need it).
pub const DISC_RES: u32 = 512;
/// Baked starburst sprite side (power of two).
pub const STARBURST_RES: u32 = 256;
/// Spectral samples integrated into the starburst bake.
pub const STARBURST_SAMPLES: u32 = 100;
/// The empirical energy scale that makes a default ghost train read well at
/// default Intensity (realflare's own `intensity * 1e3` constant, re-tuned
/// for the normalised disc texture and the Y-normalised wavelength weights;
/// set by eye against the reference renders, not derived).
pub const GHOST_ENERGY_SCALE: f32 = 1.0;
/// Floor on a landed quad's area as a fraction of its launch area — stops
/// caustic-focused cells burning to infinity (the impl note §7 trap).
pub const MIN_AREA_FRAC: f32 = 0.01;

/// Most flare sources a frame renders (Matte mode's top-K cap; Manual is one).
pub const MAX_LIGHTS: usize = 8;
/// Detection tile side, raster pixels (impl note §6).
pub const DETECT_TILE: u32 = 32;
/// Non-max suppression radius, in tiles (Chebyshev): one highlight must not
/// spend the whole light budget on its own neighbouring tiles.
pub const SUPPRESS_TILES: i64 = 2;

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

/// Manual mode's light list: one white source at the parameter position.
pub fn manual_light(p: &LensFlareParams) -> Vec<FlareLight> {
    vec![FlareLight {
        pos: p.light,
        rgb: [1.0, 1.0, 1.0],
    }]
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
pub fn detect_lights(
    matte: &[f32],
    w: u32,
    h: u32,
    threshold: f32,
    softness: f32,
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
        out.push(FlareLight {
            pos: [(px as f32 + 0.5) / w as f32, (py as f32 + 0.5) / h as f32],
            rgb: [
                matte[i].max(0.0) * weight,
                matte[i + 1].max(0.0) * weight,
                matte[i + 2].max(0.0) * weight,
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

/// One optical surface, flattened for the trace: the Cauchy pair replaces
/// (n_d, V) so no per-ray fitting happens, and the iris flag/coating ride
/// along. Mirrored field-for-field by the WGSL struct.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FlareSurface {
    /// Signed sphere radius, mm; 0 = flat.
    pub radius_mm: f32,
    /// Sphere-centre z (flat: plane z), mm — precomputed running offset.
    pub center_z_mm: f32,
    /// Housing half-height, mm.
    pub height_mm: f32,
    /// Cauchy A (dimensionless); 1.0 for air.
    pub cauchy_a: f32,
    /// Cauchy B, µm²; 0 for air.
    pub cauchy_b: f32,
    /// The quarter-wave coating's tuned wavelength, nm (0 on the iris and
    /// sensor rows, where no reflection happens).
    pub coating_nm: f32,
    /// 1.0 on the iris surface, else 0.0.
    pub is_iris: f32,
    /// 1.0 on the appended sensor surface, else 0.0.
    pub is_sensor: f32,
}

/// A ray landed on the sensor (or dead): the trace's per-ray output, and
/// the exact struct the WGSL trace writes. `reflectance` is NaN for a dead
/// ray (missed a surface, total internal reflection) — death is positional,
/// not zero-brightness (impl note §7).
#[derive(Debug, Clone, Copy)]
pub struct TracedRay {
    /// Sensor-plane position, mm (y up).
    pub pos_mm: [f32; 2],
    /// Iris crossing, normalised to the iris height (the ghost-disc UV).
    pub uv: [f32; 2],
    /// Worst relative housing height along the walk; > 1 = vignetted.
    pub rrel: f32,
    /// Accumulated reflectance of the two bounces; NaN = dead.
    pub reflectance: f32,
}

/// Everything the bake produces: pure function of the bake-relevant subset
/// of [`LensFlareParams`] (see [`bake_key`]), consumed by the GPU (uploaded
/// once, cached) and by the CPU reference directly — one bake, two
/// consumers, so the textures cannot disagree.
#[derive(Debug, Clone)]
pub struct FlareBaked {
    /// The trace surface table: the lens front-to-back plus the appended
    /// sensor row.
    pub surfaces: Vec<FlareSurface>,
    /// Index of the iris surface.
    pub aperture_index: u32,
    /// Ranked two-bounce ghost pairs, brightest first, already capped is
    /// NOT applied here — the frame slices the first `max_ghosts`.
    pub ghosts: Vec<[u32; 2]>,
    /// Launch-square side, mm (the ray grid's extent at the front element).
    pub launch_mm: f32,
    /// Focal length, mm (the light-direction z).
    pub focal_mm: f32,
    /// The auto-exposure gain (see [`bake`]): multiplies every ghost's
    /// energy so all bundled lenses read comparably at default Intensity.
    pub energy_gain: f32,
    /// The ghost-disc texture (FRFT ringing), `DISC_RES`², max-normalised.
    pub disc: Vec<f32>,
    /// The starburst sprite, `STARBURST_RES`² × RGB, energy-normalised.
    pub starburst: Vec<f32>,
}

// ---------------------------------------------------------------------------
// Optics primitives — the exact maths the WGSL trace mirrors op-for-op.
// ---------------------------------------------------------------------------

/// Cauchy dispersion pair from a prescription's (n_d, V) — impl note §1
/// deviation D1. Returns (A, B[µm²]); air (n ≤ 1 or V ≤ 0) is (n_d, 0).
pub fn cauchy_from_abbe(n_d: f32, v: f32) -> (f32, f32) {
    if n_d <= 1.0 || v <= 0.0 {
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

/// Plain unpolarised Fresnel reflectance at incidence `theta0` between
/// media `n1` → `n2` (realflare's `fresnel`).
pub fn fresnel(theta0: f32, n1: f32, n2: f32) -> f32 {
    let s = (theta0.sin() * n1 / n2).clamp(-1.0, 1.0);
    let theta1 = s.asin();
    let (ci, ct) = (theta0.cos(), theta1.cos());
    let rs = (n1 * ci - n2 * ct) / (n1 * ci + n2 * ct);
    let rp = (n1 * ct - n2 * ci) / (n1 * ct + n2 * ci);
    (rs * rs + rp * rp) / 2.0
}

/// Single-layer anti-reflective coating reflectance ([Ritschel et al. 2009]
/// supplemental; realflare's `fresnel_ar`): incidence `theta0`, ray
/// wavelength `lambda_nm`, coating thickness `d_nm`, media `n0` (outer),
/// `n1` (coating), `n2` (inner).
pub fn fresnel_ar(theta0: f32, lambda_nm: f32, d_nm: f32, n0: f32, n1: f32, n2: f32) -> f32 {
    let theta1 = (theta0.sin() * n0 / n1).clamp(-1.0, 1.0).asin();
    let theta2 = (theta0.sin() * n0 / n2).clamp(-1.0, 1.0).asin();

    let rs01 = -(theta0 - theta1).sin() / (theta0 + theta1).sin();
    let rp01 = (theta0 - theta1).tan() / (theta0 + theta1).tan();
    let ts01 = 2.0 * theta1.sin() * theta0.cos() / (theta0 + theta1).sin();
    let tp01 = ts01 * (theta0 - theta1).cos();

    let rs12 = -(theta1 - theta2).sin() / (theta1 + theta2).sin();
    let rp12 = (theta1 - theta2).tan() / (theta1 + theta2).tan();

    let ris = ts01 * ts01 * rs12;
    let rip = tp01 * tp01 * rp12;

    let dy = d_nm * n1;
    let dx = theta1.tan() * dy;
    let delay = (dx * dx + dy * dy).sqrt();
    let rel_phase = 4.0 * std::f32::consts::PI / lambda_nm * (delay - dx * theta0.sin());

    let out_s2 = rs01 * rs01 + ris * ris + 2.0 * rs01 * ris * rel_phase.cos();
    let out_p2 = rp01 * rp01 + rip * rip + 2.0 * rp01 * rip * rel_phase.cos();
    (out_s2 + out_p2) / 2.0
}

/// Snell refraction in vector form (realflare's `refract`): incidence `i`
/// and normal `n` unit vectors, `o = n1/n2`. Total internal reflection
/// returns the zero vector (the caller's dir.z == 0 death sentinel).
pub fn refract3(i: [f32; 3], n: [f32; 3], o: f32) -> [f32; 3] {
    let cost = -(i[0] * n[0] + i[1] * n[1] + i[2] * n[2]);
    let sint2 = o * o * (1.0 - cost * cost);
    let k = o * cost - (1.0 - sint2).abs().sqrt();
    let live = if sint2 < 1.0 { 1.0 } else { 0.0 };
    [
        (o * i[0] + k * n[0]) * live,
        (o * i[1] + k * n[1]) * live,
        (o * i[2] + k * n[2]) * live,
    ]
}

/// Mirror reflection of incidence `i` about unit normal `n`.
pub fn reflect3(i: [f32; 3], n: [f32; 3]) -> [f32; 3] {
    let d = -(i[0] * n[0] + i[1] * n[1] + i[2] * n[2]);
    [
        i[0] + 2.0 * d * n[0],
        i[1] + 2.0 * d * n[1],
        i[2] + 2.0 * d * n[2],
    ]
}

/// A ray–surface intersection: position, unit normal, incidence angle.
struct Hit {
    pos: [f32; 3],
    normal: [f32; 3],
    incident: f32,
    hit: bool,
}

/// Intersect a ray with one surface (flat plane or sphere), realflare's
/// `intersect` verbatim.
fn intersect(pos: [f32; 3], dir: [f32; 3], s: &FlareSurface) -> Hit {
    let dead = Hit {
        pos: [0.0; 3],
        normal: [0.0, 0.0, 1.0],
        incident: 0.0,
        hit: false,
    };
    if dir[2] == 0.0 {
        return dead;
    }
    if s.radius_mm == 0.0 {
        // Flat plane at z = −center.
        let dz = -s.center_z_mm - pos[2];
        let t = dz / dir[2];
        let p = [
            pos[0] + dir[0] * t,
            pos[1] + dir[1] * t,
            pos[2] + dir[2] * t,
        ];
        let n = if dir[2] < 0.0 {
            [0.0, 0.0, 1.0]
        } else {
            [0.0, 0.0, -1.0]
        };
        return Hit {
            pos: p,
            normal: n,
            incident: 0.0,
            hit: true,
        };
    }
    // Sphere centred at (0, 0, −center) with radius |r|.
    let r = s.radius_mm.abs();
    let c = [0.0, 0.0, -s.center_z_mm];
    let u = [c[0] - pos[0], c[1] - pos[1], c[2] - pos[2]];
    let du = u[0] * dir[0] + u[1] * dir[1] + u[2] * dir[2];
    let u1 = [dir[0] * du, dir[1] * du, dir[2] * du];
    let perp = [u[0] - u1[0], u[1] - u1[1], u[2] - u1[2]];
    let d = (perp[0] * perp[0] + perp[1] * perp[1] + perp[2] * perp[2]).sqrt();
    if d > r {
        return dead;
    }
    let sgn = if s.radius_mm * dir[2] > 0.0 {
        -1.0
    } else {
        1.0
    };
    let m = (r * r - d * d).sqrt();
    let p = [
        pos[0] + u1[0] - m * dir[0] * sgn,
        pos[1] + u1[1] - m * dir[1] * sgn,
        pos[2] + u1[2] - m * dir[2] * sgn,
    ];
    let mut n = [p[0] - c[0], p[1] - c[1], p[2] - c[2]];
    let len = (n[0] * n[0] + n[1] * n[1] + n[2] * n[2]).sqrt().max(1e-12);
    n = [n[0] / len * sgn, n[1] / len * sgn, n[2] / len * sgn];
    let cosi = (-(dir[0] * n[0] + dir[1] * n[1] + dir[2] * n[2])).clamp(-1.0, 1.0);
    Hit {
        pos: p,
        normal: n,
        incident: cosi.acos(),
        hit: true,
    }
}

/// The light direction for a light at `light` (raster fraction, y down) on
/// a lens of `focal_mm`, aspect `h/w` — realflare's `update_direction`,
/// normalised. Sensor y is up, so the y fraction flips sign.
pub fn light_direction(light: [f32; 2], aspect_h_over_w: f32, focal_mm: f32) -> [f32; 3] {
    let half_w = SENSOR_MM[0] / 2.0;
    let x = (light[0] * 2.0 - 1.0) * half_w;
    let y = -(light[1] * 2.0 - 1.0) * aspect_h_over_w * half_w;
    let v = [-x, -y, -focal_mm];
    let len = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt().max(1e-12);
    [v[0] / len, v[1] / len, v[2] / len]
}

/// Trace one ray of the launch grid through one ghost path — the CPU twin
/// the WGSL trace must match within 2 f32 ULP (impl note §8.5). `cell` is
/// the ray's (x, y) on a `grid`-sided launch square of `launch_mm`;
/// `ghost` the two bounce surface indices; `coating_mix` the 0..1 Coating
/// blend; `dir` the (unit) light direction.
pub fn trace_ray(
    baked: &FlareBaked,
    ghost: [u32; 2],
    lambda_nm: f32,
    cell: [u32; 2],
    grid: u32,
    coating_mix: f32,
    dir: [f32; 3],
) -> TracedRay {
    let dead = TracedRay {
        pos_mm: [0.0; 2],
        uv: [0.0; 2],
        rrel: 0.0,
        reflectance: f32::NAN,
    };
    let surfaces = &baked.surfaces;
    let count = surfaces.len();
    if count < 3 {
        return dead;
    }

    // Launch-grid point, mapped onto the first surface by a straight −z
    // probe, then backed up one unit along the true direction (realflare's
    // `init_ray`).
    let g = grid.max(2) as f32;
    let px = baked.launch_mm * (cell[0] as f32 / (g - 1.0) - 0.5);
    let py = baked.launch_mm * (0.5 - cell[1] as f32 / (g - 1.0));
    let probe = intersect([px, py, 1.0], [0.0, 0.0, -1.0], &surfaces[0]);
    if !probe.hit {
        return dead;
    }
    let mut pos = [
        probe.pos[0] - dir[0],
        probe.pos[1] - dir[1],
        probe.pos[2] - dir[2],
    ];
    let mut rdir = dir;
    let mut uv = [0.0_f32; 2];
    let mut rrel = 0.0_f32;
    let mut reflectance = 1.0_f32;

    let mut step = 0i32;
    let mut delta = 1i64;
    let mut lens_id = 0i64;
    // Bounded walk: forward, back after bounce one, forward after bounce
    // two — at most ~3× the surface count, so the loop cannot run away.
    let max_iters = count * 4;
    let mut iters = 0usize;
    while (0..count as i64).contains(&lens_id) {
        iters += 1;
        if iters > max_iters {
            return dead;
        }
        let s = surfaces[lens_id as usize];
        let hit = intersect(pos, rdir, &s);
        if !hit.hit {
            return dead;
        }
        pos = hit.pos;

        if s.is_iris > 0.5 {
            uv = [pos[0] / s.height_mm, pos[1] / s.height_mm];
            lens_id += delta;
            continue;
        }
        let r = (pos[0] * pos[0] + pos[1] * pos[1]).sqrt() / s.height_mm;
        rrel = rrel.max(r);

        if s.is_sensor > 0.5 {
            lens_id += delta;
            continue;
        }

        let do_reflect =
            (step == 0 && lens_id == ghost[0] as i64) || (step == 1 && lens_id == ghost[1] as i64);
        if do_reflect {
            step += 1;
            delta = -delta;
        }

        // Previous medium by travel direction (impl note §7's backward-walk
        // trap): the medium the ray is leaving.
        let n_index = if rdir[2] < 0.0 {
            lens_id - 1
        } else {
            lens_id + 1
        };
        let n1 = if (0..count as i64).contains(&n_index) {
            let ns = surfaces[n_index as usize];
            cauchy_ior(ns.cauchy_a, ns.cauchy_b, lambda_nm)
        } else {
            1.0
        };
        let n2 = cauchy_ior(s.cauchy_a, s.cauchy_b, lambda_nm);

        if do_reflect {
            rdir = reflect3(rdir, hit.normal);
            let theta = hit.incident + 1e-9;
            let plain = fresnel(theta, n1, n2);
            let r = if coating_mix > 0.0 && s.coating_nm > 0.0 {
                // Optimal single-layer index √(n1·n2), floored at MgF₂'s
                // 1.38; quarter-wave thickness at the surface's tuned λ.
                let nc = (n1 * n2).sqrt().max(1.38);
                let d = s.coating_nm / (4.0 * nc);
                let coated = fresnel_ar(theta, lambda_nm, d, n1, nc, n2);
                plain + (coated - plain) * coating_mix
            } else {
                plain
            };
            if r > 0.0 {
                reflectance *= r;
            }
        } else {
            rdir = refract3(rdir, hit.normal, n1 / n2);
            if rdir[2] == 0.0 {
                return dead;
            }
        }
        lens_id += delta;
    }
    if lens_id < count as i64 {
        return dead;
    }
    TracedRay {
        pos_mm: [pos[0], pos[1]],
        uv,
        rrel,
        reflectance,
    }
}

// ---------------------------------------------------------------------------
// Bake
// ---------------------------------------------------------------------------

/// The bake-relevant parameter subset hashed into the cache key: everything
/// the baked textures / tables depend on, quantised through `to_bits` so
/// equal floats key equally. Light position, intensities, dispersion,
/// coating, quality and mix are frame-time inputs and deliberately absent —
/// animating them never rebakes.
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
    fold(p.coating_preset);
    h
}

/// The lens model a params bundle selects (index clamped into the library).
pub fn lens_of(p: &LensFlareParams) -> &'static LensModel {
    let i = (p.lens as usize).min(LENS_MODELS.len() - 1);
    &LENS_MODELS[i]
}

/// Deterministic per-surface coating tuning wavelengths (impl note §1
/// deviation D2), one cycle per Coating preset (docs/08 §3.27): the pattern
/// sets the ghost train's colour character. Cycled by surface index.
const COATING_CYCLES: [&[f32]; 7] = [
    // Modern multicoat: staggered across the band — varied casts.
    &[440.0, 480.0, 520.0, 560.0, 600.0],
    // Vintage single coat: one tuning everywhere — the uniform amber/magenta
    // cast of an early coated lens.
    &[550.0],
    // Warm bias: tuned short, so the reflections it fails to kill are long —
    // amber ghosts.
    &[430.0, 455.0, 480.0],
    // Cool bias: tuned long — blue ghosts.
    &[580.0, 610.0, 640.0],
    // Amber single coat: uniformly short — the deep amber cast of early
    // magnesium-fluoride coatings.
    &[465.0],
    // Two-tone vintage: alternating short/long — the blue-and-amber pairs
    // mid-century lenses show.
    &[480.0, 620.0],
    // Broad multicoat: six tunings across the whole band — maximum variety.
    &[420.0, 465.0, 510.0, 555.0, 600.0, 645.0],
];

/// The cycle for a stored preset index (unknown values read as Modern).
fn coating_cycle(preset: u32) -> &'static [f32] {
    COATING_CYCLES[(preset as usize).min(COATING_CYCLES.len() - 1)]
}

/// Build the flat surface table for a model: running z offsets, Cauchy
/// pairs, coating wavelengths, and the appended sensor row.
fn build_surfaces(model: &LensModel, coating_preset: u32) -> Vec<FlareSurface> {
    let cycle = coating_cycle(coating_preset);
    let mut out = Vec::with_capacity(model.surfaces.len() + 1);
    let mut offset = 0.0_f32;
    for (i, s) in model.surfaces.iter().enumerate() {
        let (a, b) = cauchy_from_abbe(s.ior_d, s.abbe_v);
        let is_iris = i == model.aperture_index;
        out.push(FlareSurface {
            radius_mm: s.radius_mm,
            center_z_mm: offset + s.radius_mm,
            height_mm: s.height_mm.max(1e-3),
            cauchy_a: a,
            cauchy_b: b,
            coating_nm: if is_iris { 0.0 } else { cycle[i % cycle.len()] },
            is_iris: if is_iris { 1.0 } else { 0.0 },
            is_sensor: 0.0,
        });
        offset += s.thickness_mm;
    }
    // The sensor: a flat, housing-wide plane at the running offset.
    let sensor_half_norm = (SENSOR_MM[0] * SENSOR_MM[0] + SENSOR_MM[1] * SENSOR_MM[1]).sqrt() / 2.0;
    out.push(FlareSurface {
        radius_mm: 0.0,
        center_z_mm: offset,
        height_mm: sensor_half_norm,
        cauchy_a: 1.0,
        cauchy_b: 0.0,
        coating_nm: 0.0,
        is_iris: 0.0,
        is_sensor: 1.0,
    });
    out
}

/// Every legal two-bounce ghost pair for a model: `b2 < b1`, both strictly
/// inside the element run, both on the same side of the iris (realflare's
/// `ray_paths`).
pub fn enumerate_ghosts(model: &LensModel) -> Vec<[u32; 2]> {
    let count = model.surfaces.len();
    let mut ghosts = Vec::new();
    let mut index_min = 0usize;
    for b1 in 1..count.saturating_sub(1) {
        if b1 == model.aperture_index {
            index_min = b1 + 1;
        }
        for b2 in index_min..b1 {
            ghosts.push([b1 as u32, b2 as u32]);
        }
    }
    ghosts
}

/// The procedural iris image (realflare's `aperture_shape` on the CPU):
/// blade-polygon SDF + roundness bulge + softness smoothstep, `res`².
pub fn bake_aperture(p: &LensFlareParams, res: u32) -> Vec<f32> {
    let n = res as usize;
    let mut img = vec![0.0_f32; n * n];
    let blades = p.blades.clamp(3, 16) as i32;
    let rot = p.aperture_rotation_deg.to_radians();
    let softness = (p.aperture_softness / 10.0).max(1e-4);
    // The iris fills 0.75 of the texture's half-extent (realflare's default
    // shape size), leaving rim room for the FRFT ringing.
    let size = 0.75_f32;
    for y in 0..n {
        for x in 0..n {
            let ndc_x = 2.0 * (x as f32 / (n - 1) as f32) - 1.0;
            let ndc_y = 2.0 * (y as f32 / (n - 1) as f32) - 1.0;
            let (px, py) = (ndc_x / size, ndc_y / size);
            // Rotate (realflare's `rot`: x·c + y·s, y·c − x·s).
            let (s, c) = (rot.sin(), rot.cos());
            let (px, py) = (px * c + py * s, py * c - px * s);
            let mut sdf = 0.0_f32;
            for i in 0..blades {
                let ang = (i as f32 / blades as f32 + 0.25) * std::f32::consts::TAU;
                sdf = sdf.max(ang.cos() * px + ang.sin() * py);
            }
            // Roundness pulls the polygon's CORNERS in toward a circle: the
            // sine bulge must peak at the corners (between blade axes), so
            // the phase drops realflare's +0.5 — with it, the bulge lands
            // mid-edge and pinches the iris into a star (verified by bake
            // dump; realflare defaults roundness to 0 and never sees it).
            let circular = (-px).atan2(-py) / std::f32::consts::TAU + 0.5;
            let blade_grad = (circular * blades as f32).rem_euclid(1.0);
            sdf += (blade_grad * std::f32::consts::PI).sin() * p.roundness;
            let t = ((sdf - (1.0 - softness)) / (2.0 * softness)).clamp(0.0, 1.0);
            img[y * n + x] = 1.0 - t * t * (3.0 - 2.0 * t);
        }
    }
    img
}

/// The ghost-disc texture: the FRFT "ringing pattern" of the aperture at
/// `alpha = 0.15 · (λ_mid/400) · (fstop/18)` ([Ritschel 2009] §3.3), max-
/// normalised so per-ghost brightness stays with the energy terms.
pub fn bake_ghost_disc(aperture: &[f32], res: u32, fstop: f32) -> Vec<f32> {
    let n = res as usize;
    let alpha = 0.15 * (cie::LAMBDA_MID as f64 / 400.0) * (fstop.max(0.1) as f64 / 18.0);
    let mut cx: Vec<Cx> = aperture.iter().map(|&v| Cx::new(v as f64, 0.0)).collect();
    fftshift2(&mut cx, n, n);
    frft2(&mut cx, n, n, alpha);
    fftshift2(&mut cx, n, n);
    let mut disc: Vec<f32> = cx.iter().map(|z| z.norm_sq().sqrt() as f32).collect();
    let peak = disc.iter().fold(0.0_f32, |m, &v| m.max(v)).max(1e-9);
    for v in disc.iter_mut() {
        *v /= peak;
    }
    disc
}

/// The starburst sprite: the aperture's Fourier amplitude under the Fresnel
/// propagation term, integrated over the visible spectrum with the chromatic
/// scale `λ_mid/λ`, CIE-weighted into linear working RGB ([Ritschel 2009]
/// §4–5). The spectral integration is the only smear — the old stochastic
/// blur jitter speckled and was removed with its parameter (owner pass 2).
/// Peak-normalised so blade edits keep overall brightness.
pub fn bake_starburst(aperture: &[f32], res: u32) -> Vec<f32> {
    let n = res as usize;
    // Pattern: |fftshift(fft(A · e^{iπ/(λd)(x²+y²)}))|², λ_mid, d = 1 m.
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
                // sample position shrinks by λ_mid/λ (realflare's `scale`).
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
    // Energy-normalise: the brightest texel becomes 1, the intensity dials
    // own the rest.
    let peak = out.iter().fold(0.0_f32, |m, &v| m.max(v)).max(1e-9);
    for v in out.iter_mut() {
        *v /= peak;
    }
    out
}

/// The mean flare-buffer brightness the auto-exposure steers every lens
/// toward, measured by actually rendering the CPU reference at thumbnail
/// size inside the bake (K-258). Every cheaper proxy tried — per-cell probe
/// medians, on-sensor probe flux — mispredicted some lens by orders of
/// magnitude, because ghost energy depends on where a design's caustics
/// land at the render framing; the closed loop cannot. Calibrated so the
/// default cine prime keeps its tuned look.
const TARGET_PROBE_MEAN: f32 = 0.010;

/// Run the full bake for a params bundle — pure, deterministic, CPU-only.
/// Ghosts are ranked brightest-first by a 5×5 probe trace at a reference
/// off-axis angle, using the render's own energy term (launch cell area ÷
/// landed cell area, min-area floored) per probe cell; a ghost's brightness
/// proxy is its live cells' median energy. Ties break by pair order so the
/// ranking is deterministic. The same probe drives the **auto-exposure
/// gain**: lens designs legitimately differ by ~1000× in ghost focus, so a
/// per-bake gain steers the top ghosts' median brightness to a fixed target
/// — every bundled lens reads well at default Intensity, and the relative
/// brightness *between* a lens's own ghosts stays physical.
pub fn bake(p: &LensFlareParams) -> FlareBaked {
    let model = lens_of(p);
    let surfaces = build_surfaces(model, p.coating_preset);
    // The launch square covers the WHOLE front element with margin: side =
    // 2.3 × its half-height (the clear diameter is 2×, plus 15% so edge rays
    // exist to vignette). An undersized square is visible in the picture — a
    // ghost's boundary becomes the square's image instead of the housing's
    // feathered clip (K-258; the owner's screenshot caught exactly that
    // rectangle). Rays beyond the housing die cheaply in the trace.
    let front_h = model.surfaces.first().map(|s| s.height_mm).unwrap_or(25.0);
    let launch_mm = front_h.max(1.0) * 2.3;
    let mut baked = FlareBaked {
        surfaces,
        aperture_index: model.aperture_index as u32,
        ghosts: Vec::new(),
        launch_mm,
        focal_mm: model.focal_length_mm,
        energy_gain: 1.0,
        disc: Vec::new(),
        starburst: Vec::new(),
    };

    let ghosts = enumerate_ghosts(model);
    let dir = light_direction([0.35, 0.4], 1.0, baked.focal_mm);
    const PROBE: u32 = 5;
    let cell_mm = baked.launch_mm / (PROBE - 1) as f32;
    let cell_area = cell_mm * cell_mm;
    let min_area = MIN_AREA_FRAC * cell_area;
    let mut ranked: Vec<([u32; 2], f32, f32)> = ghosts
        .iter()
        .map(|&g| {
            let mut rays = [[TracedRay {
                pos_mm: [0.0; 2],
                uv: [0.0; 2],
                rrel: 0.0,
                reflectance: f32::NAN,
            }; PROBE as usize]; PROBE as usize];
            for (cy, row) in rays.iter_mut().enumerate() {
                for (cx, r) in row.iter_mut().enumerate() {
                    *r = trace_ray(
                        &baked,
                        g,
                        cie::LAMBDA_MID,
                        [cx as u32, cy as u32],
                        PROBE,
                        0.0,
                        dir,
                    );
                }
            }
            // Only cells that LAND ON THE SENSOR count (with a small
            // margin): a ghost can carry bright probe cells that never reach
            // the frame and would otherwise read as exposure it does not
            // deliver (K-258 — the Petzval did exactly that).
            let sensor_reach =
                (SENSOR_MM[0] * SENSOR_MM[0] + SENSOR_MM[1] * SENSOR_MM[1]).sqrt() / 2.0 * 1.2;
            let mut energies: Vec<f32> = Vec::new();
            let mut flux = 0.0_f32;
            for cy in 0..(PROBE - 1) as usize {
                for cx in 0..(PROBE - 1) as usize {
                    let c = [
                        rays[cy][cx],
                        rays[cy][cx + 1],
                        rays[cy + 1][cx + 1],
                        rays[cy + 1][cx],
                    ];
                    if c.iter().all(|r| r.reflectance.is_finite()) {
                        let e = |a: [f32; 2], b: [f32; 2], q: [f32; 2]| {
                            (a[0] - b[0]) * (q[1] - a[1]) - (a[1] - b[1]) * (q[0] - a[0])
                        };
                        let a0 = e(c[0].pos_mm, c[1].pos_mm, c[2].pos_mm);
                        let a1 = e(c[0].pos_mm, c[2].pos_mm, c[3].pos_mm);
                        let area = ((a0 + a1) / 2.0).abs().max(min_area);
                        let centre_x =
                            (c[0].pos_mm[0] + c[1].pos_mm[0] + c[2].pos_mm[0] + c[3].pos_mm[0])
                                / 4.0;
                        let centre_y =
                            (c[0].pos_mm[1] + c[1].pos_mm[1] + c[2].pos_mm[1] + c[3].pos_mm[1])
                                / 4.0;
                        if (centre_x * centre_x + centre_y * centre_y).sqrt() <= sensor_reach {
                            let en = cell_area / area;
                            energies.push(en);
                            flux += en;
                        }
                    }
                }
            }
            energies.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
            let brightness = if energies.len() >= 3 {
                energies[energies.len() / 2]
            } else {
                0.0
            };
            (g, brightness, flux)
        })
        .collect();
    // Descending brightness; ties by pair order (deterministic).
    ranked.sort_by(|a, b| {
        b.1.partial_cmp(&a.1)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(a.0.cmp(&b.0))
    });
    baked.ghosts = ranked.into_iter().map(|(g, _, _)| g).collect();

    let aperture = bake_aperture(p, DISC_RES);
    baked.disc = bake_ghost_disc(&aperture, DISC_RES, p.fstop);
    let sb_aperture = if STARBURST_RES == DISC_RES {
        aperture
    } else {
        bake_aperture(p, STARBURST_RES)
    };
    baked.starburst = bake_starburst(&sb_aperture, STARBURST_RES);

    // Closed-loop auto exposure (K-258): render the reference thumbnail with
    // gain 1 at FIXED frame-time settings — only bake-key inputs may steer
    // the gain, or animating a frame-time dial would rebake — and normalise
    // the mean to the target. Deterministic, and a few milliseconds.
    baked.energy_gain = 1.0;
    let probe_frame = LensFlareParams {
        light: [0.33, 0.30],
        intensity: 1.0,
        lens: p.lens,
        fstop: p.fstop,
        blades: p.blades,
        aperture_rotation_deg: p.aperture_rotation_deg,
        roundness: p.roundness,
        aperture_softness: p.aperture_softness,
        ghost_intensity: 1.0,
        max_ghosts: 32,
        dispersion: 1.0,
        coating: 0.6,
        starburst_intensity: 0.0,
        scale: 1.0,
        coating_preset: p.coating_preset,
        source: 0,
        threshold: 1.0,
        threshold_softness: 0.25,
        anamorphic: 1.0,
        quality: 0,
        background: 0,
        mix: 1.0,
    };
    let (pw, ph) = (96u32, 54u32);
    let thumb = cpu_flare(&probe_frame, &baked, pw, ph, &manual_light(&probe_frame));
    let mean: f32 = thumb.iter().sum::<f32>() / thumb.len().max(1) as f32;
    baked.energy_gain = if mean > 1e-9 {
        (TARGET_PROBE_MEAN / mean).clamp(0.02, 400.0)
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

/// The ghost-disc UV scale for the working f-stop (realflare's
/// `ghost_scale = 1 − fstop/32`, floored so extreme stops keep a disc).
pub fn ghost_disc_scale(fstop: f32) -> f32 {
    (1.0 - fstop / 32.0).clamp(0.05, 1.0)
}

/// Raster pixels per sensor mm for a `w`-wide target (realflare's
/// `screen_transform`): resolution-independent framing (§2.3).
pub fn screen_transform(w: u32) -> f32 {
    let half_norm = (SENSOR_MM[0] * SENSOR_MM[0] + SENSOR_MM[1] * SENSOR_MM[1]).sqrt() / 2.0;
    w as f32 / half_norm
}

// ---------------------------------------------------------------------------
// CPU reference renderer (the §1.6 staged oracle's frame side; not a
// production path — the CPU degradation rung renders the effect as identity,
// the K-114/K-256 pattern).
// ---------------------------------------------------------------------------

/// One rasterisation vertex (matches the WGSL vertex buffer): raster
/// position, disc UV, RGB-weighted intensity, housing rrel.
#[derive(Debug, Clone, Copy)]
struct FlareVertex {
    pos: [f32; 2],
    uv: [f32; 2],
    rgb: [f32; 3],
    rrel: f32,
}

/// Render the ghost train alone into an RGB flare buffer (`w × h × 3`),
/// mirroring the GPU's trace → quad energy → corner average → two-triangle
/// raster chain, once per live light in `lights` (Manual mode passes
/// [`manual_light`]; Matte mode the [`detect_lights`] top-K). Used by tests
/// and small enough to read as the spec of the GPU path.
pub fn cpu_flare(
    p: &LensFlareParams,
    baked: &FlareBaked,
    w: u32,
    h: u32,
    lights: &[FlareLight],
) -> Vec<f32> {
    let mut out = vec![0.0_f32; (w * h * 3) as usize];
    let (grid, lambda_count, _) = quality_ladder(p.quality);
    let ghost_count = (p.max_ghosts as usize).min(baked.ghosts.len());
    if ghost_count == 0 || p.ghost_intensity <= 0.0 {
        return out;
    }
    let weights = lambda_weights(lambda_count, p.dispersion);
    let aspect = h as f32 / w.max(1) as f32;
    let st = screen_transform(w);
    let disc_scale = ghost_disc_scale(p.fstop);
    let g = grid as usize;
    let cell_mm = baked.launch_mm / (grid.max(2) - 1) as f32;
    let area_launch = cell_mm * cell_mm;
    let min_area = MIN_AREA_FRAC * area_launch;
    let energy = GHOST_ENERGY_SCALE * p.ghost_intensity * baked.energy_gain;

    let disc_res = DISC_RES as usize;
    let disc_sample = |u: f32, v: f32| -> f32 {
        // uv arrives iris-normalised in [−1, 1]; scale by the f-stop disc,
        // then into texture space, clamped.
        let tu = ((u / disc_scale) + 1.0) / 2.0;
        let tv = ((v / disc_scale) + 1.0) / 2.0;
        if !(0.0..=1.0).contains(&tu) || !(0.0..=1.0).contains(&tv) {
            return 0.0;
        }
        let fx = tu * (disc_res - 1) as f32;
        let fy = tv * (disc_res - 1) as f32;
        let x0 = fx.floor() as usize;
        let y0 = fy.floor() as usize;
        let x1 = (x0 + 1).min(disc_res - 1);
        let y1 = (y0 + 1).min(disc_res - 1);
        let (tx, ty) = (fx - x0 as f32, fy - y0 as f32);
        let a = baked.disc[y0 * disc_res + x0] * (1.0 - tx) + baked.disc[y0 * disc_res + x1] * tx;
        let b = baked.disc[y1 * disc_res + x0] * (1.0 - tx) + baked.disc[y1 * disc_res + x1] * tx;
        a * (1.0 - ty) + b * ty
    };

    let mut rays = vec![
        TracedRay {
            pos_mm: [0.0; 2],
            uv: [0.0; 2],
            rrel: 0.0,
            reflectance: f32::NAN,
        };
        g * g
    ];
    let mut cell_e = vec![0.0_f32; (g - 1) * (g - 1)];

    for light in lights {
        if light.rgb[0] <= 0.0 && light.rgb[1] <= 0.0 && light.rgb[2] <= 0.0 {
            continue;
        }
        let dir = light_direction(light.pos, aspect, baked.focal_mm);
        for gi in 0..ghost_count {
            let ghost = baked.ghosts[gi];
            for &(traced_nm, rgb_w) in &weights {
                // Trace the grid.
                for cy in 0..g {
                    for cx in 0..g {
                        rays[cy * g + cx] = trace_ray(
                            baked,
                            ghost,
                            traced_nm,
                            [cx as u32, cy as u32],
                            grid,
                            p.coating,
                            dir,
                        );
                    }
                }
                // Per-cell energy: launch area / landed area, dead-corner cells
                // culled (energy 0).
                for cy in 0..g - 1 {
                    for cx in 0..g - 1 {
                        let r00 = rays[cy * g + cx];
                        let r10 = rays[cy * g + cx + 1];
                        let r11 = rays[(cy + 1) * g + cx + 1];
                        let r01 = rays[(cy + 1) * g + cx];
                        let live = r00.reflectance.is_finite()
                            && r10.reflectance.is_finite()
                            && r11.reflectance.is_finite()
                            && r01.reflectance.is_finite();
                        cell_e[cy * (g - 1) + cx] = if live {
                            let e = |a: [f32; 2], b: [f32; 2], c: [f32; 2]| {
                                (a[0] - b[0]) * (c[1] - a[1]) - (a[1] - b[1]) * (c[0] - a[0])
                            };
                            let a0 = e(r00.pos_mm, r10.pos_mm, r11.pos_mm);
                            let a1 = e(r00.pos_mm, r11.pos_mm, r01.pos_mm);
                            let area = ((a0 + a1) / 2.0).abs().max(min_area);
                            area_launch / area
                        } else {
                            0.0
                        };
                    }
                }
                // Rasterise each live cell as two triangles with corner-averaged
                // energies (the GPU's exact split: (0,1,2), (0,2,3) of the
                // corners (x,y), (x+1,y), (x+1,y+1), (x,y+1)).
                for cy in 0..g - 1 {
                    for cx in 0..g - 1 {
                        if cell_e[cy * (g - 1) + cx] <= 0.0 {
                            continue;
                        }
                        let corner = |ox: usize, oy: usize| -> FlareVertex {
                            let r = rays[(cy + oy) * g + cx + ox];
                            // Average the energies of the live cells sharing
                            // this corner.
                            let (vx, vy) = (cx + ox, cy + oy);
                            let mut sum = 0.0_f32;
                            let mut count = 0u32;
                            for (nx, ny) in [
                                (vx.wrapping_sub(1), vy.wrapping_sub(1)),
                                (vx, vy.wrapping_sub(1)),
                                (vx.wrapping_sub(1), vy),
                                (vx, vy),
                            ] {
                                if nx < g - 1 && ny < g - 1 {
                                    let e = cell_e[ny * (g - 1) + nx];
                                    if e > 0.0 {
                                        sum += e;
                                        count += 1;
                                    }
                                }
                            }
                            let e_avg = if count > 0 { sum / count as f32 } else { 0.0 };
                            let refl = if r.reflectance.is_finite() {
                                r.reflectance
                            } else {
                                0.0
                            };
                            let gain = e_avg * refl * energy;
                            FlareVertex {
                                pos: [
                                    r.pos_mm[0] * st + w as f32 / 2.0,
                                    h as f32 / 2.0 - r.pos_mm[1] * st,
                                ],
                                uv: r.uv,
                                rgb: [
                                    rgb_w[0] * gain * light.rgb[0],
                                    rgb_w[1] * gain * light.rgb[1],
                                    rgb_w[2] * gain * light.rgb[2],
                                ],
                                rrel: r.rrel,
                            }
                        };
                        let v = [corner(0, 0), corner(1, 0), corner(1, 1), corner(0, 1)];
                        for tri in [[0usize, 1, 2], [0, 2, 3]] {
                            raster_triangle(
                                &mut out,
                                w,
                                h,
                                [v[tri[0]], v[tri[1]], v[tri[2]]],
                                &disc_sample,
                            );
                        }
                    }
                }
            }
        }
    }
    out
}

/// Scanline-rasterise one triangle with barycentric attribute interpolation
/// into the additive RGB buffer — the CPU twin of the hardware fill (agreeing
/// to the impl note §8.6 perceptual bound, not per-pixel ULP).
fn raster_triangle(
    out: &mut [f32],
    w: u32,
    h: u32,
    v: [FlareVertex; 3],
    disc_sample: &dyn Fn(f32, f32) -> f32,
) {
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
            let u = w0 * v[0].uv[0] + w1 * v[1].uv[0] + w2 * v[2].uv[0];
            let vv = w0 * v[0].uv[1] + w1 * v[1].uv[1] + w2 * v[2].uv[1];
            let rrel = w0 * v[0].rrel + w1 * v[1].rrel + w2 * v[2].rrel;
            // Housing feather: full inside 0.95, gone at 1.0.
            let t = ((1.0 - rrel) / 0.05).clamp(0.0, 1.0);
            let clip = t * t * (3.0 - 2.0 * t);
            let d = disc_sample(u, vv);
            if d <= 0.0 || clip <= 0.0 {
                continue;
            }
            let i = ((y as u32 * w + x as u32) * 3) as usize;
            out[i] += (w0 * v[0].rgb[0] + w1 * v[1].rgb[0] + w2 * v[2].rgb[0]) * d * clip;
            out[i + 1] += (w0 * v[0].rgb[1] + w1 * v[1].rgb[1] + w2 * v[2].rgb[1]) * d * clip;
            out[i + 2] += (w0 * v[0].rgb[2] + w1 * v[1].rgb[2] + w2 * v[2].rgb[2]) * d * clip;
        }
    }
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
