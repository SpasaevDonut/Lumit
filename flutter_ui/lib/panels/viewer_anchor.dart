// The Anchor point tool — After Effects calls it Pan Behind (K-218,
// docs/07 §1.7): drag a layer's anchor without the picture moving.
//
// **In plain terms.** The anchor point is the spot a layer scales and rotates
// about, and it is also the spot Position places. Move it naively and the layer
// jumps, because the same Position now means somewhere else. This tool moves it
// *and* compensates Position by exactly the amount that cancels the jump — so
// the picture stays where it is and only the pivot slides. That is what "pan
// behind" means, and it is the difference between this tool and typing new
// anchor numbers into Effect controls.
//
// **The two modifiers, both After Effects'.**
// * `Shift` constrains the drag to one axis, so a pivot can be moved straight
//   across a face without drifting up or down.
// * `Ctrl` (`Cmd`) snaps the anchor to the layer's own key points — the four
//   corners, the four edge midpoints, and the centre — which is how a pivot
//   lands *exactly* on a corner rather than nearly on one. The snap is measured
//   in screen pixels, so it is as precise as the magnification allows and no
//   more (docs/07 §4.5's rule for every snap in the application).
//
// The maths is `panBehindPosition` in viewer_layer_map.dart, which the egui
// frontend's anchor overlay used and which is already unit-tested; the snapping
// and the axis lock are pure functions here.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:lumit_flutter/src/rust/api/effect.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';

import '../state/preview_throttle.dart';
import 'viewer_gizmo.dart';
import 'viewer_layer_map.dart';

/// How close, in screen pixels, a snapped anchor has to be to a key point.
const double anchorSnapDistance = 12;

/// The size of the drawn pointer's crosshair, in screen pixels.
const double anchorCursorSize = 9;

/// The layer's own key points, in layer space: the four corners, the four edge
/// midpoints, and the centre — nine places a pivot is usually wanted.
List<Offset> anchorKeyPoints(Size bounds) => [
      for (final y in const [0.0, 0.5, 1.0])
        for (final x in const [0.0, 0.5, 1.0])
          Offset(x * bounds.width, y * bounds.height),
    ];

/// [candidate] (layer space) snapped to the nearest key point within
/// [anchorSnapDistance] **on screen**, or unchanged when none is near.
///
/// Measured on screen rather than in layer pixels on purpose: a layer scaled to
/// 10% would otherwise snap from half a screen away, and one scaled to 1000%
/// would never snap at all. This is the same rule docs/07 §4.5 sets for the
/// Timeline's snapping — the distance a user can see is the distance that
/// counts.
Offset snapAnchor(Offset candidate, LayerBox box) {
  final onScreen = box.map.toScreen(candidate.dx, candidate.dy);
  Offset? best;
  var bestDistance = anchorSnapDistance;
  for (final point in anchorKeyPoints(box.bounds)) {
    final d = (box.map.toScreen(point.dx, point.dy) - onScreen).distance;
    if (d <= bestDistance) {
      bestDistance = d;
      best = point;
    }
  }
  return best ?? candidate;
}

/// [delta] with the smaller of its two components dropped — Shift's axis lock.
///
/// In *screen* space, because the lock is about the gesture the hand is making,
/// not about the layer's own axes: dragging straight across the screen should
/// stay straight across the screen even on a layer that is turned.
Offset constrainToAxis(Offset delta) => delta.dx.abs() >= delta.dy.abs()
    ? Offset(delta.dx, 0)
    : Offset(0, delta.dy);

/// The Anchor point tool over the picture.
class ViewerAnchorLayer extends StatefulWidget {
  /// Whether the tool is armed. Inert otherwise.
  final bool active;

  final CompositionReference comp;
  final LumitUiState uiState;

  /// Every layer with its box, top first.
  final List<LayerBox> boxes;

  final Color mark;
  final Color outline;
  final Color accent;

  final VoidCallback onChanged;

  const ViewerAnchorLayer({
    super.key,
    required this.active,
    required this.comp,
    required this.uiState,
    required this.boxes,
    required this.mark,
    required this.outline,
    required this.accent,
    required this.onChanged,
  });

  @override
  State<ViewerAnchorLayer> createState() => _ViewerAnchorLayerState();
}

class _ViewerAnchorLayerState extends State<ViewerAnchorLayer> {
  Offset? _pointer;

  /// The press, for the same reason every other tool records it (K-215): a drag
  /// is only recognised once the pointer has travelled its slop, and a pivot
  /// that jumped by that much on the first frame of every drag would be
  /// unusable.
  Offset? _downAt;

  /// The layer being panned behind, captured at the press so the maths is
  /// relative to where it started rather than to a document it is changing.
  LayerBox? _acting;

  final PreviewThrottle _throttle = PreviewThrottle();

