// One effect parameter as an editable row — shared by the Effect controls panel
// and the Timeline's fold-out, so a parameter behaves the same wherever it is
// shown.
//
// **What a row is.** The stopwatch and ◄ ◆ ► navigator for the kinds that can
// animate, the parameter's label, and whatever control its kind asks for: a
// scrub-draggable number, a colour swatch, a choice list, a seed, a layer
// picker, or a file name.
//
// **Why the writes go out through callbacks.** A `BridgeEffectInstance` is an
// opaque Rust handle, and the calls that take a whole stack — `setEffects`,
// `renderFrameWithPreview` — take it *by value*: frb moves it and disposes the
// Dart side. A row must therefore never write into the instance it was built
// from and hand that same instance on; it says what it wants written and the
// owner of the stack mints fresh handles for the one call that consumes them.
// Getting this wrong is what stopped effect parameters being draggable at all:
// the first preview tick killed the handles and the rest of the gesture threw.

import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';
import 'package:lumit_flutter/src/rust/api/effect.dart';
import 'package:uuid/uuid.dart';

import '../theme/theme.dart';
import '../widgets/colour_picker.dart';
import '../widgets/controls.dart';
import 'keyframe_controls_frb.dart';

/// How wide one value cell is.
const double effectCellWidth = 78;

/// One parameter: its label, and the control its kind asks for.
///
/// Takes the effect's *id* and this parameter's *value* rather than the opaque
/// instance handle: every read through a handle is a bridge crossing, and the
/// owner already fetched everything in one `getInfo` (K-183).
class EffectParamRowFrb extends StatelessWidget {
  final UuidValue effectId;
  final BridgeParamInfo param;

  /// This parameter's current value, from the owner's one `getInfo` read —
  /// staged value during a drag. Null when the instance does not carry the
  /// parameter (a schema newer than the saved document); the row then draws
  /// nothing rather than a misleading zero.
  final BridgeEffectValue? value;
  final CompositionReference comp;
  final int playheadFrame;
  final ValueChanged<int> onSeek;

  /// A typed value, or the release of a drag: commit it as one op.
  final void Function(UuidValue effect, String param, BridgeEffectValue value)
      onWrite;

  /// A drag tick: preview it without committing.
  final void Function(UuidValue effect, String param, BridgeEffectValue value)
      onLive;

