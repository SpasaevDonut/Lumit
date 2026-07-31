// The drawn pointers the drawing and painting tools wear over the picture
// (K-226, docs/07 §2.3.3).
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
import 'package:lumit_flutter/state/tools.dart';

import '../icons/icons.dart';

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
///
/// The painting tools are disabled on this branch (K-228) — the engine has no
/// paint strokes — so nothing calls this yet; it is the pointer they wear the
/// moment they do, and it is tested so it will be right when they arrive.
double brushRingRadius(double width, double viewScale) =>
    (width * viewScale / 2).clamp(minBrushRingRadius, maxBrushRingRadius);

/// The Hand tool's pointer: an open hand, and a closed one while it drags
/// (K-230).
///
/// **Why this is drawn.** Flutter can only ask for the pointers the platform
/// ships, and Windows ships no hand-with-fingers at all — `grab` and `grabbing`
/// are in Flutter's own list but not in the Windows embedder's, where anything
/// unknown quietly becomes the ordinary arrow. That is what the Hand tool was
/// showing: nothing. Drawing it is the only way to have it, and it buys the
/// closing hand as well, which is the half that says the pan has hold of the
/// picture.
class HandPointer extends StatelessWidget {
  final Offset? at;

  /// Whether the hand is holding: a drag in flight.
  final bool holding;
  final Color mark;
  final Color outline;

  const HandPointer({
    super.key,
    required this.at,
    required this.holding,
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
          painter: _HandPainter(
            at: at,
            holding: holding,
            mark: mark,
            outline: outline,
          ),
        ),
      ),
    );
  }
}

/// The hand itself, on a 24-unit grid centred on the pointer.
///
/// Two passes as every drawn pointer here does — a thick outline stroke, then
/// the mark over it — so it is legible over a black picture and a white one.
class _HandPainter extends CustomPainter {
  final Offset at;
  final bool holding;
  final Color mark;
  final Color outline;

  const _HandPainter({
    required this.at,
    required this.holding,
    required this.mark,
    required this.outline,
  });

  /// How tall the drawn hand is, in screen pixels.
  static const double _size = 20;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(at.dx, at.dy);
    final s = _size / 24;
    canvas.scale(s, s);
    // The palm's middle sits on the pointer, which is where a hand grips.
    canvas.translate(-12, -12);
    final path = holding ? _fist() : _openHand();
    canvas.drawPath(
      path,
      Paint()
        ..color = outline
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.5
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawPath(path, Paint()..color = mark);
    canvas.restore();
  }

  /// An open hand: palm, four fingers standing, thumb out to the left.
  Path _openHand() => Path()
    ..moveTo(6, 14)
    ..lineTo(6, 9)
    ..lineTo(8, 9)
    ..lineTo(8, 4)
    ..lineTo(10, 4)
    ..lineTo(10, 9)
    ..lineTo(12, 9)
    ..lineTo(12, 3)
    ..lineTo(14, 3)
    ..lineTo(14, 9)
    ..lineTo(16, 9)
    ..lineTo(16, 5)
    ..lineTo(18, 5)
    ..lineTo(18, 15)
    ..cubicTo(18, 19, 15, 21, 12, 21)
    ..cubicTo(9, 21, 6, 19, 6, 15)
    ..close();

  /// The same hand closed: the fingers curled down onto the palm, with the
  /// knuckles as the line across the top.
  Path _fist() => Path()
    ..moveTo(6, 13)
    ..cubicTo(6, 10, 8, 9, 10, 9)
    ..lineTo(16, 9)
    ..cubicTo(17, 9, 18, 10, 18, 11)
    ..lineTo(18, 15)
    ..cubicTo(18, 19, 15, 21, 12, 21)
    ..cubicTo(9, 21, 6, 19, 6, 15)
    ..close();

  @override
  bool shouldRepaint(_HandPainter old) =>
      old.at != at ||
      old.holding != holding ||
      old.mark != mark ||
      old.outline != outline;
}

/// The Hand tool over the picture: the drawn hand, and the drag that pans.
///
/// It takes the drag itself rather than letting it fall through to the panel,
/// for one reason: a `MouseRegion` stops reporting the pointer the moment a
/// button goes down, and a hand that freezes where you pressed is worse than no
/// hand at all. Owning the gesture means the pointer's position keeps arriving
/// for as long as the pan lasts.
class ViewerHandLayer extends StatefulWidget {
  /// Whether the Hand tool is armed. Inert otherwise — no pointer taken, no
  /// system cursor hidden.
  final bool active;

