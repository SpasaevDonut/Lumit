// The Zoom tool, and the arithmetic every zoom in the Viewer goes through
// (K-218, docs/07 §2.2).
//
// **In plain terms.** There are three ways to change the magnification: the
// wheel, a click with the Zoom tool, and dragging a box with it. All three ask
// the same question — "what magnification and what pan put *this* where I want
// it?" — so all three go through the two functions at the top of this file. A
// click keeps the point under the pointer where it is and doubles (or halves)
// the magnification about it; a box says "make this rectangle the view", which
// is a magnification *and* a re-centring; the wheel is a click with a smaller
// step.
//
// The maths is pure and unit-tested. [ViewerZoomLayer] below only listens for
// the gestures and draws the box while it is being dragged — it changes nothing
// itself, it says what was asked for and the panel applies it.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'viewer_tool_cursor.dart';

/// The magnification a Viewer can be taken to. Below the floor the picture is
/// a speck; above the ceiling a comp pixel is a tile and every further step
/// costs texture memory for nothing.
const double minViewerZoom = 0.02;
const double maxViewerZoom = 32.0;

/// How much one click of the Zoom tool changes the magnification. Doubling is
/// After Effects' step and the one the magnification menu's own list walks.
const double zoomToolStep = 2.0;

/// A magnification and the pan that goes with it — the pair the Viewer holds,
/// and the answer every function here returns.
typedef ViewerZoom = ({double scale, Offset pan});

/// Where the picture's top-left would sit for magnification [scale] with no
/// pan at all: the centred position, which is what [ViewerZoom.pan] is measured
/// from.
Offset _centredTopLeft(double scale, Size compSize, Size panel) => Offset(
      (panel.width - compSize.width * scale) / 2,
      (panel.height - compSize.height * scale) / 2,
    );

/// Zoom by [factor] about [cursor], keeping the comp point under the cursor
/// under the cursor.
///
/// The whole trick, and the reason zooming feels like leaning in rather than
/// teleporting: find which comp point `u` is under the pointer now, then solve
/// the pan that puts `u` back under the pointer at the new magnification.
/// [factor] above 1 zooms in, below 1 zooms out.
ViewerZoom zoomAboutPoint({
  required Offset cursor,
  required double factor,
  required Rect fitted,
  required Size compSize,
  required Size panel,
}) {
  final s1 = compSize.width == 0 ? 1.0 : fitted.width / compSize.width;
  final s2 = (s1 * factor).clamp(minViewerZoom, maxViewerZoom).toDouble();
  final u = (cursor - fitted.topLeft) / s1;
  final topLeft = cursor - u * s2;
  return (scale: s2, pan: topLeft - _centredTopLeft(s2, compSize, panel));
}

/// Make [box] — a rectangle the user dragged on screen — the view.
///
/// Zooming *in* fits the box to the panel: the magnification grows by whichever
/// of the two axes is the tighter fit, so everything inside the box stays
/// inside the panel, and the box's middle lands in the panel's middle. Zooming
/// out is the exact inverse — the panel's whole view is shrunk into the box's
/// footprint, still centred on it — which is what makes Alt+drag undo a drag
/// you have just done rather than being a differently-sized guess.
ViewerZoom zoomToBox({
  required Rect box,
  required bool out,
  required Rect fitted,
  required Size compSize,
  required Size panel,
}) {
  final s1 = compSize.width == 0 ? 1.0 : fitted.width / compSize.width;
  // A box with no area (a click that wandered a pixel) would divide by zero;
  // the caller filters those, and this is the belt to that pair of braces.
  final width = box.width.abs() < 1 ? 1.0 : box.width.abs();
  final height = box.height.abs() < 1 ? 1.0 : box.height.abs();
  var factor = panel.width / width < panel.height / height
      ? panel.width / width
      : panel.height / height;
  if (out) factor = 1 / factor;
  final s2 = (s1 * factor).clamp(minViewerZoom, maxViewerZoom).toDouble();
  // The comp point in the middle of the box goes to the middle of the panel.
  final u = (box.center - fitted.topLeft) / s1;
  final topLeft = Offset(panel.width / 2, panel.height / 2) - u * s2;
  return (scale: s2, pan: topLeft - _centredTopLeft(s2, compSize, panel));
}

/// The Zoom tool over the picture: the cursor, the click, and the box.
class ViewerZoomLayer extends StatefulWidget {
  /// Whether the Zoom tool is armed. When it is not, this is inert and lets
  /// every pointer through to whatever is under it.
  final bool active;

  /// A click: zoom about [at], out when [out] (the Alt modifier).
  final void Function(Offset at, {required bool out}) onZoomAt;

  /// A released box: make that rectangle the view, or its inverse when [out].
  final void Function(Rect box, {required bool out}) onZoomBox;

  final Color accent;

  /// The drawn pointer's own colours (K-230).
  final Color mark;
  final Color outline;

