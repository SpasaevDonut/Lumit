// The stopwatch and keyframe navigator, shared by the Transform rows and the
// effect parameter rows.
//
// One widget rather than two because the two rows differ only in *where* the
// value lives — a transform property or an effect parameter — and not at all in
// what keying it means. Each caller hands over the scalar and a way to write a
// new one; everything else is the same on both sides, which is what stops the
// two drifting into slightly different ideas of what the diamond does.
//
// **What the controls do** (docs/07 §5, matching After Effects):
//
// - **Stopwatch** turns animation on and off. Turning it on plants one key at
//   the playhead holding the value that is already there, so nothing moves.
//   Turning it off keeps the value the curve reads *at the playhead* rather than
//   snapping to the first key — which is why the sampling is done engine-side.
// - **◄ / ►** jump to the previous and next key, moving the playhead.
// - **◆** adds a key at the playhead, or removes the one already there. Filled
//   when the playhead sits on a key, hollow when it does not.
//
// Every one of these is a single write of the whole animation, so each is one
// undo step — the reason the frb API takes a whole `BridgeScalar` rather than
// v0's granular add/remove/shift ops, where a key drag that moved time *and*
// value cost two.

import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:lumit_flutter/src/rust/api/effect.dart';
import 'package:provider/provider.dart';

import '../icons/icons.dart';
import '../state/comp_time.dart';
import '../widgets/controls.dart';

/// The scalar with `value` written at `frame`: the key already there is
/// updated, or a new linear key is inserted in order. This is what typing or
/// dragging an *animated* value in the outline means (docs/07 §4.3) — on a
/// keyframe it edits that keyframe; between keyframes it plants one, exactly
/// as After Effects does. A static scalar just becomes the new value.
BridgeScalar scalarWithValueAt(
  BridgeScalar scalar,
  double value,
  CompositionReference comp,
  int frame,
) {
  if (scalar is! BridgeScalar_Keyframed) return BridgeScalar.static_(value);
  final next = <BridgeKeyframe>[];
  var replaced = false;
  for (final key in scalar.field0) {
    if (comp.frameAtTime(time: key.time) == frame) {
      next.add(BridgeKeyframe(
        time: key.time,
        value: value,
        interpIn: key.interpIn,
        interpOut: key.interpOut,
      ));
      replaced = true;
    } else {
      next.add(key);
    }
  }
  if (!replaced) {
    next
      ..add(BridgeKeyframe(
        time: comp.timeOfFrame(frame: frame),
        value: value,
        interpIn: const BridgeSideInterp.linear(),
        interpOut: const BridgeSideInterp.linear(),
      ))
      ..sort((a, b) => comp
          .frameAtTime(time: a.time)
          .compareTo(comp.frameAtTime(time: b.time)));
  }
  return BridgeScalar.keyframed(next);
}

/// A value field for a scalar that is **keyframed**: it shows the value under
/// the playhead and an edit writes the key sitting there (docs/07 §4.3).
///
/// The drag is staged in Dart and committed exactly once, on release — which
/// is the whole point of it existing. [DragValueField] falls back to
/// `onChanged` for every tick when no `onChangeLive` is given, so a keyframed
/// drag was writing one op per pixel: the undo stack filled with a step per
/// tick and a single undo moved the value back by one hair instead of undoing
/// the gesture. A drag that plants a *new* key was worse — it planted one per
/// tick.
class KeyedValueField extends StatefulWidget {
  /// The key on the inner field, so tests and callers address it as they
  /// would an ordinary value field.
  final Key fieldKey;

  /// The document's value at the playhead.
  final double value;
  final double min;
  final double max;
  final double speed;
  final int decimals;
  final String? suffix;

  /// The finished edit: a released drag, or a typed value. Called once.
  final ValueChanged<double> onCommit;

  const KeyedValueField({
    super.key,
    required this.fieldKey,
    required this.value,
    required this.onCommit,
    this.min = -1000000,
    this.max = 1000000,
    this.speed = 1,
    this.decimals = 2,
    this.suffix,
  });

  @override
  State<KeyedValueField> createState() => _KeyedValueFieldState();
}

class _KeyedValueFieldState extends State<KeyedValueField> {
  /// The value under the pointer mid-drag; null when nothing is in flight.
  double? _staged;

  void _commit(num value) {
    setState(() => _staged = null);
    widget.onCommit(value.toDouble());
  }

