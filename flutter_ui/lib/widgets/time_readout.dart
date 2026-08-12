// The clock readouts that do not move, and can be typed into.
//
// **In plain terms.** A timecode or a frame number drawn as ordinary text
// changes width as it counts — `f9` is half the width of `f10`, and
// `00:00:09:00` narrower than `00:00:10:00` in a font whose digits are not all
// the same width. During playback that happens sixty times a second, and
// everything to the right of the number shuffles with it: the Timeline's
// search field used to twitch through every second of playback. So each
// readout gets a **fixed slot**, wide enough for the longest thing it can ever
// say, and the number sits in it without pushing anything.
//
// The same widget is also how a time is *typed*: clicking a readout turns it
// into a field holding exactly what was shown, in the same format, and what is
// typed is read back through the caller's own parser. A time outside the
// composition is clamped to the nearest end rather than refused — asking for
// frame 100000 in a 300-frame comp means "the end", and there is nothing
// useful about an error where a clamp will do (docs/07 §2.2, §4.1).
//
// A readout may also be **dragged** left and right, the way every number field
// in Lumit drags, for the places that were a drag field before they were a
// clock (the Retime row).

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'controls.dart';

/// The width of [characters] characters of [style], measured once per style
/// and length.
///
/// Measured from the digit `0`: the readouts are drawn in the monospaced face
/// where every glyph is that wide, and where a build falls back to a
/// proportional font the digit is the widest thing a clock face carries, so
/// the slot comes out generous rather than short. Cached because it is asked
/// for on every rebuild of a bar that rebuilds per frame, and the answer
/// depends only on the face, the size and the count.
double monoSlotWidth(TextStyle style, int characters) {
  final key = (style.fontFamily, style.fontSize ?? 12.0, characters);
  final hit = _slotWidths[key];
  if (hit != null) return hit;
  final painter = TextPainter(
    text: TextSpan(text: '0' * characters, style: style),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();
  _slotWidths[key] = width;
  return width;
}

final Map<(String?, double, int), double> _slotWidths = {};

/// The padding inside a readout's slot, so the numbers on a bar sit apart from
/// each other and from whatever is beside them.
const EdgeInsets readoutPadding = EdgeInsets.symmetric(horizontal: 6);

/// How many pixels of drag move a draggable readout by one frame.
const double _pixelsPerFrame = 4;

/// A clock readout in a fixed slot: click it to type a new time.
///
/// [format] writes the frame the way this readout says times; [parse] reads
/// what was typed back into a frame, or returns null when it is not a time at
/// all — in which case the edit is dropped and the readout goes back to
/// showing where things really are. A parsed frame is clamped into
/// `[minFrame, maxFrame]` before it is handed to [onCommit].
class TimeReadout extends StatefulWidget {
  /// What the readout is showing.
  final int frame;

  /// The frame as this readout writes it.
  final String Function(int frame) format;

  /// Typed text back to a frame, or null when it cannot be read.
  final int? Function(String text) parse;

  /// How wide the slot is, in characters — the longest thing this readout can
  /// ever say, so nothing moves as it counts.
  final int widthChars;

  final TextStyle style;

  /// Where a typed or dragged frame goes, already clamped.
  final ValueChanged<int> onCommit;

  final int minFrame;
  final int maxFrame;

  /// Whether the readout can be dragged left and right to change it.
  final bool draggable;

  /// The live frame during a drag, for a caller that shows the value it is
  /// dragging before the drag ends. [onCommit] still fires on release.
  final ValueChanged<int>? onDragLive;

  /// A drag that ended without ever moving a whole frame, or was cancelled —
  /// what a caller staging a live value uses to put its staging back.
  final VoidCallback? onDragCancel;

  /// What hovering says. Null for no tooltip.
  final String? tooltip;

  const TimeReadout({
    super.key,
    required this.frame,
    required this.format,
    required this.parse,
    required this.widthChars,
    required this.style,
    required this.onCommit,
    required this.minFrame,
    required this.maxFrame,
    this.draggable = false,
    this.onDragLive,
    this.onDragCancel,
    this.tooltip,
  });

  @override
  State<TimeReadout> createState() => _TimeReadoutState();
}

class _TimeReadoutState extends State<TimeReadout>
    implements TextSelectionGestureDetectorBuilderDelegate {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();
  bool _editing = false;
  bool _hovered = false;

  /// The open editor, for the selection gestures — pressing places the caret
  /// and dragging highlights, like any text box (K-319).
  final GlobalKey<EditableTextState> textFieldKey = GlobalKey();

  @override
  GlobalKey<EditableTextState> get editableTextKey => textFieldKey;

  @override
  bool get forcePressEnabled => false;

  @override
  bool get selectionEnabled => true;

  /// Pixels dragged since the last whole frame was ticked.
  double _dragAccum = 0;

  /// The last frame ticked this drag, or null when nothing has ticked yet.
  int? _dragged;

  int get _low => widget.minFrame;
  int get _high => widget.maxFrame < _low ? _low : widget.maxFrame;

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _beginEdit() {
    final text = widget.format(widget.frame);
    setState(() {
      _editing = true;
      _controller.text = text;
      // Selected, not merely placed: a readout is retyped far more often than
      // it is amended, and a caret at the end would make every edit start with
      // a select-all of its own.
      _controller.selection =
          TextSelection(baseOffset: 0, extentOffset: text.length);
    });
  }

  /// Take what was typed, or leave the readout as it was when what is there
  /// does not read as a time.
  void _commitTyped() {
    if (!_editing) return;
    final parsed = widget.parse(_controller.text);
    setState(() => _editing = false);
    if (parsed == null) return;
    widget.onCommit(parsed.clamp(_low, _high));
  }

  void _cancel() => setState(() => _editing = false);

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final width = monoSlotWidth(widget.style, widget.widthChars) +
        readoutPadding.horizontal;

    final Widget inner = _editing
        ? Focus(
            onKeyEvent: (node, event) {
              if (event is KeyDownEvent &&
                  event.logicalKey == LogicalKeyboardKey.escape) {
                _cancel();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: TextSelectionGestureDetectorBuilder(delegate: this)
                .buildGestureDetector(
              child: EditableText(
                key: textFieldKey,
                controller: _controller,
                focusNode: _focus,
                autofocus: true,
                style: widget.style.copyWith(color: t.textPrimary),
                cursorColor: t.accent,
                backgroundCursorColor: t.surface2,
                selectionColor: t.accent.withValues(alpha: 0.5),
                onSubmitted: (_) => _commitTyped(),
                // Clicking away finishes the edit rather than throwing it
                // away: people leave a field by looking at the next thing
                // (K-243).
                onTapOutside: (_) => _commitTyped(),
              ),
            ),
          )
        : Text(
            widget.format(widget.frame),
            style: widget.style,
            maxLines: 1,
            overflow: TextOverflow.clip,
            softWrap: false,
          );

    final Widget slot = MouseRegion(
      cursor: widget.draggable
          ? SystemMouseCursors.resizeLeftRight
          : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _editing ? null : _beginEdit,
        onHorizontalDragStart: widget.draggable
            ? (_) {
                _dragAccum = 0;
                _dragged = null;
              }
            : null,
        onHorizontalDragUpdate: widget.draggable
            ? (d) {
                // Shift scrubs coarse (×10), Ctrl fine (×0.1) — with whole
                // frames, fine means ten times the drag per frame.
                _dragAccum += d.delta.dx * scrubFactor();
                final steps = (_dragAccum / _pixelsPerFrame).truncate();
                if (steps == 0) return;
                _dragAccum -= steps * _pixelsPerFrame;
                final next =
                    ((_dragged ?? widget.frame) + steps).clamp(_low, _high);
                _dragged = next;
                (widget.onDragLive ?? widget.onCommit)(next);
              }
            : null,
        onHorizontalDragEnd: widget.draggable
            ? (_) {
                final last = _dragged;
                _dragged = null;
                if (last != null) {
                  widget.onCommit(last);
                } else if (!_editing) {
                  // Never crossed a whole frame: the press was a click that
                  // wobbled, not a scrub — cancel the drag, then do what the
                  // click meant and open the editor (K-319).
                  widget.onDragCancel?.call();
                  _beginEdit();
                }
              }
            : null,
        onHorizontalDragCancel: widget.draggable
            ? () {
                _dragged = null;
                widget.onDragCancel?.call();
              }
            : null,
        child: Container(
          width: width,
          padding: readoutPadding,
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: _editing
                ? t.surface0
                : _hovered
                    ? t.surface2
                    : null,
            borderRadius: BorderRadius.circular(t.tokens.controlRadius),
          ),
          child: inner,
        ),
      ),
    );

    final tip = widget.tooltip;
    return tip == null ? slot : LumitTooltip(message: tip, child: slot);
  }
}
