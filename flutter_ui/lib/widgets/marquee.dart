// Drag-a-box selection, shared by the Timeline's lanes and the graph editor.
//
// In plain terms: put this as a `Positioned.fill` layer in a Stack, behind the
// things that take their own gestures (bars, key handles). Dragging on empty
// space draws the box; on release [onSelect] gets the box's rectangle in local
// coordinates and the owner decides what fell inside it. A plain click calls
// [onClear] — a selection box around nothing means "select nothing" everywhere.

import 'package:flutter/widgets.dart';

import 'controls.dart';

class MarqueeSelect extends StatefulWidget {
  /// The finished box, in this widget's own coordinates.
  final ValueChanged<Rect> onSelect;

  /// A plain click on the background: clear the owner's selection.
  final VoidCallback onClear;

  const MarqueeSelect({
    super.key,
    required this.onSelect,
    required this.onClear,
  });

  @override
  State<MarqueeSelect> createState() => _MarqueeSelectState();
}

class _MarqueeSelectState extends State<MarqueeSelect> {
  Offset? _from;
  Offset? _to;

  void _finish() {
    final from = _from;
    final to = _to;
    setState(() {
      _from = null;
      _to = null;
    });
    if (from == null || to == null) return;
    widget.onSelect(Rect.fromPoints(from, to));
  }

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onClear,
            // Down, not start: a pan's start position is where the slop was
            // exceeded, which would eat the box's first corner and whatever
            // sat nearest it.
            onPanDown: (d) => _from = d.localPosition,
            onPanStart: (d) => setState(() => _to = d.localPosition),
            onPanUpdate: (d) => setState(() => _to = d.localPosition),
            onPanEnd: (_) => _finish(),
            onPanCancel: () => setState(() {
              _from = null;
              _to = null;
            }),
          ),
        ),
        if (_from != null && _to != null)
          Positioned.fromRect(
            rect: Rect.fromPoints(_from!, _to!),
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  color: t.accent.withValues(alpha: 0.12),
                  border: Border.all(color: t.accent, width: 1),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
