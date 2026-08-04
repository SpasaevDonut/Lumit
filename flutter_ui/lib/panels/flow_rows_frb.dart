// The Flow group: what a footage layer does when it has to invent a frame.
//
// K-088 made flow a layer *option* rather than an effect or a dropdown entry,
// and K-256 built the parameters behind it. This is that group — it sits beside
// Transform and Effects, and appears only while the layer's flow switch is on.
//
// Every control here changes the picture, which is why every one of them is
// part of the frame's cache identity on the engine side. Nothing in this file
// decides anything: it reads the group, writes the group, and lets the engine
// work out what that means (the thin-view rule).

import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';
import 'package:lumit_flutter/src/rust/api/retime.dart';

import '../theme/theme.dart';
import '../widgets/controls.dart';
import 'fx_section.dart';

/// The Flow section for [layer], or nothing when its flow switch is off.
class FlowRowsFrb extends StatelessWidget {
  final LayerReference layer;
  final VoidCallback onChanged;

  /// Whether the section is twirled open, and how to toggle it — held by the
  /// panel so the open set survives a rebuild.
  final bool open;
  final VoidCallback onToggle;

  const FlowRowsFrb({
    super.key,
    required this.layer,
    required this.onChanged,
    required this.open,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    if (layer.getKind() != BridgeLayerKind.footage) {
      return const SizedBox.shrink();
    }
    if (!layer.getFlowEnabled()) return const SizedBox.shrink();
    final t = ThemeScope.of(context).theme;
    final p = layer.getFlowParams();

    // One write path: read the group, change one field, write it whole. The
    // engine takes it as a single undo step, which is what the user means by
    // "I changed the smoothness" — not eight separate edits waiting to happen.
    void write(BridgeFlowParams next) {
      layer.setFlowParams(params: next);
      onChanged();
    }

    return FxSection(
      title: 'Flow',
      open: open,
      onToggle: onToggle,
      rows: [
        _choice(
          context,
          t,
          'Flow resolution',
          'flow-resolution',
          const ['Native', 'Half', 'Quarter'],
          p.resolution,
          (v) => write(_with(p, resolution: v)),
        ),
        _choice(
          context,
          t,
          'Vector detail',
          'flow-detail',
          const ['Low', 'Medium', 'High', 'Ultra'],
          p.detail,
          (v) => write(_with(p, detail: v)),
        ),
        _row(
          context,
          t,
          'Smoothness',
          SizedBox(
            width: _cellWidth,
            child: DragValueField(
              key: const ValueKey('flow-smoothness'),
              value: p.smoothness,
              min: 0,
              max: 100,
              onChanged: (v) => write(_with(p, smoothness: v.toDouble())),
            ),
          ),
        ),
        _choice(
          context,
          t,
          'Occlusion',
          'flow-occlusion',
          const ['Visible only', 'Blend'],
          p.occlusion,
          (v) => write(_with(p, occlusion: v)),
        ),
        _choice(
          context,
          t,
          'Fallback',
          'flow-fallback',
          const ['Blend', 'Nearest'],
          p.fallback,
          (v) => write(_with(p, fallback: v)),
        ),
        _row(
          context,
          t,
          'HUD guard',
          HouseCheckbox(
            key: const ValueKey('flow-hud-guard'),
            value: p.hudGuard,
            onChanged: (v) => write(_with(p, hudGuard: v)),
          ),
        ),
        _row(
          context,
          t,
          'Always on',
          HouseCheckbox(
            key: const ValueKey('flow-always'),
            value: p.always,
            onChanged: (v) => write(_with(p, always: v)),
          ),
        ),
      ],
    );
  }

  /// A labelled dropdown over a small set of codes. The label list is in code
  /// order, so its index *is* the stored value — the same order the engine's
  /// `OPTIONS` constants declare, which is what keeps a stored index and its
  /// name from drifting apart.
  Widget _choice(
    BuildContext context,
    LumitTheme t,
    String label,
    String keyName,
    List<String> options,
    int value,
    ValueChanged<int> onChanged,
  ) =>
      _row(
        context,
        t,
        label,
        SizedBox(
          width: _cellWidth + 40,
          child: BareDropdown<int>(
            key: ValueKey(keyName),
            value: value < options.length ? value : 0,
            options: List.generate(options.length, (i) => i),
            label: (i) => options[i],
            onChanged: onChanged,
          ),
        ),
      );

  Widget _row(
    BuildContext context,
    LumitTheme t,
    String label,
    Widget control,
  ) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: fxTwoColumnRow(
          context: context,
          // Not keyable properties, so plain text names — there is no curve for
          // the graph editor to aim at. (The input rate *is* keyable, and lands
          // here as a property row when it is wired.)
          name: Text(label, style: t.body, overflow: TextOverflow.ellipsis),
          control: control,
        ),
      );
}

/// Copy-with over the generated struct, which has no `copyWith` of its own.
BridgeFlowParams _with(
  BridgeFlowParams p, {
  int? resolution,
  int? detail,
  double? smoothness,
  int? occlusion,
  int? fallback,
  bool? hudGuard,
  bool? always,
}) =>
    BridgeFlowParams(
      resolution: resolution ?? p.resolution,
      detail: detail ?? p.detail,
      smoothness: smoothness ?? p.smoothness,
      occlusion: occlusion ?? p.occlusion,
      fallback: fallback ?? p.fallback,
      hudGuard: hudGuard ?? p.hudGuard,
      always: always ?? p.always,
    );

/// Matches the other property sections' cell width so values line up.
const double _cellWidth = 78;
