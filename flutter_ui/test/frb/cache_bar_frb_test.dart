// The cache bar: the stripe under the time ruler showing which frames are held
// (docs/07-UI-SPEC.md §3.2, docs/06-RENDER-PIPELINE.md §5.6).
//
// The run collapsing is a pure function and tested as one. What it draws is
// tested against the real engine, because the question the bar answers — "does
// this frame play now?" — is the engine's to answer and was not previously
// askable at all: the bridge reported only totals.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumit_flutter/panels/timeline_extras_frb.dart';
import 'package:lumit_flutter/panels/timeline_panel_frb.dart';
import 'package:lumit_flutter/panels/viewer_panel_frb.dart';

import 'frb_test_support.dart';

void main() {
  group('Cache bar runs', () {
    test('contiguous frames of one tier collapse to a single run', () {
      expect(cacheBarRuns([2, 2, 2]), [(0, 3, 2)]);
    });

    test('uncached frames are gaps, not runs', () {
      expect(cacheBarRuns([0, 2, 2, 0, 2]), [(1, 3, 2), (4, 5, 2)]);
    });

    /// A frame held only at a coarser resolution is a different state, so it
    /// cannot be merged into the run beside it.
    test('a change of tier breaks the run', () {
      expect(cacheBarRuns([2, 2, 1, 1, 2]), [(0, 2, 2), (2, 4, 1), (4, 5, 2)]);
    });

    test('nothing held draws nothing', () {
      expect(cacheBarRuns([0, 0, 0]), isEmpty);
      expect(cacheBarRuns([]), isEmpty);
    });
  });

  group('Cache bar against the engine', () {
    setUpAll(initEngineForTests);

    /// The whole point of the bar: a frame that has been rendered reads back as
    /// held, and one that has not reads as nothing. Before this the bridge could
    /// only say how many bytes were in use.
    testWidgets('a rendered frame shows as held, an unrendered one does not',
        (tester) async {
      final p = freshProject();
      final comp = p.state.project!.newComposition(name: 'Scene');
      comp.addSolidLayer();
      p.uiState.setSelectedComp(comp);

      expect(
        comp.cachedFrames(frames: BigInt.from(8), scale: 1.0),
        everyElement(0),
        reason: 'nothing rendered yet',
      );

      await tester.pumpWidget(hostPanel(
        child: const ViewerPanelFrb(),
        state: p.state,
        uiState: p.uiState,
        size: const Size(700, 500),
      ));
      await tester.pump();
      await settleFrb(
        tester,
        minRounds: 20,
        maxRounds: 200,
        until: () => p.uiState.viewerImage.value != null,
      );

      final tiers =
          comp.cachedFrames(frames: BigInt.from(8), scale: p.uiState.viewerScale);
      expect(tiers[0], 2, reason: 'the frame under the playhead is held');
      expect(tiers.skip(1), everyElement(0), reason: 'and only that one');
    });

    /// Positional keys do not change when the picture does, so a committed edit
    /// has to drop the composition's frames — otherwise the bar would promise a
    /// frame that is no longer what the document says.
    ///
    /// A *rename* is used deliberately, because it is the case that shows what
    /// this costs: renaming a layer cannot change a single pixel, and every held
    /// frame is retired anyway. That is the K-178 regret, and the reason the
    /// content-hash keying in docs/TODO.md is still worth doing — but a cache
    /// that lies is worse than one that is cold.
    testWidgets('an edit empties the bar for that composition', (tester) async {
      final p = freshProject();
      final comp = p.state.project!.newComposition(name: 'Scene');
      final layer = comp.addSolidLayer();
      final other = p.state.project!.newComposition(name: 'Other');
      p.uiState.setSelectedComp(comp);

      await tester.pumpWidget(hostPanel(
        child: const ViewerPanelFrb(),
        state: p.state,
        uiState: p.uiState,
        size: const Size(700, 500),
      ));
      await tester.pump();
      await settleFrb(
        tester,
        minRounds: 20,
        maxRounds: 200,
        until: () => p.uiState.viewerImage.value != null,
      );
      expect(
        comp.cachedFrames(frames: BigInt.from(4), scale: p.uiState.viewerScale)[0],
        2,
      );

      layer.rename(name: 'Renamed');
      expect(
        comp.cachedFrames(frames: BigInt.from(4), scale: p.uiState.viewerScale),
        everyElement(0),
        reason: 'the edit retired this composition\'s frames',
      );
      expect(
        other.cachedFrames(frames: BigInt.from(4), scale: 1.0),
        everyElement(0),
        reason: 'and never held any of the other one\'s',
      );
    });

    testWidgets('the bar is drawn under the ruler', (tester) async {
      final p = freshProject();
      final comp = p.state.project!.newComposition(name: 'Scene');
      comp.addSolidLayer();
      p.uiState.setSelectedComp(comp);

      await tester.pumpWidget(hostPanel(
        child: const TimelinePanelFrb(),
        state: p.state,
        uiState: p.uiState,
        size: const Size(1000, 500),
      ));
      await tester.pump();

      expect(find.byKey(const ValueKey('tl-cache-bar')), findsOneWidget);
      expect(tester.getSize(find.byType(TimelineCacheBar)).height,
          TimelineCacheBar.height,
          reason: 'a thin stripe, per the design language');
    });
  }, skip: !engineAvailable);
}
