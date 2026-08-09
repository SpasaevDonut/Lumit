// The Ctrl+Space console (K-319): what the search ranks and divides, and what
// the ring does with a flick.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumit_flutter/shell/fx_console_context.dart';
import 'package:lumit_flutter/shell/fx_console_frb.dart';
import 'package:lumit_flutter/theme/theme.dart';
import 'package:lumit_flutter/widgets/controls.dart';
import 'package:lumit_flutter/widgets/radial_maths.dart';

void main() {
  FxConsoleEntry effect(String label, {VoidCallback? run}) => FxConsoleEntry(
        label: label,
        kind: FxConsoleKind.effect,
        group: 'Blur & sharpen',
        run: run ?? () {},
      );
  FxConsoleEntry comp(String label, {VoidCallback? run}) => FxConsoleEntry(
        label: label,
        kind: FxConsoleKind.composition,
        run: run ?? () {},
      );

  group('the search', () {
    test('matches a subsequence, so "gau" finds Gaussian blur', () {
      expect(fxConsoleScore('gau', 'Gaussian blur'), isNotNull);
      expect(fxConsoleScore('gb', 'Gaussian blur'), isNotNull,
          reason: 'the initials of the two words are a subsequence');
      expect(fxConsoleScore('zzz', 'Gaussian blur'), isNull);
    });

    test('an earlier, tighter match ranks first', () {
      final entries = [effect('Directional blur'), effect('Blur the edges')];
      final ranked = fxConsoleMatches(entries, 'blur');
      expect(ranked.first.label, 'Blur the edges');
    });

    test('effects always come before compositions, however they score', () {
      // The comp is a perfect prefix match; the effect is a scattered one.
      final entries = [comp('Blur'), effect('Directional blur')];
      final ranked = fxConsoleMatches(entries, 'blur');
      expect(ranked.map((e) => e.kind).toList(),
          [FxConsoleKind.effect, FxConsoleKind.composition],
          reason: 'a comp must never outrank an effect');
    });

    test('an empty query keeps the declared order within each kind', () {
      final entries = [comp('Scene'), effect('Invert'), effect('Glow')];
      final ranked = fxConsoleMatches(entries, '');
      expect(ranked.map((e) => e.label).toList(), ['Invert', 'Glow', 'Scene']);
    });
  });

  group('the console widget', () {
    Widget host(FxConsoleModel model, {void Function(BuildContext)? capture}) =>
        Directionality(
          textDirection: TextDirection.ltr,
          child: ThemeScope(
            theme: LumitTheme.dark(),
            animationLevel: AnimationLevel.none,
            showTooltips: false,
            child: Overlay(
              initialEntries: [
                OverlayEntry(
                  builder: (context) {
                    capture?.call(context);
                    return const SizedBox.expand();
                  },
                ),
              ],
            ),
          ),
        );

    Future<void> open(WidgetTester tester, FxConsoleModel model) async {
      late BuildContext ctx;
      await tester.pumpWidget(host(model, capture: (c) => ctx = c));
      showFxConsoleFrb(context: ctx, model: model);
      await tester.pump();
      await tester.pump();
    }

    testWidgets('Enter applies the top match', (tester) async {
      var applied = '';
      await open(
        tester,
        FxConsoleModel(
          radialTitle: 'Timeline',
          radial: const [],
          entries: [
            effect('Gaussian blur', run: () => applied = 'gaussian'),
            effect('Directional blur', run: () => applied = 'directional'),
          ],
        ),
      );

      await tester.enterText(
          find.byKey(const ValueKey('fx-console-query')), 'gau');
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(applied, 'gaussian');
    });

    testWidgets('the snapshot button saves when there is something to save',
        (tester) async {
      var shots = 0;
      await open(
        tester,
        FxConsoleModel(
          radialTitle: 'Scene',
          radial: const [],
          entries: [effect('Glow')],
          onSnapshot: () => shots++,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('fx-console-snapshot')));
      await tester.pumpAndSettle();
      expect(shots, 1);
    });

    testWidgets('the snapshot button greys out with no composition open',
        (tester) async {
      await open(
        tester,
        FxConsoleModel(
          radialTitle: 'Nothing selected',
          radial: const [],
          entries: [effect('Glow')],
        ),
      );
      final button = tester.widget<HouseButton>(
          find.byKey(const ValueKey('fx-console-snapshot')));
      expect(button.onPressed, isNull,
          reason: 'no composition, nothing to snapshot');
    });

    testWidgets('a flick in a direction runs that slice', (tester) async {
      final run = <String>[];
      await open(
        tester,
        FxConsoleModel(
          radialTitle: 'Scene',
          radial: [
            RadialEntry(label: 'Solid', run: () => run.add('solid')),
            RadialEntry(label: 'Text', run: () => run.add('text')),
            RadialEntry(label: 'Null', run: () => run.add('null')),
            RadialEntry(label: 'Camera', run: () => run.add('camera')),
          ],
          entries: [effect('Glow')],
        ),
      );

      // The ring's centre is the middle of the title; flick straight up, which
      // is the first slice.
      final centre = tester.getCenter(find.text('Scene'));
      final gesture = await tester.startGesture(centre);
      await gesture.moveBy(const Offset(0, -(radialDeadZone + 30)));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(run, ['solid'], reason: 'up is the first slice');
    });

    testWidgets('releasing inside the dead zone cancels', (tester) async {
      final run = <String>[];
      await open(
        tester,
        FxConsoleModel(
          radialTitle: 'Scene',
          radial: [
            RadialEntry(label: 'Solid', run: () => run.add('solid')),
            RadialEntry(label: 'Text', run: () => run.add('text')),
          ],
          entries: [effect('Glow')],
        ),
      );

      final centre = tester.getCenter(find.text('Scene'));
      final gesture = await tester.startGesture(centre);
      await gesture.moveBy(const Offset(0, -(radialDeadZone - 8)));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(run, isEmpty,
          reason: 'opening and letting go without travelling picks nothing');
    });

    testWidgets('a disabled slice keeps its place but does not run',
        (tester) async {
      final run = <String>[];
      await open(
        tester,
        FxConsoleModel(
          radialTitle: 'Nothing selected',
          radial: [
            RadialEntry(
                label: 'New composition', run: () => run.add('new')),
            RadialEntry(
                label: 'Import',
                enabled: false,
                run: () => run.add('import')),
          ],
          entries: const [],
        ),
      );

      expect(find.byKey(const ValueKey('fx-radial-Import')), findsOneWidget,
          reason: 'the ring keeps its shape, so directions stay learned');
      await tester.tap(find.byKey(const ValueKey('fx-radial-Import')));
      await tester.pumpAndSettle();
      expect(run, isEmpty);
    });

    testWidgets('with no radial entries the ring is not drawn at all',
        (tester) async {
      await open(
        tester,
        FxConsoleModel(
          radialTitle: 'Scene',
          radial: const [],
          entries: [effect('Glow')],
        ),
      );
      expect(find.text('Scene'), findsNothing,
          reason: 'an empty ring is hidden rather than drawn empty');
    });
  });

  group('where a snapshot goes', () {
    test('beside the saved project, in a Snapshots folder', () {
      final path = snapshotPathFor(
        compName: 'Scene',
        projectPath: '/work/film/film.lum',
        environment: const {'HOME': '/home/someone'},
      );
      expect(path, contains('/work/film'));
      expect(path, contains('Snapshots'));
      expect(path, endsWith('Scene.png'));
    });

    test('an unsaved project goes to the pictures folder, never the cwd', () {
      final path = snapshotPathFor(
        compName: 'Scene',
        environment: const {'HOME': '/home/someone'},
      );
      expect(path, startsWith('/home/someone'));
      expect(path, contains('Pictures'));
      expect(path, isNot(startsWith('Scene')),
          reason: 'a bare name would land wherever the app was started');
    });

    test('a name a file system cannot take is cleaned, never empty', () {
      expect(
        snapshotPathFor(
            compName: 'Shot 1: "hero"/final',
            environment: const {'HOME': '/h'}),
        endsWith('Shot 1 herofinal.png'),
      );
      expect(
        snapshotPathFor(compName: '///', environment: const {'HOME': '/h'}),
        endsWith('snapshot.png'),
        reason: 'a name that cleans to nothing still needs a file name',
      );
    });
  });
}
