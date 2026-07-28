// The Timeline panel, on the flutter_rust_bridge API.
//
// Two columns side by side over one shared time axis: an **outline** on the
// left (layer number, label chip, name, switches, blend mode, parent) and a
// **layer area** on the right (the ruler, the playhead, one bar per layer, the
// work area and the markers). Everything draws from the comp read model
// (state/comp_model.dart, K-184); edits go out through the reference handles.
//
// **What is here.** Adding every layer kind, deleting, duplicating, reordering,
// the eight switches, blend mode, parenting, dragging and trimming a layer's
// bar, scrubbing the playhead, the work area and marker cues.
//
// The **Graph** button swaps the layer area for the graph editor
// (graph_editor_frb.dart), which shapes the selected layer's curves.
//
// **The one rule the drags follow.** A bar drag is a live *preview* of nothing —
// unlike an effect or transform drag there is no cheap render to show, because
// moving a layer in time changes what every frame contains. So a bar drag holds
// its offset in Dart and commits one `set_span` on release: one op, one undo
// step, even when the gesture moved the in point and the start offset together.

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:lumit_flutter/src/rust/api/effect.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';
import 'package:provider/provider.dart';

import '../icons/icons.dart';
import '../state/drag_payloads.dart';
import '../theme/theme.dart';
import '../widgets/controls.dart';
import 'placeholder.dart';
import 'graph_editor_frb.dart';
import 'timeline_extras_frb.dart';
import 'effect_param_row_frb.dart';
import 'keyframe_controls_frb.dart';
import 'layer_fold_frb.dart';
import 'transform_rows_frb.dart';

/// The blend-mode names, fetched once per session: the list is static for the
/// life of the process, and every outline row was re-fetching it per rebuild.
List<String>? _blendModes;

/// The outline column's width. Wide enough for the number, four switches, a
/// name worth reading, and the blend and parent pickers side by side — about
/// what After Effects gives its own outline. Fixed rather than resizable for
/// now: a splitter is its own slice of work and nothing depends on it yet.
const double _outlineWidth = 560;

/// One layer row's height, and the ruler's.
const double _rowHeight = 22;
const double _rulerHeight = 20;

/// How near the end of a bar counts as grabbing its edge to trim rather than its
/// middle to move.
const double _trimGrab = 6;

class TimelinePanelFrb extends StatefulWidget {
  const TimelinePanelFrb({super.key});

  @override
  State<TimelinePanelFrb> createState() => _TimelinePanelFrbState();
}

class _TimelinePanelFrbState extends State<TimelinePanelFrb> {
  /// What is twirled open: layer ids, and the paths of the groups under them
  /// (`<layer>/transform`, `<layer>/effects/<effect>`, `<layer>/audio`). Held by
  /// the panel rather than by each row so the lane side can leave room for
  /// exactly the rows the outline draws — the two halves are one table, and a
  /// name that does not line up with its bar is worse than no fold-out at all.
  final Set<String> _open = {};

  /// Which layers' sources carry sound, by id. Cached because answering it
  /// probes the file with FFmpeg, which must never happen in a build — the same
  /// reason the Project panel caches missing media. Absent means "not asked
  /// yet", and a layer with no entry simply shows no Audio group until the
  /// answer arrives.
  final Map<String, bool> _hasAudio = {};

  /// Each layer's source waveform peaks, by id — fetched once when its
  /// Waveform twirl first opens (decoding a whole track is not work for a
  /// build), then good for the session: peaks belong to the file, so trims
  /// and drags never invalidate them (K-172).
  final Map<String, BridgeAudioPeaks> _peaks = {};

  /// One lane's worth of buckets: plenty for any panel width.
  static const int _peakBuckets = 2048;

  /// Fetch peaks for any layer whose Waveform twirl is open and unanswered.
  void _refreshPeaks(List<BridgeLayerEntry> layers) {
    for (final entry in layers) {
      final id = entry.layer.internallayerId.toString();
      if (!_open.contains(waveformPath(id)) || _peaks.containsKey(id)) {
        continue;
      }
      // Claim the slot first, so a rebuild mid-decode does not decode twice.
      _peaks[id] = BridgeAudioPeaks(durationSeconds: 0, pairs: Float32List(0));
      entry.layer.audioPeaks(buckets: _peakBuckets).then((peaks) {
        if (!mounted) return;
        setState(() => _peaks[id] = peaks);
      });
    }
  }

  void _toggle(String path) => setState(() {
        if (!_open.remove(path)) _open.add(path);
      });

  /// Fill in any layer's has-audio answer we do not have, off the build.
  void _refreshAudio(List<BridgeLayerEntry> layers) {
    for (final entry in layers) {
      final id = entry.layer.internallayerId.toString();
      if (_hasAudio.containsKey(id)) continue;
      // Claim the slot first, so a rebuild mid-probe does not probe twice.
      _hasAudio[id] = false;
      entry.layer.hasAudio().then((has) {
        if (!mounted || _hasAudio[id] == has) return;
        setState(() => _hasAudio[id] = has);
      });
    }
  }

  String _search = '';

  /// The layer whose fold-out was last touched — drawn a shade dimmer than
  /// the selected layer, so "which layer do these rows belong to" has an
  /// answer at a glance without stealing the selection.
  String? _highlighted;

  /// The graph editor replaces the layer area rather than sitting beside it:
  /// the two want the same width, and a curve squeezed into half a panel is not
  /// a curve you can shape.
  bool _graph = false;

  /// With the razor armed, a click on a bar cuts it rather than selecting it.
  /// Modal on purpose — it is how every editor does the tool, and it is the one
  /// gesture where "what does a click do here" has two answers.
  bool _razor = false;

  @override
  Widget build(BuildContext context) {
    final ui = Provider.of<LumitUiState>(context);
    final comp = ui.selectedComp;
    if (comp == null) {
      return const PlaceholderPanel(
        icon: LumitIcon.comp,
        title: 'Timeline',
        hint: 'Select a composition in the Project panel.',
      );
    }

    // Everything this panel draws comes from the read model (K-184): zero
    // bridge calls per rebuild. The ListenableBuilder repaints the panel when
    // the model refreshes — which happens once per committed change.
    return ListenableBuilder(
      listenable: ui.model,
      builder: (context, _) => _body(context, ui, comp),
    );
  }

