// The Effect controls panel, on the flutter_rust_bridge API — the effect stack.
//
// One card per effect on the selected layer: an enable switch, reorder and
// remove, and a row per declared parameter drawn as the control its *kind* asks
// for. Add effect offers every built-in, grouped by category.
//
// Above the stack sit the Transform rows — anchor, position, scale, rotation,
// opacity, plus the z and x/y-rotation rows when the layer is 3D.
//
// Every animatable row carries the stopwatch and the ◄ ◆ ► navigator
// (keyframe_controls_frb.dart). An animated row shows "animated" in place of its
// number field: the value there is a curve, and the graph editor is where a
// curve is shaped. The stopwatch turns animation off again, keeping the value
// the curve reads at the playhead — so the row is never a dead end.
//
// **How an edit reaches the document.** `getEffects` hands back a *staged* copy
// of the stack, `setValue` edits that copy, and `LayerReference.setEffects`
// commits the whole list as one `SetLayerEffects` op. So a drag mutates the copy
// and renders it through `renderFrameWithPreview` — which patches a clone of the
// document engine-side — and only the release commits. A drag therefore costs
// one undo entry rather than one per tick, which is the whole reason the staged
// shape exists.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:lumit_flutter/src/rust/api/effect.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../builder/layer_builder.dart';
import '../icons/icons.dart';
import '../theme/theme.dart';
import '../widgets/controls.dart';
import 'effect_param_row_frb.dart';
import 'transform_rows_frb.dart';
import '../state/drag_payloads.dart';
import 'placeholder.dart';
import 'source_rows_frb.dart';


class EffectControlsPanelFrb extends StatefulWidget {
  const EffectControlsPanelFrb({super.key});

  @override
  State<EffectControlsPanelFrb> createState() => _EffectControlsPanelFrbState();
}

class _EffectControlsPanelFrbState extends State<EffectControlsPanelFrb> {
  /// The drag in progress, and the writes that end it. Shared with the
  /// Timeline's fold-out, which shows the same rows.
  final EffectStackEditor _effects = EffectStackEditor();

  @override
  Widget build(BuildContext context) {
    final ui = Provider.of<LumitUiState>(context);
    final comp = ui.selectedComp;
    if (comp == null) {
      return const PlaceholderPanel(
        icon: LumitIcon.fx,
        title: 'Effect controls',
        hint: 'Select a composition, then a layer.',
      );
    }

    return ValueListenableBuilder<LayerReference?>(
      valueListenable: ui.selectedLayer,
      builder: (context, layer, _) {
        if (layer == null) {
          return const PlaceholderPanel(
            icon: LumitIcon.fx,
            title: 'Effect controls',
            hint: 'Select a layer in the Timeline.',
          );
        }
        return _body(context, comp, layer);
      },
    );
  }

  Widget _body(
    BuildContext context,
    CompositionReference comp,
    LayerReference layer,
  ) =>
      // The keyframe controls read the playhead — which key is under it, whether
      // the diamond is filled — so the rows have to redraw when it moves.
      ValueListenableBuilder<int>(
        valueListenable:
            Provider.of<LumitUiState>(context, listen: false).playheadFrame,
        // Wrapped so any op on this layer re-reads it — an undo or redo, or the
        // same property dragged in the Timeline's fold-out. The effect stack in
        // particular has to be read *again*, not just redrawn: the instances the
        // rows hold are a staged copy taken when the panel last built, so
        // without this an undone value stayed on screen until something else
        // rebuilt the panel.
        builder: (context, playhead, _) => LayerBuilder(
          layer: layer,
          builder: (context) => _rows(context, comp, layer, playhead),
        ),
      );

