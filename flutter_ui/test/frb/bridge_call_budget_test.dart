// How many bridge calls one interaction costs — the regression trap for FFI
// chatter.
//
// Every generated call crosses the seam through the handler, so counting there
// sees everything: property reads, schema fetches, renders. The budgets pin the
// *shape* of the panels' behaviour — a rebuild that re-reads the world shows up
// here as a number jumping, long before it shows up on a profiler as a slow
// click. Found the hard way: selecting a layer was traced at >200 calls,
// because both panels rebuilt wholesale and every widget re-asked the engine
// for everything it had already been told.
//
// The budgets are deliberately loose (roughly 2x the measured cost at the time
// of writing) so honest growth — a new column, another switch — does not trip
// them, while another rebuild-the-world regression does.

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumit_flutter/panels/effect_controls_panel_frb.dart';
import 'package:lumit_flutter/panels/timeline_panel_frb.dart';
import 'package:lumit_flutter/src/rust/frb_generated.dart';

import 'frb_test_support.dart';

/// Counts every call that crosses the bridge, by name.
class CountingHandler extends BaseHandler {
  final Map<String, int> calls = {};
  bool counting = false;

  void _tick(String name) {
    if (counting) calls[name] = (calls[name] ?? 0) + 1;
  }

  int get total => calls.values.fold(0, (a, b) => a + b);

  void reset() => calls.clear();

  /// The counts as a readable ranking, for the failure message.
  String ranking() {
    final entries = calls.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries.map((e) => '${e.value}x ${e.key}').join('\n');
  }

  @override
  Future<S> executeNormal<S, E extends Object>(NormalTask<S, E> task) {
    _tick(task.constMeta.debugName);
    return super.executeNormal(task);
  }

  @override
  S executeSync<S, E extends Object, WireSyncType>(
      SyncTask<S, E, WireSyncType> task) {
    _tick(task.constMeta.debugName);
    return super.executeSync(task);
  }
}

void main() {
  final counter = CountingHandler();

  setUpAll(() async {
    final stem = Platform.isWindows
        ? 'lumit_bridge.dll'
        : Platform.isMacOS
            ? 'liblumit_bridge.dylib'
            : 'liblumit_bridge.so';
    await BridgeLib.init(
      externalLibrary: ExternalLibrary.open('../target/debug/$stem'),
      handler: counter,
    );
  });

  group('Bridge call budget', () {
    testWidgets('selecting a layer costs a bounded number of bridge calls',
        (tester) async {
      final p = freshProject();
      final comp = p.state.project!.newComposition(name: 'Scene');
      // Two layers with an effect each — a small but honest document.
      comp.addSolidLayer().addEffect(name: 'blur');
      comp.addTextLayer().addEffect(name: 'sharpen');
      p.uiState.setSelectedComp(comp);
      final target = comp.getLayers().first;

      // The other layer starts selected, so the click below changes the
      // selection rather than setting it for the first time — the everyday
      // gesture, and the one that was traced at >200 calls.
      p.uiState.selectedLayer.value = comp.getLayers().last;

      counter
        ..reset()
        ..counting = true;
      await tester.pumpWidget(hostPanel(
        state: p.state,
        uiState: p.uiState,
        size: const Size(800, 600),
        child: Row(children: const [
          SizedBox(width: 500, height: 600, child: TimelinePanelFrb()),
          Expanded(child: EffectControlsPanelFrb()),
        ]),
      ));
      await tester.pump();
      await settleFrb(tester, minRounds: 8);
      counter.counting = false;
      // ignore: avoid_print
      print('MOUNT COST ${counter.total} calls\n${counter.ranking()}');

      // Twirl the target layer open — Transform and its effect too — which is
      // how a layer is actually being worked on when it gets clicked.
      final id = target.internallayerId.toString();
      await tester.tap(find.byKey(ValueKey<String>('tl-twirl-$id')));
      await tester.pump();
      await tester.tap(find.byKey(ValueKey<String>('tl-group-$id/transform')));
      await tester.pump();
      await settleFrb(tester, minRounds: 4, maxRounds: 8);

      counter
        ..reset()
        ..counting = true;
      // On the name, not the row's centre: the centre of a full outline row
      // lands on the blend dropdown, which eats the tap.
      final row =
          find.byKey(ValueKey<String>('tl-row-${target.internallayerId}'));
      await tester.tapAt(tester.getTopLeft(row) + const Offset(150, 10));
      await tester.pump(const Duration(milliseconds: 350));
      await settleFrb(tester, minRounds: 4, maxRounds: 8);
      counter.counting = false;

      expect(p.uiState.selectedLayer.value?.equals(layer: target), isTrue,
          reason: 'the click actually changed the selection');
      // ignore: avoid_print
      print('CLICK COST ${counter.total} calls\n${counter.ranking()}');
      // Measured at 31 after the grouped get_info reads landed (K-183);
      // the cap stays roughly 2x measured so honest growth does not trip it.
      expect(
        counter.total,
        lessThan(64),
        reason: 'one click re-read far too much across the bridge:\n'
            '${counter.ranking()}',
      );
    });
  }, skip: !engineAvailable);
}
