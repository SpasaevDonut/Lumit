// The graph editor: the selected properties' animation as curves you shape,
// After Effects style (docs/07 §5).
//
// One full-height pane over the Timeline's own time axis — same ruler, same
// zoom, same horizontal scroll — with every selected property drawn as its own
// coloured curve (a two-axis property like Position contributes one curve per
// axis). Keyframes draw with interpolation-coded glyphs; selected keys show
// their bezier tangent handles, draggable per side, with `Alt` breaking and
// re-joining the two sides. The **value** lens plots value against time; the
// **speed** lens plots dv/dt, where each key is an in point and an out point
// that move independently, each with a single influence handle — the AE speed
// graph.
//
// **Zero bridge calls to draw** (K-184): the curves are evaluated by the Dart
// port of the engine's own cubic (graph_maths.dart, pinned together by
// docs/impl/keyframe-eval.md), and every scalar rides in on the comp read
// model. The bridge is only crossed when a gesture commits — one write per
// channel, batched per layer, so a drag stays one undo step per property.

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:lumit_flutter/src/rust/api/effect.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';
import 'package:lumit_flutter/src/rust/api/shell.dart';
import 'package:lumit_flutter/state/comp_model.dart';
import 'package:provider/provider.dart';

import '../theme/theme.dart';
import '../widgets/controls.dart';
import '../widgets/marquee.dart';
import 'effect_param_row_frb.dart';
import 'graph_maths.dart';
import 'layer_fold_frb.dart';
import 'timeline_extras_frb.dart';
import 'transform_rows_frb.dart';

/// Which reading of the curve is on screen (docs/07 §5.1).
enum GraphLens { value, speed }

/// How wide a keyframe's grab target is, and a tangent handle's. Both are
/// bigger than the glyph they carry: these are small marks that must be
/// caught first time, and a miss on a handle is worse than a miss on empty
/// pane — it drops the key's selection and takes the handles away with it.
const double _keyGrab = 16;
const double _handleGrab = 18;

/// One animatable channel on the graph: a single scalar curve, where it came
/// from, and how to write it back.
class GraphChannel {
  /// The fold-row path of the property row this channel belongs to — the
  /// outline's selection speaks in these.
  final String path;

  /// Unique per curve: a two-axis property has one channel per axis.
  final String id;
  final String label;

  /// Its stroke: an index into the theme's `curve` palette, assigned in
  /// selection order so the outline can tint the row's text to match.
  final int colourIndex;
  final BridgeScalar scalar;
  final BridgeLayerEntry entry;

  /// Set for a transform channel; null for an effect parameter.
  final BridgeTransformProp? prop;

  /// Set for an effect parameter channel.
  final BridgeEffectInstanceInfo? effect;
  final BridgeParamInfo? param;

  /// True for the layer's Retime channel (K-197), which is neither a transform
  /// property nor an effect parameter but reads and writes like both.
  final bool retime;

  const GraphChannel({
    required this.path,
    required this.id,
    required this.label,
    required this.colourIndex,
    required this.scalar,
    required this.entry,
    this.prop,
    this.effect,
    this.param,
    this.retime = false,
  });

  List<BridgeKeyframe> get keys => keysOf(scalar);
  bool get isStatic => scalar is BridgeScalar_Static;
  double get staticValue => switch (scalar) {
        BridgeScalar_Static(:final field0) => field0,
        BridgeScalar_Keyframed() => 0,
        BridgeScalar_Expression() => 0,
      };
}

/// The channels the selected property paths resolve to, in selection order —
/// entirely from the read model, so building them costs no bridge calls.
///
/// A transform row yields one channel per axis (Position → x and y, the AE
/// red/green pair); a float effect parameter yields one. Volume is not in the
/// read model (K-184's deliberate exceptions) and is skipped — docs/TODO.md.
List<GraphChannel> graphChannels({
  required List<BridgeLayerEntry> layers,
  required List<String> selected,
}) {
  final out = <GraphChannel>[];
  for (final path in selected) {
    final cut = path.indexOf('/');
    if (cut <= 0) continue;
    final layerId = path.substring(0, cut);
    BridgeLayerEntry? entry;
    for (final e in layers) {
      if (e.layer.internallayerId.toString() == layerId) {
        entry = e;
        break;
      }
    }
    if (entry == null) continue;

    // Retime (K-197): one channel, source time in seconds. An ordinary curve
    // here — the lens, the handles and the interp buttons all treat it as one.
    if (path == retimePath(layerId)) {
      if (entry.info.retime case final scalar?) {
        out.add(GraphChannel(
          path: path,
          id: path,
          label: '${entry.info.name} · Retime',
          colourIndex: out.length,
          scalar: scalar,
          entry: entry,
          retime: true,
        ));
      }
      continue;
    }

    if (path.startsWith('${transformPath(layerId)}/')) {
      final lead = path.substring(path.lastIndexOf('/') + 1);
      for (final group in transformGroups(threeD: entry.info.switches.threeD)) {
        if (group.axes.first.prop.name != lead) continue;
        for (final axis in group.axes) {
          out.add(GraphChannel(
            path: path,
            id: '$path@${axis.prop.name}',
            label: group.axes.length == 1
                ? '${entry.info.name} · ${group.label}'
                : '${entry.info.name} · ${group.label} ${_axisLetter(group.axes.indexOf(axis))}',
            colourIndex: out.length,
            scalar: read(entry.info.transform, axis.prop),
            entry: entry,
            prop: axis.prop,
          ));
        }
        break;
      }
      continue;
    }

    if (path.startsWith('${effectsPath(layerId)}/')) {
      final rest = path.substring(effectsPath(layerId).length + 1);
      final slash = rest.indexOf('/');
      if (slash <= 0) continue;
      final effectId = rest.substring(0, slash);
      final paramId = rest.substring(slash + 1);
      for (final fx in entry.info.effects) {
        if (fx.id.toString() != effectId) continue;
        for (final param in cachedListParameters(fx.name)) {
          if (param.id != paramId) continue;
          if (param.kind is! BridgeParamKind_Float) continue;
          BridgeScalar? scalar;
          for (final v in fx.values) {
            if (v.id == param.id && v.value is BridgeEffectValue_Float) {
              scalar = (v.value as BridgeEffectValue_Float).field0;
            }
          }
          if (scalar == null) continue;
          out.add(GraphChannel(
            path: path,
            id: path,
            label:
                '${entry.info.name} · ${effectLabelOf(fx.name)} · ${param.label}',
            colourIndex: out.length,
            scalar: scalar,
            entry: entry,
            effect: fx,
            param: param,
          ));
        }
      }
    }
  }
  return out;
}

String _axisLetter(int i) => switch (i) { 0 => 'x', 1 => 'y', _ => 'z' };

/// Commit new scalars for a set of channels in the fewest ops: one
/// `setTransforms` batch per layer for its transform channels (one undo step),
/// one staged `setEffects` per layer for its effect channels.
void commitChannelEdits(Map<GraphChannel, BridgeScalar> edits) {
  // Transform channels, grouped by layer.
  final transforms = <String,
      (LayerReference, List<BridgeTransformProp>, List<BridgeScalar>)>{};
  final effects =
      <String, (LayerReference, Map<String, Map<String, BridgeScalar>>)>{};
  edits.forEach((channel, next) {
    final layerId = channel.entry.layer.internallayerId.toString();
    if (channel.prop != null) {
      final slot = transforms[layerId] ??= (channel.entry.layer, [], []);
      slot.$2.add(channel.prop!);
      slot.$3.add(next);
    } else if (channel.retime) {
      // One Retime per layer, so there is nothing to batch: the write is
      // already one op and therefore one undo step.
      channel.entry.layer.setRetimeProperty(value: next);
    } else if (channel.effect != null && channel.param != null) {
      final slot = effects[layerId] ??= (channel.entry.layer, {});
      (slot.$2[channel.effect!.id.toString()] ??= {})[channel.param!.id] = next;
    }
  });
  for (final (layer, props, values) in transforms.values) {
    layer.setTransforms(props: props, values: values);
  }
  for (final (layer, byEffect) in effects.values) {
    final staged = layer.getEffects();
    for (final instance in staged) {
      final wanted = byEffect[instance.id().toString()];
      if (wanted == null) continue;
      wanted.forEach((paramId, scalar) {
        instance.setValue(id: paramId, value: BridgeEffectValue.float(scalar));
      });
    }
    layer.setEffects(effects: staged);
  }
}

/// A key's position on the frame axis, fractional (a key may sit between
/// frames with the magnet off).
double _keyFrame(BridgeKeyframe key, double fps) =>
    key.time.num / key.time.den.toDouble() * fps;

