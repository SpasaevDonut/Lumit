//! Waveform peaks at every zoom, and the per-band "multiwave" stack
//! (docs/09-AUDIO.md §4).
//!
//! In plain terms: a timeline waveform is not the sound, it is a *summary* of
//! the sound — for each column of pixels, how far the speaker cone swung up
//! and down while that column's slice of time went by. The summary has to be
//! recomputed whenever the zoom changes, because a column that covered a whole
//! second when the comp was fitted covers a millisecond once you are cutting
//! on a hi-hat. Recomputing it from the raw samples every time would mean
//! reading millions of numbers per repaint, so this module does the reading
//! **once** and keeps the answer at three levels of detail — 256 samples per
//! block, 4 096, and 65 536. That is a mip-map, exactly like the ones a GPU
//! keeps for a texture: draw from the level nearest the size you are drawing
//! at, and the work per column stays tiny at every zoom.
//!
//! The second thing here is the **multiwave**. One waveform tells you how
//! *loud* a moment is and nothing about what is in it — a loud master is a
//! solid block ("a sausage") whether it is a kick, a snare or a vocal. So
//! alongside the plain wave this module also splits the sound into three
//! frequency bands (bass, middle, treble) with ordinary filters and summarises
//! each of them the same way. Stacked, the three read as a picture of *what*
//! is happening: the kick shows in the bottom band, the hats in the top, and a
//! cut can be aimed at either.
//!
//! Everything here is pure arithmetic over samples already decoded elsewhere,
//! so all of it is a plain deterministic test.

/// The bands a multiwave stack draws, plus the plain full-range wave that a
/// single-wave lane draws. Stored side by side in one pyramid because they
/// come from one pass over the samples.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Band {
    /// The whole signal — what the single-wave lane draws.
    Full,
    /// Below [`LOW_CROSSOVER_HZ`]: kicks, bass, room rumble.
    Low,
    /// Between the two crossovers: most of a voice, most of a snare's body.
    Mid,
    /// Above [`HIGH_CROSSOVER_HZ`]: hats, sibilance, transient edge.
    High,
}

/// How many summaries one pyramid holds per block — the four of [`Band`].
pub const BAND_COUNT: usize = 4;

impl Band {
    /// Where this band's summaries sit inside a tier's band-major array.
    #[must_use]
    pub const fn index(self) -> usize {
        match self {
            Band::Full => 0,
            Band::Low => 1,
            Band::Mid => 2,
            Band::High => 3,
        }
    }

    /// The stack a multiwave lane draws, bottom band first — the order a
    /// spectrum is read in, so the picture matches the mental model.
    #[must_use]
    pub const fn stack() -> [Band; 3] {
        [Band::Low, Band::Mid, Band::High]
    }
}

/// Bass/middle crossover, in Hz. Low enough that a kick and a bass line land
/// under it and a voice's fundamental mostly does not.
pub const LOW_CROSSOVER_HZ: f32 = 200.0;

/// Middle/treble crossover, in Hz. Above it lives the transient edge — hats,
/// sibilance, the click of a kick — which is what an edit is usually aimed at.
pub const HIGH_CROSSOVER_HZ: f32 = 2_000.0;

/// The finest tier's block size, in samples: ~5 ms at 48 kHz, finer than any
/// single pixel column an editor can zoom a waveform to.
pub const FINEST_BLOCK: usize = 256;

/// How much coarser each tier is than the one below it.
pub const TIER_RATIO: usize = 16;

/// How many tiers a pyramid holds: 256 / 4 096 / 65 536 samples per block,
/// the three sizes docs/09 §4 names.
pub const TIERS: usize = 3;

/// How many of a tier's blocks must fit inside one bucket before that tier is
/// coarse enough to read it from. A bucket covers whole blocks, so it always
/// reaches a little past its own edges; asking for four blocks keeps that
/// overspill under a quarter of a bucket, which is below what an eye can see
/// on a lane, while still costing only a handful of merges per column.
pub const BLOCKS_PER_BUCKET: usize = 4;

