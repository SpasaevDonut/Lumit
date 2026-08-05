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

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/data/expressions_metadata.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';
import 'package:lumit_flutter/src/rust/api/effect.dart';
import 'package:lumit_flutter/src/rust/api/state.dart';
import 'package:lumit_flutter/widgets/autofill.dart';
import 'package:provider/provider.dart';
import 'package:syntax_highlight/syntax_highlight.dart';
import 'package:uuid/uuid.dart';

import '../state/comp_time.dart';
import '../state/preview_throttle.dart';
import '../state/timeline_columns.dart';
import '../theme/theme.dart';
import '../widgets/colour_picker.dart';
import '../widgets/controls.dart';
import 'fx_section.dart';
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

  /// When set (the Timeline's fold-out), the control sits inside this fixed
  /// span so it lines up under the render-switch column group (docs/07 §4.3).
  final ValueColumn? valueColumn;

  /// Padding inside the row. The Timeline's fold-out passes zero: its rows are
  /// exactly one lane tall, and padding on top of that clipped the fields
  /// (the Effect controls card has the room, so it keeps its breathing space).
  final EdgeInsets rowPadding;

  /// Lay the row out as the Effect controls panel's two columns — name left,
  /// control left-aligned in the rest — rather than pushing the control to the
  /// row's right edge. Ignored when [valueColumn] is set: the Timeline's rows
  /// answer to the render-switch column group instead.
  final bool twoColumn;

  /// The layer this effect sits on, and every layer in the comp — what a
  /// layer-valued parameter picks from, minus the owner itself (K-194). Both
  /// ride in from the read model, so the closed picker costs nothing.
  final UuidValue ownerLayerId;
  final List<BridgeLayerEntry> ownerLayers;

  /// Clicking the parameter's *name* selects it for the graph editor
  /// (docs/07 §4.3) — the name, not the whole row.
  final VoidCallback? onLabelTap;

  /// The parameter's graph line colour while it is selected.
  final Color? graphColour;

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
    required this.ownerLayerId,
    required this.ownerLayers,
    this.valueColumn,
    this.rowPadding = const EdgeInsets.symmetric(vertical: 3),
    this.onLabelTap,
    this.graphColour,
    this.twoColumn = false,
  });

  @override
  Widget build(BuildContext context) {
    // The live playhead: an animated field shows (and edits) the value under
    // it, so it must follow a scrub.
    final playhead =
        Provider.of<LumitUiState>(context, listen: false).playheadFrame;
    return ValueListenableBuilder<int>(
      valueListenable: playhead,
      builder: (context, frame, _) => _build(context, frame),
    );
  }

  Widget _build(BuildContext context, int frame) {
    final t = ThemeScope.of(context).theme;
    final id = effectId;
    final scalar = _animatableScalarOf(value);
    // Only the number-shaped kinds animate; a choice or a file has nothing to
    // interpolate, so those rows carry no stopwatch at all.
    final keyframes = scalar == null
        ? null
        : KeyframeControlsFrb(
            // An effect parameter is one value, so one channel.
            scalars: [scalar],
            comp: comp,
            playheadFrame: playheadFrame,
            onSeek: onSeek,
            rowKey: '$id-${param.id}',
            onWrite: (next) => _set(BridgeEffectValue.float(next.single)),
          );

    // The name is the row's handle for the graph editor, so it is built once
    // and drawn by whichever layout the row takes.
    final label = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onLabelTap,
      child: Text(
        param.label,
        style:
            graphColour == null ? t.body : t.body.copyWith(color: graphColour),
        overflow: TextOverflow.ellipsis,
      ),
    );

    if (twoColumn && valueColumn == null) {
      return Padding(
        padding: rowPadding,
        child: fxTwoColumnRow(
          context: context,
          name: label,
          keyframeControls: keyframes,
          control: _control(context, t, id, value, frame),
        ),
      );
    }

    return Padding(
      padding: rowPadding,
      child: Row(
        children: [
          if (keyframes != null) keyframes,
          const SizedBox(width: 4),
          Expanded(child: label),
          if (valueColumn case final col?) ...[
            SizedBox(
              width: col.width,
              child: Align(
                alignment: Alignment.centerLeft,
                child: _control(context, t, id, value, frame),
              ),
            ),
            SizedBox(width: col.rightInset),
          ] else ...[
            const SizedBox(width: 10),
            _control(context, t, id, value, frame),
          ],
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

  Widget _control(BuildContext context, LumitTheme t, UuidValue id,
      BridgeEffectValue? value, int frame) {
    if (value == null) return Text('—', style: t.small);

    switch (param.kind) {
      case BridgeParamKind_Float(
          :final sliderMin,
          :final sliderMax,
          :final hardMin,
          :final hardMax
        ):
        if (value case BridgeEffectValue_Float(:final field0)) {
          if (field0 case BridgeScalar_Expression expr) {
            print("Rebuilding expression widget: ${expr.field0}");
            return EffectParamRowExpression(
              key: ValueKey<String>(
                  'fx-expression-$id-${param.id}-${param.hashCode}'),
              value: expr,
              comp: comp,
              frame: frame,
              layer: currentLayer,
              set: _set,
              setLive: _setLive,
            );
          }

          return _scalarField(
            context,
            scalar: field0,
            setExpression: () {
              var sampled = sampleScalarWithContext(
                  scalar: field0,
                  time: timeOfFrame(comp, frame),
                  layer: currentLayer);

              _set(BridgeEffectValue.float(
                  BridgeScalar.expression(sampled.toString())));
            },
            frame: frame,
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

  LayerReference get currentLayer => ownerLayers
      .firstWhere((i) => i.layer.internallayerId == ownerLayerId)
      .layer;

  /// A number field for a scalar. A static value drags with live preview; an
  /// animated one shows the value under the playhead and a change writes it
  /// into the key sitting there — or plants one — never flattening the curve
  /// (docs/07 §4.3).
  Widget _scalarField(
    BuildContext context, {
    required BridgeScalar scalar,
    required int frame,
    required double sliderMin,
    required double sliderMax,
    required double? hardMin,
    required double? hardMax,
    required String keyName,
    required void Function(BridgeScalar) write,
    required void Function() setExpression,
  }) {
    // The drag paces itself by the declared slider span, so a 0–1 parameter and
    // a 0–500 one both feel the same under the pointer.
    final span = (sliderMax - sliderMin).abs();
    final speed = span <= 0 ? 0.5 : span / 200;

    if (scalar case BridgeScalar_Keyframed()) {
      final sampled = sampleScalarWithContext(
          scalar: scalar, time: timeOfFrame(comp, frame), layer: currentLayer);
      // No live preview mid-drag on a curve; the release is one op — the key
      // at the playhead updated or planted.
      return SizedBox(
        width: effectCellWidth,
        child: KeyedValueField(
          fieldKey: ValueKey<String>('fx-float-$keyName'),
          value: sampled,
          min: hardMin ?? -1000000,
          max: hardMax ?? 1000000,
          speed: speed,
          onCommit: (v) => write(scalarWithValueAt(scalar, v, comp, frame)),
        ),
      );
    }

    return SizedBox(
      width: effectCellWidth,
      child: DragValueField(
        key: ValueKey<String>('fx-float-$keyName'),
        value: (scalar as BridgeScalar_Static).field0,
        // Typing may leave the slider's travel; only the hard bounds clamp
        // (docs/08 §1.2).
        min: hardMin ?? -1000000,
        max: hardMax ?? 1000000,
        setExpression: setExpression,
        speed: speed,
        decimals: 2,
        onChanged: (v) => write(BridgeScalar.static_(v.toDouble())),
        onChangeLive: (v) => _setLive(
            BridgeEffectValue.float(BridgeScalar.static_(v.toDouble()))),
        onChangeEnd: (v) => write(BridgeScalar.static_(v.toDouble())),
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

  /// A picker over the comp's other layers, with None. An unset or dangling
  /// reference is a labelled no-op engine-side, never a fault, so None is a
  /// first-class choice rather than an error state.
  ///
  /// **Lazy, and it has to be** (K-194): the options are built when the menu
  /// opens, so they can name every layer and ask which of them has a picture
  /// without either crossing the bridge on a rebuild (K-184) or probing a
  /// container with FFmpeg while drawing a row.
  Widget _layerPicker(BuildContext context, UuidValue id, UuidValue? current) {
    final chosen = current?.toString();
    return SizedBox(
      width: effectCellWidth + 40,
      child: BareLazyDropdown<UuidValue?>(
        key: ValueKey<String>('fx-layer-$id-${param.id}'),
        // Named from the read model when it can be, so the closed button
        // costs nothing; a reference to a layer since deleted says so.
        label: chosen == null
            ? 'None'
            : (ownerLayers
                    .where((l) => l.layer.internallayerId == current)
                    .map((l) => l.info.name)
                    .firstOrNull ??
                'Missing layer'),
        options: () => [
          (null, 'None'),
          for (final entry in ownerLayers)
            // A layer-valued parameter samples another layer's *picture* — a
            // depth map, a displacement source — so a layer with none (a
            // camera, an audio-only clip) is not offered, and neither is the
            // layer the effect is on: sampling itself is not defined.
            if (entry.layer.internallayerId != ownerLayerId &&
                entry.layer.hasPicture())
              (entry.layer.internallayerId, entry.info.name),
        ],
        onChanged: (picked) => _set(BridgeEffectValue.layer(picked)),
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

/// What a parameter holds before anything touches it — what Reset writes.
///
/// Read straight off the schema, which already carries every default and is
/// memoised here, so resetting an effect costs no bridge call to work out *what*
/// to write. Seed, file and layer declare none: a seed's default is zero, an
/// unset file is no paths, and an unset layer reference is None — each of which
/// is the identity the effect treats as "not configured".
BridgeEffectValue defaultEffectValue(BridgeParamKind kind) => switch (kind) {
      BridgeParamKind_Float(:final default_) =>
        BridgeEffectValue.float(BridgeScalar.static_(default_)),
      BridgeParamKind_Choice(:final default_) =>
        BridgeEffectValue.choice(default_),
      BridgeParamKind_Bool(:final default_) => BridgeEffectValue.bool(default_),
      BridgeParamKind_Colour(:final default_) =>
        BridgeEffectValue.colour(BridgeColour(
          r: BridgeScalar.static_(_channel(default_, 0)),
          g: BridgeScalar.static_(_channel(default_, 1)),
          b: BridgeScalar.static_(_channel(default_, 2)),
          a: BridgeScalar.static_(_channel(default_, 3, fallback: 1)),
        )),
      BridgeParamKind_Seed() => const BridgeEffectValue.seed(0),
      BridgeParamKind_File() => BridgeEffectValue.file(
          const BridgeFileParam(paths: [], index: BridgeScalar.static_(0))),
      BridgeParamKind_Layer() => const BridgeEffectValue.layer(),
    };

/// One channel of a declared colour default, tolerating a short list — a schema
/// that names only RGB still resets to an opaque colour rather than throwing.
double _channel(List<double> rgba, int i, {double fallback = 0}) =>
    i < rgba.length ? rgba[i] : fallback;

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

  /// Roughly one preview render per 20 ms, so a fast drag cannot outrun the
  /// renderer and queue up work it will only throw away — but the tick that
  /// lands inside the interval is *held*, not dropped, so the pointer's last
  /// position always reaches the picture ([PreviewThrottle]).
  final PreviewThrottle _throttle = PreviewThrottle();

  /// The value a row should *show*, which during a drag is the staged one.
  BridgeEffectValue? stagedValue(UuidValue effect, String param) {
    final staged = _staged;
    if (staged == null) return null;
    return staged.effect == effect && staged.param == param
        ? staged.value
        : null;
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
    // The stack is read *inside* the closure: a held tick must send the newest
    // staged value, not the one that was current when it was held.
    _throttle.request(() => comp.renderFrameWithPreview(
          frame: BigInt.from(frame),
          scale: scale,
          layer: layer,
          effects: stackWith(layer),
        ));
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
    // A release ends the drag: a held preview tick would render provisional
    // values *after* the commit, putting the pre-commit picture back on screen.
    _throttle.cancel();
    _staged = (effect: effect, param: param, value: value);
    try {
      layer.setEffects(effects: stackWith(layer));
    } catch (_) {
      debugPrint("Error while setting effect values");
      // Someone else edited the stack mid-drag. Drop ours and re-read.
    }
    _staged = null;
  }

  /// Forget any drag in progress — a cancelled gesture.
  void clear() {
    _throttle.cancel();
    _staged = null;
  }
}

class EffectParamRowExpression extends StatefulWidget {
  const EffectParamRowExpression(
      {required this.value,
      required this.set,
      required this.comp,
      required this.frame,
      required this.setLive,
      required this.layer,
      super.key});
  final BridgeScalar_Expression value;
  final CompositionReference comp;
  final int frame;
  final void Function(BridgeEffectValue value) set;
  final void Function(BridgeEffectValue value) setLive;
  final LayerReference layer;

  @override
  State<EffectParamRowExpression> createState() =>
      _EffectParamRowExpressionState();
}

const _defaultLightThemeFiles = [
  'packages/syntax_highlight/themes/light_vs.json',
  'packages/syntax_highlight/themes/light_plus.json',
];

const _defaultDarkThemeFiles = [
  'packages/syntax_highlight/themes/dark_vs.json',
  'packages/syntax_highlight/themes/dark_plus.json',
];

class ExpressionTextEditingController extends TextEditingController {
  static HighlighterTheme? darkTheme;
  static HighlighterTheme? lightTheme;

  static Future<void> initSyntaxHighlighting() async {
    await Highlighter.initialize(["dart"]);

    darkTheme = await HighlighterTheme.loadFromAssets(
        _defaultDarkThemeFiles, LumitTheme.dark().mono);

    lightTheme = await HighlighterTheme.loadFromAssets(
        _defaultLightThemeFiles, LumitTheme.light().mono);
  }

  ExpressionTextEditingController({super.text});

  @override
  TextSpan buildTextSpan(
      {required BuildContext context,
      TextStyle? style,
      required bool withComposing}) {

        final theme = ThemeScope.of(context).theme.mode == ThemeMode2.dark ? darkTheme! : lightTheme!;

    var highlighter = Highlighter(
      language: 'dart',
      theme: theme,
    );



    var span = highlighter.highlight(text);
    return span;
  }
}

class _EffectParamRowExpressionState extends State<EffectParamRowExpression> {
  late TextEditingController controller;

  double value = 0.0;
  late ValueNotifier<int> playhead;

  String lastText = "";

  @override
  void initState() {
    playhead = Provider.of<LumitUiState>(context, listen: false).playheadFrame;

    Provider.of<LumitState>(context, listen: false)
        .onChange
        .listen(onProjectChanged);

    playhead.addListener(onFrameChanged);

    controller = ExpressionTextEditingController(text: widget.value.field0);
    controller.addListener(onTextChanged);
    lastText = controller.text;

    value = sampleScalarWithContext(
        scalar: widget.value,
        time: timeOfFrame(widget.comp, playhead.value),
        layer: widget.layer);
    super.initState();
  }

  void onProjectChanged(ScopedChange event) {
    // print(event.layer);
    // print("Project changed!");

    // setState(() {
    //   controller.text = widget.value.field0;
    // });
  }

  @override
  void dispose() {
    playhead.removeListener(onFrameChanged);
    controller.removeListener(onTextChanged);

    super.dispose();
  }

  @override
  void didUpdateWidget(covariant EffectParamRowExpression oldWidget) {
    if (widget.value.field0 != controller.text) {
      // we dont want to trigger the update when setting text manually, so remove it then add it back
      controller.removeListener(onTextChanged);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        controller.text = widget.value.field0;
        controller.addListener(onTextChanged);
      });
    }
    super.didUpdateWidget(oldWidget);
  }

  void onFrameChanged() {
    final expr = controller.text;

    setState(() {
      value = sampleScalarWithContext(
          scalar: BridgeScalar_Expression(expr),
          time: timeOfFrame(widget.comp, playhead.value),
          layer: widget.layer);
    });
  }

  void onTextChanged() {
    final expr = controller.text;
    if (expr != lastText) {
      widget.setLive(BridgeEffectValue.float(BridgeScalar.expression(expr)));

      setState(() {
        value = sampleScalarWithContext(
            scalar: BridgeScalar_Expression(expr),
            time: timeOfFrame(widget.comp, playhead.value),
            layer: widget.layer);
      });
    }

    lastText = expr;
  }

  void removeExpression() {
    final expr = controller.text;

    var v = sampleScalarWithContext(
        scalar: BridgeScalar_Expression(expr),
        time: timeOfFrame(widget.comp, playhead.value),
        layer: widget.layer);

    widget.set(BridgeEffectValue.float(BridgeScalar_Static(v)));
  }

  @override
  Widget build(BuildContext context) {
    return _build(context);
  }

  Widget _build(BuildContext context) {
    final t = ThemeScope.of(context).theme;

    return Row(
      spacing: 4,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
            child: HouseContextMenu(
          itemBuilder: (close) {
            return [
              MenuRow(
                onPressed: () {
                  removeExpression();
                  close();
                },
                child: Text("Remove Expression"),
              )
            ];
          },
          child: HouseTextField(
            controller: controller,
            width: double.infinity,
            style: t.mono,
            submitOnLostFocus: true,
            autofill: ExpressionAutofillGenerator(),
            onSubmitted: (value) {
              print("Expression committed: $value");
              widget
                  .set(BridgeEffectValue.float(BridgeScalar_Expression(value)));
              onTextChanged();
            },
          ),
        )),
        SizedBox(
          width: 78,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                " = ",
                style: t.body.copyWith(color: t.textMuted),
              ),
              Text(
                value.toStringAsPrecision(6),
                style: t.mono.copyWith(color: t.textMuted),
              ),
            ],
          ),
        )
      ],
    );
  }
}
