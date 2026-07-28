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

import 'package:lumit_flutter/src/rust/api/composition.dart';
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

/// One transform property group — Position, Scale, and so on — with the
/// layer's transform read once for the whole fold (K-183).
final class FoldTransformRow extends LayerFoldRow {
  final TransformGroup group;
  final BridgeTransform transform;
  const FoldTransformRow(this.group, this.transform, {required int depth})
      : super(depth);
}

/// One parameter of one effect — everything the row draws, from the read
/// model (K-184). Plain data; a write reads fresh instance handles at commit.
final class FoldEffectParamRow extends LayerFoldRow {
  final BridgeEffectInstanceInfo info;
  final BridgeParamInfo param;

  /// This parameter's current value, or null when the instance does not carry
  /// it (a schema newer than the saved document).
  final BridgeEffectValue? value;
  const FoldEffectParamRow(this.info, this.param, this.value,
      {required int depth})
      : super(depth);
}

/// The layer's Volume.
final class FoldVolumeRow extends LayerFoldRow {
  const FoldVolumeRow({required int depth}) : super(depth);
}

/// The waveform lane (K-172): the outline names it, the lane side draws the
/// layer's source peaks through its live in/out/offset.
final class FoldWaveformRow extends LayerFoldRow {
  const FoldWaveformRow({required int depth}) : super(depth);
}

/// The keyframes a fold row shows as diamonds on its lane (docs/07 §4.3), or
/// empty for rows with nothing keyed. A multi-axis transform row reads its
/// lead axis: the axes key together, so one axis's times are the row's.
List<BridgeKeyframe> laneKeysOf(LayerFoldRow row) => switch (row) {
      FoldTransformRow(:final group, :final transform) => switch (
            read(transform, group.axes.first.prop)) {
          BridgeScalar_Keyframed(:final field0) => field0,
          BridgeScalar_Static() => const [],
        },
      FoldEffectParamRow(:final value) => switch (value) {
          BridgeEffectValue_Float(
            field0: BridgeScalar_Keyframed(:final field0)
          ) =>
            field0,
          _ => const [],
        },
      _ => const [],
    };

/// A key's position on the comp's frame axis, computed Dart-side from its
/// exact time and the comp's rate so a paint never crosses the bridge for it.
///
/// Fractional on purpose: with the magnet off a key may sit *between* frames
/// (docs/07 §4.5), and it has to draw where it actually is.
double laneKeyFrame(BridgeKeyframe key, double fps) =>
    key.time.num / key.time.den.toDouble() * fps;

/// The exact time of a (possibly fractional) frame position — what a lane key
/// drag commits.
///
/// Quantised to a thousandth of a frame and built from the comp's exact rate,
/// so the time stays rational (docs/14 §2): at 29.97 a whole frame is exactly
/// 1001/30000 s and half of one is exactly 1001/60000, never a rounded double.
BridgeRational timeOfSubframe(double frame, int fpsNum, int fpsDen) {
  final milliframes = (frame * 1000).round();
  return BridgeRational(
    num: milliframes * fpsDen,
    den: 1000 * (fpsNum == 0 ? 1 : fpsNum),
  );
}

/// Move a lane row's keyframe [index] to [time], as ONE op — one undo step
/// for the whole drag.
///
/// A transform row moves the key on *every* axis it covers: the axes key
/// together, so the row's one diamond stands for all of their keys. Refused
/// (returning false, changing nothing) when the move would land on or past a
/// neighbour — two keys cannot share a time, and the engine refuses a curve
/// whose times do not strictly ascend.
bool moveLaneKey({
  required BridgeLayerEntry entry,
  required LayerFoldRow row,
  required int index,
  required BridgeRational time,
}) {
  double at(BridgeRational r) => r.num / r.den.toDouble();
  final target = at(time);

  List<BridgeKeyframe>? moved(List<BridgeKeyframe> keys) {
    if (index >= keys.length) return null;
    for (var i = 0; i < keys.length; i++) {
      if (i == index) continue;
      final other = at(keys[i].time);
      if (i < index ? other >= target : other <= target) return null;
    }
    return [
      for (var i = 0; i < keys.length; i++)
        if (i == index)
          BridgeKeyframe(
            time: time,
            value: keys[i].value,
            interpIn: keys[i].interpIn,
            interpOut: keys[i].interpOut,
          )
        else
          keys[i],
    ];
  }

  switch (row) {
    case FoldTransformRow(:final group, :final transform):
      final props = <BridgeTransformProp>[];
      final values = <BridgeScalar>[];
      for (final axis in group.axes) {
        final scalar = read(transform, axis.prop);
        if (scalar is! BridgeScalar_Keyframed) return false;
        final next = moved(scalar.field0);
        // Every axis or none: a half-applied move would leave the row's axes
        // keyed at different times, which is not a row any more.
        if (next == null) return false;
        props.add(axis.prop);
        values.add(BridgeScalar.keyframed(next));
      }
      if (props.isEmpty) return false;
      entry.layer.setTransforms(props: props, values: values);
      return true;

    case FoldEffectParamRow(:final info, :final param):
      final stack = entry.layer.getEffects();
      for (final instance in stack) {
        if (instance.id() != info.id) continue;
        final value = instance.getValue(id: param.id);
        if (value is! BridgeEffectValue_Float) return false;
        final scalar = value.field0;
        if (scalar is! BridgeScalar_Keyframed) return false;
        final next = moved(scalar.field0);
        if (next == null) return false;
        instance.setValue(
          id: param.id,
          value: BridgeEffectValue.float(BridgeScalar.keyframed(next)),
        );
        entry.layer.setEffects(effects: stack);
        return true;
      }
      return false;

    case _:
      return false;
  }
}

