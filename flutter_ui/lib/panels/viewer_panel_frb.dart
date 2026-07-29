// The Viewer, on the flutter_rust_bridge API.
//
// A toolbar over the picture: magnification, channel view, the transparency
// grid, the transport and the timecode. The picture itself is whatever the
// render worker last published — always a platform `Texture` on a zero-copy
// path (K-183) — drawn at the chosen zoom over a checkerboard, pannable when
// it is larger than the panel.
//
// **What the overlay does.** The selected layer gets a bounding box with a
// centre handle. Dragging the handle moves the layer: the drag previews through
// `renderFrameWithTransformPreview`, which patches a clone of the document
// engine-side, and commits one `set_transform` pair on release. So dragging in
// the Viewer costs the same one undo step that dragging the number in Effect
// controls does.
//
// **What the transport does, and does not, do.** It says play, stop and seek,
// and it draws whichever frame last arrived. It runs no clock and schedules
// nothing: the engine chooses frames, paces them against the audio, and stops
// itself at the end, and every frame it publishes says which frame it is — so
// the playhead follows the picture rather than predicting it (K-181). This panel
// used to hold a `Ticker` polling the audio clock, an every-frame pump two deep,
// an in-flight counter and a staleness flag, which is a scheduler sitting on the
// far side of an FFI boundary from everything it had to schedule against.
//
// **What is not here.** The scale and rotate gizmo handles, motion paths, masks
// and the shape tools; guides, the region of interest, and the colour-management
// indicator. Recorded in docs/TODO.md — none is blocked on the engine.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/src/rust/api/audio.dart';
import 'package:lumit_flutter/src/rust/api/cache.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:lumit_flutter/src/rust/api/effect.dart';
import 'package:lumit_flutter/src/rust/api/footage.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';
import 'package:lumit_flutter/src/rust/api/project_item.dart';
import 'package:lumit_flutter/src/rust/api/state.dart';
import 'package:provider/provider.dart';

import '../icons/icons.dart';
import '../state/settings.dart';
import '../state/timecode.dart';
import '../theme/theme.dart';
import '../widgets/controls.dart';
import 'placeholder.dart';
import 'viewer_layer_map.dart';

/// The magnifications the picker offers. `null` means fit-to-panel, which is
/// the default and the only one that changes as the panel is resized.
const List<double?> _zoomSteps = [null, 0.25, 0.5, 1.0, 2.0, 4.0];

/// Which channel the picture shows.
enum ViewerChannel { rgb, red, green, blue, alpha }

class ViewerPanelFrb extends StatefulWidget {
  const ViewerPanelFrb({super.key});

  @override
  State<ViewerPanelFrb> createState() => _ViewerPanelFrbState();
}

class _ViewerPanelFrbState extends State<ViewerPanelFrb> {
  double? _zoom;
  ViewerChannel _channel = ViewerChannel.rgb;
  bool _grid = true;
  Offset _pan = Offset.zero;

  /// Edits made anywhere in the document, which are the other reason the
  /// picture has to be asked for again.
  StreamSubscription<ScopedChange>? _changes;

  @override
  void dispose() {
    _unbind();
    _changes?.cancel();
    super.dispose();
  }

  /// Something changed the document: tell the engine, which decides what to do
  /// about it. Every commit comes through here — this panel makes no edits
  /// itself, so there is no local shortcut to take.
  void _onDocumentChanged() => _boundUi?.requestFrame();

  /// The shell's transport intent (the space bar). Subscribed here rather than
  /// exposed as a callback so the key is a quiet no-op when no Viewer is
  /// mounted.
  LumitUiState? _boundUi;

  void _unbind() {
    final ui = _boundUi;
    if (ui == null) return;
    ui.togglePlayRequest.removeListener(_onTogglePlayRequest);
    ui.playheadFrame.removeListener(_onPlayheadChanged);
  }

  void _onTogglePlayRequest() => _togglePlay();

