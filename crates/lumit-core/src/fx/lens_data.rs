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

/// Every bundled lens, in the Lens parameter's Choice order (stable: new
/// models append, existing indices never move â€” saved projects store the
/// index).
pub const LENS_MODELS: &[LensModel] = &[
    LensModel {
        label: "Vintage 105mm prime",
        focal_length_mm: 105.0,
        native_fstop: 3.5,
        aperture_index: 5,
        surfaces: VINTAGE_105_SURFACES,
    },
    LensModel {
        label: "Fast 35mm prime",
        focal_length_mm: 35.0,
        native_fstop: 1.4,
        aperture_index: 6,
        surfaces: FAST_35_SURFACES,
    },
    LensModel {
        label: "Cine 50mm prime",
        focal_length_mm: 50.0,
        native_fstop: 1.3,
        aperture_index: 14,
        surfaces: CINE_50_SURFACES,
    },
    LensModel {
        label: "Telephoto zoom",
        focal_length_mm: 90.0,
        native_fstop: 3.5,
        aperture_index: 14,
        surfaces: TELE_ZOOM_SURFACES,
    },
];

/// The Lens Choice's option labels, in [`LENS_MODELS`] order (the schema
/// needs a &'static [&'static str]).
pub const LENS_OPTIONS: &[&str] = &[
    "Vintage 105mm prime",
    "Fast 35mm prime",
    "Cine 50mm prime",
    "Telephoto zoom",
];