  Widget _body(
      BuildContext context, LumitUiState ui, CompositionReference comp) {
    final frames = ui.model.durationFrames;
    final needle = _search.trim().toLowerCase();
    final layers = needle.isEmpty
        ? ui.model.layers
        : [
            for (final e in ui.model.layers)
              if (e.info.name.toLowerCase().contains(needle)) e,
          ];
    _refreshAudio(layers);
    _refreshPeaks(layers);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CompTabsFrb(
          state: Provider.of<LumitState>(context, listen: false),
          uiState: ui,
        ),
        _Toolbar(
          comp: comp,
          graph: _graph,
          onToggleGraph: () => setState(() => _graph = !_graph),
          razor: _razor,
          playheadFrame: () => ui.playheadFrame.value,
          onToggleRazor: () => setState(() => _razor = !_razor),
          onSearch: (v) => setState(() => _search = v),
          onChanged: ui.model.refresh,
        ),
        Expanded(
          // Dropping footage from the Project panel adds it as a layer. The
          // target wraps the whole body — outline and layer area both — because
          // "onto the Timeline" is what the gesture means; asking the user to
          // hit one half of it would be a rule with no reason behind it.
          child: DragTarget<FootageDragData>(
            onAcceptWithDetails: (details) {
              // Bottom-up, so a multi-item drop stacks in the order the panel
              // listed them: each lands at the top of the stack.
              for (final f in details.data.footage.reversed) {
                comp.addFootageLayer(footage: f);
              }
              ui.model.refresh();
            },
            builder: (context, candidate, _) => Container(
              // A live outline while something is over it, so the drop is
              // visibly going to land rather than being taken on faith.
              foregroundDecoration: candidate.isEmpty
                  ? null
                  : BoxDecoration(
                      border: Border.all(
                          color: ThemeScope.of(context).theme.accent, width: 2),
                    ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // A panel narrower than the outline's columns shows a
                  // horizontally-scrolling slice of them rather than the
                  // overflow stripe — the same answer the Timeline toolbar
                  // gives — keeping the lanes at least a working sliver.
                  final outlineViewport =
                      (constraints.maxWidth - 120).clamp(120.0, _outlineWidth);
                  // The axis is the panel's own width minus the outline, so a
                  // narrower panel shows the same span more tightly rather than
                  // scrolling — matching the Viewer's fit-to-panel behaviour.
                  final layerAreaWidth =
                      (constraints.maxWidth - outlineViewport).clamp(1.0, 1e6);
                  final axis = _Axis(frames: frames, width: layerAreaWidth);

                  // **Not** wrapped in a playhead listener. Every layer row and
                  // every bar used to rebuild each time the playhead moved —
                  // sixty times a second during playback, growing with the layer
                  // count, and asking the engine for each layer's name and span
                  // again every time. Only two things actually care where the
                  // playhead is: the line itself, and the razor (which reads it
                  // when clicked). Both listen for themselves now.
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: outlineViewport,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: SizedBox(
                            width: _outlineWidth,
                            child: _Outline(
                              comp: comp,
                              layers: layers,
                              selected: ui.selectedLayer.value,
                              highlighted: _highlighted,
                              open: _open,
                              hasAudio: _hasAudio,
                              onToggle: _toggle,
                              playheadFrame: ui.playheadFrame.value,
                              onSeek: (f) => ui.playheadFrame.value = f,
                              onSelect: (l) => setState(() {
                                ui.selectedLayer.value = l;
                              }),
                              onHighlight: (id) =>
                                  setState(() => _highlighted = id),
                              onChanged: ui.model.refresh,
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: _graph
                            // The graph draws the playhead through its own
                            // curves, so it does still redraw on every move.
                            ? ValueListenableBuilder<int>(
                                valueListenable: ui.playheadFrame,
                                builder: (context, playhead, _) =>
                                    GraphEditorFrb(
                                  comp: comp,
                                  layer: ui.selectedLayer.value,
                                  frames: frames,
                                  playheadFrame: playhead,
                                  onSeek: (f) => ui.playheadFrame.value = f,
                                  onChanged: ui.model.refresh,
                                ),
                              )
                            : _LayerArea(
                                comp: comp,
                                layers: layers,
                                open: _open,
                                hasAudio: _hasAudio,
                                peaks: _peaks,
                                fps: ui.model.fps,
                                axis: axis,
                                playhead: ui.playheadFrame,
                                razor: _razor,
                                onSeek: (f) => ui.playheadFrame.value =
                                    f.clamp(0, frames == 0 ? 0 : frames - 1),
                                onSelect: (l) => setState(() {
                                  ui.selectedLayer.value = l;
                                }),
                                onChanged: ui.model.refresh,
                                cacheRevision: Listenable.merge(
                                    [ui.frameArrived, ui.cacheChanged]),
                              ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
        const CacheMeterFrb(),
      ],
    );
  }
}

/// One row of a layer's fold-out, in the outline.
///
/// A heading draws its own twirl; a property row draws the same controls the
/// Effect controls panel does, at exactly one lane's height so the two halves of
/// the table stay in step.
class _FoldRow extends StatelessWidget {
  final CompositionReference comp;
  final LayerReference layer;
  final LayerFoldRow row;
  final int playheadFrame;
  final ValueChanged<int> onSeek;
  final ValueChanged<String> onToggle;
  final VoidCallback onChanged;

  const _FoldRow({
    required this.comp,
    required this.layer,
    required this.row,
    required this.playheadFrame,
    required this.onSeek,
    required this.onToggle,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    // 20 for the layer number, then one step per level, so a parameter sits
    // under its effect and an effect under Effects.
    final indent = 20.0 + row.depth * 14.0;

    // No per-row change listener: the whole panel repaints from the read model
    // when anything commits (K-184), so the numbers shown are the document's.
    return SizedBox(
      height: _rowHeight,
      child: Padding(
        padding: EdgeInsets.only(left: indent, right: 4),
        child: _control(context),
      ),
    );
  }

  Widget _control(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return switch (row) {
      FoldWaveformRow() => const SizedBox.shrink(),
      FoldGroupRow(:final path, :final label, :final open) => GestureDetector(
          key: ValueKey<String>('tl-group-$path'),
          behavior: HitTestBehavior.opaque,
          onTap: () => onToggle(path),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              lumitIcon(
                open ? LumitIcon.twirlOpen : LumitIcon.twirlClosed,
                size: 10,
                color: open ? t.textPrimary : t.textMuted,
              ),
              const SizedBox(width: 4),
              Text(label, style: t.body),
            ],
          ),
        ),
      FoldTransformRow(:final group, :final transform) => TransformRowFrb(
          comp: comp,
          layer: layer,
          transform: transform,
          group: group,
          playheadFrame: playheadFrame,
          onSeek: onSeek,
          onChanged: onChanged,
          keyPrefix: 'tl-tf',
          rowPadding: EdgeInsets.zero,
        ),
      FoldEffectParamRow() => _TimelineParamRow(
          comp: comp,
          layer: layer,
          row: row as FoldEffectParamRow,
          playheadFrame: playheadFrame,
          onSeek: onSeek,
          onChanged: onChanged,
        ),
      FoldVolumeRow() => _VolumeRow(
          comp: comp,
          layer: layer,
          playheadFrame: playheadFrame,
          onSeek: onSeek,
          onChanged: onChanged,
        ),
    };
  }
}

/// One effect parameter in the Timeline. It owns the staging for its own drag,
/// which is all the state a single row needs — no stack is read to *display*:
/// the value rides in on the fold row from the read model (K-184), and a drag
/// in flight overlays its staged value on top.
class _TimelineParamRow extends StatefulWidget {
  final CompositionReference comp;
  final LayerReference layer;
  final FoldEffectParamRow row;
  final int playheadFrame;
  final ValueChanged<int> onSeek;
  final VoidCallback onChanged;

  const _TimelineParamRow({
    required this.comp,
    required this.layer,
    required this.row,
    required this.playheadFrame,
    required this.onSeek,
    required this.onChanged,
  });

  @override
  State<_TimelineParamRow> createState() => _TimelineParamRowState();
}

class _TimelineParamRowState extends State<_TimelineParamRow> {
  final EffectStackEditor _editor = EffectStackEditor();

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final ui = Provider.of<LumitUiState>(context, listen: false);
    return EffectParamRowFrb(
      key: ValueKey<String>('tl-fx-${row.info.id}-${row.param.id}'),
      effectId: row.info.id,
      param: row.param,
      // The staged value while a drag is in flight, the document's otherwise.
      value: _editor.stagedValue(row.info.id, row.param.id) ?? row.value,
      comp: widget.comp,
      playheadFrame: widget.playheadFrame,
      onSeek: widget.onSeek,
      onWrite: (effect, param, value) {
        _editor.write(widget.layer, effect, param, value);
        setState(() {});
        widget.onChanged();
      },
      onLive: (effect, param, value) => setState(() {
        _editor.live(widget.comp, widget.layer, effect, param, value,
            frame: ui.playheadFrame.value, scale: ui.viewerScale);
      }),
    );
  }
}

/// The Audio group's one row: the layer's Volume, in dB.
class _VolumeRow extends StatefulWidget {
  final CompositionReference comp;
  final LayerReference layer;
  final int playheadFrame;
  final ValueChanged<int> onSeek;
  final VoidCallback onChanged;

  const _VolumeRow({
    required this.comp,
    required this.layer,
    required this.playheadFrame,
    required this.onSeek,
    required this.onChanged,
  });

  @override
  State<_VolumeRow> createState() => _VolumeRowState();
}

class _VolumeRowState extends State<_VolumeRow> {
  /// The value under the pointer during a drag. Unlike a transform or an effect
  /// there is no preview to render — sound is not redrawn — so a tick only holds
  /// the number and the release commits it.
  double? _staged;

  void _commit(num value) {
    widget.layer.setVolumeDb(value: BridgeScalar.static_(value.toDouble()));
    setState(() => _staged = null);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final scalar = widget.layer.getVolumeDb();
    final animated = scalar is! BridgeScalar_Static;
    final value = _staged ?? (animated ? 0.0 : scalar.field0);

    return Row(
      children: [
        KeyframeControlsFrb(
          scalars: [scalar],
          comp: widget.comp,
          playheadFrame: widget.playheadFrame,
          onSeek: widget.onSeek,
          rowKey: 'tl-volume',
          onWrite: (next) {
            widget.layer.setVolumeDb(value: next.single);
            widget.onChanged();
          },
        ),
        const SizedBox(width: 4),
        Text('Volume', style: t.body),
        const SizedBox(width: 10),
        if (animated)
          Text('animated', style: t.small.copyWith(color: t.textMuted))
        else
          SizedBox(
            width: 74,
            child: DragValueField(
              key: const ValueKey('tl-volume-db'),
              value: value,
              // The engine's own range (docs/09 6): silence to a +12 dB boost.
              min: -60,
              max: 12,
              decimals: 1,
              suffix: ' dB',
              speed: 0.2,
              onChanged: _commit,
              onChangeLive: (v) => setState(() => _staged = v.toDouble()),
              onChangeEnd: _commit,
              onDragCancel: () => setState(() => _staged = null),
            ),
          ),
      ],
    );
  }
}

/// Frames to pixels and back, for one panel width.
/// The waveform lane's painter: the layer's source peaks, mapped through its
/// live in/out/offset so dragging or trimming the bar carries the transients
/// with it in realtime (K-172). One vertical min-max line per pixel column.
class _WaveformPainter extends CustomPainter {
  final BridgeAudioPeaks? peaks;
  final BridgeLayerInfo info;
  final _Axis axis;
  final double fps;
  final Color colour;

  const _WaveformPainter({
    required this.peaks,
    required this.info,
    required this.axis,
    required this.fps,
    required this.colour,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final held = peaks;
    if (held == null || held.pairs.isEmpty || held.durationSeconds <= 0) {
      return;
    }
    final buckets = held.pairs.length ~/ 2;
    final startOffset =
        info.span.startOffset.num / info.span.startOffset.den.toDouble();
    final left = axis.xOf(info.inFrame.toInt()).clamp(0.0, size.width);
    final right = axis.xOf(info.outFrame.toInt()).clamp(0.0, size.width);
    final mid = size.height / 2;
    // Half a pixel of breathing room top and bottom.
    final half = mid - 1;
    final paintLine = Paint()
      ..color = colour
      ..strokeWidth = 1;

    for (var x = left; x < right; x += 1) {
      // Fractional, straight off the axis mapping: frameAt rounds to whole
      // frames, which would staircase the waveform.
      final compSec = x / axis.width * axis.frames / fps;
      final srcSec = compSec - startOffset;
      if (srcSec < 0 || srcSec >= held.durationSeconds) continue;
      final bucket = (srcSec / held.durationSeconds * buckets)
          .floor()
          .clamp(0, buckets - 1);
      final lo = held.pairs[bucket * 2].clamp(-1.0, 1.0);
      final hi = held.pairs[bucket * 2 + 1].clamp(-1.0, 1.0);
      canvas.drawLine(
        Offset(x, mid - hi * half),
        Offset(x, mid - lo * half),
        paintLine,
      );
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.peaks != peaks ||
      old.info != info ||
      old.fps != fps ||
      old.axis.frames != axis.frames ||
      old.axis.width != axis.width;
}

class _Axis implements CacheBarAxis {
  @override
  final int frames;
  final double width;
  const _Axis({required this.frames, required this.width});

  double get perFrame => frames <= 0 ? 0 : width / frames;
  @override
  double xOf(num frame) => frame * perFrame;
  int frameAt(double x) => perFrame <= 0 ? 0 : (x / perFrame).round();
}

/// The Layer menu, the razor, the work-area buttons, markers and search.
class _Toolbar extends StatelessWidget {
  final CompositionReference comp;
  final bool graph;
  final VoidCallback onToggleGraph;
  final bool razor;

  /// Read at click time, not at build time: the toolbar sits above the
  /// playhead's listener and does not rebuild when it moves, so a captured
  /// value would be whatever it was when the panel last drew.
  final int Function() playheadFrame;
  final VoidCallback onToggleRazor;
  final ValueChanged<String> onSearch;
  final VoidCallback onChanged;

  const _Toolbar({
    required this.comp,
    required this.graph,
    required this.onToggleGraph,
    required this.razor,
    required this.playheadFrame,
    required this.onToggleRazor,
    required this.onSearch,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return Container(
      height: 26,
      color: t.surface1,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      // Scrolls rather than overflows. The toolbar has grown a button at a
      // time and a docked Timeline can be any width; an overflow is striped
      // tape across the row, and every button here is reachable by scrolling to
      // it instead.
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            HouseButton(
              key: const ValueKey('tl-add-layer'),
              small: true,
              onPressed: () => _showLayerMenu(context, comp, onChanged),
              child: Text('New layer', style: t.small),
            ),
            const SizedBox(width: 6),
            HouseButton(
              key: const ValueKey('tl-graph'),
              small: true,
              onPressed: onToggleGraph,
              child: Text('Graph',
                  style: t.small.copyWith(color: graph ? t.accent : null)),
            ),
            const SizedBox(width: 6),
            LumitTooltip(
              message: razor
                  ? 'Razor armed — click a clip to cut it'
                  : 'Razor: cut a clip at the playhead',
              child: HouseButton(
                key: const ValueKey('tl-razor'),
                small: true,
                onPressed: onToggleRazor,
                // HouseButton has no selected state, so the armed razor says so
                // in the accent — the same colour the stopwatch uses for "this
                // is on".
                child: Text('Razor',
                    style: t.small.copyWith(color: razor ? t.accent : null)),
              ),
            ),
            const SizedBox(width: 6),
            _workAreaButton(context, t, 'Set in', isStart: true),
            _workAreaButton(context, t, 'Set out', isStart: false),
            HouseButton(
              key: const ValueKey('tl-clear-work-area'),
              small: true,
              frameless: true,
              onPressed: () {
                comp.setWorkArea(span: null);
                onChanged();
              },
              child: Text('Clear', style: t.small),
            ),
            const SizedBox(width: 6),
            HouseButton(
              key: const ValueKey('tl-markers'),
              small: true,
              frameless: true,
              onPressed: () async {
                await showMarkerEditorFrb(
                  context: context,
                  comp: comp,
                  playheadFrame: playheadFrame(),
                );
                onChanged();
              },
              child: Text('Markers', style: t.small),
            ),
            LumitTooltip(
              message: 'Find the beat in this composition and mark it',
              child: HouseButton(
                key: const ValueKey('tl-detect-beats'),
                small: true,
                frameless: true,
                onPressed: () {
                  // Seconds-long on a long comp, so it runs off-thread and the
                  // markers appear when it finishes; a comp with no audio, or
                  // a machine with no pipeline, says so by doing nothing
                  // rather than by an alarm.
                  comp
                      .detectBeats(sensitivityPercent: 50)
                      .then((_) => onChanged(), onError: (_) {});
                },
                child: Text('Detect beats', style: t.small),
              ),
            ),
            const SizedBox(width: 10),
            LayerSearchFrb(onChanged: onSearch),
          ],
        ),
      ),
    );
  }

  Widget _workAreaButton(
    BuildContext context,
    LumitTheme t,
    String label, {
    required bool isStart,
  }) =>
      HouseButton(
        key: ValueKey<String>('tl-work-${isStart ? 'in' : 'out'}'),
        small: true,
        frameless: true,
        onPressed: () {
          comp.setWorkArea(
            span: workAreaWith(
              comp: comp,
              current: comp.getWorkArea(),
              frame: playheadFrame(),
              isStart: isStart,
            ),
          );
          onChanged();
        },
        child: Text(label, style: t.small),
      );
}

Future<void> _showLayerMenu(
  BuildContext context,
  CompositionReference comp,
  VoidCallback onChanged,
) async {
  final box = context.findRenderObject();
  if (box is! RenderBox) return;
  final picked = await showLumitPopup<String>(
    context: context,
    position: box.localToGlobal(Offset(0, box.size.height + 2)),
    builder: (close) => FloatSurface(
      width: 190,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final kind in [
            'Solid',
            'Text',
            'Camera',
            'Adjustment',
            'Sequence'
          ])
            MenuRow(onPressed: () => close(kind), child: Text(kind)),
        ],
      ),
    ),
  );
  switch (picked) {
    case 'Solid':
      comp.addSolidLayer();
    case 'Text':
      comp.addTextLayer();
    case 'Camera':
      comp.addCameraLayer();
    case 'Adjustment':
      comp.addAdjustmentLayer();
    case 'Sequence':
      comp.addSequenceLayer();
    case _:
      return;
  }
  onChanged();
}

/// The left column: one row per layer, with its switches and columns.
class _Outline extends StatelessWidget {
  final CompositionReference comp;
  final List<BridgeLayerEntry> layers;
  final LayerReference? selected;
  final String? highlighted;
  final Set<String> open;
  final Map<String, bool> hasAudio;
  final ValueChanged<String> onToggle;
  final int playheadFrame;
  final ValueChanged<int> onSeek;
  final ValueChanged<LayerReference> onSelect;
  final ValueChanged<String> onHighlight;
  final VoidCallback onChanged;