  /// How far the picture should move, per pointer movement.
  final ValueChanged<Offset> onPan;

  final Color mark;
  final Color outline;

  const ViewerHandLayer({
    super.key,
    required this.active,
    required this.onPan,
    required this.mark,
    required this.outline,
  });

  @override
  State<ViewerHandLayer> createState() => _ViewerHandLayerState();
}

class _ViewerHandLayerState extends State<ViewerHandLayer> {
  Offset? _pointer;
  bool _holding = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return const SizedBox.shrink();
    return Positioned.fill(
      child: MouseRegion(
        // Hidden, because the hand below replaces it: an arrow sitting inside
        // the drawn hand would read as two pointers (K-219's rule).
        cursor: SystemMouseCursors.none,
        onEnter: (e) => setState(() => _pointer = e.localPosition),
        onHover: (e) => setState(() => _pointer = e.localPosition),
        onExit: (_) => setState(() => _pointer = null),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (d) => setState(() {
            _holding = true;
            _pointer = d.localPosition;
          }),
          onPanUpdate: (d) {
            setState(() => _pointer = d.localPosition);
            widget.onPan(d.delta);
          },
          onPanEnd: (_) => setState(() => _holding = false),
          onPanCancel: () => setState(() => _holding = false),
          child: Stack(children: [
            const Positioned.fill(child: SizedBox.expand()),
            HandPointer(
              at: _pointer,
              holding: _holding,
              mark: widget.mark,
              outline: widget.outline,
            ),
          ]),
        ),
      ),
    );
  }
}

/// The Zoom tool's pointer: a magnifier with a plus in it, or a minus while Alt
/// says the click will zoom out (K-230).
///
/// Drawn for the same reason the hand is: Flutter's `zoomIn`/`zoomOut` are not
/// in the Windows embedder's list of pointers, so asking for one got the plain
/// arrow — a Zoom tool that looked exactly like no tool at all.
class MagnifierPointer extends StatelessWidget {
  final Offset? at;

  /// Whether the click would zoom out (the Alt modifier).
  final bool out;
  final Color mark;
  final Color outline;

  const MagnifierPointer({
    super.key,
    required this.at,
    required this.out,
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
          painter: _MagnifierPainter(
            at: at,
            out: out,
            mark: mark,
            outline: outline,
          ),
        ),
      ),
    );
  }
}

class _MagnifierPainter extends CustomPainter {
  final Offset at;
  final bool out;
  final Color mark;
  final Color outline;

  const _MagnifierPainter({
    required this.at,
    required this.out,
    required this.mark,
    required this.outline,
  });

  /// The lens' radius in screen pixels, and how far the handle runs past it.
  static const double _lens = 6.5;
  static const double _handle = 7;

  @override
  void paint(Canvas canvas, Size size) {
    // The lens sits *on* the pointer: what a magnification is anchored to is
    // the point in the middle of the glass, and that has to be the point the
    // pointer claims (docs/07 §2.2 — the comp point under the cursor stays
    // under the cursor).
    canvas.save();
    canvas.translate(at.dx, at.dy);
    const grip = 0.7071 * _lens;
    for (final (colour, width) in [(outline, 3.4), (mark, 1.6)]) {
      final paint = Paint()
        ..color = colour
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round;
      canvas.drawCircle(Offset.zero, _lens, paint);
      canvas.drawLine(
        const Offset(grip, grip),
        const Offset(grip + _handle * 0.7071, grip + _handle * 0.7071),
        paint,
      );
      // The sign inside the glass: plus in, minus out. The bar across is drawn
      // for both, so the two pointers differ by one stroke and read as one
      // family.
      const arm = 3.0;
      canvas.drawLine(const Offset(-arm, 0), const Offset(arm, 0), paint);
      if (!out) {
        canvas.drawLine(const Offset(0, -arm), const Offset(0, arm), paint);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MagnifierPainter old) =>
      old.at != at ||
      old.out != out ||
      old.mark != mark ||
      old.outline != outline;
}

/// The text pointer, for the Type tool's vertical member (K-226).
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
