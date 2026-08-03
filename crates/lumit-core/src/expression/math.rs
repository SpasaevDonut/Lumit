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

    pub fn to_f64(value: Dynamic) -> f64 {
        if value.is_int() {
            return value.as_int().unwrap() as f64;
        }

        if value.is_float() {
            return value.as_float().unwrap();
        }

        if value.is_bool() {
            if value.as_bool().unwrap() {
                return 1.0;
            } else {
                return 0.0;
            }
        }

        return -1.0;
    }

    /// compute the sine of a value
    pub fn sin(value: Dynamic) -> f64 {
        to_f64(value).sin()
    }

    /// compute the cosine of a value
    pub fn cos(value: Dynamic) -> f64 {
        to_f64(value).cos()
    }

    pub fn sinh(value: Dynamic) -> f64 {
        to_f64(value).sinh()
    }

    pub fn cosh(value: Dynamic) -> f64 {
        to_f64(value).sinh()
    }

    pub fn floor(value: Dynamic) -> f64 {
        to_f64(value).floor()
    }

    pub fn ceil(value: Dynamic) -> f64 {
        to_f64(value).ceil()
    }

    /// round a value to the nearest whole number
    pub fn round(value: Dynamic) -> f64 {
        to_f64(value).round()
    }

    /// clamp the value to be between a and b
    pub fn clamp(value: Dynamic, a: Dynamic, b: Dynamic) -> f64 {
        to_f64(value).clamp(to_f64(a), to_f64(b))
    }

    /// compute the abolute value of a number
    pub fn abs(value: Dynamic) -> f64 {
        to_f64(value).abs()
    }

    /// generates noise based on an input number, returns a range between 0-1
    pub fn noise(value: Dynamic) -> f64 {
        fit(
            Dynamic::from_float(noise1d(to_f64(value))),
            Dynamic::from_float(-1.0),
            Dynamic::from_float(1.0),
            Dynamic::from_float(0.0),
            Dynamic::from_float(1.0),
        )
    }

    pub fn smoothstep(value: Dynamic) -> f64 {
        smooth_step(to_f64(value))
    }

    /// remap a value from one range to another
    pub fn fit(
        value: Dynamic,
        old_min: Dynamic,
        old_max: Dynamic,
        new_min: Dynamic,
        new_max: Dynamic,
    ) -> f64 {
        let value = to_f64(value);
        let old_min = to_f64(old_min);
        let old_max = to_f64(old_max);
        let new_min = to_f64(new_min);
        let new_max = to_f64(new_max);
        new_min + (value - old_min) * (new_max - new_min) / (old_max - old_min)
    }

    /// remap a value form one range to another, without exceeding the limit of the new range
    pub fn fit_clamped(
        value: Dynamic,
        old_min: Dynamic,
        old_max: Dynamic,
        new_min: Dynamic,
        new_max: Dynamic,
    ) -> f64 {
        let value = to_f64(value);
        let old_min = to_f64(old_min);
        let old_max = to_f64(old_max);
        let new_min = to_f64(new_min);
        let new_max = to_f64(new_max);

        let t = ((value - old_min) / (old_max - old_min)).clamp(0.0, 1.0);
        new_min + t * (new_max - new_min)
    }

    /// remap a value between 0 and 1 to a different range
    pub fn fit01(value: Dynamic, min: Dynamic, max: Dynamic) -> f64 {
        fit(
            value,
            Dynamic::from_float(0.0),
            Dynamic::from_float(1.0),
            min,
            max,
        )
    }
}