  Widget _rows(
    BuildContext context,
    CompositionReference comp,
    LayerReference layer,
    int playhead,
  ) {
    final t = ThemeScope.of(context).theme;
    final ui = Provider.of<LumitUiState>(context, listen: false);
    final effects = _effects.stackWith(layer);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          layerName: layer.getName(),
          onAdd: (name) {
            layer.addEffect(name: name);
            setState(() {});
          },
        ),
        Expanded(
          // The drop target for an effect dragged from Effects & presets.
          // Nothing else produces an `EffectDragData`, and this is the only
          // thing that accepts one — the same contract `FootageDragData` has
          // with the Timeline.
          child: DragTarget<EffectDragData>(
            onAcceptWithDetails: (details) {
              layer.addEffect(name: details.data.name);
              setState(() {});
            },
            builder: (context, candidate, _) => Container(
              // While something is over it, say so: a drop with no feedback is
              // indistinguishable from a drop that did nothing.
              decoration: candidate.isEmpty
                  ? null
                  : BoxDecoration(
                      border: Border.all(color: t.accent),
                      color: t.accent.withValues(alpha: 0.06),
                    ),
              child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 4),
            children: [
              // What the layer is made of comes before where it sits: a text
              // layer's words are the first thing you want when you select one.
              SourceRowsFrb(
                key: ValueKey<String>('src-card-${layer.internallayerId}'),
                layer: layer,
                onChanged: () => setState(() {}),
              ),
              _TransformCard(
                key: ValueKey<String>('tf-card-${layer.internallayerId}'),
                layer: layer,
                comp: comp,
                playheadFrame: playhead,
                onSeek: (frame) => ui.playheadFrame.value = frame,
                onChanged: () => setState(() {}),
              ),
              if (effects.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  child: Text(
                    'No effects on this layer yet',
                    style: t.small,
                    textAlign: TextAlign.center,
                  ),
                )
              else
                for (var index = 0; index < effects.length; index++)
                  _EffectCard(
                    key: ValueKey<String>('fx-card-${effects[index].id()}'),
                    effect: effects[index],
                    index: index,
                    count: effects.length,
                    onStackChanged: () => setState(() {}),
                    onWrite: (id, param, value) {
                      _effects.write(layer, id, param, value);
                      setState(() {});
                    },
                    onLive: (id, param, value) => setState(() {
                      _effects.live(comp, layer, id, param, value,
                          frame: ui.playheadFrame.value, scale: ui.viewerScale);
                    }),
                    layer: layer,
                    comp: comp,
                    playheadFrame: playhead,
                    onSeek: (frame) => ui.playheadFrame.value = frame,
                  ),
            ],
              ),
            ),
          ),
        ),
      ],
    );
  }

}

/// The panel header: which layer is being edited, and Add effect.
class _Header extends StatelessWidget {
  final String layerName;
  final ValueChanged<String> onAdd;
  const _Header({required this.layerName, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      color: t.surface1,
      child: Row(
        children: [
          lumitIcon(LumitIcon.fx, size: 13, color: t.textMuted),
          const SizedBox(width: 6),
          Expanded(
            child: Text(layerName,
                style: t.bodyPrimary, overflow: TextOverflow.ellipsis),
          ),
          HouseButton(
            key: const ValueKey('fx-add'),
            small: true,
            onPressed: () => _showAddMenu(context, onAdd),
            child: Text('Add effect', style: t.small),
          ),
        ],
      ),
    );
  }
}

/// The Add-effect menu: every built-in, under its category heading (K-090).
Future<void> _showAddMenu(BuildContext context, ValueChanged<String> onAdd) async {
  final box = context.findRenderObject();
  if (box is! RenderBox) return;
  final t = ThemeScope.of(context).theme;
  final origin = box.localToGlobal(Offset(0, box.size.height + 2));

  // Grouped in schema order, so the headings come out in the order the engine
  // declares rather than alphabetically by accident.
  final grouped = <String, List<BridgeEffectInfo>>{};
  final headings = <String, String>{};
  for (final e in listEffects()) {
    grouped.putIfAbsent(e.category, () => []).add(e);
    headings[e.category] = e.categoryLabel;
  }

  final picked = await showLumitPopup<String>(
    context: context,
    position: origin,
    builder: (close) => FloatSurface(
      width: 240,
      child: SizedBox(
        height: 380,
        child: ListView(
          children: [
            for (final entry in grouped.entries) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
                child: Text(headings[entry.key] ?? entry.key,
                    style: t.small.copyWith(color: t.textMuted)),
              ),
              for (final effect in entry.value)
                MenuRow(
                  onPressed: () => close(effect.name),
                  child: Text(effect.label),
                ),
            ],
          ],
        ),
      ),
    ),
  );
  if (picked != null) onAdd(picked);
}

/// One effect: its title row and a row per declared parameter.
class _EffectCard extends StatelessWidget {
  final BridgeEffectInstance effect;
  final int index;
  final int count;
  final LayerReference layer;
  final CompositionReference comp;
  final int playheadFrame;
  final ValueChanged<int> onSeek;

  /// The stack itself changed (enabled, reordered, removed) — re-read it.
  final VoidCallback onStackChanged;

  /// Write a parameter — a typed value, or the release of a drag. One op.
  final void Function(UuidValue effect, String param, BridgeEffectValue value)
      onWrite;

  /// A drag tick: preview it, do not commit it.
  final void Function(UuidValue effect, String param, BridgeEffectValue value)
      onLive;

