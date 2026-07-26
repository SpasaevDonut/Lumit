// Lumit's Flutter frontend (K-174, the frontend alternative experiment).
// The engine stays in the Rust crates; this application is the chrome —
// see docs/archive/flutter-port/ for the plan and the parity checklist.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:lumit_flutter/state/workspace.dart';
import 'package:lumit_flutter/theme/theme.dart';
import 'package:lumit_flutter/widgets/controls.dart';
import 'package:lumit_flutter/widgets/ui_scale.dart';
import 'package:provider/provider.dart';

import 'popout/popout_main.dart';

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

  // A popped-out panel runs through this same entrypoint in its own engine
  // (multi-window, same process). If this engine is a popout it takes over here;
  // otherwise — the main window, or any build without the multi-window plugin —
  // this is a swallowed no-op and the shell boots below.
  if (await maybeRunPopout(args)) return;

  await BridgeLib.init(handler: CustomHandler());

  final state = LumitState();
  // Start with an empty project rather than nothing at all. Every document
  // command — import, new composition, save — is disabled while there is no
  // project, so booting without one left the whole File and Composition menu
  // dead and no way to make it live: the first thing a user does needs
  // something to do it *to*.
  state.newProject();
  runApp(LumitAppNew(state, LumitUiState(state)));
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

  /// Take over the project this process already has open, without making one.
  ///
  /// What a popout window does. `desktop_multi_window` runs each window in the
  /// same process, so the engine's project registry is the *same* registry —
  /// the popout points at the document the main window is editing rather than
  /// loading its own copy, which is what made v0's popouts drift out of step.
  ///
  /// No render worker is started: a second worker rendering the same comp would
  /// compete with the main window's for the GPU, and every poppable panel is
  /// read-mostly. Returns false when nothing is open.
  bool adoptCurrentProject() {
    final current = LumitBridgeState.getCurrentProject();
    if (current == null) return false;
    project = current;
    notifyListeners();
    return true;
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

  /// Tell the app an edit landed, for callers that made one themselves rather
  /// than learning about it from the engine's change stream.
  ///
  /// The stream is the right mechanism for edits made *elsewhere*, but a caller
  /// that just performed an op should not wait for a Rust→Dart round trip to see
  /// its own result — see the same reasoning in project_panel_frb.dart.
  void notifyDocumentChanged() => notifyListeners();

  /// Import footage into the open project, and say whether anything landed.
  ///
  /// Here rather than in the menu bar because the Project panel offers the same
  /// command, and two copies of "import each path, then notify" is one copy too
  /// many for something every new user's first action goes through.
  Future<bool> importFootagePaths(List<String> paths) async {
    final project = this.project;
    if (project == null || paths.isEmpty) return false;
    for (final path in paths) {
      project.importFootage(path: path);
    }
    notifyDocumentChanged();
    return true;
  }

  /// Make a composition. A blank name lets the engine pick the next "Comp N".
  CompositionReference? newComposition() {
    final project = this.project;
    if (project == null) return null;
    final comp = project.newComposition(name: '');
    notifyDocumentChanged();
    return comp;
  }

  void handleChange(ScopedChange event) {
    _onChange.add(event);

    // A change that names a subtree is that subtree's business: LayerBuilder and
    // ProjectItemBuilder subscribe to the stream themselves.
    if (event.layer != null || event.item != null) return;

    // Nothing narrower to aim at — whoever listens to LumitState rebuilds.
    notifyListeners();
  }
}

class LumitUiState extends ChangeNotifier {
  /// Everything that outlives the session: the panel layout, the appearance,
  /// UI scale, tooltips, autosave and export defaults.
  ///
  /// This is the same [Workspace] the shell has always used, loaded from disk
  /// on construction — the port briefly kept its own copies of the layout and
  /// the colour scheme here instead, which is why arrangements stopped
  /// surviving a restart and the Settings window's scale slider moved nothing.
  final Workspace workspace;

  DockSplit get split => workspace.dock;
  ValueNotifier<Panel?> activePanel = ValueNotifier(null);

