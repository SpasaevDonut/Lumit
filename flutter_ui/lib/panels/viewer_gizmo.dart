// The Viewer's layer controls: the wireframe boxes, the handles that scale and
// rotate, the click that selects, the drag that moves, and the marquee that
// selects several at once (K-217, docs/07 §2.3).
//
// **In plain terms.** Everything you can do to a layer with the mouse *on the
// picture* is here. A box is drawn round each selected layer, turned the way
// the layer is turned; eight small squares on its edges resize it; a short bar
// standing off its top rotates it; dragging inside it moves it; dragging from
// empty space rubber-bands a rectangle and takes everything wholly inside it.
// Hovering an unselected layer shows its box faintly, so a click never selects
// something you could not see coming.
//
// **What is geometry and what is a widget.** The arithmetic — where a handle
// sits, which layer a point is inside, whether a box is wholly within a
// rectangle, what scale a dragged handle implies — is plain functions at the
// top of this file, tested without a widget tree. [ViewerGizmoLayer] below is
// the part that listens to a pointer and commits ops; it holds no maths of its
// own beyond routing a gesture to one of those functions.
//
// **Whose transform is whose.** Every box is built from the comp read model
// (K-184), so drawing costs no bridge calls. Edits go through the layer's own
// reference handle, as everywhere else. A layer whose position is animated has
// no single point to drag, so it gets a box and no handles — the same rule the
// move handle had before this.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:lumit_flutter/src/rust/api/effect.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';
import 'package:lumit_flutter/state/tools.dart';
import 'package:uuid/uuid.dart';

import '../state/preview_throttle.dart';
import '../widgets/controls.dart';
import 'viewer_anchor.dart';
import 'viewer_layer_map.dart';

/// How big a scale handle is drawn, and how far from it a press still counts.
///
/// The handle is a dense-surface control by 15-DESIGN §7.2's reckoning — eight
/// of them on a box that can be small — so it draws at 9px and hit-tests at 32,
/// exactly as the Timeline's keyframes do.
const double gizmoHandleSize = 9;
const double gizmoHandleSlop = 32;

/// How far the rotation bar stands off the top of the box, in screen pixels.
const double gizmoRotateReach = 28;

/// How close a press has to be to the **anchor** handle to grab it, rather than
/// starting a move of the layer (K-221).
///
/// Much tighter than [gizmoHandleSlop], and deliberately: the anchor usually
/// sits in the middle of the box, which is also the easiest place to grab a
/// layer to move it. A generous slop there would turn every body drag into a
/// pan-behind — the pivot would slide and the layer would not, which reads as
/// the drag being broken. So the pivot has to be *aimed at*.
const double gizmoAnchorSlop = 16;

/// The eight scale handles and the rotation knob.
///
/// The scale handles are named for where they sit on the layer's own box, so
/// "topLeft" stays the top left of the *layer* however the layer is turned —
/// which is what makes a rotated box's handles keep dragging the edge you
/// grabbed rather than the one that happens to be uppermost on screen.
enum GizmoHandle {
  topLeft,
  top,
  topRight,
  right,
  bottomRight,
  bottom,
  bottomLeft,
  left,
  rotate,

  /// The anchor point itself (K-221): dragging it pans behind — the pivot moves
  /// and the picture stays put, exactly as the Anchor point tool does (K-220).
  /// It sits wherever the layer's anchor is, which is usually but not always
  /// the middle of the box.
  anchor;

  /// Where this handle sits on the unit box (0..1 in each axis). The rotation
  /// knob shares the top edge's midpoint and is pushed off the box in screen
  /// space, because its distance is a fixed number of *screen* pixels — it must
  /// stay grabbable however far the picture is zoomed out.
  (double, double) get unit => switch (this) {
        GizmoHandle.topLeft => (0, 0),
        GizmoHandle.top || GizmoHandle.rotate => (0.5, 0),
        GizmoHandle.topRight => (1, 0),
        GizmoHandle.right => (1, 0.5),
        GizmoHandle.bottomRight => (1, 1),
        GizmoHandle.bottom => (0.5, 1),
        GizmoHandle.bottomLeft => (0, 1),
        GizmoHandle.left => (0, 0.5),
        // Not a corner of the box at all — [LayerBox.handleAt] answers this one
        // from the layer's own anchor.
        GizmoHandle.anchor => (0.5, 0.5),
      };

  /// The eight that scale, in the order they are drawn.
  static const List<GizmoHandle> scaling = [
    GizmoHandle.topLeft,
    GizmoHandle.top,
    GizmoHandle.topRight,
    GizmoHandle.right,
    GizmoHandle.bottomRight,
    GizmoHandle.bottom,
    GizmoHandle.bottomLeft,
    GizmoHandle.left,
  ];
}

/// One layer as the Viewer sees it: its transform, how big its content is, and
/// everything that follows from those two.
///
/// Built per paint from the read model, so it is cheap and always current.
class LayerBox {
  final LayerReference layer;
  final UuidValue id;
  final ViewerLayerMap map;

  /// The content's size in layer pixels (see state/layer_bounds.dart).
  final Size bounds;

  /// Whether the layer's position is a single point rather than a curve. False
  /// means the box is drawn and nothing on it can be dragged: a keyframed
  /// position has no one value for a drag to add to.
  final bool draggable;

  /// The same for scale and rotation, which is what the handles write. A layer
  /// with a keyframed scale still moves; it just grows no handles.
  final bool scalable;

  /// The layer's masks (K-222), so the Viewer can outline them. Read from the
  /// model with everything else, so drawing them costs no bridge calls.
  final List<BridgeMask> masks;

  /// The layer's rotation in degrees, as the document holds it.
  ///
  /// Carried rather than recovered from [map]'s sine and cosine, which only
  /// ever answer between -180 and 180: a layer wound round twice would snap
  /// back to its first turn the moment the knob was touched.
  final double rotationDegrees;