/// A fold row's stable path — its id for selection, for the lane's keyframes,
/// and for working out what contains it.
///
/// Hierarchical on purpose, sharing its prefixes with [FoldGroupRow.path]:
/// selecting `<layer>/effects/<effect>/<param>` is what tells the outline to
/// highlight that effect's heading and that layer's row (docs/07 §4.3), and
/// `startsWith` is the whole of the "is this my ancestor" test.
String foldRowPath(String layerId, LayerFoldRow row) => switch (row) {
      FoldGroupRow(:final path) => path,
      FoldTransformRow(:final group) =>
        '${transformPath(layerId)}/${group.axes.first.prop.name}',
      FoldEffectParamRow(:final info, :final param) =>
        '${effectPath(layerId, info.id.toString())}/${param.id}',
      FoldVolumeRow() => '${audioPath(layerId)}/volume',
      FoldWaveformRow() => waveformPath(layerId),
    };

/// Whether [path] sits under [ancestor] — a property under its group, a
/// parameter under its effect, anything under its layer.
bool isUnderPath(String ancestor, String path) =>
    ancestor.isNotEmpty && path.startsWith('$ancestor/');

/// The path of a layer's Transform group in the open set.
String transformPath(String layerId) => '$layerId/transform';

/// The path of a layer's Effects group.
String effectsPath(String layerId) => '$layerId/effects';

/// The path of one effect within the Effects group.
String effectPath(String layerId, String effectId) =>
    '$layerId/effects/$effectId';

/// The path of a layer's Audio group.
String audioPath(String layerId) => '$layerId/audio';

/// The path of the Waveform twirl inside the Audio group.
String waveformPath(String layerId) => '$layerId/audio/waveform';

/// The rows to draw under an open layer, in order.
///
/// `hasAudio` is passed in rather than asked for here because answering it means
/// probing the file with FFmpeg, which is not work for a build — the Timeline
/// caches it per layer, exactly as the Project panel caches missing media.
List<LayerFoldRow> layerFoldRows({
  required BridgeLayerEntry entry,
  required Set<String> open,
  required bool hasAudio,
}) {
  final id = entry.layer.internallayerId.toString();
  final info = entry.info;
  final rows = <LayerFoldRow>[];

  final transformOpen = open.contains(transformPath(id));
  rows.add(FoldGroupRow(
    path: transformPath(id),
    label: 'Transform',
    open: transformOpen,
    depth: 1,
  ));
  if (transformOpen) {
    for (final group in transformGroups(threeD: info.switches.threeD)) {
      rows.add(FoldTransformRow(group, info.transform, depth: 2));
    }
  }

  // Effects appear only once there are some: an empty heading is a promise the
  // row cannot keep.
  if (info.effects.isNotEmpty) {
    final effectsOpen = open.contains(effectsPath(id));
    rows.add(FoldGroupRow(
      path: effectsPath(id),
      label: 'Effects',
      open: effectsOpen,
      depth: 1,
    ));
    if (effectsOpen) {
      for (final fx in info.effects) {
        final path = effectPath(id, fx.id.toString());
        final effectOpen = open.contains(path);
        rows.add(FoldGroupRow(
          path: path,
          label: effectLabelOf(fx.name),
          open: effectOpen,
          depth: 2,
        ));
        if (effectOpen) {
          final values = {for (final v in fx.values) v.id: v.value};
          for (final param in cachedListParameters(fx.name)) {
            rows.add(FoldEffectParamRow(fx, param, values[param.id], depth: 3));
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
    if (audioOpen) {
      rows.add(const FoldVolumeRow(depth: 2));
      // The waveform behind its own twirl (K-172), so a busy comp only pays
      // for the lanes actually being looked at.
      final waveOpen = open.contains(waveformPath(id));
      rows.add(FoldGroupRow(
        path: waveformPath(id),
        label: 'Waveform',
        open: waveOpen,
        depth: 2,
      ));
      if (waveOpen) rows.add(const FoldWaveformRow(depth: 3));
    }
  }

  return rows;
}
