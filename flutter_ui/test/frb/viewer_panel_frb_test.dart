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

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/panels/viewer_gizmo.dart';
import 'package:lumit_flutter/panels/viewer_panel_frb.dart';
import 'package:lumit_flutter/panels/viewer_paint.dart';
import 'package:lumit_flutter/panels/viewer_zoom.dart';
import 'package:lumit_flutter/state/dropper.dart';
import 'package:lumit_flutter/state/tools.dart';
import 'package:lumit_flutter/state/settings.dart';
import 'package:lumit_flutter/theme/theme.dart';
import 'package:lumit_flutter/src/rust/api/audio.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:lumit_flutter/src/rust/api/effect.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';
import 'package:lumit_flutter/src/rust/api/state.dart';
import 'package:lumit_flutter/widgets/dropper_overlay.dart';
import 'package:uuid/uuid.dart';

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

    /// **The dropper's magnifier belongs to the pointer being over the
    /// picture.** Two things it used to get wrong: it appeared the instant the
    /// tool was armed, sitting where the *previous* pick had left the pointer,
    /// and it stayed on once the pointer had gone.
    testWidgets('the magnifier appears only while the pointer is on the picture',
        (tester) async {
      final p = withLayer();
      await mount(tester, p);

      DropperArm arm() => DropperArm(
            id: 'test',
            reads: DropperReads.colour,
            label: 'Key colour',
            onPick: (_) {},
          );

      p.uiState.armDropper(arm());
      await tester.pump();
      expect(find.byType(DropperViewfinder), findsNothing,
          reason: 'armed, but the pointer has not been near the picture');

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);

      final stage = find.byType(DropperLayer);
      await gesture.moveTo(tester.getCenter(stage));
      await tester.pump();
      expect(find.byType(DropperViewfinder), findsOneWidget,
          reason: 'the pointer is on the picture');

      // The pasteboard around the picture is not the picture: a 16:9 comp in
      // this panel leaves a band top and bottom.
      await gesture.moveTo(tester.getTopLeft(stage) + const Offset(4, 4));
      await tester.pump();
      expect(find.byType(DropperViewfinder), findsNothing,
          reason: 'off the picture, there is nothing to magnify');

      // Back on, then disarmed and armed again: the new arm must not inherit
      // the last one's pointer position.
      await gesture.moveTo(tester.getCenter(stage));
      await tester.pump();
      expect(find.byType(DropperViewfinder), findsOneWidget);

      p.uiState.disarmDropper();
      await tester.pump();
      expect(find.byType(DropperViewfinder), findsNothing);

      p.uiState.armDropper(arm());
      await tester.pump();
      expect(find.byType(DropperViewfinder), findsNothing,
          reason: 'a fresh arm starts with the pointer nowhere');
    });

    /// **The scroll crash.** Scrolling over the Viewer with the dropper armed
    /// zooms the picture, which relays the panel out under the magnifier. The
    /// magnifier is in the application's overlay, so working out where to put
    /// it from render objects *while that rebuild is happening* asserts
    /// `attached` and takes the whole window red. Its position is worked out
    /// when the pointer moves instead, and used as a plain number afterwards.
    testWidgets('scrolling with the dropper armed does not throw',
        (tester) async {
      final p = withLayer();
      await mount(tester, p);

      p.uiState.armDropper(DropperArm(
        id: 'test',
        reads: DropperReads.colour,
        label: 'Key colour',
        onPick: (_) {},
      ));
      await tester.pump();

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      final centre = tester.getCenter(find.byType(DropperLayer));
      await gesture.moveTo(centre);
      await tester.pump();
      expect(find.byType(DropperViewfinder), findsOneWidget);

      // An ordinary wheel scroll: the Viewer zooms about the pointer.
      await tester.sendEventToBinding(
        PointerScrollEvent(position: centre, scrollDelta: const Offset(0, -60)),
      );
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'zooming under it is fine');

      // And again the other way, with the magnifier still up.
      await tester.sendEventToBinding(
        PointerScrollEvent(position: centre, scrollDelta: const Offset(0, 120)),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byType(DropperViewfinder), findsOneWidget,
          reason: 'and it is still following the pointer');
    });

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
    testWidgets('dragging a selected layer repositions it', (tester) async {
      final p = withLayer();
      await mount(tester, p);

      final before = p.layer.getTransform();
      final beforeX = (before.positionX as BridgeScalar_Static).field0;

      // The layer fills the comp, so the middle of the picture is inside it —
      // there is no handle to find any more: the body is the handle (K-215).
      final stage = find.byType(ViewerPanelFrb);
      final gesture = await tester.startGesture(tester.getCenter(stage));
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

    testWidgets('with the Hand tool a drag pans the view and leaves the layer'
        ' alone', (tester) async {
      final p = withLayer();
      p.uiState.tools.select(ToolMode.hand);
      await mount(tester, p);

      final before = p.layer.getTransform();
      final beforeX = (before.positionX as BridgeScalar_Static).field0;

      final stage = find.byType(ViewerPanelFrb);
      final gesture = await tester.startGesture(tester.getCenter(stage));
      await tester.pump();
      for (var i = 0; i < 8; i++) {
        await gesture.moveBy(const Offset(6, 0));
        await tester.pump();
      }
      await gesture.up();
      await tester.pumpAndSettle();

      expect((p.layer.getTransform().positionX as BridgeScalar_Static).field0,
          beforeX,
          reason: 'the Hand tool moves the picture, never the layer');
    });

    testWidgets('a drag from empty space marquees, and takes what is wholly'
        ' inside it', (tester) async {
      final p = withLayer();
      // A small solid, so the marquee can enclose it without enclosing the
      // comp-sized adjustment layer above it.
      final solid = p.comp.addSolidLayer();
      solid.setTransform(
          prop: BridgeTransformProp.scaleX, value: BridgeScalar.static_(10));
      solid.setTransform(
          prop: BridgeTransformProp.scaleY, value: BridgeScalar.static_(10));
      p.uiState.clearSelection();
      p.uiState.model.refresh();
      await mount(tester, p);

      // Sweep the whole panel: everything wholly inside is taken, and the
      // adjustment layer's box is exactly the comp, so it qualifies too.
      final stage = tester.getRect(find.byType(ViewerPanelFrb));
      final gesture = await tester.startGesture(stage.topLeft + const Offset(2, 2));
      await tester.pump();
      await gesture.moveTo(stage.center);
      await tester.pump();
      await gesture.moveTo(stage.bottomRight - const Offset(2, 40));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(p.uiState.selectedLayers.value, isNotEmpty,
          reason: 'a marquee over everything selects something');
      expect(
          p.uiState.selectedLayers.value
              .any((l) => l.internallayerId == solid.internallayerId),
          isTrue,
          reason: 'the small solid is wholly inside the sweep');
    });

    testWidgets('an animated position gets no box, so nothing drags it',
        (tester) async {
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
      p.uiState.model.refresh();
      await mount(tester, p);

      final stage = find.byType(ViewerPanelFrb);
      final gesture = await tester.startGesture(tester.getCenter(stage));
      await tester.pump();
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      final after = p.layer.getTransform();
      expect(after.positionX, isA<BridgeScalar_Keyframed>(),
          reason: 'a curve is not overwritten by a drag it never accepted');
    });

    /// Where the picture is drawn inside the panel, worked out the way the
    /// panel works it out: the stage is the panel less its bar, and the comp is
    /// fitted into it. The gizmo's handles sit on this rectangle for a
    /// comp-sized layer, which is what lets a test grab one.
    Rect fittedRect(WidgetTester tester, CompositionReference comp) {
      const barHeight = 26.0;
      final panel = tester.getRect(find.byType(ViewerPanelFrb));
      final stage = Rect.fromLTWH(
          panel.left, panel.top, panel.width, panel.height - barHeight);
      final size = comp.getSize();
      final scale = math.min(
          stage.width / size.width, stage.height / size.height);
      final drawn = Size(size.width * scale, size.height * scale);
      return Rect.fromLTWH(
        stage.left + (stage.width - drawn.width) / 2,
        stage.top + (stage.height - drawn.height) / 2,
        drawn.width,
        drawn.height,
      );
    }

    testWidgets('clicking picks the layer under the pointer, and Shift adds to'
        ' the selection', (tester) async {
      final p = withLayer();
      final second = p.comp.addSolidLayer();
      p.uiState.clearSelection();
      p.uiState.model.refresh();
      await mount(tester, p);

      // Both layers are comp-sized, so the middle of the picture is inside
      // both and the topmost — the solid, added last and therefore on top —
      // takes the click.
      await tester.tapAt(fittedRect(tester, p.comp).center);
      await tester.pumpAndSettle();
      expect(p.uiState.selectedLayers.value.length, 1);
      expect(p.uiState.selectedLayer.value?.internallayerId,
          second.internallayerId,
          reason: 'the topmost layer takes the click');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tapAt(fittedRect(tester, p.comp).center);
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

      expect(p.uiState.selectedLayers.value.length, isNot(1),
          reason: 'Shift-clicking the same layer takes it back out again');
    });

    testWidgets('a Null layer can be picked on the picture, though it draws'
        ' nothing', (tester) async {
      final p = freshProject();
      final comp = p.state.project!.newComposition(name: 'Rig');
      final nul = comp.addNullLayer();
      p.uiState.setSelectedComp(comp);
      p.uiState.model.refresh();
      await mount(tester, p);

      final fitted = fittedRect(tester, comp);
      // The Null's own 100x100 box sits on the comp's middle.
      await tester.tapAt(fitted.center);
      await tester.pumpAndSettle();
      expect(p.uiState.selectedLayer.value?.internallayerId,
          nul.internallayerId,
          reason: 'a layer with no pixels is still a layer you can point at');

      // Well outside that small box, and there is nothing else in the comp.
      await tester.tapAt(fitted.center + const Offset(200, 0));
      await tester.pumpAndSettle();
      expect(p.uiState.selectedLayers.value, isEmpty);
    });

    testWidgets('clicking empty space clears the selection', (tester) async {
      final p = withLayer();
      await mount(tester, p);
      expect(p.uiState.selectedLayers.value, isNotEmpty);

      // The very corner of the panel is outside the fitted picture, so it is
      // outside every layer's box.
      final panel = tester.getRect(find.byType(ViewerPanelFrb));
      await tester.tapAt(panel.topLeft + const Offset(2, 2));
      await tester.pumpAndSettle();

      expect(p.uiState.selectedLayers.value, isEmpty);
      expect(p.uiState.selectedLayer.value, isNull,
          reason: 'the primary follows the selection');
    });

    /// The selected layer's box on screen, for a comp-sized layer scaled to
    /// [scalePercent] about its own middle: the fitted picture, shrunk about
    /// its centre. Half size keeps the handles well inside the window, where a
    /// gesture can reach them — a corner handle on a comp-sized layer sits on
    /// the window's own edge.
    Rect boxRect(WidgetTester tester, CompositionReference comp,
        double scalePercent) {
      final fitted = fittedRect(tester, comp);
      final factor = scalePercent / 100.0;
      return Rect.fromCenter(
        center: fitted.center,
        width: fitted.width * factor,
        height: fitted.height * factor,
      );
    }

    /// A layer at half size, so its handles are reachable.
    void halveIt(LayerReference layer) {
      layer.setTransform(
          prop: BridgeTransformProp.scaleX, value: BridgeScalar.static_(50));
      layer.setTransform(
          prop: BridgeTransformProp.scaleY, value: BridgeScalar.static_(50));
    }

    testWidgets('dragging a corner handle scales the layer', (tester) async {
      final p = withLayer();
      halveIt(p.layer);
      p.uiState.model.refresh();
      await mount(tester, p);

      final before =
          (p.layer.getTransform().scaleX as BridgeScalar_Static).field0;
      final box = boxRect(tester, p.comp, 50);

      final gesture = await tester.startGesture(box.bottomRight);
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await gesture.moveBy(const Offset(10, 6));
        await tester.pump();
      }
      await gesture.up();
      await tester.pumpAndSettle();

      final after =
          (p.layer.getTransform().scaleX as BridgeScalar_Static).field0;
      expect(after, greaterThan(before),
          reason: 'pulling the corner away from the anchor grows the layer');
    });

    testWidgets('dragging the rotation knob turns the layer', (tester) async {
      final p = withLayer();
      halveIt(p.layer);
      p.uiState.model.refresh();
      await mount(tester, p);

      final box = boxRect(tester, p.comp, 50);
      final knob = Offset(box.center.dx, box.top - gizmoRotateReach);

      final gesture = await tester.startGesture(knob);
      await tester.pump();
      // Round towards the right-hand side: a clockwise sweep about the middle.
      for (var i = 0; i < 6; i++) {
        await gesture.moveBy(const Offset(20, 10));
        await tester.pump();
      }
      await gesture.up();
      await tester.pumpAndSettle();

      final rotation = p.layer.getTransform().rotation;
      expect((rotation as BridgeScalar_Static).field0, isNot(0),
          reason: 'the knob wrote a rotation');
    });

    testWidgets('the wireframe switch is in the bar and toggles', (tester) async {
      final p = withLayer();
      await mount(tester, p);

      final button = find.byKey(const ValueKey('viewer-wireframes'));
      expect(button, findsOneWidget);
      await tester.tap(button);
      await tester.pumpAndSettle();
      // Hiding the controls must not disturb the selection or the picture: it
      // is a drawing switch, nothing more.
      expect(p.uiState.selectedLayers.value, isNotEmpty);
    });

    /// The Zoom tool armed, on a comp bigger than the panel so there is room
    /// to zoom in before the clamp.
    Future<({LumitState state, LumitUiState uiState, CompositionReference comp,
        LayerReference layer})> withZoomTool(
      WidgetTester tester, {
      AnimationLevel motion = AnimationLevel.none,
    }) async {
      final p = withLayer();
      p.uiState.tools.select(ToolMode.zoom);
      await tester.pumpWidget(hostPanel(
        child: const ViewerPanelFrb(),
        state: p.state,
        uiState: p.uiState,
        size: const Size(700, 500),
        animationLevel: motion,
      ));
      await tester.pumpAndSettle();
      return p;
    }

    testWidgets('the Zoom tool zooms in where it is clicked, and out with Alt',
        (tester) async {
      final p = await withZoomTool(tester);
      final fitted = fittedRect(tester, p.comp);
      final before = p.uiState.viewerScale;

      await tester.tapAt(fitted.center + const Offset(60, 20));
      await tester.pumpAndSettle();
      final zoomedIn = p.uiState.viewerScale;
      expect(zoomedIn, greaterThan(before),
          reason: 'a click magnifies about the point it landed on');
      expect(zoomedIn, closeTo(before * zoomToolStep, 1e-6));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.tapAt(fitted.center + const Offset(60, 20));
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);

      expect(p.uiState.viewerScale, closeTo(before, 1e-6),
          reason: 'Alt+click undoes the click before it');
    });

    testWidgets('dragging a box with the Zoom tool fits that box to the panel',
        (tester) async {
      final p = await withZoomTool(tester);
      final fitted = fittedRect(tester, p.comp);
      final before = p.uiState.viewerScale;

      // A quarter-width sweep in the middle of the picture.
      final from = fitted.center - Offset(fitted.width / 8, fitted.height / 8);
      final to = fitted.center + Offset(fitted.width / 8, fitted.height / 8);
      final gesture = await tester.startGesture(from);
      await tester.pump();
      await gesture.moveTo(Offset(to.dx, from.dy));
      await tester.pump();
      await gesture.moveTo(to);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(p.uiState.viewerScale, greaterThan(before * 2),
          reason: 'a quarter of the picture fills the panel');
    });

    testWidgets('a box drag with Alt zooms out instead', (tester) async {
      final p = await withZoomTool(tester);
      final fitted = fittedRect(tester, p.comp);
      final before = p.uiState.viewerScale;

      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      final from = fitted.center - Offset(fitted.width / 8, fitted.height / 8);
      final to = fitted.center + Offset(fitted.width / 8, fitted.height / 8);
      final gesture = await tester.startGesture(from);
      await tester.pump();
      // In steps: a single jump gives the recogniser a start and an end with
      // no update between them, so the box would be the width of the slop.
      await gesture.moveTo(Offset(to.dx, from.dy));
      await tester.pump();
      await gesture.moveTo(to);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);

      expect(p.uiState.viewerScale, lessThan(before));
    });

    testWidgets('a tiny wobble of a drag is a click, not a box', (tester) async {
      final p = await withZoomTool(tester);
      final fitted = fittedRect(tester, p.comp);
      final before = p.uiState.viewerScale;

      final gesture = await tester.startGesture(fitted.center);
      await tester.pump();
      await gesture.moveBy(const Offset(3, 2));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      // A few pixels of travel is a hand, not an intention: fitting a
      // three-pixel box to the panel would throw the picture into orbit. It
      // takes the click's own step instead.
      expect(p.uiState.viewerScale, closeTo(before * zoomToolStep, 1e-6));
    });

    testWidgets('the zoom flies rather than jumping when the shell animates',
        (tester) async {
      final p = await withZoomTool(tester, motion: AnimationLevel.all);
      final fitted = fittedRect(tester, p.comp);
      final before = p.uiState.viewerScale;

      await tester.tapAt(fitted.center);
      // Part-way through the flight the magnification is between the two.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      final midway = p.uiState.viewerScale;
      expect(midway, greaterThan(before));
      expect(midway, lessThan(before * zoomToolStep),
          reason: 'it is on its way, not there yet');

      await tester.pumpAndSettle();
      expect(p.uiState.viewerScale, closeTo(before * zoomToolStep, 1e-6),
          reason: 'and it lands exactly where it was sent');
    });

    testWidgets('with motion off the zoom lands on the first frame',
        (tester) async {
      final p = await withZoomTool(tester);
      final fitted = fittedRect(tester, p.comp);
      final before = p.uiState.viewerScale;

      await tester.tapAt(fitted.center);
      await tester.pump();

      expect(p.uiState.viewerScale, closeTo(before * zoomToolStep, 1e-6),
          reason: 'no animation means the hard cut, immediately');
    });

    testWidgets('the Rotation tool turns the selection about its anchor, and'
        ' leaves unselected layers alone', (tester) async {
      final p = withLayer();
      final other = p.comp.addSolidLayer();
      // Only the adjustment layer is selected.
      p.uiState.setSelection([p.layer]);
      p.uiState.tools.select(ToolMode.rotate);
      p.uiState.model.refresh();
      await mount(tester, p);

      final fitted = fittedRect(tester, p.comp);
      // A quarter-turn about the middle: straight up, round to the right.
      final gesture = await tester.startGesture(
          Offset(fitted.center.dx, fitted.center.dy - 100));
      await tester.pump();
      await gesture.moveTo(
          Offset(fitted.center.dx + 70, fitted.center.dy - 70));
      await tester.pump();
      await gesture.moveTo(Offset(fitted.center.dx + 100, fitted.center.dy));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      final turned =
          (p.layer.getTransform().rotation as BridgeScalar_Static).field0;
      expect(turned, closeTo(90, 0.5),
          reason: 'the angle swept about the anchor is the angle written');
      expect((other.getTransform().rotation as BridgeScalar_Static).field0, 0,
          reason: 'a layer that was not selected does not turn');
    });

    testWidgets('Shift locks the turn to 45 degrees', (tester) async {
      final p = withLayer();
      p.uiState.tools.select(ToolMode.rotate);
      await mount(tester, p);

      final fitted = fittedRect(tester, p.comp);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      final gesture = await tester.startGesture(
          Offset(fitted.center.dx, fitted.center.dy - 100));
      await tester.pump();
      // A little over 30 degrees round: without the lock it would write ~34.
      await gesture.moveTo(
          Offset(fitted.center.dx + 56, fitted.center.dy - 83));
      await tester.pump();
      await gesture.moveTo(
          Offset(fitted.center.dx + 58, fitted.center.dy - 81));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

      final turned =
          (p.layer.getTransform().rotation as BridgeScalar_Static).field0;
      expect(turned % 45, closeTo(0, 1e-6),
          reason: 'held Shift, so it lands on a 45-degree step');
    });

    testWidgets('the Rotation tool picks a layer when you click one',
        (tester) async {
      final p = withLayer();
      p.uiState.clearSelection();
      p.uiState.tools.select(ToolMode.rotate);
      await mount(tester, p);

      await tester.tapAt(fittedRect(tester, p.comp).center);
      await tester.pumpAndSettle();

      expect(p.uiState.selectedLayer.value?.internallayerId,
          p.layer.internallayerId,
          reason: 'a rotation tool you cannot choose a layer with is a trip'
              ' back to the toolbar between every turn');
    });

    testWidgets('with nothing selected the Rotation tool turns nothing',
        (tester) async {
      final p = withLayer();
      p.uiState.clearSelection();
      p.uiState.tools.select(ToolMode.rotate);
      await mount(tester, p);

      final fitted = fittedRect(tester, p.comp);
      final gesture = await tester.startGesture(
          Offset(fitted.center.dx, fitted.center.dy - 100));
      await tester.pump();
      await gesture.moveTo(Offset(fitted.center.dx + 60, fitted.center.dy));
      await tester.pump();
      await gesture.moveTo(Offset(fitted.center.dx + 100, fitted.center.dy));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect((p.layer.getTransform().rotation as BridgeScalar_Static).field0, 0);
    });

    testWidgets('the Anchor point tool slides the pivot and leaves the picture'
        ' where it was', (tester) async {
      final p = withLayer();
      p.uiState.tools.select(ToolMode.anchor);
      await mount(tester, p);

      final before = p.layer.getTransform();
      double at(BridgeScalar s) => (s as BridgeScalar_Static).field0;
      final anchorBefore = (at(before.anchorX), at(before.anchorY));
      final positionBefore = (at(before.positionX), at(before.positionY));

      final fitted = fittedRect(tester, p.comp);
      final gesture = await tester.startGesture(fitted.center);
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await gesture.moveBy(const Offset(10, 0));
        await tester.pump();
      }
      await gesture.up();
      await tester.pumpAndSettle();

      final after = p.layer.getTransform();
      expect(at(after.anchorX), isNot(anchorBefore.$1),
          reason: 'the pivot moved');
      // Pan behind: the anchor moved right, so Position moved right by exactly
      // as much (the layer is unscaled and unturned), and the picture did not
      // move at all.
      final anchorDelta = at(after.anchorX) - anchorBefore.$1;
      final positionDelta = at(after.positionX) - positionBefore.$1;
      expect(positionDelta, closeTo(anchorDelta, 0.001),
          reason: 'Position compensated exactly, so nothing appeared to move');
      expect(at(after.anchorY), closeTo(anchorBefore.$2, 0.001),
          reason: 'a sideways drag does not move the pivot vertically');
    });

    testWidgets('the Anchor point tool picks a layer when you click one',
        (tester) async {
      final p = withLayer();
      p.uiState.clearSelection();
      p.uiState.tools.select(ToolMode.anchor);
      await mount(tester, p);

      await tester.tapAt(fittedRect(tester, p.comp).center);
      await tester.pumpAndSettle();

      expect(p.uiState.selectedLayer.value?.internallayerId,
          p.layer.internallayerId);
    });

    testWidgets('the gizmo\'s centre handle pans behind, and a drag beside it'
        ' still moves the layer', (tester) async {
      final p = withLayer();
      halveIt(p.layer);
      p.uiState.model.refresh();
      await mount(tester, p);

      double at(BridgeScalar s) => (s as BridgeScalar_Static).field0;
      final before = p.layer.getTransform();
      final anchorBefore = at(before.anchorX);
      final positionBefore = at(before.positionX);

      // Dead on the pivot — the middle of a layer anchored on its own centre.
      final box = boxRect(tester, p.comp, 50);
      var gesture = await tester.startGesture(box.center);
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await gesture.moveBy(const Offset(8, 0));
        await tester.pump();
      }
      await gesture.up();
      await tester.pumpAndSettle();

      final panned = p.layer.getTransform();
      expect(at(panned.anchorX), isNot(anchorBefore), reason: 'the pivot moved');
      expect(at(panned.positionX) - positionBefore,
          closeTo((at(panned.anchorX) - anchorBefore) / 2, 0.001),
          reason: 'Position compensated (at 50%, half the layer-pixel delta), '
              'so the picture did not move');

      // A press a little way off the pivot is an ordinary move again.
      final anchorNow = at(p.layer.getTransform().anchorX);
      final positionNow = at(p.layer.getTransform().positionX);
      gesture = await tester.startGesture(box.center + const Offset(40, 0));
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await gesture.moveBy(const Offset(8, 0));
        await tester.pump();
      }
      await gesture.up();
      await tester.pumpAndSettle();

      final moved = p.layer.getTransform();
      expect(at(moved.anchorX), closeTo(anchorNow, 0.001),
          reason: 'a body drag leaves the pivot alone');
      expect(at(moved.positionX), greaterThan(positionNow));
    });

    /// The shape tools (K-220). With a layer selected a drag draws a **mask** on
    /// it; with nothing selected there is nothing to mask, and the status line
    /// says so rather than the drag vanishing into silence.
    testWidgets('a shape drag adds a mask to the selected layer',
        (tester) async {
      final p = withLayer();
      p.uiState.tools.select(ToolMode.shapeEllipse);
      await mount(tester, p);
      expect(p.layer.getMasks(), isEmpty);

      final fitted = fittedRect(tester, p.comp);
      final gesture = await tester.startGesture(
          fitted.center - const Offset(60, 40));
      await tester.pump();
      await gesture.moveTo(fitted.center);
      await tester.pump();
      await gesture.moveTo(fitted.center + const Offset(60, 40));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      final masks = p.layer.getMasks();
      expect(masks, hasLength(1));
      expect(masks.single.name, 'Ellipse');
      expect(masks.single.closed, isTrue);
      expect(masks.single.vertices, hasLength(4),
          reason: 'an ellipse is four cubics');
      // Drawn in layer space, so the mask sits where the drag was: the comp is
      // 1920x1080 and the drag was about its middle.
      final xs = [for (final v in masks.single.vertices) v.x];
      expect(xs.reduce((a, b) => a < b ? a : b), greaterThan(0));
      expect(xs.reduce((a, b) => a > b ? a : b), lessThan(1920));
    });

    testWidgets('a shape drag with nothing selected says what to do instead',
        (tester) async {
      final p = withLayer();
      p.uiState.clearSelection();
      p.uiState.tools.select(ToolMode.shapeRectangle);
      await mount(tester, p);

      final fitted = fittedRect(tester, p.comp);
      final gesture = await tester.startGesture(fitted.center);
      await tester.pump();
      await gesture.moveBy(const Offset(40, 30));
      await tester.pump();
      await gesture.moveBy(const Offset(40, 30));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(p.layer.getMasks(), isEmpty);
      expect(p.state.notice.value?.message, contains('Select a layer'),
          reason: 'silence would look like a broken tool (shape layers are '
              'not built — docs/TODO.md)');
    });

    testWidgets('the Pen places points and closes on the first one',
        (tester) async {
      final p = withLayer();
      p.uiState.tools.select(ToolMode.pen);
      await mount(tester, p);

      final fitted = fittedRect(tester, p.comp);
      final first = fitted.center - const Offset(80, 60);
      await tester.tapAt(first);
      await tester.pumpAndSettle();
      await tester.tapAt(fitted.center + const Offset(80, -60));
      await tester.pumpAndSettle();
      await tester.tapAt(fitted.center + const Offset(0, 70));
      await tester.pumpAndSettle();
      expect(p.layer.getMasks(), isEmpty,
          reason: 'an open path is a shape being drawn, not a mask yet');

      // Clicking the first point again closes it, and that is what applies it.
      await tester.tapAt(first);
      await tester.pumpAndSettle();

      final masks = p.layer.getMasks();
      expect(masks, hasLength(1));
      expect(masks.single.name, 'Path');
      expect(masks.single.vertices, hasLength(3));
      expect(masks.single.closed, isTrue);
    });

    testWidgets('the polygon tool drags out a five-sided mask', (tester) async {
      final p = withLayer();
      p.uiState.tools.select(ToolMode.shapePolygon);
      await mount(tester, p);

      final fitted = fittedRect(tester, p.comp);
      final gesture =
          await tester.startGesture(fitted.center - const Offset(70, 70));
      await tester.pump();
      await gesture.moveTo(fitted.center);
      await tester.pump();
      await gesture.moveTo(fitted.center + const Offset(70, 70));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      final masks = p.layer.getMasks();
      expect(masks, hasLength(1));
      expect(masks.single.name, 'Polygon');
      expect(masks.single.vertices, hasLength(5),
          reason: 'a polygon is a shape you drag out, not a path you build '
              '(K-221)');
    });

    /// Mask points are editable on the picture (K-222): they draw as squares on
    /// the path, a marquee gathers them, and dragging moves them.
    testWidgets('a mask\'s points can be swept up and dragged', (tester) async {
      final p = withLayer();
      // A small rectangle mask in the middle of the comp, so its points sit
      // well inside the picture.
      p.layer.addMask(
        mask: BridgeMask(
          id: UuidValue.fromString(const Uuid().v4()),
          name: 'Rectangle',
          vertices: const [
            BridgeVertex(
                x: 860, y: 440, tanInX: 0, tanInY: 0, tanOutX: 0, tanOutY: 0),
            BridgeVertex(
                x: 1060, y: 440, tanInX: 0, tanInY: 0, tanOutX: 0, tanOutY: 0),
            BridgeVertex(
                x: 1060, y: 640, tanInX: 0, tanInY: 0, tanOutX: 0, tanOutY: 0),
            BridgeVertex(
                x: 860, y: 640, tanInX: 0, tanInY: 0, tanOutX: 0, tanOutY: 0),
          ],
          closed: true,
          inverted: false,
          opacity: 100,
        ),
      );
      p.uiState.model.refresh();
      await mount(tester, p);

      final before = p.layer.getMasks().single.vertices;
      final fitted = fittedRect(tester, p.comp);
      // Where the mask's top-left point is on screen: layer space maps 1:1 to
      // the comp here, so it is the fitted rect scaled.
      Offset onScreen(double x, double y) => Offset(
            fitted.left + x / 1920 * fitted.width,
            fitted.top + y / 1080 * fitted.height,
          );

      // Sweep the top two points only, starting from empty space *outside* the
      // picture: a press inside a selected layer moves that layer, which is
      // what the Selection tool has always done (K-215) and what After Effects
      // does. The surround is the empty part a marquee starts from.
      final panel = tester.getRect(find.byType(ViewerPanelFrb));
      final gesture = await tester.startGesture(panel.topLeft + const Offset(2, 2));
      await tester.pump();
      await gesture.moveTo(onScreen(1000, 480));
      await tester.pump();
      await gesture.moveTo(onScreen(1100, 500));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      // Nothing has moved yet — a sweep only chooses.
      expect(p.layer.getMasks().single.vertices.first.x, before.first.x);

      // Now drag one of the caught points; both should travel.
      final drag = await tester.startGesture(onScreen(860, 440));
      await tester.pump();
      // Past the framework's pan slop, which is larger than the touch slop.
      for (var i = 0; i < 10; i++) {
        await drag.moveBy(const Offset(6, 0));
        await tester.pump();
      }
      await drag.up();
      await tester.pumpAndSettle();

      final after = p.layer.getMasks().single.vertices;
      expect(after[0].x, greaterThan(before[0].x),
          reason: 'the swept top-left point moved');
      expect(after[1].x, greaterThan(before[1].x),
          reason: 'and so did the other one the sweep caught');
      expect(after[3].x, closeTo(before[3].x, 0.001),
          reason: 'the points the sweep missed stayed put');
    });

    /// The Type tool (K-223): a click on empty picture makes a text layer where
    /// it landed, typing previews rather than writing, and ending the edit
    /// writes the document once.
    testWidgets('the Type tool makes a text layer where you click',
        (tester) async {
      final p = freshProject();
      final comp = p.state.project!.newComposition(name: 'Scene');
      p.uiState
        ..setSelectedComp(comp)
        ..tools.select(ToolMode.typeHorizontal);
      await tester.pumpWidget(hostPanel(
        child: const ViewerPanelFrb(),
        state: p.state,
        uiState: p.uiState,
        size: const Size(700, 500),
      ));
      await tester.pump();

      final fitted = fittedRect(tester, comp);
      final at = fitted.center + const Offset(40, 20);
      await tester.tapAt(at);
      await tester.pumpAndSettle();

      final layers = comp.getLayers();
      expect(layers, hasLength(1), reason: 'the click made one');
      final layer = layers.single;
      expect(layer.getText(), isNotNull, reason: 'and it is a text layer');
      expect(layer.getText()!.text, isEmpty,
          reason: 'an empty line, waiting to be typed into');

      // Where it landed, in comp pixels.
      final size = comp.getSize();
      final scale = fitted.width / size.width;
      final tf = layer.getTransform();
      double still(dynamic s) => (s as dynamic).field0 as double;
      expect(still(tf.positionX),
          closeTo((at.dx - fitted.left) / scale, 0.5));
      expect(still(tf.positionY), closeTo((at.dy - fitted.top) / scale, 0.5));

      // Typing does not touch the document — that is what the preview path is
      // for — and ending the edit writes it once.
      await tester.enterText(find.byType(EditableText), 'Hello');
      await tester.pump();
      expect(layer.getText()!.text, isEmpty,
          reason: 'still previewing; the document is untouched');

      p.uiState.tools.select(ToolMode.select);
      await tester.pumpAndSettle();
      expect(layer.getText()!.text, 'Hello',
          reason: 'putting the tool down ends the edit and writes it');
    });

    testWidgets('a Type click with nothing typed leaves no layer behind',
        (tester) async {
      final p = freshProject();
      final comp = p.state.project!.newComposition(name: 'Scene');
      p.uiState
        ..setSelectedComp(comp)
        ..tools.select(ToolMode.typeHorizontal);
      await tester.pumpWidget(hostPanel(
        child: const ViewerPanelFrb(),
        state: p.state,
        uiState: p.uiState,
        size: const Size(700, 500),
      ));
      await tester.pump();

      await tester.tapAt(fittedRect(tester, comp).center);
      await tester.pumpAndSettle();
      expect(comp.getLayers(), hasLength(1));

      p.uiState.tools.select(ToolMode.select);
      await tester.pumpAndSettle();
      expect(comp.getLayers(), isEmpty,
          reason: 'a stray click must not leave an empty text layer');
    });

    testWidgets('the Type tool edits the text layer you click on',
        (tester) async {
      final p = freshProject();
      final comp = p.state.project!.newComposition(name: 'Scene');
      final layer = comp.addTextLayer();
      p.uiState
        ..setSelectedComp(comp)
        ..tools.select(ToolMode.typeHorizontal);
      p.uiState.model.refresh();
      await tester.pumpWidget(hostPanel(
        child: const ViewerPanelFrb(),
        state: p.state,
        uiState: p.uiState,
        size: const Size(700, 500),
      ));
      await tester.pump();

      await tester.tapAt(fittedRect(tester, comp).center);
      await tester.pumpAndSettle();
      expect(comp.getLayers(), hasLength(1),
          reason: 'clicking an existing text layer edits it rather than '
              'making another');
      expect(find.byType(EditableText), findsOneWidget);
      expect(tester.widget<EditableText>(find.byType(EditableText))
          .controller.text, 'Text', reason: 'seeded with what it says');

      await tester.enterText(find.byType(EditableText), 'Retitled');
      await tester.pump();
      p.uiState.tools.select(ToolMode.select);
      await tester.pumpAndSettle();
      expect(layer.getText()!.text, 'Retitled');
    });

    /// Painting (K-225): a drag on the selected layer leaves a stroke, and one
    /// drag is one stroke and one undo step.
    testWidgets('a brush drag paints a stroke on the selected layer',
        (tester) async {
      final p = withLayer();
      p.uiState.tools.select(ToolMode.brush);
      await mount(tester, p);

      expect(find.byType(ViewerPaintLayer), findsOneWidget);
      expect(p.layer.getPaint(), isEmpty);

      final fitted = fittedRect(tester, p.comp);
      final gesture = await tester.startGesture(fitted.center);
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await gesture.moveBy(const Offset(10, 4));
        await tester.pump();
      }
      await gesture.up();
      await tester.pumpAndSettle();

      final strokes = p.layer.getPaint();
      expect(strokes, hasLength(1), reason: 'one drag, one stroke');
      expect(strokes.single.name, startsWith('Brush'));
      expect(strokes.single.mode, BridgePaintMode.paint);
      expect(strokes.single.points.length, greaterThan(1),
          reason: 'the path the pointer took, not one dab');
      expect(strokes.single.width, p.uiState.tools.brushSize);

      // The stroke is in layer coordinates: the middle of the picture is the
      // middle of a comp-sized layer.
      final size = p.comp.getSize();
      expect(strokes.single.points.first.x,
          closeTo(size.width / 2, size.width * 0.02));

      p.state.project!.undo();
      p.uiState.model.refresh();
      expect(p.layer.getPaint(), isEmpty, reason: 'one undo step');
    });

    testWidgets('the eraser and the clone stamp commit their own modes',
        (tester) async {
      final p = withLayer();
      p.uiState.tools.select(ToolMode.eraser);
      await mount(tester, p);
      final fitted = fittedRect(tester, p.comp);

      Future<void> paintAt(Offset from) async {
        final gesture = await tester.startGesture(from);
        await tester.pump();
        for (var i = 0; i < 6; i++) {
          await gesture.moveBy(const Offset(9, 0));
          await tester.pump();
        }
        await gesture.up();
        await tester.pumpAndSettle();
      }

      await paintAt(fitted.center);
      expect(p.layer.getPaint().single.mode, BridgePaintMode.erase);

      // The clone stamp refuses to stamp until it has been given a source.
      p.uiState.tools.select(ToolMode.cloneStamp);
      await tester.pump();
      await paintAt(fitted.center + const Offset(0, 40));
      expect(p.layer.getPaint(), hasLength(1),
          reason: 'no source yet, so nothing was stamped');
      expect(p.state.notice.value?.message, contains('clone source'));

      // Alt-click sets it, and then the stroke lands with the offset it implies.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.tapAt(fitted.center - const Offset(80, 0));
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await paintAt(fitted.center + const Offset(0, 40));

      final strokes = p.layer.getPaint();
      expect(strokes, hasLength(2));
      expect(strokes.last.mode, BridgePaintMode.clone);
      expect(strokes.last.cloneOffsetX, lessThan(0),
          reason: 'the source was to the left of where the stroke began');
    });

    testWidgets('painting with nothing selected says what to do instead',
        (tester) async {
      final p = withLayer();
      p.uiState.clearSelection();
      p.uiState.tools.select(ToolMode.brush);
      await mount(tester, p);

      final gesture = await tester.startGesture(fittedRect(tester, p.comp).center);
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await gesture.moveBy(const Offset(9, 0));
        await tester.pump();
      }
      await gesture.up();
      await tester.pumpAndSettle();

      expect(p.layer.getPaint(), isEmpty);
      expect(p.state.notice.value?.message, contains('Select a layer to paint'));
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
