// Lumit's Flutter frontend (K-174, the frontend alternative experiment).
// The engine stays in the Rust crates; this application is the chrome —
// see docs/archive/flutter-port/ for the plan and the parity checklist.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:lumit_flutter/panels/panels_frb.dart';
import 'package:lumit_flutter/panels/viewer_texture_controller.dart';
import 'package:lumit_flutter/shell/dock_widget.dart';
import 'package:lumit_flutter/shell/menu_bar_frb.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';
import 'package:lumit_flutter/src/rust/api/project.dart';
import 'package:lumit_flutter/src/rust/api/state.dart';
import 'package:lumit_flutter/src/rust/frb_generated.dart';
import 'package:lumit_flutter/state/dock.dart';
import 'package:lumit_flutter/theme/theme.dart';
import 'package:lumit_flutter/widgets/controls.dart';
import 'package:provider/provider.dart';

import 'bridge/bridge.dart';
import 'popout/popout_main.dart';
import 'shell/shell.dart';
import 'state/workspace.dart';
import 'widgets/ui_scale.dart';

/// Traces every call that crosses into Rust, so the frb seam can be watched
/// while it is being built out. `debugPrint` rather than `print`: it compiles
/// away in release, where a log per bridge call would be far too costly.
class CustomHandler extends BaseHandler {
  @override
  Future<S> executeNormal<S, E extends Object>(NormalTask<S, E> task) {
    debugPrint('Rust async call: ${task.argMap}');
    return super.executeNormal(task);
  }

  @override
  S executeSync<S, E extends Object, WireSyncType>(
      SyncTask<S, E, WireSyncType> task) {
    debugPrint('Rust sync call: ${task.argMap}');
    return super.executeSync(task);
  }
}

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // Two shells live here while the bridge is migrated (docs/TODO.md, "Bridge").
  //
  // The default is the flutter_rust_bridge shell — the direction of travel, but
  // still a small test harness: a handful of panels, and no Viewer at all off
  // Linux until the Windows render path is wired.
  //
  // `--v0-shell` boots the full frontend instead: every panel, on the v0 JSON
  // bridge, which is still compiled into the same `lumit_bridge` library. It is
  // the parity reference to judge the frb shell against, and the only way to see
  // the whole interface on Windows today. Remove this switch once the frb shell
  // has overtaken it.
  if (args.contains('--v0-shell')) {
    // A popped-out panel runs through this same entrypoint in its own engine
    // (multi-window, same process). If this engine is a popout, it takes over
    // here; otherwise — the main window, or any build without the multi-window
    // plugin — this is a swallowed no-op and the normal shell boots below.
    if (await maybeRunPopout(args)) return;
    final workspace = Workspace()..load();
    // Try the engine bridge; a null result keeps the F0 placeholder behaviour
    // (the app and every test must work without the library present).
    final bridge = LumitBridge.tryLoad();
    runApp(LumitApp(workspace: workspace, bridge: bridge));
    return;
  }

  await BridgeLib.init(handler: CustomHandler());

  var state = LumitState();
  var ui = LumitUiState(state);
  runApp(LumitAppNew(state, ui));
}

class LumitState extends ChangeNotifier {
  ProjectReference? project;

  StreamSubscription? currentDocumentStream;

  /// The render worker's reply stream. Cancelled when another project is
  /// adopted, so a stale worker cannot feed frames to the new project's Viewer.
  StreamSubscription? workerStream;

  final StreamController<ScopedChange> _onChange = StreamController.broadcast();

  final StreamController<WorkerResponse> _onWorkerResponse =
      StreamController.broadcast();

  Stream<ScopedChange> get onChange => _onChange.stream;
  
  Stream<WorkerResponse> get onWorkerResponse => _onWorkerResponse.stream;

  void newProject() {
    _adopt(LumitBridgeState.newProject(onChangeStream: _changeSink()));
  }

  void openProject(String path) {
    // Null means the file would not open; the previous project stays loaded
    // rather than the app being left with none.
    final opened =
        LumitBridgeState.openProject(path: path, onChangeStream: _changeSink());
    if (opened == null) {
      debugPrint('Could not open $path');
      return;
    }
    _adopt(opened);
  }

  /// The sink Rust pushes scoped document changes down. Held for the call so
  /// [_adopt] can attach to the same one.
  RustStreamSink<ScopedChange>? _pendingSink;

  RustStreamSink<ScopedChange> _changeSink() =>
      _pendingSink = RustStreamSink<ScopedChange>();

