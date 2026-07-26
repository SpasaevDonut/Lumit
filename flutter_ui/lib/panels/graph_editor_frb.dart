// The graph editor: a layer's animated properties as curves you can shape.
//
// One lane per animated channel — a transform property or a float effect
// parameter — drawn as value against time, with its keyframes as diamonds.
// Dragging a diamond moves it in time *and* value at once; right-clicking one
// sets its easing. Selected keys copy and paste onto another channel.
//
// **Why the whole animation goes back each time.** A key drag changes a time and
// a value together, and `set_transform` / `set_value` take the whole
// `BridgeScalar`. So every gesture here — move, ease, add, delete, paste — is a
// single write and therefore a single undo step. v0 needed one op per property
// per change and a key drag cost two, which is the thing this shape exists to
// avoid.
//
// **What is not here.** The speed and time lenses (v0's `graph_speed_lens.dart`
// and `graph_time_lens.dart`): they are the same curve read a different way, and
// the value lens is the one you cannot work without. Bezier *handles* are not
// draggable either — the interp menu sets the AE presets, which is what the
// easing is 95% of the time. Both are recorded in docs/TODO.md.

import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:lumit_flutter/src/rust/api/effect.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';

import '../theme/theme.dart';
import '../widgets/controls.dart';

/// One animatable channel: what to call it, what it currently is, and how to
/// write a new animation for it.
///
/// The graph editor never needs to know whether a channel is a transform
/// property or an effect parameter — only how to read and write it — so this is
/// the whole of what it is handed.
class GraphChannel {
  final String label;
  final BridgeScalar scalar;
  final void Function(BridgeScalar) write;

  /// Distinguishes this channel's keys from another's, for selection.
  final String id;

  const GraphChannel({
    required this.id,
    required this.label,
    required this.scalar,
    required this.write,
  });

  List<BridgeKeyframe> get keys => switch (scalar) {
        BridgeScalar_Keyframed(:final field0) => field0,
        BridgeScalar_Static() => const [],
      };
}

/// Every animated channel on `layer` — the transform properties and the float
/// effect parameters that currently carry a curve.
///
/// A static property is not listed: the graph editor shapes curves, and a lane
/// with no keys in it is a line the user cannot do anything with. The stopwatch
/// in the Effect controls panel is where a property becomes animated.
List<GraphChannel> animatedChannelsOf(LayerReference layer) {
  final out = <GraphChannel>[];

  void addTransform(String label, BridgeTransformProp prop, BridgeScalar s) {
    if (s is! BridgeScalar_Keyframed) return;
    out.add(GraphChannel(
      id: 'tf-${prop.name}',
      label: label,
      scalar: s,
      write: (next) => layer.setTransform(prop: prop, value: next),
    ));
  }

  final tf = layer.getTransform();
  addTransform('Anchor x', BridgeTransformProp.anchorX, tf.anchorX);
  addTransform('Anchor y', BridgeTransformProp.anchorY, tf.anchorY);
  addTransform('Position x', BridgeTransformProp.positionX, tf.positionX);
  addTransform('Position y', BridgeTransformProp.positionY, tf.positionY);
  addTransform('Position z', BridgeTransformProp.positionZ, tf.positionZ);
  addTransform('Scale x', BridgeTransformProp.scaleX, tf.scaleX);
  addTransform('Scale y', BridgeTransformProp.scaleY, tf.scaleY);
  addTransform('Rotation', BridgeTransformProp.rotation, tf.rotation);
  addTransform('Rotation x', BridgeTransformProp.rotationX, tf.rotationX);
  addTransform('Rotation y', BridgeTransformProp.rotationY, tf.rotationY);
  addTransform('Opacity', BridgeTransformProp.opacity, tf.opacity);

  for (final effect in layer.getEffects()) {
    for (final param in listParameters(effect: effect.name())) {
      if (param.kind is! BridgeParamKind_Float) continue;
      final value = effect.getValue(id: param.id);
      if (value is! BridgeEffectValue_Float) continue;
      if (value.field0 is! BridgeScalar_Keyframed) continue;
      out.add(GraphChannel(
        id: '${effect.id()}-${param.id}',
        label: '${effect.name()} · ${param.label}',
        scalar: value.field0,
        write: (next) {
          // The staged copy is committed whole, exactly as the Effect controls
          // panel does it — one `SetLayerEffects` for the change.
          final staged = layer.getEffects();
          for (final candidate in staged) {
            if (candidate.id() != effect.id()) continue;
            candidate.setValue(
                id: param.id, value: BridgeEffectValue.float(next));
          }
          layer.setEffects(effects: staged);
        },
      ));
    }
  }

  return out;
}

