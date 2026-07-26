// The Timeline's smaller surfaces: comp tabs, the cache bar, the search field,
// the parent picker, and the marker / work-area editors.
//
// A file of their own rather than more of timeline_panel_frb.dart, which is
// already the length it wants to be. Each is small, self-contained and used
// once — kept together because they are all "the chrome around the tracks"
// rather than because they share anything.

import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/src/rust/api/cache.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';
import 'package:lumit_flutter/src/rust/api/project_item.dart';
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

  /// Every composition in the project, folders walked.
  List<CompositionReference> _comps() {
    final out = <CompositionReference>[];
    void walk(List<ItemReference> items) {
      for (final item in items) {
        switch (item) {
          case ItemReference_Composition(:final field0):
            out.add(field0);
          case ItemReference_Folder(:final field0):
            walk(field0.getChildren());
          case _:
            break;
        }
      }
    }

    walk(state.project?.getItems() ?? const []);
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final comps = _comps();
    if (comps.isEmpty) return const SizedBox.shrink();

    return Container(
      height: 22,
      color: t.surface2,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final comp in comps)
            _CompTab(
              key: ValueKey<String>('tl-tab-${comp.internalid}'),
              comp: comp,
              active: uiState.selectedComp?.internalid == comp.internalid,
              onTap: () => uiState.setSelectedComp(comp),
            ),
        ],
      ),
    );
  }
}

class _CompTab extends StatelessWidget {
  final CompositionReference comp;
  final bool active;
  final VoidCallback onTap;
  const _CompTab({
    super.key,
    required this.comp,
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
            comp.getSettings().name,
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
/// redraw a bar nobody is watching. Never read per paint — the lock it takes is
/// the one a render holds.
class CacheBarFrb extends StatelessWidget {
  const CacheBarFrb({super.key});

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
        key: const ValueKey('tl-cache-bar'),
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

/// The sentinel a nullable dropdown option needs — see [ParentPickerFrb].
const String _noParent = '';

/// The parent picker: every *other* layer in the comp, plus None.
///
/// A layer cannot parent to itself, so it is not in its own list — the engine
/// refuses it anyway, but offering a choice that always fails is a worse way to
/// say so than not offering it.
class ParentPickerFrb extends StatelessWidget {
  final CompositionReference comp;
  final LayerReference layer;
  final VoidCallback onChanged;

  const ParentPickerFrb({
    super.key,
    required this.comp,
    required this.layer,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final others = [
      for (final l in comp.getLayers())
        if (l.internallayerId != layer.internallayerId) l,
    ];
    final names = {
      for (final l in others) l.internallayerId.toString(): l.getName(),
    };
    final current = layer.getParent()?.toString();

    // The empty string stands for "no parent", not `null`: `showLumitPopup`
    // completes with null when its barrier is tapped, so a nullable option is
    // indistinguishable from dismissing the menu and can never be chosen.
    return SizedBox(
      width: 96,
      child: BareDropdown<String>(
        key: ValueKey<String>('tl-parent-${layer.internallayerId}'),
        value: names.containsKey(current) ? current! : _noParent,
        options: [_noParent, ...names.keys],
        label: (id) => id == _noParent ? 'None' : (names[id] ?? 'None'),
        onChanged: (id) {
          // A cycle is refused engine-side; the picker reports nothing and the
          // row keeps the parent it had.
          try {
            layer.setParent(
                parent: id == _noParent ? null : UuidValue.fromString(id));
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
  final duration = comp.getSettings().durationFrames.toInt();
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
