// Lumit's Flutter frontend (K-174, the frontend alternative experiment).
// The engine stays in the Rust crates; this application is the chrome —
// see docs/archive/flutter-port/ for the plan and the parity checklist.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, Platform;
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:lumit_flutter/panels/panels_frb.dart';
import 'package:lumit_flutter/panels/timeline_extras_frb.dart';
import 'package:lumit_flutter/panels/viewer_texture_controller.dart';
import 'package:lumit_flutter/shell/comp_settings_frb.dart';
import 'package:lumit_flutter/shell/precompose_dialog_frb.dart';
import 'package:lumit_flutter/shell/dock_widget.dart';
import 'package:lumit_flutter/shell/about_window_frb.dart';
import 'package:lumit_flutter/shell/first_run_frb.dart';
import 'package:lumit_flutter/shell/menu_bar_frb.dart';
import 'package:lumit_flutter/shell/project_settings_frb.dart';
import 'package:lumit_flutter/shell/settings_window_frb.dart';
import 'package:lumit_flutter/shell/status_line_frb.dart';
import 'package:lumit_flutter/shell/tool_bar_frb.dart';
import 'package:lumit_flutter/src/rust/api/cache.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:lumit_flutter/src/rust/api/footage.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';
import 'package:lumit_flutter/src/rust/api/project.dart';
import 'package:lumit_flutter/src/rust/api/project_item.dart';
import 'package:lumit_flutter/src/rust/api/state.dart';
import 'package:lumit_flutter/src/rust/frb_generated.dart';
import 'package:lumit_flutter/state/comp_model.dart';
import 'package:lumit_flutter/state/clipboard.dart';
import 'package:lumit_flutter/state/comp_time.dart';
import 'package:lumit_flutter/state/dock.dart';
import 'package:lumit_flutter/state/dropper.dart';
import 'package:lumit_flutter/state/keymap.dart';
import 'package:lumit_flutter/src/rust/api/keymap.dart';
import 'package:lumit_flutter/state/layer_bounds.dart';
import 'package:lumit_flutter/state/preview_progress.dart';
import 'package:lumit_flutter/state/render_timings.dart';
import 'package:lumit_flutter/state/settings.dart';
import 'package:lumit_flutter/state/install_site.dart';
import 'package:lumit_flutter/state/tools.dart';
import 'package:lumit_flutter/state/updates.dart';
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
  Duration lastTime = Duration.zero;

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
    stat.lastTime = trace.duration;

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

/// The window's title: plain 'Lumit' until the project has a home on disk,
/// then 'Lumit - `<file name>`' without the extension — the same convention as
/// every editor's title bar.
String windowTitleFor(String? path) {
  if (path == null || path.isEmpty) return 'Lumit';
  var name = path.split(RegExp(r'[/\\]')).last;
  if (name.toLowerCase().endsWith('.lum')) {
    name = name.substring(0, name.length - 4);
  }
  return 'Lumit - $name';
}

