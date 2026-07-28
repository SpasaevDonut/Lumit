// Hover behaviour of the shared controls: the tooltip's lifetime, and the fact
// that hovering must not move anything.
//
// Both of these are bugs the project owner hit in the running app rather than
// anything a panel test would have caught, so they are asserted here on the
// controls themselves.

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumit_flutter/theme/theme.dart';
import 'package:lumit_flutter/widgets/controls.dart';

void main() {
  /// A real mouse the framework's tracker follows. `TestPointer.hover` sent
  /// straight to the binding does not update the mouse tracker, so `MouseRegion`
  /// never fires and a test using it would pass whatever the widget does.
  Future<TestGesture> mouse(WidgetTester tester) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    return gesture;
  }

  Widget host(Widget child, {bool tooltips = true}) => Directionality(
        textDirection: TextDirection.ltr,
        child: ThemeScope(
          theme: LumitTheme.dark(),
          animationLevel: AnimationLevel.none,
          showTooltips: tooltips,
          child: Overlay(
            initialEntries: [
              OverlayEntry(builder: (_) => Center(child: child))
            ],
          ),
        ),
      );

  group('Hover does not move the layout', () {
    /// A `BoxDecoration`'s border insets its child, so a border that only
    /// exists on hover makes the control 2 px bigger each way the moment the
    /// pointer touches it — and everything beside it shifts.
    testWidgets('a HouseButton is the same size hovered and not',
        (tester) async {
      await tester.pumpWidget(host(
        HouseButton(onPressed: () {}, child: const Text('Press')),
      ));
      await tester.pump();

      final button = find.byType(HouseButton);
      final before = tester.getSize(button);

      final gesture = await mouse(tester);
      await gesture.moveTo(tester.getCenter(button));
      await tester.pumpAndSettle();

      expect(tester.getSize(button), before,
          reason: 'hovering must not resize the control');
    });

    testWidgets('neighbouring controls do not shift when one is hovered',
        (tester) async {
      await tester.pumpWidget(host(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            HouseButton(onPressed: () {}, child: const Text('One')),
            HouseButton(onPressed: () {}, child: const Text('Two')),
          ],
        ),
      ));
      await tester.pump();

      final second = find.text('Two');
      final before = tester.getTopLeft(second);

      final gesture = await mouse(tester);
      await gesture.moveTo(tester.getCenter(find.text('One')));
      await tester.pumpAndSettle();

      expect(tester.getTopLeft(second), before,
          reason: 'its neighbour stayed put');
    });
  });

  group('Tooltip lifetime', () {
    testWidgets('a tooltip appears after the delay and goes on leaving',
        (tester) async {
      await tester.pumpWidget(host(
        const LumitTooltip(
          message: 'Explain this',
          child: SizedBox(width: 60, height: 20),
        ),
      ));
      await tester.pump();

      final gesture = await mouse(tester);
      await gesture.moveTo(tester.getCenter(find.byType(LumitTooltip)));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Explain this'), findsOneWidget);

      await gesture.moveTo(const Offset(5, 5));
      await tester.pump();
      expect(find.text('Explain this'), findsNothing);
    });

    /// The stuck-tooltip bug. Leaving *during* the delay used to let the tip
    /// appear anyway, after the pointer had gone — so nothing was left to
    /// dismiss it and it stayed on screen indefinitely.
    testWidgets('leaving before the delay elapses shows nothing',
        (tester) async {
      await tester.pumpWidget(host(
        const LumitTooltip(
          message: 'Explain this',
          child: SizedBox(width: 60, height: 20),
        ),
      ));
      await tester.pump();

      final gesture = await mouse(tester);
      await gesture.moveTo(tester.getCenter(find.byType(LumitTooltip)));
      // Away again well inside the 500 ms delay.
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveTo(const Offset(5, 5));

      // Past when it would have appeared, and then some.
      await tester.pump(const Duration(milliseconds: 900));
      expect(find.text('Explain this'), findsNothing,
          reason: 'a tip nobody is hovering must never appear');
    });

    testWidgets('the tooltip is off entirely when the setting is off',
        (tester) async {
      await tester.pumpWidget(host(
        const LumitTooltip(
          message: 'Explain this',
          child: SizedBox(width: 60, height: 20),
        ),
        tooltips: false,
      ));
      await tester.pump();

      final gesture = await mouse(tester);
      await gesture.moveTo(tester.getCenter(find.byType(LumitTooltip)));
      await tester.pump(const Duration(milliseconds: 900));
      expect(find.text('Explain this'), findsNothing);
    });
  });
}
