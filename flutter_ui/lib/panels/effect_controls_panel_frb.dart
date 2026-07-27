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

import '../icons/icons.dart';
import '../theme/theme.dart';
import '../widgets/colour_picker.dart';
import '../widgets/controls.dart';
import 'keyframe_controls_frb.dart';
import 'transform_rows_frb.dart';
import '../state/drag_payloads.dart';
import 'placeholder.dart';
import 'source_rows_frb.dart';

/// How wide a value cell is, so the rows line up down the panel.
const double _cellWidth = 78;

/// Roughly one preview render per 20 ms, so a fast drag cannot outrun the
/// renderer and queue up work it will only throw away.
const Duration _previewInterval = Duration(milliseconds: 20);

class EffectControlsPanelFrb extends StatefulWidget {
  const EffectControlsPanelFrb({super.key});

  @override
  State<EffectControlsPanelFrb> createState() => _EffectControlsPanelFrbState();
}

class _EffectControlsPanelFrbState extends State<EffectControlsPanelFrb> {
  /// The stack being dragged, held only for the length of one drag. Null the
  /// rest of the time, so an ordinary build reads the document rather than a
  /// copy that might have gone stale under it.
  List<BridgeEffectInstance>? _staged;

  final Stopwatch _since = Stopwatch()..start();
  Duration _lastPreview = Duration.zero;

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
        builder: (context, playhead, _) => _rows(context, comp, layer, playhead),
      );

  Widget _rows(
    BuildContext context,
    CompositionReference comp,
    LayerReference layer,
    int playhead,
  ) {
    final t = ThemeScope.of(context).theme;
    final ui = Provider.of<LumitUiState>(context, listen: false);
    final effects = _staged ?? layer.getEffects();

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
                    onCommit: () => _commit(layer, effects),
                    onLive: () => _preview(comp, layer, effects),
                    onDragStart: () => _staged = effects,
                    onDragEnd: () {
                      _commit(layer, effects);
                      setState(() => _staged = null);
                    },
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

  /// Commit the staged stack as one op. A stack another panel has changed under
  /// us is refused engine-side (`StaleEffectStack`); re-reading is the recovery,
  /// so the panel shows the document rather than insisting on its own copy.
  void _commit(LayerReference layer, List<BridgeEffectInstance> effects) {
    try {
      layer.setEffects(effects: effects);
    } catch (_) {
      // Someone else edited the stack mid-drag. Drop ours and re-read.
    }
    if (mounted) setState(() => _staged = null);
  }

  /// Render the staged stack without committing it, throttled.
  void _preview(
    CompositionReference comp,
    LayerReference layer,
    List<BridgeEffectInstance> effects,
  ) {
    if (_since.elapsed - _lastPreview < _previewInterval) return;
    _lastPreview = _since.elapsed;
    final ui = Provider.of<LumitUiState>(context, listen: false);
    comp.renderFrameWithPreview(
      frame: BigInt.from(ui.playheadFrame.value),
      scale: ui.viewerScale,
      layer: layer,
      effects: effects,
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

  /// A one-shot parameter edit: commit it now.
  final VoidCallback onCommit;

  /// A drag tick: render the staged stack, do not commit.
  final VoidCallback onLive;
  final VoidCallback onDragStart;
  final VoidCallback onDragEnd;

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
    required this.onCommit,
    required this.onLive,
    required this.onDragStart,
    required this.onDragEnd,
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
                    _ParamRow(
                      key: ValueKey<String>('fx-row-${effect.id()}-${param.id}'),
                      effect: effect,
                      param: param,
                      comp: comp,
                      playheadFrame: playheadFrame,
                      onSeek: onSeek,
                      onCommit: onCommit,
                      onLive: onLive,
                      onDragStart: onDragStart,
                      onDragEnd: onDragEnd,
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

/// One parameter: its label, and the control its kind asks for.
class _ParamRow extends StatelessWidget {
  final BridgeEffectInstance effect;
  final BridgeParamInfo param;
  final CompositionReference comp;
  final int playheadFrame;
  final ValueChanged<int> onSeek;
  final VoidCallback onCommit;
  final VoidCallback onLive;
  final VoidCallback onDragStart;
  final VoidCallback onDragEnd;

  const _ParamRow({
    super.key,
    required this.effect,
    required this.param,
    required this.comp,
    required this.playheadFrame,
    required this.onSeek,
    required this.onCommit,
    required this.onLive,
    required this.onDragStart,
    required this.onDragEnd,
  });

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final scalar = _animatableScalar;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          // Only the number-shaped kinds animate; a choice or a file has nothing
          // to interpolate, so those rows carry no stopwatch at all.
          if (scalar != null)
            KeyframeControlsFrb(
              // An effect parameter is one value, so one channel.
              scalars: [scalar],
              comp: comp,
              playheadFrame: playheadFrame,
              onSeek: onSeek,
              rowKey: '${effect.id()}-${param.id}',
              onWrite: (next) => _set(BridgeEffectValue.float(next.single)),
            ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(param.label,
                style: t.body, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 10),
          _control(context, t),
        ],
      ),
    );
  }

  /// The scalar behind this row when the kind is one that can animate, else
  /// null. Float is the only single-scalar animatable kind the schema declares;
  /// a colour animates per channel, which the swatch has no room to key.
  BridgeScalar? get _animatableScalar {
    if (param.kind is! BridgeParamKind_Float) return null;
    return switch (_value) {
      BridgeEffectValue_Float(:final field0) => field0,
      _ => null,
    };
  }

  /// The parameter's current value, or null when the instance does not carry it
  /// (a schema newer than the saved document). A missing value draws nothing
  /// rather than a misleading zero.
  BridgeEffectValue? get _value {
    try {
      return effect.getValue(id: param.id);
    } catch (_) {
      return null;
    }
  }

  /// Write `value` onto the staged copy and commit. Refused kinds are the
  /// engine's business — a control can never change what a parameter *is* — so a
  /// rejection here is a bug in this file, not something to surface.
  void _set(BridgeEffectValue value) {
    effect.setValue(id: param.id, value: value);
    onCommit();
  }

  Widget _control(BuildContext context, LumitTheme t) {
    final value = _value;
    if (value == null) return Text('—', style: t.small);

    switch (param.kind) {
      case BridgeParamKind_Float(
          :final sliderMin,
          :final sliderMax,
          :final hardMin,
          :final hardMax
        ):
        if (value case BridgeEffectValue_Float(:final field0)) {
          return _scalarField(
            context,
            scalar: field0,
            sliderMin: sliderMin,
            sliderMax: sliderMax,
            hardMin: hardMin,
            hardMax: hardMax,
            keyName: '${effect.id()}-${param.id}',
            write: (s) => _set(BridgeEffectValue.float(s)),
          );
        }
        return Text('—', style: t.small);

      case BridgeParamKind_Colour(:final min, :final max):
        if (value case BridgeEffectValue_Colour(:final field0)) {
          return _colourSwatch(context, field0, min, max);
        }
        return Text('—', style: t.small);

      case BridgeParamKind_Bool():
        if (value case BridgeEffectValue_Bool(:final field0)) {
          return SizedBox(
            width: _cellWidth,
            child: Align(
              alignment: Alignment.centerLeft,
              child: HouseCheckbox(
                key: ValueKey<String>('fx-bool-${effect.id()}-${param.id}'),
                value: field0,
                onChanged: (on) => _set(BridgeEffectValue.bool(on)),
              ),
            ),
          );
        }
        return Text('—', style: t.small);

      case BridgeParamKind_Choice(:final options):
        if (value case BridgeEffectValue_Choice(:final field0)) {
          final index = field0 < options.length ? field0.toInt() : 0;
          return SizedBox(
            width: _cellWidth + 40,
            child: BareDropdown<int>(
              key: ValueKey<String>('fx-choice-${effect.id()}-${param.id}'),
              value: index,
              options: [for (var i = 0; i < options.length; i++) i],
              label: (i) => options[i],
              onChanged: (i) => _set(BridgeEffectValue.choice(i)),
            ),
          );
        }
        return Text('—', style: t.small);

      case BridgeParamKind_Seed():
        if (value case BridgeEffectValue_Seed(:final field0)) {
          return SizedBox(
            width: _cellWidth,
            child: DragValueField(
              key: ValueKey<String>('fx-seed-${effect.id()}-${param.id}'),
              value: field0,
              min: 0,
              max: 0xFFFFFFFF,
              speed: 1,
              onChanged: (v) =>
                  _set(BridgeEffectValue.seed(v.toInt().clamp(0, 0xFFFFFFFF))),
            ),
          );
        }
        return Text('—', style: t.small);

      case BridgeParamKind_Layer():
        if (value case BridgeEffectValue_Layer(:final field0)) {
          return _layerPicker(context, field0);
        }
        return Text('—', style: t.small);

      case BridgeParamKind_File(:final filterName):
        if (value case BridgeEffectValue_File(:final field0)) {
          final paths = field0.paths;
          return SizedBox(
            width: _cellWidth + 60,
            child: LumitTooltip(
              message: paths.isEmpty ? 'No $filterName chosen' : paths.first,
              child: Text(
                paths.isEmpty ? 'None' : _basename(paths.first),
                style: t.small,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          );
        }
        return Text('—', style: t.small);
    }
  }

  /// A number field for a scalar — or, when the scalar is a curve, a plain
  /// "animated" label.
  ///
  /// An animated parameter is deliberately not editable here: `set_value` takes
  /// a whole animation, so writing a static number over a curve would delete
  /// every key on it in one undoable step that looks, on screen, like nudging a
  /// value. The keyframe ops land with the graph editor (docs/TODO.md); until
  /// then the honest thing is to show that it is animated and refuse to touch it.
  Widget _scalarField(
    BuildContext context, {
    required BridgeScalar scalar,
    required double sliderMin,
    required double sliderMax,
    required double? hardMin,
    required double? hardMax,
    required String keyName,
    required void Function(BridgeScalar) write,
  }) {
    final t = ThemeScope.of(context).theme;
    if (scalar is! BridgeScalar_Static) {
      return SizedBox(
        width: _cellWidth,
        child: LumitTooltip(
          message: 'Animated — edit its keys in the graph editor',
          child: Text('animated',
              style: t.small.copyWith(color: t.textMuted),
              textAlign: TextAlign.right),
        ),
      );
    }

    // The drag paces itself by the declared slider span, so a 0–1 parameter and
    // a 0–500 one both feel the same under the pointer.
    final span = (sliderMax - sliderMin).abs();
    final speed = span <= 0 ? 0.5 : span / 200;
    return SizedBox(
      width: _cellWidth,
      child: DragValueField(
        key: ValueKey<String>('fx-float-$keyName'),
        value: scalar.field0,
        // Typing may leave the slider's travel; only the hard bounds clamp
        // (docs/08 §1.2).
        min: hardMin ?? -1000000,
        max: hardMax ?? 1000000,
        speed: speed,
        decimals: 2,
        onChanged: (v) => write(BridgeScalar.static_(v.toDouble())),
        onChangeStart: onDragStart,
        onChangeLive: (v) {
          effect.setValue(
            id: param.id,
            value: BridgeEffectValue.float(BridgeScalar.static_(v.toDouble())),
          );
          onLive();
        },
        onChangeEnd: (v) {
          effect.setValue(
            id: param.id,
            value: BridgeEffectValue.float(BridgeScalar.static_(v.toDouble())),
          );
          onDragEnd();
        },
        onDragCancel: onDragEnd,
      ),
    );
  }

  /// A colour swatch. The four channels animate independently in the model, so a
  /// swatch edit writes all four statics at once; an animated channel is left
  /// alone for the same reason a scalar is.
  Widget _colourSwatch(
      BuildContext context, BridgeColour colour, double min, double max) {
    double chan(BridgeScalar s) => s is BridgeScalar_Static ? s.field0 : 0;
    final animated = colour.r is! BridgeScalar_Static ||
        colour.g is! BridgeScalar_Static ||
        colour.b is! BridgeScalar_Static;
    final t = ThemeScope.of(context).theme;
    if (animated) {
      return SizedBox(
        width: _cellWidth,
        child: Text('animated',
            style: t.small.copyWith(color: t.textMuted),
            textAlign: TextAlign.right),
      );
    }

    int byte(double f) => (f.clamp(0.0, 1.0) * 255).round();
    final shown = documentColour(
        byte(chan(colour.r)), byte(chan(colour.g)), byte(chan(colour.b)), 255);

    return SizedBox(
      width: _cellWidth,
      child: Align(
        alignment: Alignment.centerLeft,
        child: GestureDetector(
          key: ValueKey<String>('fx-colour-${effect.id()}-${param.id}'),
          behavior: HitTestBehavior.opaque,
          onTap: () async {
            final box = context.findRenderObject();
            if (box is! RenderBox) return;
            final picked = await showColourPicker(
              context: context,
              position: box.localToGlobal(Offset(0, box.size.height + 4)),
              initial: shown,
            );
            if (picked == null) return;
            double clamp(double v) => v < min ? min : (v > max ? max : v);
            _set(BridgeEffectValue.colour(BridgeColour(
              r: BridgeScalar.static_(clamp(picked.r)),
              g: BridgeScalar.static_(clamp(picked.g)),
              b: BridgeScalar.static_(clamp(picked.b)),
              a: colour.a,
            )));
          },
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Container(
              width: 28,
              height: 18,
              decoration: BoxDecoration(
                color: shown,
                borderRadius: BorderRadius.circular(t.tokens.controlRadius),
                border: Border.all(color: t.hairlineStrong),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// A picker over the comp's own layers, with None. An unset or dangling
  /// reference is a labelled no-op engine-side, never a fault, so None is a
  /// first-class choice rather than an error state.
  Widget _layerPicker(BuildContext context, UuidValue? current) {
    final layers = comp.getLayers();
    final names = {
      for (final l in layers) l.internallayerId.toString(): l.getName(),
    };
    // The empty string stands for "unset", not `null`: `showLumitPopup`
    // completes with null when its barrier is tapped, so a nullable option is
    // indistinguishable from dismissing the menu and can never be chosen.
    const unset = '';
    final chosen = current?.toString();
    return SizedBox(
      width: _cellWidth + 40,
      child: BareDropdown<String>(
        key: ValueKey<String>('fx-layer-${effect.id()}-${param.id}'),
        value: names.containsKey(chosen) ? chosen! : unset,
        options: [unset, ...names.keys],
        label: (id) => id == unset ? 'None' : (names[id] ?? 'Missing layer'),
        onChanged: (id) => _set(BridgeEffectValue.layer(
          id == unset ? null : UuidValue.fromString(id),
        )),
      ),
    );
  }
}

/// The last path segment, for showing a chosen file without its whole path.
String _basename(String path) {
  final cut = path.lastIndexOf(RegExp(r'[/\\]'));
  return cut < 0 ? path : path.substring(cut + 1);
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
