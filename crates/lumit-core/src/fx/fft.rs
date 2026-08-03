//! A small in-house complex FFT and fractional Fourier transform for the
//! Lens flare bakes (docs/impl/lens-flare.md §5, K-256). Power-of-two sizes
//! only; runs on the CPU at parameter-change time, never per frame, so
//! clarity beats micro-speed. All internals are f64 (the chirp phases of the
//! FRFT lose visible precision in f32); callers convert to f32 at the edge.
//!
//! In plain terms: a Fourier transform re-describes an image as a sum of
//! waves, which is exactly what light diffracting through an aperture does
//! physically — so the starburst and the ghost discs fall out of this maths.

/// One complex number, f64. A five-operation micro-type rather than a
/// dependency: the bake needs add, multiply, scale and exp, nothing more.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Cx {
    /// Real part.
    pub re: f64,
    /// Imaginary part.
    pub im: f64,
}

impl std::ops::Add for Cx {
    type Output = Cx;
    fn add(self, o: Cx) -> Cx {
        Cx::new(self.re + o.re, self.im + o.im)
    }
}

impl std::ops::Sub for Cx {
    type Output = Cx;
    fn sub(self, o: Cx) -> Cx {
        Cx::new(self.re - o.re, self.im - o.im)
    }
}

impl std::ops::Mul for Cx {
    type Output = Cx;
    fn mul(self, o: Cx) -> Cx {
        Cx::new(
            self.re * o.re - self.im * o.im,
            self.re * o.im + self.im * o.re,
        )
    }
}

impl Cx {
    /// Zero.
    pub const ZERO: Cx = Cx { re: 0.0, im: 0.0 };

    /// Build from parts.
    pub fn new(re: f64, im: f64) -> Cx {
        Cx { re, im }
    }

    /// Scale by a real.
    pub fn scale(self, s: f64) -> Cx {
        Cx::new(self.re * s, self.im * s)
    }

    /// `e^(i·theta)` — the unit phasor at angle `theta`.
    pub fn cis(theta: f64) -> Cx {
        Cx::new(theta.cos(), theta.sin())
    }

    /// `|z|²`.
    pub fn norm_sq(self) -> f64 {
        self.re * self.re + self.im * self.im
    }
}

/// In-place iterative radix-2 Cooley–Tukey FFT. `data.len()` must be a power
/// of two — a non-power-of-two length is left untransformed (the bake only
/// ever passes fixed power-of-two sizes; a guard beats a panic, docs/14 §4).
/// `inverse` runs the inverse transform. Normalisation is **ortho** (both
/// directions scale by 1/√n), matching numpy's `norm='ortho'` so the FRFT
/// port below keeps realflare's constants unchanged.
pub fn fft_inplace(data: &mut [Cx], inverse: bool) {
    let n = data.len();
    if n < 2 || !n.is_power_of_two() {
        return;
    }
    // Bit-reversal permutation.
    let bits = n.trailing_zeros();
    for i in 0..n {
        let j = (i as u32).reverse_bits() >> (32 - bits);
        let j = j as usize;
        if j > i {
            data.swap(i, j);
        }
    }
    // Butterflies.
    let sign = if inverse { 1.0 } else { -1.0 };
    let mut len = 2usize;
    while len <= n {
        let ang = sign * std::f64::consts::TAU / len as f64;
        let wlen = Cx::cis(ang);
        let mut i = 0usize;
        while i < n {
            let mut w = Cx::new(1.0, 0.0);
            for k in 0..len / 2 {
                let u = data[i + k];
                let v = data[i + k + len / 2] * w;
                data[i + k] = u + v;
                data[i + k + len / 2] = u - v;
                w = w * wlen;
            }
            i += len;
        }
        len <<= 1;
    }
    // Ortho normalisation.
    let s = 1.0 / (n as f64).sqrt();
    for z in data.iter_mut() {
        *z = z.scale(s);
    }
}

/// 2D FFT over a row-major `w × h` grid (rows first, then columns), ortho
/// normalised. Both dimensions must be powers of two (guarded as above).
pub fn fft2_inplace(data: &mut [Cx], w: usize, h: usize, inverse: bool) {
    if data.len() != w * h || !w.is_power_of_two() || !h.is_power_of_two() {
        return;
    }
    // Rows.
    for row in data.chunks_mut(w) {
        fft_inplace(row, inverse);
    }
    // Columns, through a scratch column buffer.
    let mut col = vec![Cx::ZERO; h];
    for x in 0..w {
        for (y, c) in col.iter_mut().enumerate() {
            *c = data[y * w + x];
        }
        fft_inplace(&mut col, inverse);
        for (y, c) in col.iter().enumerate() {
            data[y * w + x] = *c;
        }
    }
}

