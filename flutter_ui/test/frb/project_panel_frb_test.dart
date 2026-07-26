// The Project panel on frb, tested against the real engine.
//
// These are the ported equivalents of the 12 v0 tests that lived in
// project_placement_test.dart, section_d_test.dart and final_sweep_test.dart,
// plus coverage for three things v0 never asserted at all: the folder tree, the
// per-depth indent, and the row keys.
//
// Every document operation here is genuine — see frb_test_support.dart for why
// these are integration tests rather than fake-bridge unit tests.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumit_flutter/panels/project_panel_frb.dart';
import 'package:lumit_flutter/src/rust/api/footage.dart' show LumitMediaStatus;
import 'package:lumit_flutter/src/rust/api/project_item.dart' show ItemReference_Footage;
import 'package:lumit_flutter/src/rust/api/state.dart' show ScopedChange;
import 'package:lumit_flutter/state/app_state.dart' show FootageDragData;

import 'frb_test_support.dart';

void main() {
  setUpAll(initEngineForTests);

  group('Project panel (frb)', () {
    testWidgets('an empty project shows the quiet hint', (tester) async {
      final p = freshProject();
      await tester.pumpWidget(
        hostPanel(
          child: const ProjectPanelFrb(),
          state: p.state,
          uiState: p.uiState,
        ),
      );
      await tester.pump();

      expect(
        find.textContaining('No items yet'),
        findsOneWidget,
        reason: 'an empty document must say so rather than showing nothing',
      );
    });

    testWidgets('items appear as rows, each with a stable key', (tester) async {
      final p = freshProject();
      final comp = p.state.project!.newComposition(name: 'Scene');
      final footage = p.state.project!.importFootage(path: 'C:/clips/shot.mov');

      await tester.pumpWidget(hostPanel(
        child: const ProjectPanelFrb(),
        state: p.state,
        uiState: p.uiState,
      ));
      await tester.pump();

      expect(find.text('Scene'), findsOneWidget);
      expect(find.text('shot.mov'), findsOneWidget);
      // The auto-folder a new composition is filed into.
      expect(find.text('Compositions'), findsOneWidget);

      expect(
        find.byKey(ValueKey<String>('project-row-${comp.internalid}')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey<String>('project-row-${footage.internalid}')),
        findsOneWidget,
      );
    });

    /// v0 never tested nesting at all — its `walk` had no assertions. A new
    /// composition is filed into the Compositions auto-folder, so it must appear
    /// once, indented one level, not twice and not at the root.
    testWidgets('a folder nests its children, indented one level per depth',
        (tester) async {
      final p = freshProject();
      final comp = p.state.project!.newComposition(name: 'Scene');

      await tester.pumpWidget(hostPanel(
        child: const ProjectPanelFrb(),
        state: p.state,
        uiState: p.uiState,
      ));
      await tester.pump();

      expect(find.text('Scene'), findsOneWidget,
          reason: 'a filed comp is drawn once, under its folder — not twice');

      // The folder sits at depth 0, the comp inside it at depth 1.
      final folderRow = find.ancestor(
        of: find.text('Compositions'),
        matching: find.byType(Container),
      );
      final compRow = find.byKey(ValueKey<String>('project-row-${comp.internalid}'));
      final folderLeft = tester.getTopLeft(find.text('Compositions')).dx;
      final compLeft = tester.getTopLeft(find.text('Scene')).dx;
      expect(folderRow, findsWidgets);
      expect(compRow, findsOneWidget);
      expect(
        compLeft - folderLeft,
        closeTo(14, 0.01),
        reason: 'one nesting level indents by 14px',
      );
    });

    testWidgets('clicking a row selects it, and a second click renames in place',
        (tester) async {
      final p = freshProject();
      p.state.project!.importFootage(path: 'C:/clips/shot.mov');

      await tester.pumpWidget(hostPanel(
        child: const ProjectPanelFrb(),
        state: p.state,
        uiState: p.uiState,
      ));
      await tester.pump();

      // First click selects; the second (well outside the double-tap window)
      // starts the rename.
      await tapAgain(tester, find.text('shot.mov'));
      expect(find.byKey(const ValueKey('rename-field')), findsOneWidget);

      await tester.enterText(find.byType(EditableText), 'Intro');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(find.text('Intro'), findsOneWidget);
      expect(find.text('shot.mov'), findsNothing,
          reason: 'the rename reached the document, not just the field');
    });

    testWidgets('a blank rename is refused and the old name survives',
        (tester) async {
      final p = freshProject();
      p.state.project!.importFootage(path: 'C:/clips/shot.mov');

      await tester.pumpWidget(hostPanel(
        child: const ProjectPanelFrb(),
        state: p.state,
        uiState: p.uiState,
      ));
      await tester.pump();

      await tapAgain(tester, find.text('shot.mov'));
      await tester.enterText(find.byType(EditableText), '   ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(find.text('shot.mov'), findsOneWidget,
          reason: 'a row must never be able to lose its label');
    });

    testWidgets('double-clicking a composition fronts it', (tester) async {
      final p = freshProject();
      final comp = p.state.project!.newComposition(name: 'Scene');

      await tester.pumpWidget(hostPanel(
        child: const ProjectPanelFrb(),
        state: p.state,
        uiState: p.uiState,
      ));
      await tester.pump();

      expect(p.uiState.selectedComp, isNull);
      await _doubleTap(tester, find.text('Scene'));

      expect(p.uiState.selectedComp?.internalid, comp.internalid);
    });

    testWidgets('double-clicking footage places it into the front comp',
        (tester) async {
      final p = freshProject();
      final comp = p.state.project!.newComposition(name: 'Scene');
      p.state.project!.importFootage(path: 'C:/clips/shot.mov');
      p.uiState.setSelectedComp(comp);

      await tester.pumpWidget(hostPanel(
        child: const ProjectPanelFrb(),
        state: p.state,
        uiState: p.uiState,
      ));
      await tester.pump();

      expect(comp.getLayers(), isEmpty);
      await _doubleTap(tester, find.text('shot.mov'));

      final layers = comp.getLayers();
      expect(layers, hasLength(1));
      expect(layers.first.getName(), 'shot.mov');
    });

    testWidgets('footage rows are draggable, carrying FootageDragData',
        (tester) async {
      final p = freshProject();
      p.state.project!.importFootage(path: 'C:/clips/shot.mov');

      await tester.pumpWidget(hostPanel(
        child: const ProjectPanelFrb(),
        state: p.state,
        uiState: p.uiState,
      ));
      await tester.pump();

      // The Timeline's drop target consumes exactly this type and nothing else
      // produces it, so the payload type is load-bearing.
      expect(find.byType(Draggable<FootageDragData>), findsOneWidget);
    });

    testWidgets('the context menu deletes an item', (tester) async {
      final p = freshProject();
      p.state.project!.importFootage(path: 'C:/clips/shot.mov');

      await tester.pumpWidget(hostPanel(
        child: const ProjectPanelFrb(),
        state: p.state,
        uiState: p.uiState,
      ));
      await tester.pump();

      await tester.tapAt(
        tester.getCenter(find.text('shot.mov')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();

      expect(find.text('Move to root'), findsOneWidget);
      expect(find.text('Find missing footage'), findsOneWidget);

      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(find.text('shot.mov'), findsNothing);
      expect(p.state.project!.getItems(), isEmpty);
    });

    testWidgets('the context menu moves a filed item back to the root',
        (tester) async {
      final p = freshProject();
      p.state.project!.newComposition(name: 'Scene');

      await tester.pumpWidget(hostPanel(
        child: const ProjectPanelFrb(),
        state: p.state,
        uiState: p.uiState,
      ));
      await tester.pump();

      // 'Scene' starts filed inside Compositions, so it is indented.
      final indentedBefore = tester.getTopLeft(find.text('Scene')).dx;

      await tester.tapAt(
        tester.getCenter(find.text('Scene')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move to root'));
      await tester.pumpAndSettle();

      expect(
        tester.getTopLeft(find.text('Scene')).dx,
        lessThan(indentedBefore),
        reason: 'unfiled, so it is no longer indented under the folder',
      );
      expect(find.text('Scene'), findsOneWidget, reason: 'moved, not deleted');
    });

    /// Missing-media rows and the filter. The imported path does not exist, so the
    /// engine's probe genuinely fails — no fake status is injected anywhere.
    ///
    /// `settleFrb` rather than a plain `pump`: the status probe is an async frb
    /// call, and only a real event-loop turn can deliver its answer. See
    /// `frb_test_support.dart` for the full account of that seam — and note that
    /// pumping *inside* `runAsync` is not the fix, because the panel's own
    /// `.then` continuation lives in the fake-async queue.
    testWidgets('missing footage wears a badge, a Relink button, and can be '
        'filtered to', (tester) async {
      final p = freshProject();
      p.state.project!.newComposition(name: 'Scene');
      final gone = p.state.project!.importFootage(path: 'C:/nowhere/gone.mp4');

      await tester.pumpWidget(hostPanel(
        child: const ProjectPanelFrb(),
        state: p.state,
        uiState: p.uiState,
      ));
      await settleFrb(
        tester,
        until: () => find.text('missing').evaluate().isNotEmpty,
      );

      expect(find.text('missing'), findsOneWidget,
          reason: 'the engine probed the path, found nothing, and said so');
      expect(
        find.byKey(ValueKey<String>('relink-${gone.internalid}')),
        findsOneWidget,
      );

      // The header appears only while something is missing, and filters to it.
      expect(find.byKey(const ValueKey('missing-toggle')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('missing-toggle')));
      await tester.pumpAndSettle();

      expect(find.text('gone.mp4'), findsOneWidget);
      expect(find.text('Scene'), findsNothing,
          reason: 'filtered: every visible row is now something to fix');
    });

    testWidgets('relink routes the picked path to the engine', (tester) async {
      final p = freshProject();
      final gone = p.state.project!.importFootage(path: 'C:/nowhere/gone.mp4');

      // A file the engine's probe genuinely accepts, for the relink to land on.
      final target = _probeableMediaFile('relinked.wav');

      await tester.pumpWidget(hostPanel(
        child: ProjectPanelFrb(relinkPicker: () async => target),
        state: p.state,
        uiState: p.uiState,
      ));
      await settleFrb(
        tester,
        until: () => find.text('Relink…').evaluate().isNotEmpty,
      );
      expect(find.text('Relink…'), findsOneWidget,
          reason: 'the inline Relink button is what this test clicks');

      // The tap itself is ordinary fake-async work, but it does not fire on the
      // pointer-up: the *row* under the button offers `onDoubleTap`, and a
      // `DoubleTapGestureRecognizer` holds the gesture arena for
      // `kDoubleTapTimeout` so a second tap can still arrive. Until that hold is
      // released the arena is never swept, so the button's own tap recognizer
      // never wins and `onPressed` never runs. Fake time has to be advanced past
      // it — `settleFrb` deliberately elapses none, so this pump is the one that
      // presses the button.
      await tester.tap(find.text('Relink…'));
      await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
      // `_doRelink` then awaits the injected picker (a fake-zone future, already
      // resolved by that pump) and calls the synchronous `relink`, which clears
      // the panel's status cache — so the row re-probes, and that needs real
      // event-loop turns again.
      await settleFrb(tester);

      expect(find.text('missing'), findsNothing,
          reason: 'the item resolves now, so the badge is gone');
      // …and the engine, not just the widget, agrees. Started inside `runAsync`,
      // so both the call and its continuation are real async — the one shape
      // that may be awaited there without deadlocking.
      final status = await tester.runAsync(() => gone.getStatus());
      expect(status, LumitMediaStatus.ready,
          reason: 'the picked path reached the engine, not just the panel');
    });

    /// The menu offers a different set per item kind, and offering the wrong one
    /// is how a user ends up with a Relink that cannot mean anything.
    ///
    /// Migrated from the v0 suite (project_placement_test.dart), which is the
    /// only place this was asserted before.
    testWidgets('the context menu shows the item set for the row it opened on',
        (tester) async {
      final p = freshProject();
      p.state.project!.newComposition(name: 'Scene');
      p.state.project!.importFootage(path: 'C:/clips/shot.mov');

      await tester.pumpWidget(hostPanel(
        child: const ProjectPanelFrb(),
        state: p.state,
        uiState: p.uiState,
      ));
      await tester.pump();

      // A composition: settings, move, delete. Relink and Find missing are
      // footage-only (egui panels.rs).
      await tester.tapAt(tester.getCenter(find.text('Scene')),
          buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('Composition settings…'), findsOneWidget);
      expect(find.text('Move to root'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      expect(find.text('Relink…'), findsNothing);
      expect(find.text('Find missing footage'), findsNothing);
      await tester.tapAt(const Offset(400, 560));
      await tester.pumpAndSettle();

      // Present footage: no settings, and no Relink — that appears only on a
      // row that is actually broken.
      await tester.tapAt(tester.getCenter(find.text('shot.mov')),
          buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('Composition settings…'), findsNothing);
      expect(find.text('Relink…'), findsNothing);
      expect(find.text('Find missing footage'), findsOneWidget);
      expect(find.text('Move to root'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
    });

    /// Migrated from the v0 suite (final_sweep_test.dart). v0 needed an isolate,
    /// a wire protocol and a generation map to keep a cold decode off the UI
    /// thread; `FootageReference.thumbnail` is simply async, so the whole
    /// mechanism here is one `FutureBuilder`-shaped load.
    testWidgets('a footage row decodes and shows a thumbnail', (tester) async {
      final p = freshProject();
      p.state.project!.importFootage(path: _probeableImageFile('still.bmp'));

      await tester.pumpWidget(hostPanel(
        child: const ProjectPanelFrb(),
        state: p.state,
        uiState: p.uiState,
      ));
      await settleFrb(
        tester,
        until: () => find.byType(RawImage).evaluate().isNotEmpty,
      );

      expect(find.byType(RawImage), findsOneWidget,
          reason: 'the row drew the decoded picture, not the type glyph');
    });

    /// The panel used to rebuild on *every* document change, so tweaking a layer
    /// dropped the whole missing-media cache and re-probed every footage file on
    /// disk. `ScopedChange.items` is the separation; `op_scope` in api/state.rs
    /// classifies each op, and its unit tests cover the full table.
    testWidgets('a layer edit is not an item-list change; a rename is',
        (tester) async {
      final p = freshProject();
      final footage = p.state.project!.importFootage(path: 'C:/clips/shot.mov');
      final comp = p.state.project!.newComposition(name: 'Scene');
      comp.addFootageLayer(footage: footage);

      await tester.pumpWidget(hostPanel(
        child: const ProjectPanelFrb(),
        state: p.state,
        uiState: p.uiState,
      ));
      // Drain the setup's own changes first: the engine's stream only delivers
      // on real event-loop turns, so without this they arrive after we subscribe.
      await settleFrb(tester);

      final scopes = <ScopedChange>[];
      final sub = p.state.onChange.listen(scopes.add);
      addTearDown(sub.cancel);

      comp.getLayers().single.rename(name: 'Hero');
      await settleFrb(tester, until: () => scopes.isNotEmpty);

      expect(scopes.single.items, isFalse,
          reason: 'a layer rename must not make the panel re-probe every file');
      expect(scopes.single.layer, isNotNull,
          reason: 'it scopes to the layer that changed');

      // An item rename is the panel's business, and reaches it from outside.
      scopes.clear();
      final item = p.state.project!.getItems().whereType<ItemReference_Footage>().single;
      item.rename(name: 'hero.mov');
      await settleFrb(tester, until: () => scopes.isNotEmpty);

      expect(scopes.single.items, isTrue);
      expect(find.text('hero.mov'), findsOneWidget,
          reason: 'an edit made elsewhere still redraws the row');
    });
    // Without the built library there is nothing to test against; the harness
    // throws with the command to run.
  }, skip: !engineAvailable);
}

Future<void> _doubleTap(WidgetTester tester, Finder target) async {
  await tester.tap(target);
  await tester.pump(kDoubleTapMinTime);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

/// A temp file the engine's probe accepts, written **synchronously**.
///
/// Two traps are baked into this one small function.
///
/// *Synchronous `dart:io` is not a style choice.* An awaited async `dart:io` call
/// in a `testWidgets` body hangs the test outright. The I/O completes on the real
/// event loop, but its continuation was registered in the fake-async zone, and by
/// then `runTest` has done its one `flushMicrotasks` and is merely awaiting the
/// body — so nothing ever drains that queue. This is the same deadlock described
/// under `settleFrb`, and it is what made this test run for minutes instead of
/// failing: it never even reached the widget. `createTempSync`/`writeAsBytesSync`
/// sidestep it entirely.
///
/// *Existing is not the same as resolving.* `get_status` probes the file with
/// libavformat, so four arbitrary bytes read as missing just like a path that is
/// not there — the relink would appear to do nothing. This writes a genuinely
/// valid 8-bit mono PCM WAV, which libavformat opens and reports one audio stream
/// for, so the item really does resolve afterwards. A WAV rather than a video
/// because it can be built here byte by byte; a real video would need an ffmpeg
/// CLI on the machine, which a widget test must not depend on.
String _probeableMediaFile(String name) {
  final dir = Directory.systemTemp.createTempSync('lumit-relink');
  final file = File('${dir.path}/$name');
  file.writeAsBytesSync(_silentWav());
  return file.path;
}

/// 0.1 s of 8-bit mono silence, as a WAV byte for byte.
Uint8List _silentWav() {
  const sampleRate = 8000;
  final samples = Uint8List(sampleRate ~/ 10)..fillRange(0, sampleRate ~/ 10, 128);
  final out = BytesBuilder();
  void ascii(String s) => out.add(s.codeUnits);
  void u16(int v) => out.add([v & 0xff, (v >> 8) & 0xff]);
  void u32(int v) =>
      out.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);

  ascii('RIFF');
  u32(36 + samples.length); // everything after this field
  ascii('WAVE');
  ascii('fmt ');
  u32(16); // fmt chunk size
  u16(1); // PCM, uncompressed
  u16(1); // mono
  u32(sampleRate);
  u32(sampleRate); // byte rate: 1 channel × 1 byte × rate
  u16(1); // block align
  u16(8); // bits per sample
  ascii('data');
  u32(samples.length);
  out.add(samples);
  return out.takeBytes();
}

/// A file with a genuinely decodable picture in it, for the thumbnail path.
///
/// A 2×2 24-bit BMP rather than a video: it can be built here byte by byte,
/// where a real video would need an ffmpeg CLI on the machine — which a widget
/// test must not depend on. libavformat opens it as a one-frame video stream,
/// which is all `thumbnail` asks for. The WAV that [_probeableMediaFile] writes
/// will not do: it resolves, but has no picture to decode.
String _probeableImageFile(String name) {
  final dir = Directory.systemTemp.createTempSync('lumit-thumb');
  final file = File('${dir.path}/$name');
  file.writeAsBytesSync(_tinyBmp());
  return file.path;
}

/// A 2×2 24-bit BMP, bottom-up, rows padded to a 4-byte boundary.
Uint8List _tinyBmp() {
  final out = BytesBuilder();
  void ascii(String s) => out.add(s.codeUnits);
  void u16(int v) => out.add([v & 0xff, (v >> 8) & 0xff]);
  void u32(int v) =>
      out.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);

  // Two pixels per row is 6 bytes, padded to 8; two rows.
  const pixelBytes = 16;
  ascii('BM');
  u32(14 + 40 + pixelBytes); // file size
  u32(0); // reserved
  u32(14 + 40); // offset to the pixel array

  u32(40); // BITMAPINFOHEADER
  u32(2); // width
  u32(2); // height
  u16(1); // planes
  u16(24); // bits per pixel
  u32(0); // BI_RGB, uncompressed
  u32(pixelBytes);
  u32(2835); // ~72 dpi
  u32(2835);
  u32(0); // palette colours used
  u32(0); // all colours important

  // BGR triples: two rows of orange/blue, each padded to four bytes.
  for (var row = 0; row < 2; row++) {
    out.add([20, 120, 220, 220, 120, 20]);
    out.add([0, 0]); // row padding
  }
  return out.takeBytes();
}
