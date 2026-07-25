// Lumit's Flutter frontend (K-174, the frontend alternative experiment).
// The engine stays in the Rust crates; this application is the chrome —
// see docs/flutter-port/ for the plan and the parity checklist.

import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:lumit_flutter/builder/item_builder.dart';
import 'package:lumit_flutter/builder/layer_builder.dart';
import 'package:lumit_flutter/panels/viewer_texture_controller.dart';
import 'package:lumit_flutter/src/rust/api/footage.dart';
import 'package:lumit_flutter/src/rust/api/project.dart';
import 'package:lumit_flutter/src/rust/api/project_item.dart';
import 'package:lumit_flutter/src/rust/api/state.dart';
import 'package:lumit_flutter/src/rust/frb_generated.dart';
import 'package:provider/provider.dart';

import 'bridge/bridge.dart';
import 'shell/shell.dart';
import 'state/workspace.dart';
import 'widgets/ui_scale.dart';

class CustomHandler extends BaseHandler {
  @override
  Future<S> executeNormal<S, E extends Object>(NormalTask<S, E> task) {
    print("Rust Async Call: ${task.argMap}");
    return super.executeNormal(task);
  }

  @override
  S executeSync<S, E extends Object, WireSyncType>(
      SyncTask<S, E, WireSyncType> task) {
    print("Rust Sync Call: ${task.argMap}");
    return super.executeSync(task);
  }
}

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // A popped-out panel runs through this same entrypoint in its own engine
  // (multi-window, same process). If this engine is a popout, it takes over
  // here; otherwise — the main window, or any build without the multi-window
  // plugin — this is a swallowed no-op and the normal shell boots below.

  await BridgeLib.init(handler: CustomHandler());

  // if (await maybeRunPopout(args)) return;
  // final workspace = Workspace()..load();
  // // Try the engine bridge; a null result keeps the F0 placeholder behaviour
  // // (the app and every test must work without the library present).
  // final bridge = LumitBridge.tryLoad();
  var state = LumitState();
  runApp(LumitAppNew(state));
}

class LumitState extends ChangeNotifier {
  ProjectReference? project;

  StreamSubscription? currentDocumentStream;

  final StreamController<ScopedChange> _onChange = StreamController.broadcast();
  final StreamController<WorkerResponse> _onWorkerResponse =
      StreamController.broadcast();

  Stream<ScopedChange> get onChange => _onChange.stream;
  Stream<WorkerResponse> get onWorkerResponse => _onWorkerResponse.stream;

  void newProject() {
    final sink = RustStreamSink<ScopedChange>();
    project = LumitBridgeState.newProject(onChangeStream: sink);

    project?.startWorker();

    currentDocumentStream?.cancel();
    currentDocumentStream = sink.stream.listen(handleChange);

    notifyListeners();
  }

  void openProject(String path) {
    final sink = RustStreamSink<ScopedChange>();
    project = LumitBridgeState.openProject(path: path, onChangeStream: sink);
    final messages = project?.startWorker();
    messages!.listen((msg) => _onWorkerResponse.add(msg));

    currentDocumentStream?.cancel();
    currentDocumentStream = sink.stream.listen(handleChange);

    notifyListeners();
  }

  void handleChange(ScopedChange event) {
    _onChange.add(event);

    // Rebuilds should be handled by LayerBuilder, no need to notify
    if (event.layer != null) return;

    if (event.item != null) return;

    // else, not able to identify scope of this change, rebuild everything!
    print("Rebuilding everything!");
    notifyListeners();
  }
}

class LumitAppNew extends StatelessWidget {
  LumitState state;
  LumitAppNew(this.state, {super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
        theme: ThemeData.dark(),
        home: ChangeNotifierProvider.value(
          value: state,
          child: LumitAppView(),
        ));
  }
}

class LumitAppView extends StatefulWidget {
  const LumitAppView({super.key});

  @override
  State<LumitAppView> createState() => _LumitAppViewState();
}

class _LumitAppViewState extends State<LumitAppView> {
  WorkerResponse_RenderedDMABuf? renderedFrame;
  ViewerTextureController controller = ViewerTextureController();
  StreamSubscription? sub;
  int? frameId;