  const _Outline({
    required this.comp,
    required this.layers,
    required this.selected,
    required this.highlighted,
    required this.open,
    required this.hasAudio,
    required this.onToggle,
    required this.playheadFrame,
    required this.onSeek,
    required this.onSelect,
    required this.onHighlight,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Aligns the first row with the first layer bar. The lane side puts the
        // cache bar under the ruler, so this has to clear both — matching only
        // the ruler left every name two pixels below its own bar.
        Container(
          height: _rulerHeight + TimelineCacheBar.height,
          color: t.surface2,
        ),
        for (var i = 0; i < layers.length; i++) ...[
          _OutlineRow(
            key: ValueKey<String>('tl-row-${layers[i].layer.internallayerId}'),
            comp: comp,
            entry: layers[i],
            layers: layers,
            index: i,
            count: layers.length,
            // A local compare, not a bridge call: both ids already sit here.
            selected:
                selected?.internallayerId == layers[i].layer.internallayerId,
            highlighted:
                highlighted == layers[i].layer.internallayerId.toString(),
            open: open.contains(layers[i].layer.internallayerId.toString()),
            onToggleOpen: () =>
                onToggle(layers[i].layer.internallayerId.toString()),
            onSelect: () => onSelect(layers[i].layer),
            onChanged: onChanged,
          ),
          // The fold-out, from the same list the lanes leave room for.
          if (open.contains(layers[i].layer.internallayerId.toString()))
            for (final row in layerFoldRows(
              entry: layers[i],
              open: open,
              hasAudio:
                  hasAudio[layers[i].layer.internallayerId.toString()] ?? false,
            ))
              // A raw pointer listener, not a gesture: touching a sub-item
              // highlights its layer, and it must never fight the row's own
              // taps and drags for the gesture arena.
              Listener(
                onPointerDown: (_) =>
                    onHighlight(layers[i].layer.internallayerId.toString()),
                child: _FoldRow(
                  comp: comp,
                  layer: layers[i].layer,
                  row: row,
                  playheadFrame: playheadFrame,
                  onSeek: onSeek,
                  onToggle: onToggle,
                  onChanged: onChanged,
                ),
              ),
        ],
      ],
    );
  }
}

