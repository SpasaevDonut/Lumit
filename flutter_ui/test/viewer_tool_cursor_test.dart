// The drawn pointers (K-226): the brush ring's size, and that each tool badges
// its own icon.
//
// The ring is the part with arithmetic in it — a brush width is in *picture*
// pixels and the ring is drawn on *screen*, so the magnification has to come
// into it — and the part that would be wrong silently.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumit_flutter/panels/viewer_tool_cursor.dart';
import 'package:lumit_flutter/shell/tool_bar_frb.dart';
import 'package:lumit_flutter/state/tools.dart';
import 'package:lumit_flutter/theme/theme.dart';
import 'package:lumit_flutter/widgets/controls.dart';

void main() {
  /// **Which pointers the Viewer asks the platform for, and which it draws
  /// itself (K-230).** Windows has no grab and no magnifier; Flutter will
  /// happily be asked for them and the embedder quietly hands back the ordinary
  /// arrow, which is how the Hand and Zoom tools came to look like no tool at
  /// all. Anything drawn must therefore hide the system pointer rather than
  /// name one.
  group('The pointer a tool wears over the picture', () {
    test('the Hand and the Zoom draw their own, so they hide the system one',
        () {
      expect(viewerCursorFor(ToolMode.hand), SystemMouseCursors.none);
      expect(viewerCursorFor(ToolMode.zoom), SystemMouseCursors.none);
    });

    test('the Razor takes the ordinary arrow: it cuts in the Timeline', () {
      expect(viewerCursorFor(ToolMode.razor), SystemMouseCursors.basic);
    });

    test('the tools that aim at a pixel keep the crosshair', () {
      expect(viewerCursorFor(ToolMode.shapeEllipse), SystemMouseCursors.precise);
      expect(viewerCursorFor(ToolMode.pen), SystemMouseCursors.precise);
    });
  });

  group('The brush ring', () {
    test('is the stroke it would leave, at this magnification', () {
      // A 40px brush at 1:1 is a 20px radius; at half size, 10.
      expect(brushRingRadius(40, 1), 20);
      expect(brushRingRadius(40, 0.5), 10);
      expect(brushRingRadius(40, 2), 40);
    });

    test('stays visible however small, and on screen however large', () {
      expect(brushRingRadius(1, 0.01), minBrushRingRadius,
          reason: 'a ring you cannot see is not a pointer');
      expect(brushRingRadius(1000, 8), maxBrushRingRadius,
          reason: 'the ring is a pointer, not the stroke itself');
    });
  });

  group('The badge', () {
    Widget host(Widget child) => Directionality(
          textDirection: TextDirection.ltr,
          child: ThemeScope(
            theme: LumitTheme.dark(),
            animationLevel: AnimationLevel.all,
            showTooltips: true,
            child: Stack(children: [child]),
          ),
        );

    testWidgets('is the armed tool\'s own icon, twice over for legibility',
        (tester) async {
      await tester.pumpWidget(host(ToolPointer(
        at: const Offset(30, 40),
        tool: ToolMode.shapeEllipse,
        mark: const Color(0xffffffff),
        outline: const Color(0xff000000),
      )));

      // Two copies: the halo behind and the ink in front.
      expect(
        find.byWidgetPredicate((w) => w is CustomPaint || w is Icon),
        findsWidgets,
      );
      final positioned = tester.widgetList<Positioned>(find.byType(Positioned));
      expect(
        positioned.any((p) =>
            p.left == 30 + toolBadgeOffset.dx &&
            p.top == 40 + toolBadgeOffset.dy),
        isTrue,
        reason: 'the badge sits down and to the right of the pointer',
      );
    });

    testWidgets('a pointer that has left the picture draws nothing',
        (tester) async {
      await tester.pumpWidget(host(const ToolPointer(
        at: null,
        tool: ToolMode.pen,
        mark: Color(0xffffffff),
        outline: Color(0xff000000),
      )));
      expect(find.byType(Positioned), findsNothing);
    });
  });
}
