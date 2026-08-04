---
title: Sequence layers
description: Cut clips back-to-back on a single row.
sidebar:
  order: 8
---

A **Sequence layer** holds an ordered run of **clips** cut back-to-back on one row. It
is Lumit's editing surface, and it behaves the way Vegas does.

The word **clip** only means something inside a Sequence layer. Everywhere else, the
word is [layer](/use/layers/).

## Why use one

Use a Sequence layer when you are cutting rather than compositing. One row holds a whole
run of shots, so the timeline stays short.

## Each clip carries its own

- Source.
- Trim, in and out.
- [Retime](/use/retime/).

## Edit clips

- Drag a clip's edge to trim it.
- Drag a clip along the row to move it.
- Use the razor to split a clip at the playhead.

## What applies to the whole layer

Effects, masks, transforms, and switches on a Sequence layer apply to its **whole
output**, after the clips have been retimed. They are not per-clip.

Apply something to one shot only by splitting it out, or by using a separate layer.

## Related

- [Layers](/use/layers/)
- [Retiming and speed](/use/retime/)
