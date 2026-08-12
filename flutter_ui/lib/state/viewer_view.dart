// What the View menu, the keyboard and the command palette ask the Viewer for
// (docs/07-UI-SPEC.md §2.2, §15).
//
// In plain terms: the magnification and the preview resolution are two
// different things that both sound like "zoom", and this file is where the two
// words are kept apart.
//
// **Magnification** is how big the picture is drawn in the panel. It changes
// nothing about what the engine renders (K-230) — it is display scaling, and
// the arithmetic behind it lives in `panels/viewer_zoom.dart`. The three
// commands here are the named jumps a menu row or a chord can ask for; the
// Viewer panel holds the actual magnification, so the shell *asks* rather than
// reaching into a panel that may not even be mounted.
//
// **Preview resolution** is how many pixels the engine is asked to make. Half
// renders a quarter of them, so a heavy composition previews in a quarter of
// the time and looks correspondingly coarser. It is a real raster reduction,
// not a display trick, and it MUST never reach the export (glossary §5).

import 'package:lumit_flutter/l10n/strings.dart';

/// A named magnification the Viewer can be asked to take.
///
/// Not a number: "fit" is a *rule* (the whole picture in the panel) that has to
/// be re-resolved every time the panel is resized, and a step in or out means
/// "from wherever you are now", which only the Viewer knows.
enum ViewerZoomCommand {
  zoomIn,
  zoomOut,
  fit;

  /// The keymap action id this command answers (K-199, docs/07 §15).
  String get action => switch (this) {
        ViewerZoomCommand.zoomIn => 'viewer.zoom.in',
        ViewerZoomCommand.zoomOut => 'viewer.zoom.out',
        ViewerZoomCommand.fit => 'viewer.zoom.fit',
      };

  /// What the View menu's row reads.
  String get title => switch (this) {
        ViewerZoomCommand.zoomIn => l10n.menuZoomIn,
        ViewerZoomCommand.zoomOut => l10n.menuZoomOut,
        ViewerZoomCommand.fit => l10n.menuFit,
      };
}

/// The fraction of composition resolution a preview frame is rendered at.
///
/// Full / Half / Quarter are the three the View menu and the keymap carry
/// (docs/07 §15). §2.2's dropdown also offers Third and Auto and stores the
/// choice per composition; neither is built yet — see docs/TODO.md.
enum PreviewResolution {
  full,
  half,
  quarter;

  /// What the engine's render scale is multiplied by.
  double get scale => switch (this) {
        PreviewResolution.full => 1.0,
        PreviewResolution.half => 0.5,
        PreviewResolution.quarter => 0.25,
      };

  /// The keymap action id this resolution answers.
  String get action => switch (this) {
        PreviewResolution.full => 'viewer.res.full',
        PreviewResolution.half => 'viewer.res.half',
        PreviewResolution.quarter => 'viewer.res.quarter',
      };

  /// What the View ▸ Resolution row reads.
  String get title => switch (this) {
        PreviewResolution.full => l10n.menuFull,
        PreviewResolution.half => l10n.menuHalf,
        PreviewResolution.quarter => l10n.menuQuarter,
      };
}