  @override
  void dispose() {
    _throttle.cancel();
    super.dispose();
  }

  /// The layer this tool acts on: the one under the pointer if it is selected
  /// or nothing is, else the primary selection — the same "what would this
  /// gesture touch?" the Selection tool answers.
  LayerBox? _targetAt(Offset at) {
    final ids = widget.uiState.selectedLayerIds;
    final under = layerAtPoint(widget.boxes, at);
    if (under != null && (ids.isEmpty || ids.contains(under.id))) return under;
    for (final box in widget.boxes) {
      if (ids.contains(box.id)) return box;
    }
    return under;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return const SizedBox.shrink();
    final at = _pointer;
    final target = _acting ?? (at == null ? null : _targetAt(at));
    return Positioned.fill(
      child: MouseRegion(
        cursor: SystemMouseCursors.none,
        onEnter: (event) => setState(() => _pointer = event.localPosition),
        onHover: (event) => setState(() => _pointer = event.localPosition),
        onExit: (_) => setState(() => _pointer = null),
        child: Listener(
          onPointerDown: (event) => _downAt = event.localPosition,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: _onTapUp,
            onPanStart: _onPanStart,
            onPanUpdate: _onPanUpdate,
            onPanEnd: (_) => _onPanEnd(),
            onPanCancel: _onPanEnd,
            child: CustomPaint(
              painter: _AnchorCursorPainter(
                at: at,
                // Where the anchor is going, so the drag shows the pivot moving
                // even though the picture deliberately does not.
                anchor: target == null
                    ? null
                    : _acting != null && at != null
                        ? target.map.toScreen(
                            _wantedAnchor(target, at).dx,
                            _wantedAnchor(target, at).dy,
                          )
                        : target.anchorScreen,
                mark: widget.mark,
                outline: widget.outline,
                accent: widget.accent,
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _onTapUp(TapUpDetails details) {
    final hit = layerAtPoint(widget.boxes, details.localPosition);
    if (hit == null) {
      widget.uiState.clearSelection();
      return;
    }
    if (HardwareKeyboard.instance.isShiftPressed) {
      widget.uiState.toggleSelected(hit.layer);
    } else {
      widget.uiState.setSelection([hit.layer]);
    }
  }

  void _onPanStart(DragStartDetails details) {
    final at = _downAt ?? details.localPosition;
    final target = _targetAt(at);
    // Dragging a layer's pivot is working on that layer, so it becomes the
    // selection — the same rule the Selection tool's body drag follows.
    if (target != null &&
        !widget.uiState.selectedLayerIds.contains(target.id)) {
      widget.uiState.setSelection([target.layer]);
    }
    setState(() {
      _acting = target;
      _pointer = details.localPosition;
    });
  }

  /// Where the anchor should sit, in layer space, for the pointer at [at].
  ///
  /// The drag is measured from the press to the pointer and applied to the
  /// anchor the layer started with, rather than the pointer's own position
  /// being taken as the anchor: grabbing anywhere and *nudging* is what a
  /// pan-behind drag is, and it lets a pivot be moved a few pixels without the
  /// pointer having to be exactly on it.
  Offset _wantedAnchor(LayerBox box, Offset at) {
    var delta = at - (_downAt ?? at);
    if (HardwareKeyboard.instance.isShiftPressed) {
      delta = constrainToAxis(delta);
    }
    final started = box.map.toScreen(box.map.ax, box.map.ay);
    final wanted = box.map.layerOf(started + delta);
    return _isPrimaryModifierHeld ? snapAnchor(wanted, box) : wanted;
  }

  /// Ctrl (Cmd on a Mac): the snap modifier, spelled the way the keymap spells
  /// its primary modifier (state/keymap.dart).
  bool get _isPrimaryModifierHeld =>
      defaultTargetPlatform == TargetPlatform.macOS
          ? HardwareKeyboard.instance.isMetaPressed
          : HardwareKeyboard.instance.isControlPressed;

  void _onPanUpdate(DragUpdateDetails details) {
    setState(() => _pointer = details.localPosition);
    final box = _acting;
    final at = _pointer;
    if (box == null || at == null) return;
    final anchor = _wantedAnchor(box, at);
    final position = _panBehind(box, anchor);
    _throttle.request(() {
      try {
        final tf = box.layer.getTransform();
        widget.comp.renderFrameWithTransformPreview(
          frame: BigInt.from(widget.uiState.playheadFrame.value),
          scale: widget.uiState.viewerScale,
          layer: box.layer,
          transform: BridgeTransform(
            anchorX: BridgeScalar.static_(anchor.dx),
            anchorY: BridgeScalar.static_(anchor.dy),
            positionX: BridgeScalar.static_(position.dx),
            positionY: BridgeScalar.static_(position.dy),
            positionZ: tf.positionZ,
            scaleX: tf.scaleX,
            scaleY: tf.scaleY,
            rotation: tf.rotation,
            rotationX: tf.rotationX,
            rotationY: tf.rotationY,
            opacity: tf.opacity,
          ),
        );
      } catch (_) {
        // A preview is a courtesy (K-215); the commit still lands.
      }
    });
  }

  /// The Position that keeps the picture still while the anchor moves to
  /// [anchor] — the pan-behind compensation, ported maths, unit-tested in
  /// viewer_layer_map.dart.
  Offset _panBehind(LayerBox box, Offset anchor) => panBehindPosition(
        oldAnchor: Offset(box.map.ax, box.map.ay),
        newAnchor: anchor,
        position: Offset(box.map.px, box.map.py),
        scaleXPercent: box.map.sx * 100,
        scaleYPercent: box.map.sy * 100,
        rotationDegrees: box.rotationDegrees,
      );

  void _onPanEnd() {
    final box = _acting;
    final at = _pointer;
    _throttle.cancel();
    if (box != null && at != null && at != _downAt) {
      final anchor = _wantedAnchor(box, at);
      final position = _panBehind(box, anchor);
      try {
        // One op for all four properties, so one drag is one undo step: the
        // anchor and the position are only meaningful together here — half of
        // this edit would move the picture, which is the one thing pan-behind
        // promises not to do.
        box.layer.setTransforms(
          props: const [
            BridgeTransformProp.anchorX,
            BridgeTransformProp.anchorY,
            BridgeTransformProp.positionX,
            BridgeTransformProp.positionY,
          ],
          values: [
            BridgeScalar.static_(anchor.dx),
            BridgeScalar.static_(anchor.dy),
            BridgeScalar.static_(position.dx),
            BridgeScalar.static_(position.dy),
          ],
        );
        widget.onChanged();
      } catch (_) {
        // The layer went away mid-drag.
      }
    }
    setState(() {
      _acting = null;
      _downAt = null;
    });
  }
}

/// The pan-behind pointer: the anchor mark itself, with a small arrow at its
/// tail — After Effects' own pairing, and it says exactly what the tool moves.
///
/// The mark at the *pointer* is the cursor; the ring drawn at the layer's anchor
/// is where that pivot actually is, which is the thing being aimed.
class _AnchorCursorPainter extends CustomPainter {
  final Offset? at;
  final Offset? anchor;
  final Color mark;
  final Color outline;
  final Color accent;

  const _AnchorCursorPainter({
    required this.at,
    required this.anchor,
    required this.mark,
    required this.outline,
    required this.accent,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final pivot = anchor;
    if (pivot != null) {
      final paint = Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1;
      canvas.drawCircle(pivot, 4, paint);
      canvas.drawLine(
          pivot - const Offset(9, 0), pivot + const Offset(9, 0), paint);
      canvas.drawLine(
          pivot - const Offset(0, 9), pivot + const Offset(0, 9), paint);
    }

    final point = at;
    if (point == null) return;
    canvas.save();
    canvas.translate(point.dx, point.dy);
    _cursor(canvas, outline, 3.2);
    _cursor(canvas, mark, 1.4);
    canvas.restore();
  }

  void _cursor(Canvas canvas, Color colour, double width) {
    final paint = Paint()
      ..color = colour
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    // The crosshair-in-a-ring: the anchor's own mark, so the pointer and the
    // thing it moves are plainly the same idea.
    const r = anchorCursorSize / 2;
    canvas.drawCircle(Offset.zero, r, paint);
    canvas.drawLine(const Offset(-r * 1.9, 0), const Offset(r * 1.9, 0), paint);
    canvas.drawLine(const Offset(0, -r * 1.9), const Offset(0, r * 1.9), paint);
    // The little arrow at the tail, down and right, so the mark reads as a
    // pointer rather than as an overlay that happens to sit under the mouse.
    final arrow = Path()
      ..moveTo(r * 1.4, r * 1.4)
      ..lineTo(r * 3.2, r * 3.2)
      ..moveTo(r * 3.2, r * 3.2)
      ..lineTo(r * 3.2, r * 1.9)
      ..moveTo(r * 3.2, r * 3.2)
      ..lineTo(r * 1.9, r * 3.2);
    canvas.drawPath(arrow, paint);
  }

  @override
  bool shouldRepaint(_AnchorCursorPainter old) =>
      old.at != at ||
      old.anchor != anchor ||
      old.mark != mark ||
      old.outline != outline ||
      old.accent != accent;
}

/// Straight-line distance, for the tests' convenience.
@visibleForTesting
double distanceBetween(Offset a, Offset b) =>
    math.sqrt(math.pow(a.dx - b.dx, 2) + math.pow(a.dy - b.dy, 2));
