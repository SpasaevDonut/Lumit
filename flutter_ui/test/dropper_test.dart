// The dropper's arithmetic and its viewfinder.
//
// The sums matter more than they look: a colour lifted off the picture is
// written straight into a scene-linear parameter, so an average taken in the
// wrong space is a wrong colour with nothing on screen to say so. The
// viewfinder tests pin the two things the owner asked for by eye — nine by
// nine, and the centre pixel alone until Shift+scroll says otherwise.

import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumit_flutter/src/rust/api/state.dart';
import 'package:lumit_flutter/state/dropper.dart';
import 'package:lumit_flutter/theme/theme.dart';
import 'package:lumit_flutter/widgets/controls.dart';
import 'package:lumit_flutter/widgets/dropper_overlay.dart';

/// A window of [side] pixels centred on `(cx, cy)` of the picture, whose pixels
/// are given by `pixel(x, y)` in the *picture's* own coordinates — so a test can
/// say "white on the left half" without doing the window arithmetic itself.
/// [layerAlone] marks it as a read of one layer on its own, as a depth reply is.
BridgeSampledPixels windowOf(
  List<int> Function(int x, int y) pixel, {
  int side = 21,
  int cx = 40,
  int cy = 20,
  bool layerAlone = false,
}) {
  final bytes = Uint8List(side * side * 4);
  final half = side ~/ 2;
  for (var row = 0; row < side; row++) {
    for (var col = 0; col < side; col++) {
      final rgb = pixel(cx - half + col, cy - half + row);
      final i = (row * side + col) * 4;
      bytes[i] = rgb[0];
      bytes[i + 1] = rgb[1];
      bytes[i + 2] = rgb[2];
      bytes[i + 3] = 255;
    }
  }
  return BridgeSampledPixels(
    window: side,
    rgba: bytes,
    width: 100,
    height: 50,
    x: cx,
    y: cy,
    frame: BigInt.zero,
    layerAlone: layerAlone,
  );
}

Widget harness(Widget child) => Directionality(
      textDirection: TextDirection.ltr,
      child: ThemeScope(
        theme: LumitTheme.dark(),
        animationLevel: AnimationLevel.none,
        showTooltips: false,
        child: Center(child: child),
      ),
    );