/// Set one or both sides of every selected key to [side] — the F9 family and
/// the bottom bar's Linear / Bezier / Hold buttons. `inSide`/`outSide` pick
/// which sides change (ease-in touches only the in side, and so on).
void applyInterpToSelection({
  required List<GraphChannel> channels,
  required Set<String> selectedKeys,
  required BridgeSideInterp side,
  bool inSide = true,
  bool outSide = true,
}) {
  final edits = <GraphChannel, BridgeScalar>{};
  for (final channel in channels) {
    final keys = channel.keys;
    var touched = false;
    final next = <BridgeKeyframe>[];
    for (var i = 0; i < keys.length; i++) {
      if (selectedKeys.contains('${channel.id}#$i')) {
        touched = true;
        next.add(BridgeKeyframe(
          time: keys[i].time,
          value: keys[i].value,
          interpIn: inSide ? side : keys[i].interpIn,
          interpOut: outSide ? side : keys[i].interpOut,
        ));
      } else {
        next.add(keys[i]);
      }
    }
    if (touched) edits[channel] = BridgeScalar.keyframed(next);
  }
  if (edits.isNotEmpty) commitChannelEdits(edits);
}

// ---------------------------------------------------------------------------
// The keyframe clipboard (docs/07 §5.3, K-196).
// ---------------------------------------------------------------------------

/// One copied channel: where it came from (for the AE text's property line)
/// and its keys with full easing fidelity.
class GraphClipChannel {
  final GraphChannel source;
  final List<BridgeKeyframe> keys;
  const GraphClipChannel(this.source, this.keys);
}

/// The in-app keyframe clipboard: full fidelity, and the one a paste prefers.
/// Module-level so it survives panel rebuilds and pastes across layers.
List<GraphClipChannel> graphKeyClipboard = const [];

/// The running build's version, for the clipboard header — taken from the
/// engine's own boot log (`lumit-bridge 0.1.0`), so there is one source of
/// truth for it. Asked once per session; a copy is a gesture, not a paint.
String? _version;
String lumitVersion() {
  final held = _version;
  if (held != null) return held;
  try {
    final first = bootLog().firstOrNull ?? '';
    final parts = first.trim().split(RegExp(r'\s+'));
    return _version = parts.length > 1 ? parts.last : 'unknown';
  } catch (_) {
    return _version = 'unknown';
  }
}

/// Copy the selected keys. The in-app clipboard keeps everything; the system
/// clipboard gets the tab-separated keyframe table (docs/07 §5.3) — values
/// *and* easing — so a copied ramp can be scripted, inspected, or carried into
/// another tool.
void copySelectedKeys({
  required CompositionReference comp,
  required List<GraphChannel> channels,
  required Set<String> selectedKeys,
  required double fps,
}) {
  final copied = <GraphClipChannel>[];
  for (final channel in channels) {
    final keys = channel.keys;
    final hit = [
      for (var i = 0; i < keys.length; i++)
        if (selectedKeys.contains('${channel.id}#$i')) keys[i],
    ];
    if (hit.isNotEmpty) copied.add(GraphClipChannel(channel, hit));
  }
  if (copied.isEmpty) return;
  graphKeyClipboard = copied;

  // The text mirror. The axes of one property fold into a single group with an
  // X/Y[/Z] column each, over the union of their key frames.
  final settings = comp.getSettings();
  final groups = <LumitClipGroup>[];
  final done = <GraphClipChannel>{};
  for (final clip in copied) {
    if (done.contains(clip)) continue;
    final prop = clip.source.prop;
    if (prop != null) {
      final siblings = [
        for (final other in copied)
          if (other.source.path == clip.source.path) other,
      ];
      done.addAll(siblings);
      groups.add(_transformClipGroup(clip.source, siblings, fps));
    } else {
      done.add(clip);
      groups.add(LumitClipGroup(
        property: [
          'Effects',
          effectLabelOf(clip.source.effect?.name ?? ''),
          clip.source.param?.label ?? '',
        ],
        columns: const ['Value'],
        rows: [
          for (final k in clip.keys)
            LumitClipRow(
              frame: _keyFrame(k, fps),
              values: [k.value],
              eases: [(k.interpIn, k.interpOut)],
            ),
        ],
      ));
    }
  }
  Clipboard.setData(ClipboardData(
    text: lumitClipboardText(
      version: lumitVersion(),
      fps: fps,
      width: settings.width.toInt(),
      height: settings.height.toInt(),
      groups: groups,
    ),
  ));
}

/// The property line and columns for a transform property's copied axes.
LumitClipGroup _transformClipGroup(
    GraphChannel lead, List<GraphClipChannel> axes, double fps) {
  final (name, unit) = switch (lead.prop!) {
    BridgeTransformProp.anchorX || BridgeTransformProp.anchorY => (
        'Anchor Point',
        'pixels'
      ),
    BridgeTransformProp.positionX ||
    BridgeTransformProp.positionY ||
    BridgeTransformProp.positionZ =>
      ('Position', 'pixels'),
    BridgeTransformProp.scaleX || BridgeTransformProp.scaleY => (
        'Scale',
        'percent'
      ),
    BridgeTransformProp.rotation => ('Rotation', 'degrees'),
    BridgeTransformProp.rotationX => ('X Rotation', 'degrees'),
    BridgeTransformProp.rotationY => ('Y Rotation', 'degrees'),
    BridgeTransformProp.opacity => ('Opacity', 'percent'),
  };
  // The union of the axes' key frames: an axis with no key on some frame
  // contributes the value its curve reads there, so every row is complete.
  final frames = <double>{};
  for (final axis in axes) {
    for (final k in axis.keys) {
      frames.add(_keyFrame(k, fps));
    }
  }
  final sorted = frames.toList()..sort();
  final columns = axes.length == 1
      ? [unit]
      : [
          for (var i = 0; i < axes.length; i++)
            '${_axisLetter(i).toUpperCase()} $unit'
        ];

  /// The key an axis has exactly on `frame`, if any — the one whose easing
  /// the row carries. A filled-in value has no key, and so no easing.
  BridgeKeyframe? keyAt(GraphClipChannel axis, double frame) {
    for (final k in axis.keys) {
      if ((_keyFrame(k, fps) - frame).abs() < 1e-9) return k;
    }
    return null;
  }

  return LumitClipGroup(
    property: ['Transform', name],
    columns: columns,
    rows: [
      for (final f in sorted)
        LumitClipRow(
          frame: f,
          values: [
            for (final axis in axes)
              keyAt(axis, f)?.value ??
                  evaluateKeys(axis.keys, f / (fps <= 0 ? 1 : fps)),
          ],
          eases: [
            for (final axis in axes)
              switch (keyAt(axis, f)) {
                final BridgeKeyframe k => (k.interpIn, k.interpOut),
                _ => (
                    const BridgeSideInterp.linear(),
                    const BridgeSideInterp.linear()
                  ),
              },
          ],
        ),
    ],
  );
}

/// Paste the clipboard into the currently selected channels, the earliest key
/// landing on the playhead. The in-app clipboard pastes first; failing that,
/// keyframe text on the system clipboard is parsed — with its easing when it
/// carries any. Channels are matched in order.
Future<bool> pasteKeysAtPlayhead({
  required List<GraphChannel> channels,
  required int playheadFrame,
  required double fps,
  required int fpsNum,
  required int fpsDen,
}) async {
  if (channels.isEmpty) return false;

  // (channel keys to merge in) per target channel, times as comp frames.
  var sources = <List<(double, BridgeKeyframe)>>[];
  if (graphKeyClipboard.isNotEmpty) {
    sources = [
      for (final clip in graphKeyClipboard)
        [for (final k in clip.keys) (_keyFrame(k, fps), k)],
    ];
  } else {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    final parsed = text == null ? null : parseClipboardText(text);
    if (parsed == null) return false;
    // The table's frames are in whatever rate it was written at; carry them
    // across as real time rather than as frame numbers.
    for (final group in parsed.groups) {
      final columns = group.rows.isEmpty ? 0 : group.rows.first.values.length;
      for (var c = 0; c < columns; c++) {
        sources.add([
          for (final row in group.rows)
            if (c < row.values.length)
              (
                row.frame / parsed.fps * fps,
                BridgeKeyframe(
                  // Placeholder time; rewritten with the shift below.
                  time: const BridgeRational(num: 0, den: 1),
                  value: row.values[c],
                  interpIn: c < row.eases.length
                      ? row.eases[c].$1
                      : const BridgeSideInterp.linear(),
                  interpOut: c < row.eases.length
                      ? row.eases[c].$2
                      : const BridgeSideInterp.linear(),
                ),
              ),
        ]);
      }
    }
  }
  if (sources.isEmpty) return false;

  var earliest = double.infinity;
  for (final source in sources) {
    for (final (frame, _) in source) {
      if (frame < earliest) earliest = frame;
    }
  }
  if (!earliest.isFinite) return false;
  final shift = playheadFrame - earliest;

  final edits = <GraphChannel, BridgeScalar>{};
  for (var i = 0; i < channels.length && i < sources.length; i++) {
    final channel = channels[i];
    // Merge on frames: a pasted key replaces one already at its frame — two
    // keys at one time is not a curve the engine will take.
    final merged = <double, BridgeKeyframe>{
      for (final k in channel.keys) _keyFrame(k, fps): k,
    };
    for (final (frame, key) in sources[i]) {
      final at = frame + shift;
      merged[at] = BridgeKeyframe(
        time: timeOfSubframe(at, fpsNum, fpsDen),
        value: key.value,
        interpIn: key.interpIn,
        interpOut: key.interpOut,
      );
    }
    final frames = merged.keys.toList()..sort();
    edits[channel] =
        BridgeScalar.keyframed([for (final f in frames) merged[f]!]);
  }
  if (edits.isEmpty) return false;
  commitChannelEdits(edits);
  return true;
}

