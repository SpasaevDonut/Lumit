---
title: Exporting
description: Write a finished file.
sidebar:
  order: 18
---

**Export** writes a deliverable file. Lumit says *export* for what you produce, and
*render* only for what the engine does internally.

## Export a composition

1. Select the composition.
2. Choose **File ▸ Export**.
3. Set the format and destination.
4. Start it.

## Export does not block you

Export runs away from the interface. You can keep editing while it writes.

## Export is always full quality

[Adaptive degradation](/use/preview/) and preview resolution affect preview only. An
export always renders at full quality.

Export may **bake** internally — flattening retimes, rasterising, pre-compositing — to
go faster. Baking happens inside the export pipeline and never alters your project.

## Related

- [Preview and playback](/use/preview/)
- [Compositions](/use/compositions/)
