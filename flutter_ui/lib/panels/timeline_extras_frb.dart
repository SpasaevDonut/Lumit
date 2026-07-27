// The Timeline's smaller surfaces: comp tabs, the cache bar, the search field,
// the parent picker, and the marker / work-area editors.
//
// A file of their own rather than more of timeline_panel_frb.dart, which is
// already the length it wants to be. Each is small, self-contained and used
// once — kept together because they are all "the chrome around the tracks"
// rather than because they share anything.

import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/src/rust/api/cache.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../icons/icons.dart';
import '../widgets/controls.dart';

/// The open compositions, as tabs. Clicking one fronts it.
///
/// "Open" here means every composition in the project, which is what the egui
/// frontend shows too: a comp you can see in the Project panel is one you can
/// switch to, and a separate notion of open-ness would be state to keep in step
/// for no gain.
class CompTabsFrb extends StatelessWidget {
  final LumitState state;
  final LumitUiState uiState;
  const CompTabsFrb({super.key, required this.state, required this.uiState});

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    // Served from LumitState's cached walk (K-184): the item tree is only
    // re-read when the engine says it changed shape.
    final comps = state.comps();
    if (comps.isEmpty) return const SizedBox.shrink();

    return Container(
      height: 22,
      color: t.surface2,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final (comp, name) in comps)
            _CompTab(
              key: ValueKey<String>('tl-tab-${comp.internalid}'),
              name: name,
              active: uiState.selectedComp?.internalid == comp.internalid,
              onTap: () => uiState.setSelectedComp(comp),
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
  const _CompTab({
    super.key,
    required this.name,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: active ? t.surface0 : null,
          border: Border(
            bottom: BorderSide(
              color: active ? t.accent : const Color(0x00000000),
              width: 2,
            ),
          ),
        ),
        child: Center(
          child: Text(
            name,
            style: active ? t.bodyPrimary : t.small,
          ),
        ),
      ),
    );
  }
}

/// How full the rendered-frame cache is, and how often it saved a render.
///
/// Polled on the panel's own rebuilds rather than on a timer: the numbers only
/// change when something renders, and a timer would wake the interface up to
/// redraw a meter nobody is watching. Never read per paint — the lock it takes
/// is the one a render holds.
///
/// Named a *meter*, not a bar: the **cache bar** is the stripe under the time
/// ruler showing which frames are held ([`TimelineCacheBar`], and the glossary's
/// own definition). This measures how full the store is, which is a different
/// question.
class CacheMeterFrb extends StatelessWidget {
  const CacheMeterFrb({super.key});

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final stats = cacheStats();
    final budget = stats.budgetBytes.toInt();
    final used = stats.usedBytes.toInt();
    final fraction = budget <= 0 ? 0.0 : (used / budget).clamp(0.0, 1.0);
    final requests = stats.hits.toInt() + stats.misses.toInt();

    return LumitTooltip(
      message: requests == 0
          ? 'Nothing rendered yet'
          : '${stats.hits} served from the cache, ${stats.misses} rendered',
      child: GestureDetector(
        key: const ValueKey('tl-cache-meter'),
        behavior: HitTestBehavior.opaque,
        onTap: () => clearCache(),
        child: Container(
          height: 14,
          color: t.surface1,
          child: Row(
            children: [
              const SizedBox(width: 6),
              Text('Cache', style: t.small.copyWith(color: t.textMuted)),
              const SizedBox(width: 6),
              Expanded(
                child: Stack(
                  children: [
                    Container(height: 6, color: t.surface3),
                    FractionallySizedBox(
                      widthFactor: fraction,
                      child: Container(height: 6, color: t.accent),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Text('${_mib(used)} / ${_mib(budget)} MB',
                  style: t.small.copyWith(color: t.textMuted)),
              const SizedBox(width: 6),
            ],
          ),
        ),
      ),
    );
  }

  static String _mib(int bytes) => (bytes / (1 << 20)).toStringAsFixed(0);
}

/// The outline's search field: narrows the rows to those whose name matches.
class LayerSearchFrb extends StatefulWidget {
  final ValueChanged<String> onChanged;
  const LayerSearchFrb({super.key, required this.onChanged});

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
        width: 120,
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
  final VoidCallback onChanged;

  const ParentPickerFrb({
    super.key,
    required this.layer,
    required this.info,
    required this.all,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 96,
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
                      '${widget.comp.frameAtTime(time: marker.time)}',
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
                    child: Text('×',
                        style: t.small.copyWith(color: t.textMuted)),
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
