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
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';
import 'package:lumit_flutter/src/rust/api/effect.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../icons/icons.dart';
import '../l10n/engine_labels.dart';
import '../l10n/strings.dart';
import '../state/comp_time.dart';
import '../state/dropper.dart';
import '../state/file_dialogs.dart';
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
  /// layer-valued parameter picks from (K-194). The owner is offered too
  /// (K-288): picking it means "this layer", the effect's own input. Both
  /// ride in from the read model, so the closed picker costs nothing.
  final UuidValue ownerLayerId;
  final List<BridgeLayerEntry> ownerLayers;

  /// Clicking the parameter's *name* selects it for the graph editor
  /// (docs/07 §4.3) — the name, not the whole row.
  final VoidCallback? onLabelTap;

  /// The parameter's graph line colour while it is selected.
  final Color? graphColour;

  /// The rest of this effect's parameter values, by id — what a control needs
  /// when its behaviour depends on a *sibling*. The depth-of-field focal point
  /// is the case that asks for it: its dropper reads the layer named by the
  /// effect's own `depth` parameter, and inverts what it reads when
  /// `depth_invert` is set, so it cannot be built from this parameter alone.
  /// Empty is a fair default — the row then simply offers no dropper.
  final Map<String, BridgeEffectValue> siblings;

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
    this.siblings = const {},
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
        engineLabel(param.label),
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
    // Int is a Float value with integer display (docs/08 §1.2), so it
    // animates exactly like Float.
    if (param.kind is! BridgeParamKind_Float &&
        param.kind is! BridgeParamKind_Int) {
      return null;
    }
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
          final field = _scalarField(
            context,
            scalar: field0,
            frame: frame,
            sliderMin: sliderMin,
            sliderMax: sliderMax,
            hardMin: hardMin,
            hardMax: hardMax,
            keyName: '$id-${param.id}',
            write: (s) => _set(BridgeEffectValue.float(s)),
          );
          // A number picked off the picture rather than typed: the focal point
          // of a depth-of-field, read straight off its own depth pass.
          final depth = _depthDropper(context, id, hardMin, hardMax);
          if (depth == null) return field;
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [field, const SizedBox(width: 4), depth],
          );
        }
        return Text('—', style: t.small);

      case BridgeParamKind_Int(
          :final sliderMin,
          :final sliderMax,
          :final hardMin,
          :final hardMax
        ):
        if (value case BridgeEffectValue_Float(:final field0)) {
          return _scalarField(
            context,
            scalar: field0,
            frame: frame,
            sliderMin: sliderMin.toDouble(),
            sliderMax: sliderMax.toDouble(),
            hardMin: hardMin?.toDouble(),
            hardMax: hardMax?.toDouble(),
            keyName: '$id-${param.id}',
            integer: true,
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
            // A long list gets the searchable, lazily-built picker: a
            // plain dropdown builds every row eagerly, and at 1299 options
            // (the K-262 lens library) that took the app down in layout.
            // No shipped list is that long since the K-264 curation, but
            // the guard stays for the next one.
            child: options.length >= searchableOptionThreshold
                ? BareSearchDropdown(
                    key: ValueKey<String>('fx-choice-$id-${param.id}'),
                    value: index,
                    options: options,
                    // "Maker · Model" labels group by their maker.
                    group: (label) {
                      final i = label.indexOf(' · ');
                      return i > 0 ? label.substring(0, i) : null;
                    },
                    hint:
                        l10n.searchFor(engineLabel(param.label).toLowerCase()),
                    onChanged: (i) => _set(BridgeEffectValue.choice(i)),
                  )
                : BareDropdown<int>(
                    key: ValueKey<String>('fx-choice-$id-${param.id}'),
                    value: index,
                    options: [for (var i = 0; i < options.length; i++) i],
                    label: (i) => engineLabel(options[i]),
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

      case BridgeParamKind_File(:final filter, :final filterName):
        if (value case BridgeEffectValue_File(:final field0)) {
          final paths = field0.paths;
          // The row is the picker (K-265): click to choose a file through
          // the schema's own filter, and an unset row says so. It was a
          // bare label through K-264 — the parameter existed and nothing
          // in the panel could set it, which the owner found within the
          // hour. A set row grows a clear button, because a File value's
          // neutral state is "none" and there was no way back to it.
          return SizedBox(
            width: effectCellWidth + 60,
            child: Row(
              children: [
                Flexible(
                  child: LumitTooltip(
                    message:
                        paths.isEmpty ? l10n.chooseA(filterName) : paths.first,
                    child: HouseButton(
                      key: ValueKey<String>('fx-file-$id-${param.id}'),
                      onPressed: () async {
                        final path =
                            await pickEffectInputFile(filter, filterName);
                        if (path == null) return;
                        _set(BridgeEffectValue.file(BridgeFileParam(
                          paths: [path],
                          index: const BridgeScalar.static_(0),
                        )));
                      },
                      child: Text(
                        paths.isEmpty
                            ? l10n.chooseEllipsis
                            : _basename(paths.first),
                        style: t.small,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
                if (paths.isNotEmpty)
                  LumitTooltip(
                    message: l10n.clear,
                    child: HouseButton(
                      key: ValueKey<String>('fx-file-clear-$id-${param.id}'),
                      onPressed: () => _set(BridgeEffectValue.file(
                          const BridgeFileParam(
                              paths: [], index: BridgeScalar.static_(0)))),
                      child: Text('×', style: t.small),
                    ),
                  ),
              ],
            ),
          );
        }
        return Text('—', style: t.small);
    }
  }

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
    bool integer = false,
  }) {
    // The drag paces itself by the declared slider span, so a 0–1 parameter and
    // a 0–500 one both feel the same under the pointer. An integer row steps
    // whole numbers and never shows decimals (docs/08 §1.2's Int kind).
    final span = (sliderMax - sliderMin).abs();
    final speed = integer
        ? (span <= 40 ? 0.08 : span / 400)
        : (span <= 0 ? 0.5 : span / 200);
    double snap(num v) => integer ? v.roundToDouble() : v.toDouble();

    if (scalar case BridgeScalar_Keyframed()) {
      final sampled =
          sampleScalar(scalar: scalar, time: timeOfFrame(comp, frame));
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
          onCommit: (v) =>
              write(scalarWithValueAt(scalar, snap(v), comp, frame)),
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
        speed: speed,
        decimals: integer ? 0 : 2,
        onChanged: (v) => write(BridgeScalar.static_(snap(v))),
        onChangeLive: (v) =>
            _setLive(BridgeEffectValue.float(BridgeScalar.static_(snap(v)))),
        onChangeEnd: (v) => write(BridgeScalar.static_(snap(v))),
      ),
    );
  }

  /// The dropper beside a depth-of-field focal point, or null when this row is
  /// not one (docs/07 §6.1, docs/08 §3.22).
  ///
  /// It is offered on the `focus` parameter of an effect that carries a `depth`
  /// layer, and reads that layer **alone** — a depth pass is nearly always
  /// hidden, so what the composite shows at that pixel is not the number the
  /// effect uses. `depth_invert` is applied here, at the pick, so the value
  /// written is the one the parameter means; the caption and the committed
  /// number can never disagree.
  Widget? _depthDropper(
      BuildContext context, UuidValue id, double? hardMin, double? hardMax) {
    if (param.id != 'focus') return null;
    if (siblings['depth'] case BridgeEffectValue_Layer(:final field0)
        when field0 != null) {
      final entry = ownerLayers
          .where((l) => l.layer.internallayerId == field0)
          .firstOrNull;
      if (entry == null) return null;
      final invert = switch (siblings['depth_invert']) {
        BridgeEffectValue_Bool(:final field0) => field0,
        _ => false,
      };
      return _DropperButton(
        id: 'fx-$id-${param.id}',
        tip: l10n.tipPickFocalPoint,
        arm: (ui) => ui.armDropper(DropperArm(
          id: 'fx-$id-${param.id}',
          reads: DropperReads.depth,
          label: engineLabel(param.label),
          sampleLayer: entry.layer,
          sampleLayerName: entry.info.name,
          onPick: (sample) {
            final d = invert ? 1 - sample.depth : sample.depth;
            final low = hardMin ?? 0, high = hardMax ?? 1;
            _set(BridgeEffectValue.float(
                BridgeScalar.static_(d.clamp(low, high))));
          },
        )),
      );
    }
    return null;
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

    // The value written for a picked colour: the three channels as statics,
    // clamped to the parameter's declared range, with alpha left alone.
    BridgeEffectValue valueOf(PickedColour picked) {
      double clamp(double v) => v < min ? min : (v > max ? max : v);
      return BridgeEffectValue.colour(BridgeColour(
        r: BridgeScalar.static_(clamp(picked.r)),
        g: BridgeScalar.static_(clamp(picked.g)),
        b: BridgeScalar.static_(clamp(picked.b)),
        a: colour.a,
      ));
    }

    return SizedBox(
      width: effectCellWidth + 22,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            key: ValueKey<String>('fx-colour-$id-${param.id}'),
            behavior: HitTestBehavior.opaque,
            onTap: () async {
              final box = context.findRenderObject();
              if (box is! RenderBox) return;
              await showColourPicker(
                context: context,
                position: box.localToGlobal(Offset(0, box.size.height + 4)),
                initial: PickedColour(
                    chan(colour.r), chan(colour.g), chan(colour.b)),
                // An effect colour is scene-linear in a float working depth
                // (fp16 today, docs/06 §3.1): 0–1 is black to white, and the
                // parameter's own range says how far past that it may go — an
                // HDR tint really does sit above 1, and a 0–255 dial could not
                // reach it. When the project depth switch lands (docs/06 §3.1),
                // an 8 bpc project is what passes `bytes` here.
                scale: ColourScale.unit,
                min: min,
                max: max,
                // Live all the way through: a drag inside the picker previews
                // on the picture, and each settled change is one undoable edit
                // — the same shape as dragging the number beside it.
                onPreview: (picked) => _setLive(valueOf(picked)),
                onCommit: (picked) => _set(valueOf(picked)),
              );
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
          const SizedBox(width: 4),
          // The dropper: lift this colour off the picture instead of choosing
          // it (docs/07 §6.1).
          _DropperButton(
            id: 'fx-$id-${param.id}',
            tip: l10n.tipSampleFromViewer,
            arm: (ui) => ui.armDropper(DropperArm(
              id: 'fx-$id-${param.id}',
              reads: DropperReads.colour,
              label: engineLabel(param.label),
              onPick: (sample) => _set(BridgeEffectValue.colour(BridgeColour(
                // Scene-linear, exactly as the parameter stores it, so the
                // sample passes through without a conversion to disagree over.
                r: BridgeScalar.static_(sample.r.clamp(min, max)),
                g: BridgeScalar.static_(sample.g.clamp(min, max)),
                b: BridgeScalar.static_(sample.b.clamp(min, max)),
                a: colour.a,
              ))),
            )),
          ),
        ],
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
    // The layer the effect is on says so, so "everything below" is readable
    // on an adjustment layer rather than an unexplained self-reference.
    String named(String name, UuidValue layerId) =>
        layerId == ownerLayerId ? l10n.thisLayerSuffix(name) : name;
    return SizedBox(
      width: effectCellWidth + 40,
      child: BareLazyDropdown<UuidValue?>(
        key: ValueKey<String>('fx-layer-$id-${param.id}'),
        // Named from the read model when it can be, so the closed button
        // costs nothing; a reference to a layer since deleted says so.
        label: chosen == null
            ? l10n.none
            : (ownerLayers
                    .where((l) => l.layer.internallayerId == current)
                    .map((l) => named(l.info.name, l.layer.internallayerId))
                    .firstOrNull ??
                l10n.missingLayer),
        options: () => [
          (null, l10n.none),
          for (final entry in ownerLayers)
            // A layer-valued parameter samples a *picture*, so a layer with
            // none (a camera, an audio-only clip) is not offered.
            //
            // The layer the effect is ON is always offered, picture or not
            // (K-288): picking it does not re-render that layer, it reads
            // the effect's own input at its point in the stack. That is the
            // whole point on an **adjustment layer** — which has no picture
            // of its own, and whose input is the composite of everything
            // below it. A Lens flare added to one starts here.
            if (entry.layer.internallayerId == ownerLayerId ||
                entry.layer.hasPicture())
              (
                entry.layer.internallayerId,
                named(entry.info.name, entry.layer.internallayerId)
              ),
        ],
        onChanged: (picked) => _set(BridgeEffectValue.layer(picked)),
      ),
    );
  }
}

/// Two `_x`/`_y` Float parameters as ONE point row (docs/07 §6.1): the pair
/// convention the Lens flare's light and Radial blur's centre follow. One
/// label (the shared stem), one stopwatch carrying both channels — the
/// Position-row shape — two value fields, and for %-of-frame pairs a
/// position dropper that picks the point off the Viewer.
class EffectPointRowFrb extends StatelessWidget {
  final UuidValue effectId;
  final BridgeParamInfo xParam;
  final BridgeParamInfo yParam;
  final BridgeEffectValue? xValue;
  final BridgeEffectValue? yValue;
  final CompositionReference comp;
  final int playheadFrame;
  final ValueChanged<int> onSeek;
  final void Function(UuidValue effect, String param, BridgeEffectValue value)
      onWrite;
  final void Function(UuidValue effect, String param, BridgeEffectValue value)
      onLive;
  final bool twoColumn;

  /// Whether the pair may take the position dropper, and in what unit it
  /// writes: null = no dropper; false = % of frame (fraction × 100, the
  /// legacy Radial blur centre); true = comp PIXELS (fraction × comp size,
  /// read from the comp at CLICK time — never in a rebuild, K-184 — which is
  /// the K-260 convention every new point pair uses).
  final bool? pickPixels;

  const EffectPointRowFrb({
    super.key,
    required this.effectId,
    required this.xParam,
    required this.yParam,
    required this.xValue,
    required this.yValue,
    required this.comp,
    required this.playheadFrame,
    required this.onSeek,
    required this.onWrite,
    required this.onLive,
    this.twoColumn = false,
    this.pickPixels,
  });

  BridgeScalar? _scalar(BridgeEffectValue? v) => switch (v) {
        BridgeEffectValue_Float(:final field0) => field0,
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
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
    final sx = _scalar(xValue);
    final sy = _scalar(yValue);
    // The shared stem: "Light x" / "Light y" → "Light".
    var stem = xParam.label;
    if (stem.toLowerCase().endsWith(' x')) {
      stem = stem.substring(0, stem.length - 2);
    }

    final keyframes = (sx == null || sy == null)
        ? null
        : KeyframeControlsFrb(
            scalars: [sx, sy],
            comp: comp,
            playheadFrame: playheadFrame,
            onSeek: onSeek,
            rowKey: '$id-${xParam.id}-pair',
            // Two parameters, so two writes: a keyframe op on the pair costs
            // two undo steps today (the staged editor commits per param).
            onWrite: (next) {
              if (next.length == 2) {
                onWrite(id, xParam.id, BridgeEffectValue.float(next[0]));
                onWrite(id, yParam.id, BridgeEffectValue.float(next[1]));
              }
            },
          );

    final label = Text(stem, style: t.body, overflow: TextOverflow.ellipsis);

    Widget field(BridgeParamInfo param, BridgeScalar? scalar) {
      if (scalar == null) return Text('—', style: t.small);
      final kind = param.kind;
      if (kind is! BridgeParamKind_Float) return Text('—', style: t.small);
      final span = (kind.sliderMax - kind.sliderMin).abs();
      final speed = span <= 0 ? 0.5 : span / 200;
      if (scalar case BridgeScalar_Keyframed()) {
        final sampled =
            sampleScalar(scalar: scalar, time: timeOfFrame(comp, frame));
        return SizedBox(
          width: effectCellWidth,
          child: KeyedValueField(
            fieldKey: ValueKey<String>('fx-float-$id-${param.id}'),
            value: sampled,
            min: kind.hardMin ?? -1000000,
            max: kind.hardMax ?? 1000000,
            speed: speed,
            onCommit: (v) => onWrite(
              id,
              param.id,
              BridgeEffectValue.float(
                  scalarWithValueAt(scalar, v, comp, frame)),
            ),
          ),
        );
      }
      return SizedBox(
        width: effectCellWidth,
        child: DragValueField(
          key: ValueKey<String>('fx-float-$id-${param.id}'),
          value: (scalar as BridgeScalar_Static).field0,
          min: kind.hardMin ?? -1000000,
          max: kind.hardMax ?? 1000000,
          speed: speed,
          decimals: 2,
          onChanged: (v) => onWrite(id, param.id,
              BridgeEffectValue.float(BridgeScalar.static_(v.toDouble()))),
          onChangeLive: (v) => onLive(id, param.id,
              BridgeEffectValue.float(BridgeScalar.static_(v.toDouble()))),
          onChangeEnd: (v) => onWrite(id, param.id,
              BridgeEffectValue.float(BridgeScalar.static_(v.toDouble()))),
        ),
      );
    }

    final control = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        field(xParam, sx),
        const SizedBox(width: 4),
        field(yParam, sy),
        if (pickPixels != null) ...[
          const SizedBox(width: 4),
          _DropperButton(
            id: 'fx-$id-${xParam.id}',
            tip: l10n.tipPickOnViewer,
            arm: (ui) => ui.armDropper(DropperArm(
              id: 'fx-$id-${xParam.id}',
              reads: DropperReads.position,
              label: stem,
              onPick: (sample) {
                // Pixel pairs write fraction × comp size (K-260); the legacy
                // %-pairs write fraction × 100. The size is read here, at
                // click time — a pick is an edit, not a rebuild (K-184).
                double x = sample.xFrac * 100;
                double y = sample.yFrac * 100;
                if (pickPixels == true) {
                  try {
                    final size = comp.getSize();
                    x = sample.xFrac * size.width;
                    y = sample.yFrac * size.height;
                  } catch (_) {
                    return; // the comp has gone; drop the pick
                  }
                }
                onWrite(id, xParam.id,
                    BridgeEffectValue.float(BridgeScalar.static_(x)));
                onWrite(id, yParam.id,
                    BridgeEffectValue.float(BridgeScalar.static_(y)));
              },
            )),
          ),
        ],
      ],
    );

    if (twoColumn) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: fxTwoColumnRow(
          context: context,
          name: label,
          keyframeControls: keyframes,
          control: control,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          if (keyframes != null) keyframes,
          const SizedBox(width: 4),
          Expanded(child: label),
          const SizedBox(width: 10),
          control,
        ],
      ),
    );
  }
}