  const LayerBox({
    required this.layer,
    required this.id,
    required this.map,
    required this.bounds,
    required this.draggable,
    required this.scalable,
    required this.rotationDegrees,
    this.masks = const [],
  });

  /// The same box with the layer scaled to [sxPercent] / [syPercent] — the
  /// shape a scale in flight has, before it is committed (K-230). Negative is
  /// allowed and means what it says: the layer is turned over.
  LayerBox scaledTo(double sxPercent, double syPercent) => LayerBox(
        layer: layer,
        id: id,
        map: map.scaledTo(sxPercent, syPercent),
        bounds: bounds,
        draggable: draggable,
        scalable: scalable,
        rotationDegrees: rotationDegrees,
        masks: masks,
      );

  /// The same box with the layer turned to [degrees] — the shape a rotation in
  /// flight has, before it is committed (K-230).
  LayerBox turnedTo(double degrees) => LayerBox(
        layer: layer,
        id: id,
        map: map.turnedTo(degrees),
        bounds: bounds,
        draggable: draggable,
        scalable: scalable,
        rotationDegrees: degrees,
        masks: masks,
      );

  /// The box's four corners in screen space, clockwise from the layer's own
  /// top-left. A rotated layer therefore gives a rotated quad, not an
  /// axis-aligned rectangle — the box turns with the layer.
  List<Offset> get corners => [
        map.toScreen(0, 0),
        map.toScreen(bounds.width, 0),
        map.toScreen(bounds.width, bounds.height),
        map.toScreen(0, bounds.height),
      ];

  /// Where the layer's anchor — the point it scales and rotates about — is on
  /// screen.
  Offset get anchorScreen => map.toScreen(map.ax, map.ay);

  /// Whether [point] (screen space) is inside the layer's own rectangle.
  ///
  /// Answered in *layer* space rather than by a polygon test on screen, which
  /// is both simpler and exact under rotation, scale and pan: the inverse map
  /// already undoes all three.
  bool contains(Offset point) {
    final p = map.layerOf(point);
    return p.dx >= 0 &&
        p.dy >= 0 &&
        p.dx <= bounds.width &&
        p.dy <= bounds.height;
  }

  /// Whether the whole box lies within [rect] — the marquee's rule. Every
  /// corner must be inside, so a layer half-caught by the rubber band is not
  /// selected (After Effects' own behaviour, and the one that makes a sloppy
  /// sweep predictable).
  bool insideRect(Rect rect) => corners.every(rect.contains);

  /// Where [handle] is drawn, in screen space.
  Offset handleAt(GizmoHandle handle) {
    if (handle == GizmoHandle.anchor) return anchorScreen;
    final (ux, uy) = handle.unit;
    final point = map.toScreen(ux * bounds.width, uy * bounds.height);
    if (handle != GizmoHandle.rotate) return point;
    // The knob stands off the top edge along the box's own "up", so it turns
    // with the layer exactly as After Effects' does.
    final up = _up;
    return point + up * gizmoRotateReach;
  }

  /// The box's own upward direction on screen, as a unit vector: the top edge's
  /// midpoint minus the bottom edge's, normalised. Falls back to straight up
  /// for a degenerate (zero-height) box.
  Offset get _up {
    final top = map.toScreen(bounds.width / 2, 0);
    final bottom = map.toScreen(bounds.width / 2, bounds.height);
    final d = top - bottom;
    final len = d.distance;
    return len < 1e-6 ? const Offset(0, -1) : d / len;
  }

  /// The handle under [point], or null when none is. Nearest wins, so two
  /// handles whose slop overlaps on a small box do not fight.
  GizmoHandle? handleHit(Offset point) {
    GizmoHandle? best;
    var bestDistance = gizmoHandleSlop / 2;
    // The anchor first in the list only matters for ties; nearest still wins.
    for (final handle in [
      GizmoHandle.anchor,
      ...GizmoHandle.scaling,
      GizmoHandle.rotate,
    ]) {
      final slop = handle == GizmoHandle.anchor
          ? gizmoAnchorSlop / 2
          : gizmoHandleSlop / 2;
      final d = (handleAt(handle) - point).distance;
      if (d <= slop && d <= bestDistance) {
        bestDistance = d;
        best = handle;
      }
    }
    return best;
  }
}

/// One vertex of one mask, named so a selection can hold it: which layer, which
/// mask, and which point along it (K-224).
///
/// A plain string rather than a record, because it is a *set* key: two points
/// are the same point when their names match, and a string says that without a
/// hashCode to write.
String maskPointKey(UuidValue layerId, UuidValue maskId, int index) =>
    '$layerId#$maskId#$index';

/// Every mask vertex of [box], with where it sits on screen and the key that
/// names it.
List<({String key, Offset at, UuidValue maskId, int index})> maskPointsOf(
    LayerBox box) {
  final out = <({String key, Offset at, UuidValue maskId, int index})>[];
  for (final mask in box.masks) {
    for (var i = 0; i < mask.vertices.length; i++) {
      final v = mask.vertices[i];
      out.add((
        key: maskPointKey(box.id, mask.id, i),
        at: box.map.toScreen(v.x, v.y),
        maskId: mask.id,
        index: i,
      ));
    }
  }
  return out;
}

/// The mask point under [point] across [boxes], or null when none is near
/// enough. Nearest wins, so two points close together do not fight.
({LayerBox box, String key, UuidValue maskId, int index})? maskPointAt(
  List<LayerBox> boxes,
  Offset point, {
  double slop = gizmoAnchorSlop / 2,
}) {
  ({LayerBox box, String key, UuidValue maskId, int index})? best;
  var bestDistance = slop;
  for (final box in boxes) {
    for (final p in maskPointsOf(box)) {
      final d = (p.at - point).distance;
      if (d <= bestDistance) {
        bestDistance = d;
        best = (box: box, key: p.key, maskId: p.maskId, index: p.index);
      }
    }
  }
  return best;
}