/// The `.lum` file a double-click or `lumit myproject.lum` asked us to open:
/// the first argument that ends in `.lum` and exists on disk, or null. The
/// Windows runner forwards the command line as entrypoint arguments (the
/// installer's file association passes the document path this way); anything
/// else on the line — flags, stray tokens — is not a project and is ignored.
String? projectPathFromArgs(List<String> args) {
  for (final a in args) {
    if (a.toLowerCase().endsWith('.lum') && File(a).existsSync()) return a;
  }
  return null;
}

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // Sweep up after an update before anything else happens (K-297): delete the
  // version we have just replaced, now that nothing is holding its files, and
  // put it back if a swap was cut in half. Never throws and never blocks — a
  // tidying problem is not a reason for an editor not to open.
  tidyAfterUpdate(InstallSite.detect());

  await BridgeLib.init(handler: CustomHandler());

  final state = LumitState();
  // Start with an empty project rather than nothing at all. Every document
  // command — import, new composition, save — is disabled while there is no
  // project, so booting without one left the whole File and Composition menu
  // dead and no way to make it live: the first thing a user does needs
  // something to do it *to*.
  state.newProject();
  // A document on the command line opens over the empty project. On failure
  // openProject posts its notice and the empty project stands — the same
  // degraded-but-alive behaviour as a failed File → Open.
  final fromArgs = projectPathFromArgs(args);
  if (fromArgs != null) state.openProject(fromArgs);
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
    // The comp list is cached per document (K-184) and invalidated when the
    // item tree changes — but adopting another project is not a change to the
    // tree, it is a different tree. Left standing, every reader of `comps()`
    // answers from the project that is no longer loaded until something
    // happens to edit the new one: the session restore looked the reopened
    // project's comps up in the *previous* project's list and found none of
    // them, so a reopened project came back with no tabs and nothing fronted.
    _compsCache = null;

    workerStream?.cancel();
    workerStream =
        opened.startWorker().listen((msg) => _onWorkerResponse.add(msg));

    final sink = _pendingSink;
    if (sink != null) {
      currentDocumentStream?.cancel();
      currentDocumentStream = sink.stream.listen(handleChange);
      _pendingSink = null;
    }

    refreshWindowTitle();
    notifyListeners();
  }

  /// Put the project's name in the title bar. Called when the document's path
  /// can have changed — adopting a project, and a completed save — rather than
  /// on every edit, so no bridge call rides the change stream.
  void refreshWindowTitle() {
    SystemChrome.setApplicationSwitcherDescription(
      ApplicationSwitcherDescription(label: windowTitleFor(project?.path())),
    );
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
      asSequence: Provider.of<LumitUiState>(context, listen: false)
          .workspace
          .interface
          .videoAsSequenceLayer,
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

  /// Whether there is a newer Lumit, and fetching it (K-296).
  ///
  /// One for the session, here, because the Help menu and Settings ▸ General
  /// are two views of the same check and neither owns it. The version is passed
  /// as a function, not a string: it comes over the bridge, and a widget test
  /// that builds this state must not call the engine merely by existing.
  late final UpdateService updates =
      UpdateService(currentVersion: () => versionFromBootLine(lumitVersion()));

  /// How big each layer's content is, for the Viewer's boxes and hit-testing
  /// (K-217). Held here because the answer is the document's, not a panel's,
  /// and probing a clip is disk work that must happen once rather than per
  /// Viewer rebuild.
  final LayerBoundsCache layerBounds = LayerBoundsCache();

  /// Which tool the toolbar has armed (docs/07 §1.7, K-216).
  ///
  /// Session state at the shell level, like the dropper below it and for the
  /// same reason: the tool is picked in one place and read in another, and no
  /// panel should have to be mounted for either.
  final ToolsState tools = ToolsState();

  DockSplit get split => workspace.dock;
  ValueNotifier<Panel?> activePanel = ValueNotifier(null);

  /// A finer selection's claim on Delete (K-234), set by the Timeline while it
  /// is mounted and cleared when it goes.
  ///
  /// The shell's Delete removes the selected *layers*, which is only the right
  /// answer when nothing smaller is selected: with a mask row picked, Delete
  /// means that mask, and deleting the layer it sits on instead is the opposite
  /// of what was asked. The shell asks this first and stands down when it
  /// returns true. A callback rather than a race between key handlers: every
  /// hardware-keyboard handler runs on every key, so a panel cannot claim a
  /// chord simply by handling it.
  bool Function()? deleteClaim;

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

  /// Look for a newer Lumit on launch, if that is switched on and it has been
  /// a day since the last look (K-296).
  ///
  /// Only ever a *look*: what it finds ends up as the wording of the Help menu
  /// row, and downloading anything still waits for a click. Failure is silent —
  /// a machine with no network has not done anything wrong, and an editor that
  /// opened with a complaint about the internet would be insufferable.
  Future<void> maybeCheckForUpdates() async {
    if (!workspace.autoUpdate) return;
    // Never under `flutter test`: a suite that mounts the shell would otherwise
    // reach the network, which is slow, flaky, and none of a test's business.
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    if (!updates.dueForCheck(workspace.lastUpdateCheckMs)) return;
    await updates.check();
    workspace.rememberUpdateCheck(DateTime.now().millisecondsSinceEpoch);
  }

  /// Bumped when `Ctrl+Shift+P` asks for the command palette.
  ///
  /// A notifier for the same reason as [togglePlayRequest]: the palette's list
  /// of commands is the menu bar's, declared beside the menu items so the two
  /// cannot drift into different ideas of what "New composition" does. The
  /// shortcut asks for the palette rather than building a second list of its
  /// own — which would be exactly the drift that note warns about.
  final ValueNotifier<int> paletteRequest = ValueNotifier(0);

  void requestPalette() => paletteRequest.value++;

  /// Bumped each time a rendered frame reaches the Viewer, on any of the three
  /// transports. Watched by anything that redraws when the picture does — the
  /// Timeline's cache bar, the Scopes panel.
  final ValueNotifier<int> frameArrived = ValueNotifier(0);

  /// Bumped when the engine banks a frame in the background (the idle cache
  /// fill). Its own notifier, not [frameArrived]: the picture did not change,
  /// so nothing that re-renders on a new picture (the Scopes) should stir —
  /// only the cache bar, which listens to both.
  final ValueNotifier<int> cacheChanged = ValueNotifier(0);

  /// The preview tier the last frame was made at: 1 Full, 2 Half, 3 Third,
  /// 4 Quarter (K-030/K-171).
  ///
  /// Carried on the frame rather than asked for. The Viewer shows the tier in
  /// two places, and each of them asked the engine in its `build()` — two calls
  /// across the boundary for each frame of playback, ~48 a second at 24 fps,
  /// for a number that only a new frame can change.
  final ValueNotifier<int> previewTier = ValueNotifier(1);

  /// How far the frame the Viewer is waiting for has got, when that is worth
  /// drawing (docs/07 §2.5). Fed from the worker stream below; the Viewer's
  /// progress bar listens to it and nothing else does.
  final PreviewProgressTracker previewProgress = PreviewProgressTracker();

  /// The last measured frame's per-layer and per-effect render times
  /// (docs/13 §7.1). Empty — and the engine not measuring — until a column or
  /// a panel that shows the numbers asks for them.
  ///
  /// Switching it on asks for the frame under the playhead again, because
  /// numbers only exist for a frame the engine actually composites: without
  /// this the column sat empty until something else happened to want a render,
  /// which on a comp the idle fill had already made could be for ever.
  late final RenderTimings renderTimings = RenderTimings(
    onMeasuringStarted: requestFrame,
    // An engine that refuses the switch says so in the status line rather than
    // leaving a lit stopwatch over a column that will never fill.
    onEngineError: (error) => _app.postNotice(
      'Could not measure render times: $error',
      error: true,
    ),
  );

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
    _playedFrom = playheadFrame.value;
    // Whatever the scrub before this was waiting for, it is not what the user
    // is watching now: playback draws no progress bar (docs/07 §2.5), and one
    // left standing from the frame that started the run would be the only bar
    // that ever appeared during playback.
    previewProgress.stop();
    _playFrom(comp, playheadFrame.value);
    playing.value = true;
  }

  /// Where the playhead stood when [play] was called, so stopping can put it
  /// back (K-254). Null when nothing is playing.
  ///
  /// Held here rather than read off the comp because it is a fact about *this
  /// run of the transport*, not about the document: it must survive the frames
  /// arriving and moving the playhead, and it must be forgotten the moment
  /// playback ends however it ends.
  int? _playedFrom;

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

  /// Stop the transport, and — unless the user is taking hold of the playhead
  /// themselves — put the playhead back where play started (K-254).
  ///
  /// Returning is the default because playback is a *preview*: you park the
  /// playhead where you are working, watch it run, and expect to still be where
  /// you were when it stops. Somebody who wants the playhead to stay where the
  /// picture stopped ticks Settings ▸ Interface ▸ Editing.
  ///
  /// `restorePlayhead: false` is for the one case where returning would fight
  /// the user: scrubbing the ruler stops playback *in order to* move the
  /// playhead, so putting it back would undo the very gesture that stopped it.
  void stopPlayback({bool restorePlayhead = true}) {
    playing.value = false;
    _loop = null;
    selectedComp?.stopPlayback();
    _returnPlayhead(restore: restorePlayhead);
  }

  /// The half of stopping that moves the playhead — shared by the user's stop
  /// and by playback running off the end on its own, because "where am I when
  /// it stops" should not depend on *why* it stopped.
  void _returnPlayhead({bool restore = true}) {
    final from = _playedFrom;
    _playedFrom = null;
    if (!restore || from == null) return;
    if (workspace.interface.playheadStaysOnStop) return;
    // Setting the notifier is the whole of it: the Viewer listens and asks the
    // engine for the frame there, exactly as it does for any other move.
    playheadFrame.value = from;
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

  /// Move the playhead because the user is taking hold of it — a drag on the
  /// time ruler, a click in the lane area (K-254).
  ///
  /// Different from setting [playheadFrame] directly in one way that matters:
  /// it **stops the transport first**. Scrubbing against running playback was
  /// unwinnable — the engine hands back a frame every tick and each one moved
  /// the playhead straight back off the pointer — so taking hold of it means
  /// taking it off the transport. The playhead does *not* return to where play
  /// started here: the point of the gesture is to end up somewhere else.
  void scrubTo(int frame) {
    if (playing.value) stopPlayback(restorePlayhead: false);
    playheadFrame.value = frame;
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

  /// Remember a layout the user changed by dragging a panel — app-wide, and
  /// against the open project, which is what makes two projects able to be
  /// arranged differently (K-245).
  void saveLayout() {
    workspace.save();
    rememberSession();
  }

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

  /// The layer everything single-layer works on: Effect controls, the keyboard
  /// commands, the Timeline's fold-out. The *primary* of the selection below.
  ValueNotifier<LayerReference?> selectedLayer = ValueNotifier(null);

  /// What Copy put down, for Paste to pick up (K-275). One tray for the
  /// session, shared by the Edit menu and the panels.
  ///
  /// Read directly; **written through the two methods below**, because Paste is
  /// greyed out while it is empty and a menu that never hears about the copy
  /// stays greyed until something else happens to repaint it. That is exactly
  /// how it behaved before those methods existed.
  final LumitClipboard clipboard = LumitClipboard();

  /// Copy a layer, and tell the interface so Paste ungreys.
  void copyLayerToClipboard(String text) {
    clipboard.putLayer(text);
    notifyListeners();
  }

  /// Copy one effect or a whole stack, same repaint.
  void copyEffectsToClipboard(String text) {
    clipboard.putEffects(text);
    notifyListeners();
  }

  /// The whole selection, primary first (K-217).
  ///
  /// Kept beside [selectedLayer] rather than replacing it, because almost
  /// everything in the application acts on one layer and reads it directly —
  /// and a second notifier is cheaper than teaching forty call sites to take
  /// the first element of a list. The two are held in step by [_syncSelection]:
  /// setting [selectedLayer] on its own (which the Timeline and the tests do)
  /// makes that layer the entire selection, which is exactly what clicking one
  /// row means.
  final ValueNotifier<List<LayerReference>> selectedLayers =
      ValueNotifier(const []);

  /// The selection as ids, for a "is this one selected?" test that does not
  /// walk the list per layer per paint.
  Set<UuidValue> get selectedLayerIds =>
      {for (final layer in selectedLayers.value) layer.internallayerId};

  /// Replace the selection. The first entry becomes [selectedLayer].
  void setSelection(List<LayerReference> layers) {
    selectedLayers.value = List.unmodifiable(layers);
    selectedLayer.value = layers.isEmpty ? null : layers.first;
  }

  /// Add [layer] to the selection, or take it out again — Shift-click.
  void toggleSelected(LayerReference layer) {
    final id = layer.internallayerId;
    final next = [
      for (final held in selectedLayers.value)
        if (held.internallayerId != id) held,
    ];
    if (next.length == selectedLayers.value.length) next.add(layer);
    setSelection(next);
  }

  void clearSelection() => setSelection(const []);

  /// The turn a Rotation-tool drag is part way through, by layer id (K-230).
  ///
  /// The picture is previewed at the new angle while the drag is in flight, but
  /// the document still holds the old one — so the wireframe drawn from the
  /// document lagged the picture and only caught up on release. The tool that
  /// is turning publishes here and the gizmo that draws the boxes reads it; the
  /// two are different widgets in different layers of the Viewer's stack, and
  /// this is the one value they share. Empty whenever nothing is turning.
  final ValueNotifier<Map<UuidValue, double>> liveRotations =
      ValueNotifier(const {});

  /// The line a Type edit is part way through, by layer id (K-232).
  ///
  /// Published for the same reason as [liveRotations]: what is being typed is
  /// previewed on the picture while the document still holds the old document,
  /// so a box measured from the document does not grow as the words do. Empty
  /// whenever nothing is being typed.
  final ValueNotifier<Map<UuidValue, ({String text, double size})>> liveText =
      ValueNotifier(const {});

  /// Forget layers that are no longer in the composition (K-238).
  ///
  /// **Why this is not merely tidy.** A selection is not only a highlight — it
  /// is the answer to "which layer does this tool act on?". Undo a shape layer
  /// and the layer went, but its id stayed selected, so the next shape drag
  /// still believed a layer was selected and tried to draw a *mask* on one that
  /// no longer existed. The engine refused, the refusal was swallowed, and the
  /// drag did nothing: the tool had simply stopped working, with nothing on
  /// screen to say why.
  ///
  /// Undo is only the easiest way to see it. Deleting a layer from the
  /// Timeline, closing a comp, or any edit that removes a layer leaves the same
  /// stale name behind, which is why this is answered once, here, from the
  /// model — rather than at each of the places a layer can vanish.
  ///
  /// An empty model means nothing is loaded yet rather than everything has
  /// gone, so the selection is left alone: clearing it there would drop the
  /// selection on every rebind.
  void _dropVanishedFromSelection() {
    final held = selectedLayers.value;
    if (held.isEmpty) return;
    final live = model.heldLayers;
    if (live.isEmpty) return;
    final alive = {for (final entry in live) entry.layer.internallayerId};
    final kept = [
      for (final layer in held)
        if (alive.contains(layer.internallayerId)) layer,
    ];
    if (kept.length == held.length) return;
    setSelection(kept);
  }

  /// Keep the list honest when something sets the primary on its own.
  void _syncSelection() {
    final primary = selectedLayer.value;
    // Whichever way round the two notifiers were set, the selection has just
    // changed, and it is part of the session (see [rememberSession]).
    rememberSession();
    if (primary == null) {
      if (selectedLayers.value.isNotEmpty) selectedLayers.value = const [];
      return;
    }
    if (selectedLayerIds.contains(primary.internallayerId)) return;
    selectedLayers.value = List.unmodifiable([primary]);
  }

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

  /// The window of pixels the last [requestDropperSample] read back, or null
  /// before the first reply. Cleared when the tool disarms, so a fresh arm
  /// never opens on the previous pick's pixels.
  ///
  /// A window, not a pixel: the magnifier cuts its own nine-by-nine out of this
  /// as the pointer moves, and only asks again when the pointer nears its edge
  /// (see `windowCovers`). That is what keeps a sweep across the picture to a
  /// handful of reads instead of one per mouse move.
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

  /// Ask the engine for a window of pixels around the point `(u, v)` of the
  /// picture, each a fraction from 0 to 1. The answer arrives on the worker
  /// stream and lands in [dropperPatch]; nothing here waits for it.
  ///
  /// A fraction rather than a pixel because the frontend cannot know which
  /// raster will be read — a reduced-resolution preview has its own grid, and
  /// the reply is what says which one it used.
  ///
  /// Called only when the window in hand cannot answer — the caller checks
  /// first — so this is a handful of calls per pick, not one per mouse move.
  void requestDropperSample(double u, double v) {
    final comp = selectedComp;
    final arm = dropper.value;
    if (comp == null || arm == null) return;
    try {
      comp.samplePixels(
        frame: BigInt.from(playheadFrame.value),
        u: u,
        v: v,
        window: dropperWindow,
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

  /// The session's engine-facing state. Held because the comp list it caches
  /// is what says which comps still exist (K-184).
  final LumitState _app;

  LumitUiState(LumitState state, {Workspace? workspace})
      : _app = state,
        workspace = workspace ?? (Workspace()..load()) {
    // Appearance and layout live in the workspace, so a change there is a
    // change here as far as any listening widget is concerned.
    this.workspace.addListener(notifyListeners);
    // Floating windows read and write where they were left through this
    // (K-242); the controls file has no other way to reach the store.
    modalPlacementStore = this.workspace;
    selectedLayer.addListener(_syncSelection);
    // A layer that has gone must leave the selection with it (K-238). The
    // model is the one place that knows which layers exist, so the pruning
    // hangs off its refresh rather than off each of the several ways a layer
    // can disappear.
    model.addListener(_dropVanishedFromSelection);
    // And the same for the comp the model itself is bound to: it can be undone
    // out of existence while it is the one being looked at.
    model.addListener(_frontLiveCompIfFrontedOneHasGone);
    // A project being adopted — opened, or made new — is where the saved
    // session is put back. The engine state is the only thing that knows a
    // document has been swapped underneath us. The document loaded *now* is
    // the one this shell starts on, so it does not count as a swap: without
    // this the first edit of the session would read as a new project and
    // clear the fronted comp and the selection.
    _sessionProject = _app.project;
    _app.addListener(_adoptProjectSession);
    // Where the playhead was left is worth keeping, and it moves far too often
    // to write down each time. So it is captured when the user steps away from
    // the window and when they close it, alongside the deliberate acts below.
    _lifecycle = AppLifecycleListener(
      onInactive: rememberSession,
      onExitRequested: () async {
        rememberSession();
        return AppExitResponse.exit;
      },
    );
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
    final diskBudget = perf.diskBudgetBytes;
    if (diskBudget != null) setDiskCacheBudget(bytes: BigInt.from(diskBudget));
    // Where the parked frames go. Restored the same way, and by name rather
    // than by index so a reordered enum cannot silently move a user's cache.
    final where = perf.diskCacheLocation;
    if (where != null) {
      setDiskCacheLocation(
        location: cacheLocationFromName(where),
        folder: perf.diskCacheFolder ?? '',
      );
    }
    // The read model re-reads on every committed change — one bridge call —
    // and every panel that draws layers repaints from it (K-184).
    _changes = state.onChange.listen((_) {
      clearCompTimeCache();
      model.refresh();
    });
    sub = state.onWorkerResponse.listen((msg) {
      switch (msg) {
        case WorkerResponse_RenderedDMABuf frame:
          previewTier.value = frame.field0.tier;
          _showDmabuf(frame.field0);
        case WorkerResponse_RenderedSharedTexture frame:
          previewTier.value = frame.field0.tier;
          _showSharedTexture(frame.field0);
        // Scope traces ride the same stream; the Scopes panel subscribes to it
        // directly, so there is nothing for the Viewer to do with one.
        case WorkerResponse_Scope():
          break;
        // Playback ran off the end on its own. Stopping because the *user* asked
        // needs no message — `stopPlayback` already set the flag.
        case WorkerResponse_PlaybackEnded():
          playing.value = false;
          // Running off the end returns the playhead too (K-254): where you are
          // when the transport stops should not depend on whether you stopped
          // it or the composition ran out.
          _returnPlayhead();
        case WorkerResponse_CacheFilled():
          cacheChanged.value++;
        // The pixels under the dropper. Held rather than acted on: the
        // magnifier draws whatever the last read said, and the click that
        // picks reads it from here.
        case WorkerResponse_Sampled(:final field0):
          dropperPatch.value = field0;
        // How far the frame being waited on has got. The engine sends these
        // only for a frame somebody is waiting on — never during playback —
        // and the tracker decides whether it is slow enough to draw.
        case WorkerResponse_RenderProgress(:final field0):
          previewProgress.report(field0);
        // What the frame just made cost. Only sent while something is showing
        // the numbers (`RenderTimings.setMeasuring`).
        case WorkerResponse_FrameProfile(:final field0):
          renderTimings.report(field0);
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
    _app.removeListener(_adoptProjectSession);
    _lifecycle.dispose();
    sub?.cancel();
    _changes?.cancel();
    tools.dispose();
    layerBounds.dispose();
    // The progress tracker owns a timer — the delay that decides whether a
    // slow frame is slow enough to draw a bar for. Cancelling the subscription
    // above stops new reports, but a report that arrived a moment earlier has
    // already started one, and an uncancelled timer outlives the thing that
    // set it. In the application that is a small leak per project session; in
    // the frb tests it is a failure, and one that lands on whichever test
    // happens to be running when it fires rather than the one that caused it.
    previewProgress.dispose();
    model.dispose();
    cacheChanged.dispose();
    previewTier.dispose();
    viewerFrameid.dispose();
    selectedLayer.removeListener(_syncSelection);
    selectedLayer.dispose();
    selectedLayers.dispose();
    activePanel.dispose();
    paletteRequest.dispose();
    super.dispose();
  }

  /// The comps open as Timeline tabs (docs/07 §4: one tab per open comp), in
  /// the order first fronted. Fronting a comp opens its tab; closing a tab
  /// only closes the tab — the comp stays in the project.
  final List<UuidValue> openComps = [];

  /// The comp fronted before this one, so a comp that vanishes under the user
  /// can put them back where they came from rather than somewhere arbitrary.
  UuidValue? _previousComp;

  void setSelectedComp(CompositionReference? reference) {
    if (reference != null && !openComps.contains(reference.internalid)) {
      openComps.add(reference.internalid);
    }
    if (reference?.internalid != _selectedComp?.internalid) {
      _previousComp = _selectedComp?.internalid;
    }
    _selectedComp = reference;
    model.bind(reference);
    rememberSession();
    notifyListeners();
  }

  // --- The per-project session ---------------------------------------------
  //
  // Where the user had got to in *this* document: the comps on the tab strip,
  // which one was fronted, where the playhead sat, what was selected. It is
  // kept in the workspace store keyed by the project's path rather than in the
  // `.lum`, because none of it is the document — a project file must stay
  // byte-identical between two saves of the same work and must not carry one
  // machine's habits to another (docs/10 §1.1, §2). The panel arrangement and
  // which panel each tab group fronts are already persisted there too, app-wide.

  /// The project whose session is on screen. Compared by identity, so a
  /// document swapped underneath the shell is noticed the moment it is adopted.
  ProjectReference? _sessionProject;

  late final AppLifecycleListener _lifecycle;

  /// Write down where the user is. A project with no file has nowhere to be
  /// written to — the sessions are keyed by path — so this is a no-op until it
  /// has been saved once.
  void rememberSession() {
    // Restoring moves the fronted comp and the selection, and each of those
    // moves would be written back — over the very session being read.
    if (_restoring) return;
    final path = _app.project?.path();
    if (path == null) return;
    workspace.rememberSession(path, session());
  }

  /// Where the user is, as the thing that gets written down: the tab strip, the
  /// fronted comp, the playhead, the selection, and how the panels are arranged.
  SavedSession session() => SavedSession(
        openComps: [for (final id in openComps) id.toString()],
        activeComp: _selectedComp?.internalid.toString(),
        frame: playheadFrame.value,
        selectedLayer: selectedLayer.value?.internallayerId.toString(),
        dock: workspace.dock.toJson(),
      );

  /// The same thing as JSON, for the copy that goes inside the `.lum` so it
  /// travels with a project shared with someone else (K-245).
  String sessionJson() => jsonEncode(session().toJson());

  /// Put the saved session back after a project is opened, and start from
  /// nothing when a new one is made.
  ///
  /// Every id is checked against the document that actually loaded before it is
  /// used: a comp or layer deleted since the session was written must leave the
  /// user on a sensible default, never on a reference the engine has never
  /// heard of.
  bool _restoring = false;

  /// The arrangement the project file itself carries, or null when it has none
  /// or none that can be read.
  SavedSession? _embeddedSession(ProjectReference project) {
    try {
      final json = project.uiState();
      if (json == null) return null;
      final decoded = jsonDecode(json);
      if (decoded is! Map) return null;
      return SavedSession.fromJson(decoded.cast<String, dynamic>());
    } catch (_) {
      // A project written by another build may describe an interface this one
      // does not have. Opening it must still work; it simply opens arranged the
      // way this machine already was.
      return null;
    }
  }

  /// Put the panels where the session says, if it says anything about them.
  ///
  /// A layout naming a panel this build has never heard of is dropped whole
  /// rather than half-applied — the arrangement is a hint, and the one on
  /// screen is a perfectly good fallback.
  void _applyDock(Map<String, dynamic>? json) {
    if (json == null) return;
    try {
      final parsed = DockNode.fromJson(json);
      if (parsed is! DockSplit) return;
      workspace.dock = parsed;
      workspace.touch();
    } catch (_) {
      // Left as it was.
    }
  }

  void _adoptProjectSession() {
    final project = _app.project;
    if (identical(project, _sessionProject)) return;
    _sessionProject = project;

    _restoring = true;
    try {
      // Nothing from the previous document may outlive it: its comp ids, its
      // playhead and its selection all belong to a project no longer loaded.
      openComps.clear();
      clearSelection();
      playheadFrame.value = 0;
      setSelectedComp(null);

      final path = project?.path();
      if (path == null) return;
      workspace.rememberProject(path);

      // This machine's own record of the project comes first: it is the more
      // recent account of what *this* user was doing, and it is kept up to date
      // between saves. The one in the file is what a project arriving from
      // somebody else brings with it (K-245), so it answers exactly when there
      // is no local record — the first time this project is opened here.
      final session = workspace.sessionFor(path) ?? _embeddedSession(project!);
      if (session == null) return;
      _applyDock(session.dock);

      final known = {
        for (final (comp, _) in _app.comps()) comp.internalid.toString(): comp,
      };
      for (final id in session.openComps) {
        final comp = known[id];
        if (comp != null) openComps.add(comp.internalid);
      }
      final front = known[session.activeComp] ??
          (openComps.isEmpty ? null : known[openComps.first.toString()]);
      setSelectedComp(front);
      playheadFrame.value = session.frame < 0 ? 0 : session.frame;

      final wanted = session.selectedLayer;
      if (front == null || wanted == null) return;
      for (final layer in front.getLayers()) {
        if (layer.internallayerId.toString() == wanted) {
          setSelection([layer]);
          break;
        }
      }
    } finally {
      _restoring = false;
    }
  }

  /// **A comp can be taken out from under the user.** Pre-compose, step into
  /// the new comp, undo: the layer comes back and the comp it pointed at stops
  /// existing, with the Timeline still fronting it. Every panel then reads a
  /// comp the engine has never heard of, which is what put a bridge error on
  /// screen where the timeline should be.
  ///
  /// So the same rule the layer selection follows (K-238) applies to the
  /// fronted comp: what has gone cannot stay fronted. Where to go instead, in
  /// order — the comp the user was in before this one, if it is still there;
  /// else the nearest open tab, left first and then right; else nothing
  /// fronted at all, which is the state the shell starts in and draws fine.
  void _frontLiveCompIfFrontedOneHasGone() {
    if (!model.compGone) return;
    final gone = _selectedComp!.internalid;
    final known = {
      for (final (comp, _) in _app.comps()) comp.internalid: comp,
    };
    final where = openComps.indexOf(gone);
    final at = where < 0 ? 0 : where;
    openComps.remove(gone);

    // Where the user came from, then leftwards from where the gone tab stood,
    // then rightwards — after the removal the tab that stood at `at` is the
    // right-hand neighbour.
    final order = <UuidValue?>[
      _previousComp,
      for (var i = at - 1; i >= 0; i--) openComps[i],
      for (var i = at; i < openComps.length; i++) openComps[i],
    ];
    CompositionReference? next;
    for (final id in order) {
      final candidate = id == null ? null : known[id];
      // Asked of the engine, not of the cached item walk: the walk is only
      // re-read when the change stream says the tree moved, and this runs on
      // the model's refresh, which can be the earlier of the two. Fronting a
      // comp that is *also* gone would land straight back here.
      if (candidate != null && _stillThere(candidate)) {
        next = candidate;
        break;
      }
    }
    _previousComp = null;
    setSelectedComp(next);
  }

  bool _stillThere(CompositionReference comp) {
    try {
      comp.getSettings();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Drop a comp's tab where [target]'s tab sits. The strip is drawn in this
  /// list's order, so moving the entry is the whole reorder — and it rides
  /// along in the session, like the rest of the tab strip.
  void moveComp(UuidValue id, UuidValue target) {
    final from = openComps.indexOf(id);
    final to = openComps.indexOf(target);
    if (from < 0 || to < 0 || from == to) return;
    openComps.removeAt(from);
    openComps.insert(to, id);
    rememberSession();
    notifyListeners();
  }

  /// Close a comp's Timeline tab. When the closed tab was fronted, [fallback]
  /// — the tab bar's nearest remaining neighbour — fronts instead.
  void closeComp(UuidValue id, {CompositionReference? fallback}) {
    openComps.remove(id);
    if (_selectedComp?.internalid == id) {
      setSelectedComp(fallback);
    } else {
      rememberSession();
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
    // The first-run question (K-246), after the first frame so there is an
    // Overlay to put it in. It asks nothing on any later launch.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ui = context.read<LumitUiState>();
      // The update check follows the question rather than racing it: the
      // setup screen is where somebody may have just switched it off (K-296).
      maybeShowFirstRunFrb(context, ui.workspace)
          .then((_) => ui.maybeCheckForUpdates());
    });
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
          // The tools, under the menu and above everything else — where a
          // toolbar goes, and where docs/07 §1.7 puts it.
          const LumitToolBarFrb(),
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
    if (action == null) {
      // The Tools context is the one context no panel *is* (docs/07 §15 scopes
      // it to the toolbar, not to a pane), so it is asked for separately and
      // only once the focused panel and the app-wide table have both declined.
      // That ordering is what keeps a panel free to claim a letter a tool also
      // uses — `C` cuts a clip in the Timeline and arms the razor everywhere
      // else — without either binding having to know about the other.
      final tool = ui.keymap.actionFor(BridgeKeyContext.tools, event);
      if (tool != null && ui.tools.handleAction(tool)) {
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    // A tool action can also arrive from the primary lookup, if someone rebinds
    // one into a context a panel is. Same handler either way.
    if (ui.tools.handleAction(action)) return KeyEventResult.handled;

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
      case 'palette.open':
        // The menu bar owns the palette's list of commands, so the key asks
        // for it rather than assembling a second one (docs/07 §12).
        ui.requestPalette();
      case 'layer.duplicate':
        final layer = ui.selectedLayer.value;
        if (layer == null) {
          handled = false;
        } else {
          layer.duplicate();
          state.notifyDocumentChanged();
        }
      case 'layer.precompose':
        // Ctrl+Shift+C asks before it packs (docs/07 §13.4): the dialogue is
        // where the two questions live, and the engine call is one line of it.
        final layers = ui.selectedLayers.value;
        if (comp == null || layers.isEmpty) {
          handled = false;
        } else {
          showPrecomposeDialogFrb(
            context: context,
            comp: comp,
            selectedLayers: layers,
            ui: ui,
            workspace: ui.workspace,
          );
        }
      // The rest of the menu bar's own commands (K-244). Each calls the very
      // function its menu row calls, so there is one implementation of "open a
      // project" rather than a keyboard's copy of one.
      case 'file.new':
        state.newProject();
      case 'file.open':
        openProjectFrb(state);
      case 'file.save.as':
        saveProjectFrb(state, ui, forcePicker: true);
      case 'file.import':
        importFootageFrb(state);
      case 'file.export':
        if (comp == null) {
          handled = false;
        } else {
          exportFrb(context);
        }
      case 'comp.new':
        if (project == null) {
          handled = false;
        } else {
          newCompositionFrb(context, state);
        }
      case 'edit.select.all':
        if (comp == null) {
          handled = false;
        } else {
          ui.setSelection(comp.getLayers());
        }
      case 'edit.deselect.all':
        ui.clearSelection();
      case 'app.settings':
        showSettingsWindowFrb(context);
      case 'project.settings':
        if (project == null) {
          handled = false;
        } else {
          showProjectSettingsFrb(context, project);
        }
      case 'file.save':
        // Ctrl+S goes through exactly the same call the File menu's Save does
        // (K-203) — a shortcut with its own path to disk is a second save to
        // keep honest. Without a path yet it opens the picker, which is what
        // Save has always meant on a document that has never been written.
        saveProjectFrb(state, ui);
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
      // Markers (K-254). `Shift+M` (or AE's numpad `*`) drops a plain cue at
      // the playhead; `Ctrl`+digit sets the numbered one and the bare digit
      // returns to it. The numbered pair is the whole point — the key that
      // marks a moment is the key that goes back to it.
      case 'marker.add':
        if (comp == null) {
          handled = false;
        } else {
          addMarkerFrb(comp, frame: ui.playheadFrame.value);
          state.notifyDocumentChanged();
        }
      case final id when id.startsWith('marker.add.'):
        if (comp == null) {
          handled = false;
        } else {
          addMarkerFrb(
            comp,
            frame: ui.playheadFrame.value,
            label: id.substring('marker.add.'.length),
          );
          state.notifyDocumentChanged();
        }
      case final id when id.startsWith('marker.goto.'):
        // Nothing bound to that digit yet is not a failure to report — it is a
        // key that has not been given a meaning. Left unhandled so it still
        // reaches whatever else wants it.
        final at = comp == null
            ? null
            : markerFrameFrb(comp, id.substring('marker.goto.'.length));
        if (at == null) {
          handled = false;
        } else {
          // Through the scrub, so a digit pressed mid-playback lands where it
          // says rather than being overwritten by the next frame that arrives.
          ui.scrubTo(at);
        }
      case 'edit.delete.selection':
        // A panel holding a finer selection than the layer one gets the key
        // first (K-234) — a selected mask row is what Delete is about, not the
        // layer under it.
        if (ui.deleteClaim?.call() ?? false) {
          break;
        }
        // The whole selection, not just the primary (K-217): with several
        // layers boxed in the Viewer, Delete taking one of them would be a
        // surprise every time.
        final layers = ui.selectedLayers.value;
        if (layers.isEmpty) {
          handled = false;
        } else {
          for (final layer in layers) {
            layer.delete();
          }
          ui.clearSelection();
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
