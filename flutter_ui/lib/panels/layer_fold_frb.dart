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
// (docs/07 §4.3), and Retime above them all when the layer has one. Masks are
// not built yet. A group is a heading with
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

/// The layer's Retime (K-197): source time in seconds, keyframable like any
/// other property. It sits above Transform rather than inside it, and only
/// appears on a layer that has been given one (Ctrl+Alt+T) — which is why the
/// scalar rides on the row: `null` retime means no row at all, so a row that
/// exists always has a curve to draw.
final class FoldRetimeRow extends LayerFoldRow {
  final BridgeScalar scalar;
  const FoldRetimeRow(this.scalar, {required int depth}) : super(depth);
}

/// One mask on the layer (K-222): its name, and the switches that decide how it
/// gates the picture.
final class FoldMaskRow extends LayerFoldRow {
  final BridgeMask mask;
  const FoldMaskRow(this.mask, {required int depth}) : super(depth);
}

/// One piece of a shape layer's art (K-237): its name, its fill and its
/// outline — the row that makes a drawn shape editable after the fact.
final class FoldShapeRow extends LayerFoldRow {
  final BridgeShapeItem item;
  const FoldShapeRow(this.item, {required int depth}) : super(depth);
}

/// One paint stroke on the layer (K-227): its name, so a stroke can be found,
/// renamed and deleted after it was painted.
final class FoldStrokeRow extends LayerFoldRow {
  final BridgeStroke stroke;
  const FoldStrokeRow(this.stroke, {required int depth}) : super(depth);
}

/// One control of a footage layer's Flow group (K-088, K-268). Which control
/// is the [kind]; all of them read and write the whole group in one op, so a
/// row needs nothing but its own identity.
///
/// The Input rate is the one animatable member, so it is the one that carries a
/// scalar and draws diamonds on its lane.
final class FoldFlowRow extends LayerFoldRow {
  final FlowRowKind kind;

  /// The Input rate's curve; null on every other kind.
  final BridgeScalar? rate;
  const FoldFlowRow(this.kind, {this.rate, required int depth}) : super(depth);
}

/// The controls of the Flow group, in the order they are shown.
///
/// Resolution first because it is the one that costs money, then the rate (what
/// frames flow works between), then how hard it looks, then what it does where
/// it cannot see.
enum FlowRowKind {
  resolution('Flow resolution'),
  inputRate('Input rate'),
  detail('Vector detail'),
  smoothness('Smoothness'),
  occlusion('Occlusion'),
  fallback('Fallback'),
  hudGuard('HUD guard'),
  always('Always on');

  final String label;
  const FlowRowKind(this.label);
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
      FoldRetimeRow(:final scalar) => switch (scalar) {
          BridgeScalar_Keyframed(:final field0) => field0,
          BridgeScalar_Static() => const [],
        },
      FoldFlowRow(:final rate) => switch (rate) {
          BridgeScalar_Keyframed(:final field0) => field0,
          _ => const [],
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

    case FoldRetimeRow(:final scalar):
      if (scalar is! BridgeScalar_Keyframed) return false;
      final next = moved(scalar.field0);
      if (next == null) return false;
      entry.layer.setRetimeProperty(value: BridgeScalar.keyframed(next));
      return true;

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
      FoldTransformRow(:final group) => transformGroupPath(layerId, group),
      FoldEffectParamRow(:final info, :final param) =>
        '${effectPath(layerId, info.id.toString())}/${param.id}',
      FoldVolumeRow() => '${audioPath(layerId)}/volume',
      FoldRetimeRow() => retimePath(layerId),
      FoldFlowRow(:final kind) => '${flowPath(layerId)}/${kind.name}',
      FoldWaveformRow() => waveformPath(layerId),
      FoldMaskRow(:final mask) => '${masksPath(layerId)}/${mask.id}',
      FoldStrokeRow(:final stroke) => '${paintPath(layerId)}/${stroke.id}',
      FoldShapeRow(:final item) => '${contentsPath(layerId)}/${item.id}',
    };

/// Whether [path] sits under [ancestor] — a property under its group, a
/// parameter under its effect, anything under its layer.
bool isUnderPath(String ancestor, String path) =>
    ancestor.isNotEmpty && path.startsWith('$ancestor/');

/// The path of a layer's Retime row.
String retimePath(String layerId) => '$layerId/retime';

/// The path of a layer's Flow group in the open set.
String flowPath(String layerId) => '$layerId/flow';

/// The path of a layer's Transform group in the open set.
String transformPath(String layerId) => '$layerId/transform';

/// The path of one Transform row — Position, Scale, Rotation and the rest.
///
/// Named after the group's first axis rather than its label, because the label
/// is what the row *says* and the axis is what it *is*: renaming "Anchor point"
/// would otherwise quietly unbind the `A` key from the row it reveals.
String transformGroupPath(String layerId, TransformGroup group) =>
    '${transformPath(layerId)}/${group.axes.first.prop.name}';

/// The path of a layer's Effects group.
String effectsPath(String layerId) => '$layerId/effects';

/// The path of one effect within the Effects group.
String effectPath(String layerId, String effectId) =>
    '$layerId/effects/$effectId';

/// The path of a layer's Masks group.
String masksPath(String layerId) => '$layerId/masks';

/// The path of a shape layer's Contents group.
String contentsPath(String layerId) => '$layerId/contents';

/// The path of a layer's Paint group.
String paintPath(String layerId) => '$layerId/paint';

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