/// Keys cut or copied out of a channel, waiting to be pasted into another.
///
/// Module-level and deliberately not per-panel: copying in one lane and pasting
/// in the next is the whole point, and a clipboard scoped to a widget would be
/// emptied by the rebuild that follows the copy.
List<BridgeKeyframe> _clipboard = const [];

class GraphEditorFrb extends StatefulWidget {
  final CompositionReference comp;
  final LayerReference? layer;
  final int frames;
  final int playheadFrame;
  final ValueChanged<int> onSeek;
  final VoidCallback onChanged;

  const GraphEditorFrb({
    super.key,
    required this.comp,
    required this.layer,
    required this.frames,
    required this.playheadFrame,
    required this.onSeek,
    required this.onChanged,
  });

  @override
  State<GraphEditorFrb> createState() => _GraphEditorFrbState();
}

class _GraphEditorFrbState extends State<GraphEditorFrb> {
  /// `channelId#index` for each selected key.
  final Set<String> _selected = {};

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final layer = widget.layer;
    if (layer == null) {
      return Center(
        child: Text('Select a layer to edit its curves', style: t.small),
      );
    }

    final channels = animatedChannelsOf(layer);
    if (channels.isEmpty) {
      return Center(
        child: Text(
          'Nothing on this layer is animated yet — use a stopwatch in Effect '
          'controls',
          style: t.small,
          textAlign: TextAlign.center,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar(t, channels),
        Expanded(
          child: ListView(
            children: [
              for (final channel in channels)
                _Lane(
                  key: ValueKey<String>('graph-lane-${channel.id}'),
                  channel: channel,
                  comp: widget.comp,
                  frames: widget.frames,
                  playheadFrame: widget.playheadFrame,
                  selected: _selected,
                  onSelectionChanged: () => setState(() {}),
                  onChanged: widget.onChanged,
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _toolbar(LumitTheme t, List<GraphChannel> channels) {
    // The selection can span lanes, but a copy takes one lane's worth — pasting
    // a mixture into a single channel has no meaning.
    final source = channels
        .where((c) => _selected.any((s) => s.startsWith('${c.id}#')))
        .firstOrNull;

    return Container(
      height: 22,
      color: t.surface1,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          HouseButton(
            key: const ValueKey('graph-copy'),
            small: true,
            frameless: true,
            onPressed: source == null
                ? null
                : () {
                    _clipboard = [
                      for (var i = 0; i < source.keys.length; i++)
                        if (_selected.contains('${source.id}#$i'))
                          source.keys[i],
                    ];
                    setState(() {});
                  },
            child: Text('Copy keys', style: t.small),
          ),
          const SizedBox(width: 6),
          HouseButton(
            key: const ValueKey('graph-paste'),
            small: true,
            frameless: true,
            onPressed: _clipboard.isEmpty || source == null
                ? null
                : () {
                    _pasteInto(source);
                    widget.onChanged();
                  },
            child: Text('Paste keys', style: t.small),
          ),
          const Spacer(),
          Text('${_selected.length} selected',
              style: t.small.copyWith(color: t.textMuted)),
        ],
      ),
    );
  }

  /// Paste the clipboard into `channel`, offset so the earliest pasted key lands
  /// on the playhead — the AE behaviour, and the only one that does not need the
  /// user to know where the keys came from.
  void _pasteInto(GraphChannel channel) {
    if (_clipboard.isEmpty) return;
    final earliest = _clipboard
        .map((k) => widget.comp.frameAtTime(time: k.time))
        .reduce((a, b) => a < b ? a : b);
    final shift = widget.playheadFrame - earliest;

    final merged = <int, BridgeKeyframe>{
      for (final key in channel.keys)
        widget.comp.frameAtTime(time: key.time): key,
    };
    for (final key in _clipboard) {
      final frame = widget.comp.frameAtTime(time: key.time) + shift;
      // A pasted key replaces one already at that frame rather than sitting
      // beside it: two keys at one time is not a curve the engine will take.
      merged[frame] = BridgeKeyframe(
        time: widget.comp.timeOfFrame(frame: frame),
        value: key.value,
        interpIn: key.interpIn,
        interpOut: key.interpOut,
      );
    }
    final frames = merged.keys.toList()..sort();
    channel.write(
        BridgeScalar.keyframed([for (final f in frames) merged[f]!]));
  }
}

/// One channel's curve.
class _Lane extends StatefulWidget {
  final GraphChannel channel;
  final CompositionReference comp;
  final int frames;
  final int playheadFrame;
  final Set<String> selected;
  final VoidCallback onSelectionChanged;
  final VoidCallback onChanged;

  const _Lane({
    super.key,
    required this.channel,
    required this.comp,
    required this.frames,
    required this.playheadFrame,
    required this.selected,
    required this.onSelectionChanged,
    required this.onChanged,
  });

  @override
  State<_Lane> createState() => _LaneState();
}

class _LaneState extends State<_Lane> {
  static const double _height = 90;

  /// The key being dragged, and how far it has moved, held until release so the
  /// whole gesture is one write.
  int? _dragging;
  Offset _delta = Offset.zero;

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final keys = widget.channel.keys;

    return Container(
      height: _height,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.hairline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 3, 6, 0),
            child: Text(widget.channel.label,
                style: t.small.copyWith(color: t.textMuted)),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final view = _View(
                  width: constraints.maxWidth,
                  height: constraints.maxHeight,
                  frames: widget.frames,
                  keys: keys,
                  comp: widget.comp,
                );
                return Stack(
                  children: [
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _CurvePainter(
                          view: view,
                          line: t.accent,
                          grid: t.hairline,
                        ),
                      ),
                    ),
                    for (var i = 0; i < keys.length; i++)
                      _keyHandle(t, view, keys, i),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _keyHandle(
    LumitTheme t,
    _View view,
    List<BridgeKeyframe> keys,
    int index,
  ) {
    final id = '${widget.channel.id}#$index';
    final chosen = widget.selected.contains(id);
    var point = view.pointOf(keys[index]);
    if (_dragging == index) point += _delta;

    return Positioned(
      left: point.dx - 5,
      top: point.dy - 5,
      child: GestureDetector(
        key: ValueKey<String>('graph-key-$id'),
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (chosen) {
            widget.selected.remove(id);
          } else {
            widget.selected.add(id);
          }
          widget.onSelectionChanged();
        },
        onSecondaryTapDown: (d) =>
            _showInterpMenu(context, keys, index, d.globalPosition),
        onPanStart: (_) => setState(() {
          _dragging = index;
          _delta = Offset.zero;
        }),
        onPanUpdate: (d) => setState(() => _delta += d.delta),
        onPanEnd: (_) => _commitDrag(view, keys, index),
        onPanCancel: () => setState(() {
          _dragging = null;
          _delta = Offset.zero;
        }),
        child: SizedBox(
          width: 10,
          height: 10,
          child: CustomPaint(
            painter: _DiamondPainter(chosen ? t.accent : t.textPrimary),
          ),
        ),
      ),
    );
  }

  /// One write for the whole drag: the key's new time *and* its new value.
  void _commitDrag(_View view, List<BridgeKeyframe> keys, int index) {
    final delta = _delta;
    setState(() {
      _dragging = null;
      _delta = Offset.zero;
    });
    if (delta == Offset.zero) return;

    final moved = view.pointOf(keys[index]) + delta;
    final frame = view.frameAt(moved.dx).clamp(0, widget.frames);
    final value = view.valueAt(moved.dy);

    // Two keys cannot share a time, so a key dragged onto its neighbour stops
    // beside it rather than the write being refused.
    final taken = {
      for (var i = 0; i < keys.length; i++)
        if (i != index) widget.comp.frameAtTime(time: keys[i].time),
    };
    if (taken.contains(frame)) return;

    final next = [
      for (var i = 0; i < keys.length; i++)
        if (i == index)
          BridgeKeyframe(
            time: widget.comp.timeOfFrame(frame: frame),
            value: value,
            interpIn: keys[i].interpIn,
            interpOut: keys[i].interpOut,
          )
        else
          keys[i],
    ]..sort((a, b) => widget.comp
        .frameAtTime(time: a.time)
        .compareTo(widget.comp.frameAtTime(time: b.time)));

    widget.channel.write(BridgeScalar.keyframed(next));
    widget.onChanged();
  }

  Future<void> _showInterpMenu(
    BuildContext context,
    List<BridgeKeyframe> keys,
    int index,
    Offset position,
  ) async {
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
                onPressed: () => close('linear'),
                child: const Text('Linear')),
            MenuRow(
                onPressed: () => close('ease'),
                child: const Text('Easy ease')),
            MenuRow(
                onPressed: () => close('hold'), child: const Text('Hold')),
            MenuRow(
                onPressed: () => close('delete'),
                child: const Text('Delete key')),
          ],
        ),
      ),
    );
    if (picked == null) return;

