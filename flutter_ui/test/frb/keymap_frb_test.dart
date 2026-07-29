// Settings → Keymap and the reveal cycle, against the real engine
// (docs/07-UI-SPEC.md §15 and §4.3, K-199).
//
// The point of these is that the table and the keyboard are the *same* keymap.
// A settings page that edits a copy would look right in every screenshot and
// change nothing about what the keys do, which is the failure worth a test.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/panels/timeline_panel_frb.dart';
import 'package:lumit_flutter/shell/settings_window_frb.dart';
import 'package:lumit_flutter/src/rust/api/effect.dart';
import 'package:lumit_flutter/src/rust/api/keymap.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';
import 'package:lumit_flutter/widgets/controls.dart';

import 'frb_test_support.dart';

void main() {
  setUpAll(initEngineForTests);

  // Every test here edits the one session keymap, so each starts from the
  // shipped default rather than from whatever the last one left.
  setUp(() => keymapLoadPreset(preset: BridgeKeymapPreset.lumit));
  tearDownAll(() => keymapLoadPreset(preset: BridgeKeymapPreset.lumit));

  group('Settings → Keymap (frb)', () {
    Future<({LumitState state, LumitUiState uiState})> openKeymapPage(
        WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final p = freshProject();
      await tester.pumpWidget(hostPanel(
        child: Builder(
          builder: (context) => HouseButton(
            key: const ValueKey('open-settings'),
            onPressed: () => showSettingsWindowFrb(context),
            child: const Text('Open'),
          ),
        ),
        state: p.state,
        uiState: p.uiState,
      ));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('open-settings')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-page-keymap')));
      await tester.pumpAndSettle();
      return p;
    }

    /// Scroll the settings body until [finder] is built and on screen.
    ///
    /// The table is a lazy list — a few hundred rows, of which the window shows
    /// eight — so a row further down does not exist in the tree until something
    /// scrolls to it. Asserting without this tests the viewport height, not the
    /// table.
    Future<void> reveal(WidgetTester tester, Finder finder) async {
      await tester.scrollUntilVisible(
        finder,
        80,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('settings-body-keymap')),
          matching: find.byType(Scrollable),
        ).first,
      );
      await tester.pumpAndSettle();
    }

    /// The table exists, is grouped by where a binding is live, and reads in
    /// words — an action id in the left column would mean the description
    /// never made it across the seam.
    testWidgets('the table is grouped and reads in words', (tester) async {
      await openKeymapPage(tester);

      // The first group, and its first rows, are on screen as the page opens.
      expect(find.text('Anywhere'), findsOneWidget);
      expect(find.text('Play or pause'), findsOneWidget);
      // The chord cell shows the chord as this platform reads it.
      expect(find.text('Space'), findsOneWidget);
      // And no row leaks its internal name.
      expect(find.text('playback.toggle'), findsNothing);

      // Further down, the table is still grouped: the Timeline's own heading
      // and one of its rows.
      await reveal(tester, find.text('Timeline'));
      expect(find.text('Timeline'), findsOneWidget);
      await reveal(tester, find.text('Duplicate the layer'));
      expect(find.text('Duplicate the layer'), findsOneWidget);
    });

    /// K-198 gives Retime two chords deliberately. Both have to be on the row:
    /// a key that works with nothing on screen to say so is exactly what this
    /// page exists to prevent.
    testWidgets('a row with two chords shows both', (tester) async {
      await openKeymapPage(tester);
      await reveal(tester, find.text('Give the layer a Retime'));
      // One cell, both chords, joined for reading.
      expect(find.textContaining('Ctrl+Alt+T'), findsOneWidget);
      expect(find.textContaining('Alt+Shift+T'), findsOneWidget);
    });

    /// The load-bearing one: clicking a chord and pressing keys changes what
    /// the *keyboard* does, not just what the table says.
    testWidgets('rebinding a row rebinds the key itself', (tester) async {
      final p = await openKeymapPage(tester);
      expect(
        keymapLookup(context: BridgeKeyContext.global, chord: 'Mod+S'),
        'file.save',
      );

      final cell = find.byKey(
          const ValueKey('keymap-chord-global-file.save'));
      await reveal(tester, cell);
      await tester.tap(cell);
      await tester.pumpAndSettle();
      expect(find.text('Press a shortcut…'), findsOneWidget);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.f5);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.f5);
      await tester.pumpAndSettle();

      expect(
        keymapLookup(context: BridgeKeyContext.global, chord: 'F5'),
        'file.save',
        reason: 'the engine took the new chord',
      );
      expect(
        keymapLookup(context: BridgeKeyContext.global, chord: 'Mod+S'),
        isNull,
        reason: 'and the old one stopped meaning it',
      );
      // The redraw waits on a real event-loop turn: the rebind is a bridge
      // call, and its Future completes on a port message that the widget
      // tester's fake clock never delivers on its own.
      await settleFrb(
        tester,
        until: () => p.uiState.keymap.groups
            .expand((g) => g.bindings)
            .any((b) => b.action == 'file.save' && b.chords.contains('F5')),
      );
      await reveal(tester, cell);
      expect(
        find.descendant(of: cell, matching: find.text('F5')),
        findsOneWidget,
        reason: 'the table redrew with the chord the engine took',
      );
    });

    /// Reset is per row, and it has to restore *every* chord the shipped
    /// keymap gives the action — halving a two-chord row would be a quiet loss.
    testWidgets('reset puts a row back, both its chords included',
        (tester) async {
      await openKeymapPage(tester);
      final cell = find.byKey(const ValueKey(
          'keymap-chord-global-layer.retime.enable'));
      await reveal(tester, cell);
      await tester.tap(cell);
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.f6);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.f6);
      await tester.pumpAndSettle();
      expect(
        keymapLookup(context: BridgeKeyContext.global, chord: 'Alt+Shift+T'),
        isNull,
        reason: 'the rebind replaced both',
      );

      await reveal(tester, cell);
      await tester.tap(find.descendant(
        of: cell,
        matching: find.text('Reset'),
      ));
      await tester.pumpAndSettle();

      for (final chord in ['Alt+Shift+T', 'Mod+Alt+T']) {
        expect(
          keymapLookup(context: BridgeKeyContext.global, chord: chord),
          'layer.retime.enable',
          reason: '$chord came back',
        );
      }
    });

    /// A clash is not refused — it is reported, because refusing would make
    /// swapping two actions' keys impossible.
    testWidgets('taking a chord another action holds warns rather than refuses',
        (tester) async {
      // The Timeline's zoom-in takes Undo's app-wide chord: both are live in
      // the Timeline at once, so it is a clash rather than a replacement.
      //
      // Made before the page opens, and *not* awaited: a bridge Future only
      // completes on a real event-loop turn, and there is no tester to turn
      // one until a widget is pumped. The engine applies the change on the
      // call itself, which is all this needs.
      unawaited(keymapRebind(
        context: BridgeKeyContext.timeline,
        action: 'timeline.zoom.in',
        chord: 'Mod+Z',
      ));
      await openKeymapPage(tester);

      expect(find.byKey(const ValueKey('keymap-conflicts')), findsOneWidget);
      expect(find.textContaining('runs two things'), findsOneWidget);
      expect(find.textContaining('Undo'), findsWidgets,
          reason: 'the banner names what is competing');
    });

    /// The search box filters on the words the table shows, not only the ids
    /// underneath — searching for what you can see must find it.
    testWidgets('search filters the table by what it shows', (tester) async {
      await openKeymapPage(tester);
      await tester.enterText(
          find.byKey(const ValueKey('keymap-search')), 'command palette');
      await tester.pumpAndSettle();

      expect(find.text('Open the command palette'), findsOneWidget);
      expect(find.text('Play or pause'), findsNothing);
    });
  });

  group('The reveal cycle (frb)', () {
    /// `U` opens the animated groups, `UU` everything modified, `UUU` shuts the
    /// layer — the After Effects cycle (docs/07 §4.3).
    testWidgets('U, UU and UUU are three different commands', (tester) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final p = freshProject();
      final comp = p.state.project!.newComposition(name: 'Scene');
      final layer = comp.addSolidLayer();
      p.uiState
        ..setSelectedComp(comp)
        ..selectedLayer.value = layer;

      // Opacity is changed but not keyframed, so it is modified and not
      // animated — the state that tells the two reveals apart.
      layer.setTransform(
        prop: BridgeTransformProp.opacity,
        value: const BridgeScalar.static_(50),
      );
      p.state.notifyDocumentChanged();

      await tester.pumpWidget(hostPanel(
        child: const TimelinePanelFrb(),
        state: p.state,
        uiState: p.uiState,
        size: const Size(1400, 700),
      ));
      await tester.pump();

      Future<void> pressU() async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyU);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyU);
        await tester.pump();
      }

      // U: nothing is animated, so nothing opens.
      await pressU();
      expect(find.text('Transform'), findsNothing,
          reason: 'U reveals animated properties, and none are');

      // UU, inside the multi-tap window: the modified group opens.
      await pressU();
      expect(find.text('Transform'), findsOneWidget,
          reason: 'UU reveals what has been modified');

      // UUU: shut again.
      await pressU();
      expect(find.text('Transform'), findsNothing,
          reason: 'the third tap collapses the layer');
    });

    /// The taps only belong together if they are close in time. A `U` a second
    /// later is a fresh first tap, not a second one — otherwise a shortcut
    /// pressed twice a minute apart would collapse what it had just opened.
    testWidgets('a slow second press starts the cycle again', (tester) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final p = freshProject();
      final comp = p.state.project!.newComposition(name: 'Scene');
      final layer = comp.addSolidLayer();
      p.uiState
        ..setSelectedComp(comp)
        ..selectedLayer.value = layer;
      layer.setTransform(
        prop: BridgeTransformProp.opacity,
        value: const BridgeScalar.static_(50),
      );
      p.state.notifyDocumentChanged();

      await tester.pumpWidget(hostPanel(
        child: const TimelinePanelFrb(),
        state: p.state,
        uiState: p.uiState,
        size: const Size(1400, 700),
      ));
      await tester.pump();

      Future<void> pressU() async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyU);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyU);
        await tester.pump();
      }

      await pressU();
      await pressU();
      expect(find.text('Transform'), findsOneWidget, reason: 'UU opened it');

      // Past the window: this is a first tap again, and a first tap on a layer
      // with nothing animated shuts what the previous UU opened.
      await tester.pump(const Duration(milliseconds: 600));
      await pressU();
      expect(find.text('Transform'), findsNothing,
          reason: 'the cycle restarted rather than continuing to UUU');
    });
  });
}