// ---------------------------------------------------------------------------
// The pane.
// ---------------------------------------------------------------------------

class GraphEditorFrb extends StatefulWidget {
  final CompositionReference comp;
  final List<GraphChannel> channels;
  final TimelineAxis axis;

  /// The Timeline's horizontal scroll controller, so the value axis can be
  /// pinned to the viewport rather than to the start of time. Optional: a test
  /// that builds the pane alone has no scroll view around it.
  final ScrollController? hScroll;
  final int frames;
  final double fps;
  final int fpsNum;
  final int fpsDen;
  final bool magnet;
  final GraphLens lens;

  /// Auto-fit: the vertical range follows the curves (docs/07 §5.3). Off, the
  /// range is the user's — the wheel pans it and `Alt`+wheel zooms it.
  final bool autoFit;

  /// The selected keys, as `channelId#index` — owned by the Timeline panel so
  /// the bottom bar and the shortcuts act on the same set.
  final Set<String> selectedKeys;
  final VoidCallback onSelectionChanged;
  final VoidCallback onChanged;

  /// `Ctrl`/`Shift` wheels go to the panel: time zoom about the pointer and
  /// horizontal scroll are the Timeline's own, shared with the lane view.
  final void Function(PointerScrollEvent event, double contentX) onWheelTime;

  const GraphEditorFrb({
    super.key,
    required this.comp,
    required this.channels,
    required this.axis,
    this.hScroll,
    required this.frames,
    required this.fps,
    required this.fpsNum,
    required this.fpsDen,
    required this.magnet,
    required this.lens,
    required this.autoFit,
    required this.selectedKeys,
    required this.onSelectionChanged,
    required this.onChanged,
    required this.onWheelTime,
  });

  @override
  State<GraphEditorFrb> createState() => GraphEditorFrbState();
}

/// A key drag in flight: which key was grabbed and how far the gesture has
/// moved, applied to every selected key for the preview and committed once.
class _KeyDrag {
  final String grabbedId;
  double dxPx = 0;
  double dyPx = 0;
  _KeyDrag(this.grabbedId);
}

/// A tangent-handle drag in flight (value lens), or a speed-dot/influence
/// drag (speed lens).
class _HandleDrag {
  final GraphChannel channel;
  final int index;
  final bool isOut;

  /// Whether the other side follows: joined by default, `Alt` at drag start
  /// flips it — held apart if they were together, re-joined if they were
  /// apart. False at once when the other side has no span to reach into.
  final bool mirrored;
  double speed;
  double influence;

  /// The partner side's provisional easing while the drag runs, so the curve
  /// and both handles move together rather than the other side jumping on
  /// release.
  double partnerSpeed;
  double partnerInfluence;

  /// How long the partner handle was **on screen**, in pixels, when the drag
  /// began. A joined partner keeps that pixel length however the dragged side
  /// swings: a handle's *value* length is meaningless to the eye — what the
  /// user sees is its length in the panel, and it must not appear to grow
  /// when the pair rotates toward vertical.
  final double partnerLenPx;

  /// Speed lens only: this is a keyframe dot rather than an influence handle
  /// — it drags the key's time sideways and that side's speed vertically.
  final bool dotOnly;

  /// The vertical range and pane height the gesture is running under — frozen
  /// with it, so the commit can record the handles' lengths against the same
  /// scale it drew them at.
  final (double, double) range;
  final double height;

  /// Pixels the dot has travelled sideways (speed lens dot drags only).
  double dxPx = 0;

  _HandleDrag({
    required this.channel,
    required this.index,
    required this.isOut,
    required this.mirrored,
    required this.speed,
    required this.influence,
    required this.partnerSpeed,
    required this.partnerInfluence,
    required this.partnerLenPx,
    required this.range,
    required this.height,
    this.dotOnly = false,
  });
}

class GraphEditorFrbState extends State<GraphEditorFrb> {
  _KeyDrag? _keyDrag;
  _HandleDrag? _handleDrag;

  /// The vertical range on screen while a gesture is in flight — held still
  /// so the curve being dragged does not re-frame itself under the pointer.
  (double, double)? _frozen;

  /// The user's own range per lens, once auto-fit is off.
  final Map<GraphLens, (double, double)> _manual = {};

  /// The last range a build computed — what manual mode starts from, and what
  /// the wheel handlers scale.
  (double, double) _lastRange = (0, 1);
  Size _paneSize = Size.zero;

  /// How long each tangent handle was last drawn, in pixels, by channel, key
  /// time and side.
  ///
  /// **Why this is remembered rather than measured.** A handle's length on
  /// screen comes from its reach in *time*, and a tangent swung near vertical
  /// has almost none — its length there is carried almost entirely by its
  /// speed instead. Measuring the length back out of a stored ease is exact in
  /// theory and lossy in practice at that extreme, so a partner mirrored while
  /// near-vertical could come back a different length than it went in. Keeping
  /// the number means a handle is the length you last left it, and swinging
  /// the pair out to vertical and back returns it unchanged.
  ///
  /// Keyed by the keyframe's *time*, not its index, so it belongs to the key
  /// rather than to a position in a list; a key moved in time simply falls
  /// back to its measured length, which is right there anyway. The scales it
  /// was measured under ride along, because a pixel length means nothing after
  /// the view has zoomed or re-framed — a remembered number read under a
  /// different scale is quietly discarded rather than shrinking the handle.
  final Map<String, ({double lenPx, double xScale, double yScale})>
      _handleLenPx = {};

  String _handleLenKey(GraphChannel channel, BridgeKeyframe key, bool isOut) =>
      '${channel.id}#${key.time.num}/${key.time.den}-${isOut ? 'out' : 'in'}';

  /// Pixels per second, and pixels per unit of value, as the pane stands.
  (double, double) _scales((double, double) range, double height) {
    final span =
        (range.$2 - range.$1).abs() < 1e-12 ? 1.0 : range.$2 - range.$1;
    return (
      widget.axis.perFrame * (widget.fps <= 0 ? 1 : widget.fps),
      height / span,
    );
  }

  /// The length a side is drawn at, from its stored ease.
  double _measuredLength(GraphChannel channel, int index, bool isOut,
      (double, double) range, double height) {
    final keys = channel.keys;
    final key = keys[index];
    final end = _sideEndpoint(keys, index, isOut);
    final keyPx = Offset(
        _xOfSeconds(rationalSeconds(key.time)), _yOf(key.value, range, height));
    return (Offset(_xOfSeconds(end.time), _yOf(end.value, range, height)) -
            keyPx)
        .distance;
  }

  /// A side's length on screen: the one remembered for it if it was taken
  /// under the scales in force now, else the one its stored ease draws it at.
  double _handleLength(GraphChannel channel, int index, bool isOut,
      (double, double) range, double height) {
    final held =
        _handleLenPx[_handleLenKey(channel, channel.keys[index], isOut)];
    final (xScale, yScale) = _scales(range, height);
    if (held != null &&
        (held.xScale - xScale).abs() < 1e-6 * (1 + xScale.abs()) &&
        (held.yScale - yScale).abs() < 1e-6 * (1 + yScale.abs())) {
      return held.lenPx;
    }
    return _measuredLength(channel, index, isOut, range, height);
  }

  void _rememberLength(GraphChannel channel, BridgeKeyframe key, bool isOut,
      double lenPx, (double, double) range, double height) {
    final (xScale, yScale) = _scales(range, height);
    _handleLenPx[_handleLenKey(channel, key, isOut)] =
        (lenPx: lenPx, xScale: xScale, yScale: yScale);
  }

  /// Re-frame the curves now (`F`, docs/07 §5.3): in manual mode the fitted
  /// range becomes the manual one; in auto mode the next build fits anyway.
  void fitNow() => setState(() => _manual.remove(widget.lens));

  /// Delete the selected keys — the Timeline's Delete shortcut.
  void deleteSelectedKeys() => _deleteSelection();

