// The rows for what a layer is *made of*, above its Transform.
//
// A text layer gets its words, size and fill; a camera gets its zoom; a solid
// gets the asset's colour and size. Which rows appear is decided by asking the
// layer, so a footage layer simply has none.
//
// **The solid row says who else it affects, and means it.** A solid is an asset
// in the Project panel, not a per-layer setting, so recolouring one recolours
// every layer drawing it. That is the useful behaviour — one edit repaints every
// backdrop — but it is a surprise if the row does not say so, which is why it
// does.

import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/src/rust/api/assets.dart';
import 'package:lumit_flutter/src/rust/api/effect.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';
import 'package:lumit_flutter/src/rust/api/project_item.dart';
import 'package:lumit_flutter/src/rust/api/retime.dart';
import 'package:lumit_flutter/src/rust/api/solid.dart';

import '../theme/theme.dart';
import '../widgets/colour_picker.dart';
import '../widgets/controls.dart';
import 'fx_section.dart';

/// The section of source rows for [layer], or nothing when its kind has none.
class SourceRowsFrb extends StatefulWidget {
  final LayerReference layer;
  final VoidCallback onChanged;

  /// Whether the section is twirled open, and how to toggle it — held by the
  /// panel so the open set survives a rebuild of these rows.
  final bool open;
  final VoidCallback onToggle;

  const SourceRowsFrb({
    super.key,
    required this.layer,
    required this.onChanged,
    required this.open,
    required this.onToggle,
  });

  @override
  State<SourceRowsFrb> createState() => _SourceRowsFrbState();
}

class _SourceRowsFrbState extends State<SourceRowsFrb> {
  TextEditingController? _text;

  @override
  void dispose() {
    _text?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final text = widget.layer.getText();
    final zoom = widget.layer.getCameraZoom();
    final solid = _solidOf(widget.layer);

    final rows = <Widget>[
      if (text != null) ..._textRows(t, text),
      if (zoom != null) _zoomRow(t, zoom),
      if (solid != null) ..._solidRows(t, solid),
      ..._retimeRows(t),
    ];
    if (rows.isEmpty) return const SizedBox.shrink();

    return FxSection(
      title: 'Source',
      open: widget.open,
      onToggle: widget.onToggle,
      rows: rows,
    );
  }

  /// The solid asset behind a solid layer, if that is what this layer is.
  SolidReference? _solidOf(LayerReference layer) {
    final item = layer.getSourceItem();
    return item is ItemReference_Solid ? item.field0 : null;
  }

  List<Widget> _textRows(LumitTheme t, BridgeTextDocument document) {
    // The controller is created against the document the layer currently has,
    // and rebuilt only when the text changed underneath us — otherwise typing
    // would fight the rebuild its own commit triggers.
    if (_text == null ||
        (_text!.text != document.text && !_text!.selection.isValid)) {
      _text?.dispose();
      _text = TextEditingController(text: document.text);
    }

    void write({String? body, double? size, BridgeColourRgba? fill}) {
      widget.layer.setText(
        document: BridgeTextDocument(
          text: body ?? _text!.text,
          size: size ?? document.size,
          fill: fill ?? document.fill,
        ),
      );
      widget.onChanged();
    }

    return [
      _row(
        t,
        'Text',
        SizedBox(
          width: _cellWidth + 60,
          child: HouseTextField(
            key: const ValueKey('src-text'),
            controller: _text!,
            width: _cellWidth + 60,
            onSubmitted: (value) => write(body: value),
          ),
        ),
      ),
      _row(
        t,
        'Size',
        SizedBox(
          width: _cellWidth,
          child: DragValueField(
            key: const ValueKey('src-text-size'),
            value: document.size,
            min: 1,
            max: 2000,
            decimals: 1,
            onChanged: (v) => write(size: v.toDouble()),
          ),
        ),
      ),
      _row(
        t,
        'Fill',
        _swatch(
          t,
          keyName: 'src-text-fill',
          colour: document.fill,
          onPicked: (c) => write(fill: c),
        ),
      ),
    ];
  }

  Widget _zoomRow(LumitTheme t, BridgeScalar zoom) {
    if (zoom is! BridgeScalar_Static) {
      return _row(
        t,
        'Zoom',
        Text('animated', style: t.small.copyWith(color: t.textMuted)),
      );
    }
    return _row(
      t,
      'Zoom',
      SizedBox(
        width: _cellWidth,
        child: DragValueField(
          key: const ValueKey('src-camera-zoom'),
          value: zoom.field0,
          min: 1,
          max: 100000,
          speed: 4,
          decimals: 0,
          onChanged: (v) {
            widget.layer
                .setCameraZoom(zoom: BridgeScalar.static_(v.toDouble()));
            widget.onChanged();
          },
        ),
      ),
    );
  }