class _OutlineRow extends StatefulWidget {
  final CompositionReference comp;
  final BridgeLayerEntry entry;

  /// Every layer in the comp, for the parent picker's menu — from the same
  /// read model, so offering them costs nothing.
  final List<BridgeLayerEntry> layers;
  final int index;
  final int count;
  final bool selected;

  /// A sub-item of this layer was last touched — drawn a shade dimmer than
  /// selection, so the two states read apart at a glance.
  final bool highlighted;
  final bool open;
  final VoidCallback onToggleOpen;
  final VoidCallback onSelect;
  final VoidCallback onChanged;

  const _OutlineRow({
    super.key,
    required this.comp,
    required this.entry,
    required this.layers,
    required this.index,
    required this.count,
    required this.selected,
    required this.highlighted,
    required this.open,
    required this.onToggleOpen,
    required this.onSelect,
    required this.onChanged,
  });

  @override
  State<_OutlineRow> createState() => _OutlineRowState();
}

class _OutlineRowState extends State<_OutlineRow> {
  /// The inline rename, entered by double-clicking the name.
  TextEditingController? _rename;

  LayerReference get layer => widget.entry.layer;
  int get index => widget.index;
  int get count => widget.count;

  @override
  void dispose() {
    _rename?.dispose();
    super.dispose();
  }

