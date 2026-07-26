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
      await tester.pumpWidget(hostPanel(
        child: const TimelinePanelFrb(),
        state: p.state as LumitState,
        uiState: p.uiState as LumitUiState,
        size: const Size(1000, 500),
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

      expect(find.byKey(const ValueKey('graph-lane-tf-opacity')), findsOneWidget);
      expect(find.text('Opacity'), findsOneWidget);
      for (var i = 0; i < 3; i++) {
        expect(find.byKey(ValueKey<String>('graph-key-tf-opacity#$i')),
            findsOneWidget);
      }
      // Only animated channels get a lane; Position is still static.
      expect(find.byKey(const ValueKey('graph-lane-tf-positionX')), findsNothing);
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
          tester, find.byKey(const ValueKey('graph-key-tf-opacity#1')),
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
          tester, find.byKey(const ValueKey('graph-key-tf-opacity#1')),
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

      final frames =
          (p.layer.getTransform().opacity as BridgeScalar_Keyframed)
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
