//! CC Line Sweep (AE-style sequential wave wipe): reveals stripes one by one
//! as a sweep front moves across the screen. Each stripe's reveal finishes
//! before the next begins — a wave motion. Hard binary step (0 feather).

use crate::GpuContext;
use super::{work_texture, FxEngine};

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CcLineSweepOp {
    pub completion: f32,
    pub dir_cos: f32,
    pub dir_sin: f32,
    pub line_cos: f32,
    pub line_sin: f32,
    pub line_count: i32,
    pub fragment_count: i32,
    pub line_delay: i32,
    pub flip: bool,
    pub mix: f32,
}

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct CcLineSweepParams {
    completion: f32,
    dir_cos: f32,
    dir_sin: f32,
    line_cos: f32,
    line_sin: f32,
    line_count: i32,
    fragment_count: i32,
    line_delay: i32,
    flip: u32,
    mix_amt: f32,
}

impl FxEngine {
    pub fn cc_line_sweep(
        &self, ctx: &GpuContext, src: &wgpu::Texture,
        w: u32, h: u32, op: &CcLineSweepOp,
    ) -> wgpu::Texture {
        let out = work_texture(ctx, w, h, "fx-cclinesweep-out");
        self.dispatch(ctx, &self.cc_line_sweep, src, src, &out, w, h,
            bytemuck::bytes_of(&CcLineSweepParams {
                completion: op.completion,
                dir_cos: op.dir_cos,
                dir_sin: op.dir_sin,
                line_cos: op.line_cos,
                line_sin: op.line_sin,
                line_count: op.line_count,
                fragment_count: op.fragment_count,
                line_delay: op.line_delay,
                flip: if op.flip { 1 } else { 0 },
                mix_amt: op.mix,
            }),
        );
        out
    }
}
