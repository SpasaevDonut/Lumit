// The Project panel on frb, tested against the real engine.
//
// These are the ported equivalents of the 12 v0 tests that lived in
// project_placement_test.dart, section_d_test.dart and final_sweep_test.dart,
// plus coverage for three things v0 never asserted at all: the folder tree, the
// per-depth indent, and the row keys.
//
// Every document operation here is genuine — see frb_test_support.dart for why
// these are integration tests rather than fake-bridge unit tests.

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumit_flutter/panels/project_panel_frb.dart';
import 'package:lumit_flutter/state/app_state.dart' show FootageDragData;

import 'frb_test_support.dart';

/// Why the two status-dependent tests are skipped.
///
/// `FootageReference.getStatus` is an async frb call. Async frb calls complete
/// fine in a plain `test()` — verified — but not inside the fake-async zone
/// `testWidgets` runs in, even wrapped in `runAsync`. So the row never learns its
/// file is missing, and the relink case waits out its timeout rather than failing.
/// The behaviour itself is covered on the Rust side by
/// `a_footage_item_pointing_at_nothing_reports_missing` and
/// `relink_does_not_deadlock_against_its_own_read`; what is missing is the widget
/// half. Tracked in docs/TODO.md.
/// `testWidgets` takes a bool, not a reason string, so the reason lives above.
const _asyncStatusSkip = false;

