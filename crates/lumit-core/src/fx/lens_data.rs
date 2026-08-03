//! The bundled lens prescription library for the Lens flare effect
//! (docs/08 Â§3.27, docs/impl/lens-flare.md Â§1, K-256). Static data, no files:
//! each model is the optical table of a real photographic lens from its
//! published patent (a patent's optical prescription is public information),
//! as bundled by the realflare reference (GPLv3, as Lumit is).
//!
//! In plain terms: each entry lists, front to back, every glass surface of a
//! real lens â€” how curved it is, how far to the next one, what glass it is
//! and how wide the housing sits. The ray trace walks this table; the number
//! and character of the ghosts you see fall straight out of it.

/// One optical surface of a lens, front to back.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LensSurface {
    /// Signed sphere radius, mm; 0 = a flat plane (the iris sits on one).
    pub radius_mm: f32,
    /// Axial distance to the next surface, mm.
    pub thickness_mm: f32,
    /// Refractive index at the d-line (587.6 nm); 1.0 = an air gap follows.
    pub ior_d: f32,
    /// Abbe number (dispersion strength); 0 for air.
    pub abbe_v: f32,
    /// Housing half-height at this surface, mm (rays beyond it vignette).
    pub height_mm: f32,
}

/// One bundled lens model: the prescription plus its identity.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LensModel {
    /// UI label (sentence case).
    pub label: &'static str,
    /// Nominal focal length, mm.
    pub focal_length_mm: f32,
    /// The lens's native (widest) f-stop; the F-stop parameter closes the
    /// iris relative to this.
    pub native_fstop: f32,
    /// Index of the iris surface in `surfaces`.
    pub aperture_index: usize,
    /// The optical table, front to back. The sensor is appended at trace
    /// time, not listed here.
    pub surfaces: &'static [LensSurface],
}

/// Color Heliar — patent 2645156 (1950).
const VINTAGE_105_SURFACES: &[LensSurface] = &[
    LensSurface {
        radius_mm: 30.809,
        thickness_mm: 7.702,
        ior_d: 1.651,
        abbe_v: 58.6,
        height_mm: 14.5,
    },
    LensSurface {
        radius_mm: -89.35,
        thickness_mm: 1.855,
        ior_d: 1.603,
        abbe_v: 38.4,
        height_mm: 14.5,
    },
    LensSurface {
        radius_mm: 580.0,
        thickness_mm: 3.521,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 14.5,
    },
    LensSurface {
        radius_mm: -80.063,
        thickness_mm: 1.849,
        ior_d: 1.643,
        abbe_v: 47.9,
        height_mm: 12.3,
    },
    LensSurface {
        radius_mm: 28.34,
        thickness_mm: 4.625,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 12.0,
    },
    LensSurface {
        radius_mm: 0.0,
        thickness_mm: 2.554,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 11.6,
    },
    LensSurface {
        radius_mm: 0.0,
        thickness_mm: 1.849,
        ior_d: 1.582,
        abbe_v: 40.6,
        height_mm: 12.3,
    },
    LensSurface {
        radius_mm: 32.19,
        thickness_mm: 7.271,
        ior_d: 1.693,
        abbe_v: 53.5,
        height_mm: 12.3,
    },
    LensSurface {
        radius_mm: -52.99,
        thickness_mm: 92.03,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 12.3,
    },
];
// label: Vintage 105mm prime, focal 105, fstop 3.5, aperture_index 5