/// The `_x` parameters whose pair takes the position dropper, mapped to the
/// unit it writes: true = comp pixels (the K-260 convention), false = % of
/// frame (the legacy Radial blur centre, until it migrates).
const Map<String, bool> pickablePointParams = {
  'light_x': true,
  'centre_x': false,
};

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

final Map<String, List<BridgeParamGroup>> _groupSchema = {};

/// An effect's parameter groups (docs/08 §1.2, K-145/K-257), memoised like
/// the parameters: the twirls and conditional runs the panel folds the flat
/// parameter list into.
List<BridgeParamGroup> cachedListParameterGroups(String effect) =>
    _groupSchema[effect] ??= listParameterGroups(effect: effect);

/// An effect's display label from the schema, falling back to its match name
/// for an effect this build does not know.
String effectLabelOf(String name) {
  for (final info in cachedListEffects()) {
    if (info.name == name) return engineLabel(info.label);
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
      BridgeParamKind_Int(:final default_) =>
        BridgeEffectValue.float(BridgeScalar.static_(default_.toDouble())),
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

/// The little pipette beside a parameter: click to arm the dropper, click it
/// again (or press Escape, or click away from the picture) to put it away.
///
/// It lights while *this* parameter's pick is the armed one, so a dropper armed
/// from one row and forgotten is visible from across the panel.
class _DropperButton extends StatelessWidget {
  /// This button's arm id — compared with the armed one to know when to light.
  final String id;
  final String tip;
  final void Function(LumitUiState ui) arm;

  const _DropperButton(
      {required this.id, required this.tip, required this.arm});

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final ui = Provider.of<LumitUiState>(context, listen: false);
    return ValueListenableBuilder<DropperArm?>(
      valueListenable: ui.dropper,
      builder: (context, armed, _) {
        final lit = armed?.id == id;
        return LumitTooltip(
          message: tip,
          child: GestureDetector(
            key: ValueKey<String>('dropper-$id'),
            behavior: HitTestBehavior.opaque,
            onTap: () => lit ? ui.disarmDropper() : arm(ui),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: SizedBox(
                width: 18,
                height: 18,
                child: Center(
                  child: lumitIcon(
                    LumitIcon.eyedropper,
                    size: iconSize,
                    color: lit ? t.accent : t.textSecondary,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
