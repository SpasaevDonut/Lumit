// What the Ctrl+Space console's radial menu offers, given what is selected
// (K-324) — and the snapshot the console's camera button writes.
//
// **In plain terms.** A radial menu is only worth having if what is in it is
// what you were about to do. So the ring is not one fixed set of commands: it
// is chosen from the selection, in the order the panels themselves are worked
// in. An effect picked out in the stack offers the things you do to an effect;
// a layer selected with no effect picked offers the things you do to *that*
// layer — creation sits one flick further, behind a New slice that expands
// into the Layer ▸ New ring (K-325), never loose beside the selection's own
// actions; a composition open with nothing selected offers the new-layer menu
// directly, because that is what an empty timeline is for; and with no
// composition at all the ring offers the two ways to get one.
//
// Each ring is at most six entries, on purpose. The whole value of a radial
// menu is that a direction becomes muscle memory, and a ring of twelve is a
// ring nobody learns — the long tail belongs in the search bar beside it,
// which is where it is.
//
// This file is kept apart from `fx_console_frb.dart` so the console widget
// stays a thing that draws what it is given: the widget knows nothing about
// the document, and this is where the document knowledge lives.

import 'dart:io';

import 'package:flutter/widgets.dart';

import '../l10n/strings.dart';
import '../main.dart';
import '../panels/effect_param_row_frb.dart' show effectLabelOf;
import '../src/rust/api/export.dart';
import '../state/dock.dart';
import 'fx_console_frb.dart';
import 'menu_bar_frb.dart';
import 'precompose_dialog_frb.dart';

/// What the ring is about, drawn in its middle so the context is never a
/// guess: the picked effect's name, the selected layer's, the composition's,
/// or a plain hint when there is nothing to act on.
String fxConsoleContextTitle(LumitUiState ui) {
  final effect = _pickedEffectName(ui);
  if (effect != null) return effect;
  final layer = ui.selectedLayer.value;
  if (layer != null) {
    final entry = ui.model.byId(layer.internallayerId);
    if (entry != null) return entry.info.name;
  }
  final comp = ui.selectedComp;
  if (comp != null) return comp.getSettings().name;
  return l10n.fxConsoleNothingSelected;
}

/// The picked effect's display name, or null when none is picked.
String? _pickedEffectName(LumitUiState ui) {
  final picked = ui.selectedEffects.value;
  final layer = ui.selectedEffectsLayer;
  if (picked.isEmpty || layer == null) return null;
  final entry = ui.model.byId(layer.internallayerId);
  if (entry == null) return null;
  for (final effect in entry.info.effects) {
    if (effect.id == picked.first) return effectLabelOf(effect.name);
  }
  return null;
}

/// The ring for the current selection — see this file's header for the order
/// the four contexts are tried in.
List<RadialEntry> fxConsoleRadial(
  BuildContext context,
  LumitState app,
  LumitUiState ui,
) {
  final comp = ui.selectedComp;
  final layer = ui.selectedLayer.value;
  final picked = ui.selectedEffects.value;
  final effectsLayer = ui.selectedEffectsLayer;

  void done() => app.notifyDocumentChanged();

  // 1. An effect is picked: what you do to an effect.
  if (picked.isNotEmpty && effectsLayer != null) {
    final entry = ui.model.byId(effectsLayer.internallayerId);
    final instances = entry?.info.effects ?? const [];
    final target = instances.where((e) => e.id == picked.first).firstOrNull;
    return [
      RadialEntry(
        label: target?.enabled ?? true ? l10n.tipDisable : l10n.tipEnable,
        enabled: target != null,
        run: () {
          for (final instance in effectsLayer.getEffects()) {
            if (instance.id() == picked.first) {
              effectsLayer.setEffectEnabled(
                  effect: instance, enabled: !(target?.enabled ?? true));
              break;
            }
          }
          done();
        },
      ),
      RadialEntry(
        label: l10n.menuCopy,
        enabled: target != null,
        run: () => copySelectionFrb(ui),
      ),
      RadialEntry(
        label: l10n.tipRemove,
        enabled: target != null,
        run: () {
          for (final instance in effectsLayer.getEffects()) {
            if (instance.id() == picked.first) {
              effectsLayer.removeEffect(effect: instance);
              break;
            }
          }
          done();
        },
      ),
      RadialEntry(
        label: l10n.fxConsoleAddEffect,
        run: () => ui.activePanel.value = Panel.effectsAndPresets,
      ),
    ];
  }

  // The new-layer ring, in the order Layer ▸ New lists them, so the two
  // surfaces teach the same directions for the same things.
  List<RadialEntry> newLayers() => [
        RadialEntry(
          label: l10n.menuSolid,
          run: () {
            comp!.addSolidLayer();
            done();
          },
        ),
        RadialEntry(
          label: l10n.menuText,
          run: () {
            comp!.addTextLayer();
            done();
          },
        ),
        RadialEntry(
          label: l10n.menuCamera,
          run: () {
            comp!.addCameraLayer();
            done();
          },
        ),
        RadialEntry(
          label: l10n.menuAdjustment,
          run: () {
            comp!.addAdjustmentLayer();
            done();
          },
        ),
        RadialEntry(
          label: l10n.menuNull,
          run: () {
            comp!.addNullLayer();
            done();
          },
        ),
        RadialEntry(
          label: l10n.menuSequence,
          run: () {
            comp!.addSequenceLayer();
            done();
          },
        ),
      ];

  // 2. A layer is selected: what you do to THIS layer — never a grab-bag of
  //    creation commands beside it (K-325). Creating sits one level down,
  //    behind a New slice that expands into the Layer ▸ New ring, so it is
  //    reachable without being mistaken for something about the selection.
  if (layer != null && comp != null) {
    return [
      RadialEntry(
        label: l10n.menuDuplicate,
        run: () {
          layer.duplicate();
          done();
        },
      ),
      RadialEntry(
        label: l10n.fxConsoleAddEffect,
        run: () => ui.activePanel.value = Panel.effectsAndPresets,
      ),
      RadialEntry(
        label: l10n.menuPreCompose,
        run: () => showPrecomposeDialogFrb(
          context: context,
          comp: comp,
          selectedLayers: ui.selectedLayers.value,
          ui: ui,
          workspace: ui.workspace,
        ),
      ),
      RadialEntry(
        label: l10n.delete,
        run: () {
          layer.delete();
          done();
        },
      ),
      RadialEntry(label: l10n.menuNew, children: newLayers()),
    ];
  }

  // 3. A composition, nothing selected in it: the new-layer menu directly,
  //    which is what an empty timeline is asking for — plus Import, the other
  //    way something gets into a comp.
  if (comp != null) {
    return [
      ...newLayers().take(5),
      RadialEntry(
        label: l10n.menuImport,
        run: () => importFootageFrb(app),
      ),
    ];
  }

  // 4. Nothing open at all: the two ways to get somewhere.
  return [
    RadialEntry(
      label: l10n.newComposition,
      run: () => newCompositionFrb(context, app),
    ),
    RadialEntry(
      label: l10n.menuImport,
      enabled: app.project != null,
      run: () => importFootageFrb(app),
    ),
  ];
}

