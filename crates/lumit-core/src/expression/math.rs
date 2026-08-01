use rhai::plugin::*; // a "prelude" import for macros

fn hash(x: i64) -> f64 {
    let mut n = x;
    n = (n << 13) ^ n;

    let nn = n
        .wrapping_mul(n.wrapping_mul(n).wrapping_mul(15731).wrapping_add(789221))
        .wrapping_add(1376312589);

    1.0 - ((nn & 0x7fffffff) as f64 / 1073741824.0)
}

fn smooth_step(t: f64) -> f64 {
    t * t * (3.0 - 2.0 * t)
}

fn noise1d(x: f64) -> f64 {
    let x0 = x.floor() as i64;
    let x1 = x0 + 1;

    let t = smooth_step(x - x.floor());

    let n0 = hash(x0);
    let n1 = hash(x1);

    n0 * (1.0 - t) + n1 * t
}

#[export_module]
pub mod math {

    /// compute the sine of a value
    pub fn sin(value: f64) -> f64 {
        value.sin()
    }

    /// compute the cosine of a value
    pub fn cos(value: f64) -> f64 {
        value.cos()
    }

    pub fn sinh(value: f64) -> f64 {
        value.sinh()
    }

    pub fn cosh(value: f64) -> f64 {
        value.sinh()
    }

    pub fn floor(value: f64) -> f64 {
        value.floor()
    }

    pub fn ceil(value: f64) -> f64 {
        value.ceil()
    }

    /// round a value to the nearest whole number
    pub fn round(value: f64) -> f64 {
        value.round()
    }

    /// clamp the value to be between a and b
    pub fn clamp(value: f64, a: f64, b: f64) -> f64 {
        value.clamp(a, b)
    }

    /// compute the abolute value of a number
    pub fn abs(value: f64) -> f64 {
        value.abs()
    }

    /// generates noise based on an input number, returns a range between 0-1
    pub fn noise(value: f64) -> f64 {
        fit(noise1d(value), -1.0, 1.0, 0.0, 1.0)
    }

    pub fn smoothstep(value: f64) -> f64 {
        smooth_step(value)
    }

    /// remap a value from one range to another
    pub fn fit(value: f64, old_min: f64, old_max: f64, new_min: f64, new_max: f64) -> f64 {
        new_min + (value - old_min) * (new_max - new_min) / (old_max - old_min)
    }

    /// remap a value form one range to another, without exceeding the limit of the new range
    pub fn fit_clamped(value: f64, old_min: f64, old_max: f64, new_min: f64, new_max: f64) -> f64 {
        let t = ((value - old_min) / (old_max - old_min)).clamp(0.0, 1.0);
        new_min + t * (new_max - new_min)
    }

    /// remap a value between 0 and 1 to a different range
    pub fn fit01(value: f64, min: f64, max: f64) -> f64 {
        fit(value, 0.0, 1.0, min, max)
    }
}
