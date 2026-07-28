// The Viewer on frb, against the real engine.
//
// The picture itself is not asserted here — what the worker publishes is a
// platform texture or a decoded frame, and neither arrives in a widget test.
// What is asserted is everything around it: the transport, the timecode, the
// magnification and channel pickers, the grid, and the move gizmo, all of which
// are the parts a user actually operates.
//
// Six of them do still need a frame to *arrive*, because that arrival is what
// moves the playhead and bumps `frameArrived` — the engine drives playback
// (K-181), so a Viewer that is told nothing shows nothing and counts nothing.
// Those carry `skip: zeroCopyViewerUnavailable`, which is true only on a machine
// with no working zero-copy transport (see `frb_test_support.dart`). Today that
// means the Linux CI runner and its software Vulkan, so on CI these six do not
// run at all. They are among the tests most worth having; the skip is a
// statement about the runner, not about them.

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/panels/viewer_panel_frb.dart';
import 'package:lumit_flutter/state/settings.dart';
import 'package:lumit_flutter/src/rust/api/audio.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:lumit_flutter/src/rust/api/effect.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';
import 'package:lumit_flutter/src/rust/api/state.dart';

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
      final last = p.comp.durationFrames() - 1;

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

    /// **Playback runs in the engine (K-181).** Note what this test does *not*
    /// do: elapse any fake time. `settleFrb` gives real event-loop turns and
    /// deliberately advances no `FakeAsync` clock, so a Flutter `Ticker` would
    /// never fire during it. The playhead moves here purely because the engine
    /// chose frames and each arriving frame said which one it was — which is the
    /// whole point of the move, and would fail if a clock crept back into Dart.
    testWidgets('play advances the playhead, and stopping holds it',
        (tester) async {
      final p = withLayer();
      await mount(tester, p);

      await tester.tap(find.byKey(const ValueKey('viewer-play')));
      await tester.pump();
      expect(p.uiState.playing.value, isTrue);
      await settleFrb(tester,
          minRounds: 6,
          maxRounds: 120,
          until: () => p.uiState.playheadFrame.value > 0);
      expect(p.uiState.playheadFrame.value, greaterThan(0),
          reason: 'the engine chose frames and the playhead followed them');

      await tester.tap(find.byKey(const ValueKey('viewer-play')));
      await tester.pump();
      expect(p.uiState.playing.value, isFalse);
      await settleFrb(tester, minRounds: 4, maxRounds: 4);
      final stopped = p.uiState.playheadFrame.value;
      await settleFrb(tester, minRounds: 8, maxRounds: 8);
      expect(p.uiState.playheadFrame.value, stopped,
          reason: 'stopping stops it where it is, in-flight frames included');

      // The degradation badge belongs to playback alone: whatever tier the
      // controller walked to while playing (this transportless build walks
      // down, since nothing can present), a stopped Viewer never wears it.
      // The while-playing half is not asserted — it races a live controller.
      expect(find.byKey(const ValueKey('viewer-tier-badge')), findsNothing,
          reason: 'no degradation badge once playback has stopped');
    }, skip: zeroCopyViewerUnavailable);

    /// Running off the end is the engine's to notice: it knows the length and it
    /// is the one counting. The frontend is *told*, and that is the only reason
    /// its transport goes back to showing a play button.
    testWidgets('playback ends on its own at the end of the composition',
        (tester) async {
      final p = withLayer();
      // A tenth of a second, so the end arrives inside a test rather than in the
      // thirty seconds a default comp lasts.
      final was = p.comp.getSettings();
      p.comp.setSettings(
        settings: BridgeCompSettings(
          name: was.name,
          width: 160,
          height: 90,
          fpsNum: was.fpsNum,
          fpsDen: was.fpsDen,
          duration: const BridgeRational(num: 1, den: 10),
        ),
      );
      await mount(tester, p);
      expect(p.comp.durationFrames(), 6, reason: '0.1 s at 60 fps');

      await tester.tap(find.byKey(const ValueKey('viewer-play')));
      await tester.pump();
      await settleFrb(tester,
          minRounds: 6, maxRounds: 200, until: () => !p.uiState.playing.value);

      expect(p.uiState.playing.value, isFalse,
          reason: 'the engine said it ended; nothing in Dart worked it out');
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
          duration: settings.duration,
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
      expect(
          (after.positionX as BridgeScalar_Static).field0, greaterThan(beforeX),
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
      await settleFrb(tester,
          minRounds: 6,
          maxRounds: 120,
          until: () => p.uiState.playheadFrame.value > 0);

      expect(p.uiState.playheadFrame.value, greaterThan(0),
          reason:
              'no audio device, so the engine falls back to its wall clock');

      await tester.tap(find.byKey(const ValueKey('viewer-play')));
      await tester.pump();
      expect(audioClock().playing, isFalse,
          reason: 'pausing the transport pauses the sound too');
    }, skip: zeroCopyViewerUnavailable);

    /// The shell's space bar drives the transport through LumitUiState, so the
    /// key is a quiet no-op when no Viewer is mounted.
    testWidgets('the transport request from the shell starts and stops it',
        (tester) async {
      final p = withLayer();
      await mount(tester, p);

      p.uiState.requestTogglePlay();
      await tester.pump();
      await settleFrb(tester,
          minRounds: 6,
          maxRounds: 120,
          until: () => p.uiState.playheadFrame.value > 0);
      expect(p.uiState.playheadFrame.value, greaterThan(0),
          reason: 'space started playback');

      p.uiState.requestTogglePlay();
      await tester.pump();
      await settleFrb(tester, minRounds: 4, maxRounds: 4);
      final stopped = p.uiState.playheadFrame.value;
      await settleFrb(tester, minRounds: 8, maxRounds: 8);
      expect(p.uiState.playheadFrame.value, stopped,
          reason: 'and space stopped it');
    }, skip: zeroCopyViewerUnavailable);

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
      final before = p.uiState.frameArrived.value;
      p.uiState.playheadFrame.value = 12;
      await tester.pump();

      // The first render of a session also builds the renderer, so allow for
      // that before asserting anything about the picture. Frames arrive as
      // shared-texture handles (K-183); in a widget test the platform channel
      // has no handler so no texture registers, but every arrival still bumps
      // `frameArrived` — which is the fact being asserted.
      await settleFrb(
        tester,
        until: () => p.uiState.frameArrived.value > before,
        minRounds: 10,
        maxRounds: 120,
      );
      expect(p.uiState.frameArrived.value, greaterThan(before),
          reason: 'a frame was rendered for the moved playhead');
    }, skip: zeroCopyViewerUnavailable);

    /// A still Viewer must go quiet. While the in-flight rule was being built
    /// it re-asked for the frame it had just been given, so the engine rendered
    /// the same picture over and over for as long as the panel was open.
    /// Scroll-zoom (docs/07 §2.2): the wheel leans the picture in about the
    /// cursor. Observable through the scale the Viewer reports to the engine —
    /// zooming in shows more comp pixels per screen pixel, so it rises — and
    /// through the picker showing a true percentage between its steps.
    testWidgets('the wheel zooms the picture about the cursor', (tester) async {
      final p = withLayer();
      await mount(tester, p);

      final before = p.uiState.viewerScale;
      final centre = tester.getCenter(find.byType(ViewerPanelFrb));
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      pointer.hover(centre);
      // Three notches in.
      for (var i = 0; i < 3; i++) {
        await tester.sendEventToBinding(pointer.scroll(const Offset(0, -120)));
        await tester.pump();
      }

      expect(p.uiState.viewerScale, greaterThan(before),
          reason: 'zooming in raises the on-screen fraction of the comp');
      // The picker tells the truth about a zoom between its steps.
      expect(find.textContaining('%'), findsWidgets);

      // And back out well past fit: the scale falls below where it started.
      for (var i = 0; i < 8; i++) {
        await tester.sendEventToBinding(pointer.scroll(const Offset(0, 120)));
        await tester.pump();
      }
      expect(p.uiState.viewerScale, lessThan(before));
    });

    testWidgets('a still playhead stops asking for renders', (tester) async {
      final p = withLayer();
      await mount(tester, p);

      var frames = 0;
      final sub = p.state.onWorkerResponse.listen((msg) {
        // The idle cache fill is SUPPOSED to work while the playhead is still
        // (K-187) and announces each banked frame; what must go quiet is the
        // PICTURE being re-rendered and re-published.
        if (msg is! WorkerResponse_CacheFilled) frames++;
      });
      addTearDown(sub.cancel);

      // Let the mount render land, then count what follows it.
      await settleFrb(tester,
          minRounds: 10,
          maxRounds: 120,
          until: () => p.uiState.frameArrived.value > 0);
      final settled = frames;

      await settleFrb(tester, minRounds: 20, maxRounds: 20);
      expect(frames, settled,
          reason: 'nothing moved, so nothing should have been rendered');
    });

    /// **The stale-picture regression.** The Viewer asked for a frame when the
    /// playhead moved and at no other time, so an edit made with the playhead
    /// still — typing an opacity, adding an effect, anything another panel
    /// commits — left the old picture on screen until something moved the
    /// playhead. Playing was the usual accident that fixed it, which is exactly
    /// how it was reported: "the Viewer does not update until I play".
    testWidgets('an edit with the playhead still redraws the picture',
        (tester) async {
      final p = withLayer();
      await mount(tester, p);
      await settleFrb(tester,
          minRounds: 10, until: () => p.uiState.frameArrived.value > 0);
      final before = p.uiState.frameArrived.value;
      final playhead = p.uiState.playheadFrame.value;

      p.layer.setTransform(
        prop: BridgeTransformProp.opacity,
        value: const BridgeScalar.static_(25),
      );
      await settleFrb(tester,
          minRounds: 8, until: () => p.uiState.frameArrived.value > before);

      expect(p.uiState.frameArrived.value, greaterThan(before),
          reason: 'the edit asked for the picture again');
      expect(p.uiState.playheadFrame.value, playhead,
          reason: 'and did it without moving the playhead to force it');
    }, skip: zeroCopyViewerUnavailable);

    /// Pressing play with the playhead already at the end used to do nothing at
    /// all: the clock read past the end on its first tick, so it stopped again
    /// immediately, and every-frame's pump had no frame left to ask for. The
    /// rewind is the engine's now — it is the half that knows where the end is.
    testWidgets('play from the end starts from the beginning', (tester) async {
      final p = withLayer();
      await mount(tester, p);
      final last = p.comp.durationFrames() - 1;
      p.uiState.playheadFrame.value = last;
      await tester.pump();

      p.uiState.requestTogglePlay();
      await tester.pump();
      await settleFrb(tester,
          minRounds: 6,
          maxRounds: 120,
          until: () => p.uiState.playheadFrame.value < last);

      expect(p.uiState.playheadFrame.value, lessThan(100),
          reason: 'it rewound rather than sitting at the end doing nothing');
    }, skip: zeroCopyViewerUnavailable);

    /// The two playback behaviours, and the fact that you can see which is on.
    testWidgets('the playback mode is shown on the bar and toggles',
        (tester) async {
      final p = withLayer();
      await mount(tester, p);

      final button = find.byKey(const ValueKey('viewer-playback-mode'));
      expect(button, findsOneWidget, reason: 'the mode is visible, not buried');
      expect(find.textContaining('Adaptive'), findsOneWidget,
          reason:
              'adaptive is the mode that always plays, so it is the default');

      await tester.tap(button);
      await tester.pump();
      expect(find.text('Every frame'), findsOneWidget);
      expect(p.uiState.workspace.performance.playback, PlaybackMode.everyFrame,
          reason: 'and the choice is remembered, not just drawn');

      await tester.tap(button);
      await tester.pump();
      expect(find.textContaining('Adaptive'), findsOneWidget);
    });

    /// Every-frame plays WITH sound now — K-171's actual wording: audio plays
    /// while rendering holds the comp's rate, and the worker pauses it if the
    /// picture falls genuinely behind (it used to be silenced outright).
    /// Headless there is no output device or mix, so what is asserted is the
    /// seam: play in every-frame starts cleanly, the clock stays readable,
    /// and stopping silences whatever there was.
    testWidgets('every-frame playback starts the sound like adaptive',
        (tester) async {
      final p = withLayer();
      p.uiState.workspace.performance.playback = PlaybackMode.everyFrame;
      await mount(tester, p);

      await tester.tap(find.byKey(const ValueKey('viewer-play')));
      await tester.pump();
      expect(audioClock().seconds, greaterThanOrEqualTo(0),
          reason: 'the sound path engaged without a fault');

      await tester.tap(find.byKey(const ValueKey('viewer-play')));
      await tester.pump();
      expect(audioClock().playing, isFalse, reason: 'stop silences it');
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
