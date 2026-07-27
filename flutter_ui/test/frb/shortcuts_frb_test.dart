// The shell's keyboard shortcuts, against the real engine.
//
// The port dropped the previous shell's key handler entirely, so nothing on the
// keyboard did anything — space did not play, and Ctrl+Z did not undo. These
// drive `LumitAppView` itself rather than a panel, because the handler is the
// shell's and a panel-level test would not prove it is reachable.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumit_flutter/main.dart';

import 'frb_test_support.dart';

void main() {
  setUpAll(initEngineForTests);

  group('Shell shortcuts (frb)', () {
    Future<({LumitState state, LumitUiState uiState})> mount(
        WidgetTester tester) async {
      // A desktop-sized window. The whole shell is mounted here, and at the
      // 800x600 default several panel toolbars are narrower than their controls
      // and overflow — a real defect at that width, but a pre-existing one and
      // not what these tests are about (recorded in docs/TODO.md).
      tester.view.physicalSize = const Size(1800, 1100);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final p = freshProject();
      final comp = p.state.project!.newComposition(name: 'Scene');
      p.uiState.setSelectedComp(comp);
      await tester.pumpWidget(hostPanel(
        child: const LumitAppView(),
        state: p.state,
        uiState: p.uiState,
      ));
      await tester.pump();
      return p;
    }

    testWidgets('space asks the transport to toggle', (tester) async {
      final p = await mount(tester);
      var asked = 0;
      p.uiState.togglePlayRequest.addListener(() => asked++);

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(asked, 1, reason: 'space reached the transport');
    });

    testWidgets('the arrows step the playhead within the comp',
        (tester) async {
      final p = await mount(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(p.uiState.playheadFrame.value, 1);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(p.uiState.playheadFrame.value, 0);

      // A frame before the comp is not a frame.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(p.uiState.playheadFrame.value, 0);
    });

    testWidgets('Home and End go to the ends of the comp', (tester) async {
      final p = await mount(tester);
      final last = p.uiState.selectedComp!.durationFrames() - 1;

      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pump();
      expect(p.uiState.playheadFrame.value, last);

      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pump();
      expect(p.uiState.playheadFrame.value, 0);
    });

    testWidgets('Ctrl+Z undoes and Ctrl+Shift+Z redoes', (tester) async {
      final p = await mount(tester);
      final comp = p.uiState.selectedComp!;
      comp.addSolidLayer();
      expect(comp.getLayers(), hasLength(1));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.pump();
      expect(comp.getLayers(), isEmpty, reason: 'Ctrl+Z undid the layer');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(comp.getLayers(), hasLength(1), reason: 'and Ctrl+Shift+Z put it back');
    });

    testWidgets('Delete removes the selected layer, and nothing without one',
        (tester) async {
      final p = await mount(tester);
      final comp = p.uiState.selectedComp!;
      comp.addSolidLayer();

      // Nothing selected: the key must be inert rather than deleting something
      // the user did not point at.
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();
      expect(comp.getLayers(), hasLength(1));

      p.uiState.selectedLayer.value = comp.getLayers().single;
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();
      expect(comp.getLayers(), isEmpty);
      expect(p.uiState.selectedLayer.value, isNull,
          reason: 'the selection cannot outlive the layer');
    });

    /// Otherwise every letter typed into a layer name would also be a command.
    ///
    /// Driven through the Timeline's own search field, which lives inside the
    /// shell exactly as a rename field does — a field mounted *beside* the
    /// shell would not exercise the gate at all, since its keys never reach the
    /// shell's handler in the first place.
    testWidgets('a focused text field keeps its keys', (tester) async {
      final p = await mount(tester);
      var asked = 0;
      p.uiState.togglePlayRequest.addListener(() => asked++);

      final search = find.byKey(const ValueKey('tl-search'));
      expect(search, findsOneWidget, reason: 'the Timeline is in the shell');
      await tester.tap(search);
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(asked, 0,
          reason: 'the space went into the field, not the transport');

      // And once the field gives focus back, the key is a command again.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(asked, 1);
    });

    /// **The dialogue-kills-the-keyboard regression.** A modal is an *overlay*
    /// entry, so it sits outside the shell's `FocusScope` rather than inside it.
    /// A text field in one therefore takes focus out of the shell's subtree
    /// altogether, and when the entry is removed the focus it held dies with it
    /// — leaving the primary focus somewhere that is not under the shell, so the
    /// shell's key handler was never called again and *every* shortcut was dead
    /// until something inside the shell was clicked.
    ///
    /// It only became reachable when New composition grew a dialogue (K-180):
    /// make a comp, press space, nothing plays.
    testWidgets('the keyboard still works after a dialogue has been used',
        (tester) async {
      final p = await mount(tester);
      var asked = 0;
      p.uiState.togglePlayRequest.addListener(() => asked++);

      await tester.tap(find.byKey(const ValueKey<String>('menu-Composition')));
      await tester.pump();
      await tester.tap(find.text('Composition settings…'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('comp-name')), findsOneWidget);

      // Type into it, which is what moves focus into the overlay.
      await tester.tap(find.byKey(const ValueKey('comp-name')));
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey('comp-name')), 'Scene');
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('comp-apply')));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(asked, 1,
          reason: 'the shell has the keyboard back once the dialogue is gone');
    });
  }, skip: !engineAvailable);
}
