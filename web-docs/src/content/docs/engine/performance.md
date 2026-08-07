---
title: How Lumit stays fast
description: The rules the application is held to.
sidebar:
  order: 5
---

Lumit's central claim is that playback keeps up. A few rules protect it.

## The interface never renders a frame

Panels are drawn by the interface; pictures are drawn by the engine, elsewhere. A slow
frame can make the picture late. It cannot make a button late.

This is why the application still answers while it is busy, including during an export.

## Cancellation everywhere

Long work is cancellable. Change something mid-render and the old work is abandoned
rather than finished and discarded.

## Adaptive degradation, but only while you interact

Under load the engine may lower resolution or skip effects to stay responsive. This
applies to interaction only, and can never affect an [export](/use/export/).

## Budgets are tests

The performance claims are enforced in continuous integration rather than asserted in
documentation. A change that breaks a budget fails the build.

## Determinism

The same project renders the same pixels. This is a hard requirement, not an
aspiration - it is what makes the cache safe to trust and bugs possible to reproduce.

## Related

- [Preview and playback](/use/preview/)
- [Caching](/engine/cache/)
