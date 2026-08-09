// The radial menu's geometry (K-324): direction picks the slice, the dead
// zone picks nothing.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:lumit_flutter/widgets/radial_maths.dart';

void main() {
  test('the first slice is straight up, and they run clockwise', () {
    // Four slices: up, right, down, left.
    final up = radialSliceOffset(0, 4);
    expect(up.dx, closeTo(0, 1e-9));
    expect(up.dy, closeTo(-radialRadius, 1e-9), reason: 'up is negative dy');

    final right = radialSliceOffset(1, 4);
    expect(right.dx, closeTo(radialRadius, 1e-9));
    expect(right.dy, closeTo(0, 1e-9));

    final down = radialSliceOffset(2, 4);
    expect(down.dy, closeTo(radialRadius, 1e-9));

    final left = radialSliceOffset(3, 4);
    expect(left.dx, closeTo(-radialRadius, 1e-9));
  });

  test('a direction picks its slice however far the pointer went', () {
    for (final distance in [radialDeadZone + 1, 60.0, 400.0]) {
      expect(radialSliceAt(0, -distance, 4), 0, reason: 'up');
      expect(radialSliceAt(distance, 0, 4), 1, reason: 'right');
      expect(radialSliceAt(0, distance, 4), 2, reason: 'down');
      expect(radialSliceAt(-distance, 0, 4), 3, reason: 'left');
    }
  });

  test('the dead zone picks nothing, so opening and releasing cancels', () {
    expect(radialSliceAt(0, 0, 6), isNull);
    expect(radialSliceAt(radialDeadZone - 1, 0, 6), isNull);
    expect(radialSliceAt(radialDeadZone + 1, 0, 6), isNotNull);
  });

  test('every angle lands in exactly the slice it is nearest', () {
    for (final count in [1, 2, 3, 5, 8]) {
      for (var i = 0; i < count; i++) {
        final at = radialSliceOffset(i, count);
        expect(radialSliceAt(at.dx, at.dy, count), i,
            reason: 'a slice centre picks its own slice ($count slices)');
        // Just inside either boundary of the wedge picks the same slice.
        final half = math.pi / count * 0.9;
        final angle = radialSliceAngle(i, count);
        for (final edge in [angle - half, angle + half]) {
          final dx = radialRadius * math.sin(edge);
          final dy = -radialRadius * math.cos(edge);
          expect(radialSliceAt(dx, dy, count), i,
              reason: 'inside the wedge, near its edge ($count slices)');
        }
      }
    }
  });

  test('a menu with nothing in it picks nothing rather than dividing by zero',
      () {
    expect(radialSliceAt(0, -100, 0), isNull);
    expect(radialSliceAngle(0, 0), 0);
  });
}
