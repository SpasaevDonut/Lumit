---
title: Caching
description: How Lumit avoids computing the same frame twice.
sidebar:
  order: 4
---

Rendering a frame is expensive. Lumit stores what it computes and reuses it.

## Keyed by content, not by position

A cache entry is named by a hash of everything that produced it, never by its position
on the timeline.

Move a layer in time and its frames stay valid - the content did not change, only where
it sits. A cache keyed by timeline position would throw all that away.

## Three tiers

| Tier | Speed | Size |
| --- | --- | --- |
| **VRAM** | Fastest | Smallest |
| **RAM** | Fast | Larger |
| **Disk** | Slowest | Largest, and survives a restart |

Frames move down the tiers as they age. Eviction runs to a byte budget.

## What you see

The **cache bar** under the time ruler shows which frames are ready, per tier. A full
bar means playback will be smooth.

## Related

- [Preview and playback](/use/preview/)
- [The render pipeline](/engine/render-pipeline/)