  void _commitRename() {
    final text = _rename?.text.trim() ?? '';
    setState(() {
      _rename?.dispose();
      _rename = null;
    });
    if (text.isEmpty || text == widget.entry.info.name) return;
    layer.rename(name: text);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    // ZERO bridge calls: everything this row draws is in the read model
    // (K-184).
    final info = widget.entry.info;
    final switches = info.switches;
    final id = layer.internallayerId.toString();

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onSelect,
      onSecondaryTapDown: (d) => _showRowMenu(context, d.globalPosition),
      child: Container(
        height: _rowHeight,
        // Selected is the brighter of the two states; a highlight (this
        // layer's fold-out was last touched) is the same surface at half
        // strength, so they read apart at a glance.
        color: widget.selected
            ? t.surface2
            : widget.highlighted
                ? t.surface2.withValues(alpha: 0.45)
                : null,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            // The owner's column groupings (docs/TODO): visibility and sound
            // first, then twirl + label colour + name, then the rest of the
            // switches, with matte and blend closing the row.
            _switch(context, id, 'visible', LumitIcon.eye, switches.visible,
                BridgeLayerSwitch.visible),
            _switch(context, id, 'audible', LumitIcon.audio, switches.audible,
                BridgeLayerSwitch.audible),
            const SizedBox(width: 4),
            // The twirl: the layer's properties, where AE puts them. Its own
            // gesture, so opening a layer does not also select it — you often
            // want to look at one layer's values while another is selected.
            GestureDetector(
              key: ValueKey<String>('tl-twirl-$id'),
              behavior: HitTestBehavior.opaque,
              onTap: widget.onToggleOpen,
              child: SizedBox(
                width: 16,
                height: _rowHeight,
                child: Center(
                  child: lumitIcon(
                    widget.open ? LumitIcon.twirlOpen : LumitIcon.twirlClosed,
                    size: 11,
                    color: widget.open ? t.textPrimary : t.textMuted,
                  ),
                ),
              ),
            ),
            _labelSwatch(context, t, id, info.label),
            const SizedBox(width: 4),
            Expanded(child: _name(t, id, info)),
            const SizedBox(width: 4),
            SizedBox(
              width: 20,
              child: Text('${index + 1}',
                  style: t.small.copyWith(color: t.textMuted)),
            ),
            // No solo glyph in the icon set; the star reads as isolate.
            _switch(context, id, 'solo', LumitIcon.star, switches.solo,
                BridgeLayerSwitch.solo),
            _switch(context, id, 'locked', LumitIcon.lock, switches.locked,
                BridgeLayerSwitch.locked),
            ParentPickerFrb(
              layer: layer,
              info: info,
              all: widget.layers,
              onChanged: widget.onChanged,
            ),
            const SizedBox(width: 4),
            MattePickerFrb(
              layer: layer,
              info: info,
              all: widget.layers,
              onChanged: widget.onChanged,
            ),
            _blendPicker(context, t, info.blend),
          ],
        ),
      ),
    );
  }

  /// The name, or the rename editor a double-click turns it into. Submitting
  /// commits; clicking anywhere else commits too (the field loses the row).
  Widget _name(LumitTheme t, String id, BridgeLayerInfo info) {
    final editor = _rename;
    if (editor != null) {
      return HouseTextField(
        key: ValueKey<String>('tl-rename-$id'),
        controller: editor,
        autofocus: true,
        onSubmitted: (_) => _commitRename(),
      );
    }
    return GestureDetector(
      key: ValueKey<String>('tl-name-$id'),
      behavior: HitTestBehavior.opaque,
      onDoubleTap: () => setState(() {
        _rename = TextEditingController(text: info.name);
      }),
      child: SizedBox(
        height: _rowHeight,
        child: Align(
          alignment: Alignment.centerLeft,
          child:
              Text(info.name, style: t.body, overflow: TextOverflow.ellipsis),
        ),
      ),
    );
  }

  /// The layer's label colour (TL2): a chip that opens the eight-colour
  /// picker. The palette is the theme's own, so no colour literal lives here.
  Widget _labelSwatch(
      BuildContext context, LumitTheme t, String id, int label) {
    return GestureDetector(
      key: ValueKey<String>('tl-label-$id'),
      behavior: HitTestBehavior.opaque,
      onTapDown: (d) async {
        final picked = await showLumitPopup<int>(
          context: context,
          position: d.globalPosition,
          builder: (close) => FloatSurface(
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < 8; i++)
                    GestureDetector(
                      key: ValueKey<String>('tl-label-chip-$i'),
                      onTap: () => close(i),
                      child: Container(
                        width: 14,
                        height: 14,
                        margin: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: t.labelColour(i),
                          borderRadius:
                              BorderRadius.circular(t.tokens.controlRadius),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
        if (picked == null) return;
        layer.setLabel(label: picked);
        widget.onChanged();
      },
      child: SizedBox(
        width: 16,
        height: _rowHeight,
        child: Center(
          child: Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: t.labelColour(label),
              borderRadius: BorderRadius.circular(t.tokens.controlRadius),
            ),
          ),
        ),
      ),
    );
  }

  Widget _switch(
    BuildContext context,
    String id,
    String name,
    LumitIcon icon,
    bool on,
    BridgeLayerSwitch which,
  ) {
    final t = ThemeScope.of(context).theme;
    return GestureDetector(
      key: ValueKey<String>('tl-$name-$id'),
      behavior: HitTestBehavior.opaque,
      onTap: () {
        layer.setSwitch(switch_: which, on_: !on);
        widget.onChanged();
      },
      child: SizedBox(
        width: 18,
        height: _rowHeight,
        child: Center(
          child: lumitIcon(icon,
              size: 11, color: on ? t.textPrimary : t.textDisabled),
        ),
      ),
    );
  }

  Widget _blendPicker(BuildContext context, LumitTheme t, int current) {
    final modes = _blendModes ??= listBlendModes();
    // Wide enough for the longest mode name plus the caret: a dropdown that
    // overflows its cell is a layout error, not a cosmetic one.
    return SizedBox(
      width: 112,
      child: BareDropdown<int>(
        key: ValueKey<String>('tl-blend-${layer.internallayerId}'),
        value: current < modes.length ? current : 0,
        options: [for (var i = 0; i < modes.length; i++) i],
        label: (i) => modes[i],
        onChanged: (i) {
          layer.setBlend(index: i);
          widget.onChanged();
        },
      ),
    );
  }

  Future<void> _showRowMenu(BuildContext context, Offset position) async {
    final picked = await showLumitPopup<String>(
      context: context,
      position: position,
      builder: (close) => FloatSurface(
        width: 190,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MenuRow(
                onPressed: () => close('duplicate'),
                child: const Text('Duplicate')),
            if (index > 0)
              MenuRow(
                  onPressed: () => close('up'),
                  child: const Text('Bring forward')),
            if (index < count - 1)
              MenuRow(
                  onPressed: () => close('down'),
                  child: const Text('Send backward')),
            MenuRow(
                onPressed: () => close('delete'), child: const Text('Delete')),
          ],
        ),
      ),
    );
    switch (picked) {
      case 'duplicate':
        layer.duplicate();
      case 'up':
        layer.reorder(newIndex: BigInt.from(index - 1));
      case 'down':
        layer.reorder(newIndex: BigInt.from(index + 1));
      case 'delete':
        layer.delete();
      case _:
        return;
    }
    widget.onChanged();
  }
}

