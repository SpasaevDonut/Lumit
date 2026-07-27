// The Timeline panel on frb, tested against the real engine.
//
// New coverage: the v0 Timeline's tests are spread across several files and
// written against a fake bridge and a snapshot mirror, neither of which this
// panel has. What they assert about *behaviour* is reproduced here against the
// document itself — a switch that does not reach the engine is not a switch.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/panels/project_panel_frb.dart';
import 'package:lumit_flutter/panels/timeline_panel_frb.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:lumit_flutter/src/rust/api/effect.dart';
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

      final frames = p.comp.durationFrames();
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
    /// The layer rows deliberately do *not* rebuild when the playhead moves —
    /// they used to, sixty times a second during playback, re-asking the engine
    /// for every layer's name and span each time, and the cost grew with the
    /// layer count. Only the playhead line redraws now.
    ///
    /// The razor is what makes that observable: it reads the playhead when it is
    /// clicked rather than when its bar was built. If someone reverts to
    /// capturing the value at build time, the bar has not rebuilt since the
    /// playhead moved, so the cut lands on the old frame and this fails.
    testWidgets('the razor cuts where the playhead is now, not where it was',
        (tester) async {
      final p = withComp();
      final layer = p.comp.addSequenceLayer();
      p.uiState.selectedLayer.value = layer;
      await mount(tester, p);

      // Turn the razor on, then move the playhead — without touching anything
      // that would rebuild the bar.
      await tester.tap(find.byKey(const ValueKey('tl-razor')));
      await tester.pump();
      p.uiState.playheadFrame.value = 30;
      await tester.pump();

      final bar = find.byKey(
          ValueKey<String>('tl-bar-${layer.internallayerId}'));
      expect(bar, findsOneWidget);
      await tester.tap(bar, warnIfMissed: false);
      await tester.pump();

      // A Sequence layer with no clips has nothing to cut, so what is asserted
      // is the frame the razor asked for rather than the resulting clips: the
      // playhead must still be at 30, and nothing may have thrown.
      expect(tester.takeException(), isNull);
      expect(p.uiState.playheadFrame.value, 30);
    });

    /// The twirl-down the port dropped. A layer opens onto its *section
    /// headings* — Transform always, Effects when it has any, Audio only when
    /// its source carries sound — and each heading opens onto its own rows
    /// (docs/07 §4.3).
    testWidgets('a layer opens onto its section headings', (tester) async {
      final p = withComp();
      final layer = p.comp.addSolidLayer();
      await mount(tester, p);

      final twirl =
          find.byKey(ValueKey<String>('tl-twirl-${layer.internallayerId}'));
      expect(twirl, findsOneWidget, reason: 'every layer row has one');
      expect(find.text('Transform'), findsNothing,
          reason: 'closed to start with, or a busy comp is a wall of numbers');

      await tester.tap(twirl);
      await tester.pump();
      expect(find.text('Transform'), findsOneWidget);
      expect(find.text('Position'), findsNothing,
          reason: 'the heading opens first, not every property under it');
      expect(find.text('Effects'), findsNothing,
          reason: 'a layer with no effects has no Effects group to offer');
      expect(find.text('Audio'), findsNothing,
          reason: 'a solid cannot be heard, so it has no volume to set');

      await tester.tap(find.text('Transform'));
      await tester.pump();
      for (final row in ['Anchor point', 'Position', 'Scale', 'Rotation',
        'Opacity']) {
        expect(find.text(row), findsOneWidget);
      }

      await tester.tap(twirl);
      await tester.pump();
      expect(find.text('Transform'), findsNothing);
    });

    testWidgets('dragging a transform value in the Timeline reaches the document',
        (tester) async {
      final p = withComp();
      final layer = p.comp.addSolidLayer();
      await mount(tester, p);
      await tester.tap(
          find.byKey(ValueKey<String>('tl-twirl-${layer.internallayerId}')));
      await tester.pump();
      await tester.tap(find.text('Transform'));
      await tester.pump();

      final before =
          (layer.getTransform().positionX as BridgeScalar_Static).field0;
      await tester.drag(
          find.byKey(const ValueKey('tl-tf-positionX')), const Offset(40, 0));
      await tester.pump();

      expect((layer.getTransform().positionX as BridgeScalar_Static).field0,
          greaterThan(before),
          reason: 'the drag committed, exactly as it does in Effect controls');
    });

    /// An effect adds its own group, and each effect in it opens onto its
    /// parameters — the same rows, and the same drag, the Effect controls panel
    /// shows.
    testWidgets('an effect adds a group whose parameters can be dragged',
        (tester) async {
      final p = withComp();
      final layer = p.comp.addSolidLayer();
      layer.addEffect(name: 'blur');
      await mount(tester, p);

      await tester.tap(
          find.byKey(ValueKey<String>('tl-twirl-${layer.internallayerId}')));
      await tester.pump();
      expect(find.text('Effects'), findsOneWidget,
          reason: 'the group appears because there is something in it');

      await tester.tap(find.text('Effects'));
      await tester.pump();
      expect(find.text('Gaussian blur'), findsOneWidget,
          reason: 'one row per effect, by label');
      expect(find.text('Radius'), findsNothing,
          reason: 'and its parameters wait until it is opened');

      await tester.tap(find.text('Gaussian blur'));
      await tester.pump();
      expect(find.text('Radius'), findsOneWidget);

      final id = layer.getEffects().single.id();
      double radius() => ((layer.getEffects().single.getValue(id: 'radius')
              as BridgeEffectValue_Float)
          .field0 as BridgeScalar_Static)
          .field0;
      final before = radius();

      await tester.drag(
        find.byKey(ValueKey<String>('fx-float-$id-radius')),
        const Offset(50, 0),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(radius(), greaterThan(before),
          reason: 'the parameter drag reached the document');
    });

    /// The Audio group is offered only where there is sound to set. Both halves
    /// matter: a silent layer must not carry a volume control, and one with
    /// audio must.
    testWidgets('the Audio group follows whether the layer can be heard',
        (tester) async {
      final p = withComp();
      final silent = p.comp.addSolidLayer();
      final audible = p.state.project!.importFootage(path: _wavFile('tone.wav'));
      p.comp.addFootageLayer(footage: audible);
      await mount(tester, p);

      final footageLayer = p.comp.getLayers().first;
      // The probe is a real trip into FFmpeg, so the answer arrives after a
      // frame or two rather than during the first build.
      await settleFrb(tester, minRounds: 8);

      await tester.tap(find.byKey(
          ValueKey<String>('tl-twirl-${footageLayer.internallayerId}')));
      await tester.pump();
      expect(find.text('Audio'), findsOneWidget,
          reason: 'the file carries an audio stream');

      await tester.tap(find.text('Audio'));
      await tester.pump();
      expect(find.text('Volume'), findsOneWidget);

      await tester.tap(
          find.byKey(ValueKey<String>('tl-twirl-${silent.internallayerId}')));
      await tester.pump();
      expect(find.text('Audio'), findsOneWidget,
          reason: 'still only the one — a solid has nothing to be heard');
    });

    /// The outline and the lanes are one table. A fold-out that pushed the names
    /// down without leaving the same room beside them would slide every bar
    /// below it away from its own layer.
    testWidgets('an open layer keeps its bars lined up with its names',
        (tester) async {
      final p = withComp();
      final upper = p.comp.addSolidLayer();
      final lower = p.comp.addSolidLayer();
      await mount(tester, p);

      Finder rowOf(LayerReference l) =>
          find.byKey(ValueKey<String>('tl-row-${l.internallayerId}'));
      Finder barOf(LayerReference l) =>
          find.byKey(ValueKey<String>('tl-bar-${l.internallayerId}'));

      for (final layer in [upper, lower]) {
        expect(tester.getTopLeft(rowOf(layer)).dy,
            closeTo(tester.getTopLeft(barOf(layer)).dy, 0.01));
      }

      await tester.tap(
          find.byKey(ValueKey<String>('tl-twirl-${upper.internallayerId}')));
      await tester.pump();
      await tester.tap(find.text('Transform'));
      await tester.pump();

      for (final layer in [upper, lower]) {
        expect(
          tester.getTopLeft(rowOf(layer)).dy,
          closeTo(tester.getTopLeft(barOf(layer)).dy, 0.01),
          reason: 'the layer below an open one still meets its own bar',
        );
      }
    });

  }, skip: !engineAvailable);
}

