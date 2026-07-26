// The Timeline panel, on the flutter_rust_bridge API.
//
// Two columns side by side over one shared time axis: an **outline** on the
// left (layer number, label chip, name, switches, blend mode, parent) and a
// **layer area** on the right (the ruler, the playhead, one bar per layer, the
// work area and the markers). Everything reads through reference handles — there
// is no snapshot to mirror, so a row asks the layer it draws.
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
import 'package:lumit_flutter/src/rust/api/layer.dart';
import 'package:provider/provider.dart';

import '../icons/icons.dart';
import '../state/drag_payloads.dart';
import '../theme/theme.dart';
import '../widgets/controls.dart';
import 'placeholder.dart';
import 'graph_editor_frb.dart';
import 'timeline_extras_frb.dart';

/// The outline column's width. Wide enough for the number, four switches, a
/// name worth reading, and the blend and parent pickers side by side — about
/// what After Effects gives its own outline. Fixed rather than resizable for
/// now: a splitter is its own slice of work and nothing depends on it yet.
const double _outlineWidth = 400;

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
  String _search = '';

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

    final settings = comp.getSettings();
    final frames = settings.durationFrames.toInt();
    final needle = _search.trim().toLowerCase();
    final layers = [
      for (final l in comp.getLayers())
        if (needle.isEmpty || l.getName().toLowerCase().contains(needle)) l,
    ];

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
          onChanged: () => setState(() {}),
        ),
        Expanded(
          // Dropping footage from the Project panel adds it as a layer. The
          // target wraps the whole body — outline and layer area both — because
          // "onto the Timeline" is what the gesture means; asking the user to
          // hit one half of it would be a rule with no reason behind it.
          child: DragTarget<FootageDragData>(
            onAcceptWithDetails: (details) {
              comp.addFootageLayer(footage: details.data.footage);
              setState(() {});
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
                  // The axis is the panel's own width minus the outline, so a
                  // narrower panel shows the same span more tightly rather than
                  // scrolling — matching the Viewer's fit-to-panel behaviour.
                  final layerAreaWidth =
                      (constraints.maxWidth - _outlineWidth).clamp(1.0, 1e6);
                  final axis = _Axis(frames: frames, width: layerAreaWidth);

                  return ValueListenableBuilder<int>(
                    valueListenable: ui.playheadFrame,
                    builder: (context, playhead, _) => Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: _outlineWidth,
                          child: _Outline(
                            comp: comp,
                            layers: layers,
                            selected: ui.selectedLayer.value,
                            onSelect: (l) => setState(() {
                              ui.selectedLayer.value = l;
                            }),
                            onChanged: () => setState(() {}),
                          ),
                        ),
                        Expanded(
                          child: _graph
                              ? GraphEditorFrb(
                                  comp: comp,
                                  layer: ui.selectedLayer.value,
                                  frames: frames,
                                  playheadFrame: playhead,
                                  onSeek: (f) => ui.playheadFrame.value = f,
                                  onChanged: () => setState(() {}),
                                )
                              : _LayerArea(
                                  comp: comp,
                                  layers: layers,
                                  axis: axis,
                                  playhead: playhead,
                                  razor: _razor,
                                  onSeek: (f) => ui.playheadFrame.value =
                                      f.clamp(0, frames == 0 ? 0 : frames - 1),
                                  onChanged: () => setState(() {}),
                                  cacheRevision: ui.frameArrived,
                                ),
                        ),
                      ],
                    ),
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

/// Frames to pixels and back, for one panel width.
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
                  // Synchronous and seconds-long on a long comp; a comp with no
                  // audio, or a machine with no pipeline, says so by doing
                  // nothing rather than by an alarm.
                  try {
                    comp.detectBeats(sensitivityPercent: 50);
                  } catch (_) {
                    return;
                  }
                  onChanged();
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
  final List<LayerReference> layers;
  final LayerReference? selected;
  final ValueChanged<LayerReference> onSelect;
  final VoidCallback onChanged;

  const _Outline({
    required this.comp,
    required this.layers,
    required this.selected,
    required this.onSelect,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Aligns the first row with the first layer bar, under the ruler.
        Container(height: _rulerHeight, color: t.surface2),
        for (var i = 0; i < layers.length; i++)
          _OutlineRow(
            key: ValueKey<String>('tl-row-${layers[i].internallayerId}'),
            comp: comp,
            layer: layers[i],
            index: i,
            count: layers.length,
            selected: selected?.equals(layer: layers[i]) ?? false,
            onSelect: () => onSelect(layers[i]),
            onChanged: onChanged,
          ),
      ],
    );
  }
}

