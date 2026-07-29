// The Timeline's smaller surfaces: comp tabs, the cache bar, the search field,
// the parent picker, and the marker / work-area editors. (The cache *meter*
// moved to the shell's status line, where whole-store readouts belong.)
//
// A file of their own rather than more of timeline_panel_frb.dart, which is
// already the length it wants to be. Each is small, self-contained and used
// once — kept together because they are all "the chrome around the tracks"
// rather than because they share anything.

import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../icons/icons.dart';
import '../state/comp_time.dart';
import '../state/timeline_columns.dart';
import '../theme/theme.dart';
import '../widgets/controls.dart';

/// The open compositions, as tabs. Clicking one fronts it; its × closes the
/// tab (docs/07 §4: one tab per *open* comp — the comp itself stays in the
/// project, and fronting it from the Project panel opens it again).
class CompTabsFrb extends StatelessWidget {
  final LumitState state;
  final LumitUiState uiState;
  const CompTabsFrb({super.key, required this.state, required this.uiState});

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    // Served from LumitState's cached walk (K-184): the item tree is only
    // re-read when the engine says it changed shape. Filtered to the tabs the
    // user has opened, so a deleted comp's tab also simply stops matching.
    final selected = uiState.selectedComp?.internalid;
    final comps = [
      for (final entry in state.comps())
        if (uiState.openComps.contains(entry.$1.internalid) ||
            entry.$1.internalid == selected)
          entry,
    ];
    if (comps.isEmpty) return const SizedBox.shrink();

    return Container(
      height: 22,
      color: t.surface2,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (var i = 0; i < comps.length; i++)
            _CompTab(
              key: ValueKey<String>('tl-tab-${comps[i].$1.internalid}'),
              name: comps[i].$2,
              active: selected == comps[i].$1.internalid,
              onTap: () => uiState.setSelectedComp(comps[i].$1),
              closeKey:
                  ValueKey<String>('tl-tab-close-${comps[i].$1.internalid}'),
              onClose: () => uiState.closeComp(
                comps[i].$1.internalid,
                // The nearest remaining neighbour fronts: the one to the
                // left, or the next one when the first tab closes.
                fallback:
                    comps.length == 1 ? null : comps[i == 0 ? 1 : i - 1].$1,
              ),
            ),
        ],
      ),
    );
  }
}

