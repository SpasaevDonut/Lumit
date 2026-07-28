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

    /// **The recurring space-bar funeral.** Menus, popups and the palette all
    /// live in the Overlay outside the shell's focus scope; any of them could
    /// walk focus away for good, and every shortcut died until something was
    /// clicked. Shortcuts are global now — they work with focus parked
    /// nowhere at all, which is exactly the broken state this reproduces.
    testWidgets('space still toggles when focus has wandered off',
        (tester) async {
      final p = await mount(tester);
      var asked = 0;
      p.uiState.togglePlayRequest.addListener(() => asked++);

      // The broken state: nothing in the app holds focus.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(asked, 1,
          reason: 'shortcuts must not depend on where focus is sitting');
    });

    testWidgets('the arrows step the playhead within the comp', (tester) async {
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
      expect(comp.getLayers(), hasLength(1),
          reason: 'and Ctrl+Shift+Z put it back');
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

    /// Alt+Shift+T gives the selected layer a Retime — and takes it away again
    /// (K-197). Off is the property gone, not a 100% curve left behind.
    testWidgets('Alt+Shift+T toggles the selected layer\'s Retime',
        (tester) async {
      final p = await mount(tester);
      final comp = p.uiState.selectedComp!;
      comp.addSolidLayer();
      final layer = comp.getLayers().single;

      Future<void> press() async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
        await tester.pump();
      }

      // Nothing selected: inert, like every other layer command.
      await press();
      expect(layer.getRetimeProperty(), isNull);

      p.uiState.selectedLayer.value = layer;
      await press();
      expect(layer.getRetimeProperty(), isNotNull,
          reason: 'the layer now has a Retime to key');

      await press();
      expect(layer.getRetimeProperty(), isNull,
          reason: 'off removes it rather than flattening it');
    });

    /// **Ctrl+Alt+T does the same, and on Windows it is the one that lands.**
    /// Left Alt with Shift is the system's input-language switch there: with a
    /// second keyboard layout installed the OS takes the chord and the
    /// application never sees the T, so the spec's own shortcut silently does
    /// nothing on the machines most likely to have two layouts. This is After
    /// Effects' own Time Remap chord, and nothing intercepts it.
    testWidgets('Ctrl+Alt+T toggles Retime as well', (tester) async {
      final p = await mount(tester);
      final comp = p.uiState.selectedComp!;
      comp.addSolidLayer();
      final layer = comp.getLayers().single;
      p.uiState.selectedLayer.value = layer;

      Future<void> press() async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
      }

      await press();
      expect(layer.getRetimeProperty(), isNotNull);
      await press();
      expect(layer.getRetimeProperty(), isNull);
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
