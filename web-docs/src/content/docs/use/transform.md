---
title: Transforming layers
description: Anchor point, position, scale, rotation, opacity, and parenting.
sidebar:
  order: 4
---

Every layer carries a transform. Twirl the layer open in the timeline to reach it, or
use the gizmo in the Viewer.

## The properties

| Property | What it does |
| --- | --- |
| **Anchor point** | The point the layer scales and rotates around. |
| **Position** | Where the anchor point sits in the composition. |
| **Scale** | Size, as a percentage. |
| **Rotation** | Angle, in degrees. |
| **Opacity** | How much of the layer reaches the composite. |

Every one can be animated. See [Keyframes](/use/keyframes/).

## Move the anchor point

The anchor point decides what a rotation looks like. Move it before you animate, not
after, because moving it later shifts the layer.

Use the anchor point tool in the Viewer to move it without moving the layer.

## The gizmo

Select a layer and the Viewer draws its wireframe and a transform gizmo. Drag the
handles to move, scale, and rotate.

## Parenting

Parent a layer to another and it follows the parent's transform. Its own values then
read as offsets from the parent.

Use a **null layer** as the parent when you want a rig that never draws. One null can
drive many layers at once.

## Related

- [Layers](/use/layers/)
- [Keyframes](/use/keyframes/)
- [Cameras and 3D](/use/camera/)