  /// Take over a freshly created or opened project: start its render worker and
  /// subscribe to both of its streams.
  ///
  /// Both subscriptions matter and `newProject` used to make neither properly —
  /// it started the worker but dropped the returned stream, so no rendered frame
  /// ever reached the Viewer for a new project.
  void _adopt(ProjectReference opened) {
    project = opened;

    workerStream?.cancel();
    workerStream =
        opened.startWorker().listen((msg) => _onWorkerResponse.add(msg));

    final sink = _pendingSink;
    if (sink != null) {
      currentDocumentStream?.cancel();
      currentDocumentStream = sink.stream.listen(handleChange);
      _pendingSink = null;
    }

    notifyListeners();
  }

  void handleChange(ScopedChange event) {
    _onChange.add(event);

    // Rebuilds should be handled by LayerBuilder, no need to notify
    if (event.layer != null) return;

    if (event.item != null) return;

    // else, not able to identify scope of this change, rebuild everything!
    debugPrint('Rebuilding everything!');
    notifyListeners();
  }
}

class LumitUiState extends ChangeNotifier {
  DockSplit split = defaultLayout();
  ValueNotifier<Panel?> activePanel = ValueNotifier(null);
  LumitTheme theme = LumitTheme.dark();

  CompositionReference? _selectedComp;
  CompositionReference? get selectedComp => _selectedComp;

  ViewerTextureController controller = ViewerTextureController();
  ValueNotifier<int?> viewerFrameid = ValueNotifier(null);
  
  ValueNotifier<LayerReference?> selectedLayer = ValueNotifier(null);

  StreamSubscription? sub;

  LumitUiState(LumitState state) {
    sub = state.onWorkerResponse.listen((msg) {
      debugPrint('Received worker response: \$msg');
      if (msg case WorkerResponse_RenderedDMABuf frame) {
        controller
            .ensureRegistered(
                frame.field0.fd, frame.field0.width, frame.field0.height,
                fd: frame.field0.fd,
                stride: frame.field0.stride,
                offset: frame.field0.offset,
                fourcc: frame.field0.drmFourcc,
                modifier: frame.field0.modifier.toInt())
            .then((id) {
          controller.frameReady();

          if (viewerFrameid.value != id) {
            viewerFrameid.value = id;
          }
        });
      }
    });
  }

  void setSelectedComp(CompositionReference? reference) {
    _selectedComp = reference;
    notifyListeners();
  }
}

class LumitAppNew extends StatelessWidget {
  final LumitState state;
  final LumitUiState uiState;

  const LumitAppNew(this.state, this.uiState, {super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
        theme: ThemeData.dark(),
        home: ChangeNotifierProvider.value(
          value: state,
          child: ChangeNotifierProvider.value(
              value: uiState,
              child: ThemeScope(
                theme: LumitTheme.dark(),
                animationLevel: AnimationLevel.all,
                showTooltips: true,
                child: Overlay(initialEntries: [
                  OverlayEntry(builder: (context) => const LumitAppView())
                ]),
              )),
        ));
  }
}

class LumitAppView extends StatefulWidget {
  const LumitAppView({super.key});

  @override
  State<LumitAppView> createState() => _LumitAppViewState();
}

class _LumitAppViewState extends State<LumitAppView> {
  @override
  Widget build(BuildContext context) {
    var state = context.watch<LumitState>();

    var uiState = context.watch<LumitUiState>();

    return Column(
      children: [
        LumitMenuBarFrb(
          app: state,
        ),
        Expanded(
          child: DockWidget(
            root: uiState.split,
            buildPanel: (context, panel) => buildPanelBodyFrb(context, panel),
            onLayoutChanged: () {},
            activePanel: uiState.activePanel,
            onPopOut: (p0) {},
            canPopOut: (panel) => false,
          ),
        )
      ],
    );
  }

}

class LumitApp extends StatelessWidget {
  final Workspace workspace;
  final LumitBridge? bridge;
  const LumitApp({super.key, required this.workspace, this.bridge});

  @override
  Widget build(BuildContext context) {
    // WidgetsApp-level infrastructure only — no Material chrome
    // (docs/archive/flutter-port/04 "Why not Material chrome"). Settings → Interface →
    // UI scale is applied here via [UiScaleView], the Flutter counterpart of
    // egui's `ctx.set_pixels_per_point` — layout and hit-testing scale together
    // (see widgets/ui_scale.dart for why this mechanism, not a devicePixelRatio
    // override). The slider commits on release; this just reflects the value.
    return MaterialApp(
      home: ListenableBuilder(
        listenable: workspace,
        builder: (context, _) => Directionality(
          textDirection: TextDirection.ltr,
          child: ColoredBox(
            color: workspace.theme.surface0,
            child: UiScaleView(
              scale: workspace.interface.uiScale,
              child: LumitShell(workspace: workspace, bridge: bridge),
            ),
          ),
        ),
      ),
    );
  }
}