/// The right column: the ruler, the playhead, and one bar per layer.
class _LayerArea extends StatelessWidget {
  final CompositionReference comp;
  final List<BridgeLayerEntry> layers;

  /// Which layers are twirled open in the outline. Read only to leave the same
  /// room their property rows take, so a bar never drifts away from its name.
  final Set<String> open;

  /// Which layers carry sound — passed through only so the row list this side
  /// builds is identical to the outline's.
  final Map<String, bool> hasAudio;

  /// Each layer's source peaks, for the waveform lanes.
  final Map<String, BridgeAudioPeaks> peaks;

  /// The comp's rate, mapping the lane's pixels onto source seconds.
  final double fps;
  final _Axis axis;

  /// Listened to, not read: only the playhead line moves when it changes.
  final ValueListenable<int> playhead;
  final bool razor;
  final ValueChanged<int> onSeek;

  /// Clicking a bar is clicking the layer: the lane side selects too.
  final ValueChanged<LayerReference> onSelect;
  final VoidCallback onChanged;

  /// Fires when something may have changed which frames are held — a frame
  /// arriving or the idle fill banking one — so the bar repaints then rather
  /// than polling the cache on every frame it draws.
  final Listenable cacheRevision;

  const _LayerArea({
    required this.comp,
    required this.layers,
    required this.open,
    required this.hasAudio,
    required this.peaks,
    required this.fps,
    required this.axis,
    required this.playhead,
    required this.razor,
    required this.onSeek,
    required this.onSelect,
    required this.onChanged,
    required this.cacheRevision,
  });

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Ruler(
              comp: comp,
              axis: axis,
              onSeek: onSeek,
            ),
            // Directly under the ruler and above the lanes, which is where the
            // interface spec puts it (docs/07 §3.2).
            TimelineCacheBar(comp: comp, axis: axis, revision: cacheRevision),
            for (final entry in layers) ...[
              _Bar(
                key: ValueKey<String>('tl-bar-${entry.layer.internallayerId}'),
                comp: comp,
                entry: entry,
                axis: axis,
                razor: razor,
                playheadFrame: () => playhead.value,
                onSelect: () => onSelect(entry.layer),
                onChanged: onChanged,
              ),
              // One lane per fold-out row the outline is showing, from the
              // same list it builds — mostly empty room (keyframes draw in
              // the graph editor), but the waveform row paints the layer's
              // source peaks through its live in/out/offset (K-172).
              if (open.contains(entry.layer.internallayerId.toString()))
                Column(
                  key: ValueKey<String>(
                      'tl-lanes-${entry.layer.internallayerId}'),
                  children: [
                    for (final row in layerFoldRows(
                      entry: entry,
                      open: open,
                      hasAudio:
                          hasAudio[entry.layer.internallayerId.toString()] ??
                              false,
                    ))
                      SizedBox(
                        height: _rowHeight,
                        child: row is FoldWaveformRow
                            ? CustomPaint(
                                key: ValueKey<String>(
                                    'tl-wave-${entry.layer.internallayerId}'),
                                size: Size(axis.width, _rowHeight),
                                painter: _WaveformPainter(
                                  peaks: peaks[
                                      entry.layer.internallayerId.toString()],
                                  info: entry.info,
                                  axis: axis,
                                  fps: fps,
                                  colour: t.accent,
                                ),
                              )
                            : null,
                      ),
                  ],
                ),
            ],
          ],
        ),
        // The playhead rides above every bar so it is never hidden behind one,
        // and it is the only thing here that redraws when it moves.
        ValueListenableBuilder<int>(
          valueListenable: playhead,
          builder: (context, frame, child) => Positioned(
            left: axis.xOf(frame),
            top: 0,
            bottom: 0,
            child: child!,
          ),
          child: IgnorePointer(
            child: Container(width: 1, color: t.accent),
          ),
        ),
      ],
    );
  }
}