/// 35mm 1.4 — patent US5161060 (1992).
const FAST_35_SURFACES: &[LensSurface] = &[
    LensSurface {
        radius_mm: -110.114,
        thickness_mm: 2.01,
        ior_d: 1.503,
        abbe_v: 56.1,
        height_mm: 16.0,
    },
    LensSurface {
        radius_mm: 24.92,
        thickness_mm: 7.4,
        ior_d: 1.82,
        abbe_v: 45.1,
        height_mm: 16.0,
    },
    LensSurface {
        radius_mm: -305.0,
        thickness_mm: 0.1,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 16.0,
    },
    LensSurface {
        radius_mm: 28.346,
        thickness_mm: 6.07,
        ior_d: 1.82,
        abbe_v: 45.1,
        height_mm: 12.0,
    },
    LensSurface {
        radius_mm: -57.56,
        thickness_mm: 1.61,
        ior_d: 1.694,
        abbe_v: 31.0,
        height_mm: 12.0,
    },
    LensSurface {
        radius_mm: 16.624,
        thickness_mm: 4.34,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 12.0,
    },
    LensSurface {
        radius_mm: 0.0,
        thickness_mm: 1.66,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 10.0,
    },
    LensSurface {
        radius_mm: -197.204,
        thickness_mm: 6.07,
        ior_d: 1.792,
        abbe_v: 47.2,
        height_mm: 10.0,
    },
    LensSurface {
        radius_mm: -38.628,
        thickness_mm: 1.5,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 10.0,
    },
    LensSurface {
        radius_mm: -21.142,
        thickness_mm: 1.72,
        ior_d: 1.652,
        abbe_v: 33.6,
        height_mm: 10.0,
    },
    LensSurface {
        radius_mm: 101.985,
        thickness_mm: 5.86,
        ior_d: 1.82,
        abbe_v: 45.1,
        height_mm: 10.0,
    },
    LensSurface {
        radius_mm: -21.905,
        thickness_mm: 0.11,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 10.0,
    },
    LensSurface {
        radius_mm: 60.026,
        thickness_mm: 5.94,
        ior_d: 1.82,
        abbe_v: 45.1,
        height_mm: 12.0,
    },
    LensSurface {
        radius_mm: -31.325,
        thickness_mm: 2.05,
        ior_d: 1.624,
        abbe_v: 36.1,
        height_mm: 12.0,
    },
    LensSurface {
        radius_mm: 31.325,
        thickness_mm: 19.595,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 12.0,
    },
];
// label: Fast 35mm prime, focal 35, fstop 1.4, aperture_index 6

/// Zeiss MP 50/T1.3 — patent 7446944 B2 (2008).
const CINE_50_SURFACES: &[LensSurface] = &[
    LensSurface {
        radius_mm: 554.31,
        thickness_mm: 4.31,
        ior_d: 1.69901,
        abbe_v: 30.13,
        height_mm: 35.0,
    },
    LensSurface {
        radius_mm: 82.937,
        thickness_mm: 7.67,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 35.0,
    },
    LensSurface {
        radius_mm: 2539.9,
        thickness_mm: 8.05,
        ior_d: 1.80527,
        abbe_v: 25.42,
        height_mm: 35.0,
    },
    LensSurface {
        radius_mm: -185.67,
        thickness_mm: 4.67,
        ior_d: 1.81605,
        abbe_v: 46.62,
        height_mm: 35.0,
    },
    LensSurface {
        radius_mm: -188.36,
        thickness_mm: 7.281,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 35.0,
    },
    LensSurface {
        radius_mm: 52.33,
        thickness_mm: 16.11,
        ior_d: 1.61803,
        abbe_v: 63.33,
        height_mm: 35.0,
    },
    LensSurface {
        radius_mm: 12548.0,
        thickness_mm: 0.11,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 35.0,
    },
    LensSurface {
        radius_mm: 70.795,
        thickness_mm: 4.2,
        ior_d: 1.71743,
        abbe_v: 29.62,
        height_mm: 28.0,
    },
    LensSurface {
        radius_mm: 55.033,
        thickness_mm: 2.534,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 25.0,
    },
    LensSurface {
        radius_mm: 42.474,
        thickness_mm: 4.27,
        ior_d: 1.80527,
        abbe_v: 25.42,
        height_mm: 25.0,
    },
    LensSurface {
        radius_mm: 35.481,
        thickness_mm: 7.82,
        ior_d: 1.81605,
        abbe_v: 46.62,
        height_mm: 25.0,
    },
    LensSurface {
        radius_mm: 46.639,
        thickness_mm: 4.79,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 23.0,
    },
    LensSurface {
        radius_mm: 183.02,
        thickness_mm: 4.2,
        ior_d: 1.55839,
        abbe_v: 54.01,
        height_mm: 23.0,
    },
    LensSurface {
        radius_mm: 25.119,
        thickness_mm: 9.8,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 15.0,
    },
    LensSurface {
        radius_mm: 0.0,
        thickness_mm: 9.71,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 15.0,
    },
    LensSurface {
        radius_mm: -23.041,
        thickness_mm: 4.2,
        ior_d: 1.65416,
        abbe_v: 39.63,
        height_mm: 15.0,
    },
    LensSurface {
        radius_mm: 39.525,
        thickness_mm: 16.23,
        ior_d: 1.61803,
        abbe_v: 63.33,
        height_mm: 23.0,
    },
    LensSurface {
        radius_mm: -44.668,
        thickness_mm: 0.35,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 23.0,
    },
    LensSurface {
        radius_mm: 66.473,
        thickness_mm: 10.02,
        ior_d: 1.60303,
        abbe_v: 65.44,
        height_mm: 25.0,
    },
    LensSurface {
        radius_mm: -240.57,
        thickness_mm: 0.21,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 25.0,
    },
    LensSurface {
        radius_mm: 466.39,
        thickness_mm: 7.51,
        ior_d: 1.60303,
        abbe_v: 65.44,
        height_mm: 25.0,
    },
    LensSurface {
        radius_mm: -88.45271,
        thickness_mm: 0.1,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 25.0,
    },
    LensSurface {
        radius_mm: 91.728,
        thickness_mm: 4.2,
        ior_d: 1.81605,
        abbe_v: 46.62,
        height_mm: 23.0,
    },
    LensSurface {
        radius_mm: 27.982,
        thickness_mm: 16.46,
        ior_d: 1.61803,
        abbe_v: 63.33,
        height_mm: 22.0,
    },
    LensSurface {
        radius_mm: -128.64,
        thickness_mm: 39.014,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 22.0,
    },
];
// label: Cine 50mm prime, focal 50, fstop 1.3, aperture_index 14