/// 2D fftshift: swaps quadrants so the zero frequency moves from the corner
/// to the centre (its own inverse for even sizes, which ours always are).
pub fn fftshift2(data: &mut [Cx], w: usize, h: usize) {
    if data.len() != w * h || !w.is_multiple_of(2) || !h.is_multiple_of(2) {
        return;
    }
    let (hw, hh) = (w / 2, h / 2);
    for y in 0..hh {
        for x in 0..w {
            let x2 = (x + hw) % w;
            let a = y * w + x;
            let b = (y + hh) * w + x2;
            data.swap(a, b);
        }
    }
}

/// The standard FFT frequency at index `k` of an `n`-point transform:
/// `k` for the first half, `k − n` for the second — the order numpy's
/// `fftshift(mgrid)` produces, which the FRFT chirp grid uses.
fn fft_freq(k: usize, n: usize) -> f64 {
    if k < n / 2 {
        k as f64
    } else {
        k as f64 - n as f64
    }
}

/// 2D fractional Fourier transform of order `alpha`, ported from realflare's
/// `frft.py` (itself after Ozaktas et al. 1996): normalise `alpha` into
/// [0.5, 1.5) with whole FFT / flip steps, then the chirp-multiply → FFT →
/// chirp-multiply decomposition. `alpha = 1` is the plain (ortho) FFT.
/// Row-major `w × h`, both powers of two (guarded). The ghost-disc bake calls
/// this with the small alphas of docs/impl/lens-flare.md §5.
pub fn frft2(data: &mut [Cx], w: usize, h: usize, alpha: f64) {
    if data.len() != w * h || !w.is_power_of_two() || !h.is_power_of_two() {
        return;
    }
    // --- normalise (Ozaktas III): reduce alpha with exact whole transforms.
    let rel = alpha.rem_euclid(4.0);
    let alpha = if rel < 0.5 {
        fft2_inplace(data, w, h, true);
        rel + 1.0
    } else if rel < 1.5 {
        rel
    } else if rel < 2.5 {
        fft2_inplace(data, w, h, false);
        rel - 1.0
    } else if rel < 3.5 {
        data.reverse();
        rel - 2.0
    } else {
        fft2_inplace(data, w, h, true);
        rel - 3.0
    };

    let phi = alpha * std::f64::consts::FRAC_PI_2;
    let cot = 1.0 / phi.tan();
    let sq = (1.0 + cot * cot).sqrt();

    // scale = sqrt(1 − i·cot) / sqrt(total): complex square root of
    // (1, −cot), principal branch.
    let mag = (1.0 + cot * cot).sqrt().sqrt();
    let ang = (-cot).atan2(1.0) / 2.0;
    let total = (w * h) as f64;
    let scale = Cx::cis(ang).scale(mag / total.sqrt());

    // chirp_arg[y][x] = i·π·(fx²/w + fy²/h) in FFT frequency order.
    // chirp1 = exp(chirp_arg·(cot − sq)); chirp2 = exp(chirp_arg·sq).
    // out = scale · chirp1 · ifft( fft(chirp2) · fft(chirp1 · data) ).
    let mut chirped = vec![Cx::ZERO; w * h];
    let mut chirp2f = vec![Cx::ZERO; w * h];
    for y in 0..h {
        let fy = fft_freq(y, h);
        for x in 0..w {
            let fx = fft_freq(x, w);
            let arg = std::f64::consts::PI * (fx * fx / w as f64 + fy * fy / h as f64);
            let i = y * w + x;
            // exp(i·arg·c) for real c is the unit phasor at angle arg·c.
            chirped[i] = data[i] * Cx::cis(arg * (cot - sq));
            chirp2f[i] = Cx::cis(arg * sq);
        }
    }
    fft2_inplace(&mut chirped, w, h, false);
    fft2_inplace(&mut chirp2f, w, h, false);
    for (a, b) in chirped.iter_mut().zip(chirp2f.iter()) {
        *a = *a * *b;
    }
    fft2_inplace(&mut chirped, w, h, true);
    for y in 0..h {
        let fy = fft_freq(y, h);
        for x in 0..w {
            let fx = fft_freq(x, w);
            let arg = std::f64::consts::PI * (fx * fx / w as f64 + fy * fy / h as f64);
            let i = y * w + x;
            data[i] = chirped[i] * Cx::cis(arg * (cot - sq)) * scale;
        }
    }
}