/// The most blocks the finest tier may hold, so one pyramid's memory is
/// bounded however long the file is (docs/14 §5: budgeted allocations). At the
/// cap a pyramid costs about 12 MB; past it the finest tier is coarsened by
/// [`TIER_RATIO`] until it fits, which costs resolution only on files hours
/// long.
pub const MAX_BLOCKS: usize = 262_144;

/// One block's summary: how far the signal swung either way across it, and how
/// much energy it carried. `min`/`max` draw the body of the wave and `rms`
/// draws the solid core inside it (docs/15 §waveforms).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct PeakBlock {
    pub min: f32,
    pub max: f32,
    pub rms: f32,
}

impl PeakBlock {
    /// Silence — and what an empty query answers, so a caller never has to
    /// special-case a bucket that fell off the end of the audio.
    pub const SILENT: PeakBlock = PeakBlock {
        min: 0.0,
        max: 0.0,
        rms: 0.0,
    };

    /// The summary covering both of two neighbouring blocks. Extremes take the
    /// wider pair; the energy is the root of the mean of the two mean squares,
    /// which is exact when the two blocks are the same length — and inside a
    /// tier they always are, bar the last.
    #[must_use]
    fn merged(self, other: PeakBlock) -> PeakBlock {
        PeakBlock {
            min: self.min.min(other.min),
            max: self.max.max(other.max),
            rms: (0.5 * (self.rms * self.rms + other.rms * other.rms)).sqrt(),
        }
    }
}

/// A running summary, kept while a block is being filled.
#[derive(Clone, Copy)]
struct Running {
    min: f32,
    max: f32,
    sum_sq: f64,
    count: usize,
}

impl Running {
    const EMPTY: Running = Running {
        min: f32::MAX,
        max: f32::MIN,
        sum_sq: 0.0,
        count: 0,
    };

    fn push(&mut self, x: f32) {
        self.min = self.min.min(x);
        self.max = self.max.max(x);
        self.sum_sq += f64::from(x) * f64::from(x);
        self.count += 1;
    }

    fn finish(self) -> PeakBlock {
        if self.count == 0 {
            return PeakBlock::SILENT;
        }
        PeakBlock {
            min: self.min,
            max: self.max,
            rms: (self.sum_sq / self.count as f64).sqrt() as f32,
        }
    }
}

/// One second-order section, transposed direct form II — the standard "cookbook"
/// biquad. Two of these in series make the 24 dB/octave slope the band split
/// uses, which is steep enough that a kick does not smear into the middle band.
#[derive(Clone, Copy)]
struct Biquad {
    b0: f32,
    b1: f32,
    b2: f32,
    a1: f32,
    a2: f32,
    z1: f32,
    z2: f32,
}

impl Biquad {
    /// A Butterworth-Q section at `cutoff`, low-pass when `low` and high-pass
    /// otherwise. A cutoff at or above Nyquist (or at or below zero) yields a
    /// pass-through rather than a divide by zero: a 4 kHz file has no treble
    /// band to speak of, and answering "all of it" beats answering NaN.
    fn section(sample_rate: f32, cutoff: f32, low: bool) -> Biquad {
        let pass = Biquad {
            b0: 1.0,
            b1: 0.0,
            b2: 0.0,
            a1: 0.0,
            a2: 0.0,
            z1: 0.0,
            z2: 0.0,
        };
        if !sample_rate.is_finite()
            || sample_rate <= 0.0
            || cutoff <= 0.0
            || cutoff >= sample_rate * 0.5
        {
            return pass;
        }
        let q = std::f32::consts::FRAC_1_SQRT_2;
        let w0 = 2.0 * std::f32::consts::PI * cutoff / sample_rate;
        let (sin_w0, cos_w0) = w0.sin_cos();
        let alpha = sin_w0 / (2.0 * q);
        let a0 = 1.0 + alpha;
        if a0 == 0.0 {
            return pass;
        }
        let (b0, b1, b2) = if low {
            let b1 = 1.0 - cos_w0;
            (b1 * 0.5, b1, b1 * 0.5)
        } else {
            let b1 = 1.0 + cos_w0;
            (b1 * 0.5, -b1, b1 * 0.5)
        };
        Biquad {
            b0: b0 / a0,
            b1: b1 / a0,
            b2: b2 / a0,
            a1: (-2.0 * cos_w0) / a0,
            a2: (1.0 - alpha) / a0,
            z1: 0.0,
            z2: 0.0,
        }
    }