  List<List<BridgeKeyframe>> get _channelKeys =>
      [for (final c in widget.channels) c.keys];

  (double, double) _fitRange() => widget.lens == GraphLens.value
      ? fitValueRange(
          _channelKeys,
          [
            for (final c in widget.channels)
              if (c.isStatic) c.staticValue,
          ],
        )
      : fitSpeedRange(_channelKeys);

  /// The Timeline's horizontal scroll offset, or zero before the view has been
  /// laid out (and in tests, which build the pane on its own).
  double get _viewportLeft {
    final c = widget.hScroll;
    return c != null && c.hasClients ? c.offset : 0;
  }

  (double, double) _range() {
    final frozen = _frozen;
    if (frozen != null) return frozen;
    if (!widget.autoFit) {
      return _manual[widget.lens] ??= _fitRange();
    }
    return _fitRange();
  }

  double _yOf(double v, (double, double) range, double height) {
    final (lo, hi) = range;
    final span = (hi - lo).abs() < 1e-12 ? 1.0 : hi - lo;
    return height - (v - lo) / span * height;
  }

  double _valueAt(double y, (double, double) range, double height) {
    final (lo, hi) = range;
    final span = (hi - lo).abs() < 1e-12 ? 1.0 : hi - lo;
    return lo + (height - y) / (height <= 0 ? 1 : height) * span;
  }

  /// A key's y in the current lens: its value, or one side's speed.
  double _keyY(
      GraphChannel channel, int index, (double, double) range, double height,
      {required bool isOut}) {
    if (widget.lens == GraphLens.value) {
      return _yOf(channel.keys[index].value, range, height);
    }
    return _yOf(
        sideSpeedAtKey(channel.keys, index, isOut: isOut), range, height);
  }

  // --- wheel ---------------------------------------------------------------

