// The harness every frb panel test shares.
//
// **Why these are integration tests, not fake-bridge unit tests.** The v0 panels
// took a `DocumentBridge` interface, so a test could hand them a fake. The frb
// generated types are concrete classes that call straight into the native library,
// so there is nothing to substitute — and adding a Dart interface over them purely
// to allow faking would reintroduce exactly the mirror-class indirection the
// migration exists to delete.
//
// So these tests drive the real engine: `flutter test` loads the built
// `lumit_bridge` library and every document operation is the genuine one. That is
// strictly better coverage than a fake, which can only ever assert that Dart
// *called* something — a fake cannot tell you the op did what you meant, and it
// drifts silently when the engine changes. The cost is a build dependency: the
// library must exist and be in sync, or frb refuses to start (it compares a
// content hash on both sides).
//
// Run `cargo build -p lumit_bridge` first, and re-run it after any change to
// `crates/lumit-bridge/src/api/**` — a stale library fails loudly with a content
// hash mismatch rather than misbehaving quietly.

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/src/rust/frb_generated.dart';
import 'package:lumit_flutter/theme/theme.dart';
import 'package:lumit_flutter/widgets/controls.dart';
import 'package:provider/provider.dart';

/// Where `cargo build -p lumit_bridge` leaves the library, relative to
/// `flutter_ui/`. The cargokit-built copy under `build/` is not used: it only
/// exists after a full `flutter build`, which a test run should not require.
String get _libraryPath {
  final stem = Platform.isWindows
      ? 'lumit_bridge.dll'
      : Platform.isMacOS
          ? 'liblumit_bridge.dylib'
          : 'liblumit_bridge.so';
  return '../target/debug/$stem';
}

bool _initialised = false;

/// Load the engine once per test process.
///
/// Skips the whole group with a clear instruction when the library is absent,
/// rather than failing with an opaque FFI error — a contributor who has not built
/// the Rust side should be told what to run.
Future<void> initEngineForTests() async {
  if (_initialised) return;
  final library = File(_libraryPath);
  if (!library.existsSync()) {
    throw StateError(
      'The engine library is not built. Run:\n'
      '  cargo build -p lumit_bridge\n'
      'Looked for: ${library.absolute.path}',
    );
  }
  await BridgeLib.init(externalLibrary: ExternalLibrary.open(_libraryPath));
  _initialised = true;
}

/// True when the engine library is present, for `skip:` on a whole group.
bool get engineAvailable => File(_libraryPath).existsSync();

/// Mount [child] with the providers and theme scope a panel needs.
///
/// The `Overlay` is load-bearing: the project context menu and every dialog are
/// overlay entries. `showTooltips: false` keeps `LumitTooltip` out of the widget
/// tree so text finders are not confused by tooltip copy.
Widget hostPanel({
  required Widget child,
  required LumitState state,
  required LumitUiState uiState,
  Size size = const Size(480, 760),
}) =>
    Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: MediaQueryData(size: size),
        child: ChangeNotifierProvider<LumitState>.value(
          value: state,
          child: ChangeNotifierProvider<LumitUiState>.value(
            value: uiState,
            child: ThemeScope(
              theme: LumitTheme.forScheme(
                LumitColorScheme.dark,
                ThemeShape.sharp,
              ),
              animationLevel: AnimationLevel.none,
              showTooltips: false,
              child: Overlay(
                initialEntries: [OverlayEntry(builder: (_) => child)],
              ),
            ),
          ),
        ),
      ),
    );

/// A fresh engine-backed project and its UI state.
///
/// Each call makes a new project with its own id, so tests do not collide in the
/// engine's process-wide registry — but no test may call `openProject`, which
/// clears that registry wholesale.
({LumitState state, LumitUiState uiState}) freshProject() {
  final state = LumitState()..newProject();
  return (state: state, uiState: LumitUiState(state));
}

/// A second tap, far enough after the first to read as two singles rather than a
/// double-tap — the click-then-click-again rename gesture.
Future<void> tapAgain(WidgetTester tester, Finder target) async {
  await tester.tap(target);
  await tester.pump(const Duration(milliseconds: 350));
  await tester.tap(target);
  await tester.pump(const Duration(milliseconds: 350));
}
