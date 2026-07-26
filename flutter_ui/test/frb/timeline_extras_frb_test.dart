// The Timeline's chrome on frb: comp tabs, cache bar, search, the parent
// picker, markers, the work area and the razor.
//
// Driven through the panel rather than in isolation, for the same reason as
// everywhere else here: what matters is that a click reaches the document.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/panels/timeline_panel_frb.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';

import 'frb_test_support.dart';

void main() {
  setUpAll(initEngineForTests);

  group('Timeline chrome (frb)', () {
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
        size: const Size(1000, 400),
      ));
      await tester.pump();
    }

    testWidgets('the comp tabs list every composition and front one',
        (tester) async {
      final p = withComp();
      final second = p.state.project!.newComposition(name: 'Titles');
      await mount(tester, p);

      expect(find.byKey(ValueKey<String>('tl-tab-${p.comp.internalid}')),
          findsOneWidget);
      final tab = find.byKey(ValueKey<String>('tl-tab-${second.internalid}'));
      expect(tab, findsOneWidget,
          reason: 'a comp filed in a folder is still a tab');

      await tester.tap(tab);
      await tester.pump();
      expect(p.uiState.selectedComp?.internalid, second.internalid);
    });

    testWidgets('search narrows the outline to matching rows', (tester) async {
      final p = withComp();
      p.comp.addTextLayer();
      p.comp.addCameraLayer();
      await mount(tester, p);

      expect(find.text('Text'), findsOneWidget);
      expect(find.text('Camera'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('tl-search')), 'cam');
      await tester.pump();

      expect(find.text('Camera'), findsOneWidget);
      expect(find.text('Text'), findsNothing,
          reason: 'search hides the rows that do not match');
    });

    testWidgets('the parent picker parents a layer and refuses a cycle',
        (tester) async {
      final p = withComp();
      final parent = p.comp.addAdjustmentLayer();
      final child = p.comp.addCameraLayer();
      await mount(tester, p);

      expect(child.getParent(), isNull);
      await tester.tap(
          find.byKey(ValueKey<String>('tl-parent-${child.internallayerId}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(parent.getName()).last);
      await tester.pumpAndSettle();

      expect(child.getParent(), parent.internallayerId);

      // Clearing it is a first-class choice, not an error state.
      await tester.tap(
          find.byKey(ValueKey<String>('tl-parent-${child.internallayerId}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('None').last);
      await tester.pumpAndSettle();
      expect(child.getParent(), isNull);
    });

    testWidgets('Set in and Set out move the work area, Clear removes it',
        (tester) async {
      final p = withComp();
      p.comp.addAdjustmentLayer();
      await mount(tester, p);

      expect(p.comp.getWorkArea(), isNull);

      p.uiState.playheadFrame.value = 20;
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('tl-work-in')));
      await tester.pump();

      var area = p.comp.getWorkArea();
      expect(area, isNotNull);
      expect(p.comp.frameAtTime(time: area!.inPoint), 20);

      p.uiState.playheadFrame.value = 60;
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('tl-work-out')));
      await tester.pump();

      area = p.comp.getWorkArea();
      expect(p.comp.frameAtTime(time: area!.outPoint), 60);
      expect(p.comp.frameAtTime(time: area.inPoint), 20,
          reason: 'setting the out point leaves the in point alone');

      await tester.tap(find.byKey(const ValueKey('tl-clear-work-area')));
      await tester.pump();
      expect(p.comp.getWorkArea(), isNull);
    });

    /// A work area with no length is not a work area, so the opposite edge gives
    /// way rather than the click being ignored.
    testWidgets('setting the out point before the in point still leaves length',
        (tester) async {
      final p = withComp();
      p.comp.addAdjustmentLayer();
      await mount(tester, p);

      p.uiState.playheadFrame.value = 40;
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('tl-work-in')));
      await tester.pump();

      p.uiState.playheadFrame.value = 10;
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('tl-work-out')));
      await tester.pump();

      final area = p.comp.getWorkArea()!;
      final start = p.comp.frameAtTime(time: area.inPoint);
      final end = p.comp.frameAtTime(time: area.outPoint);
      expect(end, greaterThan(start), reason: 'it always has length');
    });

    testWidgets('the marker editor adds at the playhead and removes',
        (tester) async {
      final p = withComp();
      p.comp.addAdjustmentLayer();
      await mount(tester, p);

      p.uiState.playheadFrame.value = 33;
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('tl-markers')));
      await tester.pumpAndSettle();

      expect(find.text('No markers yet'), findsOneWidget);
      await tester.enterText(
          find.byKey(const ValueKey('marker-label')), 'Chorus');
      await tester.tap(find.byKey(const ValueKey('marker-add')));
      await tester.pumpAndSettle();

      final markers = p.comp.getMarkers();
      expect(markers, hasLength(1));
      expect(markers.single.label, 'Chorus');
      expect(p.comp.frameAtTime(time: markers.single.time), 33,
          reason: 'the marker landed on the playhead');

      await tester
          .tap(find.byKey(ValueKey<String>('marker-remove-${markers.single.id}')));
      await tester.pumpAndSettle();
      expect(p.comp.getMarkers(), isEmpty);

      await tester.tap(find.byKey(const ValueKey('marker-close')));
      await tester.pumpAndSettle();
    });

    testWidgets('the razor cuts a sequence clip and leaves other bars alone',
        (tester) async {
      final p = withComp();
      final footage =
          p.state.project!.importFootage(path: 'C:/clips/shot.mov');
      p.comp.addFootageLayer(footage: footage);
      final layer = p.comp.getLayers().single;
      layer.convertToSequenced();
      final sequenced = p.comp.getLayers().single;
      expect(sequenced.getClips(), hasLength(1));

      await mount(tester, p);
      p.uiState.playheadFrame.value = 12;
      await tester.pump();

      // Unarmed, a click on the bar does not cut.
      final bar = find
          .byKey(ValueKey<String>('tl-bar-${sequenced.internallayerId}'));
      await tester.tapAt(tester.getCenter(bar));
      await tester.pump();
      expect(p.comp.getLayers().single.getClips(), hasLength(1),
          reason: 'the razor is a mode, not the default click');

      await tester.tap(find.byKey(const ValueKey('tl-razor')));
      await tester.pump();
      await tester.tapAt(tester.getCenter(bar));
      await tester.pumpAndSettle();

      expect(p.comp.getLayers().single.getClips(), hasLength(2),
          reason: 'the armed razor cut the clip at the playhead');
    });

    testWidgets('the cache bar reads the engine and clears on click',
        (tester) async {
      final p = withComp();
      p.comp.addAdjustmentLayer();
      await mount(tester, p);

      expect(find.byKey(const ValueKey('tl-cache-bar')), findsOneWidget);
      // Clicking empties it; the readout is live, so this must not throw with
      // no project rendered yet.
      await tester.tap(find.byKey(const ValueKey('tl-cache-bar')));
      await tester.pump();
      expect(find.byKey(const ValueKey('tl-cache-bar')), findsOneWidget);
    });
    // Without the built library there is nothing to test against; the harness
    // throws with the command to run.
  }, skip: !engineAvailable);
}
