// Lumit's Flutter frontend (K-174, the frontend alternative experiment).
// The engine stays in the Rust crates; this application is the chrome —
// see docs/archive/flutter-port/ for the plan and the parity checklist.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:lumit_flutter/panels/panels_frb.dart';
import 'package:lumit_flutter/panels/timeline_extras_frb.dart';
import 'package:lumit_flutter/panels/viewer_texture_controller.dart';
import 'package:lumit_flutter/shell/comp_settings_frb.dart';
import 'package:lumit_flutter/shell/dock_widget.dart';
import 'package:lumit_flutter/shell/menu_bar_frb.dart';
import 'package:lumit_flutter/shell/status_line_frb.dart';
import 'package:lumit_flutter/src/rust/api/cache.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:lumit_flutter/src/rust/api/footage.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';
import 'package:lumit_flutter/src/rust/api/project.dart';
import 'package:lumit_flutter/src/rust/api/project_item.dart';
import 'package:lumit_flutter/src/rust/api/state.dart';
import 'package:lumit_flutter/src/rust/frb_generated.dart';
import 'package:lumit_flutter/state/comp_model.dart';
import 'package:lumit_flutter/state/comp_time.dart';
import 'package:lumit_flutter/state/dock.dart';
import 'package:lumit_flutter/state/dropper.dart';
import 'package:lumit_flutter/state/keymap.dart';
import 'package:lumit_flutter/src/rust/api/keymap.dart';
import 'package:lumit_flutter/state/settings.dart';
import 'package:lumit_flutter/state/workspace.dart';
import 'package:lumit_flutter/theme/theme.dart';
import 'package:lumit_flutter/widgets/controls.dart';
import 'package:lumit_flutter/widgets/ui_scale.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

class StackTraceEntry {
  StackTrace trace;
  String name;
  late DateTime time;
  late Duration duration;
  bool async;

  StackTraceEntry(
      {required this.name,
      required this.trace,
      required this.duration,
      required this.async}) {
    time = DateTime.now();
  }
}

class FunctionCallStats {
  int numCalls = 0;
  Duration totalTime = Duration.zero;

  double get averageMs =>
      totalTime.inMilliseconds.toDouble() / numCalls.toDouble();
}

class LumitDebugUI {
  List<StackTraceEntry> rustCalls = List.empty(growable: true);
  Map<String, FunctionCallStats> stats = {};

  StreamController onChange = StreamController.broadcast();

  void addStackTrace(StackTraceEntry trace) {
    rustCalls.insert(0, trace);

    const maxLen = 100;

    if (stats.containsKey(trace.name) == false) {
      stats[trace.name] = FunctionCallStats();
    }
    var stat = stats[trace.name]!;

    stat.numCalls += 1;
    stat.totalTime += trace.duration;

    if (rustCalls.length > maxLen) {
      rustCalls = rustCalls.sublist(0, maxLen);
    }

    onChange.add(null);
  }

  void clear() {
    rustCalls.clear();
    onChange.add(null);
  }
}

LumitDebugUI debugInfo = LumitDebugUI();

/// Traces every call that crosses into Rust, so the frb seam can be watched
/// while it is being built out. `debugPrint` rather than `print`: it compiles
/// away in release, where a log per bridge call would be far too costly.
class CustomHandler extends BaseHandler {
  @override
  Future<S> executeNormal<S, E extends Object>(NormalTask<S, E> task) async {
    var stack = StackTrace.current;

    var str = stack.toString();
    var lines = str.split("\n");

    var target = lines.elementAtOrNull(2);
    var split = target?.split(" ");

    final start = DateTime.now();
    final result = await super.executeNormal(task);
    final end = DateTime.now();

    var duration = end.difference(start);

    if (split != null) {
      final item = split.elementAtOrNull(split.length - 2);
      debugInfo.addStackTrace(StackTraceEntry(
          name: item!, trace: stack, duration: duration, async: true));
    }

    return result;
  }

