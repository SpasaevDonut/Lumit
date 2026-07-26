// The Timeline panel on frb, tested against the real engine.
//
// New coverage: the v0 Timeline's tests are spread across several files and
// written against a fake bridge and a snapshot mirror, neither of which this
// panel has. What they assert about *behaviour* is reproduced here against the
// document itself — a switch that does not reach the engine is not a switch.

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/panels/project_panel_frb.dart';
import 'package:lumit_flutter/panels/timeline_panel_frb.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';

import 'frb_test_support.dart';

void main() {
  setUpAll(initEngineForTests);

  group('Timeline (frb)', () {
    ({LumitState state, LumitUiState uiState, CompositionReference comp})
        withComp() {
      final p = freshProject();
      final comp = p.state.project!.newComposition(name: 'Scene');
      p.uiState.setSelectedComp(comp);
      return (state: p.state, uiState: p.uiState, comp: comp);
    }

    Future<void> mount(WidgetTester tester, dynamic p) async {
      await tester.pumpWidget(hostPanel(
        child: const TimelinePanelFrb(),
        state: p.state as LumitState,
        uiState: p.uiState as LumitUiState,
        size: const Size(900, 400),
      ));
      await tester.pump();
    }

    testWidgets('without a composition it says so', (tester) async {
      final p = freshProject();
      await tester.pumpWidget(hostPanel(
        child: const TimelinePanelFrb(),
        state: p.state,
        uiState: p.uiState,
      ));
      await tester.pump();
      expect(find.textContaining('Select a composition'), findsOneWidget);
    });

    testWidgets('New layer adds every kind, newest on top', (tester) async {
      final p = withComp();
      await mount(tester, p);

      for (final kind in [
        'Solid',
        'Text',
        'Camera',
        'Adjustment',
        'Sequence'
      ]) {
        await tester.tap(find.byKey(const ValueKey('tl-add-layer')));
        await tester.pumpAndSettle();
        await tester.tap(find.text(kind));
        await tester.pumpAndSettle();
      }

      final layers = p.comp.getLayers();
      expect(layers, hasLength(5));
      expect(layers.first.getKind(), BridgeLayerKind.sequence,
          reason: 'the newest layer is at the top of the stack');
      expect(
          find.byKey(
              ValueKey<String>('tl-row-${layers.first.internallayerId}')),
          findsOneWidget);
    });

    testWidgets('the switch column reaches the document', (tester) async {
      final p = withComp();
      final layer = p.comp.addAdjustmentLayer();
      await mount(tester, p);

      final id = layer.internallayerId.toString();
      expect(layer.getSwitches().visible, isTrue);

      await tester.tap(find.byKey(ValueKey<String>('tl-visible-$id')));
      await tester.pump();
      expect(layer.getSwitches().visible, isFalse,
          reason: 'hiding a layer is a document edit, not a view state');

      await tester.tap(find.byKey(ValueKey<String>('tl-solo-$id')));
      await tester.pump();
      expect(layer.getSwitches().solo, isTrue);
      expect(layer.getSwitches().visible, isFalse,
          reason: 'one switch does not disturb another');
    });

    testWidgets('the blend dropdown commits by index', (tester) async {
      final p = withComp();
      final layer = p.comp.addAdjustmentLayer();
      await mount(tester, p);

      expect(layer.getBlend(), 0);
      final modes = listBlendModes();

      await tester.tap(
          find.byKey(ValueKey<String>('tl-blend-${layer.internallayerId}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(modes[2]).last);
      await tester.pumpAndSettle();

      expect(layer.getBlend(), 2,
          reason:
              'the index the dropdown shows is the index the engine stores');
    });

    testWidgets('the row menu duplicates, reorders and deletes',
        (tester) async {
      final p = withComp();
      p.comp.addAdjustmentLayer();
      await mount(tester, p);

      final first = p.comp.getLayers().single;
      await tester.tapAt(
        tester.getCenter(
            find.byKey(ValueKey<String>('tl-row-${first.internallayerId}'))),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Duplicate'));
      await tester.pumpAndSettle();
      expect(p.comp.getLayers(), hasLength(2));

      // The bottom row can be brought forward but not sent back.
      final bottom = p.comp.getLayers()[1];
      await tester.tapAt(
        tester.getCenter(
            find.byKey(ValueKey<String>('tl-row-${bottom.internallayerId}'))),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      expect(find.text('Send backward'), findsNothing);
      await tester.tap(find.text('Bring forward'));
      await tester.pumpAndSettle();
      expect(p.comp.getLayers().first.internallayerId, bottom.internallayerId);

      await tester.tapAt(
        tester.getCenter(
            find.byKey(ValueKey<String>('tl-row-${bottom.internallayerId}'))),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(p.comp.getLayers(), hasLength(1));
    });

    testWidgets('clicking the ruler scrubs the playhead', (tester) async {
      final p = withComp();
      p.comp.addAdjustmentLayer();
      await mount(tester, p);

      expect(p.uiState.playheadFrame.value, 0);
      final ruler = find.byKey(const ValueKey('tl-ruler'));
      final box = tester.getRect(ruler);
      await tester.tapAt(Offset(box.left + box.width * 0.5, box.center.dy));
      await tester.pump();

      final frames = p.comp.getSettings().durationFrames.toInt();
      expect(p.uiState.playheadFrame.value, closeTo(frames * 0.5, 2),
          reason: 'the tap landed halfway along the comp');
      expect(p.uiState.playheadFrame.value, lessThan(frames),
          reason: 'the playhead never leaves the comp');
    });

    testWidgets('dragging a bar moves the layer as one op', (tester) async {
      final p = withComp();
      final layer = p.comp.addAdjustmentLayer();
      await mount(tester, p);

      final before = layer.getSpan();
      final beforeIn = p.comp.frameAtTime(time: before.inPoint);

      final bar =
          find.byKey(ValueKey<String>('tl-bar-${layer.internallayerId}'));
      final rect = tester.getRect(bar);
      // Well inside the bar, so this is a move rather than a trim.
      await tester.dragFrom(
        Offset(rect.left + rect.width * 0.5, rect.center.dy),
        const Offset(80, 0),
      );
      await tester.pumpAndSettle();

      final after = layer.getSpan();
      final afterIn = p.comp.frameAtTime(time: after.inPoint);
      expect(afterIn, greaterThan(beforeIn),
          reason: 'the bar moved later in the comp');

      // One op for the whole gesture: a single undo puts it back.
      p.state.project!.undo();
      expect(p.comp.frameAtTime(time: layer.getSpan().inPoint), beforeIn);
    });

    testWidgets('the work area and markers draw on the ruler', (tester) async {
      final p = withComp();
      p.comp.addAdjustmentLayer();
      p.comp.setWorkArea(
        span: BridgeSpan(
          inPoint: p.comp.timeOfFrame(frame: 10),
          outPoint: p.comp.timeOfFrame(frame: 40),
          startOffset: p.comp.timeOfFrame(frame: 0),
        ),
      );
      await mount(tester, p);

      expect(find.byKey(const ValueKey('tl-work-area')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('tl-clear-work-area')));
      await tester.pump();
      expect(p.comp.getWorkArea(), isNull);
      expect(find.byKey(const ValueKey('tl-work-area')), findsNothing);
    });
    // Without the built library there is nothing to test against; the harness
    // throws with the command to run.
    /// The gesture the whole Project panel drag exists for. It had no drop
    /// target at all: the drag lifted, showed feedback, and dropped into
    /// nothing, which reads as the app ignoring you.
    testWidgets('footage dragged from the Project panel becomes a layer',
        (tester) async {
      final p = withComp();
      final footage = p.state.project!.importFootage(path: 'C:/clips/shot.mov');

      // Both panels in one tree, so the drag is the real one rather than a
      // DragTarget poked directly.
      await tester.pumpWidget(hostPanel(
        child: const Row(
          children: [
            SizedBox(width: 300, child: ProjectPanelFrb()),
            Expanded(child: TimelinePanelFrb()),
          ],
        ),
        state: p.state,
        uiState: p.uiState,
        size: const Size(1400, 700),
      ));
      await tester.pump();

      expect(p.comp.getLayers(), isEmpty);

      final row =
          find.byKey(ValueKey<String>('project-row-${footage.internalid}'));
      expect(row, findsOneWidget, reason: 'the footage row is there to drag');

      final gesture = await tester.startGesture(tester.getCenter(row));
      await tester.pump(const Duration(milliseconds: 200));
      // Stepped, because one large move leaves the gesture arena resolving the
      // drag against the row's own recognisers.
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(const Offset(40, 0));
        await tester.pump();
      }
      await gesture.up();
      await tester.pumpAndSettle();

      expect(p.comp.getLayers(), hasLength(1),
          reason: 'the drop reached the document');
      expect(p.comp.getLayers().single.getName(), contains('shot'));
    });
  }, skip: !engineAvailable);
}