/// The ruler: frame ticks, the work area, the markers, and the scrub surface.
class _Ruler extends StatelessWidget {
  final CompositionReference comp;
  final _Axis axis;
  final ValueChanged<int> onSeek;

  const _Ruler({required this.comp, required this.axis, required this.onSeek});

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final work = comp.getWorkArea();
    final markers = comp.getMarkers();

    return GestureDetector(
      key: const ValueKey('tl-ruler'),
      behavior: HitTestBehavior.opaque,
      onTapDown: (d) => onSeek(axis.frameAt(d.localPosition.dx)),
      onHorizontalDragUpdate: (d) => onSeek(axis.frameAt(d.localPosition.dx)),
      child: Container(
        height: _rulerHeight,
        color: t.surface2,
        child: Stack(
          children: [
            // The work area, when there is one: the span the Viewer previews
            // and the export writes.
            if (work != null)
              Positioned(
                left: axis.xOf(comp.frameAtTime(time: work.inPoint)),
                width: (axis.xOf(comp.frameAtTime(time: work.outPoint)) -
                        axis.xOf(comp.frameAtTime(time: work.inPoint)))
                    .clamp(1.0, 1e6),
                top: 0,
                bottom: 0,
                child: IgnorePointer(
                  child: Container(
                    key: const ValueKey('tl-work-area'),
                    color: t.accent.withValues(alpha: 0.14),
                  ),
                ),
              ),
            for (final marker in markers)
              Positioned(
                left: axis.xOf(comp.frameAtTime(time: marker.time)) - 3,
                top: 4,
                child: IgnorePointer(
                  child: LumitTooltip(
                    message: marker.label,
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: t.warning,
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One layer's bar: drag its middle to move it, its ends to trim.
class _Bar extends StatefulWidget {
  final CompositionReference comp;
  final BridgeLayerEntry entry;
  final _Axis axis;
  final bool razor;

  /// Read when the razor is clicked, not captured when the bar is built.
  final int Function() playheadFrame;

  /// Clicking (or grabbing) the bar selects its layer.
  final VoidCallback onSelect;
  final VoidCallback onChanged;

  const _Bar({
    super.key,
    required this.comp,
    required this.entry,
    required this.axis,
    required this.razor,
    required this.playheadFrame,
    required this.onSelect,
    required this.onChanged,
  });

  @override
  State<_Bar> createState() => _BarState();
}

class _BarState extends State<_Bar> {
  /// Frames the gesture has moved so far, held here rather than committed.
  ///
  /// A bar drag has no cheap preview to show — moving a layer in time changes
  /// what every frame contains — so the bar moves in Dart and the document
  /// learns about it once, on release.
  int _delta = 0;
  _Grab? _grab;

  /// Where the pointer went DOWN, deciding edge-trim versus move. Down, not
  /// drag-start: a drag's start position is where the slop was exceeded,
  /// which read a fast edge grab as a grab of the middle.
  double _downDx = 0;

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    // ZERO bridge calls (K-184): the span already mapped to comp frames, the
    // kind, and the clip split positions all ride in on the read model.
    final info = widget.entry.info;
    final inFrame = info.inFrame;
    final outFrame = info.outFrame;

    final (drawIn, drawOut) = switch (_grab) {
      _Grab.move => (inFrame + _delta, outFrame + _delta),
      _Grab.trimIn => (inFrame + _delta, outFrame),
      _Grab.trimOut => (inFrame, outFrame + _delta),
      null => (inFrame, outFrame),
    };

    final left = widget.axis.xOf(drawIn);
    final width = (widget.axis.xOf(drawOut) - left).clamp(2.0, 1e6);

    return SizedBox(
      height: _rowHeight,
      child: Stack(
        children: [
          Positioned(
            left: left,
            width: width,
            top: 3,
            bottom: 3,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              // Armed razor: a click cuts the clip under the playhead rather
              // than starting a drag. A layer with no clip there says so
              // through the engine's calm error, which is nothing on screen —
              // the cut simply does not happen.
              onTap: widget.razor
                  ? () {
                      try {
                        widget.entry.layer
                            .cutClipAt(frame: widget.playheadFrame());
                      } catch (_) {
                        return;
                      }
                      widget.onChanged();
                    }
                  // Clicking anywhere on a layer selects it (docs/TODO) —
                  // the bar is most of what "the layer" is on screen.
                  : widget.onSelect,
              onHorizontalDragDown:
                  widget.razor ? null : (d) => _downDx = d.localPosition.dx,
              onHorizontalDragStart: widget.razor
                  ? null
                  : (d) => setState(() {
                        // Grabbing a bar selects its layer too: a drag is a
                        // click that kept going.
                        widget.onSelect();
                        _delta = 0;
                        _grab = _downDx < _trimGrab
                            ? _Grab.trimIn
                            : _downDx > width - _trimGrab
                                ? _Grab.trimOut
                                : _Grab.move;
                      }),
              onHorizontalDragUpdate: widget.razor
                  ? null
                  : (d) => setState(() {
                        _delta += widget.axis.frameAt(d.delta.dx);
                      }),
              onHorizontalDragEnd:
                  widget.razor ? null : (_) => _commit(inFrame, outFrame),
              onHorizontalDragCancel: widget.razor
                  ? null
                  : () => setState(() {
                        _delta = 0;
                        _grab = null;
                      }),
              child: Container(
                decoration: BoxDecoration(
                  color: _colourFor(info.kind, t),
                  borderRadius: BorderRadius.circular(2),
                ),
                // A Sequence layer draws its clip splits, so the razor has
                // something to aim at and a cut is visible once made.
                child: Stack(
                  children: [
                    for (final clipFrame in info.clipFrames)
                      Positioned(
                        left: widget.axis.xOf(clipFrame.toInt()) - 0.5,
                        top: 0,
                        bottom: 0,
                        child: Container(width: 1, color: t.surface0),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// One `set_span` for the whole gesture, so a move that shifted the in point
  /// and the start offset together is a single undo step.
  void _commit(int inFrame, int outFrame) {
    final grab = _grab;
    final delta = _delta;
    setState(() {
      _delta = 0;
      _grab = null;
    });
    if (grab == null || delta == 0) return;

    final span = widget.entry.info.span;
    var newIn = inFrame;
    var newOut = outFrame;
    var offsetShift = 0;
    switch (grab) {
      case _Grab.move:
        newIn += delta;
        newOut += delta;
        // Moving carries the content with the bar, so time 0 travels too.
        offsetShift = delta;
      case _Grab.trimIn:
        newIn += delta;
      case _Grab.trimOut:
        newOut += delta;
    }
    // A bar cannot be trimmed past itself; the op refuses it, and refusing here
    // first means the gesture simply stops rather than raising.
    if (newOut <= newIn) return;

    widget.entry.layer.setSpan(
      span: BridgeSpan(
        inPoint: widget.comp.timeOfFrame(frame: newIn),
        outPoint: widget.comp.timeOfFrame(frame: newOut),
        startOffset: offsetShift == 0
            ? span.startOffset
            : widget.comp.timeOfFrame(
                frame: widget.comp.frameAtTime(time: span.startOffset) +
                    offsetShift,
              ),
      ),
    );
    widget.onChanged();
  }
}

enum _Grab { move, trimIn, trimOut }

/// A bar's fill, by what the layer is — the same family of colours the Project
/// panel gives its row glyphs, so a footage layer reads as footage in both.
Color _colourFor(BridgeLayerKind kind, LumitTheme t) => switch (kind) {
      BridgeLayerKind.footage => t.layer.footage,
      BridgeLayerKind.precomp => t.layer.precomp,
      BridgeLayerKind.solid => t.layer.solid,
      BridgeLayerKind.text => t.layer.text,
      BridgeLayerKind.camera => t.layer.camera,
      BridgeLayerKind.sequence => t.layer.sequence,
      // A comp-sized effect container, drawn as a solid — the same choice
      // layer_style.dart makes, and the egui frontend before it.
      BridgeLayerKind.adjustment => t.layer.solid,
    };
