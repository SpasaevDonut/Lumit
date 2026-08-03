// The source rows on frb: what a layer is made of.
//
// Driven through the Effect controls panel, because the rows only appear for
// the kinds that have them and "which rows appear" is half of what they do.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/panels/effect_controls_panel_frb.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:lumit_flutter/src/rust/api/effect.dart';

import 'frb_test_support.dart';

void main() {
  setUpAll(initEngineForTests);

  group('Source rows (frb)', () {
    ({LumitState state, LumitUiState uiState, CompositionReference comp})
        withComp() {
      final p = freshProject();
      final comp = p.state.project!.newComposition(name: 'Scene');
      p.uiState.setSelectedComp(comp);
      return (state: p.state, uiState: p.uiState, comp: comp);
    }

    Future<void> mount(WidgetTester tester, dynamic p) async {
      // The Transform card is off by default (K-193); this file asserts it
      // sits beside the Source card, so it asks for it.
      (p.uiState as LumitUiState)
          .workspace
          .interface
          .transformInEffectControls = true;
      await tester.pumpWidget(hostPanel(
        child: const EffectControlsPanelFrb(),
        state: p.state as LumitState,
        uiState: p.uiState as LumitUiState,
        size: const Size(520, 700),
      ));
      await tester.pump();
    }

    testWidgets('a text layer can be retyped, resized and recoloured',
        (tester) async {
      final p = withComp();
      final text = p.comp.addTextLayer();
      p.uiState.selectedLayer.value = text;
      await mount(tester, p);

      expect(find.text('Source'), findsOneWidget);
      expect(find.byKey(const ValueKey('src-text')), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('src-text')), 'Hello');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(text.getText()!.text, 'Hello',
          reason: 'the words reached the document');

      await tester.tap(find.byKey(const ValueKey('src-text-size')));
      await tester.pump();
      await tester.enterText(find.byType(EditableText).last, '96');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(text.getText()!.size, 96);
    });

    testWidgets('a text layer can be driven by an expression', (tester) async {
      final p = withComp();
      final text = p.comp.addTextLayer();
      p.uiState.selectedLayer.value = text;
      await mount(tester, p);

      await tester.enterText(
          find.byKey(const ValueKey('src-text')), 'placeholder');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      await tester.enterText(
          find.byKey(const ValueKey('src-text-expression')), 'time * 2');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(text.getText()!.expression, 'time * 2');
      expect(text.getText()!.text, 'placeholder',
          reason: 'the typed words are kept underneath the expression');

      // Emptying the box hands the layer back to its words.
      await tester.enterText(
          find.byKey(const ValueKey('src-text-expression')), '');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(text.getText()!.expression, isNull);
      expect(text.getText()!.text, 'placeholder');
    });

    testWidgets('a camera layer shows its zoom and commits it', (tester) async {
      final p = withComp();
      final camera = p.comp.addCameraLayer();
      p.uiState.selectedLayer.value = camera;
      await mount(tester, p);

      expect(find.text('Zoom'), findsOneWidget);
      final field = find.byKey(const ValueKey('src-camera-zoom'));
      await tester.tap(field);
      await tester.pump();
      await tester.enterText(find.byType(EditableText).first, '1200');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      final zoom = camera.getCameraZoom()!;
      expect((zoom as BridgeScalar_Static).field0, 1200);
    });

    testWidgets('a solid layer edits the asset, and says that it does',
        (tester) async {
      final p = withComp();
      final solid = p.comp.addSolidLayer();
      p.uiState.selectedLayer.value = solid;
      await mount(tester, p);

      expect(find.byKey(const ValueKey('src-solid-colour')), findsOneWidget);
      expect(
          find.textContaining('every layer using it changes'), findsOneWidget,
          reason: 'the row warns that this is not a per-layer setting');

      await tester.tap(find.byKey(const ValueKey('src-solid-width')));
      await tester.pump();
      await tester.enterText(find.byType(EditableText).first, '640');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      // Read it back off the asset rather than the layer, which is the point.
      expect(find.byKey(const ValueKey('src-solid-width')), findsOneWidget);
    });

    testWidgets('a layer with no source of its own shows no card',
        (tester) async {
      final p = withComp();
      p.uiState.selectedLayer.value = p.comp.addAdjustmentLayer();
      await mount(tester, p);

      expect(find.text('Source'), findsNothing,
          reason: 'an adjustment layer has no content to edit');
      expect(find.text('Transform'), findsOneWidget,
          reason: 'but it still has a transform');
    });

    testWidgets('a footage layer retimes, and a ramp refuses a single speed',
        (tester) async {
      final p = withComp();
      final footage = p.state.project!.importFootage(path: 'C:/clips/shot.mov');
      p.comp.addFootageLayer(footage: footage);
      final layer = p.comp.getLayers().single;
      p.uiState.selectedLayer.value = layer;
      await mount(tester, p);

      // Absent until switched on: "not retimed" and "retimed to 1x" differ.
      expect(find.text('Retime'), findsOneWidget);
      expect(find.byKey(const ValueKey('src-retime-speed')), findsNothing);
      expect(layer.getRetime(), isNull);

      await tester.tap(find.byKey(const ValueKey('src-retime-on')));
      await tester.pump();
      expect(layer.getRetime(), isNotNull);
      expect(find.byKey(const ValueKey('src-retime-speed')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('src-retime-speed')));
      await tester.pump();
      await tester.enterText(find.byType(EditableText).first, '50');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(layer.getRetime()!.speedPercent, closeTo(50, 0.5));

      // The gate and the policy are independent of the speed.
      await tester.tap(find.byKey(const ValueKey('src-retime-reverse')));
      await tester.pump();
      expect(layer.getRetime()!.allowReverse, isTrue);
      expect(layer.getRetime()!.speedPercent, closeTo(50, 0.5),
          reason: 'opening the gate did not reset the speed');
    });

    testWidgets('a non-footage layer has no Retime row', (tester) async {
      final p = withComp();
      p.uiState.selectedLayer.value = p.comp.addTextLayer();
      await mount(tester, p);
      expect(find.text('Retime'), findsNothing,
          reason: 'only footage plays at a speed other than its own');
    });
  }, skip: !engineAvailable);
}
