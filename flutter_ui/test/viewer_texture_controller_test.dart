// The Viewer's zero-copy texture controller against a fake runner (K-177).
//
// The failure being guarded is the silent one: a runner that registers the
// texture, accepts every frameReady, and never actually draws it. The
// controller detects that by counting the draws the runner reports back — so a
// runner whose frameReady answers null (as the Linux one did before K-204's
// branch) can never be told apart from one that is drawing, and the fallback
// never fires. These tests pin both halves: null answers must give up after the
// grace window, and a rising count must keep the path alive.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumit_flutter/panels/viewer_texture_controller.dart';

/// A stand-in runner. `register` hands back an id; `frameReady` answers with
/// whatever [drawn] returns for that call (null means "the runner told us
/// nothing", which is the bug).
MethodChannel fakeRunner(Object? Function(int call) drawn) {
  var calls = 0;
  final channel = const MethodChannel(ViewerTextureController.channelName);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    switch (call.method) {
      case 'register':
        return 7;
      case 'frameReady':
        calls++;
        return drawn(calls);
      default:
        return null;
    }
  });
  return channel;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a runner that never reports a draw drops the texture path', () async {
    final controller =
        ViewerTextureController(channel: fakeRunner((_) => null));
    expect(await controller.ensureRegistered(0, 640, 360, fd: 3), 7);
    expect(controller.available, isTrue);

    for (var i = 0; i < 12; i++) {
      await controller.frameReady();
    }

    expect(controller.debugAnnounced, 12);
    expect(controller.debugDrawn, 0);
    expect(controller.neverDrawn, isTrue);
    expect(controller.available, isFalse,
        reason: 'twelve announced frames and no draw means the runner is not '
            'showing the texture; the Viewer must stop waiting on it');
  });

  test('a runner that counts its draws keeps the texture path', () async {
    final controller =
        ViewerTextureController(channel: fakeRunner((call) => call));
    expect(await controller.ensureRegistered(0, 640, 360, fd: 3), 7);

    for (var i = 0; i < 12; i++) {
      await controller.frameReady();
    }

    expect(controller.debugDrawn, 12);
    expect(controller.neverDrawn, isFalse);
    expect(controller.available, isTrue);
  });

  test('a missing handler latches the path off at once', () async {
    final controller = ViewerTextureController(
        channel: const MethodChannel('lumit/viewer_texture_absent'));
    expect(await controller.ensureRegistered(0, 640, 360, fd: 3), isNull);
    expect(controller.available, isFalse);
  });
}