  @override
  Widget build(BuildContext context) {
    final ui = Provider.of<LumitUiState>(context);
    if (!identical(_boundUi, ui)) {
      _unbind();
      _boundUi = ui;
      ui.togglePlayRequest.addListener(_onTogglePlayRequest);
      ui.playheadFrame.addListener(_onPlayheadChanged);
      _changes?.cancel();
      _changes = Provider.of<LumitState>(context, listen: false)
          .onChange
          .listen((_) => _onDocumentChanged());
      // The frame under the playhead as it stands: without this the Viewer
      // shows nothing at all until something moves the playhead. After the
      // frame, so the scale this asks at is the one just measured.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _onPlayheadChanged();
      });
    }
    final comp = ui.selectedComp;
    if (comp == null) {
      return const PlaceholderPanel(
        icon: LumitIcon.footage,
        title: 'Viewer',
        hint: 'Select a composition in the Project panel.',
      );
    }

    final settings = comp.getSettings();
    final t = ThemeScope.of(context).theme;
    final round = t.shape == ThemeShape.round;

    // Both notifiers, because the transport shows two things the engine owns:
    // where the playhead is, and whether it is running.
    final bar = ValueListenableBuilder<bool>(
      valueListenable: ui.playing,
      builder: (context, playing, _) => ValueListenableBuilder<int>(
        valueListenable: ui.playheadFrame,
        builder: (context, frame, _) => _Toolbar(
          zoom: _zoom,
          channel: _channel,
          grid: _grid,
          playing: playing,
          frame: frame,
          settings: settings,
          comp: comp,
          onZoom: (z) => setState(() {
            _zoom = z;
            _pan = Offset.zero;
          }),
          onChannel: (c) => setState(() => _channel = c),
          onGrid: () => setState(() => _grid = !_grid),
          onPlayPause: _togglePlay,
          onSeek: (f) => _seek(comp, ui, f),
          floating: round,
        ),
      ),
    );

    final stage = Expanded(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = comp.getSize();
          final fitted = _fittedRect(constraints, size);
          _reportScale(ui, fitted, size);

          // Which layers might be missing their file — read here, once per
          // panel rebuild, NOT inside the playhead builder below. It used to
          // live in the stage, which rebuilds per frame during playback, so
          // `getLayers` plus a `getSourceItem` per layer crossed the bridge
          // sixty times a second to re-answer a question edits change and
          // playback never does.
          final footage = <FootageReference>[
            for (final layer in comp.getLayers())
              if (layer.getSourceItem()
                  case ItemReference_Footage(:final field0))
                field0,
          ];

          return Listener(
            // The wheel zooms about the cursor (docs/07 §2.2): the comp point
            // under the pointer stays under the pointer, which is what makes
            // zooming feel like leaning in rather than teleporting.
            onPointerSignal: (event) {
              if (event is PointerScrollEvent) {
                _scrollZoom(event.localPosition, event.scrollDelta.dy,
                    constraints, size, fitted);
              }
            },
            child: ValueListenableBuilder<int>(
              valueListenable: ui.playheadFrame,
              builder: (context, frame, _) => _Stage(
                comp: comp,
                uiState: ui,
                fitted: fitted,
                grid: _grid,
                channel: _channel,
                footage: footage,
                onPan: (delta) => setState(() => _pan += delta),
                onChanged: () => setState(() {}),
              ),
            ),
          );
        },
      ),
    );

    // The transport belongs under the picture, where a transport goes. In round
    // mode it is a detached bar floating over the bottom of the frame — the
    // rounded language treats it as an object sitting on the picture rather
    // than a strip welded to the panel edge; sharp mode keeps it attached, so
    // the two shapes read as two deliberate designs rather than one with a gap.
    return round
        ? Stack(
            children: [
              Positioned.fill(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [stage],
                ),
              ),
              Positioned(
                left: t.tokens.windowInset,
                right: t.tokens.windowInset,
                bottom: t.tokens.windowInset,
                child: bar,
              ),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [stage, bar],
          );
  }

  /// Where the picture sits in the panel, at the current magnification.
  ///
  /// Fit is the default and the only mode that follows the panel; a fixed
  /// magnification draws at that multiple of comp resolution and pans, which is
  /// what "100%" has to mean for it to be worth having.
  Rect _fittedRect(BoxConstraints constraints, BridgeCompSize size) {
    final w = size.width.toDouble();
    final h = size.height.toDouble();
    if (w <= 0 || h <= 0) return Rect.zero;

    final scale = _zoom ??
        (constraints.maxWidth / w < constraints.maxHeight / h
            ? constraints.maxWidth / w
            : constraints.maxHeight / h);
    final drawn = Size(w * scale, h * scale);
    final centre = Offset(
      (constraints.maxWidth - drawn.width) / 2,
      (constraints.maxHeight - drawn.height) / 2,
    );
    return (centre + _pan) & drawn;
  }

  /// One wheel notch is ~12 % in or out, smooth on a trackpad (the delta is
  /// per-pixel there), anchored so the comp point under the cursor does not
  /// move: solve the new pan from `cursor = topLeft' + u·s'` where `u` is the
  /// comp point currently under the cursor.
  void _scrollZoom(Offset cursor, double dy, BoxConstraints constraints,
      BridgeCompSize size, Rect fitted) {
    if (size.width == 0 || fitted.width <= 0) return;
    final s1 = fitted.width / size.width;
    final s2 = (s1 * math.pow(1.0012, -dy)).clamp(0.02, 32.0).toDouble();
    if (s2 == s1) return;
    final u = (cursor - fitted.topLeft) / s1;
    final topLeft = cursor - u * s2;
    final centre = Offset(
      (constraints.maxWidth - size.width * s2) / 2,
      (constraints.maxHeight - size.height * s2) / 2,
    );
    setState(() {
      _zoom = s2;
      _pan = topLeft - centre;
    });
  }

  /// Tell the engine what fraction of comp resolution is on screen, so the next
  /// render asks for that much and no more.
  void _reportScale(LumitUiState state, Rect fitted, BridgeCompSize size) {
    if (size.width == 0) return;
    state.reportViewerScale(fitted.width / size.width);
  }

  /// The playhead moved — from anywhere. The Timeline ruler, an arrow key and
  /// the transport all just set it, and this is what tells the engine.
  ///
  /// It is only ever *told*: moving the playhead is the user's own gesture and
  /// happens the instant they make it, with no round trip to wait on. What
  /// happens next — which frame to render, whether the one in flight is now
  /// worthless — is the engine's to decide.
  void _onPlayheadChanged() => _boundUi?.requestFrame();

  /// Move the playhead, taking the sound with it. Seeking while playing keeps
  /// playing, which is what makes scrubbing during playback usable rather than
  /// a stutter.
  void _seek(CompositionReference comp, LumitUiState state, int frame) {
    final last = comp.durationFrames() - 1;
    state.playheadFrame.value = frame.clamp(0, last < 0 ? 0 : last);
    audioSeek(secs: state.playheadFrame.value / comp.fps());
  }

  /// Start or stop playback. Two calls, because that is all a transport is:
  /// the clock, the frame choice, the sound and the end of the composition are
  /// all the engine's (K-181).
  void _togglePlay() {
    final ui = _boundUi;
    if (ui == null) return;
    ui.playing.value ? ui.stopPlayback() : ui.play();
  }
}