/// AI 50-135mm — patent US 4497547A (1981).
const TELE_ZOOM_SURFACES: &[LensSurface] = &[
    LensSurface {
        radius_mm: 95.858,
        thickness_mm: 1.7,
        ior_d: 1.805,
        abbe_v: 25.4,
        height_mm: 26.0,
    },
    LensSurface {
        radius_mm: 49.02,
        thickness_mm: 8.0,
        ior_d: 1.678,
        abbe_v: 55.6,
        height_mm: 26.0,
    },
    LensSurface {
        radius_mm: 214.552,
        thickness_mm: 0.1,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 25.0,
    },
    LensSurface {
        radius_mm: 75.769,
        thickness_mm: 5.0,
        ior_d: 1.667,
        abbe_v: 48.4,
        height_mm: 25.0,
    },
    LensSurface {
        radius_mm: 691.304,
        thickness_mm: 2.959,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 25.0,
    },
    LensSurface {
        radius_mm: -708.168,
        thickness_mm: 1.25,
        ior_d: 1.697,
        abbe_v: 55.6,
        height_mm: 15.0,
    },
    LensSurface {
        radius_mm: 22.809,
        thickness_mm: 5.0,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 13.0,
    },
    LensSurface {
        radius_mm: -175.109,
        thickness_mm: 1.15,
        ior_d: 1.788,
        abbe_v: 47.5,
        height_mm: 13.0,
    },
    LensSurface {
        radius_mm: 87.266,
        thickness_mm: 0.5,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 13.0,
    },
    LensSurface {
        radius_mm: 35.758,
        thickness_mm: 3.1,
        ior_d: 1.805,
        abbe_v: 25.4,
        height_mm: 13.0,
    },
    LensSurface {
        radius_mm: 165.776,
        thickness_mm: 27.727,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 13.0,
    },
    LensSurface {
        radius_mm: -51.423,
        thickness_mm: 1.15,
        ior_d: 1.67,
        abbe_v: 57.6,
        height_mm: 13.0,
    },
    LensSurface {
        radius_mm: 81.327,
        thickness_mm: 2.95,
        ior_d: 1.672,
        abbe_v: 38.9,
        height_mm: 13.0,
    },
    LensSurface {
        radius_mm: -169.527,
        thickness_mm: 8.846,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 13.0,
    },
    LensSurface {
        radius_mm: 0.0,
        thickness_mm: 1.0,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 13.0,
    },
    LensSurface {
        radius_mm: 174.041,
        thickness_mm: 3.25,
        ior_d: 1.713,
        abbe_v: 54.0,
        height_mm: 13.0,
    },
    LensSurface {
        radius_mm: -63.18,
        thickness_mm: 0.1,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 13.0,
    },
    LensSurface {
        radius_mm: 50.356,
        thickness_mm: 5.0,
        ior_d: 1.564,
        abbe_v: 60.8,
        height_mm: 13.0,
    },
    LensSurface {
        radius_mm: -70.071,
        thickness_mm: 1.1,
        ior_d: 1.796,
        abbe_v: 41.0,
        height_mm: 13.0,
    },
    LensSurface {
        radius_mm: 229.755,
        thickness_mm: 0.1,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 13.0,
    },
    LensSurface {
        radius_mm: 25.187,
        thickness_mm: 5.6,
        ior_d: 1.518,
        abbe_v: 59.0,
        height_mm: 13.0,
    },
    LensSurface {
        radius_mm: -745.542,
        thickness_mm: 1.0,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 13.0,
    },
    LensSurface {
        radius_mm: 262.417,
        thickness_mm: 2.0,
        ior_d: 1.795,
        abbe_v: 28.6,
        height_mm: 13.0,
    },
    LensSurface {
        radius_mm: 37.552,
        thickness_mm: 10.15,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 13.0,
    },
    LensSurface {
        radius_mm: 111.689,
        thickness_mm: 3.0,
        ior_d: 1.517,
        abbe_v: 64.1,
        height_mm: 13.0,
    },
    LensSurface {
        radius_mm: -97.52,
        thickness_mm: 20.85,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 13.0,
    },
    LensSurface {
        radius_mm: -18.386,
        thickness_mm: 2.0,
        ior_d: 1.67,
        abbe_v: 47.1,
        height_mm: 14.0,
    },
    LensSurface {
        radius_mm: -31.592,
        thickness_mm: 0.1,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 14.0,
    },
    LensSurface {
        radius_mm: 941.473,
        thickness_mm: 4.55,
        ior_d: 1.702,
        abbe_v: 41.0,
        height_mm: 16.0,
    },
    LensSurface {
        radius_mm: -72.586,
        thickness_mm: 14.0,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 16.0,
    },
];