  @override
  Widget build(BuildContext context) => DragValueField(
        key: widget.fieldKey,
        value: _staged ?? widget.value,
        min: widget.min,
        max: widget.max,
        speed: widget.speed,
        decimals: widget.decimals,
        suffix: widget.suffix,
        // Typed, reset and pasted values are already one-shot edits.
        onChanged: _commit,
        onChangeStart: () => setState(() => _staged = widget.value),
        // A tick moves the number on screen and nothing else.
        onChangeLive: (v) => setState(() => _staged = v.toDouble()),
        onChangeEnd: _commit,
        onDragCancel: () => setState(() => _staged = null),
      );
}

class KeyframeControlsFrb extends StatelessWidget {
  /// The animations this control covers — one for a single value, several for a
  /// row that spans axes (Position's x and y).
  ///
  /// A multi-axis row keys its axes *together*: they are separate properties in
  /// the model, which is what makes a per-axis curve possible, but one stopwatch
  /// covering them has to act on all of them or it is lying about what it
  /// controls.
  final List<BridgeScalar> scalars;

  /// Commit a new animation for each — in ONE undo step. A caller spanning
  /// several properties must batch them; two ops for one click is what the
  /// whole-value shape exists to avoid.
  final ValueChanged<List<BridgeScalar>> onWrite;

  /// The comp, for turning frames into the exact rational times keys carry.
  final CompositionReference comp;

  final int playheadFrame;
  final ValueChanged<int> onSeek;

  /// Distinguishes this row's buttons in a panel full of them.
  final String rowKey;

  const KeyframeControlsFrb({
    super.key,
    required this.scalars,
    required this.onWrite,
    required this.comp,
    required this.playheadFrame,
    required this.onSeek,
    required this.rowKey,
  });

  /// The row's first animation, which is what the navigator reads.
  ///
  /// A multi-axis row keys every axis at the same times, so its axes agree about
  /// *where* the keys are even when they disagree about the values. Reading one
  /// is therefore enough to draw the diamonds and find the neighbours.
  BridgeScalar get _lead => scalars.first;

  List<BridgeKeyframe> _keysOf(BridgeScalar scalar) => switch (scalar) {
        BridgeScalar_Keyframed(:final field0) => field0,
        BridgeScalar_Static() => const [],
      };

  List<BridgeKeyframe> get _keys => _keysOf(_lead);

  /// True when *any* axis is animated. A row half-animated by the graph editor
  /// still shows its stopwatch lit, because turning it off is then the useful
  /// action.
  bool get _animated => scalars.any((s) => _keysOf(s).isNotEmpty);

  /// What each axis reads at `frame` — what a new key on it takes, so adding
  /// one never moves anything.
  List<double> _valuesNow(int frame) {
    final time = timeOfFrame(comp, frame);
    return [for (final s in scalars) sampleScalar(scalar: s, time: time)];
  }