  const EffectParamRowFrb({
    super.key,
    required this.effectId,
    required this.param,
    required this.value,
    required this.comp,
    required this.playheadFrame,
    required this.onSeek,
    required this.onWrite,
    required this.onLive,
  });

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final id = effectId;
    final scalar = _animatableScalarOf(value);
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
              rowKey: '$id-${param.id}',
              onWrite: (next) => _set(BridgeEffectValue.float(next.single)),
            ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(param.label,
                style: t.body, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 10),
          _control(context, t, id, value),
        ],
      ),
    );
  }

  /// The scalar behind this row when the kind is one that can animate, else
  /// null. Float is the only single-scalar animatable kind the schema declares;
  /// a colour animates per channel, which the swatch has no room to key.
  BridgeScalar? _animatableScalarOf(BridgeEffectValue? value) {
    if (param.kind is! BridgeParamKind_Float) return null;
    return switch (value) {
      BridgeEffectValue_Float(:final field0) => field0,
      _ => null,
    };
  }

  /// Write this parameter. The value goes up to the panel rather than being
  /// written into an instance here: the owner of the stack mints fresh handles
  /// for the one call that consumes them.
  void _set(BridgeEffectValue value) => onWrite(effectId, param.id, value);

  /// The same value, previewed rather than committed — one drag tick.
  void _setLive(BridgeEffectValue value) => onLive(effectId, param.id, value);

  Widget _control(
      BuildContext context, LumitTheme t, UuidValue id, BridgeEffectValue? value) {
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
            keyName: '$id-${param.id}',
            write: (s) => _set(BridgeEffectValue.float(s)),
          );
        }
        return Text('—', style: t.small);

      case BridgeParamKind_Colour(:final min, :final max):
        if (value case BridgeEffectValue_Colour(:final field0)) {
          return _colourSwatch(context, id, field0, min, max);
        }
        return Text('—', style: t.small);

      case BridgeParamKind_Bool():
        if (value case BridgeEffectValue_Bool(:final field0)) {
          return SizedBox(
            width: effectCellWidth,
            child: Align(
              alignment: Alignment.centerLeft,
              child: HouseCheckbox(
                key: ValueKey<String>('fx-bool-$id-${param.id}'),
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
            width: effectCellWidth + 40,
            child: BareDropdown<int>(
              key: ValueKey<String>('fx-choice-$id-${param.id}'),
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
            width: effectCellWidth,
            child: DragValueField(
              key: ValueKey<String>('fx-seed-$id-${param.id}'),
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
          return _layerPicker(context, id, field0);
        }
        return Text('—', style: t.small);

      case BridgeParamKind_File(:final filterName):
        if (value case BridgeEffectValue_File(:final field0)) {
          final paths = field0.paths;
          return SizedBox(
            width: effectCellWidth + 60,
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
        width: effectCellWidth,
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
      width: effectCellWidth,
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
        onChangeLive: (v) =>
            _setLive(BridgeEffectValue.float(BridgeScalar.static_(v.toDouble()))),
        onChangeEnd: (v) =>
            write(BridgeScalar.static_(v.toDouble())),
      ),
    );
  }

  /// A colour swatch. The four channels animate independently in the model, so a
  /// swatch edit writes all four statics at once; an animated channel is left
  /// alone for the same reason a scalar is.
  Widget _colourSwatch(BuildContext context, UuidValue id, BridgeColour colour,
      double min, double max) {
    double chan(BridgeScalar s) => s is BridgeScalar_Static ? s.field0 : 0;
    final animated = colour.r is! BridgeScalar_Static ||
        colour.g is! BridgeScalar_Static ||
        colour.b is! BridgeScalar_Static;
    final t = ThemeScope.of(context).theme;
    if (animated) {
      return SizedBox(
        width: effectCellWidth,
        child: Text('animated',
            style: t.small.copyWith(color: t.textMuted),
            textAlign: TextAlign.right),
      );
    }

    int byte(double f) => (f.clamp(0.0, 1.0) * 255).round();
    final shown = documentColour(
        byte(chan(colour.r)), byte(chan(colour.g)), byte(chan(colour.b)), 255);

    return SizedBox(
      width: effectCellWidth,
      child: Align(
        alignment: Alignment.centerLeft,
        child: GestureDetector(
          key: ValueKey<String>('fx-colour-$id-${param.id}'),
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
  Widget _layerPicker(BuildContext context, UuidValue id, UuidValue? current) {
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
      width: effectCellWidth + 40,
      child: BareDropdown<String>(
        key: ValueKey<String>('fx-layer-$id-${param.id}'),
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

/// The effect schema, fetched once per session and then answered from here.
///
/// `listEffects` serialises every built-in's declaration and `listParameters`
/// one effect's worth; both are static for the life of the process, yet they
/// were being re-fetched per card per rebuild — the whole schema crossing the
/// bridge to look up one display label. Memoised, a rebuild costs nothing here.
List<BridgeEffectInfo>? _effectSchema;
List<BridgeEffectInfo> cachedListEffects() => _effectSchema ??= listEffects();

final Map<String, List<BridgeParamInfo>> _paramSchema = {};
List<BridgeParamInfo> cachedListParameters(String effect) =>
    _paramSchema[effect] ??= listParameters(effect: effect);

/// An effect's display label from the schema, falling back to its match name
/// for an effect this build does not know.
String effectLabelOf(String name) {
  for (final info in cachedListEffects()) {
    if (info.name == name) return info.label;
  }
  return name;
}

/// The last path segment, for showing a chosen file without its whole path.
String _basename(String path) {
  final cut = path.lastIndexOf(RegExp(r'[/\\]'));
  return cut < 0 ? path : path.substring(cut + 1);
}


/// The staging behind a drag on an effect parameter, and the writes that end it.
///
/// Held by whichever panel is showing the rows — the Effect controls card and
/// the Timeline's fold-out each keep one. It exists because the *handles* cannot
/// be kept: what is staged is the edit (which effect, which parameter, which
/// value), and every call that consumes a stack gets a freshly read one with
/// that edit written into it.
class EffectStackEditor {
  ({UuidValue effect, String param, BridgeEffectValue value})? _staged;
  final Stopwatch _since = Stopwatch()..start();
  Duration _lastPreview = Duration.zero;

  /// Roughly one preview render per 20 ms, so a fast drag cannot outrun the
  /// renderer and queue up work it will only throw away.
  static const Duration previewInterval = Duration(milliseconds: 20);

  /// The value a row should *show*, which during a drag is the staged one.
  BridgeEffectValue? stagedValue(UuidValue effect, String param) {
    final staged = _staged;
    if (staged == null) return null;
    return staged.effect == effect && staged.param == param ? staged.value : null;
  }

  /// The layer's stack with the drag in progress written into it, freshly read.
  List<BridgeEffectInstance> stackWith(LayerReference layer) {
    final stack = layer.getEffects();
    final staged = _staged;
    if (staged != null) {
      for (final instance in stack) {
        if (instance.id() == staged.effect) {
          instance.setValue(id: staged.param, value: staged.value);
        }
      }
    }
    return stack;
  }

  /// A drag tick: stage the value and render it, throttled. Nothing is
  /// committed, so the document and the undo history never see a tick.
  void live(
    CompositionReference comp,
    LayerReference layer,
    UuidValue effect,
    String param,
    BridgeEffectValue value, {
    required int frame,
    required double scale,
  }) {
    _staged = (effect: effect, param: param, value: value);
    if (_since.elapsed - _lastPreview < previewInterval) return;
    _lastPreview = _since.elapsed;
    comp.renderFrameWithPreview(
      frame: BigInt.from(frame),
      scale: scale,
      layer: layer,
      effects: stackWith(layer),
    );
  }

  /// A release, or a typed value: the whole stack as one op.
  ///
  /// A stack another panel has changed under us is refused engine-side
  /// (`StaleEffectStack`); re-reading is the recovery, so the panel shows the
  /// document rather than insisting on its own copy.
  void write(
    LayerReference layer,
    UuidValue effect,
    String param,
    BridgeEffectValue value,
  ) {
    _staged = (effect: effect, param: param, value: value);
    try {
      layer.setEffects(effects: stackWith(layer));
    } catch (_) {
      // Someone else edited the stack mid-drag. Drop ours and re-read.
    }
    _staged = null;
  }

  /// Forget any drag in progress — a cancelled gesture.
  void clear() => _staged = null;
}