  /// The appearance the shell is drawing in.
  ///
  /// Scheme and shape are held rather than the built theme, because the theme is
  /// derived from them — keeping the composed object as the source of truth
  /// would make "what did the user choose?" a question you answer by comparing
  /// colours.
  LumitColorScheme get scheme => workspace.colorScheme;
  ThemeShape get shape => workspace.themeShape;
  LumitTheme get theme => workspace.theme;

  /// Bumped when something outside the Viewer asks the transport to start or
  /// stop — the space bar, or a command.
  ///
  /// A notifier rather than a direct call because the ticker that runs playback
  /// belongs to the Viewer's own state: the shell should not have to reach into
  /// a panel, and the Viewer should not have to be mounted for the key to be
  /// harmless.
  final ValueNotifier<int> togglePlayRequest = ValueNotifier(0);

  void requestTogglePlay() => togglePlayRequest.value++;

  /// Bumped each time a rendered frame reaches the Viewer, on any of the three
  /// transports.
  ///
  /// The Viewer waits on this to keep exactly one render in flight: without it
  /// there is nothing to tell Dart that a request it made has been answered,
  /// and the only option is to fire and hope.
  final ValueNotifier<int> frameArrived = ValueNotifier(0);

  /// Move the playhead by `delta` frames, clamped to the fronted composition.
  void stepFrame(int delta) {
    final comp = selectedComp;
    if (comp == null) return;
    final last = comp.getSettings().durationFrames.toInt() - 1;
    playheadFrame.value =
        (playheadFrame.value + delta).clamp(0, last < 0 ? 0 : last);
  }

  /// Put the panels back where they started (Window → Reset workspace).
  void resetLayout() => workspace.resetWorkspaceLayout();

  /// Remember a layout the user changed by dragging a panel.
  void saveLayout() => workspace.save();

  void setScheme(LumitColorScheme next) => workspace.setScheme(next);

  void setShape(ThemeShape next) => workspace.setShape(next);

  CompositionReference? _selectedComp;
  CompositionReference? get selectedComp => _selectedComp;

  ViewerTextureController controller = ViewerTextureController();

  /// The platform texture the Viewer draws, on either zero-copy path. Null when
  /// this build renders through the read-back path instead.
  ValueNotifier<int?> viewerFrameid = ValueNotifier(null);

  /// The decoded frame the Viewer draws on the read-back path — the portable
  /// fallback for a build without one of the zero-copy features, which is the
  /// default on Windows. Mutually exclusive with [viewerFrameid]: whichever the
  /// worker last published wins, and the other is cleared, so the Viewer never
  /// has to guess which is current.
  ValueNotifier<ui.Image?> viewerImage = ValueNotifier(null);

  ValueNotifier<LayerReference?> selectedLayer = ValueNotifier(null);

  /// The frame every panel renders and previews at.
  ///
  /// Held here rather than inside the Timeline because it is not the Timeline's
  /// alone: the Effect controls panel previews a drag at the playhead, and its
  /// preview landing on a different frame from the one on screen would show the
  /// wrong picture. A notifier so a scrub redraws only what watches it.
  ValueNotifier<int> playheadFrame = ValueNotifier(0);

  /// What fraction of comp resolution the Viewer is actually showing, which is
  /// the `scale` every render request carries. 1.0 until the Viewer has been laid
  /// out and can measure itself.
  ///
  /// This is why a Viewer in a small panel is cheap: the engine decodes and
  /// composites at the size being displayed rather than always at comp
  /// resolution. It is the frb counterpart of v0's `effectivePreviewScale`, minus
  /// the adaptive quality tier (K-171), which is not ported yet — so this tracks
  /// the panel size only, not measured render cost.
  double viewerScale = 1.0;

  /// Called by the Viewer as it lays out. Clamped to (0, 1]: rendering *above*
  /// comp resolution would cost more for no visible gain, and a zero or negative
  /// scale is meaningless.
  void reportViewerScale(double scale) {
    if (!scale.isFinite || scale <= 0) return;
    viewerScale = scale > 1.0 ? 1.0 : scale;
  }

  StreamSubscription? sub;

