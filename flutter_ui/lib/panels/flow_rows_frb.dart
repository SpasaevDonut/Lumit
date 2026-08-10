// The Flow group: what a footage layer does when it has to invent a frame.
//
// K-088 made flow a layer *option* rather than an effect or a dropdown entry,
// and K-331 built the parameters behind it. This is that group — it sits beside
// Transform and Effects, and appears only while the layer's flow switch is on.
//
// Every control here changes the picture, which is why every one of them is
// part of the frame's cache identity on the engine side. Nothing in this file
// decides anything: it reads the group, writes the group, and lets the engine
// work out what that means (the thin-view rule).

import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:lumit_flutter/src/rust/api/effect.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';
import 'package:lumit_flutter/src/rust/api/retime.dart';

import '../state/comp_time.dart';
import '../theme/theme.dart';
import '../widgets/controls.dart';
import 'fx_section.dart';
import 'keyframe_controls_frb.dart';

/// The Flow section for [layer], or nothing when its flow switch is off.
class FlowRowsFrb extends StatelessWidget {
  final LayerReference layer;
  final VoidCallback onChanged;

  /// The comp and playhead, for the Input rate's keyframe controls — the one
  /// animatable thing in this group.
  final CompositionReference comp;
  final int playheadFrame;
  final ValueChanged<int> onSeek;

  /// Whether the section is twirled open, and how to toggle it — held by the
  /// panel so the open set survives a rebuild.
  final bool open;
  final VoidCallback onToggle;