/// Every mask point of [boxes] inside [rect] — what a marquee catches when it
/// is sweeping points rather than layers.
Set<String> maskPointsInRect(List<LayerBox> boxes, Rect rect) => {
      for (final box in boxes)
        for (final p in maskPointsOf(box))
          if (rect.contains(p.at)) p.key,
    };

/// Which layer a click at [point] lands on: the topmost whose box contains it.
///
/// [boxes] is in stacking order, top first — the order the read model reports
/// layers in — so the first hit is the one a user would say is "on top".
LayerBox? layerAtPoint(List<LayerBox> boxes, Offset point) {
  for (final box in boxes) {
    if (box.contains(point)) return box;
  }
  return null;
}

/// Which layer a *drag* at [point] picks up (K-230).
///
/// A press inside something already selected grabs **that**, even when a layer
/// higher in the stack overlaps the same spot. Without this rule a layer chosen
/// in the Timeline could not be dragged wherever anything covered it: the press
/// silently swapped the selection for whatever was on top and moved that
/// instead, which is the drag doing something the user never asked for.
///
/// A plain click still takes the topmost ([layerAtPoint]) — that is how a layer
/// underneath gets chosen with the mouse in the first place.
LayerBox? layerToDragAt(
  List<LayerBox> boxes,
  Offset point,
  Set<UuidValue> selectedIds,
) {
  for (final box in boxes) {
    if (selectedIds.contains(box.id) && box.contains(point)) return box;
  }
  return layerAtPoint(boxes, point);
}

/// Every layer wholly inside [rect] — what a released marquee selects.
List<LayerBox> layersInsideRect(List<LayerBox> boxes, Rect rect) =>
    [for (final box in boxes) if (box.insideRect(rect)) box];

/// The scale percentages a handle drag implies.
///
/// [uniform] is the Shift rule: both axes take the same factor, so the layer
/// keeps its proportions. The shared factor is the mean of what each axis asked
/// for, which is what makes a corner drag follow the pointer's diagonal rather
/// than snapping to whichever axis moved more.
///
/// An edge handle resolves only its own axis — the other has no offset from the
/// anchor to divide by — so under [uniform] the resolved axis drives both.
(double, double) scaleForGizmoHandle({
  required LayerBox box,
  required GizmoHandle handle,
  required Offset pointer,
  required bool uniform,
}) {
  final (ux, uy) = handle.unit;
  final map = box.map;
  final dx = ux * box.bounds.width - map.ax;
  final dy = uy * box.bounds.height - map.ay;
  final (sx, sy) = map.scaleForHandle(
    dxFromAnchor: dx,
    dyFromAnchor: dy,
    pointer: pointer,
  );
  if (!uniform) return (sx, sy);

  final currentX = map.sx * 100.0;
  final currentY = map.sy * 100.0;
  // Which axes this handle can speak for at all: one with no offset from the
  // anchor — an edge handle's other axis, or an anchor sitting on the edge
  // being dragged — has nothing to divide by and came back unchanged. Deciding
  // that from the *geometry* rather than from "did the number move?" is what
  // keeps a corner drag that happens to leave one axis where it was from being
  // read as an edge drag.
  final ratios = <double>[
    if (dx.abs() > 1e-9 && currentX.abs() > 1e-9) sx / currentX,
    if (dy.abs() > 1e-9 && currentY.abs() > 1e-9) sy / currentY,
  ];
  if (ratios.isEmpty) return (sx, sy);
  final factor = ratios.reduce((a, b) => a + b) / ratios.length;
  return (currentX * factor, currentY * factor);
}

/// The rotation, in degrees, that dragging the knob from [from] to [to] implies
/// about [anchor] — the angle swept, added to where the layer already was.
///
/// [uniform] is Shift again, snapping to 45° steps as After Effects does.
double rotationForDrag({
  required Offset anchor,
  required Offset from,
  required Offset to,
  required double current,
  required bool uniform,
}) {
  double angle(Offset p) => math.atan2(p.dy - anchor.dy, p.dx - anchor.dx);
  final swept = (angle(to) - angle(from)) * 180.0 / math.pi;
  final result = current + swept;
  if (!uniform) return result;
  return (result / 45.0).roundToDouble() * 45.0;
}

/// What the pointer is doing to the picture right now.
enum _GizmoDrag { none, move, scale, rotate, anchor, points, marquee }

/// The layer controls over the picture.
class ViewerGizmoLayer extends StatefulWidget {
  final CompositionReference comp;
  final LumitUiState uiState;

  /// Every layer of the fronted comp, top first, with its box.
  final List<LayerBox> boxes;

  /// Whether the boxes, handles and hover highlight are drawn at all — the
  /// Viewer bar's wireframe switch. Gestures still work when they are off:
  /// hiding the controls is about the *picture* being unobstructed, not about
  /// giving up the mouse (After Effects' Show Layer Controls is the same).
  final bool showControls;

  /// The armed tool. Selection edits; Hand only ever draws.
  final ToolMode tool;

  /// Whether each selected layer's anchor point is marked — the pin it turns
  /// on. Drawn while the Rotation tool is armed (K-219), where "about what?" is
  /// the question the picture has to answer.
  final bool showAnchors;

  final VoidCallback onChanged;

  const ViewerGizmoLayer({
    super.key,
    required this.comp,
    required this.uiState,
    required this.boxes,
    required this.showControls,
    required this.tool,
    required this.onChanged,
    this.showAnchors = false,
  });

  @override
  State<ViewerGizmoLayer> createState() => _ViewerGizmoLayerState();
}