class _CompTab extends StatelessWidget {
  final String name;
  final bool active;
  final VoidCallback onTap;
  final Key closeKey;
  final VoidCallback onClose;
  const _CompTab({
    super.key,
    required this.name,
    required this.active,
    required this.onTap,
    required this.closeKey,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.only(left: 10, right: 4),
        decoration: BoxDecoration(
          color: active ? t.surface0 : null,
          border: Border(
            bottom: BorderSide(
              color: active ? t.accent : const Color(0x00000000),
              width: 2,
            ),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Text(
                name,
                style: active ? t.bodyPrimary : t.small,
              ),
            ),
            const SizedBox(width: 4),
            GestureDetector(
              key: closeKey,
              behavior: HitTestBehavior.opaque,
              onTap: onClose,
              child: SizedBox(
                width: 14,
                height: 22,
                child: Center(
                  child: Text('×', style: t.small.copyWith(color: t.textMuted)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The outline's search field: narrows the rows to those whose name matches.
class LayerSearchFrb extends StatefulWidget {
  final ValueChanged<String> onChanged;
  final double width;
  const LayerSearchFrb({super.key, required this.onChanged, this.width = 120});

  @override
  State<LayerSearchFrb> createState() => _LayerSearchFrbState();
}

class _LayerSearchFrbState extends State<LayerSearchFrb> {
  final TextEditingController _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => widget.onChanged(_controller.text));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => HouseTextField(
        key: const ValueKey('tl-search'),
        controller: _controller,
        width: widget.width,
        hint: 'Search layers',
      );
}

/// The parent picker: every *other* layer in the comp, plus None.
///
/// A layer cannot parent to itself, so it is not in its own list — the engine
/// refuses it anyway, but offering a choice that always fails is a worse way to
/// say so than not offering it.
///
/// Costs no bridge calls at all (K-184): the current parent's name and every
/// other layer's name come from the read model. This used to be one name call
/// per other layer per row per rebuild — O(layers²) across the outline.
class ParentPickerFrb extends StatelessWidget {
  final LayerReference layer;
  final BridgeLayerInfo info;

  /// Every layer in the comp, from the read model.
  final List<BridgeLayerEntry> all;

  /// The cell's width — its share of the compose group, which the header's
  /// seam can be dragged to widen.
  final double width;
  final VoidCallback onChanged;

  const ParentPickerFrb({
    super.key,
    required this.layer,
    required this.info,
    required this.all,
    required this.onChanged,
    this.width = parentCellWidth,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: BareLazyDropdown(
        key: ValueKey<String>('tl-parent-${layer.internallayerId}'),
        label: info.parent == null ? 'None' : (info.parentName ?? 'None'),
        options: () => [
          (null, 'None'),
          for (final e in all)
            if (e.layer.internallayerId != layer.internallayerId)
              (e.layer.internallayerId, e.info.name),
        ],
        onChanged: (id) {
          // A cycle is refused engine-side; the picker reports nothing and the
          // row keeps the parent it had.
          try {
            layer.setParent(parent: id);
          } catch (_) {
            return;
          }
          onChanged();
        },
      ),
    );
  }
}

/// The layer's matte cell (docs/06 §1.6): which layer gates this one, drawn
/// straight from the row's info (K-184). The dropdown picks the source; with
/// one set, the two small toggles choose luma-over-alpha and invert.
class MattePickerFrb extends StatelessWidget {
  final LayerReference layer;
  final BridgeLayerInfo info;

  /// Every layer in the comp, from the read model.
  final List<BridgeLayerEntry> all;

  /// The cell's width — its share of the compose group, which the header's
  /// seam can be dragged to widen.
  final double width;
  final VoidCallback onChanged;

  const MattePickerFrb({
    super.key,
    required this.layer,
    required this.info,
    required this.all,
    required this.onChanged,
    this.width = matteCellWidth,
  });

  void _set(BridgeMatte? matte) {
    try {
      layer.setMatte(matte: matte);
    } catch (_) {
      return;
    }
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final matte = info.matte;
    final sourceName = matte == null
        ? 'No matte'
        : all
                .where((e) => e.layer.internallayerId == matte.layer)
                .map((e) => e.info.name)
                .firstOrNull ??
            'Matte';

    // A fixed overall width whether or not the mode toggles are showing, so
    // the columns after the matte cell never shift as mattes come and go —
    // with no matte set, the dropdown takes the toggles' room rather than
    // leaving a dead gap before the blend cell.
    return SizedBox(
      width: width,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            // The two mode toggles are 28 px between them; with no matte set
            // the dropdown takes that room rather than leaving a dead gap.
            width: matte == null ? width : (width - 28).clamp(40.0, width),
            child: BareLazyDropdown<UuidValue?>(
              key: ValueKey<String>('tl-matte-${layer.internallayerId}'),
              label: sourceName,
              // Built when the menu opens, never per rebuild — which is what
              // lets it probe (K-194). A matte gates this layer with another
              // layer's *picture*, so a layer with none (a camera, a Null, an
              // audio-only clip) is not offered, and neither is this one:
              // matting a layer with itself has no meaning.
              options: () => [
                (null, 'No matte'),
                for (final e in all)
                  if (e.layer.internallayerId != layer.internallayerId &&
                      e.layer.hasPicture())
                    (e.layer.internallayerId, e.info.name),
              ],
              onChanged: (id) => _set(id == null
                  ? null
                  : BridgeMatte(
                      layer: id,
                      luma: matte?.luma ?? false,
                      inverted: matte?.inverted ?? false,
                    )),
            ),
          ),
          // The mode toggles only mean something once a source is set.
          if (matte != null) ...[
            _toggle(
              t,
              key: 'tl-matte-luma-${layer.internallayerId}',
              glyph: matte.luma ? 'L' : 'α',
              on: true,
              tip: matte.luma ? 'Luma matte' : 'Alpha matte',
              onTap: () => _set(BridgeMatte(
                  layer: matte.layer,
                  luma: !matte.luma,
                  inverted: matte.inverted)),
            ),
            _toggle(
              t,
              key: 'tl-matte-invert-${layer.internallayerId}',
              glyph: '−',
              on: matte.inverted,
              tip: matte.inverted ? 'Inverted' : 'Not inverted',
              onTap: () => _set(BridgeMatte(
                  layer: matte.layer,
                  luma: matte.luma,
                  inverted: !matte.inverted)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _toggle(
    LumitTheme t, {
    required String key,
    required String glyph,
    required bool on,
    required String tip,
    required VoidCallback onTap,
  }) {
    return LumitTooltip(
      message: tip,
      child: GestureDetector(
        key: ValueKey<String>(key),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: 14,
          height: 22,
          child: Center(
            child: Text(glyph,
                style: t.small
                    .copyWith(color: on ? t.textPrimary : t.textDisabled)),
          ),
        ),
      ),
    );
  }
}

/// Add, rename and remove markers, and set the work area, from one dialogue.
///
/// A dialogue rather than direct manipulation on the ruler: dragging markers is
/// its own gesture layer, and having the commands somewhere reachable first
/// means the capability exists before the polish does.
Future<void> showMarkerEditorFrb({
  required BuildContext context,
  required CompositionReference comp,
  required int playheadFrame,
}) async {
  await showLumitModal<void>(
    context: context,
    builder: (close) => _MarkerEditor(
      comp: comp,
      playheadFrame: playheadFrame,
      onClose: () => close(null),
    ),
  );
}

class _MarkerEditor extends StatefulWidget {
  final CompositionReference comp;
  final int playheadFrame;
  final VoidCallback onClose;
  const _MarkerEditor({
    required this.comp,
    required this.playheadFrame,
    required this.onClose,
  });

  @override
  State<_MarkerEditor> createState() => _MarkerEditorState();
}

class _MarkerEditorState extends State<_MarkerEditor> {
  final TextEditingController _label = TextEditingController();

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final markers = widget.comp.getMarkers();

    return FloatSurface(
      width: 340,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text('Markers', style: t.bodyPrimary),
          ),
          for (final marker in markers)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: Row(
                children: [
                  SizedBox(
                    width: 44,
                    child: Text(
                      '${frameAtTime(widget.comp, marker.time)}',
                      style: t.mono,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      marker.label.isEmpty ? '(no label)' : marker.label,
                      style: t.body,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  HouseButton(
                    key: ValueKey<String>('marker-remove-${marker.id}'),
                    small: true,
                    frameless: true,
                    onPressed: () {
                      widget.comp.setMarkers(
                        markers: [
                          for (final m in markers)
                            if (m.id != marker.id) m,
                        ],
                      );
                      setState(() {});
                    },
                    child:
                        Text('×', style: t.small.copyWith(color: t.textMuted)),
                  ),
                ],
              ),
            ),
          if (markers.isEmpty)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text('No markers yet', style: t.small),
            ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Expanded(
                  child: HouseTextField(
                    key: const ValueKey('marker-label'),
                    controller: _label,
                    width: 170,
                  ),
                ),
                const SizedBox(width: 6),
                HouseButton(
                  key: const ValueKey('marker-add'),
                  small: true,
                  onPressed: () {
                    widget.comp.setMarkers(
                      markers: [
                        ...markers,
                        BridgeMarker(
                          id: UuidValue.fromString(const Uuid().v4()),
                          time: widget.comp
                              .timeOfFrame(frame: widget.playheadFrame),
                          label: _label.text,
                        ),
                      ],
                    );
                    _label.clear();
                    setState(() {});
                  },
                  child: Text('Add at playhead', style: t.small),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                HouseButton(
                  key: const ValueKey('marker-close'),
                  small: true,
                  onPressed: widget.onClose,
                  child: const Text('Close'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The work area as the Timeline draws it, in frames (K-203).
///
/// The engine stores "no work area" as null, which is right — it means the
/// comp has not been narrowed. The *interface* has no such state: a comp that
/// has not been narrowed is one whose work area is the whole thing, which is
/// what every editor shows and what makes the ends grabbable from the first
/// frame. Without this the handles had nothing to hang on and B and N had
/// nothing to move, so the work area read as unimplemented.
///
/// Frames, not a [BridgeSpan], because frames are what everything drawing it
/// actually wants — an x on the axis. Handing back a span meant every caller
/// converted it straight back, four bridge calls at a time, on a widget that
/// rebuilds with the panel (docs/13). `whole` says the span covers the comp,
/// which is when there is no out-of-range ground to wash.
///
/// Two bridge calls when nothing is set, four when it is. Work it out once per
/// build and pass it down rather than asking again in each widget.
({int start, int end, bool whole}) workAreaFrames(CompositionReference comp) {
  final duration = comp.durationFrames();
  final set = comp.getWorkArea();
  if (set == null) {
    return (start: 0, end: duration < 1 ? 1 : duration, whole: true);
  }
  final start = comp.frameAtTime(time: set.inPoint);
  final end = comp.frameAtTime(time: set.outPoint);
  return (start: start, end: end, whole: start <= 0 && end >= duration);
}

/// Set the work area from the playhead: one click for its start, one for its
/// end. The two buttons match the egui frontend's B and N keys.
BridgeSpan workAreaWith({
  required CompositionReference comp,
  required BridgeSpan? current,
  required int frame,
  required bool isStart,
}) {
  final duration = comp.durationFrames();
  final zero = comp.timeOfFrame(frame: 0);
  final existingIn =
      current == null ? 0 : comp.frameAtTime(time: current.inPoint);
  final existingOut =
      current == null ? duration : comp.frameAtTime(time: current.outPoint);

  // A work area has to have length, so the opposite edge gives way rather than
  // the click being ignored — the same thing the egui frontend does.
  var start = isStart ? frame : existingIn;
  var end = isStart ? existingOut : frame;
  if (end <= start) {
    if (isStart) {
      end = (start + 1).clamp(0, duration);
      if (end <= start) start = end - 1;
    } else {
      start = (end - 1).clamp(0, duration);
    }
  }

  return BridgeSpan(
    inPoint: comp.timeOfFrame(frame: start),
    outPoint: comp.timeOfFrame(frame: end),
    startOffset: zero,
  );
}

/// The glyph for a layer kind, matching the Project panel's row glyphs so a
/// footage layer reads as footage in both.
LumitIcon iconForKind(BridgeLayerKind kind) => switch (kind) {
      BridgeLayerKind.footage => LumitIcon.footage,
      BridgeLayerKind.sequence => LumitIcon.sequence,
      BridgeLayerKind.precomp => LumitIcon.comp,
      BridgeLayerKind.text => LumitIcon.text,
      BridgeLayerKind.camera => LumitIcon.camera,
      // An adjustment layer is a comp-sized effect container, drawn as a solid —
      // the same choice layer_style.dart and the egui frontend make.
      BridgeLayerKind.solid || BridgeLayerKind.adjustment => LumitIcon.solid,
      BridgeLayerKind.nullLayer => LumitIcon.nullLayer,
    };

/// The cache bar: a thin stripe under the time ruler showing which frames are
/// already rendered and held (docs/07-UI-SPEC.md §3.2, docs/15-DESIGN.md §6.3).
///
/// **What the colours mean.** Mint means the frame is held at the resolution the
/// Viewer is showing — it plays now, which is the promise the bar exists to make
/// (docs/13 §B5). A dimmed mint means it is held only at a coarser resolution
/// than is being displayed: there is something, but it would be rendered again
/// to show it at this size. Nothing drawn means nothing held. No amber, no red,
/// no pulsing — an empty cache is not a fault.
///
/// The design language reserves steel blue for frames on disk only. There is no
/// disk frame cache in this engine yet, so that state cannot occur and is not
/// drawn; when one arrives it is a third value from `cachedFrames` and a third
/// colour here.
///
/// **It never polls.** The cache's lock is the one a render holds, so reading it
/// per paint would put the interface behind the renderer. `revision` is bumped
/// when a frame arrives, and only then is the cache asked again.
class TimelineCacheBar extends StatelessWidget {
  final CompositionReference comp;
  final CacheBarAxis axis;
  final Listenable revision;

  /// Two logical pixels, per docs/15 §6.3.
  static const double height = 2;

  const TimelineCacheBar({
    super.key,
    required this.comp,
    required this.axis,
    required this.revision,
  });

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return ListenableBuilder(
      listenable: revision,
      builder: (context, _) {
        final frames = axis.frames;
        final tiers = frames <= 0
            ? Uint8List(0)
            : comp.cachedFrames(
                frames: BigInt.from(frames),
                scale: Provider.of<LumitUiState>(context, listen: false)
                    .viewerScale,
              );
        return SizedBox(
          height: height,
          child: CustomPaint(
            key: const ValueKey('tl-cache-bar'),
            painter: _CacheBarPainter(
              tiers: tiers,
              axis: axis,
              ready: t.success,
              coarse: t.success.withValues(alpha: 0.4),
            ),
          ),
        );
      },
    );
  }
}

/// What the cache bar needs from the Timeline's frames-to-pixels mapping. Named
/// separately so the painter can be tested without building a Timeline.
abstract class CacheBarAxis {
  int get frames;
  double xOf(int frame);
}

/// The Timeline's one frames-to-pixels mapping, shared by the lane view and
/// the graph editor so a frame sits at the same x in both — zoom and scroll
/// included.
class TimelineAxis implements CacheBarAxis {
  @override
  final int frames;
  final double width;
  const TimelineAxis({required this.frames, required this.width});

  double get perFrame => frames <= 0 ? 0 : width / frames;
  @override
  double xOf(num frame) => frame * perFrame;
  int frameAt(double x) => perFrame <= 0 ? 0 : (x / perFrame).round();
}

/// The time ruler: the time labels and ticks, the work area, the markers, and
/// the scrub surface — drawn over the lanes in lane view and over the curves
/// in graph view, so neither loses the clock (docs/07 §4.1, §5).
class TimelineRuler extends StatefulWidget {
  final CompositionReference comp;
  final TimelineAxis axis;

  /// The comp's rate, turning frames into the seconds the labels speak.
  final double fps;
  final double height;
  final ValueChanged<int> onSeek;

  /// Dragging a work-area edge (K-202). Given the new span; null leaves the
  /// edges as plain marks, which is what a caller with nothing to commit to
  /// wants.
  final void Function(BridgeSpan span)? onWorkArea;

  /// Where the work area falls, in frames — worked out once by the panel and
  /// handed down, because asking the engine again in each widget that draws it
  /// is a per-rebuild cost on a panel that rebuilds a lot (docs/13).
  final ({int start, int end, bool whole}) work;

  const TimelineRuler({
    super.key,
    required this.comp,
    required this.axis,
    required this.fps,
    required this.height,
    required this.onSeek,
    required this.work,
    this.onWorkArea,
  });

  @override
  State<TimelineRuler> createState() => _TimelineRulerState();
}

class _TimelineRulerState extends State<TimelineRuler> {
  /// The frame a work-area edge has been dragged to, and which edge it is.
  ///
  /// Held here so the handle follows the pointer at once: committing a drag
  /// goes through the engine and comes back out as a fresh `work`, and drawing
  /// the edge from *that* left it visibly trailing the mouse. The commit still
  /// happens on every frame the drag crosses — this only decides where the
  /// edge is drawn while the button is down.
  int? _dragFrame;
  bool _dragIsStart = false;

  /// The work area as it should draw right now: the panel's, with the edge
  /// being dragged moved to where the pointer is. Each edge stops one frame
  /// short of the other, the rule [workAreaWith] commits.
  ({int start, int end, bool whole}) get _work {
    final work = widget.work;
    final frame = _dragFrame;
    if (frame == null) return work;
    return _dragIsStart
        ? (start: frame.clamp(0, work.end - 1), end: work.end, whole: false)
        : (
            start: work.start,
            end: frame.clamp(work.start + 1, widget.axis.frames),
            whole: false
          );
  }

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final comp = widget.comp;
    final axis = widget.axis;
    final work = _work;
    final markers = comp.getMarkers();

    return GestureDetector(
      key: const ValueKey('tl-ruler'),
      behavior: HitTestBehavior.opaque,
      onTapDown: (d) => widget.onSeek(axis.frameAt(d.localPosition.dx)),
      onHorizontalDragUpdate: (d) =>
          widget.onSeek(axis.frameAt(d.localPosition.dx)),
      child: Container(
        height: widget.height,
        color: t.surface2,
        child: Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _RulerTicksPainter(
                    axis: axis,
                    fps: widget.fps,
                    tick: t.hairlineStrong,
                    label: t.small.copyWith(color: t.textMuted),
                  ),
                ),
              ),
            ),
            // The work area: the span the Viewer previews and the export
            // writes. The ruler's lower half only, so the ticks and labels
            // above it stay legible and the band reads as a bar hung under the
            // clock rather than a tint over it.
            Positioned(
              left: axis.xOf(work.start),
              width:
                  (axis.xOf(work.end) - axis.xOf(work.start)).clamp(1.0, 1e6),
              top: widget.height / 2,
              bottom: 0,
              child: IgnorePointer(
                child: Container(
                  key: const ValueKey('tl-work-area'),
                  color: t.accent.withValues(alpha: 0.14),
                ),
              ),
            ),
            // The work area's two edges, draggable (K-202). Grabbable rather
            // than drawn-only: the menu's "set from playhead" is precise but
            // roundabout, and a span you can see is one you expect to be able
            // to take hold of. Each edge stops one frame short of the other,
            // so a drag can never invert the span.
            //
            // Only in the lower half, where the band is drawn. A handle over
            // the full height sat on top of the ticks and stole the drag from
            // the playhead whenever the two were near each other, which made
            // the playhead unscrubbable next to a work-area edge. The rule is
            // the one the band already reads as: clock above, bar below.
            if (widget.onWorkArea != null)
              for (final isStart in const [true, false])
                Positioned(
                  left: axis.xOf(isStart ? work.start : work.end) -
                      _workHandleWidth / 2,
                  width: _workHandleWidth,
                  top: widget.height / 2,
                  bottom: 0,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeLeftRight,
                    child: GestureDetector(
                      key: ValueKey('tl-work-${isStart ? 'start' : 'end'}'),
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragStart: (_) =>
                          setState(() => _dragIsStart = isStart),
                      onHorizontalDragUpdate: (d) {
                        final frame = axis
                            .frameAt(d.globalPosition.dx - _originX(context));
                        if (frame == _dragFrame) return;
                        // Drawn from here at once; committed only when the
                        // drag actually crosses a frame, because the commit
                        // costs a document write and a panel rebuild while a
                        // pointer emits many moves per frame of travel.
                        setState(() => _dragFrame = frame);
                        widget.onWorkArea!(workAreaWith(
                          comp: comp,
                          current: comp.getWorkArea(),
                          frame: frame,
                          isStart: isStart,
                        ));
                      },
                      onHorizontalDragEnd: (_) =>
                          setState(() => _dragFrame = null),
                      onHorizontalDragCancel: () =>
                          setState(() => _dragFrame = null),
                      // The grab stays the ruler's full height — a handle you
                      // have to aim at is not a handle — while the mark it
                      // draws follows the band into the lower half.
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: SizedBox(
                          width: 2,
                          height: widget.height / 2,
                          child: ColoredBox(color: t.accent),
                        ),
                      ),
                    ),
                  ),
                ),
            for (final marker in markers)
              Positioned(
                left: axis.xOf(frameAtTime(comp, marker.time)) - 3,
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

/// How wide a work-area edge is to grab. Wider than the 2 px it draws, so the
/// handle is catchable without the mark being heavy.
const double _workHandleWidth = 10;

/// The playhead: a hairline down the whole area with a head at the top.
///
/// The head is the familiar editor marker — a bare hairline is findable only by
/// hunting along the ruler, and at a glance it reads as a row seam rather than
/// as where you are. The notch through it is drawn in the darkest surface (so
/// black on a dark scheme, white on a light one), which is what makes the head
/// read as the line running *into* it rather than a shape parked near it.
///
/// Centred on the frame, so a caller positions it at `xOf(frame) - halfWidth`.
class PlayheadMarker extends StatelessWidget {
  const PlayheadMarker({super.key});

  /// Half the head's width — how far left of the frame the marker starts.
  static const double halfWidth = 5;

  /// How tall the head is. It sits at the very top of the ruler, with the
  /// labels: in the lower half the work-area band would sit over it.
  static const double headHeight = 8;

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return IgnorePointer(
      child: SizedBox(
        width: halfWidth * 2 + 1,
        child: Column(
          children: [
            CustomPaint(
              size: const Size(halfWidth * 2 + 1, headHeight),
              painter: _PlayheadHeadPainter(head: t.accent, notch: t.surface0),
            ),
            Expanded(
              child: SizedBox(width: 1, child: ColoredBox(color: t.accent)),
            ),
          ],
        ),
      ),
    );
  }
}

/// The playhead's head: a downward triangle with the hairline carried up into
/// it as a notch.
class _PlayheadHeadPainter extends CustomPainter {
  final Color head;
  final Color notch;

  const _PlayheadHeadPainter({required this.head, required this.notch});

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.width / 2;
    canvas.drawPath(
      Path()
        ..moveTo(0, 0)
        ..lineTo(size.width, 0)
        ..lineTo(mid, size.height)
        ..close(),
      Paint()..color = head,
    );
    // Up from the tip to about where the triangle is still wide enough to hold
    // it: the short stub that joins the head to the line.
    canvas.drawLine(
      Offset(mid, size.height * 0.45),
      Offset(mid, size.height),
      Paint()
        ..color = notch
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_PlayheadHeadPainter old) =>
      old.head != head || old.notch != notch;
}

/// The ruler's left edge in global coordinates — a drag reports globally, and
/// the axis speaks in the ruler's own pixels.
double _originX(BuildContext context) {
  final box = context.findRenderObject();
  return box is RenderBox ? box.localToGlobal(Offset.zero).dx : 0;
}

/// The label step for a ruler: the smallest nice second count whose labels
/// sit at least ~80 px apart, so zooming out thins the labels rather than
/// piling them up. Exposed for its test.
double rulerLabelStepSeconds({required double pixelsPerSecond}) {
  const nice = [
    0.5,
    1.0,
    2.0,
    5.0,
    10.0,
    15.0,
    30.0,
    60.0,
    120.0,
    300.0,
    600.0
  ];
  for (final step in nice) {
    if (step * pixelsPerSecond >= 80) return step;
  }
  return nice.last;
}

/// A ruler label: seconds under a minute as `05s`, above as `01:00s` — the
/// familiar editor idiom.
String rulerLabelOf(double seconds) {
  final whole = seconds.round();
  if (seconds < 60) {
    final text = seconds == whole
        ? whole.toString().padLeft(2, '0')
        : seconds.toStringAsFixed(1);
    return '${text}s';
  }
  final m = whole ~/ 60;
  final s = whole % 60;
  return '$m:${s.toString().padLeft(2, '0')}s';
}

/// The ruler's ticks and time labels: a labelled tick per nice step, minor
/// ticks per second when there is room.
class _RulerTicksPainter extends CustomPainter {
  final TimelineAxis axis;
  final double fps;
  final Color tick;
  final TextStyle label;

  const _RulerTicksPainter({
    required this.axis,
    required this.fps,
    required this.tick,
    required this.label,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (axis.frames <= 0 || fps <= 0 || size.width <= 0) return;
    final seconds = axis.frames / fps;
    final pxPerSec = size.width / seconds;
    final step = rulerLabelStepSeconds(pixelsPerSecond: pxPerSec);
    final paint = Paint()
      ..color = tick
      ..strokeWidth = 1;

    // Minor ticks each second, only when they have a few pixels each.
    if (pxPerSec >= 6) {
      for (var s = 0.0; s <= seconds; s += 1) {
        final x = s * pxPerSec;
        canvas.drawLine(
            Offset(x, size.height - 4), Offset(x, size.height), paint);
      }
    }

    for (var s = 0.0; s <= seconds; s += step) {
      final x = s * pxPerSec;
      canvas.drawLine(
          Offset(x, size.height - 9), Offset(x, size.height), paint);
      final text = TextPainter(
        text: TextSpan(text: rulerLabelOf(s), style: label),
        textDirection: TextDirection.ltr,
      )..layout();
      // Labels sit just right of their tick; the last one may clip out at the
      // comp's end rather than jumping inside, which would misplace it.
      text.paint(canvas, Offset(x + 3, 2));
    }
  }

  @override
  bool shouldRepaint(_RulerTicksPainter old) =>
      old.fps != fps ||
      old.tick != tick ||
      old.axis.frames != axis.frames ||
      old.axis.width != axis.width;
}

/// Collapse per-frame tiers into the fewest contiguous runs, so a 3000-frame
/// composition draws a handful of rectangles rather than three thousand.
///
/// Returns `(startFrame, endFrameExclusive, tier)`, skipping tier 0.
List<(int, int, int)> cacheBarRuns(List<int> tiers) {
  final runs = <(int, int, int)>[];
  var start = 0;
  while (start < tiers.length) {
    final tier = tiers[start];
    var end = start + 1;
    while (end < tiers.length && tiers[end] == tier) {
      end++;
    }
    if (tier != 0) runs.add((start, end, tier));
    start = end;
  }
  return runs;
}

class _CacheBarPainter extends CustomPainter {
  final Uint8List tiers;
  final CacheBarAxis axis;
  final Color ready;
  final Color coarse;

  const _CacheBarPainter({
    required this.tiers,
    required this.axis,
    required this.ready,
    required this.coarse,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    for (final (start, end, tier) in cacheBarRuns(tiers)) {
      paint.color = tier >= 2 ? ready : coarse;
      final left = axis.xOf(start).clamp(0.0, size.width);
      // The run's right edge is the left edge of the frame after it, so a run
      // covers its last frame rather than stopping at that frame's start. At
      // least a hairline wide so a single held frame still shows, but never
      // wider than the bar — and never expressed as a clamp whose lower bound
      // could exceed its upper, because `num.clamp` throws outright when it
      // does. A composition longer than the panel is wide in pixels reaches
      // exactly that case at its last frame.
      final right = axis.xOf(end).clamp(left, size.width);
      canvas.drawRect(
          Rect.fromLTRB(
              left, 0, max(right, min(left + 1, size.width)), size.height),
          paint);
    }
  }

  @override
  bool shouldRepaint(_CacheBarPainter old) =>
      old.tiers != tiers || old.ready != ready || old.coarse != coarse;
}

/// The Timeline's two-tone ground (K-202): the work area at one value, and a
/// darker wash either side of it.
///
/// Painted rather than laid out as two boxes because it sits *under* the bars
/// and the marquee, and a decorated box there would absorb the pointer — the
/// same reason the row seams are a painter. With no work area both shades
/// collapse to the inside one, so an unmarked comp looks exactly as it did.
class WorkAreaGroundPainter extends CustomPainter {
  /// The work area's edges in this area's own pixels, or null for none.
  final double? startX;
  final double? endX;
  final Color inside;
  final Color outside;

  const WorkAreaGroundPainter({
    required this.startX,
    required this.endX,
    required this.inside,
    required this.outside,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final full = Offset.zero & size;
    if (startX == null || endX == null) {
      if (inside.a > 0) canvas.drawRect(full, Paint()..color = inside);
      return;
    }
    // A transparent inside makes this an overlay: the same wash painted over
    // the bars instead of under them, so the span being delivered is legible
    // across a row that has a layer in it — which is every row worth looking
    // at. Only the two outside strips are painted; there is nothing to lay
    // over the work area itself.
    if (inside.a == 0) {
      final paint = Paint()..color = outside;
      final from = startX!.clamp(0.0, size.width);
      final to = endX!.clamp(from, size.width);
      canvas.drawRect(Rect.fromLTRB(0, 0, from, size.height), paint);
      canvas.drawRect(Rect.fromLTRB(to, 0, size.width, size.height), paint);
      return;
    }
    // The wash goes down first and the work area is painted back over it, so
    // the two always meet exactly — two abutting rectangles would show a seam
    // at fractional pixel positions.
    canvas.drawRect(full, Paint()..color = outside);
    final left = startX!.clamp(0.0, size.width);
    final right = endX!.clamp(0.0, size.width);
    if (right > left) {
      canvas.drawRect(
        Rect.fromLTRB(left, 0, right, size.height),
        Paint()..color = inside,
      );
    }
  }

  @override
  bool shouldRepaint(WorkAreaGroundPainter old) =>
      old.startX != startX ||
      old.endX != endX ||
      old.inside != inside ||
      old.outside != outside;

  /// Never absorbs a pointer — it is the ground, not a control.
  @override
  bool? hitTest(Offset position) => false;
}
