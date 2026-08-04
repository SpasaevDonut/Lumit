---
title: Audio
description: Audio layers, waveforms, and beat markers.
sidebar:
  order: 15
---

:::caution[Not implemented yet]
Audio is the largest gap in Lumit today. Audio layers, waveform display, mixing, and beat-driven markers are all specified but none of them are built.

The menu commands for it are listed and disabled, marked *(Not implemented)*, so you can see what is coming. Progress is tracked on [GitHub](https://github.com/luminalmvm/Lumit/issues).
:::

## What is planned

| Feature | What it will do |
| --- | --- |
| **Audio layer** | A layer whose source is an audio item, or the audio of a footage item. |
| **Waveform** | A live waveform drawn on the layer in the timeline. |
| **Mixing** | Several audio layers per composition, mixed together. |
| **Beat markers** | Markers generated from audio onset detection, to cut and animate against. |

The audio clock is also intended to be the master everything else syncs to.

## What works today

Footage keeps its audio, and export writes it. You cannot yet see it, edit it, or
animate against it inside Lumit.

## Related

- [Keyframes](/use/keyframes/) — markers.
- [Exporting](/use/export/)
