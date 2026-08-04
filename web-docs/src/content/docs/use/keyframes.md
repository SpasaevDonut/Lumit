---
title: Keyframes
description: Animate a property, and control how it moves between values.
sidebar:
  order: 5
---

A **keyframe** anchors a value to a time. Lumit works out the values in between.

## Animate a property

1. Move the playhead to where the animation starts.
2. Turn on the stopwatch beside the property.
3. Move the playhead to where it ends.
4. Change the value.

Lumit writes the second keyframe for you. Every later change at a new time adds
another.

Turn the stopwatch off to remove every keyframe on that property and hold one value.

## Move and delete

- Drag a keyframe along the layer's row to move it in time.
- Select several and drag them together.
- Press delete to remove the selected keyframes.

## Interpolation

Each side of a keyframe has its own interpolation:

| Type | Result |
| --- | --- |
| **Hold** | The value does not change until the next keyframe. |
| **Linear** | A straight line to the next value. |
| **Bezier** | A curve you shape by hand. |

A bezier keyframe carries **speed** and **influence**. Speed is the rate of change in
units per second. Influence is how far the handle reaches, as a percentage.

Lumit matches After Effects' keyframe maths, so imported animation keeps its shape.

## Markers

A **marker** is a labelled point on a composition, a layer, or an asset. Use markers to
note where something should happen.

**Beat markers** are markers generated from audio onset detection.

:::note[Partly built]
Beat detection is specified but not finished.
:::

## Related

- [The graph editor](/use/graph-editor/)
- [Retiming and speed](/use/retime/)
- [Expressions](/use/expressions/)
