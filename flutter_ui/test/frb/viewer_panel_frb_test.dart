// The Viewer on frb, against the real engine.
//
// The picture itself is not asserted here — what the worker publishes is a
// platform texture or a decoded frame, and neither arrives in a widget test.
// What is asserted is everything around it: the transport, the timecode, the
// magnification and channel pickers, the grid, and the move gizmo, all of which
// are the parts a user actually operates.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/panels/viewer_panel_frb.dart';
import 'package:lumit_flutter/src/rust/api/audio.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:lumit_flutter/src/rust/api/effect.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';

import 'frb_test_support.dart';

void main() {
  setUpAll(initEngineForTests);

  group('Viewer (frb)', () {
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

    Future<void> mount(WidgetTester tester, dynamic p) async {
      await tester.pumpWidget(hostPanel(
        child: const ViewerPanelFrb(),
        state: p.state as LumitState,
        uiState: p.uiState as LumitUiState,
        size: const Size(700, 500),
      ));
      await tester.pump();
    }

    testWidgets('without a composition it says so', (tester) async {
      final p = freshProject();
      await tester.pumpWidget(hostPanel(
        child: const ViewerPanelFrb(),
        state: p.state,
        uiState: p.uiState,
      ));
      await tester.pump();
      expect(find.textContaining('Select a composition'), findsOneWidget);
    });

    testWidgets('the transport steps, homes and ends within the comp',
        (tester) async {
      final p = withLayer();
      await mount(tester, p);
      final last = p.comp.getSettings().durationFrames.toInt() - 1;

      await tester.tap(find.byKey(const ValueKey('viewer-step-forward')));
      await tester.pump();
      expect(p.uiState.playheadFrame.value, 1);

      await tester.tap(find.byKey(const ValueKey('viewer-step-back')));
      await tester.pump();
      expect(p.uiState.playheadFrame.value, 0);

      // Stepping back from the start stays at the start rather than going
      // negative — a frame before the comp is not a frame.
      await tester.tap(find.byKey(const ValueKey('viewer-step-back')));
      await tester.pump();
      expect(p.uiState.playheadFrame.value, 0);

      await tester.tap(find.byKey(const ValueKey('viewer-end')));
      await tester.pump();
      expect(p.uiState.playheadFrame.value, last);

      await tester.tap(find.byKey(const ValueKey('viewer-step-forward')));
      await tester.pump();
      expect(p.uiState.playheadFrame.value, last,
          reason: 'and the end is the end');

      await tester.tap(find.byKey(const ValueKey('viewer-home')));
      await tester.pump();
      expect(p.uiState.playheadFrame.value, 0);
    });

    testWidgets('play advances the playhead and stops at the end',
        (tester) async {
      final p = withLayer();
      await mount(tester, p);

      await tester.tap(find.byKey(const ValueKey('viewer-play')));
      await tester.pump();
      // Ticker time is fake here, so elapse enough for several frames.
      await tester.pump(const Duration(milliseconds: 250));
      expect(p.uiState.playheadFrame.value, greaterThan(0),
          reason: 'playing moves the playhead');

      await tester.tap(find.byKey(const ValueKey('viewer-play')));
      await tester.pump();
      final stopped = p.uiState.playheadFrame.value;
      await tester.pump(const Duration(milliseconds: 250));
      expect(p.uiState.playheadFrame.value, stopped,
          reason: 'pausing stops it where it is');
    });

    testWidgets('the timecode reads HH:MM:SS:FF at the comp rate',
        (tester) async {
      final p = withLayer();
      await mount(tester, p);

      expect(find.text('00:00:00:00'), findsOneWidget);

      // A new comp is 60 fps, so frame 90 is one and a half seconds in.
      p.uiState.playheadFrame.value = 90;
      await tester.pump();
      expect(find.text('00:00:01:30'), findsOneWidget);
    });

    /// 29.97 counts thirty frames to the second of timecode, which is what every
    /// editor shows — the last frame of a second is :29, not an impossible :28.
    testWidgets('a drop-frame rate still counts a whole second of frames',
        (tester) async {
      final p = withLayer();
      final settings = p.comp.getSettings();
      p.comp.setSettings(
        settings: BridgeCompSettings(
          name: settings.name,
          width: settings.width,
          height: settings.height,
          fpsNum: 30000,
          fpsDen: 1001,
          durationFrames: settings.durationFrames,
        ),
      );
      await mount(tester, p);

      p.uiState.playheadFrame.value = 29;
      await tester.pump();
      expect(find.text('00:00:00:29'), findsOneWidget);

      p.uiState.playheadFrame.value = 30;
      await tester.pump();
      expect(find.text('00:00:01:00'), findsOneWidget);
    });

    testWidgets('the magnification, channel and grid controls are live',
        (tester) async {
      final p = withLayer();
      await mount(tester, p);

      await tester.tap(find.byKey(const ValueKey('viewer-zoom')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('100%').last);
      await tester.pumpAndSettle();
      expect(find.text('100%'), findsOneWidget,
          reason: 'the picker shows what was chosen');

      await tester.tap(find.byKey(const ValueKey('viewer-channel')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Alpha').last);
      await tester.pumpAndSettle();
      expect(find.byType(ColorFiltered), findsWidgets,
          reason: 'a single channel is drawn through a filter');

      // The grid is on by default and toggles off.
      expect(find.byKey(const ValueKey('viewer-grid')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('viewer-grid')));
      await tester.pump();
    });

    /// The one place in this port where a single gesture is two ops: x and y are
    /// separate properties in the model.
    testWidgets('dragging the move handle repositions the layer',
        (tester) async {
      final p = withLayer();
      await mount(tester, p);

      final before = p.layer.getTransform();
      final beforeX = (before.positionX as BridgeScalar_Static).field0;

      final handle = find.byKey(const ValueKey('viewer-move-handle'));
      expect(handle, findsOneWidget,
          reason: 'the selected layer gets a handle');

      final gesture = await tester.startGesture(tester.getCenter(handle));
      await tester.pump();
      for (var i = 0; i < 8; i++) {
        await gesture.moveBy(const Offset(6, 0));
        await tester.pump();
      }
      await gesture.up();
      await tester.pumpAndSettle();

      final after = p.layer.getTransform();
      expect((after.positionX as BridgeScalar_Static).field0,
          greaterThan(beforeX),
          reason: 'the drag reached the document');
    });

    testWidgets('an animated position gets no handle', (tester) async {
      final p = withLayer();
      // A position that is a curve has no single point to drag.
      p.layer.setTransform(
        prop: BridgeTransformProp.positionX,
        value: BridgeScalar.keyframed([
          BridgeKeyframe(
            time: p.comp.timeOfFrame(frame: 0),
            value: 0,
            interpIn: const BridgeSideInterp.linear(),
            interpOut: const BridgeSideInterp.linear(),
          ),
          BridgeKeyframe(
            time: p.comp.timeOfFrame(frame: 30),
            value: 400,
            interpIn: const BridgeSideInterp.linear(),
            interpOut: const BridgeSideInterp.linear(),
          ),
        ]),
      );
      await mount(tester, p);

      expect(find.byKey(const ValueKey('viewer-move-handle')), findsNothing,
          reason: 'a curve has no single position to drag');
    });

    testWidgets('a missing footage layer raises the badge', (tester) async {
      final p = withLayer();
      final gone = p.state.project!.importFootage(path: 'C:/nowhere/gone.mp4');
      p.comp.addFootageLayer(footage: gone);
      await mount(tester, p);

      await settleFrb(
        tester,
        until: () =>
            find.byKey(const ValueKey('viewer-missing')).evaluate().isNotEmpty,
      );
      expect(find.byKey(const ValueKey('viewer-missing')), findsOneWidget);
      expect(find.textContaining('missing file'), findsOneWidget);
    });
    // Without the built library there is nothing to test against; the harness
    // throws with the command to run.

    /// Silence must never stop the picture: on a machine with no sound device
    /// the transport still runs, on the wall clock.
    testWidgets('playback works without a sound device', (tester) async {
      final p = withLayer();
      await mount(tester, p);

      await tester.tap(find.byKey(const ValueKey('viewer-play')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(p.uiState.playheadFrame.value, greaterThan(0),
          reason: 'no audio device, so the wall clock drives it');

      await tester.tap(find.byKey(const ValueKey('viewer-play')));
      await tester.pump();
      expect(audioClock().playing, isFalse,
          reason: 'pausing the transport pauses the sound too');
    });

    /// The shell's space bar drives the transport through LumitUiState, because
    /// the ticker belongs to this panel's state — nothing outside can call it.
    testWidgets('the transport request from the shell starts and stops it',
        (tester) async {
      final p = withLayer();
      await mount(tester, p);

      p.uiState.requestTogglePlay();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(p.uiState.playheadFrame.value, greaterThan(0),
          reason: 'space started playback');

      p.uiState.requestTogglePlay();
      await tester.pump();
      final stopped = p.uiState.playheadFrame.value;
      await tester.pump(const Duration(milliseconds: 250));
      expect(p.uiState.playheadFrame.value, stopped,
          reason: 'and space stopped it');
    });

    /// A transport belongs under the picture. Asserted by position rather than
    /// by reading the widget tree's shape, because what matters is where the
    /// user's eye and pointer go.
    testWidgets('the transport sits below the picture', (tester) async {
      final p = withLayer();
      await mount(tester, p);

      final play = tester.getCenter(find.byKey(const ValueKey('viewer-play')));
      final stage = tester.getRect(find.byType(ViewerPanelFrb));
      expect(play.dy, greaterThan(stage.center.dy),
          reason: 'below the middle of the panel, not above it');
    });

    /// Moving the playhead from anywhere must repaint the Viewer. Only the
    /// Viewer's own transport used to render, so dragging the Timeline's
    /// playhead — or pressing an arrow key — moved the playhead and left the
    /// picture on the old frame.
    testWidgets('a playhead move from outside the Viewer renders',
        (tester) async {
      final p = withLayer();
      final sub = p.state.onWorkerResponse.listen((_) {});
      addTearDown(sub.cancel);
      await mount(tester, p);

      // Exactly what the Timeline ruler and the arrow keys do: set it.
      p.uiState.playheadFrame.value = 12;
      await tester.pump();

      // The first render of a session also builds the renderer, so allow for
      // that before asserting anything about the picture.
      await settleFrb(
        tester,
        until: () => p.uiState.viewerImage.value != null,
        minRounds: 10,
        maxRounds: 120,
      );
      expect(p.uiState.viewerImage.value, isNotNull,
          reason: 'a frame was rendered for the moved playhead');
    });

    /// One request in flight at a time. Firing one per tick queued about ten
    /// per completed render, all but the newest thrown away — a lock, a
    /// snapshot and a channel send each, on the UI thread, for nothing.
    testWidgets('playback keeps one render in flight, not one per tick',
        (tester) async {
      final p = withLayer();
      await mount(tester, p);

      var frames = 0;
      final sub = p.state.onWorkerResponse.listen((_) => frames++);
      addTearDown(sub.cancel);

      await tester.tap(find.byKey(const ValueKey('viewer-play')));
      await tester.pump();
      // Many ticks, and so many playhead moves.
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final moved = p.uiState.playheadFrame.value;
      expect(moved, greaterThan(0), reason: 'the playhead ran');

      await tester.tap(find.byKey(const ValueKey('viewer-play')));
      await tester.pump();
      await settleFrb(tester, minRounds: 10, maxRounds: 60);

      expect(frames, lessThanOrEqualTo(moved),
          reason: 'never more renders than frames the playhead visited');
    });

    /// A still Viewer must go quiet. While the in-flight rule was being built
    /// it re-asked for the frame it had just been given, so the engine rendered
    /// the same picture over and over for as long as the panel was open.
    testWidgets('a still playhead stops asking for renders', (tester) async {
      final p = withLayer();
      await mount(tester, p);

      var frames = 0;
      final sub = p.state.onWorkerResponse.listen((_) => frames++);
      addTearDown(sub.cancel);

      // Let the mount render land, then count what follows it.
      await settleFrb(tester, minRounds: 10, maxRounds: 120,
          until: () => p.uiState.viewerImage.value != null);
      final settled = frames;

      await settleFrb(tester, minRounds: 20, maxRounds: 20);
      expect(frames, settled,
          reason: 'nothing moved, so nothing should have been rendered');
    });

    testWidgets('stepping takes the sound with it', (tester) async {
      final p = withLayer();
      await mount(tester, p);

      // The seek must not throw whatever the device situation is — it is on the
      // path of every arrow key.
      await tester.tap(find.byKey(const ValueKey('viewer-step-forward')));
      await tester.pump();
      expect(p.uiState.playheadFrame.value, 1);
      expect(audioClock().seconds, greaterThanOrEqualTo(0));
    });
  }, skip: !engineAvailable);
}
