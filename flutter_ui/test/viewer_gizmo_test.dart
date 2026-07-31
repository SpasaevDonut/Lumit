// The Viewer gizmo's arithmetic (K-215): which layer a point is inside, what a
// marquee catches, where the handles sit once a layer is turned, and what a
// handle drag means.
//
// All of it is pure, so all of it is checked here against hand-computed cases
// rather than by dragging in a widget tree — the same reasoning as
// viewer_layer_map.dart, whose maths these build on.

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumit_flutter/panels/viewer_gizmo.dart';
import 'package:lumit_flutter/panels/viewer_layer_map.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';
import 'package:uuid/uuid.dart';

void main() {
  /// A layer of [size] sitting at [at] in a comp drawn 1:1 from the origin,
  /// anchored on its own middle — the arrangement a placed clip gets (K-150).
  LayerBox box({
    Size size = const Size(200, 100),
    Offset at = const Offset(300, 200),
    double scale = 100,
    double rotation = 0,
    Offset origin = Offset.zero,
    double viewScale = 1,
  }) =>
      LayerBox(
        layer: LayerReference(
          internalprojectId: UuidValue.fromString(const Uuid().v4()),
          internalcompId: UuidValue.fromString(const Uuid().v4()),
          internallayerId: UuidValue.fromString(const Uuid().v4()),
        ),
        id: UuidValue.fromString(const Uuid().v4()),
        map: ViewerLayerMap.of(
          positionX: at.dx,
          positionY: at.dy,
          anchorX: size.width / 2,
          anchorY: size.height / 2,
          scaleXPercent: scale,
          scaleYPercent: scale,
          rotationDegrees: rotation,
          origin: origin,
          viewScale: viewScale,
        ),
        bounds: size,
        draggable: true,
        scalable: true,
        rotationDegrees: rotation,
      );

  group('What a point is inside', () {
    test('the layer contains its own middle and not the space beside it', () {
      final b = box();
      expect(b.contains(const Offset(300, 200)), isTrue);
      expect(b.contains(const Offset(399, 249)), isTrue,
          reason: 'just inside the bottom-right corner');
      expect(b.contains(const Offset(401, 200)), isFalse);
      expect(b.contains(const Offset(300, 260)), isFalse);
    });

    test('a rotated layer is tested in its own frame, not on screen', () {
      // Quarter-turned, the 200×100 layer occupies a 100×200 patch of screen.
      final b = box(rotation: 90);
      expect(b.contains(const Offset(300, 290)), isTrue,
          reason: '90 px down the screen is along the layer\'s own long axis');
      expect(b.contains(const Offset(390, 200)), isFalse,
          reason: 'and 90 px across it is outside the turned layer');
    });

    test('the topmost layer takes the click', () {
      final top = box(size: const Size(50, 50));
      final under = box();
      expect(layerAtPoint([top, under], const Offset(300, 200))?.id, top.id);
      // Beyond the small one, the big one below still answers.
      expect(layerAtPoint([top, under], const Offset(380, 200))?.id, under.id);
      expect(layerAtPoint([top, under], const Offset(600, 600)), isNull);
    });
  });

  group('What a marquee catches', () {
    test('only a box wholly inside it', () {
      final b = box();
      expect(b.insideRect(const Rect.fromLTRB(150, 100, 450, 300)), isTrue);
      expect(b.insideRect(const Rect.fromLTRB(150, 100, 350, 300)), isFalse,
          reason: 'the right-hand half is outside the sweep');
      expect(b.insideRect(const Rect.fromLTRB(0, 0, 10, 10)), isFalse);
    });

    test('a rotated box is caught by its corners, not its axis-aligned span',
        () {
      final b = box(rotation: 45);
      // The turned box reaches about ±106 px from its middle on the diagonal.
      expect(b.insideRect(const Rect.fromLTRB(180, 80, 420, 320)), isTrue);
      expect(b.insideRect(const Rect.fromLTRB(220, 140, 380, 260)), isFalse);
    });

    test('layersInsideRect keeps stacking order', () {
      final top = box(size: const Size(20, 20));
      final under = box(size: const Size(40, 40));
      final caught =
          layersInsideRect([top, under], const Rect.fromLTRB(0, 0, 600, 400));
      expect(caught.map((b) => b.id).toList(), [top.id, under.id]);
    });
  });

  group('Where the handles sit', () {
    test('the eight scale handles land on the box corners and edge middles',
        () {
      final b = box();
      expect(b.handleAt(GizmoHandle.topLeft), const Offset(200, 150));
      expect(b.handleAt(GizmoHandle.top), const Offset(300, 150));
      expect(b.handleAt(GizmoHandle.bottomRight), const Offset(400, 250));
      expect(b.handleAt(GizmoHandle.left), const Offset(200, 200));
    });

    test('the rotation knob stands off the top edge, and turns with the layer',
        () {
      final upright = box().handleAt(GizmoHandle.rotate);
      expect(upright.dx, closeTo(300, 0.001));
      expect(upright.dy, closeTo(150 - gizmoRotateReach, 0.001),
          reason: 'straight up from the top edge while the layer is upright');

      // Turned a half-circle, "up" for the layer is down the screen.
      final flipped = box(rotation: 180).handleAt(GizmoHandle.rotate);
      expect(flipped.dy, closeTo(250 + gizmoRotateReach, 0.001));
    });

    test('a press near a handle finds it, and one far from any finds none', () {
      final b = box();
      expect(b.handleHit(const Offset(202, 152)), GizmoHandle.topLeft);
      expect(b.handleHit(const Offset(300, 200)), isNull,
          reason: 'the middle of the layer is not a handle');
    });
  });

  group('What a handle drag means', () {
    test('dragging a corner outward scales the layer up', () {
      final b = box();
      // The bottom-right corner sits at (400, 250) and the anchor at (300,
      // 200) — pulling the corner twice as far from the anchor doubles both.
      final (sx, sy) = scaleForGizmoHandle(
        box: b,
        handle: GizmoHandle.bottomRight,
        pointer: const Offset(500, 300),
        uniform: false,
      );
      expect(sx, closeTo(200, 0.001));
      expect(sy, closeTo(200, 0.001));
    });

    test('an edge handle moves only its own axis', () {
      final b = box();
      final (sx, sy) = scaleForGizmoHandle(
        box: b,
        handle: GizmoHandle.right,
        pointer: const Offset(500, 400),
        uniform: false,
      );
      expect(sx, closeTo(200, 0.001));
      expect(sy, closeTo(100, 0.001),
          reason: 'the vertical has no offset from the anchor to resolve');
    });

    test('Shift keeps the proportions', () {
      final b = box();
      // A corner dragged to an off-diagonal point asks for 200% across and
      // 100% down; held uniform, both take the mean.
      final (sx, sy) = scaleForGizmoHandle(
        box: b,
        handle: GizmoHandle.bottomRight,
        pointer: const Offset(500, 250),
        uniform: true,
      );
      expect(sx, closeTo(sy, 0.001), reason: 'that is what uniform means');
      expect(sx, closeTo(150, 0.001));
    });

    test('Shift on an edge handle drives both axes from the resolved one', () {
      final b = box();
      final (sx, sy) = scaleForGizmoHandle(
        box: b,
        handle: GizmoHandle.right,
        pointer: const Offset(500, 200),
        uniform: true,
      );
      expect(sx, closeTo(200, 0.001));
      expect(sy, closeTo(200, 0.001),
          reason: 'the unresolved axis follows rather than staying behind');
    });
  });

  group('What a rotation drag means', () {
    const anchor = Offset(300, 200);

    test('the angle swept is added to where the layer already was', () {
      final result = rotationForDrag(
        anchor: anchor,
        from: const Offset(300, 100), // straight up
        to: const Offset(400, 200), // to the right: a quarter turn clockwise
        current: 0,
        uniform: false,
      );
      expect(result, closeTo(90, 0.001));
    });

    test('it carries on past a full turn rather than wrapping', () {
      final result = rotationForDrag(
        anchor: anchor,
        from: const Offset(300, 100),
        to: const Offset(400, 200),
        current: 350,
        uniform: false,
      );
      expect(result, closeTo(440, 0.001),
          reason: 'a layer wound twice round keeps its winding');
    });

    test('Shift snaps to 45° steps', () {
      final result = rotationForDrag(
        anchor: anchor,
        from: const Offset(300, 100),
        to: Offset(300 + 100 * math.cos(-0.6), 200 + 100 * math.sin(-0.6)),
        current: 0,
        uniform: true,
      );
      expect(result % 45, closeTo(0, 0.001));
    });
  });
}