/// 100mm - patent US2823583 (1958).
const KODAK_100_SURFACES: &[LensSurface] = &[
    LensSurface {
        radius_mm: 36.02,
        thickness_mm: 3.1,
        ior_d: 1.517,
        abbe_v: 64.5,
        height_mm: 13.0,
    },
    LensSurface {
        radius_mm: 418.3,
        thickness_mm: 0.7,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 13.0,
    },
    LensSurface {
        radius_mm: 24.59,
        thickness_mm: 7.4,
        ior_d: 1.611,
        abbe_v: 58.8,
        height_mm: 13.0,
    },
    LensSurface {
        radius_mm: -45.33,
        thickness_mm: 3.5,
        ior_d: 1.523,
        abbe_v: 58.6,
        height_mm: 13.0,
    },
    LensSurface {
        radius_mm: -44.52,
        thickness_mm: 4.3,
        ior_d: 1.617,
        abbe_v: 36.6,
        height_mm: 13.0,
    },
    LensSurface {
        radius_mm: 13.42,
        thickness_mm: 6.9,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 10.0,
    },
    LensSurface {
        radius_mm: 0.0,
        thickness_mm: 6.9,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 10.0,
    },
    LensSurface {
        radius_mm: -13.42,
        thickness_mm: 4.3,
        ior_d: 1.617,
        abbe_v: 36.6,
        height_mm: 10.0,
    },
    LensSurface {
        radius_mm: 44.52,
        thickness_mm: 3.5,
        ior_d: 1.523,
        abbe_v: 58.6,
        height_mm: 13.0,
    },
    LensSurface {
        radius_mm: 45.33,
        thickness_mm: 7.4,
        ior_d: 1.611,
        abbe_v: 58.8,
        height_mm: 13.0,
    },
    LensSurface {
        radius_mm: -24.59,
        thickness_mm: 0.7,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 13.0,
    },
    LensSurface {
        radius_mm: -74.42,
        thickness_mm: 3.1,
        ior_d: 1.72,
        abbe_v: 29.3,
        height_mm: 15.0,
    },
    LensSurface {
        radius_mm: -32.2,
        thickness_mm: 50.0,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 15.0,
    },
];
/// AF-S 28-70mm - patent 5835272 (1990).
const NIKON_28_70_SURFACES: &[LensSurface] = &[
    LensSurface {
        radius_mm: 72.747,
        thickness_mm: 2.3,
        ior_d: 1.603,
        abbe_v: 65.42,
        height_mm: 15.0,
    },
    LensSurface {
        radius_mm: 37.0,
        thickness_mm: 13.0,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 15.0,
    },
    LensSurface {
        radius_mm: -172.809,
        thickness_mm: 2.1,
        ior_d: 1.58913,
        abbe_v: 61.09,
        height_mm: 15.0,
    },
    LensSurface {
        radius_mm: 39.894,
        thickness_mm: 1.0,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 15.0,
    },
    LensSurface {
        radius_mm: 49.82,
        thickness_mm: 4.4,
        ior_d: 1.86074,
        abbe_v: 23.01,
        height_mm: 15.0,
    },
    LensSurface {
        radius_mm: 75.75,
        thickness_mm: 53.142,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 15.0,
    },
    LensSurface {
        radius_mm: 63.402,
        thickness_mm: 1.6,
        ior_d: 1.86074,
        abbe_v: 23.01,
        height_mm: 15.0,
    },
    LensSurface {
        radius_mm: 37.53,
        thickness_mm: 8.6,
        ior_d: 1.5168,
        abbe_v: 64.1,
        height_mm: 15.0,
    },
    LensSurface {
        radius_mm: -75.887,
        thickness_mm: 1.6,
        ior_d: 1.80458,
        abbe_v: 25.5,
        height_mm: 15.0,
    },
    LensSurface {
        radius_mm: -97.792,
        thickness_mm: 7.063,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 15.0,
    },
    LensSurface {
        radius_mm: 96.034,
        thickness_mm: 3.6,
        ior_d: 1.62041,
        abbe_v: 60.14,
        height_mm: 15.0,
    },
    LensSurface {
        radius_mm: 261.743,
        thickness_mm: 0.1,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 15.0,
    },
    LensSurface {
        radius_mm: 54.262,
        thickness_mm: 6.0,
        ior_d: 1.6968,
        abbe_v: 55.6,
        height_mm: 15.0,
    },
    LensSurface {
        radius_mm: -5995.277,
        thickness_mm: 1.532,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 15.0,
    },
    LensSurface {
        radius_mm: 0.0,
        thickness_mm: 2.8,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 10.4,
    },
    LensSurface {
        radius_mm: -74.414,
        thickness_mm: 2.2,
        ior_d: 1.90265,
        abbe_v: 35.72,
        height_mm: 15.0,
    },
    LensSurface {
        radius_mm: -62.929,
        thickness_mm: 1.45,
        ior_d: 1.5168,
        abbe_v: 64.1,
        height_mm: 15.0,
    },
    LensSurface {
        radius_mm: 121.38,
        thickness_mm: 2.5,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 15.0,
    },
    LensSurface {
        radius_mm: -85.723,
        thickness_mm: 1.4,
        ior_d: 1.49782,
        abbe_v: 82.52,
        height_mm: 15.0,
    },
    LensSurface {
        radius_mm: 31.093,
        thickness_mm: 2.6,
        ior_d: 1.80458,
        abbe_v: 25.5,
        height_mm: 15.0,
    },
    LensSurface {
        radius_mm: 84.758,
        thickness_mm: 16.889,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 15.0,
    },
    LensSurface {
        radius_mm: 459.69,
        thickness_mm: 1.4,
        ior_d: 1.86074,
        abbe_v: 23.01,
        height_mm: 15.0,
    },
    LensSurface {
        radius_mm: 40.24,
        thickness_mm: 7.3,
        ior_d: 1.49782,
        abbe_v: 82.52,
        height_mm: 15.0,
    },
    LensSurface {
        radius_mm: -49.771,
        thickness_mm: 0.1,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 15.0,
    },
    LensSurface {
        radius_mm: 60.369,
        thickness_mm: 7.0,
        ior_d: 1.67025,
        abbe_v: 57.53,
        height_mm: 15.0,
    },
    LensSurface {
        radius_mm: -76.454,
        thickness_mm: 5.2,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 15.0,
    },
    LensSurface {
        radius_mm: -32.524,
        thickness_mm: 2.0,
        ior_d: 1.80454,
        abbe_v: 39.61,
        height_mm: 15.0,
    },
    LensSurface {
        radius_mm: -50.194,
        thickness_mm: 39.683,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 15.0,
    },
];

