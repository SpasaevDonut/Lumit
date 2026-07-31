// The Razor tool over the Timeline's lanes (K-218, docs/07 §4.4): the blade
// pointer, the line that shows where the cut lands, and which layers a click
// actually cuts.
//
// **In plain terms.** With the razor in hand the pointer becomes a blade and a
// vertical line follows it across the lanes: that line is where the cut will
// happen. Clicking a layer's bar cuts it *there* — not at the playhead — which
// is the whole difference between a razor and the Cut-at-playhead command.
// Holding Shift cuts every layer that spans that moment at once, the way
// Premiere's razor cuts all tracks.
//
// **Two kinds of cut, because there are two kinds of layer.** A Sequence layer
// holds clips, so cutting it makes an **edit point** inside it and the layer
// stays one layer. Everything else **splits into two layers**, which is what
// After Effects does — both halves keep the source, effects, masks and
// keyframes, and each takes half the span. The engine decides which is which;
// this only asks (`cut_clip_at` or `split_at`).

import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';

/// How long the drawn blade is, in screen pixels.
const double razorCursorSize = 16;

/// The layers a razor click at [frame] should cut.
///
/// [clicked] is the bar under the pointer, or null when the click landed on
/// empty lane space. Plain: only what was clicked. [allLayers] (Shift): every
/// layer whose span contains that moment, whether it was clicked or not —
/// including the clicked one.
///
/// A layer is only a target while the cut would land **strictly inside** it:
/// cutting at an end makes a layer of no length, which the engine refuses
/// anyway, and offering it would make Shift look as though it had done
/// something to layers it had not.
List<BridgeLayerEntry> razorTargets(
  List<BridgeLayerEntry> layers,
  int frame, {
  required BridgeLayerEntry? clicked,
  required bool allLayers,
}) {
  bool spans(BridgeLayerEntry entry) =>
      frame > entry.info.inFrame.toInt() && frame < entry.info.outFrame.toInt();

  if (allLayers) return [for (final entry in layers) if (spans(entry)) entry];
  if (clicked == null || !spans(clicked)) return const [];
  return [clicked];
}

/// Cut every layer in [targets] at [frame], and say whether anything happened.
///
/// A Sequence layer gains an edit point; anything else splits in two. Each is a
/// single op, so each is a single undo step (docs/07 §4.7) — a Shift-cut across
/// five layers is five steps, which is honest: it is five edits.
///
/// A refusal is silence, not an error: the engine declines a clip an eased ramp
/// cannot be cut through, and a razor that threw a dialogue at the user for
/// clicking slightly wrong would be worse than one that does nothing.
bool razorCut(List<BridgeLayerEntry> targets, int frame) {
  var cut = false;
  for (final entry in targets) {
    try {
      if (entry.info.kind == BridgeLayerKind.sequence) {
        entry.layer.cutClipAt(frame: frame);
      } else {
        entry.layer.splitAt(frame: frame);
      }
      cut = true;
    } catch (_) {
      // Nothing cuttable there. The next layer still gets its turn.
    }
  }
  return cut;
}

/// The blade pointer and the cut line, over whatever [child] draws.
///
/// Wrapped round the lanes rather than laid over them as a sibling: the line
/// has to span every row, and the pointer must not be clipped to one bar.
/// Neither takes a gesture — the bars keep their own clicks and drags.
class RazorOverlay extends StatefulWidget {
  /// Whether the Razor tool is armed.
  final bool active;

  /// The pointer's colours: the mark, and the outline that keeps it legible
  /// over a bar of any label colour.
  final Color mark;
  final Color outline;

  final Widget child;

  const RazorOverlay({
    super.key,
    required this.active,
    required this.mark,
    required this.outline,
    required this.child,
  });

  @override
  State<RazorOverlay> createState() => _RazorOverlayState();
}

class _RazorOverlayState extends State<RazorOverlay> {
  Offset? _pointer;

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return widget.child;
    return MouseRegion(
      // Hidden and replaced, for the same reason the Rotation tool's is
      // (K-217): no platform ships a razor, and a system arrow inside the drawn
      // blade would read as two pointers.
      cursor: SystemMouseCursors.none,
      onEnter: (event) => setState(() => _pointer = event.localPosition),
      onHover: (event) => setState(() => _pointer = event.localPosition),
      onExit: (_) => setState(() => _pointer = null),
      child: Stack(
        children: [
          widget.child,
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _RazorCursorPainter(
                  at: _pointer,
                  mark: widget.mark,
                  outline: widget.outline,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The blade, and the line down the lanes that says where the cut lands.
class _RazorCursorPainter extends CustomPainter {
  final Offset? at;
  final Color mark;
  final Color outline;

  const _RazorCursorPainter({
    required this.at,
    required this.mark,
    required this.outline,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final point = at;
    if (point == null) return;

    // The cut line first, so the blade draws over it: full height, at the
    // pointer's time, which is the one thing the user needs to aim.
    canvas.drawLine(
      Offset(point.dx, 0),
      Offset(point.dx, size.height),
      Paint()
        ..color = mark.withValues(alpha: 0.7)
        ..strokeWidth = 1,
    );

    canvas.save();
    canvas.translate(point.dx, point.dy);
    _blade(canvas, outline, 3.2);
    _blade(canvas, mark, 1.4);
    canvas.restore();
  }

  /// A blade on its handle, leaning the way a razor is held: the edge runs down
  /// to the pointer's own position, so what it cuts is where it points.
  void _blade(Canvas canvas, Color colour, double width) {
    final paint = Paint()
      ..color = colour
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    const s = razorCursorSize;
    // The blade: a leaning quadrilateral above and right of the point.
    final blade = Path()
      ..moveTo(0, 0)
      ..lineTo(s * 0.45, -s * 0.75)
      ..lineTo(s * 0.85, -s * 0.45)
      ..lineTo(s * 0.4, s * 0.3)
      ..close();
    canvas.drawPath(blade, paint);
    // The handle, running back up from the blade's top corner.
    canvas.drawLine(
      const Offset(s * 0.45, -s * 0.75),
      const Offset(s * 0.15, -s * 1.15),
      paint,
    );
  }

  @override
  bool shouldRepaint(_RazorCursorPainter old) =>
      old.at != at || old.mark != mark || old.outline != outline;
}
