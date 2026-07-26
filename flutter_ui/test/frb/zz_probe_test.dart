// SCRATCH probe — delete before reporting.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumit_flutter/src/rust/api/footage.dart';

import 'frb_test_support.dart';

void main() {
  setUpAll(initEngineForTests);

  test('plain test: getStatus resolves', () async {
    final p = freshProject();
    final gone = p.state.project!.importFootage(path: 'C:/nowhere/gone.mp4');
    final s = await gone.getStatus();
    debugPrint('PROBE plain -> $s');
    expect(s, LumitMediaStatus.missing);
  });

  testWidgets('probe A: bare await inside runAsync, no widgets', (tester) async {
    final p = freshProject();
    final gone = p.state.project!.importFootage(path: 'C:/nowhere/gone.mp4');
    LumitMediaStatus? got;
    await tester.runAsync(() async {
      got = await gone.getStatus();
    });
    debugPrint('PROBE A -> $got');
    expect(got, LumitMediaStatus.missing);
  });

  testWidgets('probe B: future started OUTSIDE runAsync, awaited inside',
      (tester) async {
    final p = freshProject();
    final gone = p.state.project!.importFootage(path: 'C:/nowhere/gone.mp4');
    final f = gone.getStatus();
    LumitMediaStatus? got;
    await tester.runAsync(() async {
      got = await f;
    });
    debugPrint('PROBE B -> $got');
    expect(got, LumitMediaStatus.missing);
  });

  testWidgets('probe C: .then registered outside, delay inside runAsync',
      (tester) async {
    final p = freshProject();
    final gone = p.state.project!.importFootage(path: 'C:/nowhere/gone.mp4');
    LumitMediaStatus? got;
    // ignore: unawaited_futures
    gone.getStatus().then((s) => got = s);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    debugPrint('PROBE C -> $got');
    expect(got, LumitMediaStatus.missing);
  });

  testWidgets('probe D: call+then made inside runAsync, delay inside',
      (tester) async {
    final p = freshProject();
    final gone = p.state.project!.importFootage(path: 'C:/nowhere/gone.mp4');
    LumitMediaStatus? got;
    await tester.runAsync(() async {
      // ignore: unawaited_futures
      gone.getStatus().then((s) => got = s);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    debugPrint('PROBE D -> $got');
    expect(got, LumitMediaStatus.missing);
  });
}
