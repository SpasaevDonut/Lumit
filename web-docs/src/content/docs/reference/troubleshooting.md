---
title: Troubleshooting
description: What common problems look like, and what to do.
sidebar:
  order: 3
---

## The app will not start

Lumit is GPU-first: the whole render pipeline lives on the graphics card and there is
no software-rendering fallback. You need a GPU that supports Vulkan, Direct3D 12 or
Metal - in practice, any card or integrated graphics from roughly 2016 onwards. On an
older machine, Lumit cannot run.

## Windows shows "Windows protected your PC"

The build is not code-signed yet, so SmartScreen warns on first run. Choose
**More info → Run anyway**. See [Installation](/start/install/).

## macOS refuses to open the app

The macOS build is not notarised, so Gatekeeper refuses a double-click. Right-click
the app in Finder, choose **Open**, and confirm at the prompt. This only has to be
done once. The macOS build is experimental - see [Installation](/start/install/).

## Media shows as missing

The project stores a reference to the file's path, not the file itself. If the file
moves, the asset reports that it is missing. Relink it to the new path and every
layer using it recovers. See [Importing media](/use/importing/).

## Playback is slow, or quality drops while you work

Under load, Lumit reduces quality on its own to keep responding - it may drop
resolution or skip effects while you interact. This is adaptive degradation, and it
only happens during interaction. To get smoother playback: lower the preview
resolution, let the cache fill on a first pass, turn off heavy effects while you block
out timing, or precompose a finished section. See [Preview and playback](/use/preview/).

## The export might look worse than the degraded preview did

It does not. Adaptive degradation and preview resolution affect preview only; an
export always renders at full quality. What you saw degraded was the preview, never
the file. See [Exporting](/use/export/).

## Related

- [Installation](/start/install/)
- [Preview and playback](/use/preview/)
- [Exporting](/use/export/)
