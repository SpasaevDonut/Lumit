// The sequence view: a Sequence layer's row, grown tall (K-248).
//
// Double-click a Sequence layer — its name in the outline, or its bar in the
// lanes — and the row opens *in place* rather than swapping the Timeline for
// another tab. Cutting is the reason: you cut against the beat you can see, so
// the music, the other layers and the ruler all have to stay on screen while
// you do it. K-071 originally put this in a tab of its own; K-248 supersedes
// that clause.
//
// **Six rows, three and three.** The clips get three rows' worth of height —
// enough to take hold of, cut, drag along the row and trim by the edges — and
// the speed envelope gets three below them. Everything under the layer moves
// down by the same six rows, which is what makes the view part of the table
// rather than a thing floating over it.
//
// The envelope is the same editor as the graph's Vegas lens, over the same
// keyframes (K-247, K-249): a point per key, its height the playback speed in
// per cent, straight lines between. `Ctrl`-click or double-click the line
// plants a point; `Alt`-click lifts one. A clip that has never been retimed
// draws the flat 100% it is playing at, and the first edit gives it a real map.
//
// Zero bridge calls to draw: every clip and its map ride in on the comp read
// model (K-184). The bridge is crossed only when a gesture commits.

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:lumit_flutter/src/rust/api/effect.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';

import '../theme/theme.dart';
import '../widgets/controls.dart';
import 'graph_maths.dart';
import 'layer_fold_frb.dart';
import 'timeline_extras_frb.dart';

/// One timeline row's height — the unit the whole view is measured in, so it
/// lands on the table's own grid.
const double sequenceRow = 22;

/// Three rows of clips and three of envelope (K-248).
const double sequenceClipStrip = sequenceRow * 3;
const double sequenceEnvelopeStrip = sequenceRow * 3;
const double sequenceViewHeight = sequenceClipStrip + sequenceEnvelopeStrip;

/// How near an edge counts as grabbing it rather than the clip's body.
const double _edgeGrab = 7;

/// A Sequence layer's clips and their speed envelope, under its bar.
class SequenceViewFrb extends StatefulWidget {
  final BridgeLayerEntry entry;
  final TimelineAxis axis;
  final double fps;
  final int fpsNum;
  final int fpsDen;

  /// Committed a gesture; the panel refreshes its read model.
  final VoidCallback onChanged;

  const SequenceViewFrb({
    super.key,
    required this.entry,
    required this.axis,
    required this.fps,
    required this.fpsNum,
    required this.fpsDen,
    required this.onChanged,
  });

  @override
  State<SequenceViewFrb> createState() => _SequenceViewFrbState();
}

class _SequenceViewFrbState extends State<SequenceViewFrb> {
  /// The clip being dragged, what the gesture is doing to it, and how far it
  /// has travelled — so the drag previews and commits once, on release.
  ({BridgeClip clip, _Grab grab, double dx})? _drag;

  /// Where the envelope was last clicked, for spotting a double-click without
  /// putting a recogniser in the way of the single click that selects.
  DateTime? _lastEnvelopeTap;

  List<BridgeClip> get _clips => widget.entry.info.clips;

  double _xOf(int frame) => widget.axis.xOf(frame);

