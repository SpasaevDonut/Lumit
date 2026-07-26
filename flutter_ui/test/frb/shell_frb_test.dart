// The shell surfaces on frb: Settings, recovery, the command palette.
//
// The Settings window and the recovery dialogue read the engine, so they run
// against it. The palette's ranking is pure and is tested as a function, because
// what matters about it is which command comes first — not how it is drawn.

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumit_flutter/shell/command_palette_frb.dart';
import 'package:lumit_flutter/shell/export_dialog_frb.dart';
import 'package:lumit_flutter/shell/recovery_dialog_frb.dart';
import 'package:lumit_flutter/shell/settings_window_frb.dart';
import 'package:lumit_flutter/src/rust/api/cache.dart';
import 'package:lumit_flutter/src/rust/api/export.dart';
import 'package:lumit_flutter/src/rust/api/shell.dart';
import 'package:lumit_flutter/theme/theme.dart';
import 'package:lumit_flutter/widgets/controls.dart';

import 'frb_test_support.dart';

void main() {
  setUpAll(initEngineForTests);

  group('Command palette ranking', () {
    test('a subsequence matches, and an absent letter does not', () {
      expect(paletteScore('nc', 'New composition'), isNotNull,
          reason: 'initials are the point of a palette');
      expect(paletteScore('', 'anything'), 0, reason: 'empty matches all');
      expect(paletteScore('zzz', 'New composition'), isNull);
      expect(paletteScore('NC', 'new composition'), isNotNull,
          reason: 'matching ignores case both ways');
    });

    test('an earlier, tighter match ranks first', () {
      // "comp" is contiguous and early in one, late in the other.
      final settings = paletteScore('comp', 'Composition settings')!;
      final created = paletteScore('comp', 'New composition')!;
      expect(settings, lessThan(created));
    });

    test('a scattered match ranks below a contiguous one', () {
      final tight = paletteScore('save', 'Save as…')!;
      final loose = paletteScore('save', 'Show all viewer edges')!;
      expect(tight, lessThan(loose));
    });
  });

  group('Settings window (frb)', () {
    testWidgets('it reads the engine and its buttons reach it', (tester) async {
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

      // The boot log states facts about this build, so at least its version.
      expect(find.textContaining('lumit-bridge'), findsOneWidget);
      expect(find.byKey(const ValueKey('settings-tier')), findsOneWidget);
      expect(find.byKey(const ValueKey('settings-cache-used')), findsOneWidget);

      // The budget picker changes what the engine holds, not just the label.
      await tester.tap(find.byKey(const ValueKey('settings-cache-budget')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('256 MB').last);
      await tester.pumpAndSettle();
      expect(cacheStats().budgetBytes.toInt(), 256 << 20);

      await tester.tap(find.byKey(const ValueKey('settings-cache-clear')));
      await tester.pump();
      expect(cacheStats().entries.toInt(), 0);

      await tester.tap(find.byKey(const ValueKey('settings-tier-reset')));
      await tester.pump();
      expect(playbackTier().tier, 1);
    });

    testWidgets('the appearance controls change the shell theme',
        (tester) async {
      final p = freshProject();
      expect(p.uiState.scheme, LumitColorScheme.dark);

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

      await tester.tap(find.byKey(const ValueKey('settings-scheme')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Light').last);
      await tester.pumpAndSettle();

      expect(p.uiState.scheme, LumitColorScheme.light);
      expect(p.uiState.theme.mode, isNot(ThemeMode2.dark),
          reason: 'the derived theme follows the choice');
    });
  }, skip: !engineAvailable);

  group('Recovery (frb)', () {
    testWidgets('with nothing beside the project no dialogue is offered',
        (tester) async {
      final p = freshProject();
      final dir = Directory.systemTemp.createTempSync('lumit-recover-none');
      late RecoveryChoice? choice;

      await tester.pumpWidget(hostPanel(
        child: Builder(builder: (context) {
          return HouseButton(
            key: const ValueKey('recover'),
            onPressed: () async {
              choice = await showRecoveryDialogFrb(
                context: context,
                state: p.state,
                projectPath: '${dir.path}/scene.lum',
              );
            },
            child: const Text('Recover'),
          );
        }),
        state: p.state,
        uiState: p.uiState,
      ));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('recover')));
      await tester.pumpAndSettle();

      expect(choice, isNull,
          reason: 'a project with nothing to recover raises no dialogue');
      expect(find.textContaining('Recover unsaved work'), findsNothing);
    });

    testWidgets('an autosave beside the project offers the three choices',
        (tester) async {
      final p = freshProject();
      p.state.project!.newComposition(name: 'Scene');

      final dir = Directory.systemTemp.createTempSync('lumit-recover-some');
      final path = '${dir.path}/scene.lum';
      // A real autosave, written by the engine, so the listing is genuine.
      p.state.project!.autosave(projectPath: path, keep: 3);
      expect(listAutosaves(project: path), hasLength(1));

      await tester.pumpWidget(hostPanel(
        child: Builder(builder: (context) {
          return HouseButton(
            key: const ValueKey('recover'),
            onPressed: () => showRecoveryDialogFrb(
              context: context,
              state: p.state,
              projectPath: path,
            ),
            child: const Text('Recover'),
          );
        }),
        state: p.state,
        uiState: p.uiState,
      ));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('recover')));
      await tester.pumpAndSettle();

      expect(find.text('Recover unsaved work'), findsOneWidget);
      expect(find.byKey(const ValueKey('recover-journal')), findsOneWidget);
      expect(find.byKey(const ValueKey('recover-autosave')), findsOneWidget);
      expect(find.byKey(const ValueKey('recover-discard')), findsOneWidget);

      // Discard leaves everything where it is — the copies are not deleted.
      await tester.tap(find.byKey(const ValueKey('recover-discard')));
      await tester.pumpAndSettle();
      expect(listAutosaves(project: path), hasLength(1));
    });
  }, skip: !engineAvailable);

  group('Export dialogue (frb)', () {
    testWidgets('Export is inert until somewhere to write is chosen',
        (tester) async {
      final p = freshProject();
      final comp = p.state.project!.newComposition(name: 'Scene');
      comp.addAdjustmentLayer();

      await tester.pumpWidget(hostPanel(
        child: Builder(
          builder: (context) => HouseButton(
            key: const ValueKey('open-export'),
            onPressed: () => showExportDialogFrb(
              context: context,
              comp: comp,
              picker: () async => '${Directory.systemTemp.path}/out.mp4',
            ),
            child: const Text('Open'),
          ),
        ),
        state: p.state,
        uiState: p.uiState,
      ));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('open-export')));
      await tester.pumpAndSettle();

      expect(find.text('Export composition'), findsOneWidget);
      expect(find.text('Not chosen'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('export-choose')));
      await tester.pumpAndSettle();
      expect(find.text('out.mp4'), findsOneWidget,
          reason: 'the chosen path is shown by its file name');

      // Starting either runs or explains itself — a machine with no GPU says
      // so where the progress would be, rather than the dialogue looking dead.
      await tester.tap(find.byKey(const ValueKey('export-start')));
      await tester.pumpAndSettle(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('export-close')), findsOneWidget,
          reason: 'the dialogue survives whatever the exporter said');

      exportCancel();
      await tester.tap(find.byKey(const ValueKey('export-close')));
      await tester.pumpAndSettle();
    });
  }, skip: !engineAvailable);
}
