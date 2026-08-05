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
import 'package:lumit_flutter/widgets/controls.dart';
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
    ({LumitState state, LumitUiState uiState, LayerReference layer})
        withLayer() {
      final p = freshProject();
      final comp = p.state.project!.newComposition(name: 'Scene');
      final footage = p.state.project!.importFootage(path: 'C:/clips/shot.mov');
      comp.addFootageLayer(footage: footage, asSequence: false);
      final layer = comp.getLayers().single;
      p.uiState
        ..setSelectedComp(comp)
        ..selectedLayer.value = layer;
      return (state: p.state, uiState: p.uiState, layer: layer);
    }

    Future<void> mount(
      WidgetTester tester,
      ({LumitState state, LumitUiState uiState, LayerReference layer}) p, {
      // The Transform card is off by default (K-193); the rows it holds are
      // still this panel's to test, so the tests that want them ask for it
      // exactly as a user would.
      bool transform = true,
    }) async {
      p.uiState.workspace.interface.transformInEffectControls = transform;
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

    testWidgets('deselecting a layer keeps the last one on the panel',
        (tester) async {
      final p = withLayer();
      await mount(tester, p);
      expect(find.textContaining('No effects'), findsOneWidget);

      p.uiState.selectedLayer.value = null;
      await tester.pump();
      // Still the same layer's stack: clicking away in the Timeline is not a
      // request to lose your place.
      expect(find.textContaining('Select a layer'), findsNothing);
      expect(find.textContaining('No effects'), findsOneWidget);
    });

    testWidgets('Add effect commits one, and it appears as a card',
        (tester) async {
      final p = withLayer();
      await mount(tester, p);

      expect(find.textContaining('No effects'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('fx-add')));
      await tester.pumpAndSettle();
      // The menu lists categories, each opening onto its effects by their
      // sentence-case label — the raw match_name never reaches the user
      // (K-194: Add effect → Blur & sharpen → Gaussian blur).
      expect(find.text('Gaussian blur'), findsNothing,
          reason: 'the effects wait behind their category');
      await tester.tap(find.byKey(const ValueKey('fx-category-blur_sharpen')));
      await tester.pumpAndSettle();
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

    testWidgets(
        'a null layer says its effects change no picture, and keeps their values',
        (tester) async {
      // K-274: effects on a null are ACCEPTED and labelled inert rather than
      // refused. A null draws nothing, so nothing here changes a picture — but
      // the parameters are real, animatable values, which is the whole point
      // of putting a control on a null.
      final p = freshProject();
      final comp = p.state.project!.newComposition(name: 'Scene');
      final nul = comp.addNullLayer();
      p.uiState
        ..setSelectedComp(comp)
        ..selectedLayer.value = nul;

      await tester.pumpWidget(hostPanel(
        child: const EffectControlsPanelFrb(),
        state: p.state,
        uiState: p.uiState,
      ));
      await tester.pump();
      expect(find.byKey(const ValueKey('fx-null-inert')), findsNothing,
          reason: 'nothing to say about a stack that is empty');

      nul.addEffect(name: 'blur');
      p.uiState.model.refresh();
      await tester.pump();
      expect(find.byKey(const ValueKey('fx-null-inert')), findsOneWidget,
          reason: 'the drop is accepted, and the panel says what it does');

      // And the effect is genuinely on the layer, with a readable value — the
      // difference between "inert" and "refused". (That those values stay
      // live and animatable is pinned engine-side, where the commit is:
      // `an_effect_on_a_null_layer_keeps_its_animated_value`.)
      expect(nul.getEffects().length, 1);
      expect(find.text('Gaussian blur'), findsOneWidget,
          reason: 'the stack draws as it does on any other layer');
    });

    testWidgets('a selection made in the Viewer switches the panel to it',
        (tester) async {
      // The Viewer picks a layer by calling `setSelection` on the shell — it
      // never goes through the Timeline — so this panel must follow the shell,
      // not the panel that happens to be next to it (K-275).
      final p = withLayer();
      p.layer.addEffect(name: 'blur');
      final other = p.uiState.selectedComp!.addSolidLayer();
      other.addEffect(name: 'invert');
      await mount(tester, p);
      expect(find.text('Gaussian blur'), findsOneWidget);

      p.uiState.setSelection([other]);
      await tester.pump();

      expect(find.text('Invert'), findsOneWidget,
          reason: "the panel shows the newly selected layer's stack");
      expect(find.text('Gaussian blur'), findsNothing,
          reason: 'and not the one it was showing before');
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

      final radius = p.layer.getEffects().single.getValue(id: 'radius');
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

    /// **The drag regression.** A parameter could be typed into but not dragged:
    /// the panel held the stack of effect handles across the whole gesture, and
    /// a `BridgeEffectInstance` passed to `renderFrameWithPreview` is *moved* —
    /// frb disposes the Dart side of it — so the first preview tick killed the
    /// handles and every tick after it threw `DroppableDisposedException`. What
    /// is staged now is the edit, not the handles.
    testWidgets('a parameter can be dragged, not only typed into',
        (tester) async {
      final p = withLayer();
      p.layer.addEffect(name: 'blur');
      await mount(tester, p);

      final id = p.layer.getEffects().single.id();
      double radius() => ((p.layer.getEffects().single.getValue(id: 'radius')
                  as BridgeEffectValue_Float)
              .field0 as BridgeScalar_Static)
          .field0;
      final before = radius();

      await tester.drag(
        find.byKey(ValueKey<String>('fx-float-$id-radius')),
        const Offset(60, 0),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull,
          reason: 'no handle was used after it had been handed to Rust');
      expect(radius(), greaterThan(before),
          reason: 'the drag reached the document');
    });

    testWidgets('the enable switch, reorder and remove all reach the document',
        (tester) async {
      final p = withLayer();
      p.layer.addEffect(name: 'blur');
      p.layer.addEffect(name: 'sharpen');
      await mount(tester, p);

      final first = p.layer.getEffects().first;
      expect(first.enabled(), isTrue);

      await tester
          .tap(find.byKey(ValueKey<String>('fx-enabled-${first.id()}')));
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
      await tester
          .tap(find.byKey(ValueKey<String>('fx-up-${effects[0].id()}')));
      await tester.pump();
      await tester
          .tap(find.byKey(ValueKey<String>('fx-down-${effects[1].id()}')));
      await tester.pump();

      expect(p.layer.getEffects().map((e) => e.name()).toList(), order,
          reason: 'a disabled arrow does nothing rather than wrapping around');
    });

    testWidgets('an effect twirls shut, and its rows go with it',
        (tester) async {
      final p = withLayer();
      p.layer.addEffect(name: 'blur');
      await mount(tester, p, transform: false);

      final id = p.layer.getEffects().single.id();
      expect(find.text('Radius'), findsOneWidget,
          reason: 'a newly applied effect arrives open');

      // The heading is the twirl: anywhere on it, not only the caret.
      await tester.tap(find.text('Gaussian blur'));
      await tester.pump();
      expect(find.text('Radius'), findsNothing);
      expect(find.byKey(ValueKey<String>('fx-enabled-$id')), findsOneWidget,
          reason: 'a shut effect still shows its heading and its switch');

      await tester.tap(find.text('Gaussian blur'));
      await tester.pump();
      expect(find.text('Radius'), findsOneWidget);
    });

    testWidgets('Reset puts every parameter back and drops its keyframes',
        (tester) async {
      final p = withLayer();
      p.layer.addEffect(name: 'blur');
      final before = p.layer.getEffects().single.getValue(id: 'radius');
      await mount(tester, p, transform: false);

      // Animate it and move it away from its default, so Reset has both a
      // changed value and a curve to undo.
      final id = p.layer.getEffects().single.id();
      final stack = p.layer.getEffects();
      stack.single.setValue(
        id: 'radius',
        value: BridgeEffectValue.float(BridgeScalar.keyframed([
          BridgeKeyframe(
            time: const BridgeRational(num: 0, den: 1),
            value: 40,
            interpIn: const BridgeSideInterp.linear(),
            interpOut: const BridgeSideInterp.linear(),
          ),
        ])),
      );
      p.layer.setEffects(effects: stack);
      p.uiState.model.refresh();
      await tester.pump();

      await tester.tap(find.byKey(ValueKey<String>('fx-reset-$id')));
      await tester.pump();

      expect(p.layer.getEffects().single.getValue(id: 'radius'), before,
          reason: 'the schema default is written back, curve and all');
    });

    testWidgets(
        'the Transform rows draw every property and commit one at a time',
        (tester) async {
      final p = withLayer();
      await mount(tester, p);

      expect(find.text('Transform'), findsOneWidget);
      for (final row in [
        'Anchor point',
        'Position',
        'Scale',
        'Rotation',
        'Opacity'
      ]) {
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

    /// **The stale-value regression.** A row only ever changed when it wrote
    /// the value itself. So an undo moved the picture and left the number
    /// behind, and the same property edited in the Timeline's fold-out never
    /// reached this panel — one miss, two symptoms: nothing here listened to
    /// the engine. Fails without the read model's change subscription and its
    /// revision check (K-184).
    testWidgets('an edit made elsewhere, and an undo, both reach the rows',
        (tester) async {
      final p = withLayer();
      await mount(tester, p);
      expect(find.text('100%'), findsOneWidget, reason: 'opacity as it starts');

      // What the Timeline's fold-out does when the same row is dragged there.
      p.layer.setTransform(
          prop: BridgeTransformProp.opacity, value: BridgeScalar.static_(40));
      await settleFrb(tester,
          until: () => find.text('40%').evaluate().isNotEmpty);
      expect(find.text('40%'), findsOneWidget,
          reason: 'an edit made in the other panel shows here');

      p.state.project!.undo();
      await settleFrb(tester,
          until: () => find.text('100%').evaluate().isNotEmpty);
      expect(find.text('100%'), findsOneWidget,
          reason: 'undo puts the number back, not only the picture');
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

    /// An animated parameter stays a field (docs/07 §4.3): editing it writes
    /// the key under the playhead — never a static value over the curve,
    /// which would delete every key in one step that looks like nudging a
    /// number.
    testWidgets('editing an animated parameter edits the key, not the curve',
        (tester) async {
      final p = withLayer();
      p.layer.addEffect(name: 'blur');

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
      final field = find.byKey(ValueKey<String>('fx-float-$id-radius'));
      expect(field, findsOneWidget,
          reason: 'an animated parameter keeps its field');

      // The playhead sits on the first key: the drag edits that key.
      await tester.drag(field, const Offset(40, 0));
      await tester.pumpAndSettle();

      final after = p.layer.getEffects().single.getValue(id: 'radius');
      final scalar = (after as BridgeEffectValue_Float).field0;
      expect(scalar, isA<BridgeScalar_Keyframed>(),
          reason: 'the curve survives the edit');
      final keys = (scalar as BridgeScalar_Keyframed).field0;
      expect(keys, hasLength(2), reason: 'no key added or lost at a key');
      expect(keys.first.value, greaterThan(4),
          reason: 'the edit landed in the key under the playhead');
      expect(keys.last.value, 40, reason: 'the other key is untouched');
    });
    testWidgets(
        'the lens flare panel folds: point pair, groups, conditional matte rows',
        (tester) async {
      final p = withLayer();
      p.layer.addEffect(name: 'lens_flare');
      p.uiState.model.refresh();
      await mount(tester, p, transform: false);

      // The light x/y pair is ONE row (docs/07 SS6.1) with a shared stem
      // label, not two rows.
      expect(
        find.byWidgetPredicate((w) {
          final key = w.key;
          return key is ValueKey<String> &&
              key.value.startsWith('fx-row-') &&
              key.value.endsWith('-light_x-pair');
        }),
        findsOneWidget,
      );
      expect(find.text('Light'), findsOneWidget);
      expect(find.text('Light y'), findsNothing);

      // The collapsed groups show their headers, not their members.
      expect(find.text('Lens options'), findsOneWidget);
      expect(find.text('Flare options'), findsOneWidget);
      expect(find.text('Blades'), findsNothing);

      // Twirling Lens options open reveals the Int-kind Blades row.
      await tester.tap(find.text('Lens options'));
      await tester.pump();
      expect(find.text('Blades'), findsOneWidget);

      // The matte rows are hidden while Source is Manual...
      expect(find.text('Matte layer'), findsNothing);
      expect(find.text('Threshold'), findsNothing);

      // ...and appear when Source type switches to Matte.
      final effects = p.layer.getEffects();
      final fx = effects.single;
      fx.setValue(id: 'source_type', value: const BridgeEffectValue.choice(1));
      p.layer.setEffects(effects: effects);
      p.uiState.model.refresh();
      await tester.pump();
      expect(find.text('Matte layer'), findsOneWidget);
      expect(find.text('Threshold'), findsOneWidget);
      expect(find.text('Threshold softness'), findsOneWidget);

      // Light tint is a source-mode-independent row (K-259); Use source
      // colour appears with Matte and would with Lights.
      expect(find.text('Light tint'), findsOneWidget);
      expect(find.text('Use source colour'), findsOneWidget);

      // Back to Manual: the tint stays, the source-colour toggle and the
      // matte rows go.
      final again = p.layer.getEffects();
      again.single
          .setValue(id: 'source_type', value: const BridgeEffectValue.choice(0));
      p.layer.setEffects(effects: again);
      p.uiState.model.refresh();
      await tester.pump();
      expect(find.text('Light tint'), findsOneWidget);
      expect(find.text('Use source colour'), findsNothing);
      expect(find.text('Matte layer'), findsNothing);
    });

    // The Lens picker (K-262, curated K-264). Twenty entries sit well
    // under the searchable threshold, so the row is the PLAIN dropdown —
    // the searchable picker's laziness is pinned in
    // test/search_dropdown_test.dart against synthetic options. What the
    // panel owes here: the curated default shows, and the custom Lens file
    // row (K-264) is present for the prescriptions the palette leaves out.
    testWidgets('the lens picker shows the curated default and the file row',
        (tester) async {
      final p = withLayer();
      p.layer.addEffect(name: 'lens_flare');
      p.uiState.model.refresh();
      await mount(tester, p, transform: false);

      expect(find.byType(BareSearchDropdown), findsNothing,
          reason: 'twenty entries is a dropdown, not a search problem');
      expect(find.text('Zeiss · Arri Master Prime T1.3 50mm'), findsOneWidget,
          reason: 'the curated default is the reference cine prime');
      expect(find.text('Lens file'), findsOneWidget,
          reason: 'a user .lens file covers everything the palette leaves out');
    });

    // Without the built library there is nothing to test against; the harness
    // throws with the command to run.
  }, skip: !engineAvailable);
}
