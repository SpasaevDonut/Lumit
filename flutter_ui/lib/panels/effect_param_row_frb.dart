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
import '../state/comp_time.dart';
import '../state/dropper.dart';
import '../state/preview_throttle.dart';
import '../state/timeline_columns.dart';
import '../theme/theme.dart';
import '../widgets/angle_dial.dart';
import '../widgets/colour_picker.dart';
import '../widgets/controls.dart';
import 'fx_section.dart';
import 'keyframe_controls_frb.dart';
import 'viewer_layer_map.dart';

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

  /// Whether this row is editable, per the effect's conditional-enablement
  /// rules (`EnabledWhen` in the schema, `listParamLayout` across the bridge).
  ///
  /// A greyed row still draws its value — you can read what focus distance
  /// *would* be — but takes no gesture, because while Use focus point is ticked
  /// the number decides nothing and offering it to drag would be a lie about
  /// what is in charge.
  final bool enabled;

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
    this.enabled = true,
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
    final scalars = _animatableScalarsOf(value);
    // Only the number-shaped kinds animate; a choice, a layer or a file has
    // nothing to interpolate, so those rows carry no stopwatch at all. A point
    // carries one stopwatch over both its axes: they are separate properties,
    // which is what makes a per-axis curve possible, but one stopwatch covering
    // them has to act on both or it is lying about what it controls.
    final keyframes = scalars == null
        ? null
        : KeyframeControlsFrb(
            scalars: scalars,
            comp: comp,
            playheadFrame: playheadFrame,
            onSeek: onSeek,
            rowKey: '$id-${param.id}',
            onWrite: (next) => _set(
              next.length == 2
                  ? BridgeEffectValue.point(
                      BridgePoint(x: next[0], y: next[1]))
                  : BridgeEffectValue.float(next.single),
            ),
          );

    // The name is the row's handle for the graph editor, so it is built once
    // and drawn by whichever layout the row takes. A greyed row's name is
    // muted with it: half a row going quiet reads as a rendering fault rather
    // than as "this control is not the one in charge".
    final labelStyle = !enabled
        ? t.body.copyWith(color: t.textDisabled)
        : (graphColour == null ? t.body : t.body.copyWith(color: graphColour));
    final label = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onLabelTap,
      child: Text(
        param.label,
        style: labelStyle,
        overflow: TextOverflow.ellipsis,
      ),
    );

    final control = _greyed(_control(context, t, id, value, frame));

    if (twoColumn && valueColumn == null) {
      return Padding(
        padding: rowPadding,
        child: fxTwoColumnRow(
          context: context,
          name: label,
          keyframeControls: keyframes == null ? null : _greyed(keyframes),
          control: control,
        ),
      );
    }

    return Padding(
      padding: rowPadding,
      child: Row(
        children: [
          if (keyframes != null) _greyed(keyframes),
          const SizedBox(width: 4),
          Expanded(child: label),
          if (valueColumn case final col?) ...[
            SizedBox(
              width: col.width,
              child: Align(
                alignment: Alignment.centerLeft,
                child: control,
              ),
            ),
            SizedBox(width: col.rightInset),
          ] else ...[
            const SizedBox(width: 10),
            control,
          ],
        ],
      ),
    );
  }

  /// A control on a row another parameter has taken over: faded, and deaf to
  /// the pointer. Both halves matter — fading alone still lets a drag land, and
  /// blocking alone gives no reason why nothing happened.
  Widget _greyed(Widget child) => enabled
      ? child
      : Opacity(
          opacity: 0.4,
          child: IgnorePointer(child: child),
        );

  /// The scalars behind this row when the kind is one that can animate, else
  /// null.
  ///
  /// Float and Angle are one scalar each — an angle *is* a number of degrees,
  /// so it keys exactly as a float does. A point is two, keyed together. A
  /// colour animates per channel too, but the swatch has no room to key them
  /// and no sensible way to show four curves in one row, so it stays out.
  List<BridgeScalar>? _animatableScalarsOf(BridgeEffectValue? value) {
    return switch ((param.kind, value)) {
      (BridgeParamKind_Float(), BridgeEffectValue_Float(:final field0)) =>
        [field0],
      (BridgeParamKind_Angle(), BridgeEffectValue_Float(:final field0)) =>
        [field0],
      (BridgeParamKind_Point(), BridgeEffectValue_Point(:final field0)) =>
        [field0.x, field0.y],
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

      // An angle is a number of degrees plus a dial showing which way that
      // points — one control drawn twice, either half usable. The value is an
      // ordinary Float, so keyframes and expressions see nothing new.
      case BridgeParamKind_Angle(:final dialStep):
        if (value case BridgeEffectValue_Float(:final field0)) {
          return _angleControl(
            context,
            scalar: field0,
            frame: frame,
            step: dialStep,
            keyName: '$id-${param.id}',
          );
        }
        return Text('—', style: t.small);

      // A point is two numbers and the crosshair that fills them in from the
      // picture. The axes are separate properties in the model — that is what
      // makes a per-axis curve possible — so a pick writes both at once.
      case BridgeParamKind_Point():
        if (value case BridgeEffectValue_Point(:final field0)) {
          return _pointControl(context, t, id, field0, frame);
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
  }) {
    // The drag paces itself by the declared slider span, so a 0–1 parameter and
    // a 0–500 one both feel the same under the pointer.
    final span = (sliderMax - sliderMin).abs();
    final speed = span <= 0 ? 0.5 : span / 200;

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
        speed: speed,
        decimals: 2,
        onChanged: (v) => write(BridgeScalar.static_(v.toDouble())),
        onChangeLive: (v) => _setLive(
            BridgeEffectValue.float(BridgeScalar.static_(v.toDouble()))),
        onChangeEnd: (v) => write(BridgeScalar.static_(v.toDouble())),
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
        tip: 'Read the focal point off ${entry.info.name} in the Viewer',
        arm: (ui) => ui.armDropper(DropperArm(
          id: 'fx-$id-${param.id}',
          reads: DropperReads.depth,
          label: param.label,
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

  /// A number in degrees with the dial under it (docs/07 §6).
  ///
  /// The dial drags live and commits on release, exactly as the number does, so
  /// the two are interchangeable. It is unbounded in both: an angle animates
  /// through full turns rather than wrapping, and a keyframe pair that wrapped
  /// would spin backwards through the whole circle on the way to the next key.
  Widget _angleControl(
    BuildContext context, {
    required BridgeScalar scalar,
    required int frame,
    required double step,
    required String keyName,
  }) {
    final animated = scalar is! BridgeScalar_Static;
    final shown = animated
        ? sampleScalar(scalar: scalar, time: timeOfFrame(comp, frame))
        : scalar.field0;

    void write(double v) {
      // On a curve the edit lands in the key under the playhead, or plants one
      // — never flattening what is already there.
      final next = animated
          ? scalarWithValueAt(scalar, v, comp, frame)
          : BridgeScalar.static_(v);
      _set(BridgeEffectValue.float(next));
    }

    return SizedBox(
      width: effectCellWidth,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          DragValueField(
            key: ValueKey<String>('fx-angle-$keyName'),
            value: shown,
            min: -1000000,
            max: 1000000,
            speed: 1,
            decimals: 1,
            suffix: '°',
            onChanged: (v) => write(v.toDouble()),
            onChangeLive: animated
                ? null
                : (v) => _setLive(BridgeEffectValue.float(
                    BridgeScalar.static_(v.toDouble()))),
            onChangeEnd: (v) => write(v.toDouble()),
          ),
          const SizedBox(height: 3),
          AngleDial(
            key: ValueKey<String>('fx-dial-$keyName'),
            degrees: shown,
            step: step,
            enabled: enabled,
            // A dial drag is a drag like any other: preview each tick, commit
            // the release. On a curve there is no live preview, for the same
            // reason the number has none — the value being previewed is not
            // the one that will be stored.
            onChanged: (v) => animated
                ? null
                : _setLive(
                    BridgeEffectValue.float(BridgeScalar.static_(v))),
            onChangeEnd: write,
          ),
        ],
      ),
    );
  }

  /// Two number fields and the crosshair that fills them in from the picture.
  ///
  /// **The crosshair is the point of this control.** Setting a focus point by
  /// typing two numbers means reading coordinates off the Viewer and copying
  /// them across; arming this and clicking the thing you want sharp is the same
  /// edit without the arithmetic, which is why docs/07 §6 asks for it and why
  /// the Focus point row exists at all rather than being a distance slider.
  Widget _pointControl(BuildContext context, LumitTheme t, UuidValue id,
      BridgePoint point, int frame) {
    final ui = Provider.of<LumitUiState>(context, listen: false);
    final owner = '$id-${param.id}';

    double shown(BridgeScalar s) => s is BridgeScalar_Static
        ? s.field0
        : sampleScalar(scalar: s, time: timeOfFrame(comp, frame));

    // The Viewer reports where the click landed in **composition** pixels, but
    // a point parameter is authored in the **layer's own** pixels — the frame
    // the effect stack runs in, and the frame its auxiliary inputs (a depth
    // pass) are resampled to. On an untransformed full-frame layer the two are
    // the same, which is exactly why getting it wrong stays invisible until
    // someone scales or moves the layer and the focus lands somewhere else.
    //
    // The conversion is the Viewer's own [ViewerLayerMap.layerOf] with the
    // screen mapping taken out (origin zero, view scale 1), so a picked point
    // and a dragged move handle cannot disagree about where a layer is. A layer
    // whose transform is animated has no single position to invert, so the
    // point is taken as given rather than guessed at.
    Offset toLayerSpace(double x, double y) {
      final owner = ownerLayers
          .where((l) => l.layer.internallayerId == ownerLayerId)
          .firstOrNull;
      if (owner == null) return Offset(x, y);
      final tf = owner.layer.getTransform();
      double? still(BridgeScalar s) =>
          s is BridgeScalar_Static ? s.field0 : null;
      final px = still(tf.positionX);
      final py = still(tf.positionY);
      if (px == null || py == null) return Offset(x, y);
      return ViewerLayerMap.of(
        positionX: px,
        positionY: py,
        anchorX: still(tf.anchorX) ?? 0,
        anchorY: still(tf.anchorY) ?? 0,
        scaleXPercent: still(tf.scaleX) ?? 100,
        scaleYPercent: still(tf.scaleY) ?? 100,
        rotationDegrees: still(tf.rotation) ?? 0,
        origin: Offset.zero,
        viewScale: 1,
      ).layerOf(Offset(x, y));
    }

    // One write for both axes: they are two properties, but they are one point,
    // and two ops for one click is what the whole-value shape exists to avoid.
    void writeBoth(double x, double y) {
      BridgeScalar axis(BridgeScalar was, double v) => was is BridgeScalar_Static
          ? BridgeScalar.static_(v)
          : scalarWithValueAt(was, v, comp, frame);
      _set(BridgeEffectValue.point(BridgePoint(
        x: axis(point.x, x),
        y: axis(point.y, y),
      )));
    }

    Widget axisField(String axis, BridgeScalar scalar, bool isX) => SizedBox(
          width: effectCellWidth - 12,
          child: DragValueField(
            key: ValueKey<String>('fx-point-$axis-$owner'),
            value: shown(scalar),
            min: -1000000,
            max: 1000000,
            speed: 1,
            decimals: 1,
            onChanged: (v) => isX
                ? writeBoth(v.toDouble(), shown(point.y))
                : writeBoth(shown(point.x), v.toDouble()),
          ),
        );

    return ValueListenableBuilder<ViewerPickRequest?>(
      valueListenable: ui.viewerPick,
      builder: (context, armed, _) {
        final mine = armed?.owner == owner;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            axisField('x', point.x, true),
            const SizedBox(width: 4),
            axisField('y', point.y, false),
            const SizedBox(width: 4),
            LumitTooltip(
              message: mine
                  ? 'Click in the Viewer to place the point, or press Escape'
                  : 'Pick this point in the Viewer',
              child: GestureDetector(
                key: ValueKey<String>('fx-pick-$owner'),
                behavior: HitTestBehavior.opaque,
                // Armed again while already armed means "never mind", which is
                // the only way out that does not need the keyboard.
                onTap: () => mine
                    ? ui.cancelViewerPick()
                    : ui.armViewerPick(ViewerPickRequest(
                        owner: owner,
                        onPicked: (x, y) {
                          final p = toLayerSpace(x, y);
                          writeBoth(p.dx, p.dy);
                        },
                      )),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CustomPaint(
                      painter: _CrosshairPainter(
                        // Lit while it is this row's pick that is armed, so a
                        // panel full of points says which one is waiting.
                        colour: mine ? t.accent : t.textSecondary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
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
            tip: 'Sample ${param.label} from the Viewer',
            arm: (ui) => ui.armDropper(DropperArm(
              id: 'fx-$id-${param.id}',
              reads: DropperReads.colour,
              label: param.label,
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

/// The crosshair on a point row's pick button: a ring with four ticks reaching
/// in, which is the shape every host draws for "click somewhere in the picture".
class _CrosshairPainter extends CustomPainter {
  final Color colour;

  const _CrosshairPainter({required this.colour});

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2 - 3;
    final pen = Paint()
      ..color = colour
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    canvas.drawCircle(c, r, pen);
    // Ticks from the rim inward, leaving the middle clear so the ring reads as
    // a sight rather than a filled dot.
    const reach = 3.0;
    canvas.drawLine(Offset(c.dx, 0), Offset(c.dx, r - reach + 1), pen);
    canvas.drawLine(
        Offset(c.dx, size.height), Offset(c.dx, c.dy + r - 1), pen);
    canvas.drawLine(Offset(0, c.dy), Offset(r - reach + 1, c.dy), pen);
    canvas.drawLine(Offset(size.width, c.dy), Offset(c.dx + r - 1, c.dy), pen);
  }

  @override
  bool shouldRepaint(_CrosshairPainter old) => old.colour != colour;
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

final Map<String, BridgeParamLayout> _paramLayout = {};

/// How an effect's rows are arranged — its twirls and its greying rules.
/// Static for the life of the process, like the parameter list, so it is
/// memoised the same way.
BridgeParamLayout cachedListParamLayout(String effect) =>
    _paramLayout[effect] ??= listParamLayout(effect: effect);

/// Which of an effect's rows are editable, given what the instance holds.
///
/// The same rule as `lumit_core::fx::param_enabled`, evaluated here so ticking
/// a switch greys its dependent row on the spot rather than after a round trip
/// — a checkbox whose consequence arrives a frame later reads as a glitch. The
/// Rust side stays the authority the tests pin; this is the copy that has to
/// keep up with the pointer.
///
/// A rule naming a parameter the instance does not carry greys nothing: an
/// older instance that predates the deciding parameter stays fully editable
/// rather than locking a row it can never unlock.
Set<String> disabledParams(
  String effect,
  Map<String, BridgeEffectValue> values,
) {
  final disabled = <String>{};
  for (final rule in cachedListParamLayout(effect).enabledWhen) {
    final on = values[rule.on_];
    if (on == null) continue;
    // A rule pointed at the wrong kind of parameter is a schema mistake the
    // engine's own sweep fails the build for; here every mismatch falls through
    // to `true`, greying nothing rather than locking a row unreachably.
    final ok = switch (rule.cond) {
      BridgeEnabledCond_BoolIs(:final field0) =>
        on is BridgeEffectValue_Bool ? on.field0 == field0 : true,
      BridgeEnabledCond_ChoiceIs(:final field0) =>
        on is BridgeEffectValue_Choice ? on.field0 == field0 : true,
      BridgeEnabledCond_ChoiceIsNot(:final field0) =>
        on is BridgeEffectValue_Choice ? on.field0 != field0 : true,
      BridgeEnabledCond_LayerSet() =>
        on is BridgeEffectValue_Layer ? on.field0 != null : true,
    };
    if (!ok) disabled.add(rule.param);
  }
  return disabled;
}

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
      // An angle resets to its declared degrees like any other number.
      BridgeParamKind_Angle(:final default_) =>
        BridgeEffectValue.float(BridgeScalar.static_(default_)),
      // A point's schema default is raster-independent — the centring a fresh
      // instance gets is applied where the raster is known (the engine's
      // `instantiate_for_raster`), so Reset here restores the declared pair.
      BridgeParamKind_Point(:final defaultX, :final defaultY) =>
        BridgeEffectValue.point(BridgePoint(
          x: BridgeScalar.static_(defaultX),
          y: BridgeScalar.static_(defaultY),
        )),
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

  const _DropperButton({required this.id, required this.tip, required this.arm});

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
