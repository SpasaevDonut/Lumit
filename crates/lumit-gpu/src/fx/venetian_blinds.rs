//! CC Line Sweep (AE-style geometric wipe): generates an alpha mask from a
//! sweeping straight edge (direction angle, slant shear, thickness smoothstep).

use crate::GpuContext;

use super::{work_texture, FxEngine};

/// One resolved CC Line Sweep operation (staggered-line wipe).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct VenetianBlindsOp {
    /// 0..1, wipe progress.
    pub completion: f32,
    /// cos(angle_deg * π/180), the sweep axis x component.
    pub dir_cos: f32,
    /// sin(angle_deg * π/180), the sweep axis y component.
    pub dir_sin: f32,
    /// Number of discrete stripes across the sweep span.
    pub line_count: i32,
    /// 0..1, per-stripe timing variance.
    pub stagger: f32,
    /// When true, inverts the wipe direction.
    pub flip: bool,
    /// 0..1, blended against the unprocessed input.
    pub mix: f32,
}

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct VenetianBlindsParams {
    completion: f32,
    dir_cos: f32,
    dir_sin: f32,
    line_count: i32,
    stagger: f32,
    flip: u32,
    mix_amt: f32,
    _pad0: f32,
}

impl FxEngine {
    /// Apply one CC Line Sweep to a linear working texture, returning a new
    /// texture of the same size. One pointwise pass on the standard layout.
    pub fn venetian_blinds(
        &self,
        ctx: &GpuContext,
        src: &wgpu::Texture,
        w: u32,
        h: u32,
        op: &VenetianBlindsOp,
    ) -> wgpu::Texture {
        let out = work_texture(ctx, w, h, "fx-venetian-blinds-out");
        self.dispatch(
            ctx,
            &self.venetian_blinds,
            src,
            src,
            &out,
            w,
            h,
            bytemuck::bytes_of(&VenetianBlindsParams {
                completion: op.completion,
                dir_cos: op.dir_cos,
                dir_sin: op.dir_sin,
                line_count: op.line_count,
                stagger: op.stagger,
                flip: if op.flip { 1 } else { 0 },
                mix_amt: op.mix,
                _pad0: 0.0,
            }),
        );
        out
    }
}
