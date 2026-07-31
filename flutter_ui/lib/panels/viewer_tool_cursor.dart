// The drawn pointers the drawing and painting tools wear over the picture
// (K-224, docs/07 §2.3.3).
//
// **In plain terms.** A tool should say what it is without you looking away
// from the picture, and no operating system ships a "rectangle tool" pointer.
// So the tools that draw wear the same crosshair the eyedropper does — the
// pointer that means *this exact pixel* — with the tool's own icon tucked just
// down and to the right of it, the way After Effects badges its pointers. The
// crosshair is where the shape starts; the badge only says which shape.
//
// **The painting tools are different, and rightly.** A brush is not a point,
// it is a *width*, so its pointer is a circle the size of the stroke it would
// leave — the one thing a painter needs to see before pressing. The badge under
// it says brush, clone stamp or eraser.
//
// **Why they are drawn and not chosen.** A system cursor is a small fixed
// picture from a list the platform ships, and none of these are on it. Drawing
// them means hiding the system pointer over the picture and painting our own —
// the same thing the Rotation, Anchor point and Razor tools already do.
//
// Everything here is a widget, not a canvas: the icons are the application's
// own [lumitIcon] set, and drawing one on a canvas would mean a second copy of
// every glyph.

import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/state/tools.dart';

import '../icons/icons.dart';
import '../widgets/controls.dart';

/// How far the tool's badge sits from the pointer, and how big it is drawn.
///
/// Down and to the right, out of the way of what is being drawn: a badge above
/// or to the left would sit on the shape the user is dragging out.
const Offset toolBadgeOffset = Offset(7, 7);
const double toolBadgeSize = 13;

/// How long each arm of the drawn crosshair is, in screen pixels.
const double toolCrosshairReach = 8;

/// The smallest and largest a brush ring is drawn at, whatever the width says.
///
/// A one-pixel brush would otherwise have an invisible pointer, and a very wide
/// one would fill the picture — the ring is a pointer, not the stroke itself.
const double minBrushRingRadius = 3;
const double maxBrushRingRadius = 200;

/// The drawn pointer for a tool that draws: a crosshair, or a brush ring, with
/// the tool's icon badged beside it.
///
/// [at] is in the same coordinates as the layer this is placed in — panel-local
/// for every caller here. A null [at] draws nothing, which is what a pointer
/// that has left the picture should do.
class ToolPointer extends StatelessWidget {
  final Offset? at;
  final ToolMode tool;

  /// The ink and the halo behind it, so the pointer is legible on a white
  /// picture and on a black one alike.
  final Color mark;
  final Color outline;

  /// The radius of the ring, for the painting tools. Null draws a crosshair.
  final double? ringRadius;

  const ToolPointer({
    super.key,
    required this.at,
    required this.tool,
    required this.mark,
    required this.outline,
    this.ringRadius,
  });