void main() {
  setUpAll(initEngineForTests);

  group('Project panel (frb)', () {
    testWidgets('an empty project shows the quiet hint', (tester) async {
      final p = freshProject();
      await tester.pumpWidget(
        hostPanel(
          child: const ProjectPanelFrb(),
          state: p.state,
          uiState: p.uiState,
        ),
      );
      await tester.pump();

      expect(
        find.textContaining('No items yet'),
        findsOneWidget,
        reason: 'an empty document must say so rather than showing nothing',
      );
    });

    testWidgets('items appear as rows, each with a stable key', (tester) async {
      final p = freshProject();
      final comp = p.state.project!.newComposition(name: 'Scene');
      final footage = p.state.project!.importFootage(path: 'C:/clips/shot.mov');

      await tester.pumpWidget(hostPanel(
        child: const ProjectPanelFrb(),
        state: p.state,
        uiState: p.uiState,
      ));
      await tester.pump();

      expect(find.text('Scene'), findsOneWidget);
      expect(find.text('shot.mov'), findsOneWidget);
      // The auto-folder a new composition is filed into.
      expect(find.text('Compositions'), findsOneWidget);

      expect(
        find.byKey(ValueKey<String>('project-row-${comp.internalid}')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey<String>('project-row-${footage.internalid}')),
        findsOneWidget,
      );
    });

    /// v0 never tested nesting at all — its `walk` had no assertions. A new
    /// composition is filed into the Compositions auto-folder, so it must appear
    /// once, indented one level, not twice and not at the root.
    testWidgets('a folder nests its children, indented one level per depth',
        (tester) async {
      final p = freshProject();
      final comp = p.state.project!.newComposition(name: 'Scene');

      await tester.pumpWidget(hostPanel(
        child: const ProjectPanelFrb(),
        state: p.state,
        uiState: p.uiState,
      ));
      await tester.pump();

      expect(find.text('Scene'), findsOneWidget,
          reason: 'a filed comp is drawn once, under its folder — not twice');

      // The folder sits at depth 0, the comp inside it at depth 1.
      final folderRow = find.ancestor(
        of: find.text('Compositions'),
        matching: find.byType(Container),
      );
      final compRow = find.byKey(ValueKey<String>('project-row-${comp.internalid}'));
      final folderLeft = tester.getTopLeft(find.text('Compositions')).dx;
      final compLeft = tester.getTopLeft(find.text('Scene')).dx;
      expect(folderRow, findsWidgets);
      expect(compRow, findsOneWidget);
      expect(
        compLeft - folderLeft,
        closeTo(14, 0.01),
        reason: 'one nesting level indents by 14px',
      );
    });

    testWidgets('clicking a row selects it, and a second click renames in place',
        (tester) async {
      final p = freshProject();
      p.state.project!.importFootage(path: 'C:/clips/shot.mov');

      await tester.pumpWidget(hostPanel(
        child: const ProjectPanelFrb(),
        state: p.state,
        uiState: p.uiState,
      ));
      await tester.pump();

      // First click selects; the second (well outside the double-tap window)
      // starts the rename.
      await tapAgain(tester, find.text('shot.mov'));
      expect(find.byKey(const ValueKey('rename-field')), findsOneWidget);

      await tester.enterText(find.byType(EditableText), 'Intro');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(find.text('Intro'), findsOneWidget);
      expect(find.text('shot.mov'), findsNothing,
          reason: 'the rename reached the document, not just the field');
    });

    testWidgets('a blank rename is refused and the old name survives',
        (tester) async {
      final p = freshProject();
      p.state.project!.importFootage(path: 'C:/clips/shot.mov');

      await tester.pumpWidget(hostPanel(
        child: const ProjectPanelFrb(),
        state: p.state,
        uiState: p.uiState,
      ));
      await tester.pump();

      await tapAgain(tester, find.text('shot.mov'));
      await tester.enterText(find.byType(EditableText), '   ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(find.text('shot.mov'), findsOneWidget,
          reason: 'a row must never be able to lose its label');
    });

    testWidgets('double-clicking a composition fronts it', (tester) async {
      final p = freshProject();
      final comp = p.state.project!.newComposition(name: 'Scene');

      await tester.pumpWidget(hostPanel(
        child: const ProjectPanelFrb(),
        state: p.state,
        uiState: p.uiState,
      ));
      await tester.pump();

      expect(p.uiState.selectedComp, isNull);
      await _doubleTap(tester, find.text('Scene'));

      expect(p.uiState.selectedComp?.internalid, comp.internalid);
    });

    testWidgets('double-clicking footage places it into the front comp',
        (tester) async {
      final p = freshProject();
      final comp = p.state.project!.newComposition(name: 'Scene');
      p.state.project!.importFootage(path: 'C:/clips/shot.mov');
      p.uiState.setSelectedComp(comp);

      await tester.pumpWidget(hostPanel(
        child: const ProjectPanelFrb(),
        state: p.state,
        uiState: p.uiState,
      ));
      await tester.pump();

      expect(comp.getLayers(), isEmpty);
      await _doubleTap(tester, find.text('shot.mov'));

      final layers = comp.getLayers();
      expect(layers, hasLength(1));
      expect(layers.first.getName(), 'shot.mov');
    });

    testWidgets('footage rows are draggable, carrying FootageDragData',
        (tester) async {
      final p = freshProject();
      p.state.project!.importFootage(path: 'C:/clips/shot.mov');

      await tester.pumpWidget(hostPanel(
        child: const ProjectPanelFrb(),
        state: p.state,
        uiState: p.uiState,
      ));
      await tester.pump();

      // The Timeline's drop target consumes exactly this type and nothing else
      // produces it, so the payload type is load-bearing.
      expect(find.byType(Draggable<FootageDragData>), findsOneWidget);
    });

    testWidgets('the context menu deletes an item', (tester) async {
      final p = freshProject();
      p.state.project!.importFootage(path: 'C:/clips/shot.mov');

      await tester.pumpWidget(hostPanel(
        child: const ProjectPanelFrb(),
        state: p.state,
        uiState: p.uiState,
      ));
      await tester.pump();

      await tester.tapAt(
        tester.getCenter(find.text('shot.mov')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();

      expect(find.text('Move to root'), findsOneWidget);
      expect(find.text('Find missing footage'), findsOneWidget);

      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(find.text('shot.mov'), findsNothing);
      expect(p.state.project!.getItems(), isEmpty);
    });

    testWidgets('the context menu moves a filed item back to the root',
        (tester) async {
      final p = freshProject();
      p.state.project!.newComposition(name: 'Scene');

      await tester.pumpWidget(hostPanel(
        child: const ProjectPanelFrb(),
        state: p.state,
        uiState: p.uiState,
      ));
      await tester.pump();

      // 'Scene' starts filed inside Compositions, so it is indented.
      final indentedBefore = tester.getTopLeft(find.text('Scene')).dx;

      await tester.tapAt(
        tester.getCenter(find.text('Scene')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move to root'));
      await tester.pumpAndSettle();

      expect(
        tester.getTopLeft(find.text('Scene')).dx,
        lessThan(indentedBefore),
        reason: 'unfiled, so it is no longer indented under the folder',
      );
      expect(find.text('Scene'), findsOneWidget, reason: 'moved, not deleted');
    });

    /// Missing-media rows and the filter. The imported path does not exist, so the
    /// engine's probe genuinely fails — no fake status is injected anywhere.
    testWidgets('missing footage wears a badge, a Relink button, and can be '
        'filtered to', (tester) async {
      final p = freshProject();
      p.state.project!.newComposition(name: 'Scene');
      final gone = p.state.project!.importFootage(path: 'C:/nowhere/gone.mp4');

      // `runAsync` because the status probe is a real FFI call: fake-async never
      // completes it, so the row would never learn the file is gone.
      await tester.runAsync(() async {
        await tester.pumpWidget(hostPanel(
          child: const ProjectPanelFrb(),
          state: p.state,
          uiState: p.uiState,
        ));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();

      expect(find.text('missing'), findsOneWidget);
      expect(
        find.byKey(ValueKey<String>('relink-${gone.internalid}')),
        findsOneWidget,
      );

      // The header appears only while something is missing, and filters to it.
      expect(find.byKey(const ValueKey('missing-toggle')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('missing-toggle')));
      await tester.pumpAndSettle();

      expect(find.text('gone.mp4'), findsOneWidget);
      expect(find.text('Scene'), findsNothing,
          reason: 'filtered: every visible row is now something to fix');
    }, skip: _asyncStatusSkip);

    testWidgets('relink routes the picked path to the engine', (tester) async {
      final p = freshProject();
      p.state.project!.importFootage(path: 'C:/nowhere/gone.mp4');

      // A real file for the relink to land on, so the engine accepts it.
      final target = await _tempFile('relinked.mp4');

      await tester.runAsync(() async {
        await tester.pumpWidget(hostPanel(
          child: ProjectPanelFrb(relinkPicker: () async => target),
          state: p.state,
          uiState: p.uiState,
        ));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();

      await tester.runAsync(() async {
        await tester.tap(find.text('Relink…'));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();

      expect(find.text('missing'), findsNothing,
          reason: 'the item resolves now, so the badge is gone');
    }, skip: _asyncStatusSkip);
    // Without the built library there is nothing to test against; the harness
    // throws with the command to run.
  }, skip: !engineAvailable);
}

Future<void> _doubleTap(WidgetTester tester, Finder target) async {
  await tester.tap(target);
  await tester.pump(kDoubleTapMinTime);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<String> _tempFile(String name) async {
  final dir = await Directory.systemTemp.createTemp('lumit-relink');
  final file = File('${dir.path}/$name');
  await file.writeAsBytes(const [0, 1, 2, 3]);
  return file.path;
}