class _OutlineRow extends StatelessWidget {
  final CompositionReference comp;
  final LayerReference layer;
  final int index;
  final int count;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onChanged;

  const _OutlineRow({
    super.key,
    required this.comp,
    required this.layer,
    required this.index,
    required this.count,
    required this.selected,
    required this.onSelect,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final switches = layer.getSwitches();
    final id = layer.internallayerId.toString();

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onSelect,
      onSecondaryTapDown: (d) => _showRowMenu(context, d.globalPosition),
      child: Container(
        height: _rowHeight,
        color: selected ? t.surface2 : null,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            SizedBox(
              width: 20,
              child: Text('${index + 1}',
                  style: t.small.copyWith(color: t.textMuted)),
            ),
            _switch(context, id, 'visible', LumitIcon.eye, switches.visible,
                BridgeLayerSwitch.visible),
            _switch(context, id, 'audible', LumitIcon.audio, switches.audible,
                BridgeLayerSwitch.audible),
            // No solo glyph in the icon set; the star reads as isolate.
            _switch(context, id, 'solo', LumitIcon.star, switches.solo,
                BridgeLayerSwitch.solo),
            _switch(context, id, 'locked', LumitIcon.lock, switches.locked,
                BridgeLayerSwitch.locked),
            const SizedBox(width: 4),
            Expanded(
              child: Text(layer.getName(),
                  style: t.body, overflow: TextOverflow.ellipsis),
            ),
            _blendPicker(context, t),
            const SizedBox(width: 4),
            ParentPickerFrb(
              comp: comp,
              layer: layer,
              onChanged: onChanged,
            ),
          ],
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
        onChanged();
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

  Widget _blendPicker(BuildContext context, LumitTheme t) {
    final modes = listBlendModes();
    final current = layer.getBlend();
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
          onChanged();
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
    onChanged();
  }
}

/// The right column: the ruler, the playhead, and one bar per layer.
class _LayerArea extends StatelessWidget {
  final CompositionReference comp;
  final List<LayerReference> layers;
  final _Axis axis;
  final int playhead;
  final bool razor;
  final ValueChanged<int> onSeek;
  final VoidCallback onChanged;

  /// Bumped when something may have changed which frames are held, so the bar
  /// repaints then rather than polling the cache on every frame it draws.
  final ValueListenable<int> cacheRevision;

  const _LayerArea({
    required this.comp,
    required this.layers,
    required this.axis,
    required this.playhead,
    required this.razor,
    required this.onSeek,
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
            for (final layer in layers)
              _Bar(
                key: ValueKey<String>('tl-bar-${layer.internallayerId}'),
                comp: comp,
                layer: layer,
                axis: axis,
                razor: razor,
                playhead: playhead,
                onChanged: onChanged,
              ),
          ],
        ),
        // The playhead rides above every bar so it is never hidden behind one.
        Positioned(
          left: axis.xOf(playhead),
          top: 0,
          bottom: 0,
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
  final LayerReference layer;
  final _Axis axis;
  final bool razor;
  final int playhead;
  final VoidCallback onChanged;

  const _Bar({
    super.key,
    required this.comp,
    required this.layer,
    required this.axis,
    required this.razor,
    required this.playhead,
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

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final span = widget.layer.getSpan();
    final inFrame = widget.comp.frameAtTime(time: span.inPoint);
    final outFrame = widget.comp.frameAtTime(time: span.outPoint);

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
                        widget.layer.cutClipAt(frame: widget.playhead);
                      } catch (_) {
                        return;
                      }
                      widget.onChanged();
                    }
                  : null,
              onHorizontalDragStart: widget.razor
                  ? null
                  : (d) => setState(() {
                        _delta = 0;
                        _grab = d.localPosition.dx < _trimGrab
                            ? _Grab.trimIn
                            : d.localPosition.dx > width - _trimGrab
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
                  color: _colourFor(widget.layer.getKind(), t),
                  borderRadius: BorderRadius.circular(2),
                ),
                // A Sequence layer draws its clip splits, so the razor has
                // something to aim at and a cut is visible once made.
                child: Stack(
                  children: [
                    for (final clip in widget.layer.getClips())
                      Positioned(
                        left: widget.axis.xOf(
                              widget.comp.frameAtTime(time: clip.placeStart),
                            ) -
                            0.5,
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

    final span = widget.layer.getSpan();
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

    widget.layer.setSpan(
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
