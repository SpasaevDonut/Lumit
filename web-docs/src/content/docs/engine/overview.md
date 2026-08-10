---
title: How Lumit is built
description: The engine, the interface, and why they are separate.
sidebar:
  order: 1
---

This section explains what is behind the application. You do not need any of it to use
Lumit. Read it if you want to know why the application behaves as it does, or if you
mean to work on it.

## Two halves

| Half | What it is | Why |
| --- | --- | --- |
| **The engine** | Rust | It holds the document, decides what to draw, and draws it. Rust makes whole classes of crash impossible. |
| **The interface** | Flutter | It draws panels and forwards what you do. It holds no logic of its own. |

Everything decides in the engine. The interface displays values and forwards commands.
That split is deliberate: it keeps one source of truth, and it means the engine can be
driven without any interface at all, which is how the tests and the exporter run.

## The engine is small crates, not one lump

The engine is split into focused libraries: the document model, the evaluation graph,
the GPU layer, media, audio, the cache, text, the file format, and the pixel pass.

Small pieces keep builds fast and make the seams explicit. The rule that matters: an
engine crate never depends on the interface.

## GPU first

The whole picture pipeline lives on the graphics card, through a portable GPU layer
that speaks Direct3D 12 on Windows, Vulkan on Linux, and Metal on macOS. Effects are
compute shaders.

There is no software fallback. That is why Lumit asks for a modern GPU.

## Related

- [The render pipeline](/engine/render-pipeline/)
- [Time and precision](/engine/time/)
- [Caching](/engine/cache/)
- [How Lumit stays fast](/engine/performance/)