  @override
  S executeSync<S, E extends Object, WireSyncType>(
      SyncTask<S, E, WireSyncType> task) {
    var stack = StackTrace.current;

    var str = stack.toString();
    var lines = str.split("\n");

    var target = lines.elementAtOrNull(2);
    var split = target?.split(" ");

    final start = DateTime.now();
    final result = super.executeSync(task);
    final end = DateTime.now();

    var duration = end.difference(start);

    if (split != null) {
      final item = split.elementAtOrNull(split.length - 2);
      debugInfo.addStackTrace(StackTraceEntry(
          name: item!, trace: stack, duration: duration, async: false));
    }

    return result;
  }
}

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

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

  /// The status bar's one-line notice: the latest quiet message or genuine
  /// error, dismissed by its close button. One current notice rather than a
  /// feed, which is what the egui shell's `app.notice` was too.
  final ValueNotifier<LumitNotice?> notice = ValueNotifier(null);

  void postNotice(String message, {bool error = false}) =>
      notice.value = LumitNotice(message, error: error);

  void newProject() {
    _adopt(LumitBridgeState.newProject(onChangeStream: _changeSink()));
  }

  void openProject(String path) {
    // Null means the file would not open; the previous project stays loaded
    // rather than the app being left with none.
    final opened =
        LumitBridgeState.openProject(path: path, onChangeStream: _changeSink());
    if (opened == null) {
      postNotice('Could not open $path', error: true);
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

  /// Give [layer] a Retime, or take it away again — the one implementation,
  /// shared by the keyboard chords and the Composition menu (K-197, docs/04
  /// §12), so no route can drift from the others.
  ///
  /// The engine refuses nothing here, but the call is a bridge crossing like
  /// any other: a layer deleted between the menu opening and the click would
  /// throw, and a command that cannot be performed should do nothing rather
  /// than take the interface down with it.
  bool toggleRetime(LayerReference layer) {
    try {
      layer.toggleRetimeProperty();
    } catch (_) {
      return false;
    }
    notifyDocumentChanged();
    return true;
  }

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

/// One status-bar notice: what to say, and whether it is a genuine error
/// (drawn in the warning tint) rather than quiet feedback.
class LumitNotice {
  final String message;
  final bool error;
  const LumitNotice(this.message, {this.error = false});
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

  /// The keyboard map every shortcut is looked up in (docs/07 §15, K-199).
  late final KeymapState keymap;

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

  /// Bumped when the engine banks a frame in the background (the idle cache
  /// fill). Its own notifier, not [frameArrived]: the picture did not change,
  /// so nothing that re-renders on a new picture (the Scopes) should stir —
  /// only the cache bar, which listens to both.
  final ValueNotifier<int> cacheChanged = ValueNotifier(0);

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
    // The work area is the span being worked on, so it is the span playback
    // runs round: reaching its end goes back to its start and carries on,
    // rather than playing out to the end of the comp and stopping. Read once
    // here rather than per frame — it cannot change while the transport is
    // running, and [_arrived] fires at the comp's rate.
    final set = comp.getWorkArea();
    _loop = set == null
        ? null
        : (
            start: comp.frameAtTime(time: set.inPoint),
            end: comp.frameAtTime(time: set.outPoint)
          );
    _playFrom(comp, playheadFrame.value);
    playing.value = true;
  }

  /// The work area playback loops round, or null when the comp has not been
  /// narrowed — in which case playback ends at the end, as it always did.
  ({int start, int end})? _loop;

  void _playFrom(CompositionReference comp, int frame) => comp.play(
        from: BigInt.from(frame),
        scale: viewerScale,
        mode: workspace.performance.playback == PlaybackMode.adaptive
            ? BridgePlaybackMode.adaptive
            : BridgePlaybackMode.everyFrame,
      );

  void stopPlayback() {
    playing.value = false;
    _loop = null;
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
    if (!playing.value) return;
    if (playheadFrame.value != frame) playheadFrame.value = frame;
    // Round the work area: the frame at its end is shown, then playback starts
    // again from its start. Restarted through `play` rather than by moving the
    // playhead, because the sound and the scheduler's clock both take their
    // baseline from the frame play was asked for.
    final loop = _loop;
    final comp = selectedComp;
    if (loop != null && comp != null && frame >= loop.end) {
      playheadFrame.value = loop.start;
      _playFrom(comp, loop.start);
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

  /// The armed dropper, or null when the tool is not armed (docs/07 §7).
  ///
  /// One at a time, and held at the session level rather than inside the Viewer:
  /// the tool is armed from a parameter row in another panel entirely, and the
  /// Viewer must not have to be mounted for that click to be harmless.
  final ValueNotifier<DropperArm?> dropper = ValueNotifier(null);

  /// The pixels the last [requestDropperSample] read back, or null before the
  /// first reply. Cleared when the tool disarms, so a fresh arm never opens on
  /// the previous pick's pixels.
  final ValueNotifier<BridgeSampledPixels?> dropperPatch = ValueNotifier(null);

  /// Arm the dropper. Replaces whatever was armed — two pending picks would
  /// leave the next click ambiguous.
  void armDropper(DropperArm arm) {
    dropperPatch.value = null;
    dropper.value = arm;
  }

  /// Put the dropper away, picked or not.
  void disarmDropper() {
    dropper.value = null;
    dropperPatch.value = null;
  }

  /// Ask the engine for the pixels around `(x, y)` in the fronted comp's own
  /// pixel grid. The answer arrives on the worker stream and lands in
  /// [dropperPatch]; nothing here waits for it.
  void requestDropperSample(int x, int y) {
    final comp = selectedComp;
    final arm = dropper.value;
    if (comp == null || arm == null) return;
    try {
      comp.samplePixels(
        frame: BigInt.from(playheadFrame.value),
        x: x < 0 ? 0 : x,
        y: y < 0 ? 0 : y,
        grid: dropperGrid,
        scale: viewerScale,
        layer: arm.sampleLayer,
      );
    } catch (_) {
      // No worker, or a composition that has gone away. The next pointer move
      // asks again; there is nothing to recover here.
    }
  }

  StreamSubscription? sub;
  StreamSubscription? _changes;

  LumitUiState(LumitState state, {Workspace? workspace})
      : workspace = workspace ?? (Workspace()..load()) {
    // Appearance and layout live in the workspace, so a change there is a
    // change here as far as any listening widget is concerned.
    this.workspace.addListener(notifyListeners);
    // The keymap: restored from the workspace if the user has changed one,
    // otherwise the engine's shipped defaults (K-199). Held here because
    // every keypress goes through it and the settings page edits it, so it
    // wants the same lifetime as the rest of the session's UI state.
    keymap = KeymapState(workspace: this.workspace);
    // The cache budgets: live engine state with no store behind it, so the
    // settings file carries the user's choice and hands it back here (K-194's
    // sizing only picks the *default*). Null means untouched — leave the
    // engine on its own default rather than writing today's default into the
    // file forever.
    final perf = this.workspace.performance;
    final ramBudget = perf.cacheBudgetBytes;
    if (ramBudget != null) setCacheBudget(bytes: BigInt.from(ramBudget));
    final vramBudget = perf.vramBudgetBytes;
    if (vramBudget != null) setVramCacheBudget(bytes: BigInt.from(vramBudget));
    // The read model re-reads on every committed change — one bridge call —
    // and every panel that draws layers repaints from it (K-184).
    _changes = state.onChange.listen((_) {
      clearCompTimeCache();
      model.refresh();
    });
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
        case WorkerResponse_CacheFilled():
          cacheChanged.value++;
        // The pixels under the dropper. Held rather than acted on: the
        // magnifier draws whatever the last read said, and the click that
        // picks reads it from here.
        case WorkerResponse_Sampled(:final field0):
          dropperPatch.value = field0;
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

  /// Windows and macOS zero-copy: register the surface by the one integer that
  /// names it — an NT handle for the shared D3D12 texture there, an `IOSurfaceID`
  /// here (K-195). One case for both, because the payload is the same shape.
  /// Leaving `fd` null is what selects the handle argument set.
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
    cacheChanged.dispose();
    viewerFrameid.dispose();
    selectedLayer.dispose();
    activePanel.dispose();
    super.dispose();
  }

  /// The comps open as Timeline tabs (docs/07 §4: one tab per open comp), in
  /// the order first fronted. Fronting a comp opens its tab; closing a tab
  /// only closes the tab — the comp stays in the project.
  final List<UuidValue> openComps = [];

  void setSelectedComp(CompositionReference? reference) {
    if (reference != null && !openComps.contains(reference.internalid)) {
      openComps.add(reference.internalid);
    }
    _selectedComp = reference;
    model.bind(reference);
    notifyListeners();
  }

  /// Close a comp's Timeline tab. When the closed tab was fronted, [fallback]
  /// — the tab bar's nearest remaining neighbour — fronts instead.
  void closeComp(UuidValue id, {CompositionReference? fallback}) {
    openComps.remove(id);
    if (_selectedComp?.internalid == id) {
      setSelectedComp(fallback);
    } else {
      notifyListeners();
    }
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
  void initState() {
    super.initState();
    // Shortcuts are handled GLOBALLY, not through the focus tree. Every menu,
    // popup and palette lives in the Overlay outside this view's scope, so
    // any of them could walk focus away and never bring it back — and every
    // shortcut died until something was clicked (the space bar's recurring
    // funeral). A hardware-keyboard handler fires wherever focus is; the
    // focused-text-field guard inside _onKey keeps typing safe.
    HardwareKeyboard.instance.addHandler(_handleKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKey);
    super.dispose();
  }

  bool _handleKey(KeyEvent event) {
    if (!mounted) return false;
    return _onKey(
            context.read<LumitState>(), context.read<LumitUiState>(), event) ==
        KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    var uiState = context.watch<LumitUiState>();
    final state = context.watch<LumitState>();

    // The scope stays for the text fields: when one gives focus up, focus
    // falls back to the enclosing scope rather than to nothing.
    return FocusScope(
      autofocus: true,
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
          ),
          // The strip under the dock (docs/07 §1): the running export's
          // progress and Cancel, reachable without the dialogue open.
          const StatusLineFrb(),
        ],
      ),
    );
  }

  /// Which keymap context the focused panel is. Panels with no bindings of
  /// their own resolve to `Global`, which is also the fallback for every other
  /// context, so nothing is lost by the mapping being partial.
  BridgeKeyContext _contextOf(Panel? panel) => switch (panel) {
        Panel.project => BridgeKeyContext.project,
        Panel.viewer => BridgeKeyContext.viewer,
        Panel.timeline => BridgeKeyContext.timeline,
        Panel.effectControls => BridgeKeyContext.effects,
        _ => BridgeKeyContext.global,
      };

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

    final project = state.project;
    final comp = ui.selectedComp;

    // Which action this chord means is the engine's answer, not a ladder of key
    // comparisons here (K-199). Asked in the *focused panel's* context, because
    // a binding scoped to one panel has to beat the app-wide one while that
    // panel is active — the engine falls back to Global itself, so one call
    // answers both. (This handler runs wherever focus is; the active panel is
    // what the dock last fronted, which is what a user would call "where I am".)
    final action = ui.keymap.actionFor(_contextOf(ui.activePanel.value), event);
    if (action == null) return KeyEventResult.ignored;

    var handled = true;
    switch (action) {
      case 'edit.redo':
        project?.redo();
        state.notifyDocumentChanged();
      case 'edit.undo':
        project?.undo();
        state.notifyDocumentChanged();
      case 'playback.toggle':
        ui.requestTogglePlay();
      // Shuttle is not built, and J/L have always stepped a frame here. Mapping
      // them onto the step keeps today's keyboard exactly as it is rather than
      // taking two keys away until a shuttle exists to give them back.
      case 'playback.frame.prev' || 'playback.shuttle.reverse':
        ui.stepFrame(-1);
      case 'playback.frame.next' || 'playback.shuttle.forward':
        ui.stepFrame(1);
      case 'playback.comp.start':
        ui.playheadFrame.value = 0;
      case 'playback.comp.end':
        final last = (comp?.durationFrames() ?? 1) - 1;
        ui.playheadFrame.value = last < 0 ? 0 : last;
      case 'layer.retime.enable':
        // Give the selected layer a Retime, or take it away again (docs/04
        // §12). On installs the identity map, so the picture does not move —
        // it just gains a row above Transform to key. Ctrl+Alt+T by default
        // (K-200): AE's own Time Remap chord, and one Windows cannot steal.
        // The Composition menu carries the command too (K-198's lesson).
        final layer = ui.selectedLayer.value;
        if (layer == null) {
          handled = false;
        } else {
          state.toggleRetime(layer);
        }
      case 'layer.duplicate':
        final layer = ui.selectedLayer.value;
        if (layer == null) {
          handled = false;
        } else {
          layer.duplicate();
          state.notifyDocumentChanged();
        }
      case 'file.save':
        // Ctrl+S goes through exactly the same call the File menu's Save does
        // (K-203) — a shortcut with its own path to disk is a second save to
        // keep honest. Without a path yet it opens the picker, which is what
        // Save has always meant on a document that has never been written.
        saveProjectFrb(state);
      // The work area is the span the Viewer previews and the export writes
      // (K-037), so setting its ends from the playhead is a two-key job, not a
      // trip to a menu. A comp that has never had one set reads as the whole
      // comp, so B and N always have something to move.
      case 'workarea.set.start' || 'workarea.set.end':
        if (comp == null) {
          handled = false;
        } else {
          comp.setWorkArea(
            span: workAreaWith(
              comp: comp,
              current: comp.getWorkArea(),
              wanted: ui.playheadFrame.value,
              isStart: action == 'workarea.set.start',
            ),
          );
          state.notifyDocumentChanged();
        }
      case 'edit.delete.selection':
        final layer = ui.selectedLayer.value;
        if (layer == null) {
          handled = false;
        } else {
          layer.delete();
          ui.selectedLayer.value = null;
          state.notifyDocumentChanged();
        }
      // A bound action this shell has no call for yet — the menus carry those.
      // Ignored rather than swallowed, so the key still reaches whatever else
      // wants it.
      default:
        handled = false;
    }
    return handled ? KeyEventResult.handled : KeyEventResult.ignored;
  }
}