/// Write the frame on screen to a PNG (K-324).
///
/// It is a one-frame **export**, not a new engine path: the exporter already
/// writes PNGs (`codec: 'png'`, K-201) and is the tested way a Lumit frame
/// becomes a file, so a snapshot is that with the range set to the playhead
/// and the frame after it. The alternative — a second still-writer beside the
/// exporter — is a second thing to keep correct about colour and size for no
/// gain. The engine numbers an image sequence `<stem>.00001.png`, so the frame
/// number lands in the file name whatever this passes.
///
/// Nothing is reported here beyond what the status line already says: the
/// strip polls the exporter and shows the finished path itself, which is the
/// same feedback any other export gives.
void saveSnapshotFrb(LumitState app, LumitUiState ui) {
  final comp = ui.selectedComp;
  if (comp == null) return;
  final path = snapshotPathFor(
    compName: comp.getSettings().name,
    projectPath: app.project?.path(),
  );
  try {
    comp.startExport(
      spec: BridgeExportSpec(
        preset: '',
        codec: 'png',
        width: 0,
        height: 0,
        bitrateMbps: 0,
        fps: 0,
        rangeStartFrame: ui.playheadFrame.value,
        rangeEndFrame: ui.playheadFrame.value + 1,
        includeAudio: false,
        audioBitRate: 0,
      ),
      path: path,
    );
  } on Object {
    // An export already running is the everyday refusal, and a calm one: the
    // status line is already showing that export's progress, which answers
    // the question better than a window over a console just dismissed.
  }
}

/// Where a snapshot goes: a `Snapshots` folder beside the saved project, so
/// the stills of a job live with the job. An unsaved project has nowhere of
/// its own, so those land in the user's pictures folder instead — never in
/// whatever directory the application happens to have been started from,
/// which is where a bare file name would put them.
///
/// The composition's name is the file's, with anything a file name cannot
/// carry taken out; the engine appends the frame number.
String snapshotPathFor({
  required String compName,
  String? projectPath,
  Map<String, String>? environment,
}) {
  final env = environment ?? Platform.environment;
  final sep = Platform.pathSeparator;
  final safe = compName.replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '').trim();
  final stem = safe.isEmpty ? 'snapshot' : safe;

  if (projectPath != null && projectPath.trim().isNotEmpty) {
    final cut = projectPath.lastIndexOf(RegExp(r'[/\\]'));
    if (cut > 0) {
      return '${projectPath.substring(0, cut)}${sep}Snapshots$sep$stem.png';
    }
  }
  final home = env['USERPROFILE'] ?? env['HOME'] ?? '.';
  return '$home${sep}Pictures${sep}Lumit$sep$stem.png';
}
