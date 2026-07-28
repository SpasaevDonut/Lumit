// A layer's Transform properties as editable rows — the one implementation of
// them, used by both panels that show them.
//
// The Effect controls panel wraps these in its Transform card; the Timeline
// twirls them open under a layer. They were the Effect controls card's private
// business first, and the Timeline's fold-out would have been a second copy of
// the same eleven properties, the same staging, and the same preview throttle —
// which is exactly the kind of copy that drifts. So they moved here whole.
//
// **What a row is.** Keyframe controls (the stopwatch and the ◄ ◆ ► navigator),
// a label, and one draggable value per axis. A property group that has more than
// one axis — Position is x and y — is *one* row with one stopwatch, because a
// control that says "Position" has to act on Position; the axes are separate
// properties underneath (which is what makes a per-axis curve possible) and are
// committed together as one op.
//
// **What a drag costs.** One undo step, not one per tick. A tick stages the new
// value locally and renders it through `renderFrameWithTransformPreview`, which
// patches a clone of the document engine-side and never touches the document;
// only the release commits. An animated property is not draggable at all —
// writing a static value over a curve would delete it — and says so instead.

import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:lumit_flutter/src/rust/api/effect.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';
import 'package:provider/provider.dart';

import '../state/timeline_columns.dart';
import '../widgets/controls.dart';
import 'fx_section.dart';
import 'keyframe_controls_frb.dart';

/// How wide one value cell is. Fixed rather than flexible so the columns line
/// up down the card, which is what makes a stack of numbers readable.
const double transformCellWidth = 74;

/// How often a drag is allowed to ask for a preview frame. Faster than the
/// renderer can answer is wasted work; slower and the picture lags the pointer.
const Duration _previewInterval = Duration(milliseconds: 40);

/// One axis of a transform row: which property it edits, and the display hints
/// that make its drag feel right.
class TransformAxis {
  final BridgeTransformProp prop;
  final String? suffix;
  final double min;
  final double max;
  final int decimals;
  final double speed;
  const TransformAxis(
    this.prop, {
    this.suffix,
    this.min = -100000,
    this.max = 100000,
    this.decimals = 1,
    this.speed = 1,
  });
}

/// One row: its label and the axes it edits.
class TransformGroup {
  final String label;
  final List<TransformAxis> axes;
  const TransformGroup(this.label, this.axes);
}

/// The rows a layer shows, in order.
///
/// The 3D rows (Position z, Rotation x, Rotation y) appear only on a 3D layer: a
/// 2D layer showing controls that cannot do anything is worse than not showing
/// them. Exposed as a list rather than built inline because the Timeline has to
/// know *how many* rows a layer will take before it draws them — its lanes have
/// to leave exactly that much room or the bars stop lining up with the names.
List<TransformGroup> transformGroups({required bool threeD}) => [
      const TransformGroup('Anchor point', [
        TransformAxis(BridgeTransformProp.anchorX),
        TransformAxis(BridgeTransformProp.anchorY),
      ]),
      TransformGroup('Position', [
        const TransformAxis(BridgeTransformProp.positionX),
        const TransformAxis(BridgeTransformProp.positionY),
        if (threeD) const TransformAxis(BridgeTransformProp.positionZ),
      ]),
      const TransformGroup('Scale', [
        TransformAxis(BridgeTransformProp.scaleX, suffix: '%'),
        TransformAxis(BridgeTransformProp.scaleY, suffix: '%'),
      ]),
      const TransformGroup('Rotation', [
        TransformAxis(BridgeTransformProp.rotation, suffix: '°', speed: 0.5),
      ]),
      if (threeD) ...[
        const TransformGroup('Rotation x', [
          TransformAxis(BridgeTransformProp.rotationX, suffix: '°', speed: 0.5),
        ]),
        const TransformGroup('Rotation y', [
          TransformAxis(BridgeTransformProp.rotationY, suffix: '°', speed: 0.5),
        ]),
      ],
      const TransformGroup('Opacity', [
        TransformAxis(BridgeTransformProp.opacity,
            suffix: '%', min: 0, max: 100, decimals: 0, speed: 0.5),
      ]),
    ];