  /// The key sitting exactly on `frame`, if there is one.
  ///
  /// Compared by *frame*, not by rational equality: a key placed at frame 24
  /// and the playhead at frame 24 are the same key to the user even if some
  /// other route stored an unreduced time.
  BridgeKeyframe? _keyAt(int frame) {
    for (final key in _keys) {
      if (frameAtTime(comp, key.time) == frame) return key;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    // The live playhead, not the one captured when the panel last drew: the
    // diamond fills exactly while the playhead sits on a key, and hollows the
    // moment it scrubs away (docs/07 §4.3).
    final playhead =
        Provider.of<LumitUiState>(context, listen: false).playheadFrame;
    return ValueListenableBuilder<int>(
      valueListenable: playhead,
      builder: (context, frame, _) => _build(context, frame),
    );
  }

  Widget _build(BuildContext context, int frame) {
    final t = ThemeScope.of(context).theme;
    final onKey = _keyAt(frame) != null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        LumitTooltip(
          message: _animated ? 'Stop animating this' : 'Animate this',
          child: _button(
            context,
            keyName: 'kf-stopwatch-$rowKey',
            child: lumitIcon(LumitIcon.stopwatch,
                size: 12, color: _animated ? t.accent : t.textMuted),
            onPressed: () => _toggleAnimated(frame),
          ),
        ),
        if (_animated) ...[
          _button(
            context,
            keyName: 'kf-prev-$rowKey',
            enabled: _neighbour(frame, before: true) != null,
            child: Text('◄',
                style: t.small.copyWith(
                    color: _neighbour(frame, before: true) == null
                        ? t.textDisabled
                        : t.textMuted)),
            onPressed: () => _seekTo(_neighbour(frame, before: true)),
          ),
          LumitTooltip(
            message: onKey ? 'Remove this keyframe' : 'Add a keyframe here',
            child: _button(
              context,
              keyName: 'kf-toggle-$rowKey',
              child: lumitIcon(
                onKey ? LumitIcon.keyframeFilled : LumitIcon.keyframe,
                size: 11,
                color: onKey ? t.accent : t.textMuted,
              ),
              onPressed: () => _toggleKeyHere(frame),
            ),
          ),
          _button(
            context,
            keyName: 'kf-next-$rowKey',
            enabled: _neighbour(frame, before: false) != null,
            child: Text('►',
                style: t.small.copyWith(
                    color: _neighbour(frame, before: false) == null
                        ? t.textDisabled
                        : t.textMuted)),
            onPressed: () => _seekTo(_neighbour(frame, before: false)),
          ),
        ],
      ],
    );
  }

  Widget _button(
    BuildContext context, {
    required String keyName,
    required Widget child,
    required VoidCallback onPressed,
    bool enabled = true,
  }) =>
      HouseButton(
        key: ValueKey<String>(keyName),
        frameless: true,
        small: true,
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
        onPressed: enabled ? onPressed : null,
        child: child,
      );

  /// Animation on: one key at the playhead holding what is already there.
  /// Animation off: the value the curve reads at the playhead, so turning it off
  /// leaves the picture where it is rather than jumping to the first key.
  void _toggleAnimated(int frame) {
    final values = _valuesNow(frame);
    if (_animated) {
      onWrite([for (final v in values) BridgeScalar.static_(v)]);
      return;
    }
    onWrite([
      for (final v in values) BridgeScalar.keyframed([_newKeyAt(frame, v)])
    ]);
  }

  /// Add a key at the playhead, or remove the one there.
  ///
  /// Removing the last key does not leave an empty curve — an animation with no
  /// keys is not a curve anything can evaluate — so it falls back to a static
  /// value holding what that key held.
  void _toggleKeyHere(int frame) {
    final removing = _keyAt(frame) != null;
    final values = _valuesNow(frame);
    final next = <BridgeScalar>[];

    for (var axis = 0; axis < scalars.length; axis++) {
      final keys = _keysOf(scalars[axis]);
      if (removing) {
        final rest = [
          for (final k in keys)
            if (comp.frameAtTime(time: k.time) != frame) k,
        ];
        // A curve with no keys is not something the engine can evaluate, so the
        // last one removed leaves a static value holding what it held.
        next.add(rest.isEmpty
            ? BridgeScalar.static_(values[axis])
            : BridgeScalar.keyframed(rest));
        continue;
      }
      // Keys must stay strictly ascending in time — the engine enforces it on
      // the way in, so this inserts in order rather than appending and hoping.
      final added = [...keys, _newKeyAt(frame, values[axis])]..sort((a, b) =>
          comp
              .frameAtTime(time: a.time)
              .compareTo(comp.frameAtTime(time: b.time)));
      next.add(BridgeScalar.keyframed(added));
    }
    onWrite(next);
  }

  BridgeKeyframe _newKeyAt(int frame, double value) => BridgeKeyframe(
        time: comp.timeOfFrame(frame: frame),
        value: value,
        // Linear both sides: the neutral default. Easing is the graph editor's
        // business, and guessing a bezier here would be a shape the user did not
        // ask for.
        interpIn: const BridgeSideInterp.linear(),
        interpOut: const BridgeSideInterp.linear(),
      );

  /// The nearest key strictly before or after `frame`.
  BridgeKeyframe? _neighbour(int frame, {required bool before}) {
    BridgeKeyframe? best;
    int? bestFrame;
    for (final key in _keys) {
      final at = frameAtTime(comp, key.time);
      if (before ? at >= frame : at <= frame) continue;
      if (bestFrame == null || (before ? at > bestFrame : at < bestFrame)) {
        best = key;
        bestFrame = at;
      }
    }
    return best;
  }

  void _seekTo(BridgeKeyframe? key) {
    if (key == null) return;
    onSeek(comp.frameAtTime(time: key.time));
  }
}
