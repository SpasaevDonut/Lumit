// The shape tools and the Pen over the picture: the drag that draws a mask, and
// the Pen's point-by-point path (K-222, K-223, docs/07 §2.3).
//
// **In plain terms.** With a shape tool in hand and a layer selected, dragging
// over the picture draws a mask on that layer — a rectangle, a rounded
// rectangle, an ellipse, a polygon or a star, between the two corners you
// dragged, with Shift keeping it square. The **Pen** is different: it builds a
// path a point at a time, and clicking its first point again closes and applies
// it. (That gesture was briefly on the polygon tool; it is After Effects' pen,
// and it belongs on the Pen — K-223.)
//
// **What it does with nothing selected.** Nothing — and it says so. After
// Effects would make a *shape layer* there, which Lumit's engine has no such
// thing as yet (`LayerKind` has no Shape variant, docs/TODO.md). Rather than
// quietly doing nothing, or inventing something that only looks like a shape
// layer, the status line says what to do instead. That is the honest state of
// it until the engine grows the kind.
//
// The geometry is in viewer_shapes.dart and is pure; this is the gesture and
// the drawing.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';
import 'package:lumit_flutter/state/tools.dart';
import 'package:uuid/uuid.dart';

import '../widgets/controls.dart';
import 'viewer_gizmo.dart';
import 'viewer_tool_cursor.dart';
import 'viewer_shapes.dart';

/// The shape tools over the picture.
class ViewerShapeLayer extends StatefulWidget {
  /// Whether a shape tool is armed. Inert otherwise.
  final bool active;

  final ToolMode tool;
  final LumitState state;
  final LumitUiState uiState;

  /// Every layer with its box, top first — for the layer being masked and the
  /// map that turns the pointer into layer coordinates.
  final List<LayerBox> boxes;

  /// The composition, for the shape layer a drag makes when nothing is
  /// selected (K-237).
  final CompositionReference comp;

  /// Where the picture sits on screen, and the comp's own size — the two that
  /// turn a pointer into composition pixels when there is no layer to ask.
  final Rect fitted;
  final Size compSize;

  final Color accent;

  final VoidCallback onChanged;

  const ViewerShapeLayer({
    super.key,
    required this.active,
    required this.tool,
    required this.state,
    required this.uiState,
    required this.boxes,
    required this.comp,
    required this.fitted,
    required this.compSize,
    required this.accent,
    required this.onChanged,
  });

  @override
  State<ViewerShapeLayer> createState() => _ViewerShapeLayerState();
}

class _ViewerShapeLayerState extends State<ViewerShapeLayer> {
  /// The drag in flight, in screen space.
  Offset? _from;
  Offset? _to;

  /// Where the pointer went down, for the same reason every other tool records
  /// it (K-217): the framework only reports a drag once it has travelled its
  /// slop, and a shape that started 18px from where you pressed is the wrong
  /// shape.
  Offset? _downAt;

  /// The path being built with the Pen, and the pointer drawing its next edge.
  PathDraft _draft = const PathDraft();
  Offset? _penPointer;

  /// Where the pointer is, for the drawn cursor (K-226). Tracked for every
  /// shape tool, not only the Pen, because every one of them wears one.
  Offset? _pointer;

  /// The handle being pulled out of the vertex just placed, if the click that
  /// placed it turned into a drag.
  Offset? _handleFrom;
  Offset? _handleTo;

  /// Whether the Pen is in hand. Only the Pen itself builds a path; its four
  /// siblings (add/delete/convert vertex, mask feather) edit a *finished* one,
  /// which is not built (docs/TODO.md).
  bool get _isPen => widget.tool == ToolMode.pen;

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

