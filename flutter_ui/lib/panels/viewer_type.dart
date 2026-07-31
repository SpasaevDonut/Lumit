// The Type tool: making and editing text layers on the picture (K-225,
// docs/07 §1.7, §2.3.2).
//
// **In plain terms.** With the Type tool in hand, clicking empty picture makes a
// **new text layer** where you clicked and puts a caret there; clicking an
// existing text layer edits *that* one. What you type appears in the picture as
// you type it, and the edit ends when you press `Escape`, press `Enter`, click
// somewhere else, or put the tool down. A new layer you never typed anything
// into is removed again — After Effects does the same, and a project full of
// empty text layers left by stray clicks is nobody's idea of a feature.
//
// **Why the document is written only once.** Every edit to the document is an
// undo step, so writing the layer on each keystroke would make `Ctrl+Z` walk
// back through a sentence one letter at a time. Instead the picture is kept in
// step with `render_frame_with_text_preview` — the same live-preview path a
// dragged transform uses (K-183), which shows a provisional value without the
// document ever holding it — and the layer is written once, when the edit ends.
// One typing session, one undo step.
//
// **Where the caret comes from.** The typing itself is a real Flutter text
// field, so arrows, selection, backspace, paste and IME all behave as they do
// everywhere else — but its *drawing* is turned off, because the text the user
// should see is the engine's own rendering of the layer. What is drawn here is
// the caret, placed by the same rough estimate of a line's width the engine
// uses to anchor a text layer (half the point size per character). It is an
// estimate, and it is the same estimate on both sides, which is what keeps the
// caret and the picture from disagreeing about where the line ends.

import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/src/rust/api/assets.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:lumit_flutter/src/rust/api/effect.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';
import 'package:lumit_flutter/state/tools.dart';

import '../state/preview_throttle.dart';
import '../widgets/controls.dart';
import 'viewer_gizmo.dart';
import 'viewer_tool_cursor.dart';
import 'viewer_layer_map.dart';

/// How wide a line of text is, roughly, in layer pixels.
///
/// **This is the engine's own estimate**, mirrored here on purpose: the bridge
/// anchors a new text layer at half of `characters × size × 0.5`, and the caret
/// is placed by the same sum. Neither is the true advance width of the glyphs —
/// that is known only to the rasteriser — but both being wrong the same way is
/// what matters for the caret sitting at the end of the line.
double estimatedTextWidth(String text, double size) =>
    text.runes.length * size * 0.5;

/// Where a point on screen falls in the composition's own pixels.
///
/// [fitted] is the rectangle the picture occupies on screen, which already
/// carries the magnification and the pan.
(double, double) compPointOf(Offset screen, Rect fitted, Size comp) {
  final scale = fitted.width / comp.width;
  return ((screen.dx - fitted.left) / scale, (screen.dy - fitted.top) / scale);
}

/// The anchor a text layer of this text wants: the middle of its estimated
/// bounds, so it scales and turns about itself rather than about its first
/// letter. The engine picks the same point when it makes a text layer.
Offset textAnchor(String text, double size) =>
    Offset(estimatedTextWidth(text, size) * 0.5, size * 0.5);

/// The Type tool over the picture.
class ViewerTypeLayer extends StatefulWidget {
  /// Whether a type tool is armed. Inert otherwise.
  final bool active;

  final ToolMode tool;
  final CompositionReference comp;
  final LumitState state;
  final LumitUiState uiState;

  /// Every layer with its box, top first — for finding the text layer under a
  /// click and for placing the caret over it.
  final List<LayerBox> boxes;

  /// Where the picture sits on screen.
  final Rect fitted;

  /// The composition's size in its own pixels.
  final Size compSize;

  final Color accent;

  final VoidCallback onChanged;

  const ViewerTypeLayer({
    super.key,
    required this.active,
    required this.tool,
    required this.comp,
    required this.state,
    required this.uiState,
    required this.boxes,
    required this.fitted,
    required this.compSize,
    required this.accent,
    required this.onChanged,
  });

  @override
  State<ViewerTypeLayer> createState() => _ViewerTypeLayerState();
}

class _ViewerTypeLayerState extends State<ViewerTypeLayer> {
  /// The layer being typed into, if any.
  LayerReference? _editing;

  /// Whether this tool made that layer, so an edit that ends with nothing typed
  /// can take it away again.
  bool _created = false;

  /// Where the line starts on screen — the point clicked for a new layer, or the
  /// layer's own origin for an existing one. The caret is measured from it.
  Offset _origin = Offset.zero;

  /// The point size and fill the edit is using, from the toolbar's options.
  double _size = 72;
  BridgeColourRgba _fill =
      const BridgeColourRgba(r: 1, g: 1, b: 1, a: 1);

