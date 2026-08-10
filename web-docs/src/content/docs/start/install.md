---
title: Installation
description: Install Lumit on Windows, Linux or macOS.
sidebar:
  order: 1
---

Free and open source under GPLv3. You do not need an account or licence key. Download the
build for your platform from [lumitlab.com/download](https://lumitlab.com/download) and run
it.

## What you need

Lumit is GPU-first: the whole render pipeline lives on the graphics card and there is no
software-rendering fallback. You need a GPU that supports **Vulkan**, **Direct3D 12** or
**Metal** - which in practice means any discrete card or integrated graphics from roughly
2016 onwards.

## Windows

Download the `.exe` installer and run it. It registers `.lum` (projects) and `.lumfx`
(effect presets), so double-clicking either opens Lumit.

The build is not code-signed yet, so SmartScreen will show a blue "Windows protected your
PC" panel on first run. Choose **More info → Run anyway**. Code signing is on the list; it
needs a certificate, which costs money the project does not currently spend.

## Linux

Download the `.flatpak` and install it:

```bash
flatpak install lumit-*.flatpak
```

Lumit then appears in your applications menu like any other program. FFmpeg ships inside
the bundle, so there is nothing else to install; the GNOME runtime it builds on is fetched
from Flathub on first install if you do not already have it.

Any distribution with Flatpak works — the point of shipping this way is that Lumit does not
care whether you run Ubuntu, Fedora or Arch. If your distribution does not have Flatpak set
up, [flathub.org/setup](https://flathub.org/setup) covers it in a couple of commands.

`.lum` and `.lumfx` file associations are the one thing the Flatpak cannot give you:
Flatpak only exports icons named after the application itself, so double-click-to-open
needs a native install — run `packaging/linux/install.sh` from a clone of the repository
instead.

## macOS

:::caution[Experimental]
The macOS build is Apple silicon only, is **not notarised**, and the Metal path is not yet
verified on the full range of hardware. Treat it as a preview rather than a daily driver
until the macOS pass lands.
:::

Gatekeeper will refuse to open an unnotarised app on a double-click. Right-click the app in
Finder and choose **Open**, then confirm at the prompt - this only has to be done once.

## Building from source

Clone the repository and follow the README. The engine is Rust and the interface is
Flutter; CI builds these same artefacts on every tagged release, so a local build should
match what the download page serves.

```bash
git clone https://github.com/luminalmvm/Lumit.git
```

## Updating

Lumit does not update itself yet. New releases are announced on the
[GitHub releases page](https://github.com/luminalmvm/Lumit/releases) - install over the top
of an existing copy to upgrade.
