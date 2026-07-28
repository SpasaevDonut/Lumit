// The graph editor on frb, against the real engine.
//
// New coverage: v0's graph editor is four lens files over a snapshot mirror, and
// its keyframe edits went through granular ops this API deliberately does not
// have. What is asserted here is the behaviour, not the shape.

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/panels/timeline_panel_frb.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:lumit_flutter/src/rust/api/effect.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';

import 'frb_test_support.dart';

void main() {
  setUpAll(initEngineForTests);

  group('Graph editor (frb)', () {
    ({
      LumitState state,
      LumitUiState uiState,
      CompositionReference comp,
      LayerReference layer,
    }) withLayer() {
      final p = freshProject();
      final comp = p.state.project!.newComposition(name: 'Scene');
      final layer = comp.addAdjustmentLayer();
      p.uiState
        ..setSelectedComp(comp)
        ..selectedLayer.value = layer;
      return (state: p.state, uiState: p.uiState, comp: comp, layer: layer);
    }

    /// A ramp on Opacity: 0 at frame 0 to 100 at frame 100.
    void animateOpacity(
      CompositionReference comp,
      LayerReference layer, {
      List<int> frames = const [0, 100],
    }) {
      layer.setTransform(
        prop: BridgeTransformProp.opacity,
        value: BridgeScalar.keyframed([
          for (final f in frames)
            BridgeKeyframe(
              time: comp.timeOfFrame(frame: f),
              value: f.toDouble(),
              interpIn: const BridgeSideInterp.linear(),
              interpOut: const BridgeSideInterp.linear(),
            ),
        ]),
      );
    }

    Future<void> mountGraph(WidgetTester tester, dynamic p) async {
      // The outline alone is 800 px of columns; the default 800×600 test
      // surface would push the Graph button (and the lanes) off screen.
      tester.view.physicalSize = const Size(1280, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(hostPanel(
        child: const TimelinePanelFrb(),
        state: p.state as LumitState,
        uiState: p.uiState as LumitUiState,
        size: const Size(1280, 600),
      ));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('tl-graph')));
      await tester.pump();
    }

    testWidgets('a layer with nothing animated says so', (tester) async {
      final p = withLayer();
      await mountGraph(tester, p);
      expect(find.textContaining('Nothing on this layer is animated'),
          findsOneWidget);
    });

    testWidgets('an animated property gets a lane with a diamond per key',
        (tester) async {
      final p = withLayer();
      animateOpacity(p.comp, p.layer, frames: [0, 40, 90]);
      await mountGraph(tester, p);

      expect(
          find.byKey(const ValueKey('graph-lane-tf-opacity')), findsOneWidget);
      expect(find.text('Opacity'), findsOneWidget);
      for (var i = 0; i < 3; i++) {
        expect(find.byKey(ValueKey<String>('graph-key-tf-opacity#$i')),
            findsOneWidget);
      }
      // Only animated channels get a lane; Position is still static.
      expect(
          find.byKey(const ValueKey('graph-lane-tf-positionX')), findsNothing);
    });

    /// The marquee (docs/TODO Timeline): a drag on the lane's background
    /// selects the keys inside the box, replacing the lane's old selection;
    /// a plain background click clears it.
    testWidgets('a marquee drag selects the keys it encloses', (tester) async {
      final p = withLayer();
      // Spread across the comp, so the keys sit far apart on the lane and a
      // box can honestly take some and not others.
      animateOpacity(p.comp, p.layer, frames: [0, 600, 1500]);
      await mountGraph(tester, p);

      // Drag from an empty band (clear of the frame-0 key's handle at the
      // left edge) to past the right edge: the box takes the later two keys
      // and leaves the first outside.
      final lane = find.byKey(const ValueKey('graph-marquee-tf-opacity'));
      final box = tester.getRect(lane);
      final start = Offset(box.left + box.width * 0.15, box.top + 2);
      final gesture = await tester.startGesture(start);
      // In steps, as a real pointer moves — a single jump can resolve the
      // gesture arena differently than a drag ever would.
      final end = box.bottomRight - const Offset(1, 1);
      for (var i = 1; i <= 8; i++) {
        await gesture.moveTo(start + (end - start) * (i / 8));
        await tester.pump();
      }
      await gesture.up();
      await tester.pump();
      expect(find.text('2 selected'), findsOneWidget,
          reason: 'the box swallowed the keys inside it, and only those');

      // A click on empty background clears the lane's selection.
      await tester.tapAt(start);
      await tester.pump();
      expect(find.text('0 selected'), findsOneWidget);
    });

    /// The whole reason the API takes a whole animation: one gesture, one op.
    testWidgets('dragging a key moves it in time and value as one undo step',
        (tester) async {
      final p = withLayer();
      animateOpacity(p.comp, p.layer);
      await mountGraph(tester, p);

      final before =
          (p.layer.getTransform().opacity as BridgeScalar_Keyframed).field0;
      final beforeFrame = p.comp.frameAtTime(time: before[1].time);

      // Rightwards: dragging left from frame 100 would clamp past zero onto the
      // first key, which the collision guard refuses — a different behaviour,
      // tested below.
      await _dragKey(
          tester,
          find.byKey(const ValueKey('graph-key-tf-opacity#1')),
          const Offset(120, -20));

      final after =
          (p.layer.getTransform().opacity as BridgeScalar_Keyframed).field0;
      expect(after, hasLength(2));
      final afterFrame = p.comp.frameAtTime(time: after[1].time);
      expect(afterFrame, greaterThan(beforeFrame), reason: 'it moved later');
      expect(after[1].value, isNot(before[1].value),
          reason: 'and its value changed in the same gesture');

      p.state.project!.undo();
      final undone =
          (p.layer.getTransform().opacity as BridgeScalar_Keyframed).field0;
      expect(p.comp.frameAtTime(time: undone[1].time), beforeFrame,
          reason: 'one undo puts back both the time and the value');
    });

    /// Two keys cannot share a time — the engine refuses a curve whose times do
    /// not strictly ascend — so a key dragged onto its neighbour stays put
    /// rather than the write failing and the lane appearing to swallow it.
    testWidgets('a key dragged onto its neighbour does not land there',
        (tester) async {
      final p = withLayer();
      animateOpacity(p.comp, p.layer, frames: [0, 10]);
      await mountGraph(tester, p);

      // Far enough left that the second key would clamp onto the first.
      await _dragKey(
          tester,
          find.byKey(const ValueKey('graph-key-tf-opacity#1')),
          const Offset(-900, 0));

      final keys =
          (p.layer.getTransform().opacity as BridgeScalar_Keyframed).field0;
      expect(keys, hasLength(2), reason: 'neither key was lost');
      final frames = keys.map((k) => p.comp.frameAtTime(time: k.time)).toList();
      expect(frames[0], isNot(frames[1]), reason: 'they still differ in time');
    });

    testWidgets('the interp menu eases a key and deletes it', (tester) async {
      final p = withLayer();
      animateOpacity(p.comp, p.layer);
      await mountGraph(tester, p);

      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('graph-key-tf-opacity#0'))),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Easy ease'));
      await tester.pumpAndSettle();

      var keys =
          (p.layer.getTransform().opacity as BridgeScalar_Keyframed).field0;
      expect(keys[0].interpOut, isA<BridgeSideInterp_Bezier>(),
          reason: 'the AE easy-ease constant went to the document');

      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('graph-key-tf-opacity#0'))),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete key'));
      await tester.pumpAndSettle();

      keys = (p.layer.getTransform().opacity as BridgeScalar_Keyframed).field0;
      expect(keys, hasLength(1));
    });

    /// The fx keyframe lane carries the same interpolation menu the transform
    /// lanes do (docs/TODO: "Effect-param interpolation menu") — the lane
    /// machinery is one implementation, so an eased blur is one right-click.
    testWidgets('an effect parameter lane has the interpolation menu',
        (tester) async {
      final p = withLayer();
      p.layer.addEffect(name: 'blur');
      // A staged copy plus set_effects is the commit, exactly as the Effect
      // controls panel writes (K-065).
      final staged = p.layer.getEffects();
      staged.single.setValue(
        id: 'radius',
        value: BridgeEffectValue.float(BridgeScalar.keyframed([
          BridgeKeyframe(
            time: p.comp.timeOfFrame(frame: 0),
            value: 0,
            interpIn: const BridgeSideInterp.linear(),
            interpOut: const BridgeSideInterp.linear(),
          ),
          BridgeKeyframe(
            time: p.comp.timeOfFrame(frame: 900),
            value: 40,
            interpIn: const BridgeSideInterp.linear(),
            interpOut: const BridgeSideInterp.linear(),
          ),
        ])),
      );
      p.layer.setEffects(effects: staged);
      final effect = p.layer.getEffects().single;
      await mountGraph(tester, p);

      final key =
          find.byKey(ValueKey<String>('graph-key-${effect.id()}-radius#0'));
      expect(key, findsOneWidget, reason: 'the effect parameter has a lane');
      await tester.tapAt(tester.getCenter(key), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Easy ease'));
      await tester.pumpAndSettle();

      final value = p.layer.getEffects().single.getValue(id: 'radius')
          as BridgeEffectValue_Float;
      final keys = (value.field0 as BridgeScalar_Keyframed).field0;
      expect(keys[0].interpOut, isA<BridgeSideInterp_Bezier>(),
          reason: 'the ease reached the effect keyframe in the document');
    });

    /// A curve with no keys is not something the engine can evaluate, so the
    /// last key deleted has to leave a static value rather than an empty list.
    testWidgets('deleting the last key leaves a static value', (tester) async {
      final p = withLayer();
      animateOpacity(p.comp, p.layer, frames: [30]);
      await mountGraph(tester, p);

      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('graph-key-tf-opacity#0'))),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete key'));
      await tester.pumpAndSettle();

      final opacity = p.layer.getTransform().opacity;
      expect(opacity, isA<BridgeScalar_Static>());
      expect((opacity as BridgeScalar_Static).field0, 30,
          reason: 'it holds what the deleted key held');
    });

    testWidgets('copy and paste move keys onto the playhead', (tester) async {
      final p = withLayer();
      animateOpacity(p.comp, p.layer, frames: [0, 20]);
      await mountGraph(tester, p);

      // Select the second key and copy it.
      await tester.tap(find.byKey(const ValueKey('graph-key-tf-opacity#1')));
      await tester.pump();
      expect(find.text('1 selected'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('graph-copy')));
      await tester.pump();

      p.uiState.playheadFrame.value = 75;
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('graph-paste')));
      await tester.pumpAndSettle();

      final frames = (p.layer.getTransform().opacity as BridgeScalar_Keyframed)
          .field0
          .map((k) => p.comp.frameAtTime(time: k.time))
          .toList();
      expect(frames, contains(75),
          reason: 'the earliest pasted key lands on the playhead');
      expect(frames, hasLength(3));
    });
    // Without the built library there is nothing to test against; the harness
    // throws with the command to run.
  }, skip: !engineAvailable);
}

/// Drag a keyframe diamond in steps rather than one jump.
///
/// A single large pointer move leaves the gesture arena to resolve a pan
/// against the lane list's own vertical drag from one ambiguous sample; stepping
/// is both what a real drag looks like and what lets the pan win.
Future<void> _dragKey(WidgetTester tester, Finder key, Offset by) async {
  final gesture = await tester.startGesture(tester.getCenter(key));
  await tester.pump();
  const steps = 10;
  for (var i = 0; i < steps; i++) {
    await gesture.moveBy(by / steps.toDouble());
    await tester.pump();
  }
  await gesture.up();
  await tester.pumpAndSettle();
}