class _ViewerGizmoLayerState extends State<ViewerGizmoLayer> {
  /// The pointer's own gesture, decided when a drag starts and held until it
  /// ends — so a drag that began on a handle keeps scaling even once the
  /// pointer has left the handle's slop.
  _GizmoDrag _drag = _GizmoDrag.none;

  /// The drag so far, in screen pixels (a move), or the pointer's current
  /// position (a scale, a rotation, a marquee).
  Offset _delta = Offset.zero;
  Offset _origin = Offset.zero;
  Offset _pointer = Offset.zero;

  GizmoHandle? _handle;

  /// Where the pointer went down.
  ///
  /// Not the same as where the drag *starts*: a pan is only recognised once the
  /// pointer has travelled the framework's slop, and `DragStartDetails` reports
  /// that later point. A handle is 9px across, so by then the press has left it
  /// and every handle drag was read as a drag of the layer's body. What the
  /// user grabbed is where they put the pointer down, so that is what the hit
  /// test uses.
  Offset? _downAt;

  /// The layer a scale or rotation is acting on, and its box as it was when the
  /// gesture started — the maths is all relative to that, so it must not be
  /// rebuilt from a document the drag is itself changing.
  LayerBox? _acting;

  /// The layer under the pointer, drawn faintly so a click is predictable.
  UuidValue? _hover;

  /// The mask points that are selected, by [maskPointKey] (K-224).
  ///
  /// Points, not layers: with a mask on the picture the same marquee that
  /// gathers layers gathers *vertices*, and a drag then moves them. Which of
  /// the two a gesture means is decided by what is under it — a press on a
  /// point edits the path, a press anywhere else is the layer's.
  final Set<String> _points = {};

  final PreviewThrottle _throttle = PreviewThrottle();

  @override
  void dispose() {
    _throttle.cancel();
    super.dispose();
  }

  bool get _selectionTool => widget.tool.group == ToolGroup.select;

  /// The boxes of the selected layers, in stacking order.
  List<LayerBox> get _selected {
    final ids = widget.uiState.selectedLayerIds;
    return [for (final box in widget.boxes) if (ids.contains(box.id)) box];
  }

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final selected = [for (final box in _selected) _live(box)];
    // The single-selection case is the one that gets handles: scaling and
    // rotating a set about a shared box is a different gesture with its own
    // maths, and is not built (docs/TODO.md).
    final soleHandles = selected.length == 1 && selected.single.scalable
        ? selected.single
        : null;

    final painter = CustomPaint(
      painter: _GizmoPainter(
        selected: widget.showControls ? selected : const [],
        hover: widget.showControls && _hover != null && _selectionTool
            ? _hoverBox()
            : null,
        handlesFor: widget.showControls && _selectionTool ? soleHandles : null,
        // The masks of what is selected: a mask you cannot see is a mask you
        // cannot judge, and until mask editing exists this outline is the only
        // sight of one on the picture (K-222).
        maskedBoxes: widget.showControls ? selected : const [],
        selectedPoints: _points,
        pointNudge: _drag == _GizmoDrag.points ? _delta : Offset.zero,
        anchors: widget.showControls && widget.showAnchors
            ? [for (final box in selected) box.anchorScreen]
            : const [],
        marquee: _drag == _GizmoDrag.marquee ? _marqueeRect() : null,
        moved: _drag == _GizmoDrag.move ? _delta : Offset.zero,
        accent: t.accent,
        hairline: t.hairlineStrong,
        surface: t.surface0,
      ),
    );

    // The Hand tool never edits: its boxes are a read-out, and the drag under
    // them belongs to the panel, which pans the picture with it.
    if (!_selectionTool) {
      return Positioned.fill(child: IgnorePointer(child: painter));
    }