  @override
  Widget build(BuildContext context) {
    final at = this.at;
    if (at == null) return const SizedBox.shrink();
    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _ToolPointerPainter(
                  at: at,
                  mark: mark,
                  outline: outline,
                  ringRadius: ringRadius,
                ),
              ),
            ),
            Positioned(
              left: at.dx + toolBadgeOffset.dx,
              top: at.dy + toolBadgeOffset.dy,
              // The icon twice: the halo copy a pixel down and across, then the
              // ink one over it. Cheaper than an outlined glyph and legible on
              // any picture, which is the whole requirement.
              child: Stack(
                children: [
                  Transform.translate(
                    offset: const Offset(1, 1),
                    child: lumitIcon(tool.icon,
                        size: toolBadgeSize, color: outline),
                  ),
                  lumitIcon(tool.icon, size: toolBadgeSize, color: mark),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolPointerPainter extends CustomPainter {
  final Offset at;
  final Color mark;
  final Color outline;
  final double? ringRadius;

  const _ToolPointerPainter({
    required this.at,
    required this.mark,
    required this.outline,
    required this.ringRadius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final halo = Paint()
      ..color = outline
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    final ink = Paint()
      ..color = mark
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    final radius = ringRadius;
    if (radius != null) {
      for (final paint in [halo, ink]) {
        canvas.drawCircle(at, radius, paint);
      }
      // A dot at the centre: a wide ring alone leaves the actual point of the
      // brush unmarked, and a stroke starts at a point.
      canvas.drawCircle(at, 1, Paint()..color = mark);
      return;
    }

    for (final paint in [halo, ink]) {
      canvas.drawLine(at - const Offset(toolCrosshairReach, 0),
          at + const Offset(toolCrosshairReach, 0), paint);
      canvas.drawLine(at - const Offset(0, toolCrosshairReach),
          at + const Offset(0, toolCrosshairReach), paint);
    }
  }

  @override
  bool shouldRepaint(_ToolPointerPainter old) =>
      old.at != at ||
      old.mark != mark ||
      old.outline != outline ||
      old.ringRadius != ringRadius;
}

/// The ring a brush of [width] layer pixels draws at this magnification, kept
/// within sight either way.
double brushRingRadius(double width, double viewScale) =>
    (width * viewScale / 2).clamp(minBrushRingRadius, maxBrushRingRadius);

/// The text pointer, for the Type tool's vertical member (K-224).
///
/// Horizontal type wears the system's own I-beam — every platform has one and
/// it is the pointer everybody already reads as "you can type here". Nobody
/// ships a *sideways* one, so vertical type gets this: the same beam, turned a
/// quarter turn, so the pointer says which way the line will run.
class TextPointer extends StatelessWidget {
  final Offset? at;
  final Color mark;
  final Color outline;

  const TextPointer({
    super.key,
    required this.at,
    required this.mark,
    required this.outline,
  });

  @override
  Widget build(BuildContext context) {
    final at = this.at;
    if (at == null) return const SizedBox.shrink();
    return Positioned.fill(
      child: IgnorePointer(
        child: CustomPaint(
          painter: _BeamPainter(at: at, mark: mark, outline: outline),
        ),
      ),
    );
  }
}

/// An I-beam lying on its side: the bar runs across, its serifs stand up.
class _BeamPainter extends CustomPainter {
  final Offset at;
  final Color mark;
  final Color outline;

  const _BeamPainter(
      {required this.at, required this.mark, required this.outline});

  @override
  void paint(Canvas canvas, Size size) {
    const reach = 7.0;
    const serif = 3.0;
    for (final (colour, width) in [(outline, 3.0), (mark, 1.0)]) {
      final paint = Paint()
        ..color = colour
        ..style = PaintingStyle.stroke
        ..strokeWidth = width;
      canvas.drawLine(
          at - const Offset(reach, 0), at + const Offset(reach, 0), paint);
      for (final end in [-reach, reach]) {
        canvas.drawLine(
          at + Offset(end, -serif),
          at + Offset(end, serif),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_BeamPainter old) =>
      old.at != at || old.mark != mark || old.outline != outline;
}

/// The painting tools over the picture: their pointers, and the notice that
/// says why nothing happens (K-224).
///
/// **Nothing is painted.** The engine has no paint: no stroke in the document,
/// no operation to add one, no renderer path to draw one — a feature the size of
/// shape layers (docs/TODO.md). What this layer does is wear the right pointer
/// for the tool in hand, so the toolbar's three painting tools are visibly
/// distinct, and say what is missing rather than swallowing the press.
class ViewerPaintPointerLayer extends StatefulWidget {
  final bool active;
  final ToolMode tool;
  final LumitState state;
  final LumitUiState uiState;

  /// The picture's magnification, so a brush width in picture pixels draws the
  /// ring it would really leave.
  final double viewScale;

  const ViewerPaintPointerLayer({
    super.key,
    required this.active,
    required this.tool,
    required this.state,
    required this.uiState,
    required this.viewScale,
  });

  @override
  State<ViewerPaintPointerLayer> createState() =>
      _ViewerPaintPointerLayerState();
}

class _ViewerPaintPointerLayerState extends State<ViewerPaintPointerLayer> {
  Offset? _pointer;

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return const SizedBox.shrink();
    final t = ThemeScope.of(context).theme;
    return Positioned.fill(
      child: MouseRegion(
        // Hidden, because the ring below replaces it: a system arrow inside the
        // brush ring would read as two pointers.
        cursor: SystemMouseCursors.none,
        onEnter: (e) => setState(() => _pointer = e.localPosition),
        onHover: (e) => setState(() => _pointer = e.localPosition),
        onExit: (_) => setState(() => _pointer = null),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (_) => widget.state.postNotice(
            '${widget.tool.label} is not built yet — the engine has no paint '
            'strokes',
          ),
          child: Stack(
            children: [
              const Positioned.fill(child: SizedBox.expand()),
              ToolPointer(
                at: _pointer,
                tool: widget.tool,
                mark: t.textPrimary,
                outline: t.surface0,
                ringRadius: brushRingRadius(
                  widget.uiState.tools.strokeWidth,
                  widget.viewScale,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