/// What is painted around the picture (K-203).
///
/// Neutral by default, and deliberately so: a grade cannot be judged against a
/// tinted surround, which is why the theme carries `viewerSurround` as a grey
/// no scheme colours (docs/15-DESIGN §2.1/§11). The Appearance toggle exists
/// because a neutral rectangle in the middle of a themed shell is something
/// people reasonably want to switch off — the same shape of answer the scopes
/// toggle gives.
Color viewerSurroundFor(LumitTheme t, {bool themed = false}) =>
    themed ? t.surface0 : t.viewerSurround;

/// The picture, its checkerboard, and the selection overlay.
class _Stage extends StatelessWidget {
  final CompositionReference comp;
  final LumitUiState uiState;
  final Rect fitted;
  final bool grid;
  final ViewerChannel channel;

  /// The comp's footage layers' sources, read by the panel once per rebuild —
  /// not here, where playback would re-read them per frame.
  final List<FootageReference> footage;
  final ValueChanged<Offset> onPan;
  final VoidCallback onChanged;

  const _Stage({
    required this.comp,
    required this.uiState,
    required this.fitted,
    required this.grid,
    required this.channel,
    required this.footage,
    required this.onPan,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // Panning the picture, not the layer: the overlay's own handle takes the
      // gesture first when it is hit, so this only fires on empty space.
      onPanUpdate: (d) => onPan(d.delta),
      child: Container(
        color: viewerSurroundFor(
          t,
          themed: uiState.workspace.themedViewerSurround,
        ),
        child: Stack(
          children: [
            if (grid)
              Positioned.fromRect(
                rect: fitted,
                child: CustomPaint(painter: _CheckerPainter(t)),
              ),
            Positioned.fromRect(
              rect: fitted,
              child: _Picture(uiState: uiState, channel: channel),
            ),
            _missingSlate(context, t),
            _SelectionOverlay(
              comp: comp,
              uiState: uiState,
              fitted: fitted,
              onChanged: onChanged,
            ),
          ],
        ),
      ),
    );
  }

