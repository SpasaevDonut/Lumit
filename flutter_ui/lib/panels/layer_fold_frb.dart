// What a layer shows when it is twirled open in the Timeline: the section
// headings, and the property rows under whichever of them are open.
//
// **One list, two halves.** The Timeline is a table: names on the left, lanes on
// the right, and a row of one has to be the same height as the row of the other
// or every bar drifts away from its own layer. So the fold-out is worked out
// *once*, as a list of rows, and each half walks the same list — the outline
// drawing each row's controls, the lane side leaving each row's height. Nothing
// has to be kept in step by hand because there is only one description of it.
//
// **The groups.** Transform always (every layer has one), Effects when the layer
// has any, Audio only when the layer's source actually carries sound
// (docs/07 §4.3). Masks and Retime are not built yet. A group is a heading with
// its own twirl, so opening a layer shows a tidy list of headings and you open
// only the one you want — which is what the spec asks for and what keeps a busy
// comp from becoming a wall of numbers.

import 'package:lumit_flutter/src/rust/api/effect.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';

import 'effect_param_row_frb.dart';
import 'transform_rows_frb.dart';

/// One row of a layer's fold-out.
sealed class LayerFoldRow {
  /// How far this row is indented — 1 for a section heading, 2 for a property
  /// under one, 3 for a parameter under an effect.
  final int depth;
  const LayerFoldRow(this.depth);
}

/// A section heading with its own twirl: Transform, Effects, an effect, Audio.
final class FoldGroupRow extends LayerFoldRow {
  /// Identifies this group in the open set. Built from ids, not labels, so two
  /// effects of the same kind on one layer open independently.
  final String path;
  final String label;
  final bool open;
  const FoldGroupRow({
    required this.path,
    required this.label,
    required this.open,
    required int depth,
  }) : super(depth);
}

/// One transform property group — Position, Scale, and so on.
final class FoldTransformRow extends LayerFoldRow {
  final TransformGroup group;
  const FoldTransformRow(this.group, {required int depth}) : super(depth);
}

/// One parameter of one effect.
final class FoldEffectParamRow extends LayerFoldRow {
  final BridgeEffectInstance effect;
  final BridgeParamInfo param;
  const FoldEffectParamRow(this.effect, this.param, {required int depth})
      : super(depth);
}

/// The layer's Volume.
final class FoldVolumeRow extends LayerFoldRow {
  const FoldVolumeRow({required int depth}) : super(depth);
}

/// The path of a layer's Transform group in the open set.
String transformPath(String layerId) => '$layerId/transform';

/// The path of a layer's Effects group.
String effectsPath(String layerId) => '$layerId/effects';

/// The path of one effect within the Effects group.
String effectPath(String layerId, String effectId) =>
    '$layerId/effects/$effectId';

/// The path of a layer's Audio group.
String audioPath(String layerId) => '$layerId/audio';

/// The rows to draw under an open layer, in order.
///
/// `hasAudio` is passed in rather than asked for here because answering it means
/// probing the file with FFmpeg, which is not work for a build — the Timeline
/// caches it per layer, exactly as the Project panel caches missing media.
List<LayerFoldRow> layerFoldRows({
  required LayerReference layer,
  required Set<String> open,
  required bool hasAudio,
}) {
  final id = layer.internallayerId.toString();
  final rows = <LayerFoldRow>[];

  final transformOpen = open.contains(transformPath(id));
  rows.add(FoldGroupRow(
    path: transformPath(id),
    label: 'Transform',
    open: transformOpen,
    depth: 1,
  ));
  if (transformOpen) {
    for (final group in transformGroups(threeD: layer.isThreeD())) {
      rows.add(FoldTransformRow(group, depth: 2));
    }
  }

  // Effects appear only once there are some: an empty heading is a promise the
  // row cannot keep.
  final effects = layer.getEffects();
  if (effects.isNotEmpty) {
    final effectsOpen = open.contains(effectsPath(id));
    rows.add(FoldGroupRow(
      path: effectsPath(id),
      label: 'Effects',
      open: effectsOpen,
      depth: 1,
    ));
    if (effectsOpen) {
      for (final effect in effects) {
        final path = effectPath(id, effect.id().toString());
        final effectOpen = open.contains(path);
        rows.add(FoldGroupRow(
          path: path,
          label: effectLabel(effect),
          open: effectOpen,
          depth: 2,
        ));
        if (effectOpen) {
          for (final param in cachedListParameters(effect.name())) {
            rows.add(FoldEffectParamRow(effect, param, depth: 3));
          }
        }
      }
    }
  }

  if (hasAudio) {
    final audioOpen = open.contains(audioPath(id));
    rows.add(FoldGroupRow(
      path: audioPath(id),
      label: 'Audio',
      open: audioOpen,
      depth: 1,
    ));
    if (audioOpen) rows.add(const FoldVolumeRow(depth: 2));
  }

  return rows;
}

/// An effect's display label, falling back to its match name for one this build
/// does not know about. The schema behind it is the session-cached copy.
String effectLabel(BridgeEffectInstance effect) => effectLabelOf(effect.name());