  void _wheel(PointerScrollEvent event) {
    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isShiftPressed) {
      widget.onWheelTime(event, event.localPosition.dx);
      return;
    }
    // The vertical axis is the user's only once auto-fit is off.
    if (widget.autoFit || _paneSize.height <= 0) return;
    final range = _manual[widget.lens] ??= _lastRange;
    final (lo, hi) = range;
    final span = hi - lo;
    if (keys.isAltPressed) {
      // Zoom about the pointer: the value under the cursor stays put.
      final at = _valueAt(event.localPosition.dy, range, _paneSize.height);
      final factor = event.scrollDelta.dy < 0 ? 1 / 1.2 : 1.2;
      setState(() => _manual[widget.lens] =
          (at - (at - lo) * factor, at + (hi - at) * factor));
      return;
    }
    // Wheel down moves the *content* up, as scrolling does everywhere: the
    // window onto the values travels the other way to the wheel.
    final pan = -event.scrollDelta.dy / _paneSize.height * span;
    setState(() => _manual[widget.lens] = (lo + pan, hi + pan));
  }

  // --- selection -----------------------------------------------------------

  bool get _addToSelection =>
      HardwareKeyboard.instance.isShiftPressed ||
      HardwareKeyboard.instance.isControlPressed;

  void _selectKey(String id, {bool toggle = false}) {
    if (toggle && widget.selectedKeys.contains(id)) {
      widget.selectedKeys.remove(id);
    } else if (_addToSelection) {
      widget.selectedKeys.add(id);
    } else {
      widget.selectedKeys
        ..clear()
        ..add(id);
    }
    widget.onSelectionChanged();
  }

  void _applyMarquee(Rect rect, (double, double) range, double height) {
    if (!_addToSelection) widget.selectedKeys.clear();
    for (final channel in widget.channels) {
      final keys = channel.keys;
      for (var i = 0; i < keys.length; i++) {
        final x = widget.axis.xOf(_keyFrame(keys[i], widget.fps));
        final hit = widget.lens == GraphLens.value
            ? rect.contains(
                Offset(x, _keyY(channel, i, range, height, isOut: true)))
            : rect.contains(
                    Offset(x, _keyY(channel, i, range, height, isOut: true))) ||
                rect.contains(
                    Offset(x, _keyY(channel, i, range, height, isOut: false)));
        if (hit) widget.selectedKeys.add('${channel.id}#$i');
      }
    }
    widget.onSelectionChanged();
  }

  /// A plain click on empty pane clears the selection; `Ctrl`+click plants a
  /// key on the curve under the pointer (docs/07 §4.3's lane gesture, read
  /// through the graph).
  void _tapPane(Offset local, (double, double) range, double height) {
    if (HardwareKeyboard.instance.isControlPressed) {
      _addKeyAt(local, range, height);
      return;
    }
    if (widget.selectedKeys.isEmpty) return;
    widget.selectedKeys.clear();
    widget.onSelectionChanged();
  }

  void _addKeyAt(Offset local, (double, double) range, double height) {
    if (widget.lens != GraphLens.value) return;
    final frame = widget.magnet
        ? widget.axis.frameAt(local.dx).toDouble()
        : (local.dx / (widget.axis.perFrame <= 0 ? 1 : widget.axis.perFrame));
    final seconds = frame / (widget.fps <= 0 ? 1 : widget.fps);
    // The curve nearest the pointer vertically takes the key.
    GraphChannel? nearest;
    var best = 12.0;
    for (final channel in widget.channels) {
      final v = evaluateScalar(channel.scalar, seconds);
      final d = (_yOf(v, range, height) - local.dy).abs();
      if (d < best) {
        best = d;
        nearest = channel;
      }
    }
    if (nearest == null || nearest.isStatic && nearest.keys.isEmpty) {
      // A static channel gains its first key where its flat line is.
      if (nearest == null) return;
    }
    final keys = nearest.keys;
    final value =
        nearest.isStatic ? nearest.staticValue : evaluateKeys(keys, seconds);
    final taken = {
      for (final k in keys) _keyFrame(k, widget.fps).round(),
    };
    if (taken.contains(frame.round())) return;
    final next = [
      ...keys,
      BridgeKeyframe(
        time: timeOfSubframe(frame, widget.fpsNum, widget.fpsDen),
        value: value,
        interpIn: const BridgeSideInterp.linear(),
        interpOut: const BridgeSideInterp.linear(),
      ),
    ]..sort(
        (a, b) => rationalSeconds(a.time).compareTo(rationalSeconds(b.time)));
    commitChannelEdits({nearest: BridgeScalar.keyframed(next)});
    widget.onChanged();
  }

  // --- key drags -----------------------------------------------------------

  void _startKeyDrag(String id) {
    if (!widget.selectedKeys.contains(id)) _selectKey(id);
    setState(() {
      _keyDrag = _KeyDrag(id);
      _frozen = _range();
    });
  }

  void _commitKeyDrag((double, double) range, double height) {
    final drag = _keyDrag;
    setState(() {
      _keyDrag = null;
      _frozen = null;
    });
    if (drag == null || (drag.dxPx == 0 && drag.dyPx == 0)) return;

    final perFrame = widget.axis.perFrame;
    final dFrames = perFrame <= 0 ? 0.0 : drag.dxPx / perFrame;
    final span =
        (range.$2 - range.$1).abs() < 1e-12 ? 1.0 : range.$2 - range.$1;
    final dValue =
        widget.lens == GraphLens.value ? -drag.dyPx / height * span : 0.0;

    final edits = <GraphChannel, BridgeScalar>{};
    final newSelection = <String>{};
    for (final channel in widget.channels) {
      final keys = channel.keys;
      final movedIdx = <int>{};
      for (var i = 0; i < keys.length; i++) {
        if (widget.selectedKeys.contains('${channel.id}#$i')) movedIdx.add(i);
      }
      if (movedIdx.isEmpty) continue;

      // Every key with its (possibly moved) frame; a moved key may cross an
      // unmoved one — the list re-sorts, exactly as AE lets keys pass each
      // other — but two keys may not share a frame, which refuses the channel.
      final placed = <(double frame, BridgeKeyframe key, bool moved)>[];
      for (var i = 0; i < keys.length; i++) {
        final base = _keyFrame(keys[i], widget.fps);
        if (!movedIdx.contains(i)) {
          placed.add((base, keys[i], false));
          continue;
        }
        var frame = (base + dFrames).clamp(0.0, widget.frames.toDouble());
        if (widget.magnet) frame = frame.roundToDouble();
        placed.add((
          frame,
          BridgeKeyframe(
            time: timeOfSubframe(frame, widget.fpsNum, widget.fpsDen),
            value: keys[i].value + dValue,
            interpIn: keys[i].interpIn,
            interpOut: keys[i].interpOut,
          ),
          true,
        ));
      }
      placed.sort((a, b) => a.$1.compareTo(b.$1));
      var collides = false;
      for (var i = 0; i + 1 < placed.length; i++) {
        if ((placed[i].$1 - placed[i + 1].$1).abs() < 1e-9) collides = true;
      }
      if (collides) {
        // The gesture stops at the wall: this channel keeps what it had, and
        // its keys stay selected where they were.
        for (final i in movedIdx) {
          newSelection.add('${channel.id}#$i');
        }
        continue;
      }
      edits[channel] = BridgeScalar.keyframed([for (final p in placed) p.$2]);
      for (var i = 0; i < placed.length; i++) {
        if (placed[i].$3) newSelection.add('${channel.id}#$i');
      }
    }
    if (edits.isEmpty) return;
    commitChannelEdits(edits);
    widget.selectedKeys
      ..clear()
      ..addAll(newSelection);
    widget.onSelectionChanged();
    widget.onChanged();
  }

  /// Where key [index] of [channel] draws, with the drag in flight applied.
  Offset _keyPoint(
      GraphChannel channel, int index, (double, double) range, double height,
      {required bool isOut}) {
    final key = channel.keys[index];
    var x = widget.axis.xOf(_keyFrame(key, widget.fps));
    var y = _keyY(channel, index, range, height, isOut: isOut);
    final drag = _keyDrag;
    if (drag != null && widget.selectedKeys.contains('${channel.id}#$index')) {
      x += drag.dxPx;
      if (widget.lens == GraphLens.value) y += drag.dyPx;
    }
    // A speed-lens dot in flight: sideways under the pointer, and the side
    // being dragged sits at the speed the pointer is asking for.
    final dot = _handleDrag;
    if (dot != null &&
        dot.dotOnly &&
        dot.channel.id == channel.id &&
        dot.index == index) {
      x += dot.dxPx;
      if (dot.isOut == isOut) y = _yOf(dot.speed, range, height);
    }
    return Offset(x, y);
  }

  // --- handle drags --------------------------------------------------------

  /// The neighbour a side's handle reaches toward, or null at the ends.
  BridgeKeyframe? _neighbour(
          List<BridgeKeyframe> keys, int index, bool isOut) =>
      isOut
          ? (index + 1 < keys.length ? keys[index + 1] : null)
          : (index > 0 ? keys[index - 1] : null);

  /// Seconds ↔ pixels on the time axis, so handle geometry can be worked out
  /// where the user actually sees it: on screen.
  double _xOfSeconds(double t) => widget.axis.xOf(t * widget.fps);
  double _secondsOfX(double x) => widget.axis.perFrame <= 0
      ? 0
      : x / widget.axis.perFrame / (widget.fps <= 0 ? 1 : widget.fps);

  /// A side's handle endpoint in (seconds, value) whatever its interpolation —
  /// a bezier side's own, or where a linear side's *would* be. Used to measure
  /// the partner's on-screen length before a drag starts.
  ({double time, double value}) _sideEndpoint(
      List<BridgeKeyframe> keys, int index, bool isOut) {
    final key = keys[index];
    final nb = _neighbour(keys, index, isOut);
    final side = isOut ? key.interpOut : key.interpIn;
    return handleEndpoint(
      keyTime: rationalSeconds(key.time),
      keyValue: key.value,
      neighbourTime:
          nb == null ? rationalSeconds(key.time) : rationalSeconds(nb.time),
      isOut: isOut,
      speed: switch (side) {
        BridgeSideInterp_Bezier(:final field0) => field0.speed,
        _ => sideSpeedAtKey(keys, index, isOut: isOut),
      },
      influence: sideInfluence(side),
    );
  }

  void _startHandleDrag(GraphChannel channel, int index, bool isOut,
      bool dotOnly, (double, double) range, double height) {
    final keys = channel.keys;
    final key = keys[index];
    final side = isOut ? key.interpOut : key.interpIn;
    final other = isOut ? key.interpIn : key.interpOut;
    // Joined when both sides are beziers moving at the same speed; `Alt` held
    // as the drag begins flips it — break them apart, or join them back. A
    // side with no span on the other flank has nothing to join to.
    final joined = side is BridgeSideInterp_Bezier &&
        other is BridgeSideInterp_Bezier &&
        (side.field0.speed - other.field0.speed).abs() < 1e-9;
    final alt = HardwareKeyboard.instance.isAltPressed;
    final hasOther = _neighbour(keys, index, !isOut) != null;
    final speed = switch (side) {
      BridgeSideInterp_Bezier(:final field0) => field0.speed,
      _ => sideSpeedAtKey(keys, index, isOut: isOut),
    };

    setState(() {
      _handleDrag = _HandleDrag(
        channel: channel,
        index: index,
        isOut: isOut,
        mirrored: hasOther && (alt ? !joined : joined),
        speed: speed,
        influence: sideInfluence(side),
        partnerSpeed: switch (other) {
          BridgeSideInterp_Bezier(:final field0) => field0.speed,
          _ => sideSpeedAtKey(keys, index, isOut: !isOut),
        },
        partnerInfluence: sideInfluence(other),
        partnerLenPx: _handleLength(channel, index, !isOut, range, height),
        range: range,
        height: height,
        dotOnly: dotOnly,
      );
      _frozen = _range();
    });
  }

  void _updateHandleDrag(Offset local, (double, double) range, double height,
      {double dx = 0}) {
    final drag = _handleDrag;
    if (drag == null) return;
    final keys = drag.channel.keys;
    final key = keys[drag.index];
    final nb = _neighbour(keys, drag.index, drag.isOut);
    final keyTime = rationalSeconds(key.time);
    final pointerTime = _secondsOfX(local.dx);
    final pointerValue = _valueAt(local.dy, range, height);

    setState(() {
      if (widget.lens == GraphLens.speed) {
        // The speed lens: a dot's height IS that side's speed and its sideways
        // travel moves the keyframe in time; an influence handle's reach sets
        // the influence.
        drag.speed = pointerValue;
        if (drag.dotOnly) {
          drag.dxPx += dx;
        } else if (nb != null) {
          final dt = (rationalSeconds(nb.time) - keyTime).abs();
          if (dt > 1e-9) {
            drag.influence =
                ((drag.isOut ? pointerTime - keyTime : keyTime - pointerTime) /
                        dt)
                    .clamp(1e-3, 1.0)
                    .toDouble();
          }
        }
        return;
      }

      if (nb == null) return;
      final r = handleFromDrag(
        keyTime: keyTime,
        keyValue: key.value,
        neighbourTime: rationalSeconds(nb.time),
        isOut: drag.isOut,
        dragTime: pointerTime,
        dragValue: pointerValue,
      );
      drag.speed = r.speed;
      drag.influence = r.influence;
      _mirrorPartner(drag, key, r.speed, r.influence, range, height);
    });
  }

  /// Swing the joined partner opposite the dragged handle, keeping the pixel
  /// length it had when the gesture began.
  ///
  /// The whole calculation is in **screen** space: the two handles read as one
  /// straight line through the key, and staying straight means being opposite
  /// *as drawn* — the value axis and the time axis have different units and
  /// their own zooms, so mirroring in value space would bend the line and
  /// stretch the partner as the pair swings toward vertical.
  void _mirrorPartner(_HandleDrag drag, BridgeKeyframe key, double speed,
      double influence, (double, double) range, double height) {
    if (!drag.mirrored) return;
    final keys = drag.channel.keys;
    final partnerNb = _neighbour(keys, drag.index, !drag.isOut);
    if (partnerNb == null) return;
    final keyTime = rationalSeconds(key.time);
    final nb = _neighbour(keys, drag.index, drag.isOut);
    if (nb == null) return;

    // Where the dragged handle actually ended up (its reach is clamped inside
    // the span), so the partner is opposite what is drawn, not opposite the
    // raw pointer.
    final e = handleEndpoint(
      keyTime: keyTime,
      keyValue: key.value,
      neighbourTime: rationalSeconds(nb.time),
      isOut: drag.isOut,
      speed: speed,
      influence: influence,
    );
    final keyPx = Offset(_xOfSeconds(keyTime), _yOf(key.value, range, height));
    final direction =
        Offset(_xOfSeconds(e.time), _yOf(e.value, range, height)) - keyPx;
    final length = direction.distance;
    if (length < 1e-6) return;
    // The partner keeps the pixel length it began the gesture with, whatever
    // the pair's angle: what the eye reads is length on screen, and a handle
    // that grew as the tangent swung would be the thing this exists to avoid.
    final partnerPx = keyPx - direction / length * drag.partnerLenPx;

    final pr = handleFromDrag(
      keyTime: keyTime,
      keyValue: key.value,
      neighbourTime: rationalSeconds(partnerNb.time),
      isOut: !drag.isOut,
      dragTime: _secondsOfX(partnerPx.dx),
      dragValue: _valueAt(partnerPx.dy, range, height),
    );
    drag.partnerSpeed = pr.speed;
    drag.partnerInfluence = pr.influence;
  }

  void _commitHandleDrag() {
    final drag = _handleDrag;
    setState(() {
      _handleDrag = null;
      _frozen = null;
    });
    if (drag == null) return;
    final shown = _keysWithHandleDrag(drag, drag.channel.keys);

    // Both sides keep the length they were left at: the dragged one wherever
    // the pointer put it, the partner exactly the length it started with. Held
    // against the scale they were drawn under, so a later zoom re-measures
    // rather than shrinking them.
    if (widget.lens == GraphLens.value && !drag.dotOnly) {
      final key = shown[drag.index];
      final keyPx = Offset(_xOfSeconds(rationalSeconds(key.time)),
          _yOf(key.value, drag.range, drag.height));
      final end = _sideEndpoint(shown, drag.index, drag.isOut);
      _rememberLength(
        drag.channel,
        key,
        drag.isOut,
        (Offset(_xOfSeconds(end.time),
                    _yOf(end.value, drag.range, drag.height)) -
                keyPx)
            .distance,
        drag.range,
        drag.height,
      );
      if (drag.mirrored) {
        _rememberLength(drag.channel, key, !drag.isOut, drag.partnerLenPx,
            drag.range, drag.height);
      }
    }

    // A speed-lens dot also carries the key sideways: commit the move with the
    // same rules a key drag follows — whole frames with the magnet on, and no
    // two keys sharing a frame.
    if (drag.dotOnly && drag.dxPx != 0) {
      final moved = _keysWithDotTimeMove(drag, shown);
      if (moved == null) {
        // The move collided; the easing still stands where the key already is.
        commitChannelEdits({drag.channel: BridgeScalar.keyframed(shown)});
        widget.onChanged();
        return;
      }
      commitChannelEdits({drag.channel: BridgeScalar.keyframed(moved)});
      widget.onChanged();
      return;
    }
    commitChannelEdits({drag.channel: BridgeScalar.keyframed(shown)});
    widget.onChanged();
  }

  /// [keys] with a speed-lens dot's sideways travel applied to its keyframe,
  /// or null when the move would land on a neighbour.
  List<BridgeKeyframe>? _keysWithDotTimeMove(
      _HandleDrag drag, List<BridgeKeyframe> keys) {
    final perFrame = widget.axis.perFrame;
    if (perFrame <= 0) return null;
    final base = _keyFrame(keys[drag.index], widget.fps);
    var frame =
        (base + drag.dxPx / perFrame).clamp(0.0, widget.frames.toDouble());
    if (widget.magnet) frame = frame.roundToDouble();
    if ((frame - base).abs() < 1e-9) return null;
    for (var i = 0; i < keys.length; i++) {
      if (i == drag.index) continue;
      if ((_keyFrame(keys[i], widget.fps) - frame).abs() < 1e-9) return null;
    }
    final moved = [
      for (var i = 0; i < keys.length; i++)
        if (i == drag.index)
          BridgeKeyframe(
            time: timeOfSubframe(frame, widget.fpsNum, widget.fpsDen),
            value: keys[i].value,
            interpIn: keys[i].interpIn,
            interpOut: keys[i].interpOut,
          )
        else
          keys[i],
    ]..sort(
        (a, b) => rationalSeconds(a.time).compareTo(rationalSeconds(b.time)));
    return moved;
  }

  /// [keys] with the drag's provisional easing written into its key — both
  /// sides when they are joined, so the curve, the handle and its partner all
  /// move together while the pointer is down.
  List<BridgeKeyframe> _keysWithHandleDrag(
      _HandleDrag drag, List<BridgeKeyframe> keys) {
    final dragged = BridgeSideInterp.bezier(
        BridgeBezierSide(speed: drag.speed, influence: drag.influence));
    final partner = drag.mirrored
        ? BridgeSideInterp.bezier(BridgeBezierSide(
            speed: drag.partnerSpeed, influence: drag.partnerInfluence))
        : null;
    return [
      for (var i = 0; i < keys.length; i++)
        if (i == drag.index)
          BridgeKeyframe(
            time: keys[i].time,
            value: keys[i].value,
            interpIn: drag.isOut ? (partner ?? keys[i].interpIn) : dragged,
            interpOut: drag.isOut ? dragged : (partner ?? keys[i].interpOut),
          )
        else
          keys[i],
    ];
  }

  /// The keys as the painter should read them — the handle drag's provisional
  /// sides swapped in, so the curve follows the handle live.
  List<BridgeKeyframe> _shownKeys(GraphChannel channel) {
    final drag = _handleDrag;
    if (drag == null || drag.channel.id != channel.id) return channel.keys;
    return _keysWithHandleDrag(drag, channel.keys);
  }

  // --- menus ---------------------------------------------------------------

  Future<void> _showKeyMenu(
      GraphChannel channel, int index, Offset position) async {
    final picked = await showLumitPopup<String>(
      context: context,
      position: position,
      builder: (close) => FloatSurface(
        width: 170,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MenuRow(
                onPressed: () => close('linear'), child: const Text('Linear')),
            MenuRow(
                onPressed: () => close('ease'), child: const Text('Easy ease')),
            MenuRow(onPressed: () => close('hold'), child: const Text('Hold')),
            MenuRow(
                onPressed: () => close('delete'),
                child: const Text('Delete key')),
          ],
        ),
      ),
    );
    if (picked == null) return;
    final id = '${channel.id}#$index';
    if (picked == 'delete') {
      _deleteSelection(fallback: id);
      return;
    }
    final targets =
        widget.selectedKeys.contains(id) ? widget.selectedKeys : {id};
    applyInterpToSelection(
      channels: widget.channels,
      selectedKeys: targets,
      side: switch (picked) {
        'linear' => const BridgeSideInterp.linear(),
        'hold' => const BridgeSideInterp.hold(),
        _ => easyEase,
      },
    );
    widget.onChanged();
  }

  /// Delete the selected keys (or [fallback] when none) — the last key of a
  /// curve leaves a static value holding what it held.
  void _deleteSelection({String? fallback}) {
    final targets = widget.selectedKeys.isNotEmpty
        ? widget.selectedKeys
        : {if (fallback != null) fallback};
    final edits = <GraphChannel, BridgeScalar>{};
    for (final channel in widget.channels) {
      final keys = channel.keys;
      final rest = <BridgeKeyframe>[];
      var removed = false;
      double? lastRemoved;
      for (var i = 0; i < keys.length; i++) {
        if (targets.contains('${channel.id}#$i')) {
          removed = true;
          lastRemoved = keys[i].value;
        } else {
          rest.add(keys[i]);
        }
      }
      if (!removed) continue;
      edits[channel] = rest.isEmpty
          ? BridgeScalar.static_(lastRemoved ?? 0)
          : BridgeScalar.keyframed(rest);
    }
    if (edits.isEmpty) return;
    commitChannelEdits(edits);
    widget.selectedKeys.clear();
    widget.onSelectionChanged();
    widget.onChanged();
  }

  // --- build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;

    // An empty graph is still a graph. It used to be replaced outright by a
    // line of text, which took the wheel handler, the grid, the value axis and
    // the horizontal scrollbar with it: with nothing selected you could not
    // Ctrl-scroll to zoom, could not pan, and had no axis to read — the pane
    // only became a pane once it had something in it. The empty range is a
    // real range (`fitValueRange` answers 0..1 for no data), so everything
    // below works with no channels; the message is drawn over the top instead.
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        final range = _range();
        _lastRange = range;
        _paneSize = Size(constraints.maxWidth, height);

        return Listener(
          // Claimed through the resolver, not handled outright: the pane sits
          // inside the Timeline's horizontal scroll view, which registers for
          // the same wheel event and would *also* act on it — scrolling the
          // curves sideways while this handler zoomed or panned them. The
          // resolver gives one event to exactly one handler, and the innermost
          // registrant (this one) wins.
          onPointerSignal: (event) {
            if (event is! PointerScrollEvent) return;
            GestureBinding.instance.pointerSignalResolver.register(event,
                (resolved) {
              if (resolved is PointerScrollEvent) _wheel(resolved);
            });
          },
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              // Repainted as the Timeline scrolls, not merely as it rebuilds:
              // scrolling moves this pane without rebuilding it, and the value
              // labels are pinned to the viewport, so they have to be redrawn
              // at the new edge. The listener is the scroll controller the
              // Timeline already owns.
              Positioned.fill(
                child: AnimatedBuilder(
                  animation: widget.hScroll ?? const AlwaysStoppedAnimation(0),
                  builder: (context, _) => ClipRect(
                    child: CustomPaint(
                      painter: _GraphPainter(
                        channels: widget.channels,
                        shownKeys: [
                          for (final c in widget.channels) _shownKeys(c)
                        ],
                        lens: widget.lens,
                        axis: widget.axis,
                        fps: widget.fps,
                        range: range,
                        palette: t.curve,
                        comp: Provider.of<LumitUiState>(context, listen: false)
                            .model,
                        grid: t.hairline,
                        label: t.small.copyWith(color: t.textMuted),
                        viewportLeft: _viewportLeft,
                      ),
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: MarqueeSelect(
                  key: const ValueKey('graph-marquee'),
                  onSelect: (rect) => _applyMarquee(rect, range, height),
                  onTapAt: (local) => _tapPane(local, range, height),
                  onClear: () {},
                ),
              ),
              // The tangent handles (or speed influence handles), above the
              // marquee so they win their own gestures.
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _HandlesPainter(
                      state: this,
                      range: range,
                      height: height,
                      colour: t.warning,
                    ),
                  ),
                ),
              ),
              // Which of the two wins where they overlap depends on the lens,
              // and they *do* overlap: a handle's reach is a fraction of the
              // gap to the next key, so on a long composition it sits within
              // a few pixels of its own key.
              //
              // Value lens: the handle is on top. It is the finer gesture, the
              // key is grabbable everywhere else along the curve, and a miss
              // that drops the selection also takes the handles away.
              // Speed lens: the dot is on top — it is the keyframe itself, and
              // its influence bar runs out sideways from underneath it.
              if (widget.lens == GraphLens.value) ...[
                ..._keyHandles(t, range, height),
                ..._tangentHandles(t, range, height),
              ] else ...[
                ..._tangentHandles(t, range, height),
                ..._keyHandles(t, range, height),
              ],
              // Over the live pane rather than instead of it, so the grid and
              // the axis stay readable behind the invitation to fill them.
              if (widget.channels.isEmpty)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Center(
                      child: Text(
                        'Select a property to see its curve — click its name '
                        'in the outline; Ctrl/Shift-click adds more',
                        style: t.small,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// The grabbable key glyphs.
  List<Widget> _keyHandles(
      LumitTheme t, (double, double) range, double height) {
    final out = <Widget>[];
    for (final channel in widget.channels) {
      final keys = channel.keys;
      for (var i = 0; i < keys.length; i++) {
        final id = '${channel.id}#$i';
        final chosen = widget.selectedKeys.contains(id);
        final sides = widget.lens == GraphLens.value
            ? const [true]
            // Speed lens: an in dot and an out dot, moved independently —
            // the ends have only the side that exists.
            : [
                if (i > 0) false,
                if (i + 1 < keys.length || keys.length == 1) true,
              ];
        for (final isOut in sides) {
          final point = _keyPoint(channel, i, range, height, isOut: isOut);
          out.add(Positioned(
            left: point.dx - _keyGrab / 2,
            top: point.dy - _keyGrab / 2,
            child: GestureDetector(
              key: ValueKey<String>(widget.lens == GraphLens.value
                  ? 'graph-key-$id'
                  : 'graph-key-$id-${isOut ? 'out' : 'in'}'),
              behavior: HitTestBehavior.opaque,
              onTap: () => _selectKey(id,
                  toggle: HardwareKeyboard.instance.isControlPressed),
              onSecondaryTapDown: (d) =>
                  _showKeyMenu(channel, i, d.globalPosition),
              onPanStart: (_) {
                if (widget.lens == GraphLens.value) {
                  _startKeyDrag(id);
                } else {
                  // A speed dot: this side's speed vertically, the keyframe's
                  // time sideways. It does not select on the way — changing
                  // the selection mid-gesture rebuilds the handles out from
                  // under the recogniser and the drag dies on its first move.
                  _startHandleDrag(channel, i, isOut, true, range, height);
                }
              },
              onPanUpdate: (d) {
                if (widget.lens == GraphLens.value) {
                  setState(() {
                    _keyDrag
                      ?..dxPx += d.delta.dx
                      ..dyPx += d.delta.dy;
                  });
                } else {
                  final box = context.findRenderObject();
                  if (box is RenderBox) {
                    _updateHandleDrag(
                        box.globalToLocal(d.globalPosition), range, height,
                        dx: d.delta.dx);
                  }
                }
              },
              onPanEnd: (_) {
                if (widget.lens == GraphLens.value) {
                  _commitKeyDrag(range, height);
                } else {
                  _commitHandleDrag();
                }
              },
              onPanCancel: () => setState(() {
                _keyDrag = null;
                _handleDrag = null;
                _frozen = null;
              }),
              // The glyph is small; the target around it is not (see
              // [_keyGrab]).
              child: SizedBox(
                width: _keyGrab,
                height: _keyGrab,
                child: Center(
                  child: SizedBox(
                    width: 10,
                    height: 10,
                    child: CustomPaint(
                      painter: _KeyGlyphPainter(
                        key_: keys[i],
                        colour: chosen
                            ? t.accent
                            : t.curve[channel.colourIndex % t.curve.length],
                        speedDot: widget.lens == GraphLens.speed,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ));
        }
      }
    }
    return out;
  }

  /// The draggable tangent endpoints for selected keys.
  List<Widget> _tangentHandles(
      LumitTheme t, (double, double) range, double height) {
    final out = <Widget>[];
    for (final channel in widget.channels) {
      final keys = _shownKeys(channel);
      for (var i = 0; i < keys.length; i++) {
        if (!widget.selectedKeys.contains('${channel.id}#$i')) continue;
        for (final isOut in const [true, false]) {
          final e = _handleEndpointFor(channel, keys, i, isOut);
          if (e == null) continue;
          final point = Offset(
            widget.axis.xOf(e.$1 * widget.fps),
            _yOf(e.$2, range, height),
          );
          // A handle's reach is a fraction of the gap to the next key, so on a
          // long composition both handles sit a few pixels from their key —
          // and from each other. A fixed target would make which one you get a
          // coin toss, so it never grows past the reach itself: the two stay
          // tellable apart however tight the curve, and the key underneath
          // keeps whatever is left.
          final reach =
              (point - _keyPoint(channel, i, range, height, isOut: true))
                  .distance;
          final grab = reach.clamp(9.0, _handleGrab);
          out.add(Positioned(
            left: point.dx - grab / 2,
            top: point.dy - grab / 2,
            child: GestureDetector(
              key: ValueKey<String>(
                  'graph-handle-${channel.id}#$i-${isOut ? 'out' : 'in'}'),
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) =>
                  _startHandleDrag(channel, i, isOut, false, range, height),
              onPanUpdate: (d) {
                final box = context.findRenderObject();
                if (box is RenderBox) {
                  _updateHandleDrag(
                      box.globalToLocal(d.globalPosition), range, height);
                }
              },
              onPanEnd: (_) => _commitHandleDrag(),
              onPanCancel: () => setState(() {
                _handleDrag = null;
                _frozen = null;
              }),
              // A generous target around a small dot: a handle that takes two
              // attempts to grab loses the keyframe's selection on the miss.
              child: SizedBox(
                width: grab,
                height: grab,
                child: Center(
                  child: SizedBox(
                    width: 8,
                    height: 8,
                    child: CustomPaint(painter: _HandleDotPainter(t.warning)),
                  ),
                ),
              ),
            ),
          ));
        }
      }
    }
    return out;
  }

  /// A selected key's handle endpoint in (seconds, y-value) for the current
  /// lens, or null where the side has no span to reach into.
  (double, double)? _handleEndpointFor(
      GraphChannel channel, List<BridgeKeyframe> keys, int index, bool isOut) {
    final nb = _neighbour(keys, index, isOut);
    if (nb == null) return null;
    final key = keys[index];
    final side = isOut ? key.interpOut : key.interpIn;
    if (widget.lens == GraphLens.value) {
      // Handles belong to eased sides; a linear side has none to show.
      if (side is! BridgeSideInterp_Bezier) return null;
      final e = handleEndpoint(
        keyTime: rationalSeconds(key.time),
        keyValue: key.value,
        neighbourTime: rationalSeconds(nb.time),
        isOut: isOut,
        speed: side.field0.speed,
        influence: sideInfluence(side),
      );
      return (e.time, e.value);
    }
    // Speed lens: the influence handle reaches horizontally from the dot.
    final keyTime = rationalSeconds(key.time);
    final dt = (rationalSeconds(nb.time) - keyTime).abs();
    final speed = sideSpeedAtKey(keys, index, isOut: isOut);
    final reach = sideInfluence(side) * dt;
    return (isOut ? keyTime + reach : keyTime - reach, speed);
  }
}

// ---------------------------------------------------------------------------
// Painters.
// ---------------------------------------------------------------------------

/// The grid, the value-axis labels, and every channel's curve.
class _GraphPainter extends CustomPainter {
  final List<GraphChannel> channels;
  final List<List<BridgeKeyframe>> shownKeys;
  final GraphLens lens;
  final TimelineAxis axis;
  final double fps;
  final (double, double) range;
  final List<Color> palette;
  final Color grid;
  final TextStyle label;
  final CompModel comp;

  /// Where the viewport's left edge sits in the canvas's own coordinates.
  ///
  /// The pane is as wide as the whole comp and lives inside the Timeline's
  /// horizontal scroll view, so canvas x 0 is the *start of time*, not the
  /// left of the window. The value labels were painted there and scrolled out
  /// of sight the moment the Timeline moved, leaving the grid lines with
  /// nothing naming them. Painting at the viewport's edge keeps the axis
  /// readable wherever the view is and at whatever zoom.
  final double viewportLeft;

  const _GraphPainter({
    required this.channels,
    required this.shownKeys,
    required this.lens,
    required this.axis,
    required this.fps,
    required this.range,
    required this.palette,
    required this.grid,
    required this.label,
    required this.comp,
    required this.viewportLeft,
  });

  double _yOf(double v, Size size) {
    final (lo, hi) = range;
    final span = (hi - lo).abs() < 1e-12 ? 1.0 : hi - lo;
    return size.height - (v - lo) / span * size.height;
  }

  @override
  void paint(Canvas canvas, Size size) {
    _paintGrid(canvas, size);
    final f = fps <= 0 ? 1.0 : fps;
    for (var c = 0; c < channels.length; c++) {
      final channel = channels[c];
      final keys = shownKeys[c];
      final paint = Paint()
        ..color = palette[channel.colourIndex % palette.length]
        ..strokeWidth = 1.4
        ..style = PaintingStyle.stroke;

      if (channel.scalar is! BridgeScalar_Expression) {
        if (channel.isStatic || keys.isEmpty) {
          // A static property is a flat line of its value (a flat 0 as speed).
          final y =
              _yOf(lens == GraphLens.value ? channel.staticValue : 0, size);
          canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
          continue;
        }
        if (keys.length == 1) {
          final y = _yOf(lens == GraphLens.value ? keys.first.value : 0, size);
          canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
          continue;
        }
      }

      final path = Path();
      const step = 2.5;
      var first = true;

      if (channel.scalar case BridgeScalar_Expression _) {
        var startSeconds = 0 / axis.perFrame / f;
        var endSeconds = size.width / axis.perFrame / f;
        var start =
            timeOfSubframe(startSeconds * f, comp.fpsExact.$1, comp.fpsExact.$2);
        var end =
            timeOfSubframe(endSeconds * f, comp.fpsExact.$1, comp.fpsExact.$2);

        int samples = 500;
        final result = sampleScalarRangeWithContext(
            scalar: channel.scalar,
            layer: channel.entry.layer,
            start: start,
            end: end,
            samples: samples);

        for (int i = 0; i < result.length; i++) {
          var v = result[i];
          var alpha = i.toDouble() / samples.toDouble();
          var x = size.width * alpha;

          final point = Offset(x, _yOf(v, size));
          if (first) {
            path.moveTo(point.dx, point.dy);
            first = false;
          } else {
            path.lineTo(point.dx, point.dy);
          }
        }
      } else {
        for (var x = 0.0; x <= size.width; x += step) {
          final seconds = axis.perFrame <= 0 ? 0.0 : x / axis.perFrame / f;

          var v = 0.0;

          v = lens == GraphLens.value
              ? evaluateKeys(keys, seconds)
              : evaluateKeysSpeed(keys, seconds);

          final point = Offset(x, _yOf(v, size));
          if (first) {
            path.moveTo(point.dx, point.dy);
            first = false;
          } else {
            path.lineTo(point.dx, point.dy);
          }
        }
      }
      canvas.drawPath(path, paint);

      // Speed lens: the vertical join at each key, where in and out speed
      // step — drawn faint so a discontinuity reads as one key, not two.
      if (lens == GraphLens.speed) {
        final joinPaint = Paint()
          ..color = paint.color.withValues(alpha: 0.35)
          ..strokeWidth = 1;
        for (var i = 0; i < keys.length; i++) {
          final x = axis.xOf(_keyFrame(keys[i], f));
          final yIn = _yOf(sideSpeedAtKey(keys, i, isOut: false), size);
          final yOut = _yOf(sideSpeedAtKey(keys, i, isOut: true), size);
          if ((yIn - yOut).abs() > 1) {
            canvas.drawLine(Offset(x, yIn), Offset(x, yOut), joinPaint);
          }
        }
      }
    }
  }

  void _paintGrid(Canvas canvas, Size size) {
    final (lo, hi) = range;
    final span = (hi - lo).abs() < 1e-12 ? 1.0 : hi - lo;
    final paint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    // A nice value step whose lines sit at least ~36 px apart.
    final rawStep = span / (size.height / 36).clamp(1, 12);
    final magnitude = _pow10((rawStep.abs()).clamp(1e-12, double.infinity));
    var step = magnitude;
    for (final m in const [1.0, 2.0, 5.0, 10.0]) {
      if (magnitude * m >= rawStep) {
        step = magnitude * m;
        break;
      }
    }
    if (!step.isFinite || step <= 0) return;
    final start = (lo / step).ceilToDouble() * step;
    for (var v = start; v <= hi; v += step) {
      final y = _yOf(v, size);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
      final text = TextPainter(
        text: TextSpan(
            text: v.abs() >= 100 || v == v.roundToDouble()
                ? v.round().toString()
                : v.toStringAsFixed(1),
            style: label),
        textDirection: TextDirection.ltr,
      )..layout();
      text.paint(
          canvas,
          Offset(viewportLeft + 2,
              (y - text.height - 1).clamp(0, size.height - 12)));
    }
  }

  /// The power of ten at or just under `v` (0.03 → 0.01, 30 → 10).
  static double _pow10(double v) {
    var p = 1.0;
    while (p > v) {
      p /= 10;
    }
    while (p * 10 <= v) {
      p *= 10;
    }
    return p;
  }

  @override
  bool shouldRepaint(_GraphPainter old) => true;

  /// A picture, not a control: hits fall through to the marquee.
  @override
  bool? hitTest(Offset position) => false;
}

/// The lines from selected keys to their tangent (or influence) endpoints.
class _HandlesPainter extends CustomPainter {
  final GraphEditorFrbState state;
  final (double, double) range;
  final double height;
  final Color colour;

  const _HandlesPainter({
    required this.state,
    required this.range,
    required this.height,
    required this.colour,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = colour.withValues(alpha: 0.8)
      ..strokeWidth = 1;
    final widget = state.widget;
    for (final channel in widget.channels) {
      final keys = state._shownKeys(channel);
      for (var i = 0; i < keys.length; i++) {
        if (!widget.selectedKeys.contains('${channel.id}#$i')) continue;
        for (final isOut in const [true, false]) {
          final e = state._handleEndpointFor(channel, keys, i, isOut);
          if (e == null) continue;
          final from = widget.lens == GraphLens.value
              ? state._keyPoint(channel, i, range, height, isOut: true)
              : state._keyPoint(channel, i, range, height, isOut: isOut);
          final to = Offset(
            widget.axis.xOf(e.$1 * widget.fps),
            state._yOf(e.$2, range, height),
          );
          canvas.drawLine(from, to, paint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_HandlesPainter old) => true;

  @override
  bool? hitTest(Offset position) => false;
}

/// A keyframe's glyph, coded by interpolation: diamond for linear, circle for
/// an eased (bezier) key, square for hold — the same coding the lanes will
/// learn (docs/07 §4.3). On the speed lens every dot is a circle.
class _KeyGlyphPainter extends CustomPainter {
  final BridgeKeyframe key_;
  final Color colour;
  final bool speedDot;
  const _KeyGlyphPainter({
    required this.key_,
    required this.colour,
    required this.speedDot,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = colour;
    final half = size.width / 2;
    if (speedDot ||
        key_.interpIn is BridgeSideInterp_Bezier ||
        key_.interpOut is BridgeSideInterp_Bezier) {
      canvas.drawCircle(Offset(half, half), half - 1, paint);
      return;
    }
    if (key_.interpOut is BridgeSideInterp_Hold) {
      canvas.drawRect(
          Rect.fromLTWH(1, 1, size.width - 2, size.height - 2), paint);
      return;
    }
    canvas.drawPath(
      Path()
        ..moveTo(half, 0)
        ..lineTo(size.width, half)
        ..lineTo(half, size.height)
        ..lineTo(0, half)
        ..close(),
      paint,
    );
  }

  @override
  bool shouldRepaint(_KeyGlyphPainter old) =>
      old.colour != colour ||
      old.speedDot != speedDot ||
      old.key_.interpIn != key_.interpIn ||
      old.key_.interpOut != key_.interpOut;
}

/// A tangent endpoint's dot.
class _HandleDotPainter extends CustomPainter {
  final Color colour;
  const _HandleDotPainter(this.colour);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawCircle(Offset(size.width / 2, size.height / 2),
        size.width / 2 - 1, Paint()..color = colour);
  }

  @override
  bool shouldRepaint(_HandleDotPainter old) => old.colour != colour;
}
