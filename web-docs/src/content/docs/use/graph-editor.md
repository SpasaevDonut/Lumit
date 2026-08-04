---
title: The graph editor
description: Edit the curve between keyframes, by value or by speed.
sidebar:
  order: 6
---

The graph editor shows a property as a curve rather than as keyframes. Use it when the
timing matters more than the values.

## The two views

| View | Shows |
| --- | --- |
| **Value graph** | The value against time. |
| **Speed graph** | The rate of change against time. |

Both views show the same data. Editing one changes the other. Neither is a separate
copy.

Use the value graph to ask *where is it?* Use the speed graph to ask *how fast is it
going?*

## Edit a curve

- Drag a keyframe to change its value and time.
- Drag a handle to change the curve's shape.
- Select several keyframes to move them together.

Ease a move in and out by pulling the handles flat at each end. The speed graph makes
this easier to judge, because a flat line means a constant rate.

## Retime in the graph editor

A retimed layer shows its Retime as a graph channel with two lenses. The value lens is
labelled **Time**, and the derivative lens is labelled **Velocity**. Those two labels
are inherited from After Effects and Vegas.

Everywhere else, Lumit calls the quantity **speed**.

See [Retiming and speed](/use/retime/).

## Related

- [Keyframes](/use/keyframes/)
- [Retiming and speed](/use/retime/)
