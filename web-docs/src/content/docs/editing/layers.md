---
title: Layers
description: How layers, compositions and precomps fit together.
sidebar:
  order: 1
---

:::note[Being written]
A stub. The concepts below are stable; the detail is still being written.
:::

A **composition** holds an ordered stack of **layers**. Layers render bottom to top, each
one contributing pixels and alpha to the frame beneath it.

Layer kinds:

| Kind | What it is |
| --- | --- |
| Footage | Video or an image from the project panel |
| Solid | A flat colour, usually a base for effects |
| Text | Editable type |
| Shape | Vector geometry |
| Sequence | Another composition, nested as a layer |

A **precomp** is a composition used as a layer inside another one — the way to group work
and treat it as a single object.