  LumitUiState(LumitState state, {Workspace? workspace})
      : workspace = workspace ?? (Workspace()..load()) {
    // Appearance and layout live in the workspace, so a change there is a
    // change here as far as any listening widget is concerned.
    this.workspace.addListener(notifyListeners);
    sub = state.onWorkerResponse.listen((msg) {
      switch (msg) {
        case WorkerResponse_RenderedDMABuf frame:
          _showDmabuf(frame.field0);
        case WorkerResponse_RenderedSharedTexture frame:
          _showSharedTexture(frame.field0);
        case WorkerResponse_RenderedPixels frame:
          _showPixels(frame.field0);
        // Scope traces ride the same stream; the Scopes panel subscribes to it
        // directly, so there is nothing for the Viewer to do with one.
        case WorkerResponse_Scope():
          break;
      }
    });
  }

  /// Linux zero-copy: register the DMA-BUF and show its texture. The first
  /// positional argument is the controller's identity key, and on this path the
  /// fd serves as that key — a non-null `fd` is also what tells the controller to
  /// send the DMA-BUF argument set rather than the DXGI one.
  void _showDmabuf(BridgeSharedFrameInfoLinux f) {
    controller
        .ensureRegistered(f.fd, f.width, f.height,
            fd: f.fd,
            stride: f.stride,
            offset: f.offset,
            fourcc: f.drmFourcc,
            modifier: f.modifier.toInt())
        .then(_adoptTexture);
  }

  /// Windows zero-copy: register the shared D3D12 texture by its NT handle.
  /// Leaving `fd` null is what selects the DXGI argument set.
  void _showSharedTexture(BridgeSharedFrameInfo f) {
    controller
        .ensureRegistered(f.handle.toInt(), f.width, f.height)
        .then(_adoptTexture);
  }

  /// A registered texture is now current: mark a frame available and, if the id
  /// changed, point the Viewer at it. Also drops any held read-back image, since
  /// the two paths are mutually exclusive.
  void _adoptTexture(int? id) {
    frameArrived.value++;
    if (id == null) return;
    controller.frameReady();
    _disposeImage();
    if (viewerFrameid.value != id) viewerFrameid.value = id;
  }

  /// The portable path: decode the pixels into a `ui.Image` for the Viewer to
  /// draw. The previous image is disposed once the new one is in place —
  /// a `ui.Image` holds native memory and is not collected for us.
  void _showPixels(BridgeRenderedFrame f) {
    if (f.width == 0 || f.height == 0) return;
    ui.decodeImageFromPixels(
      f.rgba,
      f.width,
      f.height,
      ui.PixelFormat.rgba8888,
      (image) {
        final previous = viewerImage.value;
        viewerImage.value = image;
        // Whichever path published last wins.
        viewerFrameid.value = null;
        frameArrived.value++;
        // Disposed a frame later, not now. `RawImage` does not take ownership:
        // the tree still holds the previous image until the rebuild this
        // assignment schedules has been painted. Disposing it here left a
        // `RawImage` drawing a disposed image, which throws inside paint — and
        // once paint throws the Viewer stops updating at all. Harmless while
        // scrubbing by hand, constant during playback, which is why playback
        // showed one frame and then froze.
        if (previous != null) {
          WidgetsBinding.instance
              .addPostFrameCallback((_) => previous.dispose());
        }
      },
    );
  }

  void _disposeImage() {
    final held = viewerImage.value;
    if (held == null) return;
    viewerImage.value = null;
    held.dispose();
  }