  // A reveal key (`P`, `S`, `R`, `T`, `A`) leaves exactly one Transform row
  // open and the group itself shut — "show me Position" means Position, not
  // Position among five others. That is a *solo*, and it is read here rather
  // than passed in because the lanes build their rows from this same list and
  // must leave room for the same ones (docs/07 §4.3).
  final transformOpen = open.contains(transformPath(id));
  final groups = transformGroups(threeD: info.switches.threeD);
  final soloed = !transformOpen &&
      groups.any((g) => open.contains(transformGroupPath(id, g)));

  // Retime first, above everything (docs/07 §4.3): it decides *which* frame of
  // the source the rest of the fold-out then transforms. A layer that has not
  // been given one shows no row rather than a dead control — and it stands
  // down while a solo is in force, for the same reason the other four rows do.
  if (info.retime case final retime? when !soloed) {
    rows.add(FoldRetimeRow(retime, depth: 1));
  }

  // Flow above Transform and below Retime, which is the order the picture is
  // built in: the retime picks a moment, flow decides what is *shown* at a
  // moment between two frames, and the transform then places the result. Only
  // on a layer whose flow switch is on — an empty heading is a promise the row
  // cannot keep (K-088).
  if (info.flow && !soloed) {
    final flowOpen = open.contains(flowPath(id));
    rows.add(FoldGroupRow(
      path: flowPath(id),
      label: 'Flow',
      open: flowOpen,
      depth: 1,
    ));
    if (flowOpen) {
      for (final kind in FlowRowKind.values) {
        rows.add(FoldFlowRow(
          kind,
          rate: kind == FlowRowKind.inputRate ? info.flowInputRate : null,
          depth: 2,
        ));
      }
    }
  }

  rows.add(FoldGroupRow(
    path: transformPath(id),
    label: 'Transform',
    open: transformOpen,
    depth: 1,
  ));
  for (final group in groups) {
    if (transformOpen || open.contains(transformGroupPath(id, group))) {
      rows.add(FoldTransformRow(group, info.transform, depth: 2));
    }
  }

  // Contents first of the three: a shape layer's art *is* its picture, so it
  // comes before the masks that gate that picture and the effects that process
  // it (K-237, docs/06 render order).
  if (info.shapeContents.isNotEmpty) {
    final contentsOpen = open.contains(contentsPath(id));
    rows.add(FoldGroupRow(
      path: contentsPath(id),
      label: 'Contents',
      open: contentsOpen,
      depth: 1,
    ));
    if (contentsOpen) {
      for (final item in info.shapeContents) {
        rows.add(FoldShapeRow(item, depth: 2));
      }
    }
  }

  // Masks, above Effects because that is the order they are applied in: a mask
  // gates the layer's alpha *before* its effects run (docs/06 render order), so
  // the fold-out reads top to bottom the way the picture is built. Like
  // Effects, the heading appears only once there is something under it — an
  // empty heading is a promise the row cannot keep.
  if (info.masks.isNotEmpty) {
    final masksOpen = open.contains(masksPath(id));
    rows.add(FoldGroupRow(
      path: masksPath(id),
      label: 'Masks',
      open: masksOpen,
      depth: 1,
    ));
    if (masksOpen) {
      for (final mask in info.masks) {
        rows.add(FoldMaskRow(mask, depth: 2));
      }
    }
  }

  // Paint, between Masks and Effects, because that is where it happens: strokes
  // are stamped into the layer's own pixels, which the masks then gate and the
  // effects then process (K-227, docs/06 render order).
  if (info.paint.isNotEmpty) {
    final paintOpen = open.contains(paintPath(id));
    rows.add(FoldGroupRow(
      path: paintPath(id),
      label: 'Paint',
      open: paintOpen,
      depth: 1,
    ));
    if (paintOpen) {
      for (final stroke in info.paint) {
        rows.add(FoldStrokeRow(stroke, depth: 2));
      }
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