    if (picked == 'delete') {
      final rest = [
        for (var i = 0; i < keys.length; i++)
          if (i != index) keys[i],
      ];
      // A curve with no keys is not a curve the engine can evaluate, so the
      // last one deleted leaves a static value holding what it held.
      widget.channel.write(rest.isEmpty
          ? BridgeScalar.static_(keys[index].value)
          : BridgeScalar.keyframed(rest));
      widget.onChanged();
      return;
    }

    // The AE easy-ease constant: zero speed, one third influence. Set on both
    // sides, which is what the menu entry means.
    const ease = BridgeSideInterp.bezier(
      BridgeBezierSide(speed: 0, influence: 1 / 3),
    );
    final side = switch (picked) {
      'linear' => const BridgeSideInterp.linear(),
      'hold' => const BridgeSideInterp.hold(),
      _ => ease,
    };

    widget.channel.write(BridgeScalar.keyframed([
      for (var i = 0; i < keys.length; i++)
        if (i == index)
          BridgeKeyframe(
            time: keys[i].time,
            value: keys[i].value,
            interpIn: side,
            interpOut: side,
          )
        else
          keys[i],
    ]));
    widget.onChanged();
  }
}

/// The mapping between a lane's pixels and (frame, value).
///
/// The value axis fits the channel's own range with a small margin, so a curve
/// that moves between 40 and 60 fills the lane rather than sitting as a flat
/// line in the middle of a 0..100 scale. A channel whose keys all hold the same
/// value gets an arbitrary unit of range so it draws as a line rather than
/// dividing by zero.
class _View {
  final double width;
  final double height;
  final int frames;
  final List<BridgeKeyframe> keys;
  final CompositionReference comp;