/// A layer's transform rows, all of them.
///
/// The Effect controls card shows the whole set; the Timeline's fold-out draws
/// them one at a time (its lanes are per row), so the row itself is the widget
/// that carries the behaviour and this is a Column of them.
class TransformRowsFrb extends StatelessWidget {
  final CompositionReference comp;
  final LayerReference layer;

  /// The layer's transform and 3D flag, from the read model (K-184) — so
  /// drawing the rows costs no bridge calls.
  final BridgeTransform transform;
  final bool threeD;
  final int playheadFrame;
  final ValueChanged<int> onSeek;
  final VoidCallback onChanged;

  /// Prefixes every row's widget key, so the same rows in two panels do not
  /// collide when both are on screen.
  final String keyPrefix;

  /// A fixed height per row, for a caller that has to line something up beside
  /// them (the Timeline's lanes). Null lets each row take what it needs.
  final double? rowHeight;

  /// Padding inside each row.
  final EdgeInsets rowPadding;

  /// Lay the rows out as the Effect controls panel's two columns.
  final bool twoColumn;

  const TransformRowsFrb({
    super.key,
    required this.comp,
    required this.layer,
    required this.transform,
    required this.threeD,
    required this.playheadFrame,
    required this.onSeek,
    required this.onChanged,
    this.keyPrefix = 'tf',
    this.rowHeight,
    this.rowPadding = const EdgeInsets.symmetric(vertical: 3),
    this.twoColumn = false,
  });

  /// One widget per transform row — for a caller that has to put each row in its
  /// own chrome (the Effect controls panel's hairline-separated rows).
  List<Widget> rows(BuildContext context) => [
        for (final group in transformGroups(threeD: threeD))
          TransformRowFrb(
            comp: comp,
            layer: layer,
            transform: transform,
            group: group,
            playheadFrame: playheadFrame,
            onSeek: onSeek,
            onChanged: onChanged,
            keyPrefix: keyPrefix,
            rowHeight: rowHeight,
            rowPadding: rowPadding,
            twoColumn: twoColumn,
          ),
      ];

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: rows(context),
      );
}

/// One transform property group as a row.
class TransformRowFrb extends StatefulWidget {
  final CompositionReference comp;
  final LayerReference layer;

  /// The layer's transform as the owner last read it — one read shared by all
  /// the rows, rather than one crossing per row (K-183).
  final BridgeTransform transform;
  final TransformGroup group;
  final int playheadFrame;
  final ValueChanged<int> onSeek;
  final VoidCallback onChanged;
  final String keyPrefix;
  final double? rowHeight;
  final EdgeInsets rowPadding;

  /// When set (the Timeline's fold-out), the value cells share this fixed
  /// span — aligned to both its edges — instead of each taking
  /// [transformCellWidth], so the values sit exactly under the render-switch
  /// column group whatever order the groups are dragged into (docs/07 §4.3).
  final ValueColumn? valueColumn;

  /// Lay the row out as the Effect controls panel's two columns — name left,
  /// axes left-aligned in the rest. Ignored when [valueColumn] is set.
  final bool twoColumn;

  const TransformRowFrb({
    super.key,
    required this.comp,
    required this.layer,
    required this.transform,
    required this.group,
    required this.playheadFrame,
    required this.onSeek,
    required this.onChanged,
    this.keyPrefix = 'tf',
    this.rowHeight,
    this.rowPadding = const EdgeInsets.symmetric(vertical: 3),
    this.valueColumn,
    this.twoColumn = false,
  });

  @override
  State<TransformRowFrb> createState() => _TransformRowFrbState();
}

class _TransformRowFrbState extends State<TransformRowFrb> {
  /// The transform being dragged, held only for the length of one drag, so the
  /// preview renders the other ten properties as the document has them.
  BridgeTransform? _staged;

  final Stopwatch _since = Stopwatch()..start();
  Duration _lastPreview = Duration.zero;