  /// The frames a drag has travelled, snapped to whole frames — the row edits
  /// in frames, like everything else on the timeline.
  int _draggedFrames(double dx) {
    final perFrame = widget.axis.perFrame;
    return perFrame <= 0 ? 0 : (dx / perFrame).round();
  }

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: sequenceClipStrip,
          child: Stack(children: [for (final c in _clips) _clip(t, c)]),
        ),
        SizedBox(
          height: sequenceEnvelopeStrip,
          child: _EnvelopeStrip(
            entry: widget.entry,
            axis: widget.axis,
            fps: widget.fps,
            fpsNum: widget.fpsNum,
            fpsDen: widget.fpsDen,
            onChanged: widget.onChanged,
            onTapped: () {
              final now = DateTime.now();
              final last = _lastEnvelopeTap;
              _lastEnvelopeTap = now;
              return last != null && now.difference(last) < kDoubleTapTimeout;
            },
          ),
        ),
      ],
    );
  }

  /// One clip: a box where it sits, saying how fast it plays. Its body drags
  /// it along the row and its edges trim it.
  Widget _clip(LumitTheme t, BridgeClip clip) {
    final drag = _drag;
    final moving = drag != null && drag.clip.id == clip.id;
    final shift = moving ? _draggedFrames(drag.dx) : 0;
    final start = clip.startFrame.toInt() +
        (moving && drag.grab != _Grab.end ? shift : 0);
    final end = clip.endFrame.toInt() +
        (moving && drag.grab != _Grab.start ? shift : 0);
    final left = _xOf(start);
    final width = (_xOf(end) - left).clamp(2.0, double.infinity);
    final speed = clip.speedPercent;

    return Positioned(
      key: ValueKey<String>('seq-clip-${clip.id}'),
      left: left,
      width: width,
      top: 2,
      bottom: 2,
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeLeftRight,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (d) => setState(() {
            final where = d.localPosition.dx;
            _drag = (
              clip: clip,
              grab: where < _edgeGrab
                  ? _Grab.start
                  : where > width - _edgeGrab
                      ? _Grab.end
                      : _Grab.body,
              dx: 0,
            );
          }),
          onHorizontalDragUpdate: (d) => setState(() {
            final held = _drag;
            if (held != null) {
              _drag = (
                clip: held.clip,
                grab: held.grab,
                dx: held.dx + d.delta.dx,
              );
            }
          }),
          onHorizontalDragEnd: (_) => _commitDrag(),
          onHorizontalDragCancel: () => setState(() => _drag = null),
          child: Container(
            decoration: BoxDecoration(
              color: t.labelColour(widget.entry.info.label),
              border: Border.all(color: t.surface0, width: 1),
              borderRadius: BorderRadius.circular(2),
            ),
            alignment: Alignment.center,
            child: ClipRect(
              child: Text(
                // A ramp has no single number to show, and printing one would
                // be a lie about a curve — the envelope below reads it.
                speed == null ? 'ramp' : '${speed.round()}%',
                style: t.small.copyWith(color: t.textPrimary),
                overflow: TextOverflow.clip,
                softWrap: false,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Write the drag: a body grab slides the clip, an edge grab trims it.
  void _commitDrag() {
    final drag = _drag;
    setState(() => _drag = null);
    if (drag == null) return;
    final shift = _draggedFrames(drag.dx);
    if (shift == 0) return;
    final layer = widget.entry.layer;
    switch (drag.grab) {
      case _Grab.body:
        layer.slideClip(
          clip: drag.clip.id,
          toFrame: drag.clip.startFrame + shift,
        );
      case _Grab.start:
        layer.trimClip(
          clip: drag.clip.id,
          startFrame: drag.clip.startFrame + shift,
          endFrame: drag.clip.endFrame,
        );
      case _Grab.end:
        layer.trimClip(
          clip: drag.clip.id,
          startFrame: drag.clip.startFrame,
          endFrame: drag.clip.endFrame + shift,
        );
    }
    widget.onChanged();
  }
}

/// What a clip drag has hold of.
enum _Grab { body, start, end }

/// The speed envelope: every clip's map drawn as points and straight lines,
/// against an axis that grows to hold whatever the curves reach.
class _EnvelopeStrip extends StatefulWidget {
  final BridgeLayerEntry entry;
  final TimelineAxis axis;
  final double fps;
  final int fpsNum;
  final int fpsDen;
  final VoidCallback onChanged;

  /// Reports a click and answers whether it was the second of a double.
  final bool Function() onTapped;

  const _EnvelopeStrip({
    required this.entry,
    required this.axis,
    required this.fps,
    required this.fpsNum,
    required this.fpsDen,
    required this.onChanged,
    required this.onTapped,
  });

  @override
  State<_EnvelopeStrip> createState() => _EnvelopeStripState();
}

class _EnvelopeStripState extends State<_EnvelopeStrip> {
  /// The point under the pointer while a drag runs: which clip, which key,
  /// and the speed it is being asked for.
  ({BridgeClip clip, int index, double speed})? _drag;

  List<BridgeClip> get _clips => widget.entry.info.clips;

  /// A clip's envelope keys. An un-retimed clip has none of its own, so it is
  /// read as the flat 100% it is actually playing — two implied points, one at
  /// each end — and the first edit writes that out as a real map.
  List<BridgeKeyframe> _keysOf(BridgeClip clip) {
    final map = clip.retime;
    if (map != null) {
      final keys = keysOf(map);
      if (keys.length >= 2) return keys;
    }
    final duration =
        (clip.endFrame - clip.startFrame) / (widget.fps <= 0 ? 1 : widget.fps);
    return [
      BridgeKeyframe(
        time: const BridgeRational(num: 0, den: 1),
        value: 0,
        interpIn: const BridgeSideInterp.linear(),
        interpOut: const BridgeSideInterp.linear(),
      ),
      BridgeKeyframe(
        time: timeOfSubframe(
            duration * widget.fps, widget.fpsNum, widget.fpsDen),
        value: duration,
        interpIn: const BridgeSideInterp.linear(),
        interpOut: const BridgeSideInterp.linear(),
      ),
    ];
  }

  /// The range the strip draws over: the documented default, grown to hold
  /// every point on every clip **and** whatever a drag is currently asking
  /// for — so a point dragged past the floor reframes the axis instead of
  /// running off the strip and over the layers below (K-247).
  (double, double) get _range {
    var (lo, hi) = fitEnvelopeRange([for (final c in _clips) _keysOf(c)]);
    final held = _drag;
    if (held != null) {
      if (held.speed < lo) lo = held.speed;
      if (held.speed > hi) hi = held.speed;
    }
    // Air at both ends, always. K-247's 100%-to-−25% is what the axis has to
    // *contain*, and contained is not the same as touching the edge: without
    // this an un-retimed clip's flat 100% line drew exactly on the strip's top
    // edge, half of it outside its own row.
    const air = 18.0;
    return (lo - air, hi + air);
  }

  double _y(double speed, double height) {
    final (lo, hi) = _range;
    final span = (hi - lo).abs() < 1e-9 ? 1.0 : hi - lo;
    return height - (speed - lo) / span * height;
  }

  double _speedAt(double y, double height) {
    final (lo, hi) = _range;
    final span = (hi - lo).abs() < 1e-9 ? 1.0 : hi - lo;
    return lo + (height - y) / (height <= 0 ? 1 : height) * span;
  }

  /// Where a clip's key sits on the comp's own clock, in x pixels.
  double _xOfKey(BridgeClip clip, BridgeKeyframe key) => widget.axis
      .xOf(clip.startFrame.toInt() + (rationalSeconds(key.time) * widget.fps).round());

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return LayoutBuilder(
      builder: (context, box) {
        final height = box.maxHeight;
        return Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _EnvelopePainter(
                    lanes: [
                      for (final c in _clips)
                        (
                          clip: c,
                          keys: _shown(c),
                        ),
                    ],
                    xOfKey: _xOfKey,
                    y: (s) => _y(s, height),
                    range: _range,
                    line: t.hairline,
                    curve: t.curve.first,
                    label: t.small.copyWith(color: t.textMuted),
                  ),
                ),
              ),
            ),
            // The line itself: click to plant a point, drag one to re-speed.
            Positioned.fill(
              child: GestureDetector(
                key: const ValueKey('seq-envelope'),
                behavior: HitTestBehavior.opaque,
                onTapUp: (d) => _tap(d.localPosition, height),
                onVerticalDragStart: (d) => _startDrag(d.localPosition, height),
                onVerticalDragUpdate: (d) => setState(() {
                  final held = _drag;
                  if (held != null) {
                    _drag = (
                      clip: held.clip,
                      index: held.index,
                      speed: _speedAt(d.localPosition.dy, height),
                    );
                  }
                }),
                onVerticalDragEnd: (_) => _commit(),
                onVerticalDragCancel: () => setState(() => _drag = null),
              ),
            ),
          ],
        );
      },
    );
  }

  /// A clip's keys with the drag in flight applied, so the line follows the
  /// pointer rather than jumping on release.
  List<BridgeKeyframe> _shown(BridgeClip clip) {
    final keys = _keysOf(clip);
    final held = _drag;
    if (held == null || held.clip.id != clip.id) return keys;
    return _withSpeed(clip, keys, held.index, held.speed);
  }

  /// [keys] with the drag applied — one point, or the whole line.
  ///
  /// **A clip nobody has retimed moves as one level.** Its envelope is the two
  /// implied ends of a flat 100%, and dragging one of those alone would tilt
  /// the line into a ramp nobody asked for: the obvious reading of dragging a
  /// flat line is "this clip plays at that speed", which is also what Vegas's
  /// first envelope point does. Plant a point and the line has a shape worth
  /// keeping, so from then on a drag moves only the point it has hold of.
  List<BridgeKeyframe> _withSpeed(
      BridgeClip clip, List<BridgeKeyframe> keys, int index, double speed) {
    if (clip.retime == null) {
      return envelopeToKeys(keys, [for (final _ in keys) speed]);
    }
    return setEnvelopeSpeed(keys, index, speed);
  }

  /// The envelope point [local] means: the nearest one within reach, or —
  /// failing that — the nearest point of whichever clip the pointer is over.
  ///
  /// The fallback is what makes the band usable. A point is a 7px dot on a
  /// 2px line; asking for a direct hit on one would make re-speeding a clip a
  /// test of aim, when the obvious reading of "drag anywhere on this clip's
  /// line" is never ambiguous — a clip's points are its own.
  ({BridgeClip clip, int index})? _nearestPoint(Offset local, double height) {
    ({BridgeClip clip, int index})? best;
    var bestD = 14.0;
    for (final clip in _clips) {
      final keys = _keysOf(clip);
      final speeds = envelopeSpeeds(keys);
      for (var i = 0; i < keys.length; i++) {
        final p = Offset(_xOfKey(clip, keys[i]), _y(speeds[i], height));
        final d = (p - local).distance;
        if (d < bestD) {
          bestD = d;
          best = (clip: clip, index: i);
        }
      }
    }
    if (best != null) return best;

    final over = _clipAt(local.dx);
    if (over == null) return null;
    final keys = _keysOf(over);
    var nearest = 0;
    var nearestD = double.infinity;
    for (var i = 0; i < keys.length; i++) {
      final d = (_xOfKey(over, keys[i]) - local.dx).abs();
      if (d < nearestD) {
        nearestD = d;
        nearest = i;
      }
    }
    return (clip: over, index: nearest);
  }

  /// The clip whose span covers [x] pixels.
  BridgeClip? _clipAt(double x) {
    for (final c in _clips) {
      final left = widget.axis.xOf(c.startFrame.toInt());
      final right = widget.axis.xOf(c.endFrame.toInt());
      if (x >= left && x < right) return c;
    }
    return null;
  }

  void _startDrag(Offset local, double height) {
    final found = _nearestPoint(local, height);
    if (found == null) return;
    setState(() => _drag = (
          clip: found.clip,
          index: found.index,
          speed: envelopeSpeeds(_keysOf(found.clip))[found.index],
        ));
  }

  /// `Ctrl`-click or double-click the line to plant a point; `Alt`-click one
  /// to lift it — the same gestures the graph editor uses, so nothing new has
  /// to be learnt for the strip.
  void _tap(Offset local, double height) {
    final doubled = widget.onTapped();
    final keys = HardwareKeyboard.instance;
    final found = _nearestPoint(local, height);

    if (found != null && keys.isAltPressed) {
      final all = _keysOf(found.clip);
      if (all.length <= 2) return; // never below the two ends
      _write(found.clip, [
        for (var i = 0; i < all.length; i++)
          if (i != found.index) all[i],
      ]);
      return;
    }
    if (!doubled && !keys.isControlPressed) return;

    final clip = _clipAt(local.dx);
    if (clip == null) return;
    final all = _keysOf(clip);
    final at = (widget.axis.frameAt(local.dx) - clip.startFrame) / widget.fps;
    final speeds = envelopeSpeeds(all);
    var index = all.length;
    for (var i = 0; i < all.length; i++) {
      if (at < rationalSeconds(all[i].time)) {
        index = i;
        break;
      }
    }
    if (index == 0 || index == all.length) return; // only between the ends
    final t0 = rationalSeconds(all[index - 1].time);
    final t1 = rationalSeconds(all[index].time);
    final f = t1 > t0 ? (at - t0) / (t1 - t0) : 0.0;
    final planted = speeds[index - 1] + (speeds[index] - speeds[index - 1]) * f;
    final grown = [...all]..insert(
        index,
        BridgeKeyframe(
          time: timeOfSubframe(at * widget.fps, widget.fpsNum, widget.fpsDen),
          value: 0,
          interpIn: const BridgeSideInterp.linear(),
          interpOut: const BridgeSideInterp.linear(),
        ));
    _write(clip, envelopeToKeys(grown, [...speeds]..insert(index, planted)));
  }

  void _commit() {
    final held = _drag;
    setState(() => _drag = null);
    if (held == null) return;
    _write(
      held.clip,
      _withSpeed(held.clip, _keysOf(held.clip), held.index, held.speed),
    );
  }

  void _write(BridgeClip clip, List<BridgeKeyframe> keys) {
    widget.entry.layer.setClipRetime(
      clip: clip.id,
      value: BridgeScalar.keyframed(keys),
    );
    widget.onChanged();
  }
}

