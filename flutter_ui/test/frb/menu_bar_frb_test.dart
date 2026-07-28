// The menu bar on frb, tested against the real engine.
//
// The port landed untested; this is that gap closed. There was almost nothing to
// migrate — v0's menu bar had exactly one test (Composition ▸ Add solid layer, in
// project_placement_test.dart, against a fake bridge) — so these are new
// coverage rather than a translation.
//
// Every document operation here is genuine. See frb_test_support.dart for why
// these are integration tests rather than fake-bridge unit tests, and for the
// fake-async/real-async seam `settleFrb` exists to cross.
//
// **The one ordering constraint.** `openProject` clears the engine's
// process-wide project registry, which invalidates every reference any other
// test is holding. The round-trip test that calls it is therefore last, and
// builds everything it needs within itself.

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/state/dock.dart';
import 'package:lumit_flutter/shell/menu_bar_frb.dart';
import 'package:lumit_flutter/src/rust/api/project_item.dart';
import 'package:lumit_flutter/theme/theme.dart';
import 'package:provider/provider.dart';

import 'frb_test_support.dart';

void main() {
  setUpAll(initEngineForTests);

  group('Menu bar (frb)', () {
    /// Mount the menu bar over a fresh engine-backed project, arranged the way
    /// the real shell arranges it.
    ///
    /// The `watch` pair is load-bearing and deliberately mirrors
    /// `_LumitAppViewState` in main.dart: `LumitMenuBarFrb` takes its project as
    /// a constructor argument and reads `LumitUiState` with `context.read`, so it
    /// does not subscribe to either notifier itself — an ancestor that watches
    /// both is what makes Undo/Redo and Composition settings grey and ungrey.
    /// Mounting it bare would test an arrangement that does not ship.
    Future<({LumitState state, LumitUiState uiState})> mount(
      WidgetTester tester, {
      Future<String?> Function()? openPicker,
      Future<String?> Function()? savePicker,
      Future<List<String>> Function()? footagePicker,
    }) async {
      final p = freshProject();
      await tester.pumpWidget(hostPanel(
        child: Builder(builder: (context) {
          final state = context.watch<LumitState>();
          context.watch<LumitUiState>();
          return LumitMenuBarFrb(
            app: state,
            openPicker: openPicker,
            savePicker: savePicker,
            footagePicker: footagePicker,
          );
        }),
        state: p.state,
        uiState: p.uiState,
      ));
      await tester.pump();
      return p;
    }

    /// Open a top-level menu and tap one of its rows.
    ///
    /// Two pumps rather than `pumpAndSettle`: the popup is an overlay entry and
    /// the host disables animation, so one frame each is enough — and
    /// `pumpAndSettle` would spin on anything the engine has left in flight.
    /// Open a menu and pick a row, scrolling to it first.
    ///
    /// The Composition menu is taller than an 800x600 test surface, so it
    /// scrolls — and a row below the fold has to be brought into view before it
    /// can be tapped, which is what a user does with the wheel.
    /// Open [menu] and click [item]. [under] names a submenu to step through
    /// first — Window → Workspaces → Audio (K-194).
    Future<void> choose(WidgetTester tester, String menu, String item,
        {String? under}) async {
      await tester.tap(find.byKey(ValueKey<String>('menu-$menu')));
      await tester.pump();
      if (under != null) {
        await tester.tap(find.text(under));
        await tester.pump();
      }
      await tester.ensureVisible(find.text(item));
      await tester.pump();
      await tester.tap(find.text(item));
      await tester.pump();
    }

    /// New composition asks for its settings first (K-180), so every route to a
    /// comp goes through the dialogue: choose the command, then press Create.
    Future<void> makeComp(WidgetTester tester) async {
      await choose(tester, 'Composition', 'New composition');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('comp-apply')));
      await tester.pumpAndSettle();
    }

    /// Dismiss an open menu through its full-screen barrier, without choosing
    /// anything.
    /// Well below the menus, and inside the 800x600 test surface — a tap outside
    /// it is not delivered at all, so the menu would silently stay open.
    Future<void> dismiss(WidgetTester tester) async {
      await tester.tapAt(const Offset(400, 500));
      await tester.pump();
    }

    /// Every item in the project, folders flattened — a composition is filed
    /// into the Compositions auto-folder, so it is never one of the roots.
    List<ItemReference> allItems(LumitState state) {
      List<ItemReference> walk(List<ItemReference> items) => [
            for (final i in items) ...[
              i,
              if (i is ItemReference_Folder) ...walk(i.field0.getChildren()),
            ]
          ];
      return walk(state.project?.getItems() ?? const []);
    }

    testWidgets('File shows its items', (tester) async {
      await mount(tester);
      await tester.tap(find.byKey(const ValueKey<String>('menu-File')));
      await tester.pump();

      for (final item in [
        'New project',
        'Open project…',
        'Save',
        'Save as…',
        'Import footage…',
      ]) {
        expect(find.text(item), findsOneWidget, reason: 'File ▸ $item');
      }
      await dismiss(tester);
      expect(find.text('New project'), findsNothing,
          reason: 'the barrier closes the menu without choosing anything');
    });

    testWidgets('Edit and Composition show their items', (tester) async {
      await mount(tester);

      await tester.tap(find.byKey(const ValueKey<String>('menu-Edit')));
      await tester.pump();
      expect(find.text('Undo'), findsOneWidget);
      expect(find.text('Redo'), findsOneWidget);
      await dismiss(tester);

      await tester.tap(find.byKey(const ValueKey<String>('menu-Composition')));
      await tester.pump();
      expect(find.text('New composition'), findsOneWidget);
      expect(find.text('Composition settings…'), findsOneWidget);
    });

    testWidgets('New composition creates one, fronts it, and names it for you',
        (tester) async {
      final p = await mount(tester);
      expect(p.uiState.selectedComp, isNull);

      await makeComp(tester);

      final comps = allItems(p.state).whereType<ItemReference_Composition>();
      expect(comps.length, 1, reason: 'the menu committed one composition');
      expect(
        p.uiState.selectedComp?.internalid,
        comps.single.field0.internalid,
        reason: 'a comp you just made is the one you want to work on',
      );
      // A blank name is passed through so the engine picks the next "Comp N".
      expect(comps.single.name(), 'Comp 1');
    });

    testWidgets('Composition settings… is disabled until a comp is fronted',
        (tester) async {
      final p = await mount(tester);

      await choose(tester, 'Composition', 'Composition settings…');
      expect(find.text('Composition settings'), findsNothing,
          reason: 'no comp is fronted, so the row does nothing when pressed');

      // Front one, and the same row now opens the dialogue.
      await makeComp(tester);
      expect(p.uiState.selectedComp, isNotNull);
      await choose(tester, 'Composition', 'Composition settings…');
      await tester.pump();

      expect(find.text('Composition settings'), findsOneWidget,
          reason: 'the dialogue heading');
    });

    testWidgets('Import footage imports every picked path', (tester) async {
      final p = await mount(
        tester,
        footagePicker: () async => ['C:/clips/a.mov', 'C:/clips/b.mov'],
      );

      await choose(tester, 'File', 'Import footage…');
      await tester.pump();

      final names = allItems(p.state)
          .whereType<ItemReference_Footage>()
          .map((f) => f.name())
          .toList();
      expect(names, containsAll(<String>['a.mov', 'b.mov']));
    });

    testWidgets('a cancelled picker changes nothing', (tester) async {
      final p = await mount(
        tester,
        footagePicker: () async => <String>[],
        savePicker: () async => null,
      );

      await choose(tester, 'File', 'Import footage…');
      await tester.pump();
      expect(p.state.project!.getItems(), isEmpty);

      await choose(tester, 'File', 'Save');
      await settleFrb(tester);
      expect(p.state.project!.path(), isNull,
          reason: 'cancelling the location dialogue must not write anything');
    });

    testWidgets('Undo and Redo grey out with the document history',
        (tester) async {
      final p = await mount(tester);
      final t = LumitTheme.forScheme(LumitColorScheme.dark, ThemeShape.sharp);

      Color? colourOf(String label) =>
          tester.widget<Text>(find.text(label)).style?.color;

      // A fresh document has nothing either way.
      await tester.tap(find.byKey(const ValueKey<String>('menu-Edit')));
      await tester.pump();
      expect(colourOf('Undo'), t.textDisabled);
      expect(colourOf('Redo'), t.textDisabled);
      await dismiss(tester);

      // One edit, and Undo lights up.
      await makeComp(tester);
      expect(p.state.project!.history().canUndo, isTrue);

      await tester.tap(find.byKey(const ValueKey<String>('menu-Edit')));
      await tester.pump();
      expect(colourOf('Undo'), isNot(t.textDisabled),
          reason:
              'an item you can see is disabled tells you the document state');
      await tester.tap(find.text('Undo'));
      await tester.pump();

      expect(p.state.project!.getItems(), isEmpty,
          reason: 'Undo reached the engine, not just the menu');
      expect(p.state.project!.history().canRedo, isTrue);

      // Undone: the pair swaps over.
      await tester.tap(find.byKey(const ValueKey<String>('menu-Edit')));
      await tester.pump();
      expect(colourOf('Undo'), t.textDisabled);
      expect(colourOf('Redo'), isNot(t.textDisabled));
      await tester.tap(find.text('Redo'));
      await tester.pump();

      expect(allItems(p.state).whereType<ItemReference_Composition>().length, 1,
          reason: 'Redo put it back');
    });

    testWidgets(
        'Save prompts once, then saves in place; Save as always prompts',
        (tester) async {
      final dir = Directory.systemTemp.createTempSync('lumit-menu-save');
      final first = '${dir.path}/first.lum';
      final second = '${dir.path}/second.lum';

      var prompts = 0;
      final picks = <String>[first, second];
      final p = await mount(
        tester,
        savePicker: () async {
          prompts++;
          return picks.removeAt(0);
        },
      );
      await makeComp(tester);

      // Never saved: Save has to ask where.
      await choose(tester, 'File', 'Save');
      await settleFrb(tester, until: () => File(first).existsSync());
      expect(prompts, 1);
      expect(File(first).existsSync(), isTrue);
      expect(p.state.project!.path(), first);

      // Saved once: Save now writes in place without asking again.
      await choose(tester, 'File', 'Save');
      await settleFrb(tester);
      expect(prompts, 1,
          reason: 'a project with a path is saved, not asked about');

      // Save as asks every time, and moves the project to the new location.
      await choose(tester, 'File', 'Save as…');
      await settleFrb(tester, until: () => File(second).existsSync());
      expect(prompts, 2);
      expect(File(second).existsSync(), isTrue);
      expect(p.state.project!.path(), second);
    });

    // LAST: `openProject` clears the engine's project registry, so every
    // reference held by an earlier test dies here. Nothing may run after it.
    testWidgets('a saved project opens again with its contents intact',
        (tester) async {
      final dir = Directory.systemTemp.createTempSync('lumit-menu-roundtrip');
      final path = '${dir.path}/round.lum';

      final p = await mount(
        tester,
        savePicker: () async => path,
        openPicker: () async => path,
        footagePicker: () async => ['C:/clips/hero.mov'],
      );
      await makeComp(tester);
      await choose(tester, 'File', 'Import footage…');
      await tester.pump();
      await choose(tester, 'File', 'Save');
      await settleFrb(tester, until: () => File(path).existsSync());
      expect(File(path).existsSync(), isTrue,
          reason: 'nothing to open otherwise');

      // A new, empty project, then open the saved one over the top of it.
      await choose(tester, 'File', 'New project');
      await tester.pump();
      expect(p.state.project!.getItems(), isEmpty);

      await choose(tester, 'File', 'Open project…');
      await tester.pump();

      final names = allItems(p.state).map((i) => i.name()).toList();
      expect(names, contains('hero.mov'));
      expect(names, contains('Comp 1'),
          reason: 'the composition came back, filed where it was');
    });
    // Without the built library there is nothing to test against; the harness
    // throws with the command to run.
    /// The port shipped a menu with three items per menu where the previous
    /// frontend had layer creation, clip and marker commands, beat detection
    /// and a Window menu. Each of these reaches the document.
    testWidgets('Composition creates every kind of layer', (tester) async {
      final p = await mount(tester);
      await makeComp(tester);
      final comp = p.uiState.selectedComp!;

      for (final item in [
        'Add solid layer',
        'Add text layer',
        'Add camera layer',
        'Add adjustment layer',
        'Add sequence layer',
      ]) {
        final before = comp.getLayers().length;
        await choose(tester, 'Composition', item);
        await tester.pump();
        expect(comp.getLayers(), hasLength(before + 1),
            reason: '$item added one');
      }
    });

    testWidgets('the layer items are disabled without a composition',
        (tester) async {
      final p = await mount(tester);
      expect(p.uiState.selectedComp, isNull);

      // Pressing it must be a no-op rather than a crash — a disabled row that
      // throws when clicked is worse than one that is simply absent.
      await choose(tester, 'Composition', 'Add solid layer');
      await tester.pump();
      expect(p.uiState.selectedComp, isNull);
    });

    testWidgets('Add marker at playhead marks the fronted comp',
        (tester) async {
      final p = await mount(tester);
      await makeComp(tester);
      final comp = p.uiState.selectedComp!;
      p.uiState.playheadFrame.value = 30;

      await choose(tester, 'Composition', 'Add marker at playhead');
      await tester.pump();

      expect(comp.getMarkers(), hasLength(1));
      expect(comp.frameAtTime(time: comp.getMarkers().single.time), 30,
          reason: 'it landed on the playhead, not at zero');
    });

    testWidgets('Clear beat markers is calm on a comp with none',
        (tester) async {
      final p = await mount(tester);
      await makeComp(tester);
      await choose(tester, 'Composition', 'Clear beat markers');
      await tester.pump();
      expect(p.uiState.selectedComp!.getMarkers(), isEmpty);
    });

    /// The palette's four categories (docs/07 §12): commands, and now every
    /// effect, comp and panel under its own badge; Enter on each does its
    /// kind of thing. The taught shortcut shows only where a real binding
    /// exists.
    testWidgets('the palette carries effects, comps and panels',
        (tester) async {
      final p = await mount(tester);
      final comp = p.state.project!.newComposition(name: 'Scene beta');
      final layer = comp.addSolidLayer();
      p.uiState
        ..setSelectedComp(comp)
        ..selectedLayer.value = layer;
      await tester.pump();

      await choose(tester, 'Window', 'Command palette…');
      await tester.pump();

      // Each category surfaces under its badge when searched for (the list
      // is lazy, so the badges are asserted where their rows are on screen).
      final query = find.byKey(const ValueKey('palette-query'));
      await tester.enterText(query, 'timeline');
      await tester.pump();
      expect(find.text('Panel'), findsWidgets);

      await tester.enterText(query, 'undo');
      await tester.pump();
      expect(find.text('Ctrl+Z'), findsOneWidget,
          reason: 'undo teaches its real shortcut, and only real ones taught');

      // An effect entry applies to the selected layer.
      await tester.enterText(query, 'gaussian');
      await tester.pump();
      expect(find.text('Effect'), findsWidgets);
      await tester
          .tap(find.byKey(const ValueKey('palette-item-Gaussian blur')));
      await tester.pumpAndSettle();
      expect(layer.getEffects().single.name(), 'blur');

      // A comp entry fronts its comp; the recent run ranks it first next time.
      await choose(tester, 'Window', 'Command palette…');
      await tester.pump();
      await tester.enterText(
          find.byKey(const ValueKey('palette-query')), 'scene beta');
      await tester.pump();
      expect(find.text('Comp'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('palette-item-Scene beta')));
      await tester.pumpAndSettle();
      expect(p.uiState.selectedComp?.internalid, comp.internalid);
    });

    /// The four shipped workspace presets (docs/07 §1.6): each rearranges the
    /// dock to its factory layout; the same panel inventory throughout, and a
    /// distinct arrangement per preset.
    testWidgets('the Window menu applies the four workspace presets',
        (tester) async {
      final p = await mount(tester);

      // The presets live under their own heading now (K-194).
      await choose(tester, 'Window', 'Effects', under: 'Workspaces');
      await tester.pump();
      expect(panelsIn(p.uiState.split),
          panelsIn(presetLayout(WorkspacePreset.effects)));
      expect(p.uiState.split.toJson(),
          isNot(presetLayout(WorkspacePreset.colour).toJson()),
          reason: 'the presets are genuinely different arrangements');

      await choose(tester, 'Window', 'Audio', under: 'Workspaces');
      await tester.pump();
      expect(p.uiState.split.toJson(),
          presetLayout(WorkspacePreset.audio).toJson());

      // Reset still means the default (Edit) arrangement.
      await choose(tester, 'Window', 'Reset workspace', under: 'Workspaces');
      await tester.pump();
      expect(panelsIn(p.uiState.split), panelsIn(defaultLayout()));
    });

    testWidgets('the Window menu offers the palette, reset and settings',
        (tester) async {
      final p = await mount(tester);

      await tester.tap(find.byKey(const ValueKey<String>('menu-Window')));
      await tester.pump();
      expect(find.text('Command palette…'), findsOneWidget);
      expect(find.text('Settings…'), findsOneWidget);
      // The arrangements sit behind their own heading now (K-194), so the
      // Window menu is four rows rather than eight.
      expect(find.text('Workspaces'), findsOneWidget);
      expect(find.text('Reset workspace'), findsNothing,
          reason: 'reset lives with the arrangements it undoes');
      await dismiss(tester);

      // Reset puts a rearranged workspace back to the default.
      p.uiState.workspace.dock = DockSplit(
        DockAxis.vertical,
        [DockPane(Panel.viewer), DockPane(Panel.timeline)],
        [0.5, 0.5],
      );
      await choose(tester, 'Window', 'Reset workspace', under: 'Workspaces');
      await tester.pump();
      expect(panelsIn(p.uiState.split), panelsIn(defaultLayout()),
          reason: 'the default arrangement is back');
    });
  }, skip: !engineAvailable);
}