    return Positioned.fill(
      child: MouseRegion(
        onHover: _onHover,
        onExit: (_) => _setHover(null),
        child: Listener(
          onPointerDown: (event) => _downAt = event.localPosition,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: _onTapUp,
            onPanStart: _onPanStart,
            onPanUpdate: _onPanUpdate,
            onPanEnd: (_) => _onPanEnd(),
            onPanCancel: _onPanCancel,
            child: painter,
          ),
        ),
      ),
    );
  }

  /// [box] as the gesture in flight would have it (K-230).
  ///
  /// The picture underneath is previewed at the value being dragged towards
  /// while the document still holds the old one, so a box built from the
  /// document lags the picture and only catches up on release. Three gestures
  /// can be in flight, never at once: this gizmo's own rotation knob and its
  /// scale handles, both local, and the Rotation tool's turn, which arrives on
  /// [LumitUiState.liveRotations] from another layer of the Viewer's stack.
  LayerBox _live(LayerBox box) {
    if (_acting?.id == box.id) {
      switch (_drag) {
        case _GizmoDrag.rotate:
          final degrees = _rotationNow();
          if (degrees != null) return box.turnedTo(degrees);
        case _GizmoDrag.scale:
          final scale = _scaleNow();
          if (scale != null) return box.scaledTo(scale.$1, scale.$2);
        default:
          break;
      }
    }
    final degrees = widget.uiState.liveRotations.value[box.id];
    return degrees == null ? box : box.turnedTo(degrees);
  }

  LayerBox? _hoverBox() {
    for (final box in widget.boxes) {
      if (box.id == _hover) return box;
    }
    return null;
  }

  Rect _marqueeRect() => Rect.fromPoints(_origin, _pointer);

  void _setHover(UuidValue? id) {
    if (_hover == id) return;
    setState(() => _hover = id);
  }

  /// Track what a click would select. Only the layers that are *not* already
  /// selected highlight: a box already drawn in the accent needs no second
  /// mark, and highlighting it would read as a second state.
  void _onHover(PointerHoverEvent event) {
    if (_drag != _GizmoDrag.none) return;
    final hit = layerAtPoint(widget.boxes, event.localPosition);
    final ids = widget.uiState.selectedLayerIds;
    _setHover(hit == null || ids.contains(hit.id) ? null : hit.id);
  }

  /// A click selects what is under it — with Shift, adds to or removes from the
  /// selection; on empty space, selects nothing.
  void _onTapUp(TapUpDetails details) {
    final shift = HardwareKeyboard.instance.isShiftPressed;
    // A mask point first: it sits on top of the layer it belongs to, and a
    // click on it means the point rather than the layer.
    final point = widget.showControls
        ? maskPointAt(_selected, details.localPosition)
        : null;
    if (point != null) {
      setState(() {
        if (!shift) {
          _points
            ..clear()
            ..add(point.key);
        } else if (!_points.remove(point.key)) {
          _points.add(point.key);
        }
      });
      return;
    }

    final hit = layerAtPoint(widget.boxes, details.localPosition);
    if (hit == null) {
      if (!shift) {
        setState(_points.clear);
        widget.uiState.clearSelection();
      }
      return;
    }
    if (shift) {
      widget.uiState.toggleSelected(hit.layer);
    } else {
      widget.uiState.setSelection([hit.layer]);
    }
    _setHover(null);
  }

  void _onPanStart(DragStartDetails details) {
    // The press, not the point the pan was recognised at (see [_downAt]).
    final at = _downAt ?? details.localPosition;
    _origin = at;
    _pointer = details.localPosition;
    // The travel already spent recognising the drag counts: without it a move
    // lags the pointer by the slop for the whole gesture.
    _delta = details.localPosition - at;
    _acting = null;
    _handle = null;

    // A handle first: it sits on the box's edge, where the layer's own body is
    // also a target, and the handle must win there.
    final selected = _selected;
    if (selected.length == 1 && selected.single.scalable) {
      final handle = selected.single.handleHit(at);
      if (handle != null) {
        setState(() {
          _acting = selected.single;
          _handle = handle;
          _drag = switch (handle) {
            GizmoHandle.rotate => _GizmoDrag.rotate,
            GizmoHandle.anchor => _GizmoDrag.anchor,
            _ => _GizmoDrag.scale,
          };
        });
        return;
      }
    }

    // A mask point, on a layer that is selected: dragging it edits the path.
    // Only on selected layers, because a stray point of some layer underneath
    // must not steal a press meant for the picture.
    final point = widget.showControls
        ? maskPointAt(_selected, at)
        : null;
    if (point != null) {
      setState(() {
        if (!_points.contains(point.key)) {
          if (!HardwareKeyboard.instance.isShiftPressed) _points.clear();
          _points.add(point.key);
        }
        _drag = _GizmoDrag.points;
      });
      return;
    }

    final hit =
        layerToDragAt(widget.boxes, at, widget.uiState.selectedLayerIds);
    if (hit == null) {
      // Empty picture: rubber-band. The selection is left alone until the band
      // is let go — partly so the boxes stay on screen while it is drawn, and
      // partly because a sweep over a *selected* layer's mask points gathers
      // points (K-224), which it could not do if the press had already dropped
      // the layer they belong to.
      setState(() => _drag = _GizmoDrag.marquee);
      return;
    }

    // Dragging a layer that is not selected selects it first — otherwise the
    // gesture would move something the user had not chosen. A layer already in
    // the selection leaves the selection alone, so a set can be dragged as one.
    if (!widget.uiState.selectedLayerIds.contains(hit.id)) {
      widget.uiState.setSelection([hit.layer]);
    }
    setState(() {
      _drag = _GizmoDrag.move;
      _hover = null;
    });
  }

  void _onPanUpdate(DragUpdateDetails details) {
    setState(() {
      _pointer = details.localPosition;
      _delta += details.delta;
    });
    switch (_drag) {
      case _GizmoDrag.move:
        _previewMove();
      case _GizmoDrag.scale:
        _previewScale();
      case _GizmoDrag.rotate:
        _previewRotate();
      case _GizmoDrag.anchor:
        _previewAnchor();
      // The points follow the pointer as they are dragged; the picture catches
      // up on release. A mask preview would mean patching a path into the
      // engine's clone, which the preview call has no room for.
      case _GizmoDrag.points:
      case _GizmoDrag.marquee || _GizmoDrag.none:
        break;
    }
  }

  void _onPanEnd() {
    switch (_drag) {
      case _GizmoDrag.move:
        _commitMove();
      case _GizmoDrag.scale:
        _commitScale();
      case _GizmoDrag.rotate:
        _commitRotate();
      case _GizmoDrag.anchor:
        _commitAnchor();
      case _GizmoDrag.points:
        _commitPoints();
      case _GizmoDrag.marquee:
        _commitMarquee();
      case _GizmoDrag.none:
        break;
    }
    _throttle.cancel();
    setState(() {
      _drag = _GizmoDrag.none;
      _delta = Offset.zero;
      _acting = null;
      _handle = null;
    });
  }

  void _onPanCancel() {
    _throttle.cancel();
    setState(() {
      _drag = _GizmoDrag.none;
      _delta = Offset.zero;
      _acting = null;
      _handle = null;
    });
  }

  // --- Move -----------------------------------------------------------------

  /// A live preview, but only for a single layer: the engine patches one
  /// layer's transform into a clone of the document per request (K-183's
  /// preview path), so a set being dragged shows the picture move on release
  /// instead. The boxes follow the pointer either way, which is what makes the
  /// gesture readable.
  void _previewMove() {
    final selected = _selected;
    if (selected.length != 1) return;
    _throttle.request(() => _sendMovePreview(selected.single));
  }

  void _sendMovePreview(LayerBox box) {
    final (x, y) = _movedPosition(box);
    _sendPreview(box, (tf) => transformWithPosition(tf, x, y));
  }

  /// Ask for the provisional picture, and never let a refusal end the gesture.
  ///
  /// A preview is a courtesy: the drag is the user's, and it must finish and
  /// commit whatever the renderer is doing. Without this guard a machine with
  /// no working render worker — no GPU adapter, a worker that has stopped —
  /// threw out of the pointer handler and the drag died mid-stroke, taking the
  /// commit with it. The bridge throws on any refusal (docs/TODO.md: a panic or
  /// an error both arrive as a Dart throw), so the catch is deliberately broad.
  void _sendPreview(
      LayerBox box, BridgeTransform Function(BridgeTransform) patch) {
    try {
      widget.comp.renderFrameWithTransformPreview(
        frame: BigInt.from(widget.uiState.playheadFrame.value),
        scale: widget.uiState.viewerScale,
        layer: box.layer,
        transform: patch(box.layer.getTransform()),
      );
    } catch (_) {
      // The boxes still follow the pointer, and the commit still lands.
    }
  }

  (double, double) _movedPosition(LayerBox box) => (
        box.map.px + _delta.dx / box.map.viewScale,
        box.map.py + _delta.dy / box.map.viewScale,
      );

  void _commitMove() {
    if (_delta == Offset.zero) return;
    var landed = false;
    for (final box in _selected) {
      if (!box.draggable) continue;
      final (x, y) = _movedPosition(box);
      // One op for both axes (K-230). x and y are separate properties in the
      // model, and writing them separately made one drag cost two undo steps —
      // Ctrl+Z put the layer back half way, along one axis, which reads as the
      // undo being broken rather than as two honest edits.
      try {
        box.layer.setTransforms(
          props: const [
            BridgeTransformProp.positionX,
            BridgeTransformProp.positionY,
          ],
          values: [BridgeScalar.static_(x), BridgeScalar.static_(y)],
        );
        landed = true;
      } catch (_) {
        // A layer deleted while the drag was in flight. The rest still move.
      }
    }
    if (landed) widget.onChanged();
  }

  // --- Scale ----------------------------------------------------------------

  (double, double)? _scaleNow() {
    final box = _acting;
    final handle = _handle;
    if (box == null || handle == null) return null;
    return scaleForGizmoHandle(
      box: box,
      handle: handle,
      pointer: _pointer,
      uniform: HardwareKeyboard.instance.isShiftPressed,
    );
  }

  void _previewScale() {
    final box = _acting;
    final scale = _scaleNow();
    if (box == null || scale == null) return;
    _throttle
        .request(() => _sendPreview(box, (tf) => transformWithScale(tf, scale.$1, scale.$2)));
  }

  void _commitScale() {
    final box = _acting;
    final scale = _scaleNow();
    if (box == null || scale == null || _delta == Offset.zero) return;
    // One op for both axes, for the same reason a move is (K-230).
    box.layer.setTransforms(
      props: const [
        BridgeTransformProp.scaleX,
        BridgeTransformProp.scaleY,
      ],
      values: [
        BridgeScalar.static_(scale.$1),
        BridgeScalar.static_(scale.$2),
      ],
    );
    widget.onChanged();
  }

  // --- Rotate ---------------------------------------------------------------

  double? _rotationNow() {
    final box = _acting;
    if (box == null) return null;
    return rotationForDrag(
      anchor: box.anchorScreen,
      from: _origin,
      to: _pointer,
      current: box.rotationDegrees,
      uniform: HardwareKeyboard.instance.isShiftPressed,
    );
  }

  void _previewRotate() {
    final box = _acting;
    final rotation = _rotationNow();
    if (box == null || rotation == null) return;
    _throttle
        .request(() => _sendPreview(box, (tf) => transformWithRotation(tf, rotation)));
  }

  void _commitRotate() {
    final box = _acting;
    final rotation = _rotationNow();
    if (box == null || rotation == null || _delta == Offset.zero) return;
    box.layer.setTransform(
        prop: BridgeTransformProp.rotation,
        value: BridgeScalar.static_(rotation));
    widget.onChanged();
  }

  // --- Anchor (pan behind) --------------------------------------------------

  /// Where the anchor is being dragged to, in layer space, with the same two
  /// modifiers the Anchor point tool has (K-220): Shift locks the drag to one
  /// screen axis, Ctrl/Cmd snaps to the layer's own key points.
  Offset? _anchorNow() {
    final box = _acting;
    if (box == null) return null;
    var delta = _pointer - _origin;
    if (HardwareKeyboard.instance.isShiftPressed) {
      delta = constrainToAxis(delta);
    }
    final started = box.map.toScreen(box.map.ax, box.map.ay);
    final wanted = box.map.layerOf(started + delta);
    final snapping = defaultTargetPlatform == TargetPlatform.macOS
        ? HardwareKeyboard.instance.isMetaPressed
        : HardwareKeyboard.instance.isControlPressed;
    return snapping ? snapAnchor(wanted, box) : wanted;
  }

  /// The Position that keeps the picture still while the anchor moves.
  Offset _panBehindFor(LayerBox box, Offset anchor) => panBehindPosition(
        oldAnchor: Offset(box.map.ax, box.map.ay),
        newAnchor: anchor,
        position: Offset(box.map.px, box.map.py),
        scaleXPercent: box.map.sx * 100,
        scaleYPercent: box.map.sy * 100,
        rotationDegrees: box.rotationDegrees,
      );

  void _previewAnchor() {
    final box = _acting;
    final anchor = _anchorNow();
    if (box == null || anchor == null) return;
    final position = _panBehindFor(box, anchor);
    _throttle.request(() => _sendPreview(
          box,
          (tf) => BridgeTransform(
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
        ));
  }

  void _commitAnchor() {
    final box = _acting;
    final anchor = _anchorNow();
    if (box == null || anchor == null || _delta == Offset.zero) return;
    final position = _panBehindFor(box, anchor);
    try {
      // One op for the four properties: half of this edit moves the picture,
      // which is the one thing panning behind promises not to do (K-220).
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

  // --- Mask points ----------------------------------------------------------

  /// Write every dragged point's new position (K-224).
  ///
  /// The drag is a screen delta; each point is moved in its **own layer's**
  /// space, so a selection spanning two layers with different transforms still
  /// moves together on screen. One `set_mask` per mask, which is one undo step
  /// per mask — the same rule the razor follows for a multi-layer cut.
  void _commitPoints() {
    if (_delta == Offset.zero || _points.isEmpty) return;
    var landed = false;
    for (final box in _selected) {
      for (final mask in box.masks) {
        final moved = <int>[
          for (var i = 0; i < mask.vertices.length; i++)
            if (_points.contains(maskPointKey(box.id, mask.id, i))) i,
        ];
        if (moved.isEmpty) continue;
        // The delta in this layer's coordinates: two points on the picture,
        // subtracted, so the layer's scale and rotation are undone exactly.
        final origin = box.map.layerOf(Offset.zero);
        final shifted = box.map.layerOf(_delta);
        final dx = shifted.dx - origin.dx;
        final dy = shifted.dy - origin.dy;
        final vertices = [
          for (var i = 0; i < mask.vertices.length; i++)
            if (moved.contains(i))
              BridgeVertex(
                x: mask.vertices[i].x + dx,
                y: mask.vertices[i].y + dy,
                tanInX: mask.vertices[i].tanInX,
                tanInY: mask.vertices[i].tanInY,
                tanOutX: mask.vertices[i].tanOutX,
                tanOutY: mask.vertices[i].tanOutY,
              )
            else
              mask.vertices[i],
        ];
        try {
          box.layer.setMask(
            mask: BridgeMask(
              id: mask.id,
              name: mask.name,
              vertices: vertices,
              closed: mask.closed,
              inverted: mask.inverted,
              opacity: mask.opacity,
            ),
          );
          landed = true;
        } catch (_) {
          // The mask went away mid-drag; the rest still move.
        }
      }
    }
    if (landed) widget.onChanged();
  }

  // --- Marquee --------------------------------------------------------------

  void _commitMarquee() {
    final rect = _marqueeRect();
    // A stray click that happened to be read as a tiny drag should not clear a
    // selection the user just made another way.
    if (rect.width < 3 && rect.height < 3) return;

    // A sweep over a selected layer's mask points gathers **points** (K-224):
    // with a path on screen that is what a rubber band means, and the layers
    // are already selected anyway. With none caught it is the layer sweep it
    // has always been.
    if (widget.showControls) {
      final caughtPoints = maskPointsInRect(_selected, rect);
      if (caughtPoints.isNotEmpty) {
        setState(() {
          if (!HardwareKeyboard.instance.isShiftPressed) _points.clear();
          _points.addAll(caughtPoints);
        });
        return;
      }
    }
    setState(_points.clear);
    final caught = layersInsideRect(widget.boxes, rect);
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final layers = <LayerReference>[
      if (shift)
        for (final box in _selected) box.layer,
      for (final box in caught)
        if (!shift || !widget.uiState.selectedLayerIds.contains(box.id))
          box.layer,
    ];
    widget.uiState.setSelection(layers);
  }
}

/// The transform with one property replaced — the shape the preview call wants,
/// spelled out three times because the generated struct has no copy-with.
///
/// Public because the Rotation tool (viewer_rotate.dart) writes through the same
/// preview path: one copy of "the transform, but turned" for both.
BridgeTransform transformWithPosition(BridgeTransform tf, double x, double y) =>
    BridgeTransform(
      anchorX: tf.anchorX,
      anchorY: tf.anchorY,
      positionX: BridgeScalar.static_(x),
      positionY: BridgeScalar.static_(y),
      positionZ: tf.positionZ,
      scaleX: tf.scaleX,
      scaleY: tf.scaleY,
      rotation: tf.rotation,
      rotationX: tf.rotationX,
      rotationY: tf.rotationY,
      opacity: tf.opacity,
    );

BridgeTransform transformWithScale(BridgeTransform tf, double sx, double sy) =>
    BridgeTransform(
      anchorX: tf.anchorX,
      anchorY: tf.anchorY,
      positionX: tf.positionX,
      positionY: tf.positionY,
      positionZ: tf.positionZ,
      scaleX: BridgeScalar.static_(sx),
      scaleY: BridgeScalar.static_(sy),
      rotation: tf.rotation,
      rotationX: tf.rotationX,
      rotationY: tf.rotationY,
      opacity: tf.opacity,
    );

BridgeTransform transformWithRotation(BridgeTransform tf, double degrees) =>
    BridgeTransform(
      anchorX: tf.anchorX,
      anchorY: tf.anchorY,
      positionX: tf.positionX,
      positionY: tf.positionY,
      positionZ: tf.positionZ,
      scaleX: tf.scaleX,
      scaleY: tf.scaleY,
      rotation: BridgeScalar.static_(degrees),
      rotationX: tf.rotationX,
      rotationY: tf.rotationY,
      opacity: tf.opacity,
    );

/// Everything the gizmo draws: the selected boxes, the hovered one, the
/// handles, and the marquee.
class _GizmoPainter extends CustomPainter {
  final List<LayerBox> selected;

  /// The boxes whose masks are outlined.
  final List<LayerBox> maskedBoxes;

  /// The mask points that are selected, and how far a drag has moved them so
  /// far — so the path follows the pointer before the document hears about it.
  final Set<String> selectedPoints;
  final Offset pointNudge;
  final LayerBox? hover;
  final LayerBox? handlesFor;

  /// Where to mark an anchor point, in screen space.
  final List<Offset> anchors;
  final Rect? marquee;
  final Offset moved;
  final Color accent;
  final Color hairline;
  final Color surface;

  const _GizmoPainter({
    required this.selected,
    required this.maskedBoxes,
    required this.selectedPoints,
    required this.pointNudge,
    required this.hover,
    required this.handlesFor,
    required this.anchors,
    required this.marquee,
    required this.moved,
    required this.accent,
    required this.hairline,
    required this.surface,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // The layer a click would take: the same box, drawn faintly. Under the
    // selection, so a selected box is never dimmed by a hover on top of it.
    final hovered = hover;
    if (hovered != null) {
      _outline(canvas, hovered.corners, accent.withValues(alpha: 0.35));
    }

    for (final box in selected) {
      _outline(canvas, [for (final c in box.corners) c + moved], accent);
    }

    final handles = handlesFor;
    if (handles != null) {
      final corners = [for (final c in handles.corners) c + moved];
      // The rotation bar first, so the knob's outline draws over it.
      final top = (corners[0] + corners[1]) / 2;
      final knob = handles.handleAt(GizmoHandle.rotate) + moved;
      canvas.drawLine(
        top,
        knob,
        Paint()
          ..color = accent
          ..strokeWidth = 1,
      );
      _knob(canvas, knob);
      for (final handle in GizmoHandle.scaling) {
        _handle(canvas, handles.handleAt(handle) + moved);
      }
      // The pivot, which is now a handle in its own right (K-221): drawn as
      // the anchor's ring-and-cross rather than a square, so it never reads as
      // a ninth scale handle.
      _anchor(canvas, handles.handleAt(GizmoHandle.anchor) + moved);
    }

    for (final box in maskedBoxes) {
      for (final mask in box.masks) {
        _maskOutline(canvas, box, mask);
      }
    }

    for (final anchor in anchors) {
      _anchor(canvas, anchor + moved);
    }

    final band = marquee;
    if (band != null) {
      canvas.drawRect(band, Paint()..color = accent.withValues(alpha: 0.12));
      canvas.drawRect(
        band,
        Paint()
          ..color = accent
          ..strokeWidth = 1
          ..style = PaintingStyle.stroke,
      );
    }
  }

  void _outline(Canvas canvas, List<Offset> corners, Color colour) {
    canvas.drawPath(
      Path()..addPolygon(corners, true),
      Paint()
        ..color = colour
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke,
    );
  }

  /// A scale handle: a filled square with a hairline edge, so it reads on both
  /// a bright and a dark picture.
  void _handle(Canvas canvas, Offset at) {
    final rect = Rect.fromCenter(
      center: at,
      width: gizmoHandleSize,
      height: gizmoHandleSize,
    );
    canvas.drawRect(rect, Paint()..color = surface);
    canvas.drawRect(
      rect,
      Paint()
        ..color = accent
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke,
    );
  }

  /// One mask's path over the picture, in the layer's own space put through its
  /// transform — so the outline sits on the pixels it gates however the layer
  /// is moved or turned.
  void _maskOutline(Canvas canvas, LayerBox box, BridgeMask mask) {
    if (mask.vertices.length < 2) return;
    // A selected point follows the pointer while it is being dragged, so the
    // path bends live rather than jumping on release.
    Offset nudgeFor(int i) =>
        selectedPoints.contains(maskPointKey(box.id, mask.id, i))
            ? pointNudge
            : Offset.zero;
    Offset at(int i) {
      final v = mask.vertices[i];
      return box.map.toScreen(v.x, v.y) + moved + nudgeFor(i);
    }

    Offset out(int i) {
      final v = mask.vertices[i];
      return box.map.toScreen(v.x + v.tanOutX, v.y + v.tanOutY) +
          moved +
          nudgeFor(i);
    }

    Offset into(int i) {
      final v = mask.vertices[i];
      return box.map.toScreen(v.x + v.tanInX, v.y + v.tanInY) +
          moved +
          nudgeFor(i);
    }

    final path = Path()..moveTo(at(0).dx, at(0).dy);
    for (var i = 1; i < mask.vertices.length; i++) {
      path.cubicTo(
          out(i - 1).dx, out(i - 1).dy, into(i).dx, into(i).dy, at(i).dx, at(i).dy);
    }
    if (mask.closed && mask.vertices.length > 2) {
      final last = mask.vertices.length - 1;
      path.cubicTo(
          out(last).dx, out(last).dy, into(0).dx, into(0).dy, at(0).dx, at(0).dy);
      path.close();
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    // Every vertex, so a path can be seen point by point (K-224): hollow when
    // it is merely there, filled when it is selected — the same "outline means
    // available, fill means chosen" the keyframe diamonds use.
    for (var i = 0; i < mask.vertices.length; i++) {
      final selected =
          selectedPoints.contains(maskPointKey(box.id, mask.id, i));
      final rect = Rect.fromCenter(center: at(i), width: 6, height: 6);
      canvas.drawRect(rect, Paint()..color = selected ? accent : surface);
      if (!selected) {
        canvas.drawRect(
          rect,
          Paint()
            ..color = accent
            ..strokeWidth = 1
            ..style = PaintingStyle.stroke,
        );
      }
    }
  }

  /// The anchor point: a small ring with a cross through it — the same mark the
  /// anchor-point tool's icon carries, so the two read as one idea.
  void _anchor(Canvas canvas, Offset at) {
    final paint = Paint()
      ..color = accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawCircle(at, 4, paint);
    canvas.drawLine(at - const Offset(8, 0), at + const Offset(8, 0), paint);
    canvas.drawLine(at - const Offset(0, 8), at + const Offset(0, 8), paint);
  }

  void _knob(Canvas canvas, Offset at) {
    canvas.drawCircle(at, gizmoHandleSize / 2, Paint()..color = surface);
    canvas.drawCircle(
      at,
      gizmoHandleSize / 2,
      Paint()
        ..color = accent
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_GizmoPainter old) => true;
}
