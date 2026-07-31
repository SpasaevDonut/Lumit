// The toolbar as it is mounted in the shell (K-216, docs/07 §1.7).
//
// It draws from `LumitUiState` — the armed tool, the keymap the tooltips quote,
// the workspace it rearranges — so it runs against the real engine like every
// other shell surface here. What is asserted is the gestures a toolbar lives or
// dies by: a click arms, a right-click reaches the hidden tools, and the button
// then shows the one that was picked.

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/shell/tool_bar_frb.dart';
import 'package:lumit_flutter/state/dock.dart';
import 'package:lumit_flutter/state/tools.dart';

import 'frb_test_support.dart';

void main() {
  setUpAll(initEngineForTests);

  group('Toolbar (frb)', () {
    Future<({LumitState state, LumitUiState uiState})> mount(
        WidgetTester tester) async {
      final p = freshProject();
      await tester.pumpWidget(hostPanel(
        child: const Align(
          alignment: Alignment.topLeft,
          child: LumitToolBarFrb(),
        ),
        state: p.state,
        uiState: p.uiState,
        // Wide enough that the strip is not scrolled off: the buttons are
        // pressed by key, and a widget scrolled out of view cannot be tapped.
        size: const Size(1400, 300),
      ));
      await tester.pump();
      return p;
    }

    testWidgets('every tool group has a button', (tester) async {
      await mount(tester);
      for (final group in toolBarOrder) {
        expect(find.byKey(ValueKey<String>('tool-${group.name}')), findsOneWidget,
            reason: '$group has no way to be armed');
      }
      expect(toolBarOrder.toSet(), ToolGroup.values.toSet(),
          reason: 'a tool group missing from the strip is a tool nobody can reach');
    });

    testWidgets('clicking a button arms that group', (tester) async {
      final p = await mount(tester);
      expect(p.uiState.tools.tool, ToolMode.select);

      await tester.tap(find.byKey(const ValueKey('tool-pen')));
      await tester.pump();

      expect(p.uiState.tools.tool, ToolMode.pen);
    });

    testWidgets('right-clicking opens the hidden tools, and picking one arms it'
        ' and sticks to the button', (tester) async {
      final p = await mount(tester);
      final shape = find.byKey(const ValueKey('tool-shape'));

      await tester.tapAt(tester.getCenter(shape), buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      final star = find.byKey(const ValueKey('tool-flyout-shapeStar'));
      expect(star, findsOneWidget, reason: 'the flyout lists the whole group');

      await tester.tap(star);
      await tester.pumpAndSettle();

      expect(p.uiState.tools.tool, ToolMode.shapeStar);
      expect(p.uiState.tools.memberOf(ToolGroup.shape), ToolMode.shapeStar,
          reason: 'the button now stands for the star, as AE does');
    });

    testWidgets('a single-tool group offers no flyout', (tester) async {
      await mount(tester);
      final hand = find.byKey(const ValueKey('tool-hand'));
      await tester.tapAt(tester.getCenter(hand), buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('tool-flyout-hand')), findsNothing);
    });

    testWidgets('the snapping switch toggles', (tester) async {
      final p = await mount(tester);
      expect(p.uiState.tools.snapping, isTrue);

      await tester.tap(find.byKey(const ValueKey('tool-snapping')));
      await tester.pump();

      expect(p.uiState.tools.snapping, isFalse);
    });

    testWidgets('the workspace strip rearranges the panels', (tester) async {
      final p = await mount(tester);
      expect(p.uiState.workspace.activePreset, isNull,
          reason: 'nothing is ticked until a preset is chosen');

      await tester.tap(find.byKey(const ValueKey('workspace-effects')));
      await tester.pump();

      expect(p.uiState.workspace.activePreset, WorkspacePreset.effects);
    });

    /// The tool options area (K-225): After Effects shows the settings the
    /// armed tool draws with, and nothing at all for the tools that draw
    /// nothing.
    testWidgets('the options area follows the armed tool', (tester) async {
      final p = await mount(tester);
      expect(find.text('Fill'), findsNothing,
          reason: 'the Selection tool draws nothing');

      p.uiState.tools.select(ToolMode.typeHorizontal);
      await tester.pump();
      expect(find.text('Fill'), findsOneWidget);
      expect(find.text('Stroke'), findsNothing,
          reason: 'type has a fill and a size, not a stroke');

      p.uiState.tools.select(ToolMode.shapeRectangle);
      await tester.pump();
      expect(find.text('Fill'), findsOneWidget);
      expect(find.text('Stroke'), findsOneWidget);

      p.uiState.tools.select(ToolMode.hand);
      await tester.pump();
      expect(find.text('Fill'), findsNothing);
    });

    /// A group with nothing built in it is on the strip and cannot be pressed
    /// (K-228): the gap should be visible rather than remembered.
    testWidgets('a group with nothing built cannot be armed', (tester) async {
      final p = await mount(tester);

      final roto = find.byKey(const ValueKey('tool-roto'));
      await tester.ensureVisible(roto);
      await tester.pumpAndSettle();
      await tester.tap(roto);
      await tester.pump();
      expect(p.uiState.tools.tool, ToolMode.select,
          reason: 'the Roto tools have no engine behind them yet');

      final puppet = find.byKey(const ValueKey('tool-puppet'));
      await tester.ensureVisible(puppet);
      await tester.pumpAndSettle();
      await tester.tap(puppet);
      await tester.pump();
      expect(p.uiState.tools.tool, ToolMode.select);

      // And the button offers no flyout to get in by the side door.
      await tester.tapAt(
        tester.getCenter(puppet),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tool-flyout-puppetPosition')),
          findsNothing);
    });

    testWidgets('an unbuilt member of a mixed group is listed but inert',
        (tester) async {
      final p = await mount(tester);

      final pen = find.byKey(const ValueKey('tool-pen'));
      await tester.ensureVisible(pen);
      await tester.pumpAndSettle();
      await tester.tapAt(tester.getCenter(pen), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tool-flyout-penMaskFeather')),
          findsOneWidget,
          reason: 'listed, so the gap is visible');
      expect(find.text('Not built'), findsWidgets);

      await tester.tap(find.byKey(const ValueKey('tool-flyout-penMaskFeather')));
      await tester.pumpAndSettle();
      expect(p.uiState.tools.tool, ToolMode.select,
          reason: 'and inert, so picking it does nothing');
    });

    testWidgets('the camera tools can be armed', (tester) async {
      final p = await mount(tester);
      final camera = find.byKey(const ValueKey('tool-camera'));
      await tester.ensureVisible(camera);
      await tester.pumpAndSettle();
      await tester.tap(camera);
      await tester.pump();
      expect(p.uiState.tools.tool.group, ToolGroup.camera);
    });

    testWidgets('every tool group names a chord the engine knows',
        (tester) async {
      final p = await mount(tester);
      // The tooltips teach the shortcut (docs/07 §14), and they can only teach
      // one the keymap actually carries — this is the check that the ids in
      // `toolActions` match the ones the engine ships.
      for (final entry in toolActions.entries) {
        expect(p.uiState.keymap.chordFor(entry.key), isNotNull,
            reason: '${entry.key} has no binding in the shipped keymap');
      }
    });
  }, skip: !engineAvailable);
}