  late final double _low;
  late final double _high;

  _View({
    required this.width,
    required this.height,
    required this.frames,
    required this.keys,
    required this.comp,
  }) {
    final values = keys.map((k) => k.value).toList();
    final low = values.isEmpty ? 0.0 : values.reduce((a, b) => a < b ? a : b);
    final high = values.isEmpty ? 1.0 : values.reduce((a, b) => a > b ? a : b);
    final margin = (high - low).abs() < 1e-9 ? 1.0 : (high - low) * 0.15;
    _low = low - margin;
    _high = high + margin;
  }

  double xOf(int frame) => frames <= 0 ? 0 : frame / frames * width;
  int frameAt(double x) => width <= 0 ? 0 : (x / width * frames).round();

  double yOf(double value) =>
      height - ((value - _low) / (_high - _low)) * height;
  double valueAt(double y) =>
      _low + ((height - y) / height) * (_high - _low);

  Offset pointOf(BridgeKeyframe key) =>
      Offset(xOf(comp.frameAtTime(time: key.time)), yOf(key.value));
}

/// The curve itself, sampled between keys.
///
/// Sampled rather than drawn as beziers because the engine's easing is a
/// speed/influence pair, not a cubic in screen space — the only way to draw
/// exactly what will be rendered is to ask for values. A step per few pixels is
/// plenty for a lane this size.
class _CurvePainter extends CustomPainter {
  final _View view;
  final Color line;
  final Color grid;
  const _CurvePainter({
    required this.view,
    required this.line,
    required this.grid,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final axis = Paint()
      ..color = grid
      ..strokeWidth = 1;
    canvas.drawLine(
        Offset(0, size.height / 2), Offset(size.width, size.height / 2), axis);

    if (view.keys.length < 2) return;

    final path = Path();
    const step = 3.0;
    var first = true;
    for (var x = 0.0; x <= size.width; x += step) {
      final frame = view.frameAt(x);
      final value = sampleScalar(
        scalar: BridgeScalar.keyframed(view.keys),
        time: view.comp.timeOfFrame(frame: frame),
      );
      final point = Offset(x, view.yOf(value));
      if (first) {
        path.moveTo(point.dx, point.dy);
        first = false;
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = line
        ..strokeWidth = 1.4
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_CurvePainter old) => true;
}

/// A keyframe's diamond.
class _DiamondPainter extends CustomPainter {
  final Color colour;
  const _DiamondPainter(this.colour);

  @override
  void paint(Canvas canvas, Size size) {
    final half = size.width / 2;
    canvas.drawPath(
      Path()
        ..moveTo(half, 0)
        ..lineTo(size.width, half)
        ..lineTo(half, size.height)
        ..lineTo(0, half)
        ..close(),
      Paint()..color = colour,
    );
  }

  @override
  bool shouldRepaint(_DiamondPainter old) => old.colour != colour;
}