  @override
  Widget build(BuildContext context) {
    // The live playhead: an animated cell shows (and edits) the value under
    // the playhead, so it must follow a scrub rather than hold the frame the
    // panel last drew at.
    final playhead =
        Provider.of<LumitUiState>(context, listen: false).playheadFrame;
    return ValueListenableBuilder<int>(
      valueListenable: playhead,
      builder: (context, frame, _) =>
          _row(_staged ?? widget.transform, widget.group, frame),
    );
  }

  Widget _row(BridgeTransform transform, TransformGroup group, int frame) {
    final t = ThemeScope.of(context).theme;
    // One stopwatch, every axis in the row — and one undo step, because
    // `setTransforms` commits them as a batch.
    final keyframes = KeyframeControlsFrb(
      scalars: [for (final axis in group.axes) read(transform, axis.prop)],
      comp: widget.comp,
      playheadFrame: widget.playheadFrame,
      onSeek: widget.onSeek,
      rowKey: '${widget.keyPrefix}-${group.axes.first.prop.name}',
      onWrite: (next) {
        widget.layer.setTransforms(
          props: [for (final axis in group.axes) axis.prop],
          values: next,
        );
        setState(() => _staged = null);
        widget.onChanged();
      },
    );

    if (widget.twoColumn && widget.valueColumn == null) {
      final row = Padding(
        padding: widget.rowPadding,
        child: fxTwoColumnRow(
          context: context,
          name: group.label,
          keyframeControls: keyframes,
          control: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < group.axes.length; i++) ...[
                if (i > 0) const SizedBox(width: 6),
                _cell(transform, group.axes[i], frame),
              ],
            ],
          ),
        ),
      );
      final height = widget.rowHeight;
      return height == null ? row : SizedBox(height: height, child: row);
    }

    final row = Padding(
      padding: widget.rowPadding,
      child: Row(
        children: [
          keyframes,
          const SizedBox(width: 4),
          Expanded(
            child: Text(group.label,
                style: t.body, overflow: TextOverflow.ellipsis),
          ),
          if (widget.valueColumn case final col?) ...[
            SizedBox(
              width: col.width,
              child: Row(
                children: [
                  for (var i = 0; i < group.axes.length; i++) ...[
                    if (i > 0) const SizedBox(width: 4),
                    Expanded(
                        child: _cell(transform, group.axes[i], frame,
                            fixed: false)),
                  ],
                ],
              ),
            ),
            SizedBox(width: col.rightInset),
          ] else
            for (final axis in group.axes) ...[
              const SizedBox(width: 6),
              _cell(transform, axis, frame),
            ],
        ],
      ),
    );
    final height = widget.rowHeight;
    return height == null ? row : SizedBox(height: height, child: row);
  }

  Widget _cell(BridgeTransform transform, TransformAxis axis, int frame,
      {bool fixed = true}) {
    final scalar = read(transform, axis.prop);

    // An animated property stays editable (docs/07 §4.3): the field shows the
    // value under the playhead, and a change writes it into the key sitting
    // there — or plants a new one — never flattening the curve.
    if (scalar is! BridgeScalar_Keyframed) {
      final static_ = (scalar as BridgeScalar_Static).field0;
      return SizedBox(
        width: fixed ? transformCellWidth : null,
        child: DragValueField(
          key: ValueKey<String>('${widget.keyPrefix}-${axis.prop.name}'),
          value: static_,
          min: axis.min,
          max: axis.max,
          speed: axis.speed,
          decimals: axis.decimals,
          suffix: axis.suffix,
          onChanged: (v) => _commit(axis.prop, v.toDouble()),
          onChangeStart: () => _staged = transform,
          onChangeLive: (v) => _live(axis.prop, v.toDouble()),
          onChangeEnd: (v) => _commit(axis.prop, v.toDouble()),
          onDragCancel: () => setState(() => _staged = null),
        ),
      );
    }

    final sampled = sampleScalar(
        scalar: scalar, time: widget.comp.timeOfFrame(frame: frame));
    // No live preview mid-drag: staging a keyframed transform through the
    // static-preview path would lie about the curve. The release commits one
    // op — the key at the playhead updated or planted.
    return SizedBox(
      width: fixed ? transformCellWidth : null,
      child: KeyedValueField(
        fieldKey: ValueKey<String>('${widget.keyPrefix}-${axis.prop.name}'),
        value: sampled,
        min: axis.min,
        max: axis.max,
        speed: axis.speed,
        decimals: axis.decimals,
        suffix: axis.suffix,
        onCommit: (v) => _commitKeyed(axis.prop, scalar, v, frame),
      ),
    );
  }

  /// Write `value` into the animated property's key at `frame` (or plant one
  /// there) — one op, one undo step.
  void _commitKeyed(
      BridgeTransformProp prop, BridgeScalar scalar, double value, int frame) {
    widget.layer.setTransform(
      prop: prop,
      value: scalarWithValueAt(scalar, value, widget.comp, frame),
    );
    widget.onChanged();
  }

  /// A drag tick: hold the new value locally and render it, without committing.
  void _live(BridgeTransformProp prop, double value) {
    final staged = write(_staged ?? widget.transform, prop, value);
    setState(() => _staged = staged);

    if (_since.elapsed - _lastPreview < _previewInterval) return;
    _lastPreview = _since.elapsed;
    final ui = Provider.of<LumitUiState>(context, listen: false);
    widget.comp.renderFrameWithTransformPreview(
      frame: BigInt.from(ui.playheadFrame.value),
      scale: ui.viewerScale,
      layer: widget.layer,
      transform: staged,
    );
  }

  /// Release, or a typed value: one op for the one property that changed.
  void _commit(BridgeTransformProp prop, double value) {
    widget.layer.setTransform(prop: prop, value: BridgeScalar.static_(value));
    setState(() => _staged = null);
    widget.onChanged();
  }
}