  const FlowRowsFrb({
    super.key,
    required this.layer,
    required this.onChanged,
    required this.comp,
    required this.playheadFrame,
    required this.onSeek,
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
          (v) => write(flowParamsWith(p, resolution: v)),
        ),
        _inputRateRow(context, t),
        _choice(
          context,
          t,
          'Vector detail',
          'flow-detail',
          const ['Low', 'Medium', 'High', 'Ultra'],
          p.detail,
          (v) => write(flowParamsWith(p, detail: v)),
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
              onChanged: (v) =>
                  write(flowParamsWith(p, smoothness: v.toDouble())),
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
          (v) => write(flowParamsWith(p, occlusion: v)),
        ),
        _choice(
          context,
          t,
          'Fallback',
          'flow-fallback',
          const ['Blend', 'Nearest'],
          p.fallback,
          (v) => write(flowParamsWith(p, fallback: v)),
        ),
        _row(
          context,
          t,
          'HUD guard',
          HouseCheckbox(
            key: const ValueKey('flow-hud-guard'),
            value: p.hudGuard,
            onChanged: (v) => write(flowParamsWith(p, hudGuard: v)),
          ),
        ),
        _row(
          context,
          t,
          'Always on',
          HouseCheckbox(
            key: const ValueKey('flow-always'),
            value: p.always,
            onChanged: (v) => write(flowParamsWith(p, always: v)),
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

  /// **Input rate** — the fps the clip is *interpreted* at for flow (K-095,
  /// K-160). The only animatable control in the group, so the only one with a
  /// stopwatch and a ◄ ◆ ► navigator.
  ///
  /// `0` shows as **Auto**: adjacent source frames, the clip's own rate. Two
  /// opposite footage problems want something else. High-speed capture (a
  /// 600 fps phone clip) has neighbours so close together there is no motion to
  /// interpolate, and slow-motion looks frozen. **Animation drawn on 2s or 3s**
  /// is the mirror: the same drawing is held two or three times, so half the
  /// frame pairs flow between a frame and its own duplicate — no motion at all —
  /// and the rest carry double. That reads as judder, not slow motion. Telling
  /// flow the rate the animation was *drawn* at makes every pair span real
  /// motion.
  ///
  /// The presets do that arithmetic: an editor knows a cut is "on 2s", not that
  /// 24 ÷ 2 is 12. They write into the same field, so a preset and a typed rate
  /// are the same thing to the document — and it stays keyframeable, because a
  /// scene's cadence is not always constant.
  Widget _inputRateRow(BuildContext context, LumitTheme t) {
    final rate = layer.getFlowInputRate();
    // An animated rate shows what the curve reads at the playhead, sampled
    // engine-side — the same answer the render will use, rather than a second
    // implementation of the interpolation living in the view.
    final shown = switch (rate) {
      BridgeScalar_Static(:final field0) => field0,
      // An expression is sampled engine-side too, so it needs no case of its
      // own here — `sampleScalar` is the one place either is evaluated.
      BridgeScalar_Keyframed() ||
      BridgeScalar_Expression() =>
        sampleScalar(scalar: rate, time: timeOfFrame(comp, playheadFrame)),
    };

    void writeRate(double fps) {
      layer.setFlowInputRate(
        value: scalarWithValueAt(rate, fps, comp, playheadFrame),
      );
      onChanged();
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: fxTwoColumnRow(
        context: context,
        keyframeControls: KeyframeControlsFrb(
          scalars: [rate],
          onWrite: (next) {
            layer.setFlowInputRate(value: next.first);
            onChanged();
          },
          comp: comp,
          playheadFrame: playheadFrame,
          onSeek: onSeek,
          rowKey: 'flow-input-rate',
        ),
        name:
            Text('Input rate', style: t.body, overflow: TextOverflow.ellipsis),
        control: Row(
          children: [
            SizedBox(
              width: _cellWidth,
              child: DragValueField(
                key: const ValueKey('flow-input-rate'),
                value: shown,
                min: 0,
                max: 240,
                decimals: 2,
                // 0 is Auto rather than "zero frames per second", which is not
                // a thing — so the field says so instead of showing a number
                // that would read as a mistake.
                suffix: shown < 0.5 ? '' : ' fps',
                onChanged: (v) => writeRate(v.toDouble()),
              ),
            ),
            const SizedBox(width: 6),
            SizedBox(
              width: 92,
              child: BareDropdown<double>(
                key: const ValueKey('flow-input-rate-preset'),
                value: flowPresetLabel(shown) == null ? -1 : shown,
                options: [
                  if (flowPresetLabel(shown) == null) -1,
                  ...flowRatePresets.map((p) => p.$1),
                ],
                label: (v) => flowPresetLabel(v) ?? 'Custom',
                onChanged: (v) {
                  if (v >= 0) writeRate(v);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

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
          // the graph editor to aim at. Input rate is the exception, and builds
          // its own row above.
          name: Text(label, style: t.body, overflow: TextOverflow.ellipsis),
          control: control,
        ),
      );
}

/// Input-rate presets, keyed by the fps they write.
///
/// Named for the cadence rather than the number, because that is how the
/// footage is described: an animator says a cut is "on 2s", and 24 ÷ 2 = 12 is
/// arithmetic the editor should not have to do at the point of use. The rates
/// cover the common animation cadences at 24 fps and the film/broadcast rates
/// worth conforming high-speed capture to.
/// A list rather than a map, because Dart will not const a map keyed by
/// doubles — and the order here is the order the menu shows.
const List<(double, String)> flowRatePresets = [
  (0, 'Auto'),
  (12, 'On 2s (12)'),
  (8, 'On 3s (8)'),
  (6, 'On 4s (6)'),
  (24, '24 fps'),
  (25, '25 fps'),
  (30, '30 fps'),
];

/// The preset label for an exact rate, or null when the value is the user's own.
String? flowPresetLabel(double fps) {
  for (final (rate, label) in flowRatePresets) {
    if ((rate - fps).abs() < 0.001) return label;
  }
  return null;
}

/// Copy-with over the generated struct, which has no `copyWith` of its own.
/// Shared with the Timeline fold-out's rows, so one definition of "change one
/// field of the group" serves both surfaces.
BridgeFlowParams flowParamsWith(
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
