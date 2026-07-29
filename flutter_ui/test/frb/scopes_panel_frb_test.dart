// The Scopes panel's own chrome.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumit_flutter/panels/scopes_panel_frb.dart';

import 'frb_test_support.dart';

void main() {
  setUpAll(initEngineForTests);

  group('Scopes (frb)', () {
    /// The toolbar names the trace and nothing else (K-203). It used to carry
    /// a frame readout beside the picker, which is the Timeline's and the
    /// Viewer's to state — three places saying the same number, and one of
    /// them competing with the trace it sits above.
    testWidgets('the toolbar carries no frame readout', (tester) async {
      final p = freshProject();
      final comp = p.state.project!.newComposition(name: 'Scene');
      p.uiState.setSelectedComp(comp);
      p.uiState.playheadFrame.value = 7;

      await tester.pumpWidget(hostPanel(
        child: const ScopesPanelFrb(),
        state: p.state,
        uiState: p.uiState,
      ));
      await tester.pump();

      expect(find.byKey(const ValueKey('scope-kind')), findsOneWidget,
          reason: 'the picker is still there');
      expect(find.textContaining('frame'), findsNothing);
      expect(find.textContaining('7'), findsNothing);
    });
  }, skip: !engineAvailable);
}