  /// A notice when a footage layer in this comp has lost its file. The probe
  /// itself happens in the badge; this only places it.
  Widget _missingSlate(BuildContext context, LumitTheme t) {
    if (footage.isEmpty) return const SizedBox.shrink();
    return Positioned(
      left: 8,
      bottom: 8,
      child: _MissingBadge(footage: footage),
    );
  }
}

/// The badge that appears only once a probe has actually found a file gone.
class _MissingBadge extends StatefulWidget {
  final List<FootageReference> footage;
  const _MissingBadge({required this.footage});

  @override
  State<_MissingBadge> createState() => _MissingBadgeState();
}

class _MissingBadgeState extends State<_MissingBadge> {
  int _missing = 0;

  @override
  void initState() {
    super.initState();
    _probe();
  }

  @override
  void didUpdateWidget(_MissingBadge old) {
    super.didUpdateWidget(old);
    if (old.footage.length != widget.footage.length) _probe();
  }

  Future<void> _probe() async {
    var count = 0;
    for (final f in widget.footage) {
      if (await f.getStatus() == LumitMediaStatus.missing) count++;
    }
    if (mounted && count != _missing) setState(() => _missing = count);
  }

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    if (_missing == 0) return const SizedBox.shrink();
    return Container(
      key: const ValueKey('viewer-missing'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: t.surface2,
        borderRadius: BorderRadius.circular(t.tokens.controlRadius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          lumitIcon(LumitIcon.unlink, size: 12, color: t.warning),
          const SizedBox(width: 6),
          Text(
            '$_missing missing file${_missing == 1 ? '' : 's'}',
            style: t.small.copyWith(color: t.warning),
          ),
        ],
      ),
    );
  }
}

/// Whatever the worker last published, in the chosen channel — always a
/// platform texture (K-183): frames only ever arrive as GPU handles.
class _Picture extends StatelessWidget {
  final LumitUiState uiState;
  final ViewerChannel channel;
  const _Picture({required this.uiState, required this.channel});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int?>(
      valueListenable: uiState.viewerFrameid,
      builder: (context, textureId, _) {
        final picture = textureId != null
            ? Texture(textureId: textureId)
            : const SizedBox.expand();
        final filter = channelFilterFor(channel);
        return filter == null
            ? picture
            : ColorFiltered(colorFilter: filter, child: picture);
      },
    );
  }
}