  /// Escape abandons a path in progress; Backspace takes back its last point.
  /// Both are what every path tool does, and both are why a half-drawn path is
  /// never a trap.
  bool _onKey(KeyEvent event) {
    if (!widget.active || !_isPen || _draft.isEmpty) return false;
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      setState(() => _draft = const PathDraft());
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      setState(() => _draft = _draft.withoutLast());
      return true;
    }
    return false;
  }

  /// The layer a shape would be drawn on: the primary selection.
  LayerBox? get _target {
    final ids = widget.uiState.selectedLayerIds;
    for (final box in widget.boxes) {
      if (ids.contains(box.id)) return box;
    }
    return null;
  }

  /// A point on screen in the composition's own pixels — what a shape layer's
  /// art is built in when there is no layer to ask (K-237).
  (double, double) _compPoint(Offset at) {
    final scale = widget.compSize.width == 0
        ? 1.0
        : widget.fitted.width / widget.compSize.width;
    return (
      (at.dx - widget.fitted.left) / scale,
      (at.dy - widget.fitted.top) / scale,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return const SizedBox.shrink();
    final t = ThemeScope.of(context).theme;
    final target = _target;
    return Positioned.fill(
      child: MouseRegion(
        // Hidden, because the drawn pointer below replaces it (K-226): the
        // eyedropper's crosshair, badged with this tool's own icon.
        cursor: SystemMouseCursors.none,
        onEnter: (event) => setState(() => _pointer = event.localPosition),
        onHover: (event) => setState(() {
          _pointer = event.localPosition;
          // The Pen also draws the edge it would place next, from the last
          // point placed to here.
          if (_isPen) _penPointer = event.localPosition;
        }),
        onExit: (_) => setState(() {
          _pointer = null;
          _penPointer = null;
        }),
        child: Listener(
          onPointerDown: (event) => _downAt = event.localPosition,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: _isPen ? _onPenTap : null,
            onPanStart: _onPanStart,
            onPanUpdate: _onPanUpdate,
            onPanEnd: (_) => _onPanEnd(),
            onPanCancel: _onPanCancel,
            child: Stack(children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _ShapePreviewPainter(
                    tool: widget.tool,
                    box: target,
                    from: _from,
                    to: _to,
                    square: HardwareKeyboard.instance.isShiftPressed,
                    draft: _draft,
                    penPointer: _penPointer,
                    handleFrom: _handleFrom,
                    handleTo: _handleTo,
                    accent: widget.accent,
                  ),
                ),
              ),
              ToolPointer(
                at: _pointer,
                tool: widget.tool,
                mark: t.textPrimary,
                outline: t.surface0,
              ),
            ]),
          ),
        ),
      ),
    );
  }

  // --- The dragged shapes ---------------------------------------------------

  void _onPanStart(DragStartDetails details) {
    final at = _downAt ?? details.localPosition;
    if (_isPen) {
      // A click that became a drag: the vertex lands where the press was, and
      // the drag pulls its handles out.
      setState(() {
        _handleFrom = at;
        _handleTo = details.localPosition;
      });
      return;
    }
    setState(() {
      _from = at;
      _to = details.localPosition;
    });
  }

  void _onPanUpdate(DragUpdateDetails details) {
    setState(() {
      if (_isPen) {
        _handleTo = details.localPosition;
        _penPointer = details.localPosition;
      } else {
        _to = details.localPosition;
      }
    });
  }

  void _onPanEnd() {
    if (_isPen) {
      _finishHandleDrag();
      return;
    }
    final from = _from;
    final to = _to;
    setState(() {
      _from = null;
      _to = null;
    });
    if (from == null || to == null) return;
    // A drag of a few pixels is a slip of the hand, not a shape.
    if ((to - from).distance < 4) return;

    final box = _target;
    if (box == null) {
      // Nothing selected: After Effects' other half of this gesture — a new
      // shape layer at the top of the composition (K-237).
      _commitShapeLayer(shapePath(
        tool: widget.tool,
        from: _compPoint(from),
        to: _compPoint(to),
        square: HardwareKeyboard.instance.isShiftPressed,
      ));
      return;
    }
    final a = box.map.layerOf(from);
    final b = box.map.layerOf(to);
    final path = shapePath(
      tool: widget.tool,
      from: (a.dx, a.dy),
      to: (b.dx, b.dy),
      square: HardwareKeyboard.instance.isShiftPressed,
    );
    _commit(box, path);
  }

  void _onPanCancel() => setState(() {
        _from = null;
        _to = null;
        _handleFrom = null;
        _handleTo = null;
      });

  // --- The Pen --------------------------------------------------------------

  /// A plain click: place a corner, or close the path when it lands on the
  /// first point.
  void _onPenTap(TapUpDetails details) {
    final box = _target;
    // The path is built in the layer's coordinates when there is a layer, and
    // in the composition's when there is not — the same path either way, and
    // the difference is only which thing it will belong to (K-237).
    final at = box == null
        ? _compPoint(details.localPosition)
        : () {
            final p = box.map.layerOf(details.localPosition);
            return (p.dx, p.dy);
          }();
    final start = _draft.first;
    if (start != null &&
        _draft.canClose &&
        withinClosingDistance(
          at,
          start,
          screenScale: box == null
              ? _screenScale
              : box.map.viewScale * box.map.sx,
        )) {
      final path = _draft.vertices;
      setState(() => _draft = const PathDraft());
      if (box == null) {
        _commitShapeLayer(path);
      } else {
        _commit(box, path);
      }
      return;
    }
    setState(() => _draft = _draft.withCorner(at));
  }

  /// How many screen pixels one composition pixel covers.
  double get _screenScale => widget.compSize.width == 0
      ? 1.0
      : widget.fitted.width / widget.compSize.width;

  /// A click that turned into a drag: the vertex is placed where the press was
  /// and its handles are pulled out to the pointer.
  void _finishHandleDrag() {
    final from = _handleFrom;
    final to = _handleTo;
    setState(() {
      _handleFrom = null;
      _handleTo = null;
    });
    final box = _target;
    if (from == null || to == null) return;
    final at = box == null
        ? _compPoint(from)
        : () {
            final p = box.map.layerOf(from);
            return (p.dx, p.dy);
          }();
    final handle = box == null
        ? _compPoint(to)
        : () {
            final p = box.map.layerOf(to);
            return (p.dx, p.dy);
          }();
    setState(() => _draft = _draft.withBezier(
          at,
          handle,
          independent: HardwareKeyboard.instance.isAltPressed,
        ));
  }

  // --- Committing -----------------------------------------------------------

  /// A new shape layer holding this art, at the top of the composition — what a
  /// shape tool or the Pen does with nothing selected (K-237).
  ///
  /// The art takes the toolbar's fill, and its stroke when one has a width: the
  /// two swatches that had nothing to paint until there were shape layers.
  void _commitShapeLayer(List<BridgeVertex> path) {
    if (path.length < 2) return;
    final tools = widget.uiState.tools;
    final name = shapeMaskName(widget.tool);
    try {
      final layer = widget.comp.addShapeLayer(
        name: name,
        contents: [
          BridgeShapeItem(
            id: UuidValue.fromString(const Uuid().v4()),
            name: name,
            vertices: path,
            // Always closed: a shape tool draws a closed figure, and the Pen
            // commits only when its path has come back to its first point.
            closed: true,
            fill: tools.fillRgba,
            stroke: tools.strokeWidth > 0 ? tools.strokeRgba : null,
            strokeWidth: tools.strokeWidth,
            opacity: 100,
          ),
        ],
      );
      widget.uiState.setSelection([layer]);
      widget.onChanged();
    } catch (_) {
      widget.state.postNotice('Could not add a shape layer', error: true);
    }
  }

  void _commit(LayerBox box, List<BridgeVertex> path) {
    if (path.length < 2) return;
    try {
      box.layer.addMask(
        mask: shapeMask(
          vertices: path,
          name: shapeMaskName(widget.tool),
        ),
      );
      widget.onChanged();
    } catch (_) {
      // The layer went away, or the engine refused the path. Nothing on
      // screen: the same calm refusal every other tool gives.
    }
  }
}

