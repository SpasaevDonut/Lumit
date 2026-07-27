// Lumit's Flutter frontend (K-174, the frontend alternative experiment).
// The engine stays in the Rust crates; this application is the chrome —
// see docs/archive/flutter-port/ for the plan and the parity checklist.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:lumit_flutter/panels/panels_frb.dart';
import 'package:lumit_flutter/panels/viewer_texture_controller.dart';
import 'package:lumit_flutter/shell/comp_settings_frb.dart';
import 'package:lumit_flutter/shell/dock_widget.dart';
import 'package:lumit_flutter/shell/menu_bar_frb.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:lumit_flutter/src/rust/api/footage.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';
import 'package:lumit_flutter/src/rust/api/project.dart';
import 'package:lumit_flutter/src/rust/api/project_item.dart';
import 'package:lumit_flutter/src/rust/api/state.dart';
import 'package:lumit_flutter/src/rust/frb_generated.dart';
import 'package:lumit_flutter/state/comp_model.dart';
import 'package:lumit_flutter/state/dock.dart';
import 'package:lumit_flutter/state/settings.dart';
import 'package:lumit_flutter/state/workspace.dart';
import 'package:lumit_flutter/theme/theme.dart';
import 'package:lumit_flutter/widgets/controls.dart';
import 'package:lumit_flutter/widgets/ui_scale.dart';
import 'package:provider/provider.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  await BridgeLib.init();

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

  /// Make a composition, asking for its settings first.
  ///
  /// Every route to a new comp — the menu bar, the command palette, the Project
  /// panel's button, and footage dropped on that button — comes through here, so
  /// there is one answer to what "New composition" does. `footage` is what was
  /// dropped: the dialog opens on the media's own size, rate and length, and each
  /// item lands in the finished comp as a layer.
  ///
  /// Null when the project is closed or the dialog was cancelled.
  Future<CompositionReference?> newComposition(
    BuildContext context, {
    List<FootageReference> footage = const [],
  }) async {
    final project = this.project;
    if (project == null) return null;
    final comp = await showNewCompositionFrb(
      context: context,
      project: project,
      footage: footage,
    );
    if (comp == null) return null;
    notifyDocumentChanged();
    return comp;
  }

  void handleChange(ScopedChange event) {
    // The item tree changed shape: the cached comp list is stale.
    if (event.items || event.item != null) _compsCache = null;

    _onChange.add(event);

    // A change that names a subtree is that subtree's business: the comp read
    // model and ProjectItemBuilder subscribe to the stream themselves.
    if (event.layer != null || event.item != null) return;

    _compsCache = null;
    // Nothing narrower to aim at — whoever listens to LumitState rebuilds.
    notifyListeners();
  }

  /// Every composition in the project with its name, folders walked — cached
  /// so the comp tabs cost no bridge calls per rebuild (K-184). Invalidated
  /// whenever the item tree changes.
  List<(CompositionReference, String)>? _compsCache;
  List<(CompositionReference, String)> comps() {
    if (_compsCache != null) return _compsCache!;
    final out = <(CompositionReference, String)>[];
    void walk(List<ItemReference> items) {
      for (final item in items) {
        switch (item) {
          case ItemReference_Composition(:final field0):
            out.add((field0, field0.getSettings().name));
          case ItemReference_Folder(:final field0):
            walk(field0.getChildren());
          case _:
            break;
        }
      }
    }

    walk(project?.getItems() ?? const []);
    return _compsCache = out;
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
  /// transports. Watched by anything that redraws when the picture does — the
  /// Timeline's cache bar, the Scopes panel.
  final ValueNotifier<int> frameArrived = ValueNotifier(0);

  /// Whether the engine is playing.
  ///
  /// Mirrored, not decided: it goes true when [play] is called and false when
  /// the engine says playback ended or the user stops it. The transport reads it
  /// to know which button to draw.
  final ValueNotifier<bool> playing = ValueNotifier(false);

  /// Start playing the fronted composition from the playhead.
  ///
  /// Everything about *how* playback runs — which frame is next, whether the
  /// clock has moved on, when to give up a tier — belongs to the engine
  /// (K-181). This says go, and [_arrived] follows the frames back.
  void play() {
    final comp = selectedComp;
    if (comp == null) return;
    comp.play(
      from: BigInt.from(playheadFrame.value),
      scale: viewerScale,
      mode: workspace.performance.playback == PlaybackMode.adaptive
          ? BridgePlaybackMode.adaptive
          : BridgePlaybackMode.everyFrame,
    );
    playing.value = true;
  }

  void stopPlayback() {
    playing.value = false;
    selectedComp?.stopPlayback();
  }

  /// Ask for the frame under the playhead as the document now stands.
  ///
  /// Called when the playhead moves or an edit lands — both are *facts* the
  /// engine is told, not requests the frontend schedules. The worker coalesces
  /// whatever piles up behind a render in flight (`drain_to_newest`), which is
  /// why this can be called freely and needs no in-flight bookkeeping here.
  /// Ignored during playback, where the engine is already choosing frames.
  void requestFrame() {
    if (playing.value) return;
    final comp = selectedComp;
    if (comp == null) return;
    try {
      comp.renderFrame(
        frame: BigInt.from(playheadFrame.value),
        scale: viewerScale,
        mode: workspace.performance.playback == PlaybackMode.adaptive
            ? BridgePlaybackMode.adaptive
            : BridgePlaybackMode.everyFrame,
      );
    } catch (_) {
      // No worker yet, or a composition that has gone away. The next playhead
      // move or edit asks again; there is nothing to recover here.
    }
  }

  /// A frame arrived. While playing, the picture leads and the playhead follows
  /// it — that is what makes the transport show the frame actually on screen
  /// rather than the one the engine was asked for. Paused, the playhead is the
  /// user's and is left alone.
  void _arrived(int frame) {
    frameArrived.value++;
    if (playing.value && playheadFrame.value != frame) {
      playheadFrame.value = frame;
    }
  }

  /// Move the playhead by `delta` frames, clamped to the fronted composition.
  void stepFrame(int delta) {
    final comp = selectedComp;
    if (comp == null) return;
    final last = comp.durationFrames() - 1;
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

  /// The fronted comp as the panels draw it (K-184) — refreshed by one bridge
  /// call when the engine reports a change, read by everything else for free.
  final CompModel model = CompModel();

  ViewerTextureController controller = ViewerTextureController();

  /// The platform texture the Viewer draws — the only frame transport (K-183):
  /// every frame arrives as a GPU handle, never as pixels. Null before the
  /// first registration.
  ValueNotifier<int?> viewerFrameid = ValueNotifier(null);

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
  StreamSubscription? _changes;

  LumitUiState(LumitState state, {Workspace? workspace})
      : workspace = workspace ?? (Workspace()..load()) {
    // Appearance and layout live in the workspace, so a change there is a
    // change here as far as any listening widget is concerned.
    this.workspace.addListener(notifyListeners);
    // The read model re-reads on every committed change — one bridge call —
    // and every panel that draws layers repaints from it (K-184).
    _changes = state.onChange.listen((_) => model.refresh());
    sub = state.onWorkerResponse.listen((msg) {
      switch (msg) {
        case WorkerResponse_RenderedDMABuf frame:
          _showDmabuf(frame.field0);
        case WorkerResponse_RenderedSharedTexture frame:
          _showSharedTexture(frame.field0);
        // Scope traces ride the same stream; the Scopes panel subscribes to it
        // directly, so there is nothing for the Viewer to do with one.
        case WorkerResponse_Scope():
          break;
        // Playback ran off the end on its own. Stopping because the *user* asked
        // needs no message — `stopPlayback` already set the flag.
        case WorkerResponse_PlaybackEnded():
          playing.value = false;
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
        .then((id) => _adoptTexture(id, f.frame.toInt()));
  }

  /// Windows zero-copy: register the shared D3D12 texture by its NT handle.
  /// Leaving `fd` null is what selects the DXGI argument set.
  void _showSharedTexture(BridgeSharedFrameInfo f) {
    controller
        .ensureRegistered(f.handle.toInt(), f.width, f.height)
        .then((id) => _adoptTexture(id, f.frame.toInt()));
  }

  /// A registered texture is now current: mark a frame available and, if the id
  /// changed, point the Viewer at it.
  void _adoptTexture(int? id, int frame) {
    _arrived(frame);
    if (id == null) return;
    controller.frameReady();
    if (viewerFrameid.value != id) viewerFrameid.value = id;
  }

  @override
  void dispose() {
    sub?.cancel();
    _changes?.cancel();
    model.dispose();
    viewerFrameid.dispose();
    selectedLayer.dispose();
    activePanel.dispose();
    super.dispose();
  }

  void setSelectedComp(CompositionReference? reference) {
    _selectedComp = reference;
    model.bind(reference);
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
      final last = (comp?.durationFrames() ?? 1) - 1;
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