/// The matrix that isolates one channel, or null for the full picture.
///
/// A single channel is shown as grey rather than tinted — the point of looking
/// at one is to judge its *values*, and a red picture is harder to read than a
/// grey one. Alpha is copied into all three, which is what makes a matte
/// legible.
ColorFilter? channelFilterFor(ViewerChannel channel) => switch (channel) {
      ViewerChannel.rgb => null,
      ViewerChannel.red => const ColorFilter.matrix(<double>[
          1, 0, 0, 0, 0, //
          1, 0, 0, 0, 0, //
          1, 0, 0, 0, 0, //
          0, 0, 0, 0, 255,
        ]),
      ViewerChannel.green => const ColorFilter.matrix(<double>[
          0, 1, 0, 0, 0, //
          0, 1, 0, 0, 0, //
          0, 1, 0, 0, 0, //
          0, 0, 0, 0, 255,
        ]),
      ViewerChannel.blue => const ColorFilter.matrix(<double>[
          0, 0, 1, 0, 0, //
          0, 0, 1, 0, 0, //
          0, 0, 1, 0, 0, //
          0, 0, 0, 0, 255,
        ]),
      ViewerChannel.alpha => const ColorFilter.matrix(<double>[
          0, 0, 0, 1, 0, //
          0, 0, 0, 1, 0, //
          0, 0, 0, 1, 0, //
          0, 0, 0, 0, 255,
        ]),
    };

/// The selected layer's bounding box, and the handle that moves it.
class _SelectionOverlay extends StatefulWidget {
  final CompositionReference comp;
  final LumitUiState uiState;
  final Rect fitted;
  final VoidCallback onChanged;

  const _SelectionOverlay({
    required this.comp,
    required this.uiState,
    required this.fitted,
    required this.onChanged,
  });

  @override
  State<_SelectionOverlay> createState() => _SelectionOverlayState();
}

class _SelectionOverlayState extends State<_SelectionOverlay> {
  Offset _drag = Offset.zero;

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final layer = widget.uiState.selectedLayer.value;
    if (layer == null || widget.fitted.isEmpty) {
      return const SizedBox.shrink();
    }

    final size = widget.comp.getSize();
    final map = _mapFor(layer, size);
    if (map == null) return const SizedBox.shrink();

    // The handle sits on the layer's position — the point a move actually
    // moves — rather than on the box's middle, which is the anchor's business.
    final centre = map.toScreen(map.ax, map.ay) + _drag;