/// The shape being dragged, and the polygon being built.
class _ShapePreviewPainter extends CustomPainter {
  final ToolMode tool;
  final LayerBox? box;
  final Offset? from;
  final Offset? to;
  final bool square;
  final PathDraft draft;
  final Offset? penPointer;
  final Offset? handleFrom;
  final Offset? handleTo;
  final Color accent;

  const _ShapePreviewPainter({
    required this.tool,
    required this.box,
    required this.from,
    required this.to,
    required this.square,
    required this.draft,
    required this.penPointer,
    required this.handleFrom,
    required this.handleTo,
    required this.accent,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    final layer = box;
    // The dragged shape, drawn as the real path rather than as its bounding
    // box: an ellipse being dragged should look like an ellipse.
    if (layer != null && from != null && to != null) {
      final a = layer.map.layerOf(from!);
      final b = layer.map.layerOf(to!);
      final path = shapePath(
        tool: tool,
        from: (a.dx, a.dy),
        to: (b.dx, b.dy),
        square: square,
      );
      if (path.isNotEmpty) {
        canvas.drawPath(_screenPath(layer, path, closed: true), stroke);
      }
    }

    if (draft.isEmpty && handleFrom == null) return;

    if (layer != null && draft.vertices.isNotEmpty) {
      canvas.drawPath(
        _screenPath(layer, draft.vertices, closed: false),
        stroke,
      );
      // Every placed vertex, and the first one larger: it is the one a click
      // has to land on to close the shape.
      for (var i = 0; i < draft.vertices.length; i++) {
        final v = draft.vertices[i];
        final at = layer.map.toScreen(v.x, v.y);
        canvas.drawCircle(at, i == 0 ? 5 : 3, Paint()..color = accent);
      }
      // The edge that would be drawn if the pointer clicked now.
      final pointer = penPointer;
      if (pointer != null) {
        final last = draft.vertices.last;
        canvas.drawLine(
          layer.map.toScreen(last.x, last.y),
          pointer,
          Paint()
            ..color = accent.withValues(alpha: 0.5)
            ..strokeWidth = 1,
        );
      }
    }

    // The handles being pulled out of a vertex, with their mirror — the same
    // pair of arms the graph editor draws on a keyframe.
    final hFrom = handleFrom;
    final hTo = handleTo;
    if (hFrom != null && hTo != null) {
      final mirrored = hFrom * 2 - hTo;
      canvas.drawLine(hFrom, hTo, stroke);
      if (!HardwareKeyboard.instance.isAltPressed) {
        canvas.drawLine(hFrom, mirrored, stroke);
        canvas.drawCircle(mirrored, 3, Paint()..color = accent);
      }
      canvas.drawCircle(hTo, 3, Paint()..color = accent);
      canvas.drawCircle(hFrom, 4, Paint()..color = accent);
    }
  }

  /// A mask path in layer space, as a screen path — cubics between each pair of
  /// vertices, using their facing handles, which is exactly how the engine
  /// reads the same numbers.
  Path _screenPath(LayerBox layer, List<BridgeVertex> vertices,
      {required bool closed}) {
    final path = Path();
    Offset at(BridgeVertex v) => layer.map.toScreen(v.x, v.y);
    Offset out(BridgeVertex v) => layer.map.toScreen(v.x + v.tanOutX, v.y + v.tanOutY);
    Offset into(BridgeVertex v) => layer.map.toScreen(v.x + v.tanInX, v.y + v.tanInY);

    path.moveTo(at(vertices.first).dx, at(vertices.first).dy);
    for (var i = 1; i < vertices.length; i++) {
      final a = vertices[i - 1];
      final b = vertices[i];
      final c1 = out(a);
      final c2 = into(b);
      path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, at(b).dx, at(b).dy);
    }
    if (closed && vertices.length > 2) {
      final a = vertices.last;
      final b = vertices.first;
      final c1 = out(a);
      final c2 = into(b);
      path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, at(b).dx, at(b).dy);
      path.close();
    }
    return path;
  }

  @override
  bool shouldRepaint(_ShapePreviewPainter old) => true;
}
