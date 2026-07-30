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

/// A 9×9 patch whose pixels are given by `pixel(x, y)` as an RGB triple.
/// [layerAlone] marks it as a read of one layer on its own, as a depth reply is.
BridgeSampledPixels patchOf(List<int> Function(int x, int y) pixel,
    {bool layerAlone = false}) {
  final bytes = Uint8List(dropperGrid * dropperGrid * 4);
  for (var y = 0; y < dropperGrid; y++) {
    for (var x = 0; x < dropperGrid; x++) {
      final rgb = pixel(x, y);
      final i = (y * dropperGrid + x) * 4;
      bytes[i] = rgb[0];
      bytes[i + 1] = rgb[1];
      bytes[i + 2] = rgb[2];
      bytes[i + 3] = 255;
    }
  }
  return BridgeSampledPixels(
    grid: dropperGrid,
    rgba: bytes,
    width: 100,
    height: 50,
    x: 7,
    y: 9,
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

  group('sampling a patch', () {
    test('one pixel is that pixel, decoded to scene-linear', () {
      // Pure red in the middle, black everywhere else.
      final patch = patchOf((x, y) => x == 4 && y == 4 ? [255, 0, 0] : [0, 0, 0]);
      final sample = sampleFromPatch(patch, 1);
      expect(sample.r, closeTo(1.0, 1e-9), reason: 'sRGB 255 is linear 1.0');
      expect(sample.g, closeTo(0.0, 1e-9));
      expect(sample.b, closeTo(0.0, 1e-9));
      expect(sample.region, 1);
      expect([sample.x, sample.y], [7, 9], reason: 'the pixel it came from');
    });

    test('a wider region averages in linear light, not in sRGB bytes', () {
      // The centre pixel white, its eight neighbours black: over 3×3 that is
      // one ninth of the light, not the byte midpoint a naive average gives.
      final patch =
          patchOf((x, y) => x == 4 && y == 4 ? [255, 255, 255] : [0, 0, 0]);
      final sample = sampleFromPatch(patch, 3);
      expect(sample.r, closeTo(1 / 9, 1e-9));
      expect(sample.depth, closeTo(1 / 9, 1e-9));
    });

    test('the region is the centre of the patch, whatever its size', () {
      // A left half of white and a right half of black: a 9×9 average is
      // dominated by the left, a 1×1 read of the centre column is not.
      final patch = patchOf((x, y) => x < 4 ? [255, 255, 255] : [0, 0, 0]);
      expect(sampleFromPatch(patch, 1).r, closeTo(0.0, 1e-9),
          reason: 'the centre pixel is on the black side');
      expect(sampleFromPatch(patch, 9).r, closeTo(4 / 9, 1e-9));
    });

    test('a region wider than the patch is clamped rather than read past', () {
      final patch = patchOf((x, y) => [255, 255, 255]);
      final sample = sampleFromPatch(patch, 99);
      expect(sample.region, dropperGrid);
      expect(sample.r, closeTo(1.0, 1e-9));
    });

    test('depth is Rec. 709 luma in linear light', () {
      final green = patchOf((x, y) => [0, 255, 0]);
      expect(sampleFromPatch(green, 1).depth, closeTo(0.7152, 1e-6));
      final black = patchOf((x, y) => [0, 0, 0]);
      expect(sampleFromPatch(black, 1).depth, 0);
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
        patch: patchOf((x, y) => [255, 128, 0]),
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
        patch: patchOf((x, y) => [255, 255, 255], layerAlone: true),
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
        patch: patchOf((x, y) => [0, 0, 0]),
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
      await tester.pumpWidget(
          harness(DropperViewfinder(arm: arm, patch: null, region: 1)));
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