/// Cooke triplet (H. D. Taylor, 1893; textbook f/3.5 form) - the classic
/// three-element design, few surfaces, a clean sparse ghost train.
const COOKE_50_SURFACES: &[LensSurface] = &[
    LensSurface {
        radius_mm: 19.95,
        thickness_mm: 2.955,
        ior_d: 1.617,
        abbe_v: 55.0,
        height_mm: 6.798,
    },
    LensSurface {
        radius_mm: -395.0,
        thickness_mm: 5.447,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 6.798,
    },
    LensSurface {
        radius_mm: -20.13,
        thickness_mm: 0.9064,
        ior_d: 1.649,
        abbe_v: 33.8,
        height_mm: 5.438,
    },
    LensSurface {
        radius_mm: 18.39,
        thickness_mm: 1.586,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 5.438,
    },
    LensSurface {
        radius_mm: 0.0,
        thickness_mm: 2.719,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 4.713,
    },
    LensSurface {
        radius_mm: 72.22,
        thickness_mm: 2.674,
        ior_d: 1.617,
        abbe_v: 55.0,
        height_mm: 5.892,
    },
    LensSurface {
        radius_mm: -16.68,
        thickness_mm: 37.16,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 5.892,
    },
];

/// Tessar (P. Rudolph, 1902; textbook f/2.8 form) - front singlet, negative
/// singlet, cemented rear doublet.
const TESSAR_50_SURFACES: &[LensSurface] = &[
    LensSurface {
        radius_mm: 24.51,
        thickness_mm: 5.372,
        ior_d: 1.612,
        abbe_v: 56.9,
        height_mm: 13.54,
    },
    LensSurface {
        radius_mm: -416.0,
        thickness_mm: 2.844,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 13.54,
    },
    LensSurface {
        radius_mm: -52.02,
        thickness_mm: 1.836,
        ior_d: 1.605,
        abbe_v: 38.0,
        height_mm: 11.29,
    },
    LensSurface {
        radius_mm: 23.88,
        thickness_mm: 2.709,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 10.53,
    },
    LensSurface {
        radius_mm: 0.0,
        thickness_mm: 2.257,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 9.631,
    },
    LensSurface {
        radius_mm: 413.1,
        thickness_mm: 1.806,
        ior_d: 1.517,
        abbe_v: 64.2,
        height_mm: 11.29,
    },
    LensSurface {
        radius_mm: 31.98,
        thickness_mm: 4.575,
        ior_d: 1.611,
        abbe_v: 58.8,
        height_mm: 11.29,
    },
    LensSurface {
        radius_mm: -25.03,
        thickness_mm: 57.19,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 11.29,
    },
];