  const _EffectCard({
    super.key,
    required this.effect,
    required this.index,
    required this.count,
    required this.layer,
    required this.comp,
    required this.playheadFrame,
    required this.onSeek,
    required this.onStackChanged,
    required this.onWrite,
    required this.onLive,
  });

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final params = listParameters(effect: effect.name());

    return Container(
      margin: const EdgeInsets.fromLTRB(6, 3, 6, 3),
      decoration: BoxDecoration(
        color: t.surface1,
        borderRadius: BorderRadius.circular(t.tokens.controlRadius),
        border: Border.all(color: t.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _titleRow(context, t),
          if (params.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
              child: Column(
                children: [
                  for (final param in params)
                    EffectParamRowFrb(
                      key: ValueKey<String>('fx-row-${effect.id()}-${param.id}'),
                      effect: effect,
                      param: param,
                      comp: comp,
                      playheadFrame: playheadFrame,
                      onSeek: onSeek,
                      onWrite: onWrite,
                      onLive: onLive,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _titleRow(BuildContext context, LumitTheme t) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 5, 6, 5),
        child: Row(
          children: [
            LumitTooltip(
              message: effect.enabled() ? 'Disable this effect' : 'Enable it',
              child: HouseCheckbox(
                key: ValueKey<String>('fx-enabled-${effect.id()}'),
                value: effect.enabled(),
                onChanged: (on) {
                  layer.setEffectEnabled(effect: effect, enabled: on);
                  onStackChanged();
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(_titleOf(effect), style: t.bodyPrimary)),
            _markButton(
              context,
              mark: '▲',
              tip: 'Move up the stack',
              enabled: index > 0,
              key: 'fx-up-${effect.id()}',
              onPressed: () {
                layer.reorderEffect(effect: effect, newIndex: index - 1);
                onStackChanged();
              },
            ),
            _markButton(
              context,
              mark: '▼',
              tip: 'Move down the stack',
              enabled: index < count - 1,
              key: 'fx-down-${effect.id()}',
              onPressed: () {
                layer.reorderEffect(effect: effect, newIndex: index + 1);
                onStackChanged();
              },
            ),
            _markButton(
              context,
              mark: '×',
              tip: 'Remove this effect',
              enabled: true,
              key: 'fx-remove-${effect.id()}',
              onPressed: () {
                layer.removeEffect(effect: effect);
                onStackChanged();
              },
            ),
          ],
        ),
      );

  /// A small text mark rather than an icon, matching v0's × for Remove — the
  /// icon set has no caret or close glyph, and three marks do not earn three
  /// new ones.
  Widget _markButton(
    BuildContext context, {
    required String mark,
    required String tip,
    required bool enabled,
    required String key,
    required VoidCallback onPressed,
  }) {
    final t = ThemeScope.of(context).theme;
    return LumitTooltip(
      message: tip,
      child: HouseButton(
        key: ValueKey<String>(key),
        frameless: true,
        small: true,
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        onPressed: enabled ? onPressed : null,
        child: Text(
          mark,
          style: t.small
              .copyWith(color: enabled ? t.textMuted : t.textDisabled),
        ),
      ),
    );
  }
}

/// The card heading. The instance carries its match name, which is a snake_case
/// key rather than something to show, so this is the label from the schema —
/// falling back to the raw name for an effect this build does not know.
String _titleOf(BridgeEffectInstance effect) {
  final name = effect.name();
  for (final info in listEffects()) {
    if (info.name == name) return info.label;
  }
  return name;
}

/// The Transform card: the layer's transform rows, in the panel's card chrome.
///
/// The rows themselves are [TransformRowsFrb], shared with the Timeline's
/// twirl-down — this is the card around them, which is all that is particular to
/// this panel.
class _TransformCard extends StatelessWidget {
  final LayerReference layer;
  final CompositionReference comp;
  final int playheadFrame;
  final ValueChanged<int> onSeek;
  final VoidCallback onChanged;

  const _TransformCard({
    super.key,
    required this.layer,
    required this.comp,
    required this.playheadFrame,
    required this.onSeek,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return Container(
      margin: const EdgeInsets.fromLTRB(6, 3, 6, 3),
      decoration: BoxDecoration(
        color: t.surface1,
        borderRadius: BorderRadius.circular(t.tokens.controlRadius),
        border: Border.all(color: t.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 5, 8, 3),
            child: Text('Transform', style: t.bodyPrimary),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
            child: TransformRowsFrb(
              comp: comp,
              layer: layer,
              playheadFrame: playheadFrame,
              onSeek: onSeek,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}