    return Stack(
      children: [
        Positioned.fromRect(
          rect: widget.fitted,
          child: IgnorePointer(
            child: CustomPaint(
              painter: _BoxPainter(
                map: map,
                size: size,
                origin: widget.fitted.topLeft,
                colour: t.accent,
                nudge: _drag,
              ),
            ),
          ),
        ),
        Positioned(
          left: centre.dx - 7,
          top: centre.dy - 7,
          child: GestureDetector(
            key: const ValueKey('viewer-move-handle'),
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => setState(() => _drag = Offset.zero),
            onPanUpdate: (d) {
              setState(() => _drag += d.delta);
              _preview(layer, map);
            },
            onPanEnd: (_) => _commit(layer, map),
            onPanCancel: () => setState(() => _drag = Offset.zero),
            child: SizedBox(
              width: 14,
              height: 14,
              child: CustomPaint(painter: _HandlePainter(t.accent)),
            ),
          ),
        ),
      ],
    );
  }

  /// The layer↔screen map, or null when the layer's transform is animated in a
  /// way this overlay cannot represent as a single position.
  ViewerLayerMap? _mapFor(LayerReference layer, BridgeCompSize size) {
    final tf = layer.getTransform();
    double? still(BridgeScalar s) => s is BridgeScalar_Static ? s.field0 : null;

    final px = still(tf.positionX);
    final py = still(tf.positionY);
    if (px == null || py == null) return null;

    return ViewerLayerMap.of(
      positionX: px,
      positionY: py,
      anchorX: still(tf.anchorX) ?? 0,
      anchorY: still(tf.anchorY) ?? 0,
      scaleXPercent: still(tf.scaleX) ?? 100,
      scaleYPercent: still(tf.scaleY) ?? 100,
      rotationDegrees: still(tf.rotation) ?? 0,
      origin: widget.fitted.topLeft,
      viewScale: size.width == 0 ? 1 : widget.fitted.width / size.width,
    );
  }

  /// Comp-pixel position for the current drag.
  (double, double) _moved(ViewerLayerMap map) => (
        map.px + _drag.dx / map.viewScale,
        map.py + _drag.dy / map.viewScale,
      );

  void _preview(LayerReference layer, ViewerLayerMap map) {
    final (x, y) = _moved(map);
    final tf = layer.getTransform();
    widget.comp.renderFrameWithTransformPreview(
      frame: BigInt.from(widget.uiState.playheadFrame.value),
      scale: widget.uiState.viewerScale,
      layer: layer,
      transform: BridgeTransform(
        anchorX: tf.anchorX,
        anchorY: tf.anchorY,
        positionX: BridgeScalar.static_(x),
        positionY: BridgeScalar.static_(y),
        positionZ: tf.positionZ,
        scaleX: tf.scaleX,
        scaleY: tf.scaleY,
        rotation: tf.rotation,
        rotationX: tf.rotationX,
        rotationY: tf.rotationY,
        opacity: tf.opacity,
      ),
    );
  }

  /// Two ops, because x and y are separate properties in the model — an
  /// unavoidable pair, and the one place in this port where a single gesture is
  /// not a single undo step. Recorded in docs/TODO.md.
  void _commit(LayerReference layer, ViewerLayerMap map) {
    final (x, y) = _moved(map);
    final moved = _drag != Offset.zero;
    setState(() => _drag = Offset.zero);
    if (!moved) return;

    layer.setTransform(
        prop: BridgeTransformProp.positionX, value: BridgeScalar.static_(x));
    layer.setTransform(
        prop: BridgeTransformProp.positionY, value: BridgeScalar.static_(y));
    widget.onChanged();
  }
}

/// The selected layer's outline, at comp size through its own transform.
class _BoxPainter extends CustomPainter {
  final ViewerLayerMap map;
  final BridgeCompSize size;
  final Offset origin;
  final Color colour;
  final Offset nudge;

  const _BoxPainter({
    required this.map,
    required this.size,
    required this.origin,
    required this.colour,
    required this.nudge,
  });

  @override
  void paint(Canvas canvas, Size canvasSize) {
    // Layer space is the comp's own pixel grid for every kind the Viewer can
    // outline today, so the box is the comp rectangle put through the layer's
    // transform.
    final w = size.width.toDouble();
    final h = size.height.toDouble();
    final corners = [
      map.toScreen(0, 0),
      map.toScreen(w, 0),
      map.toScreen(w, h),
      map.toScreen(0, h),
    ].map((p) => p - origin + nudge).toList();

    final path = Path()..addPolygon(corners, true);
    canvas.drawPath(
      path,
      Paint()
        ..color = colour
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_BoxPainter old) => true;
}

class _HandlePainter extends CustomPainter {
  final Color colour;
  const _HandlePainter(this.colour);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawCircle(
      size.center(Offset.zero),
      size.width / 2 - 1,
      Paint()
        ..color = colour
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_HandlePainter old) => old.colour != colour;
}

/// The transparency checkerboard behind the picture.
class _CheckerPainter extends CustomPainter {
  final LumitTheme theme;
  const _CheckerPainter(this.theme);

  static const double _square = 8;

  @override
  void paint(Canvas canvas, Size size) {
    final light = Paint()..color = theme.surface2;
    final dark = Paint()..color = theme.surface1;
    canvas.drawRect(Offset.zero & size, dark);
    for (var y = 0.0; y < size.height; y += _square) {
      for (var x = 0.0; x < size.width; x += _square) {
        final odd = ((x / _square).floor() + (y / _square).floor()).isOdd;
        if (odd) continue;
        canvas.drawRect(Rect.fromLTWH(x, y, _square, _square), light);
      }
    }
  }