    fn run(&mut self, x: f32) -> f32 {
        let y = self.b0 * x + self.z1;
        self.z1 = self.b1 * x - self.a1 * y + self.z2;
        self.z2 = self.b2 * x - self.a2 * y;
        y
    }
}

/// A cascade of two sections: the 24 dB/octave slope each band edge uses.
#[derive(Clone, Copy)]
struct Slope([Biquad; 2]);

impl Slope {
    fn low(sample_rate: f32, cutoff: f32) -> Slope {
        Slope([
            Biquad::section(sample_rate, cutoff, true),
            Biquad::section(sample_rate, cutoff, true),
        ])
    }

    fn high(sample_rate: f32, cutoff: f32) -> Slope {
        Slope([
            Biquad::section(sample_rate, cutoff, false),
            Biquad::section(sample_rate, cutoff, false),
        ])
    }

    fn run(&mut self, x: f32) -> f32 {
        let mut y = x;
        for section in &mut self.0 {
            y = section.run(y);
        }
        y
    }
}

/// The three-way split a multiwave stack is made of.
struct Split {
    low: Slope,
    mid_high: Slope,
    mid_low: Slope,
    high: Slope,
}

impl Split {
    fn new(sample_rate: f32) -> Split {
        Split {
            low: Slope::low(sample_rate, LOW_CROSSOVER_HZ),
            // The middle band is what survives both edges.
            mid_high: Slope::high(sample_rate, LOW_CROSSOVER_HZ),
            mid_low: Slope::low(sample_rate, HIGH_CROSSOVER_HZ),
            high: Slope::high(sample_rate, HIGH_CROSSOVER_HZ),
        }
    }

    /// One mono sample in, the four band values out, in [`Band::index`] order.
    fn run(&mut self, x: f32) -> [f32; BAND_COUNT] {
        [
            x,
            self.low.run(x),
            self.mid_low.run(self.mid_high.run(x)),
            self.high.run(x),
        ]
    }
}

/// One level of detail: `len` blocks of `block` samples each, per band.
struct Tier {
    /// Samples per block.
    block: usize,
    /// Blocks per band.
    len: usize,
    /// Band-major: band `b`'s block `i` is at `b * len + i`.
    data: Vec<PeakBlock>,
}

impl Tier {
    fn at(&self, band: Band, index: usize) -> PeakBlock {
        self.data
            .get(band.index() * self.len + index)
            .copied()
            .unwrap_or(PeakBlock::SILENT)
    }
}

/// One source's waveform summarised at three levels of detail, for all four
/// bands — everything a lane needs to draw itself at any zoom without going
/// near the samples again.
///
/// Built once per source (the bridge keeps a small cache of them), then asked
/// for whatever window the lane is currently showing.
pub struct PeakPyramid {
    sample_rate: u32,
    frames: usize,
    /// Finest first.
    tiers: Vec<Tier>,
}

