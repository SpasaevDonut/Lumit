---
title: Time and precision
description: Why Lumit stores time as exact fractions.
sidebar:
  order: 3
---

## The problem with decimals

At 29.97 frames per second, one frame is 1001/30000 of a second. As a decimal that is
0.033366666… — it does not terminate.

Store times as decimals and small errors accumulate. After an hour a frame lands a
frame early or late. Editors know this as drift.

## What Lumit does

Lumit stores time as an **exact fraction** — a whole-number numerator over a
whole-number denominator. 1001/30000 is stored as exactly that, not as an
approximation.

Arithmetic on fractions stays exact. There is no drift to accumulate, however long the
project or however many nested retimes it passes through.

## Four timebases

Time means different things at different depths, so Lumit names them separately:

| Timebase | Measured from |
| --- | --- |
| **Source time** | The start of the media file, before any retiming. |
| **Clip time** | The start of a clip, inside a Sequence layer. |
| **Layer time** | A layer's in point. |
| **Comp time** | The start of the composition. |

Keeping them distinct is what stops a nested retime inside a precomp inside a sequence
from quietly losing a frame.

## What this buys you

- A [speed ramp](/use/retime/) lands on the frame you asked for.
- Changing a composition's frame rate does not move your keyframes.
- Nesting does not accumulate error.

## Related

- [Retiming and speed](/use/retime/)
- [The render pipeline](/engine/render-pipeline/)
