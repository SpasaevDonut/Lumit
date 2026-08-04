---
title: The render pipeline
description: How a layer stack becomes a frame.
sidebar:
  order: 2
---

## From stack to frame

Your layer stack is a document. To draw it, Lumit compiles it into an **evaluation
graph**: a graph of the work needed for one frame.

Compiling does three useful things:

1. It folds identical work together, so two layers using one source decode it once.
2. It gives every piece of work a name derived from its content.
3. It makes the work cancellable, so a change part-way through abandons cleanly.

You never see this graph. It is an internal step.

## Content hashing

Each piece of work is named by a hash of everything that affects its result: the
source, the parameters, the time, the effects above it.

Two things that hash the same *are* the same, so the answer can be reused. Change a
parameter and only what depended on it is recomputed.

This is why the [cache](/engine/cache/) survives edits that would invalidate a
position-keyed cache.

## Order of operations

For each layer, bottom to top: source, then Retime, then masks, then effects, then
transform, then blend into the composite below.

Getting this order right is why a blur before a glow looks different from a glow before
a blur.

## Related

- [Caching](/engine/cache/)
- [Time and precision](/engine/time/)
