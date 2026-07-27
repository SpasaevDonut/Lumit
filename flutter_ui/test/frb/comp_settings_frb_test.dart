// The Composition settings / New composition dialogue (K-180).
//
// Two things are worth testing here and both were bugs before it: what the
// dialogue *writes* when only the frame rate changes, and how the two text
// fields read what is typed into them. A rate typed as a decimal still has to
// reach the engine as the exact pair, and a duration typed as a wall-clock time
// has to survive a rate change untouched — that is the whole of the fix.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumit_flutter/shell/comp_settings_frb.dart';
import 'package:lumit_flutter/src/rust/api/effect.dart';

import 'frb_test_support.dart';

void main() {
  group('the rate field reads a decimal as an exact rate', () {
    test('the NTSC family comes back exact, not as the rounded decimal', () {
      // 23.976 is a *rounding* of 24000/1001, so no arithmetic on the rounded
      // number recovers the rate — it has to be matched by name.
      expect(parseRate('23.976'), (24000, 1001));
      expect(parseRate('29.97'), (30000, 1001));
      expect(parseRate('59.94'), (60000, 1001));
    });

    test('a whole rate is that rate over one', () {
      expect(parseRate('60'), (60, 1));
      expect(parseRate('600'), (600, 1));
    });

    test('any other decimal is read on the thousandths grid and reduced', () {
      expect(parseRate('12.5'), (25, 2));
    });

    test('nonsense is refused rather than guessed at', () {
      expect(parseRate(''), isNull);
      expect(parseRate('0'), isNull);
      expect(parseRate('-30'), isNull);
      expect(parseRate('fast'), isNull);
    });
  });

  group('the duration field is a length of time', () {
    test('HH:MM:SS.mmm round-trips through exact seconds', () {
      final parsed = parseDurationHms('00:00:11.892');
      expect(parsed, isNotNull);
      expect(formatDurationHms(parsed!), '00:00:11.892');
    });

    test('a colon before the milliseconds reads the same as a full stop', () {
      expect(parseDurationHms('00:00:11:892'), parseDurationHms('00:00:11.892'));
    });

    test('shorter forms mean what they obviously mean', () {
      expect(parseDurationHms('1:30'), parseDurationHms('00:01:30.000'));
      expect(parseDurationHms('11.892'), parseDurationHms('00:00:11.892'));
    });

    test('an exact thirty seconds prints as thirty seconds', () {
      expect(formatDurationHms(const BridgeRational(num: 30, den: 1)),
          '00:00:30.000');
    });

    test('nonsense is refused, so a typo cannot shorten a comp', () {
      expect(parseDurationHms('soon'), isNull);
      expect(parseDurationHms(''), isNull);
    });
  });

  test('the aspect label is the shape in its smallest whole numbers', () {
    expect(aspectRatioLabel(1920, 816), '40 : 17');
    expect(aspectRatioLabel(1920, 1080), '16 : 9');
  });

  group('the dialogue against the engine', () {
    setUpAll(initEngineForTests);

    /// **The regression this dialogue exists to fix.** Change only the rate and
    /// press Save: the comp must keep its length and its layers their timing.
    /// The old dialogue wrote yesterday's frame *count* back at the new rate,
    /// which halved or doubled the comp under layers that had not moved.
    testWidgets('changing only the rate does not retime the comp',
        (tester) async {
      final p = freshProject();
      final comp = p.state.project!.newComposition(name: 'Scene');
      comp.addSolidLayer();
      final spanBefore = comp.getLayers().single.getSpan();
      expect(comp.durationFrames(), 1800, reason: '30 s at the default 60 fps');

      await tester.pumpWidget(hostPanel(
        child: Builder(
          builder: (context) => GestureDetector(
            key: const ValueKey('open'),
            behavior: HitTestBehavior.opaque,
            onTap: () => showCompSettingsFrb(context: context, comp: comp),
            child: const SizedBox(width: 200, height: 40),
          ),
        ),
        state: p.state,
        uiState: p.uiState,
      ));
      await tester.tap(find.byKey(const ValueKey('open')));
      await tester.pumpAndSettle();

      expect(find.text('00:00:30.000'), findsOneWidget,
          reason: 'the duration opens as a wall-clock length, not a count');

      await tester.enterText(find.byKey(const ValueKey('comp-fps')), '30');
      await tester.tap(find.byKey(const ValueKey('comp-apply')));
      await tester.pumpAndSettle();

      final after = comp.getSettings();
      expect((after.fpsNum, after.fpsDen), (30, 1));
      expect(after.duration, const BridgeRational(num: 30, den: 1),
          reason: 'still thirty seconds long');
      expect(comp.durationFrames(), 900,
          reason: 'the same thirty seconds, counted half as finely');
      expect(comp.getLayers().single.getSpan(), spanBefore,
          reason: 'the layer occupies the same time — the rate is not a speed');
    });

    testWidgets('a drop-frame preset reaches the engine as its exact pair',
        (tester) async {
      final p = freshProject();
      final comp = p.state.project!.newComposition(name: 'Scene');

      await tester.pumpWidget(hostPanel(
        child: Builder(
          builder: (context) => GestureDetector(
            key: const ValueKey('open'),
            behavior: HitTestBehavior.opaque,
            onTap: () => showCompSettingsFrb(context: context, comp: comp),
            child: const SizedBox(width: 200, height: 40),
          ),
        ),
        state: p.state,
        uiState: p.uiState,
      ));
      await tester.tap(find.byKey(const ValueKey('open')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const ValueKey('comp-fps')), '23.976');
      await tester.tap(find.byKey(const ValueKey('comp-apply')));
      await tester.pumpAndSettle();

      final after = comp.getSettings();
      expect((after.fpsNum, after.fpsDen), (24000, 1001),
          reason: 'a decimal in the field, the exact rate in the document');
    });

    /// The list beside the field says what the field says: a preset by name, or
    /// "Custom" for a rate of one's own. It used to read "Presets" whatever was
    /// typed, which told you nothing about the comp.
    testWidgets('the presets list reads Custom for a rate of one\'s own',
        (tester) async {
      final p = freshProject();
      final comp = p.state.project!.newComposition(name: 'Scene');

      await tester.pumpWidget(hostPanel(
        child: Builder(
          builder: (context) => GestureDetector(
            key: const ValueKey('open'),
            behavior: HitTestBehavior.opaque,
            onTap: () => showCompSettingsFrb(context: context, comp: comp),
            child: const SizedBox(width: 200, height: 40),
          ),
        ),
        state: p.state,
        uiState: p.uiState,
      ));
      await tester.tap(find.byKey(const ValueKey('open')));
      await tester.pumpAndSettle();

      expect(find.text('60'), findsWidgets, reason: 'the default rate');
      expect(find.text('Custom'), findsNothing,
          reason: '60 is a preset, so it is named');

      await tester.enterText(find.byKey(const ValueKey('comp-fps')), '600');
      await tester.pump();

      expect(find.text('Custom'), findsOneWidget,
          reason: 'and it follows the field as it is typed into');
    });

    testWidgets('Cancel writes nothing', (tester) async {
      final p = freshProject();
      final comp = p.state.project!.newComposition(name: 'Scene');
      final before = comp.getSettings();

      await tester.pumpWidget(hostPanel(
        child: Builder(
          builder: (context) => GestureDetector(
            key: const ValueKey('open'),
            behavior: HitTestBehavior.opaque,
            onTap: () => showCompSettingsFrb(context: context, comp: comp),
            child: const SizedBox(width: 200, height: 40),
          ),
        ),
        state: p.state,
        uiState: p.uiState,
      ));
      await tester.tap(find.byKey(const ValueKey('open')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const ValueKey('comp-name')), 'Nope');
      await tester.tap(find.byKey(const ValueKey('comp-cancel')));
      await tester.pumpAndSettle();

      expect(comp.getSettings().name, before.name);
    });
  });
}