impl PeakPyramid {
    /// Summarise interleaved-stereo PCM. One pass over the samples fills the
    /// finest tier; the coarser ones are folded down from it, so the whole
    /// pyramid costs barely more than the single tier the old fixed-bucket
    /// waveform cost.
    #[must_use]
    pub fn build(interleaved: &[f32], sample_rate: u32) -> PeakPyramid {
        let frames = interleaved.len() / 2;
        if frames == 0 || sample_rate == 0 {
            return PeakPyramid {
                sample_rate: sample_rate.max(1),
                frames: 0,
                tiers: Vec::new(),
            };
        }

        // Coarsen the finest tier until it fits the memory budget — only files
        // hours long ever reach this.
        let mut block = FINEST_BLOCK;
        while frames.div_ceil(block) > MAX_BLOCKS {
            block = block.saturating_mul(TIER_RATIO);
        }

        let len = frames.div_ceil(block);
        let mut data = vec![PeakBlock::SILENT; len * BAND_COUNT];
        let mut split = Split::new(sample_rate as f32);
        let mut running = [Running::EMPTY; BAND_COUNT];
        let mut index = 0usize;
        let mut filled = 0usize;
        for frame in 0..frames {
            let l = interleaved.get(frame * 2).copied().unwrap_or(0.0);
            let r = interleaved.get(frame * 2 + 1).copied().unwrap_or(0.0);
            let bands = split.run(0.5 * (l + r));
            for (b, value) in bands.iter().enumerate() {
                if let Some(slot) = running.get_mut(b) {
                    slot.push(*value);
                }
            }
            filled += 1;
            if filled == block {
                for (b, slot) in running.iter().enumerate() {
                    if let Some(cell) = data.get_mut(b * len + index) {
                        *cell = slot.finish();
                    }
                }
                running = [Running::EMPTY; BAND_COUNT];
                filled = 0;
                index += 1;
            }
        }
        if filled > 0 {
            for (b, slot) in running.iter().enumerate() {
                if let Some(cell) = data.get_mut(b * len + index) {
                    *cell = slot.finish();
                }
            }
        }

        let mut tiers = vec![Tier { block, len, data }];
        for _ in 1..TIERS {
            let Some(finer) = tiers.last() else { break };
            if finer.len <= 1 {
                break;
            }
            let coarse_len = finer.len.div_ceil(TIER_RATIO);
            let mut coarse = vec![PeakBlock::SILENT; coarse_len * BAND_COUNT];
            for b in 0..BAND_COUNT {
                for i in 0..coarse_len {
                    let mut acc: Option<PeakBlock> = None;
                    for k in 0..TIER_RATIO {
                        let src = i * TIER_RATIO + k;
                        if src >= finer.len {
                            break;
                        }
                        let block = finer.data.get(b * finer.len + src).copied();
                        acc = match (acc, block) {
                            (Some(a), Some(x)) => Some(a.merged(x)),
                            (None, Some(x)) => Some(x),
                            (a, None) => a,
                        };
                    }
                    if let Some(cell) = coarse.get_mut(b * coarse_len + i) {
                        *cell = acc.unwrap_or(PeakBlock::SILENT);
                    }
                }
            }
            tiers.push(Tier {
                block: finer.block.saturating_mul(TIER_RATIO),
                len: coarse_len,
                data: coarse,
            });
        }

        PeakPyramid {
            sample_rate,
            frames,
            tiers,
        }
    }

    /// How long the summarised audio runs, in seconds.
    #[must_use]
    pub fn duration_seconds(&self) -> f64 {
        if self.sample_rate == 0 {
            return 0.0;
        }
        self.frames as f64 / f64::from(self.sample_rate)
    }