/// Petzval portrait (J. Petzval, 1840; scaled textbook form) - two widely
/// spaced doublets, the historic fast-portrait design; big soft ghosts.
const PETZVAL_85_SURFACES: &[LensSurface] = &[
    LensSurface {
        radius_mm: 45.23,
        thickness_mm: 5.542,
        ior_d: 1.517,
        abbe_v: 64.2,
        height_mm: 13.04,
    },
    LensSurface {
        radius_mm: -34.88,
        thickness_mm: 1.222,
        ior_d: 1.576,
        abbe_v: 41.0,
        height_mm: 13.04,
    },
    LensSurface {
        radius_mm: -154.8,
        thickness_mm: 26.08,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 13.04,
    },
    LensSurface {
        radius_mm: 0.0,
        thickness_mm: 9.78,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 10.59,
    },
    LensSurface {
        radius_mm: -51.34,
        thickness_mm: 1.304,
        ior_d: 1.576,
        abbe_v: 41.0,
        height_mm: 11.41,
    },
    LensSurface {
        radius_mm: 37.9,
        thickness_mm: 1.141,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 11.41,
    },
    LensSurface {
        radius_mm: 42.38,
        thickness_mm: 4.564,
        ior_d: 1.517,
        abbe_v: 64.2,
        height_mm: 11.41,
    },
    LensSurface {
        radius_mm: -44.82,
        thickness_mm: 44.82,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 11.41,
    },
];

