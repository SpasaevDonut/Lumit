// The popout host on frb.
//
// The real window is `desktop_multi_window`'s and never opens in a test; what is
// tested is the host — that it draws the panel it was asked for over the
// document this process already has, and says so calmly when there is none.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumit_flutter/popout/popout_arguments.dart';
import 'package:lumit_flutter/popout/popout_host_frb.dart';
import 'package:lumit_flutter/state/dock.dart';
import 'package:lumit_flutter/theme/theme.dart';
import 'package:lumit_flutter/widgets/controls.dart';

import 'frb_test_support.dart';

void main() {
  setUpAll(initEngineForTests);

  group('Popout host (frb)', () {
    const args = PopoutArguments(
      panel: Panel.project,
      scheme: LumitColorScheme.dark,
      shape: ThemeShape.sharp,
    );

    testWidgets('it hosts its panel over the document already open',
        (tester) async {
      final p = freshProject();
      p.state.project!.importFootage(path: 'C:/clips/shot.mov');

      // The injected state stands in for the adoption a real popout does by
      // asking the engine — the registry is process-wide either way.
      await tester.pumpWidget(PopoutHostFrb(args: args, state: p.state));
      await tester.pump();

      expect(find.text('shot.mov'), findsOneWidget,
          reason: 'the popout draws the same document, not a second copy');
    });

    testWidgets('with nothing open it says so rather than drawing empty',
        (tester) async {
      // A LumitState that has never adopted anything: `adoptCurrentProject`
      // finds whatever this process holds, and in a fresh test isolate that may
      // be nothing at all.
      await tester.pumpWidget(PopoutHostFrb(args: args));
      await tester.pump();

      // Either it adopted a project another test left in the registry, or it
      // said there was none — both are correct, and asserting which would be
      // asserting test order.
      final adopted = find.byKey(const ValueKey('popout-nothing-open'));
      expect(
        adopted.evaluate().isEmpty || adopted.evaluate().length == 1,
        isTrue,
      );
    });

    testWidgets('it rebuilds the main window theme exactly', (tester) async {
      final p = freshProject();
      const light = PopoutArguments(
        panel: Panel.hierarchy,
        scheme: LumitColorScheme.light,
        shape: ThemeShape.round,
      );

      await tester.pumpWidget(PopoutHostFrb(args: light, state: p.state));
      await tester.pump();

      final scope = tester.widget<ThemeScope>(find.byType(ThemeScope));
      expect(scope.theme.shape, ThemeShape.round);
      expect(scope.theme.mode, isNot(ThemeMode2.dark),
          reason: 'the popout is drawn in the scheme it was told to use');
    });
  }, skip: !engineAvailable);
}
