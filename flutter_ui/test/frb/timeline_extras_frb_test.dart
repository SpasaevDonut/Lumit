// The Timeline's chrome on frb: comp tabs, cache bar, search, the parent
// picker, markers, the work area and the razor.
//
// Driven through the panel rather than in isolation, for the same reason as
// everywhere else here: what matters is that a click reaches the document.

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/panels/graph_maths.dart';
import 'package:lumit_flutter/panels/timeline_extras_frb.dart';
import 'package:lumit_flutter/panels/timeline_panel_frb.dart';
import 'package:lumit_flutter/shell/status_line_frb.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';
import 'package:lumit_flutter/src/rust/api/project_item.dart';

import 'package:lumit_flutter/state/tools.dart';

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
      // The outline alone is 800 px of columns; the default 800×600 test
      // surface would push its right edge (and the lanes) off screen.
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
    }

    /// Open the toolbar's ⋯ menu, where the layer/work-area/marker commands
    /// live now that the toolbar row belongs to the readouts and the search.
    Future<void> openMore(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('tl-more')));
      await tester.pumpAndSettle();
    }

    testWidgets('the comp tabs show the open comps and front one',
        (tester) async {
      final p = withComp();
      final second = p.state.project!.newComposition(name: 'Titles');
      await mount(tester, p);

      expect(find.byKey(ValueKey<String>('tl-tab-${p.comp.internalid}')),
          findsOneWidget);
      expect(find.byKey(ValueKey<String>('tl-tab-${second.internalid}')),
          findsNothing,
          reason: 'a comp nobody has fronted is not an open tab');

      p.uiState.setSelectedComp(second);
      await tester.pump();
      final tab = find.byKey(ValueKey<String>('tl-tab-${second.internalid}'));
      expect(tab, findsOneWidget, reason: 'fronting a comp opens its tab');

      await tester
          .tap(find.byKey(ValueKey<String>('tl-tab-${p.comp.internalid}')));
      await tester.pump();
      expect(p.uiState.selectedComp?.internalid, p.comp.internalid);
      expect(tab, findsOneWidget, reason: 'switching away keeps the tab open');
    });

    /// The × closes only the tab: the comp stays in the project, and closing
    /// the fronted tab fronts its nearest remaining neighbour.
    testWidgets('closing a comp tab keeps the comp and fronts a neighbour',
        (tester) async {
      final p = withComp();
      final second = p.state.project!.newComposition(name: 'Titles');
      p.uiState.setSelectedComp(second);
      await mount(tester, p);

      await tester.tap(
          find.byKey(ValueKey<String>('tl-tab-close-${second.internalid}')));
      await tester.pump();

      expect(find.byKey(ValueKey<String>('tl-tab-${second.internalid}')),
          findsNothing);
      expect(p.uiState.selectedComp?.internalid, p.comp.internalid,
          reason: 'the neighbour fronted');
      expect(p.state.comps().map((c) => c.$2), contains('Titles'),
          reason: 'closing a tab never deletes the comp');

      // Closing the last tab leaves no comp fronted, and the panel says so.
      await tester.tap(
          find.byKey(ValueKey<String>('tl-tab-close-${p.comp.internalid}')));
      await tester.pump();
      expect(p.uiState.selectedComp, isNull);
      expect(find.textContaining('Open a composition'), findsOneWidget);
    });

    /// **The bridge error where the Timeline should be.** Pre-compose, step
    /// into the new comp, undo: the layers come back and the comp they were
    /// packed into stops existing — with the Timeline still fronting it, every
    /// panel read a comp the engine had never heard of. What has gone cannot
    /// stay fronted, so the user goes back where they came from.
    testWidgets('undoing away the fronted comp goes back to the previous one',
        (tester) async {
      final p = withComp();
      p.comp.addSolidLayer();
      final packed = p.comp.precompose(
        layerIds: [p.comp.getLayers().single.internallayerId],
        name: 'Packed',
        leaveAttributes: false,
        adjustDuration: false,
      );
      final inner = switch (packed.getSourceItem()!) {
        ItemReference_Composition(:final field0) => field0,
        _ => throw StateError('a Precomp layer draws from a composition'),
      };
      p.uiState.setSelectedComp(inner);
      await mount(tester, p);
      expect(p.uiState.selectedComp?.internalid, inner.internalid);

      p.state.project!.undo();
      p.uiState.model.refresh();
      await tester.pump();

      expect(p.uiState.selectedComp?.internalid, p.comp.internalid,
          reason: 'the comp the user came from fronts again');
      expect(find.byKey(ValueKey<String>('tl-tab-${inner.internalid}')),
          findsNothing, reason: 'and the tab it had goes with it');
      expect(tester.takeException(), isNull);
    });

    /// With nowhere to go back to — the comp the user came from has gone too
    /// — the nearest open tab takes over, looking left before right.
    testWidgets('a vanished comp falls back to the nearest open tab',
        (tester) async {
      final p = withComp();
      final second = p.state.project!.newComposition(name: 'Titles');
      p.uiState.setSelectedComp(second);
      final third = p.state.project!.newComposition(name: 'Doomed');
      p.uiState.setSelectedComp(third);
      await mount(tester, p);

      // Both the fronted comp and the one the user came from go.
      for (final comp in [second, third]) {
        ItemReference.composition(comp).delete();
      }
      p.uiState.model.refresh();
      await tester.pump();

      expect(p.uiState.selectedComp?.internalid, p.comp.internalid,
          reason: 'the nearest tab still standing, to the left');
      expect(tester.takeException(), isNull);
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
      await openMore(tester);
      await tester.tap(find.byKey(const ValueKey('tl-work-in')));
      await tester.pumpAndSettle();

      var area = p.comp.getWorkArea();
      expect(area, isNotNull);
      expect(p.comp.frameAtTime(time: area!.inPoint), 20);

      p.uiState.playheadFrame.value = 60;
      await tester.pump();
      await openMore(tester);
      await tester.tap(find.byKey(const ValueKey('tl-work-out')));
      await tester.pumpAndSettle();

      area = p.comp.getWorkArea();
      expect(p.comp.frameAtTime(time: area!.outPoint), 60);
      expect(p.comp.frameAtTime(time: area.inPoint), 20,
          reason: 'setting the out point leaves the in point alone');

      await openMore(tester);
      await tester.tap(find.byKey(const ValueKey('tl-clear-work-area')));
      await tester.pumpAndSettle();
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
      await openMore(tester);
      await tester.tap(find.byKey(const ValueKey('tl-work-in')));
      await tester.pumpAndSettle();

      p.uiState.playheadFrame.value = 10;
      await tester.pump();
      await openMore(tester);
      await tester.tap(find.byKey(const ValueKey('tl-work-out')));
      await tester.pumpAndSettle();

      final area = p.comp.getWorkArea()!;
      final start = p.comp.frameAtTime(time: area.inPoint);
      final end = p.comp.frameAtTime(time: area.outPoint);
      expect(end, greaterThan(start), reason: 'it always has length');
    });

    /// **Dragging an edge cannot leave the comp.** A pointer past either end
    /// gave a frame outside it, and a negative in point took the render worker
    /// down: cast unsigned for the cache fill it became a first frame of
    /// eighteen quintillion, `clamp` panicked on the crossed bounds, and every
    /// later frame request came back a send error. The helper the drag commits
    /// through clamps, so the handle stops at the edge.
    testWidgets('a work-area edge dragged past the comp stops at its end',
        (tester) async {
      final p = withComp();
      await mount(tester, p);
      final frames = p.comp.durationFrames();

      // Well past the end, then well before the start.
      p.comp.setWorkArea(
        span: workAreaWith(
          comp: p.comp,
          current: null,
          wanted: frames + 500,
          isStart: false,
        ),
      );
      expect(p.comp.frameAtTime(time: p.comp.getWorkArea()!.outPoint), frames,
          reason: 'the out point stops at the end of the comp');

      p.comp.setWorkArea(
        span: workAreaWith(
          comp: p.comp,
          current: p.comp.getWorkArea(),
          wanted: -500,
          isStart: true,
        ),
      );
      final area = p.comp.getWorkArea()!;
      expect(p.comp.frameAtTime(time: area.inPoint), 0,
          reason: 'and the in point at frame zero');
      expect(p.comp.frameAtTime(time: area.outPoint),
          greaterThan(p.comp.frameAtTime(time: area.inPoint)));
    });

    testWidgets('the marker editor adds at the playhead and removes',
        (tester) async {
      final p = withComp();
      p.comp.addAdjustmentLayer();
      await mount(tester, p);

      p.uiState.playheadFrame.value = 33;
      await tester.pump();
      await openMore(tester);
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

      await tester.tap(
          find.byKey(ValueKey<String>('marker-remove-${markers.single.id}')));
      await tester.pumpAndSettle();
      expect(p.comp.getMarkers(), isEmpty);

      await tester.tap(find.byKey(const ValueKey('marker-close')));
      await tester.pumpAndSettle();
    });

    // --- the sequence view (K-248) --------------------------------------

    /// A Sequence layer, ready to open. Added layers land at the top of the
    /// stack, so it is always the first — which lets a test put something
    /// underneath it first.
    Future<LayerReference> sequencedLayer(dynamic p) async {
      final footage = p.state.project!.importFootage(path: 'C:/clips/shot.mov');
      p.comp.addFootageLayer(footage: footage, asSequence: false);
      p.comp.getLayers().first.convertToSequenced();
      return p.comp.getLayers().first as LayerReference;
    }

    testWidgets('double-clicking a Sequence layer opens its clips in its row',
        (tester) async {
      final p = withComp();
      final layer = await sequencedLayer(p);
      await mount(tester, p);
      await tester.pump();

      final clip = layer.getClips().single;
      expect(find.byKey(ValueKey<String>('seq-clip-${clip.id}')), findsNothing,
          reason: 'shut until it is opened');

      final name = find.byKey(
          ValueKey<String>('tl-name-${layer.internallayerId}'));
      await tester.tap(name);
      await tester.pump(kDoubleTapMinTime);
      await tester.tap(name);
      await tester.pumpAndSettle();

      expect(find.byKey(ValueKey<String>('seq-clip-${clip.id}')), findsOneWidget,
          reason: 'the clip is on screen');
      expect(find.byKey(const ValueKey('seq-envelope')), findsOneWidget,
          reason: 'and so is the speed envelope beneath it');

      // Double-clicking again shuts it.
      await tester.tap(name);
      await tester.pump(kDoubleTapMinTime);
      await tester.tap(name);
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey<String>('seq-clip-${clip.id}')), findsNothing);
    });

    /// The two halves of the Timeline must agree about how tall every row is.
    ///
    /// The outline has nothing of its own to draw for an open sequence view —
    /// the clips and their envelope are the lane's — so it has to reserve the
    /// room anyway. It did not, which put every row below the opened layer at
    /// a different height on each side: names stopped lining up with bars.
    testWidgets('opening a view moves the outline down with the lanes',
        (tester) async {
      final p = withComp();
      // The solid goes in *first*: a new layer lands at the top of the stack,
      // so this is the one that ends up below the sequenced layer — and below
      // is where the misalignment showed.
      final below = p.comp.addSolidLayer();
      final layer = await sequencedLayer(p);
      await mount(tester, p);
      await tester.pump();
      Rect nameOf() => tester.getRect(
          find.byKey(ValueKey<String>('tl-row-${below.internallayerId}')));
      Rect barOf() => tester.getRect(
          find.byKey(ValueKey<String>('tl-bar-${below.internallayerId}')));

      final gapBefore = nameOf().top - barOf().top;

      final name =
          find.byKey(ValueKey<String>('tl-name-${layer.internallayerId}'));
      await tester.tap(name);
      await tester.pump(kDoubleTapMinTime);
      await tester.tap(name);
      await tester.pumpAndSettle();

      expect(nameOf().top - barOf().top, closeTo(gapBefore, 0.5),
          reason: 'the row below moved by the same amount on both sides');
    });

    /// A drag must survive the readout appearing.
    ///
    /// The readout is a `Stack` child that only exists while a drag runs, and
    /// unkeyed children are matched by position — so it took the gesture
    /// detector's slot, Flutter rebuilt that element, and the recogniser
    /// holding the drag went with it. The gesture ended the instant the
    /// readout showed up, one frame in. Driven here one step at a time,
    /// because a single synthetic move never reproduces it (the same reason
    /// K-212's first round of tests all passed).
    /// The velocity drag must stay linear.
    ///
    /// The axis grows to hold whatever a point reaches, so a point dragged
    /// past the floor widened it, which stretched what the next pixel of
    /// travel was worth, which pushed the point further still — a steady hand
    /// sent the value off exponentially. The axis is frozen for the length of
    /// a gesture now, so equal travel is equal change.
    testWidgets('an envelope drag stays linear', (tester) async {
      final p = withComp();
      final layer = await sequencedLayer(p);
      await mount(tester, p);
      await tester.pump();
      final name =
          find.byKey(ValueKey<String>('tl-name-${layer.internallayerId}'));
      await tester.tap(name);
      await tester.pump(kDoubleTapMinTime);
      await tester.tap(name);
      await tester.pumpAndSettle();

      final clip = layer.getClips().single;
      final strip = tester.getRect(find.byKey(const ValueKey('seq-envelope')));
      final clipBox =
          tester.getRect(find.byKey(ValueKey<String>('seq-clip-${clip.id}')));
      // Near the clip's own start, so the point grabbed is its first — the
      // one whose speed is read back below.
      final from = Offset(clipBox.left + 3, strip.top + strip.height * 0.3);

      /// The first point's speed after dragging down by [by] pixels, in equal
      /// steps. Read off the map rather than `speedPercent`, which is null the
      /// moment the two ends differ — which is exactly what dragging one does.
      Future<double> after(double by) async {
        layer.setClipSpeed(clip: clip.id, percent: 100, endPercent: 100);
        // The panel draws from the read model, so a write behind its back has
        // to be published or the next drag starts from the last one's result.
        p.uiState.model.refresh();
        await tester.pumpAndSettle();
        final gesture = await tester.startGesture(from);
        for (var i = 0; i < 6; i++) {
          await gesture.moveBy(Offset(0, by / 6));
          await tester.pump();
        }
        await gesture.up();
        await tester.pumpAndSettle();
        final map = layer.getClips().single.retime!;
        return envelopeSpeeds(keysOf(map)).first;
      }

      final near = 100 - await after(20);
      final far = 100 - await after(40);
      // Twice the travel, twice the change — not four times, or forty.
      expect(far, closeTo(near * 2, near * 0.25),
          reason: 'equal pixels are equal per cent, however far it has gone');
    });

    testWidgets('a drag keeps going once the readout appears', (tester) async {
      final p = withComp();
      final layer = await sequencedLayer(p);
      await mount(tester, p);
      await tester.pump();
      final name =
          find.byKey(ValueKey<String>('tl-name-${layer.internallayerId}'));
      await tester.tap(name);
      await tester.pump(kDoubleTapMinTime);
      await tester.tap(name);
      await tester.pumpAndSettle();

      final before = layer.getClips().single;
      final strip = tester.getRect(find.byKey(const ValueKey('seq-envelope')));
      final clipBox =
          tester.getRect(find.byKey(ValueKey<String>('seq-clip-${before.id}')));
      final from = Offset(clipBox.center.dx, strip.top + strip.height * 0.3);

      // One event at a time, because a single synthetic move never
      // reproduces a drag that dies part way (the same reason K-212's first
      // round of tests all passed).
      final gesture = await tester.startGesture(from);
      for (var i = 0; i < 6; i++) {
        await gesture.moveBy(const Offset(0, 8));
        await tester.pump();
      }
      await gesture.up();
      await tester.pumpAndSettle();

      final after = layer.getClips().single;
      expect(after.speedPercent, isNotNull);
      // The whole 48px of travel, not the first step of it.
      final oneStepOnly = 100 - (8 / strip.height) * 161;
      expect(after.speedPercent!, lessThan(oneStepOnly - 20),
          reason: 'every move counted, not just the one before the readout '
              'appeared');
    });

    testWidgets('dragging an envelope point re-speeds only that clip',
        (tester) async {
      final p = withComp();
      final layer = await sequencedLayer(p);
      await mount(tester, p);
      await tester.pump();
      final name = find.byKey(
          ValueKey<String>('tl-name-${layer.internallayerId}'));
      await tester.tap(name);
      await tester.pump(kDoubleTapMinTime);
      await tester.tap(name);
      await tester.pumpAndSettle();

      final before = layer.getClips().single;
      expect(before.retimed, isFalse, reason: 'plays at source rate to start');

      // Downwards is slower: the envelope runs fast at the top to backwards at
      // the bottom, so a drag down the strip lowers the speed. Started over
      // the clip's own span, which is what picks the clip whose line it is.
      final strip = tester.getRect(find.byKey(const ValueKey('seq-envelope')));
      final clipBox =
          tester.getRect(find.byKey(ValueKey<String>('seq-clip-${before.id}')));
      await tester.dragFrom(
        Offset(clipBox.center.dx, strip.top + strip.height * 0.3),
        const Offset(0, 30),
      );
      await tester.pumpAndSettle();

      final after = layer.getClips().single;
      expect(after.retimed, isTrue);
      expect(after.speedPercent, isNotNull);
      expect(after.speedPercent!, lessThan(100),
          reason: 'dragging down the strip slows the clip');
      // The covenant: the clip is still exactly where it was on the row.
      expect(after.startFrame, before.startFrame);
      expect(after.endFrame, before.endFrame);
    });

    testWidgets('the razor cuts a sequence clip where it is clicked',
        (tester) async {
      final p = withComp();
      final footage = p.state.project!.importFootage(path: 'C:/clips/shot.mov');
      p.comp.addFootageLayer(footage: footage, asSequence: false);
      final layer = p.comp.getLayers().single;
      layer.convertToSequenced();
      final sequenced = p.comp.getLayers().single;
      expect(sequenced.getClips(), hasLength(1));

      await mount(tester, p);
      await tester.pump();

      // Unarmed, a click on the bar does not cut.
      final bar = find.byKey(
          ValueKey<String>('tl-bar-body-${sequenced.internallayerId}'));
      expect(bar, findsOneWidget);
      final box = tester.getRect(bar);
      // Near the start of the bar: a Sequence layer's own span is the comp's,
      // but the clip inside it is only as long as its (unreadable) media makes
      // it, so a point a third of the way along the *bar* can be past the end
      // of the clip — where there is nothing to cut.
      final inside = Offset(box.left + 8, box.center.dy);
      await tester.tapAt(inside);
      await tester.pump();
      expect(p.comp.getLayers().single.getClips(), hasLength(1),
          reason: 'the razor is a mode, not the default click');

      // The Timeline's menu item arms the toolbar's Razor tool (K-220) —
      // one razor, two doors.
      await openMore(tester);
      await tester.tap(find.byKey(const ValueKey('tl-razor')));
      await tester.pumpAndSettle();
      expect(p.uiState.tools.tool, ToolMode.razor);

      await tester.tapAt(inside);
      await tester.pumpAndSettle();

      expect(p.comp.getLayers().single.getClips(), hasLength(2),
          reason: 'the armed razor cut the clip under the pointer');
    });

    testWidgets('the cache meter reads the engine and clears on click',
        (tester) async {
      // The meter lives on the shell's status line now, so it is mounted
      // directly rather than through the Timeline.
      final p = withComp();
      await tester.pumpWidget(hostPanel(
        child: const CacheMeterFrb(),
        state: p.state,
        uiState: p.uiState,
      ));
      await tester.pump();

      expect(find.byKey(const ValueKey('cache-meter')), findsOneWidget);
      // One bar per tier, each with its own megabytes: a merged number cannot
      // answer "what is cached" for any of the three.
      expect(find.text('RAM'), findsOneWidget);
      expect(find.text('VRAM'), findsOneWidget);
      expect(find.text('Disk'), findsOneWidget);
      expect(find.textContaining('MB'), findsNWidgets(3),
          reason: 'the megabytes held read out beside each bar');
      // Clicking a tier empties that tier; the readout is live, so this must
      // not throw with no project rendered yet. The disk tier asks first rather
      // than deleting on a click — with nothing parked there is nothing to ask
      // about, so no dialogue appears and nothing happens.
      await tester.tap(find.byKey(const ValueKey('cache-meter-ram')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('cache-meter-vram')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('cache-meter-disk')));
      await tester.pump();
      expect(find.byKey(const ValueKey('cache-meter')), findsOneWidget);
    });
    // Without the built library there is nothing to test against; the harness
    // throws with the command to run.
    testWidgets('Detect beats is offered and is calm without audio',
        (tester) async {
      final p = withComp();
      p.comp.addAdjustmentLayer();
      await mount(tester, p);

      await openMore(tester);
      expect(find.byKey(const ValueKey('tl-detect-beats')), findsOneWidget);

      // No audio in this comp — and on CI no pipeline either. Either way the
      // command does nothing rather than raising, and no markers appear.
      await tester.tap(find.byKey(const ValueKey('tl-detect-beats')));
      await tester.pumpAndSettle();
      expect(p.comp.getMarkers(), isEmpty);
    });
  }, skip: !engineAvailable);
}