  List<Widget> _solidRows(LumitTheme t, SolidReference solid) {
    final definition = solid.getDefinition();

    void write({BridgeColourRgba? colour, int? width, int? height}) {
      solid.setDefinition(
        definition: BridgeSolidDef(
          name: definition.name,
          colour: colour ?? definition.colour,
          width: width ?? definition.width,
          height: height ?? definition.height,
        ),
      );
      widget.onChanged();
    }

    return [
      _row(
        t,
        'Solid colour',
        _swatch(
          t,
          keyName: 'src-solid-colour',
          colour: definition.colour,
          onPicked: (c) => write(colour: c),
        ),
      ),
      _row(
        t,
        'Solid size',
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: _cellWidth,
              child: DragValueField(
                key: const ValueKey('src-solid-width'),
                value: definition.width,
                min: 1,
                max: 16384,
                onChanged: (v) => write(width: v.toInt()),
              ),
            ),
            const SizedBox(width: 6),
            SizedBox(
              width: _cellWidth,
              child: DragValueField(
                key: const ValueKey('src-solid-height'),
                value: definition.height,
                min: 1,
                max: 16384,
                onChanged: (v) => write(height: v.toInt()),
              ),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(
          'This is an asset — every layer using it changes.',
          style: t.small.copyWith(color: t.textMuted),
        ),
      ),
    ];
  }

  /// Retiming, on footage layers only. Absent until switched on, because "not
  /// retimed" and "retimed to exactly 1x" are different states in the file.
  List<Widget> _retimeRows(LumitTheme t) {
    // Only footage retimes; every other kind answers null to both.
    if (widget.layer.getKind() != BridgeLayerKind.footage) return const [];
    final retime = widget.layer.getRetime();

    final rows = <Widget>[
      _row(
        t,
        'Retime',
        HouseCheckbox(
          key: const ValueKey('src-retime-on'),
          value: retime != null,
          onChanged: (on) {
            widget.layer.setRetimeEnabled(on_: on);
            widget.onChanged();
          },
        ),
      ),
    ];
    if (retime == null) return rows;

    rows.add(_row(
      t,
      'Speed',
      retime.varies
          // A ramp has no single speed to show, and writing one would discard
          // its shape — the same rule an animated property follows.
          ? LumitTooltip(
              message: 'This layer ramps — edit it in the Retime graph',
              child: Text('varies (${retime.speedPercent.round()}% average)',
                  style: t.small.copyWith(color: t.textMuted)),
            )
          : SizedBox(
              width: _cellWidth,
              child: DragValueField(
                key: const ValueKey('src-retime-speed'),
                value: retime.speedPercent,
                min: -400,
                max: 400,
                decimals: 0,
                suffix: '%',
                onChanged: (v) {
                  widget.layer.setRetimeSpeed(percent: v.toDouble());
                  widget.onChanged();
                },
              ),
            ),
    ));

    rows.add(_row(
      t,
      'Allow reverse',
      HouseCheckbox(
        key: const ValueKey('src-retime-reverse'),
        value: retime.allowReverse,
        onChanged: (on) {
          widget.layer.setRetimeReverse(allow: on);
          widget.onChanged();
        },
      ),
    ));

    rows.add(_row(
      t,
      'In-between frames',
      SizedBox(
        width: _cellWidth + 40,
        child: BareDropdown<BridgeRetimeInterp>(
          key: const ValueKey('src-retime-interp'),
          value: retime.interpolation,
          options: BridgeRetimeInterp.values,
          label: (i) => switch (i) {
            BridgeRetimeInterp.nearest => 'Nearest',
            BridgeRetimeInterp.blend => 'Blend',
            BridgeRetimeInterp.flow => 'Optical flow',
          },
          onChanged: (i) {
            widget.layer.setRetimeInterpolation(interpolation: i);
            widget.onChanged();
          },
        ),
      ),
    ));
    return rows;
  }

  Widget _swatch(
    LumitTheme t, {
    required String keyName,
    required BridgeColourRgba colour,
    required ValueChanged<BridgeColourRgba> onPicked,
  }) {
    int byte(double f) => (f.clamp(0.0, 1.0) * 255).round();
    final shown =
        documentColour(byte(colour.r), byte(colour.g), byte(colour.b), 255);

    return SizedBox(
      width: _cellWidth,
      child: Align(
        alignment: Alignment.centerLeft,
        child: GestureDetector(
          key: ValueKey<String>(keyName),
          behavior: HitTestBehavior.opaque,
          onTap: () async {
            final box = context.findRenderObject();
            if (box is! RenderBox) return;
            await showColourPicker(
              context: context,
              position: box.localToGlobal(Offset(0, box.size.height + 4)),
              initial: shown,
              // A solid's colour applies as it is chosen — there is no
              // cheaper preview of a solid than the solid itself.
              onCommit: (picked) => onPicked(BridgeColourRgba(
                r: picked.r,
                g: picked.g,
                b: picked.b,
                a: colour.a,
              )),
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
      ),
    );
  }

  Widget _row(LumitTheme t, String label, Widget control) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: fxTwoColumnRow(
          context: context,
          // A source row is not a keyable property, so its name is plain text —
          // there is no curve for the graph editor to aim at.
          name: Text(label, style: t.body, overflow: TextOverflow.ellipsis),
          control: control,
        ),
      );
}

/// Matches the Effect controls panel's own cell width, so the two sections'
/// values line up down the panel.
const double _cellWidth = 78;