  const ViewerZoomLayer({
    super.key,
    required this.active,
    required this.onZoomAt,
    required this.onZoomBox,
    required this.accent,
    required this.mark,
    required this.outline,
  });

  @override
  State<ViewerZoomLayer> createState() => _ViewerZoomLayerState();
}

class _ViewerZoomLayerState extends State<ViewerZoomLayer> {
  Offset? _from;
  Offset? _to;

  /// Where the pointer is, for the drawn magnifier. Null when it is not over
  /// the picture, which is where a drawn pointer should draw nothing.
  Offset? _pointer;

  /// The mouse the pointer events are coming from, so the hidden cursor can be
  /// asked for again for that same device — see [_hideSystemCursorAgain].
  int? _device;

  /// Whether Alt is held, tracked rather than read at the moment of the click.
  ///
  /// The cursor has to say which way the click will go *before* it is clicked —
  /// that is the whole job of a zoom-in and a zoom-out pointer — so pressing or
  /// releasing Alt has to repaint. A keyboard handler is the only way to hear
  /// about a modifier changing while nothing else is happening.
  bool _alt = false;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    final held = HardwareKeyboard.instance.isAltPressed;
    if (held != _alt && mounted) {
      setState(() => _alt = held);
      _hideSystemCursorAgain();
    }
    // Never consumed: Alt is a modifier here, not a shortcut.
    return false;
  }

  /// Ask the platform to hide the pointer again (K-235).
  ///
  /// Alt is the key Windows reserves for the window menu, and pressing it takes
  /// the pointer's own state with it: the arrow comes back and sits beside our
  /// drawn magnifier, which is two pointers — exactly what hiding the system
  /// one is for. Flutter will not re-apply a cursor by itself here, because it
  /// only does so when the answer *changes*, and "hidden" to "hidden" is no
  /// change at all.
  ///
  /// So the same request Flutter's own cursor manager makes is made directly,
  /// for the device the pointer events are arriving from. Nothing in the widget
  /// tree moves — an earlier attempt gave the region a new identity to force
  /// the question, which rebuilt the gesture detector under it and dropped any
  /// drag that was in flight.
  void _hideSystemCursorAgain() {
    final device = _device;
    if (device == null || _pointer == null) return;
    SystemChannels.mouseCursor.invokeMethod<void>(
      'activateSystemCursor',
      <String, dynamic>{'device': device, 'kind': 'none'},
    );
  }

  Rect? get _box {
    final from = _from;
    final to = _to;
    if (from == null || to == null) return null;
    return Rect.fromPoints(from, to);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return const SizedBox.shrink();
    return Positioned.fill(
      // The system pointer is hidden and replaced below (K-230): `zoomIn` and
      // `zoomOut` are in Flutter's list of pointers but not in the Windows
      // embedder's, where an unknown one silently becomes the ordinary arrow —
      // so the Zoom tool looked like no tool at all. A drawn magnifier is the
      // only one there is.
      child: DrawnPointerRegion(
        onPointer: (at) => setState(() => _pointer = at),
        child: Listener(
          // Which mouse is being used, for the cursor request above. A Listener
          // rather than a wider change: it consumes nothing and takes no
          // gesture away from the detector under it.
          onPointerHover: (event) => _device = event.device,
          onPointerMove: (event) => _device = event.device,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (details) => widget.onZoomAt(details.localPosition,
                out: HardwareKeyboard.instance.isAltPressed),
            onPanStart: (details) => setState(() {
              _from = details.localPosition;
              _to = details.localPosition;
              _pointer = details.localPosition;
            }),
            onPanUpdate: (details) => setState(() {
              _to = details.localPosition;
              _pointer = details.localPosition;
            }),
            onPanEnd: (_) {
              final box = _box;
              setState(() {
                _from = null;
                _to = null;
              });
              // A drag of a few pixels is a click that wobbled: zooming to a
              // 3-pixel box would throw the picture into the far distance.
              if (box == null || (box.width < 8 && box.height < 8)) return;
              widget.onZoomBox(box,
                  out: HardwareKeyboard.instance.isAltPressed);
            },
            onPanCancel: () => setState(() {
              _from = null;
              _to = null;
            }),
            child: Stack(children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _ZoomBoxPainter(box: _box, accent: widget.accent),
                ),
              ),
              MagnifierPointer(
                at: _pointer,
                out: _alt,
                mark: widget.mark,
                outline: widget.outline,
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// The rectangle being dragged — the same mark the selection marquee draws, so
/// "I am sweeping an area" reads the same whichever tool is in hand.
class _ZoomBoxPainter extends CustomPainter {
  final Rect? box;
  final Color accent;

  const _ZoomBoxPainter({required this.box, required this.accent});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = box;
    if (rect == null) return;
    canvas.drawRect(rect, Paint()..color = accent.withValues(alpha: 0.12));
    canvas.drawRect(
      rect,
      Paint()
        ..color = accent
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_ZoomBoxPainter old) =>
      old.box != box || old.accent != accent;
}
