---
title: Preview and playback
description: Play the composition back, and understand the cache.
sidebar:
  order: 17
---

**Preview** is playback inside Lumit. It never writes files.

## Play

Press play. The playhead moves and the Viewer shows each frame.

Lumit says *playhead*, never *CTI*.

## The cache

Lumit stores rendered frames so it does not compute them twice. The **cache bar** under
the time ruler shows which frames are ready.

Cache entries are keyed by the content that made them, not by their position in time.
Move a layer and the frames that did not change stay cached.

There are three tiers: VRAM, RAM, and disk.

## Preview resolution

Lower the preview resolution to get more speed: full, half, third, quarter, or auto.
This is real downsampling, and it applies per composition. It never affects export.

## Adaptive degradation

Under load, Lumit reduces quality on its own to keep responding — it may drop
resolution or skip effects while you interact.

This only happens during interaction. It can never affect an export.

## If playback is slow

1. Lower the preview resolution.
2. Let the cache fill on a first pass, then play again.
3. Turn off heavy effects while you block out timing.
4. Precompose a finished section so it caches as one unit.

## Related

- [Exporting](/use/export/)
- [How Lumit stays fast](/engine/performance/)