  @override
  bool shouldRepaint(_CheckerPainter old) => old.theme != theme;
}

/// Magnification, channel, grid, transport and timecode.
class _Toolbar extends StatelessWidget {
  final double? zoom;
  final ViewerChannel channel;
  final bool grid;
  final bool playing;
  final int frame;
  final BridgeCompSettings settings;
  final CompositionReference comp;
  final ValueChanged<double?> onZoom;
  final ValueChanged<ViewerChannel> onChannel;
  final VoidCallback onGrid;
  final VoidCallback onPlayPause;
  final ValueChanged<int> onSeek;

  /// Drawn as a detached bar over the picture (round mode) rather than a strip
  /// filling the panel's width (sharp mode).
  final bool floating;

  const _Toolbar({
    required this.zoom,
    required this.channel,
    required this.grid,
    required this.playing,
    required this.frame,
    required this.settings,
    required this.comp,
    required this.onZoom,
    required this.onChannel,
    required this.onGrid,
    required this.onPlayPause,
    required this.onSeek,
    this.floating = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final tier = comp.playbackTier();
    return Container(
      height: 26,
      decoration: BoxDecoration(
        color: t.surface1,
        borderRadius:
            floating ? BorderRadius.circular(t.tokens.floatRadius) : null,
        border: floating ? Border.all(color: t.hairline) : null,
        boxShadow: floating ? t.tokens.cardShadow : null,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      // Scrolls rather than overflowing: a Viewer docked narrow has less width
      // than this bar wants, and an overflow stripe is not a design.
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            SizedBox(
              width: 76,
              child: BareDropdown<int>(
                key: const ValueKey('viewer-zoom'),
                // -1: a wheel zoom between the listed steps; the button shows
                // the true percentage and the menu still offers the steps.
                value: _zoomSteps.indexOf(zoom),
                options: [for (var i = 0; i < _zoomSteps.length; i++) i],
                label: (i) => i == -1
                    ? '${((zoom ?? 1) * 100).round()}%'
                    : _zoomSteps[i] == null
                        ? 'Fit'
                        : '${(_zoomSteps[i]! * 100).round()}%',
                onChanged: (i) => onZoom(_zoomSteps[i]),
              ),
            ),
            const SizedBox(width: 6),
            SizedBox(
              width: 76,
              child: BareDropdown<ViewerChannel>(
                key: const ValueKey('viewer-channel'),
                value: channel,
                options: ViewerChannel.values,
                label: _channelLabel,
                onChanged: onChannel,
              ),
            ),
            const SizedBox(width: 6),
            LumitTooltip(
              message: 'Show the transparency grid behind the picture',
              child: HouseButton(
                key: const ValueKey('viewer-grid'),
                small: true,
                frameless: true,
                onPressed: onGrid,
                child: Text('Grid',
                    style: t.small.copyWith(color: grid ? t.accent : null)),
              ),
            ),
            const SizedBox(width: 6),
            _PlaybackModeButton(comp: comp),
            // A fixed gap, not a Spacer: the bar scrolls when the panel is
            // narrow, and a flex child cannot live inside a scroll view.
            const SizedBox(width: 24),
            HouseButton(
              key: const ValueKey('viewer-home'),
              small: true,
              frameless: true,
              onPressed: () => onSeek(0),
              child: Text('|◀', style: t.small),
            ),
            HouseButton(
              key: const ValueKey('viewer-step-back'),
              small: true,
              frameless: true,
              onPressed: () => onSeek(frame - 1),
              child: Text('◀', style: t.small),
            ),
            HouseButton(
              key: const ValueKey('viewer-play'),
              small: true,
              onPressed: onPlayPause,
              child: lumitIcon(playing ? LumitIcon.pause : LumitIcon.play,
                  size: 12, color: t.textPrimary),
            ),
            HouseButton(
              key: const ValueKey('viewer-step-forward'),
              small: true,
              frameless: true,
              onPressed: () => onSeek(frame + 1),
              child: Text('▶', style: t.small),
            ),
            HouseButton(
              key: const ValueKey('viewer-end'),
              small: true,
              frameless: true,
              onPressed: () => onSeek(comp.durationFrames() - 1),
              child: Text('▶|', style: t.small),
            ),
            const SizedBox(width: 8),
            Text(
              timecodeOf(frame, settings),
              key: const ValueKey('viewer-timecode'),
              style: t.mono,
            ),
            // The degradation badge (docs/13 §B5, docs/07 §2.2): when adaptive
            // playback has dropped below Full, say so on the bar — a softer
            // picture must never be a mystery. Reading the tier is one atomic;
            // this bar already rebuilds per shown frame.
            if (playing && tier > 1) ...[
              const SizedBox(width: 8),
              Container(
                key: const ValueKey('viewer-tier-badge'),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: t.surface2,
                  borderRadius: BorderRadius.circular(t.tokens.controlRadius),
                ),
                child: Text(
                  _PlaybackModeButton._tierNames[tier.clamp(0, 4)],
                  style: t.small.copyWith(color: t.warning),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _channelLabel(ViewerChannel c) => switch (c) {
        ViewerChannel.rgb => 'RGB',
        ViewerChannel.red => 'Red',
        ViewerChannel.green => 'Green',
        ViewerChannel.blue => 'Blue',
        ViewerChannel.alpha => 'Alpha',
      };
}

/// `HH:MM:SS:FF` for `frame` at the comp's rate — the shared clock face in
/// state/timecode.dart, bound to this comp's settings.
String timecodeOf(int frame, BridgeCompSettings settings) =>
    timecodeOfRate(frame, settings.fpsNum, settings.fpsDen);

/// Which playback behaviour is in force, and a click to change it.
///
/// **Why this is on the bar rather than buried in Settings.** The two modes
/// disagree about what playback *is* — one keeps time and lets the picture go
/// soft, the other shows every frame and takes as long as it takes — so a
/// picture that looks wrong or a transport that runs slow is explained by which
/// one you are in. Being unable to see that from the Viewer is what makes it
/// feel broken rather than chosen.
///
/// In adaptive mode the tier it has settled on is shown beside the name, so
/// "why is it soft?" is answered on screen: Full, Half, Third or Quarter.
class _PlaybackModeButton extends StatelessWidget {
  final CompositionReference comp;
  const _PlaybackModeButton({required this.comp});

  static const _tierNames = ['Full', 'Full', 'Half', 'Third', 'Quarter'];

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final ui = Provider.of<LumitUiState>(context);
    final adaptive = ui.workspace.performance.playback == PlaybackMode.adaptive;
    final tier = comp.playbackTier();
    final label = adaptive
        ? 'Adaptive · ${_tierNames[tier.clamp(0, _tierNames.length - 1)]}'
        : 'Every frame';

    // Which route frames take to get here. A build without a zero-copy path
    // copies every pixel down, serialises it a byte at a time and uploads it
    // again, which is the difference between playback feeling immediate and
    // feeling heavy — so it is worth being able to read off the screen.
    final transport = switch (viewerTransport()) {
      BridgeViewerTransport.sharedTexture => 'shared texture, no copy',
      BridgeViewerTransport.dmaBuf => 'DMA-BUF, no copy',
      BridgeViewerTransport.readBack => 'read-back (pixels copied)',
    };

    return LumitTooltip(
      message: adaptive
          ? 'Playback keeps time and lowers the resolution when it has to. '
              'Click for every frame instead. '
              'Frames arrive by $transport.'
          : 'Playback shows every frame at full resolution and caches it, '
              'however long that takes, with the sound silenced. '
              'Click for adaptive instead. '
              'Frames arrive by $transport.',
      child: HouseButton(
        key: const ValueKey('viewer-playback-mode'),
        small: true,
        onPressed: () {
          ui.workspace.performance.playback =
              adaptive ? PlaybackMode.everyFrame : PlaybackMode.adaptive;
          ui.workspace.touch();
        },
        child: Text(
          label,
          style: t.small.copyWith(color: adaptive ? null : t.accent),
        ),
      ),
    );
  }
}
