//! CC Image Wipe (docs/08, AE-style gradient-driven transition): reads a
//! referenced gradient layer and fades the source toward transparent where the
//! gradient's chosen property (Luminance / R / G / B / Alpha) falls below the
//! Completion slider. The smoothed edge is controlled by Border Softness
//! (optionally overridden by Auto Softness) and optionally pre-blurred.

use crate::GpuContext;

use super::{work_texture, FxEngine};

/// One resolved CC Image Wipe operation (docs/08, AE-style gradient-driven
/// transition). The gradient texture travels beside the op (like DoF's depth)
/// and is pre-rendered by the caller.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CcImageWipeOp {
    /// 0..1, wipe progress.
    pub completion: f32,
    /// 0..1, smoothstep half-width.
    pub softness: f32,
    /// When true, overrides softness with `completion * (1 - completion) * 2`.
    pub auto_soft: bool,
    /// 0 = Luminance, 1 = Red, 2 = Green, 3 = Blue, 4 = Alpha.
    pub property: u32,
    /// Pre-blur radius on the gradient, in pixels. 0 = no blur.
    pub blur_px: f32,
    /// When true, inverts the gradient comparison.
    pub inverse: bool,
    /// 0..1, blended against the unprocessed input.
    pub mix: f32,
}

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct CcImageWipeParams {
    completion: f32,
    softness: f32,
    auto_soft: u32,
    property: u32,
    inverse: u32,
    mix_amt: f32,
    _pad0: f32,
    _pad1: f32,
}

/// Matches the private `blur::BlurParams` and `fx_blur.wgsl` — the blur
/// pipeline writes to the same struct layout. `dir`: (1,0) = horizontal,
/// (0,1) = vertical. `edge`: 0 transparent, 1 repeat, 2 mirror.
#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct BlurParams {
    dir: [f32; 2],
    radius: f32,
    sigma: f32,
    edge: u32,
    mix_amt: f32,
    _pad: [f32; 2],
}

impl FxEngine {
    /// Apply one CC Image Wipe to a linear working texture, returning a new
    /// texture of the same size. If `blur_px > 0`, the gradient is first
    /// blurred (separable Gaussian, two passes) before the wipe pass.
    /// The wipe pass uses `mb_layout` (3 sampled inputs: src, src/orig,
    /// gradient).
    pub fn cc_image_wipe(
        &self,
        ctx: &GpuContext,
        src: &wgpu::Texture,
        gradient: &wgpu::Texture,
        w: u32,
        h: u32,
        op: &CcImageWipeOp,
    ) -> wgpu::Texture {
        use wgpu::util::DeviceExt;

        // Optional pre-blur on the gradient. When blur > 0, create an
        // intermediate blurred gradient; otherwise use the original.
        let blurred_grad;
        let final_grad: &wgpu::Texture = if op.blur_px > 0.0 {
            blurred_grad = Self::blur_gradient(self, ctx, gradient, w, h, op.blur_px);
            &blurred_grad
        } else {
            gradient
        };

        let out = work_texture(ctx, w, h, "fx-ccwipe-out");
        let params = CcImageWipeParams {
            completion: op.completion,
            softness: op.softness,
            auto_soft: if op.auto_soft { 1 } else { 0 },
            property: op.property,
            inverse: if op.inverse { 1 } else { 0 },
            mix_amt: op.mix,
            _pad0: 0.0,
            _pad1: 0.0,
        };
        let ubuf = ctx
            .device
            .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("fx-ccwipe-params"),
                contents: bytemuck::bytes_of(&params),
                usage: wgpu::BufferUsages::UNIFORM,
            });
        let bind = ctx.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("fx-ccwipe-bind"),
            layout: &self.mb_layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::TextureView(
                        &src.create_view(&Default::default()),
                    ),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::TextureView(
                        &src.create_view(&Default::default()),
                    ),
                },
                wgpu::BindGroupEntry {
                    binding: 2,
                    resource: wgpu::BindingResource::TextureView(
                        &final_grad.create_view(&Default::default()),
                    ),
                },
                wgpu::BindGroupEntry {
                    binding: 3,
                    resource: wgpu::BindingResource::TextureView(
                        &out.create_view(&Default::default()),
                    ),
                },
                wgpu::BindGroupEntry {
                    binding: 4,
                    resource: ubuf.as_entire_binding(),
                },
            ],
        });
        let mut enc = ctx
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("fx-ccwipe-enc"),
            });
        {
            let mut cpass = enc.begin_compute_pass(&wgpu::ComputePassDescriptor {
                label: Some("fx-ccwipe-pass"),
                timestamp_writes: None,
            });
            cpass.set_pipeline(&self.cc_image_wipe);
            cpass.set_bind_group(0, &bind, &[]);
            cpass.dispatch_workgroups(w.div_ceil(8), h.div_ceil(8), 1);
        }
        ctx.queue.submit([enc.finish()]);
        out
    }

    /// Apply a separable Gaussian blur to the gradient texture as a pre-pass.
    /// Returns the blurred texture (owned by the calling method).
    fn blur_gradient(
        &self,
        ctx: &GpuContext,
        grad: &wgpu::Texture,
        w: u32,
        h: u32,
        blur_px: f32,
    ) -> wgpu::Texture {
        let sigma = (blur_px * 0.5).max(1e-3);
        let tmp = work_texture(ctx, w, h, "fx-ccwipe-blur-tmp");
        let out = work_texture(ctx, w, h, "fx-ccwipe-blur-out");
        let blur_params = BlurParams {
            dir: [1.0, 0.0],
            radius: blur_px,
            sigma,
            edge: 1, // Repeat
            mix_amt: 1.0,
            _pad: [0.0; 2],
        };
        self.dispatch(
            ctx,
            &self.blur,
            grad,
            grad,
            &tmp,
            w,
            h,
            bytemuck::bytes_of(&blur_params),
        );
        let blur_params = BlurParams {
            dir: [0.0, 1.0],
            radius: blur_px,
            sigma,
            edge: 1,
            mix_amt: 1.0,
            _pad: [0.0; 2],
        };
        self.dispatch(
            ctx,
            &self.blur,
            &tmp,
            &tmp,
            &out,
            w,
            h,
            bytemuck::bytes_of(&blur_params),
        );
        out
    }
}