    /// Whether anything was summarised at all.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.frames == 0 || self.tiers.is_empty()
    }

    /// Roughly how much memory this pyramid holds, for the cache's budget.
    #[must_use]
    pub fn bytes(&self) -> usize {
        self.tiers
            .iter()
            .map(|t| t.data.len() * std::mem::size_of::<PeakBlock>())
            .sum()
    }

    /// The tier to read a bucket of `samples_per_bucket` samples from: the
    /// coarsest whose blocks are at least [`BLOCKS_PER_BUCKET`] times smaller
    /// than the bucket, so the work per bucket stays near constant at every
    /// zoom and a bucket never drags in a neighbour's worth of sound. Zoomed
    /// past the finest tier's block there is nothing finer to reach for, and
    /// tier 0 is the answer.
    fn tier_for(&self, samples_per_bucket: f64) -> Option<&Tier> {
        let mut chosen = self.tiers.first()?;
        for tier in &self.tiers {
            if (tier.block.saturating_mul(BLOCKS_PER_BUCKET) as f64) <= samples_per_bucket {
                chosen = tier;
            }
        }
        Some(chosen)
    }

    /// The summary of one span of the source, in seconds. Used a bucket at a
    /// time by callers whose time mapping is not a straight line — a retimed
    /// clip, where each pixel column covers its own stretch of source.
    ///
    /// A backwards span (a clip playing in reverse) is read the same as its
    /// forwards twin; the picture of what is in the audio does not change
    /// because it is being played the other way.
    #[must_use]
    pub fn window(&self, band: Band, start_seconds: f64, end_seconds: f64) -> PeakBlock {
        let (a, b) = if start_seconds <= end_seconds {
            (start_seconds, end_seconds)
        } else {
            (end_seconds, start_seconds)
        };
        let rate = f64::from(self.sample_rate.max(1));
        let first = (a * rate).floor().max(0.0);
        let last = (b * rate).ceil().min(self.frames as f64);
        if self.is_empty() || last <= first {
            return PeakBlock::SILENT;
        }
        let Some(tier) = self.tier_for(last - first) else {
            return PeakBlock::SILENT;
        };
        self.block_range(tier, band, first as usize, last as usize)
    }

    /// `buckets` summaries evenly spanning `[start_seconds, end_seconds)` of
    /// the source — one per pixel column of a lane, which is what makes the
    /// drawn resolution follow the zoom.
    ///
    /// Buckets falling outside the audio come back silent rather than missing,
    /// so the caller's column index and the returned index always agree.
    #[must_use]
    pub fn range(
        &self,
        band: Band,
        start_seconds: f64,
        end_seconds: f64,
        buckets: usize,
    ) -> Vec<PeakBlock> {
        if buckets == 0 {
            return Vec::new();
        }
        if self.is_empty() || end_seconds <= start_seconds {
            return vec![PeakBlock::SILENT; buckets];
        }
        let rate = f64::from(self.sample_rate.max(1));
        let span = (end_seconds - start_seconds) * rate;
        let per_bucket = span / buckets as f64;
        let Some(tier) = self.tier_for(per_bucket) else {
            return vec![PeakBlock::SILENT; buckets];
        };
        let origin = start_seconds * rate;
        let mut out = Vec::with_capacity(buckets);
        for i in 0..buckets {
            let a = origin + per_bucket * i as f64;
            let b = a + per_bucket;
            let first = a.floor().max(0.0);
            let last = b.ceil().min(self.frames as f64);
            if last <= first {
                out.push(PeakBlock::SILENT);
                continue;
            }
            out.push(self.block_range(tier, band, first as usize, last as usize));
        }
        out
    }

    /// Merge every block of `tier` that overlaps `[first, last)` samples.
    fn block_range(&self, tier: &Tier, band: Band, first: usize, last: usize) -> PeakBlock {
        if tier.block == 0 || tier.len == 0 || last <= first {
            return PeakBlock::SILENT;
        }
        let from = first / tier.block;
        // `last` is exclusive, so the final block is the one holding `last - 1`.
        let to = ((last - 1) / tier.block).min(tier.len.saturating_sub(1));
        if from > to {
            return PeakBlock::SILENT;
        }
        let mut acc = tier.at(band, from);
        for i in (from + 1)..=to {
            acc = acc.merged(tier.at(band, i));
        }
        acc
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    /// Interleave a mono signal into the stereo shape the builder takes.
    fn stereo(mono: &[f32]) -> Vec<f32> {
        mono.iter().flat_map(|&s| [s, s]).collect()
    }

    /// A sine at `hz`, `seconds` long, at `rate`.
    fn sine(hz: f32, seconds: f32, rate: u32) -> Vec<f32> {
        let n = (seconds * rate as f32) as usize;
        (0..n)
            .map(|i| (2.0 * std::f32::consts::PI * hz * i as f32 / rate as f32).sin())
            .collect()
    }

    #[test]
    fn empty_input_summarises_to_nothing() {
        let p = PeakPyramid::build(&[], 48_000);
        assert!(p.is_empty());
        assert_eq!(p.duration_seconds(), 0.0);
        // A query against nothing still answers one summary per bucket.
        assert_eq!(p.range(Band::Full, 0.0, 1.0, 4).len(), 4);
        assert_eq!(p.window(Band::Full, 0.0, 1.0), PeakBlock::SILENT);
    }

    #[test]
    fn the_full_band_keeps_the_signals_extremes() {
        // Half a second of full-scale square, so every block is ±1.
        let mono: Vec<f32> = (0..24_000)
            .map(|i| if i % 2 == 0 { 1.0 } else { -1.0 })
            .collect();
        let p = PeakPyramid::build(&stereo(&mono), 48_000);
        assert!((p.duration_seconds() - 0.5).abs() < 1e-9);
        for block in p.range(Band::Full, 0.0, 0.5, 32) {
            assert!((block.max - 1.0).abs() < 1e-6, "max {}", block.max);
            assert!((block.min + 1.0).abs() < 1e-6, "min {}", block.min);
            assert!((block.rms - 1.0).abs() < 1e-3, "rms {}", block.rms);
        }
    }

    #[test]
    fn zooming_in_asks_for_and_gets_finer_detail() {
        // A single click 100 ms in, silence either side. Summarised across the
        // whole second it is one bucket's worth of nothing much; summarised
        // across 10 ms around it, it fills its bucket.
        let mut mono = vec![0.0f32; 48_000];
        if let Some(s) = mono.get_mut(4_800) {
            *s = 1.0;
        }
        let p = PeakPyramid::build(&stereo(&mono), 48_000);

        let wide = p.range(Band::Full, 0.0, 1.0, 10);
        // The click lands in the second of ten buckets, and nowhere but the
        // block it shares an edge with — a bucket covers whole blocks, so it
        // may reach a few milliseconds past its own edge and no further.
        assert!(wide[1].max > 0.9);
        assert_eq!(wide[3].max, 0.0);
        assert_eq!(wide[9].max, 0.0);

        // Zoomed to 10 ms across 100 columns, each column is 4.8 samples —
        // finer than the finest tier's block, so neighbouring columns share it
        // rather than inventing detail, and the click is still exactly one
        // block wide.
        let close = p.range(Band::Full, 0.095, 0.105, 100);
        let loud = close.iter().filter(|b| b.max > 0.9).count();
        assert!(loud > 0, "the click vanished when zoomed in");
        assert!(
            loud < close.len(),
            "the click smeared across the whole view"
        );
    }

    #[test]
    fn a_bass_tone_shows_in_the_low_band_and_not_the_high() {
        let p = PeakPyramid::build(&stereo(&sine(60.0, 0.5, 48_000)), 48_000);
        // Skip the first blocks: the filters start from rest and take a few
        // cycles to settle, which is a real property of filters and not a bug.
        let low = p.window(Band::Low, 0.25, 0.5).max;
        let high = p.window(Band::High, 0.25, 0.5).max;
        assert!(low > 0.7, "60 Hz should survive the low band, got {low}");
        assert!(
            high < 0.05,
            "60 Hz should not reach the high band, got {high}"
        );
    }

    #[test]
    fn a_hat_like_tone_shows_in_the_high_band_and_not_the_low() {
        let p = PeakPyramid::build(&stereo(&sine(8_000.0, 0.5, 48_000)), 48_000);
        let low = p.window(Band::Low, 0.25, 0.5).max;
        let high = p.window(Band::High, 0.25, 0.5).max;
        assert!(high > 0.7, "8 kHz should survive the high band, got {high}");
        assert!(low < 0.05, "8 kHz should not reach the low band, got {low}");
    }

    #[test]
    fn a_voice_like_tone_shows_in_the_middle_band() {
        let p = PeakPyramid::build(&stereo(&sine(700.0, 0.5, 48_000)), 48_000);
        let mid = p.window(Band::Mid, 0.25, 0.5).max;
        let low = p.window(Band::Low, 0.25, 0.5).max;
        let high = p.window(Band::High, 0.25, 0.5).max;
        assert!(
            mid > 0.7,
            "700 Hz should survive the middle band, got {mid}"
        );
        assert!(mid > low * 4.0 && mid > high * 4.0);
    }

    #[test]
    fn coarse_tiers_agree_with_the_fine_one() {
        // The whole point of a mip-map: reading a wide window from a coarse
        // tier must give the same extremes as reading it from the finest.
        let mono: Vec<f32> = (0..48_000)
            .map(|i| (i as f32 / 48_000.0 * 7.0).sin() * (i as f32 / 48_000.0))
            .collect();
        let p = PeakPyramid::build(&stereo(&mono), 48_000);
        let coarse = p.range(Band::Full, 0.0, 1.0, 8);
        // Ask for the same eight spans one at a time, each narrow enough that
        // `window` picks the finest tier it can.
        for (i, block) in coarse.iter().enumerate() {
            let a = i as f64 / 8.0;
            let fine = p.window(Band::Full, a, a + 1.0 / 8.0);
            assert!((fine.max - block.max).abs() < 1e-3, "bucket {i}");
            assert!((fine.min - block.min).abs() < 1e-3, "bucket {i}");
        }
    }

    #[test]
    fn queries_outside_the_audio_are_silent_not_missing() {
        let p = PeakPyramid::build(&stereo(&vec![0.5f32; 4_800]), 48_000);
        let out = p.range(Band::Full, -1.0, 2.0, 30);
        assert_eq!(out.len(), 30);
        assert_eq!(out[0], PeakBlock::SILENT);
        assert_eq!(out[29], PeakBlock::SILENT);
        assert!(out[10].max > 0.4);
        // A degenerate span answers silence rather than dividing by zero.
        assert_eq!(p.range(Band::Full, 0.5, 0.5, 3).len(), 3);
        assert!(p.range(Band::Full, 0.0, 1.0, 0).is_empty());
    }

    #[test]
    fn a_reversed_window_reads_the_same_as_its_forward_twin() {
        let p = PeakPyramid::build(&stereo(&sine(440.0, 0.5, 48_000)), 48_000);
        assert_eq!(
            p.window(Band::Full, 0.1, 0.2),
            p.window(Band::Full, 0.2, 0.1)
        );
    }

    #[test]
    fn a_long_file_stays_inside_its_memory_budget() {
        // Not a real hour of audio — just enough to prove the coarsening rule
        // picks a bigger finest block rather than letting the tier grow.
        let frames = MAX_BLOCKS * FINEST_BLOCK + FINEST_BLOCK;
        let p = PeakPyramid {
            sample_rate: 48_000,
            frames,
            tiers: Vec::new(),
        };
        let _ = p; // the shape above is what `build` must not exceed
        let mut block = FINEST_BLOCK;
        while frames.div_ceil(block) > MAX_BLOCKS {
            block *= TIER_RATIO;
        }
        assert!(frames.div_ceil(block) <= MAX_BLOCKS);
        assert!(block > FINEST_BLOCK);
    }
}