/// Double Gauss (Biotar-type, 1927 lineage; textbook f/2 form) - the
/// symmetric six-element workhorse behind most fast normal lenses.
const DGAUSS_58_SURFACES: &[LensSurface] = &[
    LensSurface {
        radius_mm: 44.31,
        thickness_mm: 6.048,
        ior_d: 1.673,
        abbe_v: 47.2,
        height_mm: 18.61,
    },
    LensSurface {
        radius_mm: 133.0,
        thickness_mm: 0.2326,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 18.61,
    },
    LensSurface {
        radius_mm: 24.19,
        thickness_mm: 7.676,
        ior_d: 1.67,
        abbe_v: 51.7,
        height_mm: 16.28,
    },
    LensSurface {
        radius_mm: 43.5,
        thickness_mm: 1.861,
        ior_d: 1.7,
        abbe_v: 30.1,
        height_mm: 16.28,
    },
    LensSurface {
        radius_mm: 16.4,
        thickness_mm: 6.862,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 11.63,
    },
    LensSurface {
        radius_mm: 0.0,
        thickness_mm: 6.513,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 11.16,
    },
    LensSurface {
        radius_mm: -17.68,
        thickness_mm: 1.744,
        ior_d: 1.7,
        abbe_v: 30.1,
        height_mm: 11.63,
    },
    LensSurface {
        radius_mm: 38.5,
        thickness_mm: 7.559,
        ior_d: 1.67,
        abbe_v: 51.7,
        height_mm: 13.96,
    },
    LensSurface {
        radius_mm: -23.61,
        thickness_mm: 0.2326,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 13.96,
    },
    LensSurface {
        radius_mm: 90.71,
        thickness_mm: 5.234,
        ior_d: 1.673,
        abbe_v: 47.2,
        height_mm: 15.12,
    },
    LensSurface {
        radius_mm: -48.5,
        thickness_mm: 41.87,
        ior_d: 1.0,
        abbe_v: 0.0,
        height_mm: 15.12,
    },
];

/// Every bundled lens, in the Lens parameter's Choice order (stable: new
/// models append, existing indices never move â€” saved projects store the
/// index).
pub const LENS_MODELS: &[LensModel] = &[
    LensModel {
        label: "Voigtländer 105mm f/3.5",
        focal_length_mm: 105.0,
        native_fstop: 3.5,
        aperture_index: 5,
        surfaces: VINTAGE_105_SURFACES,
    },
    LensModel {
        label: "Leica 35mm f/1.4",
        focal_length_mm: 35.0,
        native_fstop: 1.4,
        aperture_index: 6,
        surfaces: FAST_35_SURFACES,
    },
    LensModel {
        label: "Zeiss 50mm T1.3",
        focal_length_mm: 50.0,
        native_fstop: 1.3,
        aperture_index: 14,
        surfaces: CINE_50_SURFACES,
    },
    LensModel {
        label: "Nikon 50-135mm f/3.5",
        focal_length_mm: 90.0,
        native_fstop: 3.5,
        aperture_index: 14,
        surfaces: TELE_ZOOM_SURFACES,
    },
    LensModel {
        label: "Kodak 100mm f/3.8",
        focal_length_mm: 100.0,
        native_fstop: 3.8,
        aperture_index: 6,
        surfaces: KODAK_100_SURFACES,
    },
    LensModel {
        label: "Nikon 28-70mm f/2.8",
        focal_length_mm: 28.0,
        native_fstop: 2.9,
        aperture_index: 14,
        surfaces: NIKON_28_70_SURFACES,
    },
    LensModel {
        label: "Cooke triplet 50mm f/3.5",
        focal_length_mm: 50.0,
        native_fstop: 3.5,
        aperture_index: 4,
        surfaces: COOKE_50_SURFACES,
    },
    LensModel {
        label: "Tessar 50mm f/2.8",
        focal_length_mm: 50.0,
        native_fstop: 2.8,
        aperture_index: 4,
        surfaces: TESSAR_50_SURFACES,
    },
    LensModel {
        label: "Petzval 85mm f/2.2",
        focal_length_mm: 85.0,
        native_fstop: 2.2,
        aperture_index: 3,
        surfaces: PETZVAL_85_SURFACES,
    },
    LensModel {
        label: "Double Gauss 58mm f/2",
        focal_length_mm: 58.0,
        native_fstop: 2.0,
        aperture_index: 5,
        surfaces: DGAUSS_58_SURFACES,
    },
];

/// The Lens Choice's option labels, in [`LENS_MODELS`] order (the schema
/// needs a &'static [&'static str]).
pub const LENS_OPTIONS: &[&str] = &[
    "Voigtländer 105mm f/3.5",
    "Leica 35mm f/1.4",
    "Zeiss 50mm T1.3",
    "Nikon 50-135mm f/3.5",
    "Kodak 100mm f/3.8",
    "Nikon 28-70mm f/2.8",
    "Cooke triplet 50mm f/3.5",
    "Tessar 50mm f/2.8",
    "Petzval 85mm f/2.2",
    "Double Gauss 58mm f/2",
];