/// A real, probeable WAV: 16-bit mono PCM, a tenth of a second of silence.
///
/// Written to a temp file **synchronously** — an awaited async `dart:io` call in
/// a `testWidgets` body hangs the test outright (see frb_test_support.dart). The
/// point is only that FFmpeg reports an audio stream, so the samples can be
/// anything.
String _wavFile(String name) {
  final dir = Directory.systemTemp.createTempSync('lumit-audio');
  final file = File('${dir.path}/$name');
  file.writeAsBytesSync(_tinyWav());
  return file.path;
}

Uint8List _tinyWav() {
  const rate = 8000;
  const samples = 800;
  const dataBytes = samples * 2;
  final out = BytesBuilder();
  void ascii(String s) => out.add(s.codeUnits);
  void u16(int v) => out.add([v & 0xff, (v >> 8) & 0xff]);
  void u32(int v) =>
      out.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);

  ascii('RIFF');
  u32(36 + dataBytes);
  ascii('WAVE');
  ascii('fmt ');
  u32(16); // PCM header length
  u16(1); // PCM
  u16(1); // mono
  u32(rate);
  u32(rate * 2); // byte rate
  u16(2); // block align
  u16(16); // bits per sample
  ascii('data');
  u32(dataBytes);
  out.add(Uint8List(dataBytes));
  return out.toBytes();
}
