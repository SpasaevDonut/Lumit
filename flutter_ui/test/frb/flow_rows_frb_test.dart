// The Flow group on frb: the layer option K-088 specified and K-256 built.
//
// Two things are being pinned here. That flow is reachable *only* as a switch —
// it left the in-between-frames dropdown, so it can no longer be picked as if
// it were a peer of Nearest and Blend — and that every parameter behind it
// actually reaches the document, which is what the whole group exists for after
// two decisions' worth of engine sat with no control surface at all.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/panels/effect_controls_panel_frb.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';
import 'package:lumit_flutter/src/rust/api/retime.dart';

import 'frb_test_support.dart';

void main() {
  setUpAll(initEngineForTests);

  group('Flow group (frb)', () {
    ({LumitState state, LumitUiState uiState, CompositionReference comp})
        withComp() {
      final p = freshProject();
      final comp = p.state.project!.newComposition(name: 'Scene');
      p.uiState.setSelectedComp(comp);
      return (state: p.state, uiState: p.uiState, comp: comp);
    }

    LayerReference footageLayer(dynamic p) {
      final footage =
          (p.state as LumitState).project!.importFootage(path: 'C:/c/shot.mov');
      (p.comp as CompositionReference)
          .addFootageLayer(footage: footage, asSequence: false);
      final layer = (p.comp as CompositionReference).getLayers().single;
      (p.uiState as LumitUiState).selectedLayer.value = layer;
      return layer;
    }

    Future<void> mount(WidgetTester tester, dynamic p) async {
      (p.uiState as LumitUiState)
          .workspace
          .interface
          .transformInEffectControls = true;
      await tester.pumpWidget(hostPanel(
        child: const EffectControlsPanelFrb(),
        state: p.state as LumitState,
        uiState: p.uiState as LumitUiState,
        size: const Size(560, 900),
      ));
      await tester.pump();
    }

    testWidgets('the group appears only while flow is on', (tester) async {
      final p = withComp();
      final layer = footageLayer(p);
      await mount(tester, p);

      expect(find.text('Flow'), findsNothing,
          reason: 'a layer not using flow has no flow group');

      layer.setFlowEnabled(on_: true);
      await mount(tester, p);
      expect(find.text('Flow'), findsOneWidget);
      expect(layer.getInterpolation(), BridgeRetimeInterp.flow);
    });

    testWidgets('flow is a switch, not a dropdown entry', (tester) async {
      final p = withComp();
      final layer = footageLayer(p);
      await mount(tester, p);

      // The dropdown is still there for Nearest/Blend...
      expect(find.byKey(const ValueKey('src-retime-interp')), findsOneWidget);
      // ...but flow is no longer one of the things it offers. Picking it there
      // made the most expensive setting a layer has look like a small one.
      expect(find.text('Optical flow'), findsNothing);

      // The switch is what turns it on, and it round-trips.
      expect(layer.getFlowEnabled(), isFalse);
      layer.setFlowEnabled(on_: true);
      expect(layer.getFlowEnabled(), isTrue);
      layer.setFlowEnabled(on_: false);
      expect(layer.getFlowEnabled(), isFalse);
      expect(layer.getInterpolation(), BridgeRetimeInterp.nearest,
          reason: 'turning flow off returns the layer to the crisp default');
    });

    testWidgets('every parameter reaches the document', (tester) async {
      final p = withComp();
      final layer = footageLayer(p);
      layer.setFlowEnabled(on_: true);
      await mount(tester, p);

      // Sections start twirled open, so the rows are already built.
      for (final key in [
        'flow-resolution',
        'flow-detail',
        'flow-smoothness',
        'flow-occlusion',
        'flow-fallback',
        'flow-hud-guard',
        'flow-always',
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget,
            reason: '$key is one of the parameters docs/08 §3.1 specifies');
      }

      // Defaults, straight from the engine.
      final before = layer.getFlowParams();
      expect(before.resolution, 0, reason: 'native');
      expect(before.detail, 1, reason: 'medium');
      expect(before.smoothness, 50);
      expect(before.hudGuard, isTrue,
          reason: 'game capture is the primary footage, so the guard is on');
      expect(before.always, isFalse);

      // A write of the whole group round-trips.
      layer.setFlowParams(
        params: BridgeFlowParams(
          resolution: 2,
          detail: 3,
          smoothness: 12.5,
          occlusion: 1,
          fallback: 1,
          hudGuard: false,
          always: true,
        ),
      );
      final after = layer.getFlowParams();
      expect(after.resolution, 2);
      expect(after.detail, 3);
      expect(after.smoothness, 12.5);
      expect(after.occlusion, 1);
      expect(after.fallback, 1);
      expect(after.hudGuard, isFalse);
      expect(after.always, isTrue);
    });

    testWidgets('switching flow off discards the group, for now',
        (tester) async {
      final p = withComp();
      final layer = footageLayer(p);
      layer.setFlowEnabled(on_: true);
      layer.setFlowParams(
        params: BridgeFlowParams(
          resolution: 1,
          detail: 3,
          smoothness: 80,
          occlusion: 1,
          fallback: 1,
          hudGuard: false,
          always: false,
        ),
      );
      layer.setFlowEnabled(on_: false);
      layer.setFlowEnabled(on_: true);
      // Pinning the *limitation*, not endorsing it. The parameters live inside
      // the Flow variant of the interpolation policy, so turning flow off has
      // nowhere to keep them. Comparing a flow shot against the plain one is a
      // normal thing to do and should not cost the tuning that got you there —
      // fixing it means moving FlowParams onto the layer beside the policy
      // rather than inside it (docs/TODO.md). When that lands, this test
      // inverts and the reason it exists is recorded here.
      expect(layer.getFlowParams().resolution, 0);
      expect(layer.getFlowParams().detail, 1);
      expect(layer.getFlowParams().smoothness, 50);
    });
  }, skip: !engineAvailable);
}
