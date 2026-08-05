// The render-time column as a user meets it: the stopwatch in its header has to
// be reachable, and the numbers have to land on the rows.
//
// **Why this is a test and not an assumption.** The header cell lives inside the
// column-group `Draggable`/`DragTarget` that reorders the outline's clusters, so
// "does a tap on it reach the switch?" is a real question with a real way to be
// wrong — and if the answer were no, the column would look exactly like a
// feature that does not work: a header, a row per layer, and nothing in them
// ever (which is how it was reported).

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/panels/timeline_panel_frb.dart';
import 'package:lumit_flutter/panels/timeline_timings.dart';
import 'package:lumit_flutter/src/rust/api/state.dart';

import 'frb_test_support.dart';

void main() {
  setUpAll(initEngineForTests);

  group('The Timeline render-time column (frb)', () {
    ({LumitState state, LumitUiState uiState, String layerId}) withLayer() {
      final p = freshProject();
      final comp = p.state.project!.newComposition(name: 'Scene');
      comp.addSolidLayer();
      p.uiState.setSelectedComp(comp);
      return (
        state: p.state,
        uiState: p.uiState,
        layerId: comp.getLayers().single.internallayerId.toString(),
      );
    }

    Future<void> mount(WidgetTester tester,
        ({LumitState state, LumitUiState uiState, String layerId}) p) async {
      // A window wide enough to hold the whole outline: the render-time column
      // is its rightmost, and the test is about reaching it rather than about
      // what a narrow window hides.
      tester.view.physicalSize = const Size(1600, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(hostPanel(
        state: p.state,
        uiState: p.uiState,
        size: const Size(1600, 700),
        child: const TimelinePanelFrb(),
      ));
      await tester.pump();
      await settleFrb(tester, minRounds: 6);
    }

    testWidgets('the stopwatch in the header turns measuring on and off',
        (tester) async {
      final p = withLayer();
      await mount(tester, p);

      expect(p.uiState.renderTimings.measuring, isFalse,
          reason: 'nothing is measured until it is asked for');

      // The header cell sits inside the column-group Draggable; a tap must
      // still reach it.
      await tester.tap(find.byType(TimingsHeaderCell));
      await tester.pump();
      expect(p.uiState.renderTimings.measuring, isTrue);

      await tester.tap(find.byType(TimingsHeaderCell));
      await tester.pump();
      expect(p.uiState.renderTimings.measuring, isFalse);
      // Leave the engine as it was found.
      await settleFrb(tester, minRounds: 4);
    });

    /// **How the column was reported broken.** Idle, it drew nothing at all, so
    /// a header called Time over a row per layer and nothing in any of them
    /// looked exactly like a feature that did not work — and the switch was a
    /// glyph in the header nobody had reason to press. An idle cell now shows a
    /// dimmed dash and starts measuring when it is clicked, so the column is
    /// its own switch wherever the user reaches for it.
    testWidgets('an idle column shows dashes, and a click on one starts it',
        (tester) async {
      final p = withLayer();
      await mount(tester, p);

      expect(p.uiState.renderTimings.measuring, isFalse);
      expect(find.descendant(of: find.byType(TimingsCell), matching: find.text('—')),
          findsWidgets, reason: 'idle reads as "no numbers", not as blank');

      await tester.tap(find.byType(TimingsCell).first);
      await tester.pump();
      expect(p.uiState.renderTimings.measuring, isTrue);
      p.uiState.renderTimings.setMeasuring(false);
      await settleFrb(tester, minRounds: 4);
    });

    testWidgets('a measured frame puts its number on the layer row',
        (tester) async {
      final p = withLayer();
      await mount(tester, p);

      await tester.tap(find.byType(TimingsHeaderCell));
      await tester.pump();

      // The engine's own answer arrives on the worker stream; this test is
      // about the *row*, so it feeds the read model directly with the shape
      // the engine sends (render_timings_frb_test.dart pins that the engine
      // really sends it, and with these ids).
      p.uiState.renderTimings.report(BridgeFrameProfile(
        frame: BigInt.zero,
        totalMs: 12.5,
        layers: [
          BridgeLayerTiming(layer: p.layerId, ms: 8.5, effects: const []),
        ],
      ));
      await tester.pump();

      expect(find.text('8.5 ms'), findsOneWidget,
          reason: 'the layer row shows what its picture cost');

      p.uiState.renderTimings.setMeasuring(false);
      await tester.pump();
      expect(find.text('8.5 ms'), findsNothing,
          reason: 'and stops showing a cost nothing is measuring any more');
      await settleFrb(tester, minRounds: 4);
    });
  });
}
