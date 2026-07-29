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
import 'package:lumit_flutter/shell/status_line_frb.dart';
import 'package:lumit_flutter/src/rust/api/cache.dart';
import 'package:lumit_flutter/src/rust/api/effect.dart';
import 'package:lumit_flutter/src/rust/api/export.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';
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

      // General opens first, and states facts about this build.
      expect(find.textContaining('lumit-bridge'), findsOneWidget);

      // The engine's own readouts and buttons live on Performance (K-193).
      await tester.tap(find.byKey(const ValueKey('settings-page-performance')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-tier')), findsOneWidget);
      expect(find.byKey(const ValueKey('settings-cache-used')), findsOneWidget);

      // The budget is a typed number now (K-194), not a pick from a list:
      // dragging it changes what the engine holds, not just the label.
      final before = cacheStats().budgetBytes.toInt();
      await tester.drag(find.byKey(const ValueKey('settings-cache-budget')),
          const Offset(60, 0));
      await tester.pumpAndSettle();
      expect(cacheStats().budgetBytes.toInt(), greaterThan(before),
          reason: 'the drag reached the engine');

      await tester.tap(find.byKey(const ValueKey('settings-cache-clear')));
      await tester.pump();
      expect(cacheStats().entries.toInt(), 0);

      await tester.tap(find.byKey(const ValueKey('settings-tier-reset')));
      await tester.pump();
      expect(playbackTier().tier, 1);
    });

    /// The pages are the point of the window: each shows its own settings and
    /// only its own, and a preference edited on one sticks (K-193).
    testWidgets('the pages divide the settings, and a choice persists',
        (tester) async {
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

      // General is open: nothing from another page is on screen with it.
      expect(find.byKey(const ValueKey('settings-reset-workspace')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('settings-scheme')), findsNothing);
      expect(find.byKey(const ValueKey('settings-cache-budget')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('settings-page-interface')));
      await tester.pumpAndSettle();
      expect(
          find.byKey(const ValueKey('settings-reset-workspace')), findsNothing);

      // The Transform card's toggle: off by default, and it stays where it
      // is put (K-193).
      expect(p.uiState.workspace.interface.transformInEffectControls, isFalse,
          reason: 'the Effect controls panel is about effects by default');
      await tester.tap(find.byKey(const ValueKey('settings-transform-in-fx')));
      await tester.pumpAndSettle();
      expect(p.uiState.workspace.interface.transformInEffectControls, isTrue);
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

      await tester.tap(find.byKey(const ValueKey('settings-page-appearance')));
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

  group('Status line (frb)', () {
    /// The strip stays empty while there is nothing to say, follows the
    /// export through running to its outcome, and offers Cancel only while
    /// something is actually cancellable. Driven through the injected poll,
    /// so no engine has to run a real export.
    testWidgets('the status line follows an export through its states',
        (tester) async {
      var state = const BridgeExportState.idle();
      final p = freshProject();
      await tester.pumpWidget(hostPanel(
        child: StatusLineFrb(poll: () => state),
        state: p.state,
        uiState: p.uiState,
      ));

      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const ValueKey('status-export-progress')), findsNothing,
          reason: 'idle says nothing');

      state = BridgeExportState.running(
          frame: BigInt.from(30), total: BigInt.from(120), encoder: 'x264');
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.textContaining('frame 30 of 120'), findsOneWidget);
      expect(find.byKey(const ValueKey('status-export-cancel')), findsOneWidget,
          reason: 'a running export can be cancelled from the strip');

      state = const BridgeExportState.done(path: 'C:/out/final.mp4');
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.textContaining('Exported to'), findsOneWidget);
      expect(find.byKey(const ValueKey('status-export-cancel')), findsNothing,
          reason: 'nothing to cancel any more');

      state = const BridgeExportState.failed(error: 'cancelled');
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Export cancelled'), findsOneWidget);
    });

    /// The left end of the strip: whether the document is saved. Fails
    /// without the engine's `is_dirty` (saved_revision stamped on save).
    testWidgets('the saved state follows edits and saves', (tester) async {
      final p = freshProject();
      await tester.pumpWidget(hostPanel(
        child: StatusLineFrb(poll: () => const BridgeExportState.idle()),
        state: p.state,
        uiState: p.uiState,
      ));
      await tester.pump();

      expect(find.text('Not saved yet'), findsOneWidget,
          reason: 'a fresh untouched project has nothing to lose');

      p.state.project!.newComposition(name: 'Scene');
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Unsaved changes'), findsOneWidget);

      final dir = Directory.systemTemp.createTempSync('lumit-status');
      addTearDown(() => dir.deleteSync(recursive: true));
      // Not awaited: save is an async frb call, and its continuation only
      // lands on the real turns settleFrb provides.
      p.state.project!.save(path: '${dir.path}/probe.lum');
      await settleFrb(tester, until: () => !p.state.project!.isDirty());
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Saved'), findsOneWidget,
          reason: 'the save stamped the revision clean');
    });

    /// The notice area: the latest message shows with its close button, and
    /// closing it leaves the strip quiet.
    testWidgets('a notice shows in the strip until closed', (tester) async {
      final p = freshProject();
      await tester.pumpWidget(hostPanel(
        child: StatusLineFrb(poll: () => const BridgeExportState.idle()),
        state: p.state,
        uiState: p.uiState,
      ));
      await tester.pump();
      expect(find.byKey(const ValueKey('status-notice')), findsNothing);

      p.state.postNotice('Could not open C:/gone.lum', error: true);
      await tester.pump();
      expect(find.byKey(const ValueKey('status-notice')), findsOneWidget);
      expect(find.textContaining('Could not open'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('status-notice-close')));
      await tester.pump();
      expect(find.byKey(const ValueKey('status-notice')), findsNothing,
          reason: 'every notice carries its close button');
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

    /// The dialogue's fields default to the composition's own facts (K-201):
    /// the frame rate is the comp's, and the range is the work area exactly as
    /// the Timeline set it — already typed, not re-derived by the user.
    testWidgets('the rate and range default to the comp and its work area',
        (tester) async {
      final p = freshProject();
      final comp = p.state.project!.newComposition(name: 'Scene');
      comp.addAdjustmentLayer();
      // A 60 fps comp with a work area over frames 60..180 (1 s .. 3 s).
      comp.setWorkArea(
        span: const BridgeSpan(
          inPoint: BridgeRational(num: 1, den: 1),
          outPoint: BridgeRational(num: 3, den: 1),
          startOffset: BridgeRational(num: 0, den: 1),
        ),
      );

      await tester.pumpWidget(hostPanel(
        child: Builder(
          builder: (context) => HouseButton(
            key: const ValueKey('open-export'),
            onPressed: () =>
                showExportDialogFrb(context: context, comp: comp),
            child: const Text('Open'),
          ),
        ),
        state: p.state,
        uiState: p.uiState,
      ));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('open-export')));
      await tester.pumpAndSettle();

      expect(find.text('Frame rate'), findsOneWidget);
      expect(find.text('60.00'), findsOneWidget,
          reason: 'the rate starts as the comp order — its own 60');
      expect(find.text('60'), findsOneWidget,
          reason: 'the range starts at the work area start');
      expect(find.text('180'), findsOneWidget,
          reason: 'and ends at the work area end');

      await tester.tap(find.byKey(const ValueKey('export-close')));
      await tester.pumpAndSettle();
    });

    /// An image sequence is stills: the video-only rows leave rather than
    /// sitting greyed, and the picker's suggestion follows the extension.
    testWidgets('choosing a sequence format sheds the video-only rows',
        (tester) async {
      final p = freshProject();
      final comp = p.state.project!.newComposition(name: 'Scene');
      comp.addAdjustmentLayer();

      await tester.pumpWidget(hostPanel(
        child: Builder(
          builder: (context) => HouseButton(
            key: const ValueKey('open-export'),
            onPressed: () =>
                showExportDialogFrb(context: context, comp: comp),
            child: const Text('Open'),
          ),
        ),
        state: p.state,
        uiState: p.uiState,
      ));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('open-export')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('export-audio')), findsOneWidget);
      expect(find.byKey(const ValueKey('export-bitrate')), findsOneWidget);
      expect(find.byKey(const ValueKey('export-audio-rate')), findsOneWidget,
          reason: 'audio has its own rate once audio is on');

      await tester.tap(find.byKey(const ValueKey('export-format')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('PNG image sequence').last);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('export-audio')), findsNothing,
          reason: 'stills carry no sound');
      expect(find.byKey(const ValueKey('export-bitrate')), findsNothing,
          reason: 'stills are lossless');
      expect(find.byKey(const ValueKey('export-preset')), findsNothing,
          reason: 'the delivery presets are mp4 by nature');
      expect(find.textContaining('One numbered PNG per frame'), findsOneWidget,
          reason: 'the dialogue says what a sequence writes');
      // The rate and range stay: stills have both.
      expect(find.byKey(const ValueKey('export-fps')), findsOneWidget);
      expect(find.byKey(const ValueKey('export-range-start')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('export-close')));
      await tester.pumpAndSettle();
    });
  }, skip: !engineAvailable);
}