/// The envelope's furniture and its lines: the 100% reference every clip is
/// measured against, the zero line that says where backwards begins, and each
/// clip's own straight run of points.
class _EnvelopePainter extends CustomPainter {
  final List<({BridgeClip clip, List<BridgeKeyframe> keys})> lanes;
  final double Function(BridgeClip, BridgeKeyframe) xOfKey;
  final double Function(double) y;
  final (double, double) range;
  final Color line;
  final Color curve;
  final TextStyle label;

  const _EnvelopePainter({
    required this.lanes,
    required this.xOfKey,
    required this.y,
    required this.range,
    required this.line,
    required this.curve,
    required this.label,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (final (speed, text) in [(100.0, '100%'), (0.0, '0')]) {
      final at = y(speed);
      if (at < 0 || at > size.height) continue;
      canvas.drawLine(
        Offset(0, at),
        Offset(size.width, at),
        Paint()
          ..color = line
          ..strokeWidth = 1,
      );
      final painter = TextPainter(
        text: TextSpan(text: text, style: label),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(canvas, Offset(2, at - painter.height));
    }

    final stroke = Paint()
      ..color = curve
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    for (final lane in lanes) {
      final speeds = envelopeSpeeds(lane.keys);
      final points = [
        for (var i = 0; i < lane.keys.length; i++)
          Offset(xOfKey(lane.clip, lane.keys[i]), y(speeds[i])),
      ];
      if (points.length < 2) continue;
      final path = Path()..moveTo(points.first.dx, points.first.dy);
      for (final p in points.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, stroke);
      for (final p in points) {
        canvas.drawCircle(p, 3.5, Paint()..color = curve);
      }
    }
  }

  @override
  bool shouldRepaint(_EnvelopePainter old) =>
      old.lanes != lanes || old.range != range || old.curve != curve;
}
