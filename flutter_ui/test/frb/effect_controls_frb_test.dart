// The Effect controls panel on frb, tested against the real engine.
//
// The panel that existed before this was a float-only sketch in panels_frb.dart
// with a `TODO: commit the value` where the commit should be, so there is
// nothing to migrate here — v0's own panel could only *edit* scalars and colours
// ("every other kind shows its value read-only… since the matching edit op is
// not in the bridge yet"), which this one improves on rather than matches.
//
// Every document operation is genuine; see frb_test_support.dart.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/panels/effect_controls_panel_frb.dart';
import 'package:lumit_flutter/src/rust/api/effect.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';

import 'frb_test_support.dart';

void main() {
  setUpAll(initEngineForTests);

  group('Effect controls (frb)', () {
    /// A project with one comp, one layer in it, and that layer selected — the
    /// state the panel needs before it draws anything at all.
    ({LumitState state, LumitUiState uiState, LayerReference layer}) withLayer() {
      final p = freshProject();
      final comp = p.state.project!.newComposition(name: 'Scene');
      final footage = p.state.project!.importFootage(path: 'C:/clips/shot.mov');
      comp.addFootageLayer(footage: footage);
      final layer = comp.getLayers().single;
      p.uiState
        ..setSelectedComp(comp)
        ..selectedLayer.value = layer;
      return (state: p.state, uiState: p.uiState, layer: layer);
    }

    Future<void> mount(
      WidgetTester tester,
      ({LumitState state, LumitUiState uiState, LayerReference layer}) p,
    ) async {
      await tester.pumpWidget(hostPanel(
        child: const EffectControlsPanelFrb(),
        state: p.state,
        uiState: p.uiState,
      ));
      await tester.pump();
    }

    testWidgets('without a layer selected it says so rather than drawing empty',
        (tester) async {
      final p = freshProject();
      await tester.pumpWidget(hostPanel(
        child: const EffectControlsPanelFrb(),
        state: p.state,
        uiState: p.uiState,
      ));
      await tester.pump();
      expect(find.textContaining('Select a composition'), findsOneWidget);

      final comp = p.state.project!.newComposition(name: 'Scene');
      p.uiState.setSelectedComp(comp);
      await tester.pump();
      expect(find.textContaining('Select a layer'), findsOneWidget);
    });

    testWidgets('Add effect commits one, and it appears as a card',
        (tester) async {
      final p = withLayer();
      await mount(tester, p);

      expect(find.textContaining('No effects'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('fx-add')));
      await tester.pumpAndSettle();
      // The menu lists built-ins by their sentence-case label, under a category
      // heading — the raw match_name never reaches the user.
      expect(find.text('Gaussian blur'), findsOneWidget);
      await tester.tap(find.text('Gaussian blur'));
      await tester.pumpAndSettle();

      expect(p.layer.getEffects(), hasLength(1),
          reason: 'the menu reached the document');
      expect(find.text('Gaussian blur'), findsOneWidget,
          reason: 'the card is titled by label, not by match name');
      expect(find.text('Radius'), findsOneWidget,
          reason: 'a row per declared parameter, labelled from the schema');
    });

    testWidgets('a parameter edit commits, and reading it back is exact',
        (tester) async {
      final p = withLayer();
      p.layer.addEffect(name: 'blur');
      await mount(tester, p);

      // By key, not `.first`: the Transform card is drawn above the stack, so
      // the first DragValueField on screen is an anchor-point cell.
      final id = p.layer.getEffects().single.id();
      await tester.tap(find.byKey(ValueKey<String>('fx-float-$id-radius')));
      await tester.pump();
      await tester.enterText(find.byType(EditableText).first, '12.5');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      final radius =
          p.layer.getEffects().single.getValue(id: 'radius');
      expect(
        radius,
        isA<BridgeEffectValue_Float>().having(
          (v) => (v.field0 as BridgeScalar_Static).field0,
          'radius',
          12.5,
        ),
        reason: 'the typed value reached the document as a static scalar',
      );
    });

    testWidgets('the enable switch, reorder and remove all reach the document',
        (tester) async {
      final p = withLayer();
      p.layer.addEffect(name: 'blur');
      p.layer.addEffect(name: 'sharpen');
      await mount(tester, p);

      final first = p.layer.getEffects().first;
      expect(first.enabled(), isTrue);

      await tester.tap(find.byKey(ValueKey<String>('fx-enabled-${first.id()}')));
      await tester.pump();
      expect(p.layer.getEffects().first.enabled(), isFalse,
          reason: 'bypassing an effect is a document edit, not a view state');

      // Reorder: the second card's up arrow swaps the pair.
      final before = p.layer.getEffects().map((e) => e.name()).toList();
      final second = p.layer.getEffects()[1];
      await tester.tap(find.byKey(ValueKey<String>('fx-up-${second.id()}')));
      await tester.pump();
      expect(p.layer.getEffects().map((e) => e.name()).toList(),
          before.reversed.toList());

      // Remove: the stack shortens by exactly one.
      final top = p.layer.getEffects().first;
      await tester.tap(find.byKey(ValueKey<String>('fx-remove-${top.id()}')));
      await tester.pump();
      expect(p.layer.getEffects(), hasLength(1));
    });

    testWidgets('the top card cannot move up and the bottom cannot move down',
        (tester) async {
      final p = withLayer();
      p.layer.addEffect(name: 'blur');
      p.layer.addEffect(name: 'sharpen');
      await mount(tester, p);

      final effects = p.layer.getEffects();
      final order = effects.map((e) => e.name()).toList();

      // Both are present but inert, so the row's shape does not shift.
      await tester.tap(find.byKey(ValueKey<String>('fx-up-${effects[0].id()}')));
      await tester.pump();
      await tester
          .tap(find.byKey(ValueKey<String>('fx-down-${effects[1].id()}')));
      await tester.pump();

      expect(p.layer.getEffects().map((e) => e.name()).toList(), order,
          reason: 'a disabled arrow does nothing rather than wrapping around');
    });

    testWidgets('the Transform rows draw every property and commit one at a time',
        (tester) async {
      final p = withLayer();
      await mount(tester, p);

      expect(find.text('Transform'), findsOneWidget);
      for (final row in ['Anchor point', 'Position', 'Scale', 'Rotation',
          'Opacity']) {
        expect(find.text(row), findsOneWidget, reason: row);
      }

      final before = p.layer.getTransform();
      await tester.tap(find.byKey(const ValueKey('tf-opacity')));
      await tester.pump();
      await tester.enterText(find.byType(EditableText).first, '40');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      final after = p.layer.getTransform();
      expect((after.opacity as BridgeScalar_Static).field0, 40);
      expect(after.positionX, before.positionX,
          reason: 'one property per op — nothing else moved');
    });

    /// A 2D layer showing 3D controls that cannot do anything is worse than not
    /// showing them, so the z and x/y-rotation rows are gated on the switch.
    testWidgets('the 3D rows appear only on a 3D layer', (tester) async {
      final p = withLayer();
      await mount(tester, p);

      expect(p.layer.isThreeD(), isFalse);
      expect(find.text('Rotation x'), findsNothing);
      expect(find.text('Rotation y'), findsNothing);
      // Position draws two cells, not three, when the layer is flat.
      expect(find.byKey(const ValueKey('tf-positionZ')), findsNothing);
      expect(find.byKey(const ValueKey('tf-positionX')), findsOneWidget);
      expect(find.byKey(const ValueKey('tf-positionY')), findsOneWidget);
    });

    /// The one thing a panel that cannot yet edit curves must not do: flatten
    /// one. `set_value` takes a whole animation, so a static write over a
    /// keyframed parameter would delete every key in a single undoable step
    /// that looks like nudging a number.
    testWidgets('an animated parameter is shown as animated, not as a field',
        (tester) async {
      final p = withLayer();
      p.layer.addEffect(name: 'blur');

      // Animate the radius behind the panel's back, the way the graph editor
      // will once it exists.
      final staged = p.layer.getEffects();
      staged.single.setValue(
        id: 'radius',
        value: BridgeEffectValue.float(BridgeScalar.keyframed([
          BridgeKeyframe(
            time: const BridgeRational(num: 0, den: 1),
            value: 4,
            interpIn: const BridgeSideInterp.linear(),
            interpOut: const BridgeSideInterp.linear(),
          ),
          BridgeKeyframe(
            time: const BridgeRational(num: 1, den: 1),
            value: 40,
            interpIn: const BridgeSideInterp.linear(),
            interpOut: const BridgeSideInterp.linear(),
          ),
        ])),
      );
      p.layer.setEffects(effects: staged);

      await mount(tester, p);

      final id = p.layer.getEffects().single.id();
      expect(find.text('animated'), findsOneWidget);
      expect(find.byKey(ValueKey<String>('fx-float-$id-radius')), findsNothing,
          reason: 'no editor is offered, so the curve cannot be flattened');
      // The effect's other float is untouched: only the animated one loses its
      // field, not the whole card.
      expect(find.byKey(ValueKey<String>('fx-float-$id-mix')), findsOneWidget);

      // …and it is still a curve after the panel has drawn it.
      final after = p.layer.getEffects().single.getValue(id: 'radius');
      expect(
        (after as BridgeEffectValue_Float).field0,
        isA<BridgeScalar_Keyframed>(),
      );
    });
    // Without the built library there is nothing to test against; the harness
    // throws with the command to run.
  }, skip: !engineAvailable);
}