  @override
  void dispose() {
    sub?.cancel();
    _disposeImage();
    viewerImage.dispose();
    viewerFrameid.dispose();
    selectedLayer.dispose();
    activePanel.dispose();
    super.dispose();
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
    // WidgetsApp-level infrastructure only — no Material chrome
    // (docs/archive/flutter-port/04 "Why not Material chrome"). `ThemeData.dark()`
    // was doing real damage here: Material's own greys showed through wherever a
    // panel did not paint, so the shell read as a Material app with Lumit panels
    // in it rather than as Lumit. The backdrop is `surface0` from the theme.
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: ChangeNotifierProvider.value(
        value: state,
        child: ChangeNotifierProvider.value(
          value: uiState,
          // Rebuilt when the workspace changes, so the scale slider and the
          // scheme picker take effect as they are moved.
          child: ListenableBuilder(
            listenable: uiState,
            builder: (context, _) => ThemeScope(
              theme: uiState.theme,
              animationLevel: uiState.workspace.animationLevel,
              showTooltips: uiState.workspace.interface.showTooltips,
              child: Directionality(
                textDirection: TextDirection.ltr,
                child: ColoredBox(
                  color: uiState.theme.surface0,
                  // Settings → Interface → UI scale, the Flutter counterpart of
                  // egui's `set_pixels_per_point`: layout and hit-testing scale
                  // together (see widgets/ui_scale.dart).
                  child: UiScaleView(
                    scale: uiState.workspace.interface.uiScale,
                    child: Overlay(initialEntries: [
                      OverlayEntry(builder: (context) => const LumitAppView())
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
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

    // A scope, not a bare Focus: when a text field gives focus up, focus falls
    // back to the enclosing *scope*. With a bare Focus here it fell back to
    // nothing at all, and every shortcut stopped working after the first rename
    // until something was clicked.
    return FocusScope(
      autofocus: true,
      onKeyEvent: (node, event) => _onKey(state, uiState, event),
      child: Column(
        children: [
          LumitMenuBarFrb(app: state),
          Expanded(
            child: DockWidget(
              root: uiState.split,
              buildPanel: (context, panel) => buildPanelBodyFrb(context, panel),
              // Persisted, so an arrangement survives a restart.
              onLayoutChanged: uiState.saveLayout,
              activePanel: uiState.activePanel,
              onPopOut: (p0) {},
              canPopOut: (panel) => false,
            ),
          )
        ],
      ),
    );
  }

  /// The keyboard shortcuts, restored from the shell the port replaced.
  ///
  /// Only the ones whose engine calls exist on this bridge; the rest are on the
  /// menus. A field with focus is left alone, or every letter typed into a
  /// layer name would also be a command.
  KeyEventResult _onKey(LumitState state, LumitUiState ui, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    // A field with focus keeps its keys, or typing a layer name would also run
    // commands. The focused context's own widget is the `Focus` that
    // `EditableText` builds, not the `EditableText` — so the check has to look
    // up the tree, which is what the previous shell's version missed.
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused != null &&
        (focused.widget is EditableText ||
            focused.findAncestorWidgetOfExactType<EditableText>() != null)) {
      return KeyEventResult.ignored;
    }

    final keyboard = HardwareKeyboard.instance;
    final ctrl = keyboard.isControlPressed || keyboard.isMetaPressed;
    final shift = keyboard.isShiftPressed;
    final key = event.logicalKey;
    final project = state.project;
    final comp = ui.selectedComp;

    var handled = true;
    if (ctrl && shift && key == LogicalKeyboardKey.keyZ) {
      project?.redo();
      state.notifyDocumentChanged();
    } else if (ctrl && key == LogicalKeyboardKey.keyZ) {
      project?.undo();
      state.notifyDocumentChanged();
    } else if (key == LogicalKeyboardKey.space) {
      ui.requestTogglePlay();
    } else if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.keyJ) {
      ui.stepFrame(-1);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      ui.stepFrame(1);
    } else if (key == LogicalKeyboardKey.home) {
      ui.playheadFrame.value = 0;
    } else if (key == LogicalKeyboardKey.end) {
      final last = (comp?.getSettings().durationFrames.toInt() ?? 1) - 1;
      ui.playheadFrame.value = last < 0 ? 0 : last;
    } else if (ctrl && key == LogicalKeyboardKey.keyD) {
      final layer = ui.selectedLayer.value;
      if (layer == null) {
        handled = false;
      } else {
        layer.duplicate();
        state.notifyDocumentChanged();
      }
    } else if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace) {
      final layer = ui.selectedLayer.value;
      if (layer == null) {
        handled = false;
      } else {
        layer.delete();
        ui.selectedLayer.value = null;
        state.notifyDocumentChanged();
      }
    } else {
      handled = false;
    }
    return handled ? KeyEventResult.handled : KeyEventResult.ignored;
  }
}
