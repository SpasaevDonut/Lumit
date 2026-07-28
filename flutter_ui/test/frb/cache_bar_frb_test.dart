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
import 'package:lumit_flutter/panels/scopes_panel_frb.dart';
import 'package:lumit_flutter/theme/theme.dart';
import 'package:lumit_flutter/panels/timeline_panel_frb.dart';
import 'package:lumit_flutter/panels/viewer_panel_frb.dart';
import 'package:lumit_flutter/src/rust/api/cache.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:lumit_flutter/src/rust/api/effect.dart';

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

    // Viewer frames only ever cross as GPU handles now (K-183), so nothing the
    // Viewer shows leaves bytes behind — the rendered-frame cache is filled by
    // the scope path, which needs CPU pixels and files what it renders.

    /// The whole point of the bar: a frame that has been rendered (here, for a
    /// trace) reads back as held, and one that has not reads as nothing.
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
      // Retried, because the cache is process-global and every parallel test
      // suite's committed edit invalidates it: a hold observed and then
      // snatched away by a neighbour's commit is the environment, not the
      // regression this test exists for.
      late List<int> tiers;
      for (var attempt = 0; attempt < 5; attempt++) {
        comp.renderScope(
          frame: BigInt.zero,
          scale: p.uiState.viewerScale,
          kind: 0,
          colours: scopeColoursFor(LumitTheme.dark()),
        );
        await settleFrb(
          tester,
          minRounds: 20,
          maxRounds: 200,
          until: () => comp.cachedFrames(
                  frames: BigInt.from(8), scale: p.uiState.viewerScale)[0] !=
              0,
        );
        tiers = comp.cachedFrames(
            frames: BigInt.from(8), scale: p.uiState.viewerScale);
        if (tiers[0] != 0) break;
      }
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
      comp.renderScope(
        frame: BigInt.zero,
        scale: p.uiState.viewerScale,
        kind: 0,
        colours: scopeColoursFor(LumitTheme.dark()),
      );
      await settleFrb(
        tester,
        minRounds: 20,
        maxRounds: 200,
        until: () => comp
                .cachedFrames(frames: BigInt.from(4), scale: p.uiState.viewerScale)[0] !=
            0,
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

    /// A composition far longer than the panel is wide gives a run whose right
    /// edge lands past the bar. `num.clamp` throws when the lower bound exceeds
    /// the upper, so the naive clamp crashed the paint outright.
    testWidgets('a run at the far end of a long comp does not crash the paint',
        (tester) async {
      final p = freshProject();
      final comp = p.state.project!.newComposition(name: 'Long');
      final settings = comp.getSettings();
      comp.setSettings(
        settings: BridgeCompSettings(
          name: settings.name,
          width: settings.width,
          height: settings.height,
          fpsNum: settings.fpsNum,
          fpsDen: settings.fpsDen,
          // 4000 frames at the comp's 60 fps.
          duration: const BridgeRational(num: 200, den: 3),
        ),
      );
      comp.addSolidLayer();
      p.uiState.setSelectedComp(comp);

      await tester.pumpWidget(hostPanel(
        child: const TimelinePanelFrb(),
        state: p.state,
        uiState: p.uiState,
        size: const Size(1000, 500),
      ));
      await tester.pump();
      await settleFrb(tester, minRounds: 10, maxRounds: 60);

      expect(tester.takeException(), isNull,
          reason: '4000 frames across 1000 px must not throw in paint');
    });

    /// A scope trace needs CPU pixels, and the zero-copy Viewer keeps none
    /// (K-183) — so the first trace of a frame renders and files it, and a
    /// second trace of the same frame is served from the cache rather than
    /// compositing the composition again.
    testWidgets('a second trace of the same frame is served from the cache',
        (tester) async {
      final p = freshProject();
      final comp = p.state.project!.newComposition(name: 'Scene');
      comp.addSolidLayer();
      p.uiState.setSelectedComp(comp);

      await tester.pumpWidget(hostPanel(
        child: const ViewerPanelFrb(),
        state: p.state,
        uiState: p.uiState,
        size: const Size(700, 500),
      ));
      await tester.pump();

      comp.renderScope(
        frame: BigInt.zero,
        scale: p.uiState.viewerScale,
        kind: 0,
        colours: scopeColoursFor(LumitTheme.dark()),
      );
      // Wait for THIS comp's frame to be held, not for the process-wide entry
      // count to be non-zero — earlier tests in this file leave residue in the
      // shared cache, and a `before` snapshotted on their entries races the
      // first trace (two queued traces collapse to the newest, so the first
      // can vanish entirely).
      await settleFrb(
        tester,
        minRounds: 15,
        maxRounds: 400,
        until: () => comp
                .cachedFrames(frames: BigInt.one, scale: p.uiState.viewerScale)[0] !=
            0,
      );

      final before = cacheStats();
      comp.renderScope(
        frame: BigInt.zero,
        scale: p.uiState.viewerScale,
        kind: 1,
        colours: scopeColoursFor(LumitTheme.dark()),
      );
      await settleFrb(tester, minRounds: 15, maxRounds: 80);

      // `best_frame` serves the held frame without touching the hit/miss
      // counters (they describe cache lookups, and this is a reuse before the
      // lookup) — so the observable is that nothing new was made: a fresh
      // composite would have filed another entry and counted a miss.
      final after = cacheStats();
      expect(after.entries, before.entries,
          reason: 'the second trace did not composite the composition again');
      expect(after.misses, before.misses,
          reason: 'and never even asked the cache for a render');
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

    /// The idle fill (K-187): show a frame, leave the engine alone for a
    /// moment, and it banks the frames around the playhead on its own —
    /// forward-biased, so the ones ahead come first. Real wall-clock waits,
    /// because the worker is a real thread with a real 200 ms lull gate;
    /// without the fill this times out with nothing held but the shown frame.
    testWidgets('the idle fill warms frames around the playhead',
        (tester) async {
      final p = freshProject();
      final comp = p.state.project!.newComposition(name: 'Scene');
      comp.addSolidLayer();
      p.uiState.setSelectedComp(comp);

      comp.renderFrame(
        frame: BigInt.from(5),
        scale: 1.0,
        mode: BridgePlaybackMode.everyFrame,
      );

      await tester.runAsync(() async {
        for (var i = 0; i < 50; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          final tiers = comp.cachedFrames(frames: BigInt.from(12), scale: 1.0);
          // Ahead of the playhead fills first (two forward for one back),
          // but all three neighbours arriving is the honest "it works".
          if (tiers[6] == 2 && tiers[7] == 2 && tiers[4] == 2) return;
        }
        fail('the idle fill banked nothing around the playhead');
      });
    });
  }, skip: !engineAvailable);
}