/// One property out of a transform.
BridgeScalar read(BridgeTransform tf, BridgeTransformProp prop) =>
    switch (prop) {
      BridgeTransformProp.anchorX => tf.anchorX,
      BridgeTransformProp.anchorY => tf.anchorY,
      BridgeTransformProp.positionX => tf.positionX,
      BridgeTransformProp.positionY => tf.positionY,
      BridgeTransformProp.positionZ => tf.positionZ,
      BridgeTransformProp.scaleX => tf.scaleX,
      BridgeTransformProp.scaleY => tf.scaleY,
      BridgeTransformProp.rotation => tf.rotation,
      BridgeTransformProp.rotationX => tf.rotationX,
      BridgeTransformProp.rotationY => tf.rotationY,
      BridgeTransformProp.opacity => tf.opacity,
    };

/// A copy of `tf` with one property replaced — what the preview renders.
///
/// Rebuilt field by field because the generated type has no `copyWith`: it is a
/// plain data class across the seam, which is the point of it.
BridgeTransform write(
    BridgeTransform tf, BridgeTransformProp prop, double value) {
  final replacement = BridgeScalar.static_(value);
  BridgeScalar pick(BridgeTransformProp p, BridgeScalar current) =>
      p == prop ? replacement : current;

  return BridgeTransform(
    anchorX: pick(BridgeTransformProp.anchorX, tf.anchorX),
    anchorY: pick(BridgeTransformProp.anchorY, tf.anchorY),
    positionX: pick(BridgeTransformProp.positionX, tf.positionX),
    positionY: pick(BridgeTransformProp.positionY, tf.positionY),
    positionZ: pick(BridgeTransformProp.positionZ, tf.positionZ),
    scaleX: pick(BridgeTransformProp.scaleX, tf.scaleX),
    scaleY: pick(BridgeTransformProp.scaleY, tf.scaleY),
    rotation: pick(BridgeTransformProp.rotation, tf.rotation),
    rotationX: pick(BridgeTransformProp.rotationX, tf.rotationX),
    rotationY: pick(BridgeTransformProp.rotationY, tf.rotationY),
    opacity: pick(BridgeTransformProp.opacity, tf.opacity),
  );
}