  @override
  void initState() {
    final store = Provider.of<LumitState>(context, listen: false);

    sub = store.onWorkerResponse.listen((msg) {
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
          if (id != frameId) {
            setState(() {
              print("Frame Id: $id");
              frameId = id;
            });
          }
        });
      }
    });

    super.initState();
  }

  @override
  void dispose() {
    sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var state = context.watch<LumitState>();

    return Column(
      children: [
        if (state.project == null) ...[
          TextButton(
              onPressed: () {
                state.newProject();
              },
              child: Text("New Project")),
          TextButton(
              onPressed: () async {
                const XTypeGroup typeGroup = XTypeGroup(
                  label: 'Lumit File',
                  extensions: <String>['lum'],
                );

                final XFile? file = await openFile(
                  acceptedTypeGroups: <XTypeGroup>[typeGroup],
                );

                state.openProject(file!.path);
              },
              child: Text("Open Project")),
        ],
        if (state.project != null) ...[
          Text(
            "Project: ${state.project!}",
            style: Theme.of(context).textTheme.titleLarge,
          ),
          Row(
            children: [
              TextButton(
                  onPressed: () {
                    state.project?.undo();
                  },
                  child: Text(
                    "Undo",
                    style: Theme.of(context).textTheme.labelMedium,
                  )),
              TextButton(
                  onPressed: () {
                    state.project?.redo();
                  },
                  child: Text(
                    "Redo",
                    style: Theme.of(context).textTheme.labelMedium,
                  ))
            ],
          ),
          if (frameId != null)
            SizedBox(
              height: 200,
              width: 200,
              child: Texture(textureId: frameId!),
            ),
          Expanded(
            child: Container(
                color: ColorScheme.of(context).surfaceContainerLow,
                child: Column(children: [
                  Text(
                    "Items:",
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  ...state.project!.getItems().map((i) => ProjectItemBuilder(
                        item: i,
                        builder: (context) {
                          return buildItem(context, i);
                        },
                      ))
                ])),
          )
        ]
      ],
    );
  }

  static int frame = 161;

  Widget buildItem(BuildContext context, ItemReference item) {
    // since this is just a lookup from the project document, it should be really fast, and is okay to be called sync

    // this is bad: since get status reads from disk, its async and we can build its result with FutureBuilder
    // ideally this could be cached somewhere on rust side

    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Container(
          color: ColorScheme.of(context).surfaceContainer,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(switch (item) {
                ItemReference_Footage() => Icons.video_file,
                ItemReference_Solid() => Icons.square,
                ItemReference_Composition() => Icons.layers,
                ItemReference_Folder() => Icons.folder,
              }),
              if (item case ItemReference_Footage footage) ...[
                FutureBuilder(
                  future: footage.field0.getStatus(),
                  builder: (context, snapshot) {
                    return Icon(switch (snapshot.data) {
                      null => Icons.question_mark,
                      LumitMediaStatus.missing =>
                        Icons.signal_cellular_connected_no_internet_0_bar,
                      LumitMediaStatus.ready => Icons.check,
                    });
                  },
                ),
              ],
              if (item case ItemReference_Composition comp) ...[
                Text(
                  "Layers:",
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                SizedBox(
                  width: 8,
                ),
                TextButton(
                    onPressed: () {
                      print(
                        "Rendering frame: $frame",
                      );
                      comp.field0.renderFrame(frame: BigInt.from(frame));
                      frame += 5;
                    },
                    child: Text(
                      "Render",
                      style: Theme.of(context).textTheme.labelSmall,
                    )),
                Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: comp.field0
                        .getLayers()
                        .map((i) => LayerBuilder(
                              layer: i,
                              builder: (context) {
                                return TextButton(
                                  child: Text(
                                    i.getName(),
                                    style:
                                        Theme.of(context).textTheme.labelSmall,
                                  ),
                                  onPressed: () {
                                    print(i);
                                    i.rename(name: "Renamed layer!");
                                  },
                                );
                              },
                            ))
                        .toList())
              ],
              Text(
                item.name(),
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          )),
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
    // (docs/flutter-port/04 "Why not Material chrome"). Settings → Interface →
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
