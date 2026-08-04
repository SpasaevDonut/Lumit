---
title: Your first composition
description: Import footage, build a composition, animate it and export.
sidebar:
  order: 2
---

:::note[Being written]
This page is a stub while the beta settles. If you hit something confusing before it is
finished, open an issue on
[GitHub](https://github.com/luminalmvm/Lumit/issues) — that is the fastest way to get it
documented.
:::

## The shape of a project

A Lumit project is a single `.lum` file. Inside it are **compositions**, and inside those
are **layers** stacked in order — footage, solids, text, shapes, and nested sequences.
Effects attach to layers, and almost every value on a layer or effect can be keyframed.

## Getting footage in

Drag files into the project panel, or use **File → Import**. Lumit decodes with FFmpeg and
will use hardware decoding where the platform offers it.

## Animating

Every animatable property has a stopwatch beside it. Turn it on and Lumit writes a keyframe
whenever the value changes; the graph editor gives you the curve between them. Speed ramps
and retiming live on the layer itself rather than in a separate dialog.

## Exporting

**File → Export** queues the composition. Export runs off the interface thread, so the
editor stays interactive while it works.