void main() {
  group('the sample sizes', () {
    test('start at one pixel and step 1, 3, 5, 7, 9 without wrapping', () {
      expect(dropperRegions.first, 1, reason: 'the centre pixel alone');
      expect(dropperRegions, [1, 3, 5, 7, 9]);
      expect(nextDropperRegion(1, 1), 3);
      expect(nextDropperRegion(3, 1), 5);
      expect(nextDropperRegion(9, 1), 9, reason: 'the top holds, never wraps');
      expect(nextDropperRegion(1, -1), 1, reason: 'and so does the bottom');
      expect(nextDropperRegion(5, -1), 3);
    });

    test('every size is odd, so there is always one centre pixel', () {
      for (final n in dropperRegions) {
        expect(n.isOdd, isTrue, reason: '$n');
        expect(n <= dropperGrid, isTrue, reason: 'never wider than the grid');
      }
    });
  });

  group('sampling a window', () {
    test('one pixel is that pixel, decoded to scene-linear', () {
      // Pure red at (40, 20), black everywhere else.
      final w = windowOf((x, y) => x == 40 && y == 20 ? [255, 0, 0] : [0, 0, 0]);
      final sample = sampleFromWindow(w, 1, 40, 20);
      expect(sample.r, closeTo(1.0, 1e-9), reason: 'sRGB 255 is linear 1.0');
      expect(sample.g, closeTo(0.0, 1e-9));
      expect(sample.b, closeTo(0.0, 1e-9));
      expect(sample.region, 1);
      expect([sample.x, sample.y], [40, 20], reason: 'the pixel it came from');
    });

    test('a wider region averages in linear light, not in sRGB bytes', () {
      // One white pixel among its eight black neighbours: over 3×3 that is one
      // ninth of the light, not the byte midpoint a naive average gives.
      final w =
          windowOf((x, y) => x == 40 && y == 20 ? [255, 255, 255] : [0, 0, 0]);
      final sample = sampleFromWindow(w, 3, 40, 20);
      expect(sample.r, closeTo(1 / 9, 1e-9));
      expect(sample.depth, closeTo(1 / 9, 1e-9));
    });

    /// **The point of a window.** The magnifier reads it around wherever the
    /// pointer is *now*, not around where it was when the window was read — so
    /// moving the pointer inside one costs no engine call and still samples the
    /// right pixel.
    test('reads around the pointer, not around the window centre', () {
      // White left of x = 40, black from there on.
      final w = windowOf((x, y) => x < 40 ? [255, 255, 255] : [0, 0, 0]);
      expect(sampleFromWindow(w, 1, 40, 20).r, closeTo(0.0, 1e-9));
      expect(sampleFromWindow(w, 1, 39, 20).r, closeTo(1.0, 1e-9),
          reason: 'one pixel left of the centre is on the white side');
      expect(sampleFromWindow(w, 1, 45, 25).r, closeTo(0.0, 1e-9));
    });

    test('a region wider than the magnifier is clamped rather than taken', () {
      final w = windowOf((x, y) => [255, 255, 255]);
      final sample = sampleFromWindow(w, 99, 40, 20);
      expect(sample.region, dropperGrid);
      expect(sample.r, closeTo(1.0, 1e-9));
    });

    test('a pixel outside the window clamps to its edge rather than throwing',
        () {
      final w = windowOf((x, y) => [10, 20, 30], side: 11);
      final px = windowPixel(w, 4000, 4000);
      expect(px, isNotNull);
      expect([px!.r, px.g, px.b], [10, 20, 30]);
    });

    test('depth is Rec. 709 luma in linear light', () {
      expect(sampleFromWindow(windowOf((x, y) => [0, 255, 0]), 1, 40, 20).depth,
          closeTo(0.7152, 1e-6));
      expect(
          sampleFromWindow(windowOf((x, y) => [0, 0, 0]), 1, 40, 20).depth, 0);
    });
  });

  group('when a window has to be re-read', () {
    // 21 a side centred on (40, 20): it covers the magnifier's grid anywhere
    // within ten pixels of that centre, less the four the grid itself reaches.
    final w = windowOf((x, y) => [0, 0, 0]);

    test('covers the pointer while the whole grid still fits inside it', () {
      expect(windowCovers(w, 40, 20), isTrue, reason: 'dead centre');
      expect(windowCovers(w, 46, 26), isTrue);
      expect(windowCovers(w, 34, 14), isTrue, reason: 'the far corner, just');
    });

    test('stops covering once the grid would reach past its edge', () {
      expect(windowCovers(w, 47, 20), isFalse);
      expect(windowCovers(w, 40, 33), isFalse);
    });

    /// The whole point of the size: a pointer can travel most of a window
    /// before another read is needed, so a sweep across the picture is a
    /// handful of reads rather than one per mouse move.
    test('a full-size window lasts a long pointer travel', () {
      final full = windowOf((x, y) => [0, 0, 0], side: dropperWindow);
      final reach = dropperWindow ~/ 2 - dropperGrid ~/ 2;
      expect(reach, greaterThan(50));
      expect(windowCovers(full, 40 + reach, 20), isTrue);
      expect(windowCovers(full, 40 + reach + 1, 20), isFalse);
    });
  });

  group('sRGB conversion', () {
    test('round-trips every byte', () {
      for (var b = 0; b <= 255; b++) {
        expect(srgbEncode(srgbDecode(b)), b, reason: '$b');
      }
    });

    test('the ends are exact and the middle is not the byte midpoint', () {
      expect(srgbDecode(0), 0);
      expect(srgbDecode(255), closeTo(1.0, 1e-9));
      expect(srgbDecode(128), lessThan(0.25),
          reason: 'mid-grey is about a fifth of the light, not half');
    });
  });

  group('the viewfinder', () {
    testWidgets('shows the colour and its numbers for a colour pick',
        (tester) async {
      final arm = DropperArm(
        id: 'test',
        reads: DropperReads.colour,
        label: 'Key colour',
        onPick: (_) {},
      );
      await tester.pumpWidget(harness(DropperViewfinder(
        arm: arm,
        window: windowOf((x, y) => [255, 128, 0]),
        centre: (40, 20),
        region: 1,
      )));
      expect(find.text('255 128 0'), findsOneWidget);
      expect(find.text('1×1'), findsOneWidget);
    });

    testWidgets('names the layer it is reading for a pick that is not a colour',
        (tester) async {
      final arm = DropperArm(
        id: 'test',
        reads: DropperReads.depth,
        label: 'Focus distance',
        sampleLayerName: 'Depth pass',
        onPick: (_) {},
      );
      await tester.pumpWidget(harness(DropperViewfinder(
        arm: arm,
        window: windowOf((x, y) => [255, 255, 255], layerAlone: true),
        centre: (40, 20),
        region: 3,
      )));
      // The layer the numbers come from, and the value — no colour swatch,
      // because no colour is being chosen.
      expect(find.textContaining('Depth pass'), findsOneWidget);
      expect(find.textContaining('1.000'), findsOneWidget);
      expect(find.text('3×3'), findsOneWidget);
    });

    testWidgets('says Composite when the pixels are not of that layer alone',
        (tester) async {
      final arm = DropperArm(
        id: 'test',
        reads: DropperReads.depth,
        label: 'Focus distance',
        sampleLayerName: 'Depth pass',
        onPick: (_) {},
      );
      await tester.pumpWidget(harness(DropperViewfinder(
        arm: arm,
        // layerAlone false: the reply is of the composite, so naming the layer
        // would claim the number came from somewhere it did not.
        window: windowOf((x, y) => [0, 0, 0]),
        centre: (40, 20),
        region: 1,
      )));
      expect(find.textContaining('Composite'), findsOneWidget);
      expect(find.textContaining('Depth pass'), findsNothing);
    });

    testWidgets('says so while the first read is still in flight',
        (tester) async {
      final arm = DropperArm(
        id: 'test',
        reads: DropperReads.colour,
        label: 'Key colour',
        onPick: (_) {},
      );
      await tester.pumpWidget(harness(DropperViewfinder(
          arm: arm, window: null, centre: (0, 0), region: 1)));
      expect(find.text('Reading…'), findsOneWidget);
    });

    test('the viewfinder is kept inside the picture at every edge', () {
      const bounds = Rect.fromLTWH(0, 0, 400, 300);
      // Middle of the picture: below and right of the pointer.
      expect(dropperViewfinderOrigin(const Offset(100, 100), bounds),
          const Offset(118, 118));
      // Bottom-right corner: pulled back so the whole of it stays on screen.
      final corner = dropperViewfinderOrigin(const Offset(399, 299), bounds);
      expect(corner.dx + dropperViewfinderSize.width, lessThanOrEqualTo(400));
      expect(corner.dy + dropperViewfinderSize.height, lessThanOrEqualTo(300));
    });
  });
}
