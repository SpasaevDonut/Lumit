---
title: Effects
description: Apply effects, order them, and the built-in roster.
sidebar:
  order: 9
---

An **effect** is one operation in a layer's **effect stack**. The stack runs
top-to-bottom.

## Apply an effect

1. Select one or more layers.
2. Choose **Effect**, then a category, then the effect.

The **Effect** menu applies to every selected layer at once. With nothing selected, the
whole menu is disabled.

You can also drag an effect from the Effects & Presets panel onto a layer.

## Edit the parameters

Select the layer and open the **Effect Controls** panel. Every parameter can be
animated. Turn on a stopwatch to start. See [Keyframes](/use/keyframes/).

## Order matters

Effects run in stack order. A blur before a glow does not look like a glow before a
blur. Drag an effect up or down the stack to reorder it.

## Apply one effect to many layers

Put the effect on an **adjustment layer**. It then applies to the composite of
everything below it. See [Layers](/use/layers/).

## The built-in roster

Thirty-three effects ship today.

**Blur and sharpen** — Gaussian blur, Directional blur, Radial blur, Sharpen, Unsharp
mask, Depth of field.

**Motion** — Motion blur, Fast motion blur, Echo, Posterize time.

**Colour** — Colour balance, Contrast, Exposure, Gamma, Hue shift, Invert, Saturation,
Temperature, Tint, Vibrancy, LUT.

**Stylise** — Glow, Flash, Vignette, Scanlines.

**Distort and damage** — Chromatic aberration, RGB split, Block glitch, Datamosh, Shake,
Transform.

**Matte** — Screen matte.

**Lens** — Lens options.

### The three kinds of motion blur

They are easy to confuse:

| What | Where | Does |
| --- | --- | --- |
| Motion blur **switch** | A layer switch | Smears one layer along its own transform. |
| **Motion blur** effect | The effect stack | Re-renders the scene below at sub-frame times and averages. |
| **Fast motion blur** effect | The effect stack | Smears motion already inside the footage, in one pass. |

## Plugins

OFX and LFX plugins will appear beside the built-in effects.

:::caution[Not implemented yet]
Plugin hosting is specified but not built.
:::

## Related

- [Layers](/use/layers/)
- [Keyframes](/use/keyframes/)