  /// Where the pointer is, for the drawn beam vertical type wears (K-226).
  Offset? _pointer;

  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode(debugLabel: 'Type tool');
  final PreviewThrottle _throttle = PreviewThrottle();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTyped);
  }

  @override
  void didUpdateWidget(ViewerTypeLayer old) {
    super.didUpdateWidget(old);
    // Putting the tool down finishes the edit, as does swapping horizontal for
    // vertical: an edit belongs to the tool that started it.
    if (!widget.active || widget.tool != old.tool) _finish();
  }

  @override
  void dispose() {
    _throttle.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool get _editingNow => _editing != null;

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return const SizedBox.shrink();
    final viewScale = widget.fitted.width / widget.compSize.width;
    // Horizontal type wears the system's own I-beam; vertical type has one
    // drawn for it, because no platform ships a sideways beam (K-226).
    final vertical = widget.tool == ToolMode.typeVertical;
    final t = ThemeScope.of(context).theme;
    return Positioned.fill(
      child: MouseRegion(
        cursor:
            vertical ? SystemMouseCursors.none : SystemMouseCursors.text,
        onEnter: (e) => setState(() => _pointer = e.localPosition),
        onHover: (e) => setState(() => _pointer = e.localPosition),
        onExit: (_) => setState(() => _pointer = null),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: _onTapUp,
          child: Stack(
            children: [
              if (vertical)
                TextPointer(
                  at: _pointer,
                  mark: t.textPrimary,
                  outline: t.surface0,
                ),
              if (_editingNow)
                Positioned(
                  left: _origin.dx,
                  top: _origin.dy - _size * viewScale,
                  width: 1,
                  height: 1,
                  // The field itself never shows: the text a user should see is
                  // the engine's rendering of the layer, and a second copy of
                  // it in a different font on top of that would only disagree.
                  // What it is here for is the keyboard — arrows, backspace,
                  // selection, paste and IME, all of it for free. Invisible
                  // rather than *offstage*, because an offstage field is not
                  // built, and one that is not built takes no keystrokes.
                  child: Opacity(
                    opacity: 0,
                    child: EditableText(
                      controller: _controller,
                      focusNode: _focus,
                      style: TextStyle(fontSize: _size * viewScale),
                      cursorColor: widget.accent,
                      backgroundCursorColor: widget.accent,
                      onSubmitted: (_) => _finish(),
                    ),
                  ),
                ),
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _CaretPainter(
                      show: _editingNow,
                      origin: _origin,
                      before: _controller.selection.isValid
                          ? _controller.text.substring(
                              0,
                              _controller.selection.baseOffset
                                  .clamp(0, _controller.text.length),
                            )
                          : _controller.text,
                      size: _size,
                      viewScale: viewScale,
                      accent: widget.accent,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- The gesture ----------------------------------------------------------

  void _onTapUp(TapUpDetails details) {
    if (widget.tool == ToolMode.typeVertical) {
      widget.state.postNotice(
        'Vertical type is not built yet — the engine lays out one horizontal line',
      );
      return;
    }
    // Whatever was being typed is finished first: a click elsewhere is what
    // ends an edit, exactly as it does in After Effects.
    _finish();

    final existing = _textLayerAt(details.localPosition);
    if (existing != null) {
      _begin(existing.layer, existing.box.map.toScreen(0, existing.box.map.ay),
          created: false);
      return;
    }
    _create(details.localPosition);
  }

  /// The topmost text layer whose box contains [at], or null.
  ({LayerBox box, LayerReference layer})? _textLayerAt(Offset at) {
    for (final box in widget.boxes) {
      if (!box.contains(at)) continue;
      try {
        if (box.layer.getText() != null) return (box: box, layer: box.layer);
      } catch (_) {
        // A layer that went away between the read model and the click.
      }
    }
    return null;
  }

  /// Make a text layer where the pointer is, and start typing into it.
  void _create(Offset at) {
    final options = widget.uiState.tools;
    final (cx, cy) = compPointOf(at, widget.fitted, widget.compSize);
    try {
      final layer = widget.comp.addTextLayer();
      // The starter document is "Text" at the middle of the comp; the tool
      // wants an empty line where the user clicked, in the toolbar's colour
      // and size.
      layer.setText(
        document: BridgeTextDocument(
          text: '',
          size: options.textSize,
          fill: options.fillRgba,
        ),
      );
      layer.setTransforms(
        props: const [
          BridgeTransformProp.anchorX,
          BridgeTransformProp.anchorY,
          BridgeTransformProp.positionX,
          BridgeTransformProp.positionY,
        ],
        values: [
          // The click is where the text goes (K-226): the anchor starts on the
          // left end of the line's baseline, so what is typed runs to the right
          // of the pointer and sits on it rather than straddling it. An empty
          // line has no width to be anchored in the middle of anyway; the
          // anchor is recentred when the edit ends.
          BridgeScalar.static_(0),
          BridgeScalar.static_(options.textSize),
          BridgeScalar.static_(cx),
          BridgeScalar.static_(cy),
        ],
      );
      widget.uiState.setSelection([layer]);
      _begin(layer, at, created: true);
      widget.onChanged();
    } catch (_) {
      widget.state.postNotice('Could not add a text layer', error: true);
    }
  }

  void _begin(LayerReference layer, Offset origin, {required bool created}) {
    final document = () {
      try {
        return layer.getText();
      } catch (_) {
        return null;
      }
    }();
    if (document == null) return;
    setState(() {
      _editing = layer;
      _created = created;
      _origin = origin;
      _size = document.size;
      _fill = document.fill;
      _controller.text = document.text;
      _controller.selection =
          TextSelection.collapsed(offset: document.text.length);
    });
    _focus.requestFocus();
  }

  /// Every keystroke: the picture keeps up through the preview path, and the
  /// caret moves. The document is not touched.
  void _onTyped() {
    if (!_editingNow) return;
    setState(() {});
    final layer = _editing!;
    _throttle.request(() {
      try {
        widget.comp.renderFrameWithTextPreview(
          frame: BigInt.from(widget.uiState.playheadFrame.value),
          scale: widget.uiState.viewerScale,
          layer: layer,
          document: BridgeTextDocument(
            text: _controller.text,
            size: _size,
            fill: _fill,
          ),
        );
      } catch (_) {
        // A preview is a courtesy; the typing carries on without it.
      }
    });
  }

  /// End the edit: write the document once, or take the layer away if nothing
  /// was ever typed into a layer this tool made.
  void _finish() {
    final layer = _editing;
    if (layer == null) return;
    final text = _controller.text;
    _throttle.cancel();
    setState(() {
      _editing = null;
      _controller.clear();
    });
    _focus.unfocus();

    try {
      if (text.isEmpty) {
        // An empty line renders nothing, so a layer left empty by a stray click
        // would be an invisible row in the Timeline. One this tool made goes
        // away again; one the user already had keeps whatever it had.
        if (_created) {
          layer.delete();
          widget.onChanged();
        }
        return;
      }
      layer.setText(
        document: BridgeTextDocument(text: text, size: _size, fill: _fill),
      );
      if (_created) _recentreAnchor(layer, text);
      widget.onChanged();
    } catch (_) {
      // The layer was deleted while it was being typed into.
    }
  }

  /// Put a new layer's anchor in the middle of the line it turned out to hold,
  /// **without the line moving**: the pivot slides and Position compensates,
  /// the same pan-behind sum the Anchor point tool commits (K-220).
  void _recentreAnchor(LayerReference layer, String text) {
    final transform = layer.getTransform();
    final old = Offset(
      staticValueOf(transform.anchorX) ?? 0,
      staticValueOf(transform.anchorY) ?? 0,
    );
    final wanted = textAnchor(text, _size);
    final position = panBehindPosition(
      oldAnchor: old,
      newAnchor: wanted,
      position: Offset(
        staticValueOf(transform.positionX) ?? 0,
        staticValueOf(transform.positionY) ?? 0,
      ),
      scaleXPercent: staticValueOf(transform.scaleX) ?? 100,
      scaleYPercent: staticValueOf(transform.scaleY) ?? 100,
      rotationDegrees: staticValueOf(transform.rotation) ?? 0,
    );
    layer.setTransforms(
      props: const [
        BridgeTransformProp.anchorX,
        BridgeTransformProp.anchorY,
        BridgeTransformProp.positionX,
        BridgeTransformProp.positionY,
      ],
      values: [
        BridgeScalar.static_(wanted.dx),
        BridgeScalar.static_(wanted.dy),
        BridgeScalar.static_(position.dx),
        BridgeScalar.static_(position.dy),
      ],
    );
  }
}

/// A transform channel's plain value, or null when it is keyframed and so has
/// no one value to read.
double? staticValueOf(BridgeScalar scalar) =>
    scalar is BridgeScalar_Static ? scalar.field0 : null;

/// The caret, and nothing else: the text belongs to the picture.
class _CaretPainter extends CustomPainter {
  final bool show;
  final Offset origin;
  final String before;
  final double size;
  final double viewScale;
  final Color accent;

  const _CaretPainter({
    required this.show,
    required this.origin,
    required this.before,
    required this.size,
    required this.viewScale,
    required this.accent,
  });

  @override
  void paint(Canvas canvas, Size canvasSize) {
    if (!show) return;
    final x = origin.dx + estimatedTextWidth(before, size) * viewScale;
    final height = size * viewScale;
    canvas.drawRect(
      Rect.fromLTWH(x, origin.dy - height, 1.5, height),
      Paint()..color = accent,
    );
  }

  @override
  bool shouldRepaint(_CaretPainter old) =>
      old.show != show ||
      old.origin != origin ||
      old.before != before ||
      old.size != size ||
      old.viewScale != viewScale ||
      old.accent != accent;
}
