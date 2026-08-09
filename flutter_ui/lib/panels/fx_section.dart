// The shape of one section in the Effect controls panel: a heading that twirls,
// and property rows under it laid out in two columns.
//
// **In plain terms.** The panel used to draw each effect as a separate bordered
// box, which made the stack read as a pile of unrelated cards. It is really one
// list — the same list the Timeline twirls open under a layer — so it is drawn
// as one now: a heading bar per section, a hairline under every row, names down
// the left and their controls down the right. The two columns are not divided by
// anything visible; they line up because every row reserves the same width for
// its name (`fxNameColumnWidth`), which is what makes a stack of numbers
// readable.
//
// **The heading row.** Left column: the twirl, the section's own enable switch
// where it has one, the name. Right column, aligned with the values below it:
// the section's actions — Reset for an effect. Hard against the right edge: the
// close mark, kept apart from the actions because removing is not an adjustment.
//
// **Round mode keeps its bubble** (K-092). Sharp draws the section edge to edge
// with hairlines, which is the After Effects reading; round wraps the same rows
// in the floating-card chrome, so the two shapes differ in chrome and not in
// layout.

import 'package:flutter/widgets.dart';

import '../icons/icons.dart';
import '../theme/theme.dart';
import '../widgets/controls.dart';

/// How wide the name column is — every row in the panel reserves this much for
/// its label so the controls stack into one column down the panel.
const double fxNameColumnWidth = 138;

/// The width a row leaves for its stopwatch when it has none, so labels line up
/// whether or not the property can animate.
const double fxKeyframeGutter = 18;

/// One twirl-open section: Source, Transform, or one effect.
class FxSection extends StatelessWidget {
  /// The section's own control, left of the name — an effect's enable switch.
  final Widget? leading;
  final String title;
  final bool open;
  final VoidCallback onToggle;

  /// Actions in the value column, aligned with the controls below — Reset.
  final List<Widget> actions;

  /// Hard right — the close mark.
  final Widget? trailing;

  /// A right-click on the heading, with the pointer's global position — where
  /// the actions that are not worth a permanent button live (an effect's
  /// reordering, K-276). Null leaves the secondary click unclaimed.
  final void Function(Offset at)? onContextMenu;

  /// A click on the heading's name **picks this section** (K-300) — an effect
  /// is a thing that can be selected, copied and cut, and the click that says
  /// which one is the one on its name. Null (Source, Transform: sections that
  /// are not one of several) leaves the name doing what the twirl does, which
  /// is what the whole heading did before.
  final VoidCallback? onSelect;

  /// Drawn picked: the heading takes the selection fill, as a Timeline row
  /// does, so one effect chosen in either place reads the same in both.
  final bool selected;

  /// The twirl mark's own key — it is the only thing that folds a selectable
  /// section, so it is worth being able to point at.
  final Key? twirlKey;

  /// This section's place in its list, when the heading may be **dragged** to
  /// another place in it (docs/07 §6's drag-to-reorder). Null — Source,
  /// Transform, anything that does not sit in a reorderable stack — leaves the
  /// heading undraggable and accepting nothing.
  final int? dragIndex;

  /// A heading dropped on this one: the place it came from. Called only when
  /// [dragIndex] is set and the two differ.
  final void Function(int from)? onDropped;

  /// The rows under the heading, drawn only while [open].
  final List<Widget> rows;

  /// While true the heading's name is an inline editor instead of a label —
  /// how an effect is renamed (`Enter` on the selected effect, K-317).
  /// Sections that cannot be renamed (Source, Transform) never set it.
  final bool renaming;

  /// The rename's commit: the typed name, empty to clear back to the
  /// effect's own label. Called on Enter and on clicking away, the same
  /// contract every inline rename in the application has (K-243).
  final ValueChanged<String>? onRenamed;

  const FxSection({
    super.key,
    required this.title,
    required this.open,
    required this.onToggle,
    required this.rows,
    this.leading,
    this.actions = const [],
    this.trailing,
    this.onContextMenu,
    this.onSelect,
    this.selected = false,
    this.twirlKey,
    this.dragIndex,
    this.onDropped,
    this.renaming = false,
    this.onRenamed,
  });

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _draggableHeading(t),
        if (open)
          for (final row in rows)
            Container(
              decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: t.hairline))),
              padding: const EdgeInsets.fromLTRB(8, 2, 6, 2),
              child: row,
            ),
      ],
    );

    // Round mode keeps the bubble the sharp shape does without; the rows inside
    // are identical either way.
    if (t.tokens.cardRadius <= 0) return column;
    return Container(
      margin: const EdgeInsets.fromLTRB(6, 4, 6, 4),
      decoration: BoxDecoration(
        color: t.surface1,
        borderRadius: BorderRadius.circular(t.tokens.cardRadius),
        border: Border.all(color: t.hairline),
      ),
      clipBehavior: Clip.antiAlias,
      child: column,
    );
  }

  /// The heading, wrapped in the drag-and-drop that reorders the stack when
  /// this section has a place in one. Dragging the *name* is how a stack is
  /// reordered everywhere else in the application (layers in the Timeline,
  /// items in the Project panel), so an effect stack reorders the same way; the
  /// heading also stays a drop target, and the one under the pointer lights up
  /// so it is clear which place is being taken.
  Widget _draggableHeading(LumitTheme t) {
    final index = dragIndex;
    if (index == null || onDropped == null) return _heading(t);
    return DragTarget<int>(
      onWillAcceptWithDetails: (d) => d.data != index,
      onAcceptWithDetails: (d) => onDropped!(d.data),
      builder: (context, candidate, _) => Draggable<int>(
        data: index,
        // The pointer carries the effect's name and nothing else: a full-width
        // card under the cursor hides the stack it is being placed into.
        feedback: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: t.surface2,
            borderRadius: BorderRadius.circular(t.tokens.controlRadius),
            border: Border.all(color: t.accent),
          ),
          child: Text(title, style: t.small),
        ),
        childWhenDragging: Opacity(opacity: 0.4, child: _heading(t)),
        child: candidate.isEmpty
            ? _heading(t)
            : DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: t.accent, width: 2)),
                ),
                child: _heading(t),
              ),
      ),
    );
  }

  Widget _heading(LumitTheme t) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        // **The name picks the effect; only the twirl folds it** (K-300). A
        // click that both picked and collapsed took the parameters away at the
        // moment you said which effect you meant, which is the opposite of what
        // selecting one is for. A section that cannot be picked (Source,
        // Transform) twirls on its name as it always did.
        onTap: onSelect ?? onToggle,
        onSecondaryTapUp: onContextMenu == null
            ? null
            : (details) => onContextMenu!(details.globalPosition),
        child: Container(
          color: selected ? t.selectionFill : t.surface2,
          padding: const EdgeInsets.fromLTRB(4, 4, 6, 4),
          child: Row(
            children: [
              SizedBox(
                width: fxNameColumnWidth,
                child: Row(
                  children: [
                    GestureDetector(
                      key: twirlKey,
                      behavior: HitTestBehavior.opaque,
                      onTap: onToggle,
                      child: Padding(
                        // Room to aim at, now that it is the only way in.
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: lumitIcon(
                          open ? LumitIcon.twirlOpen : LumitIcon.twirlClosed,
                          size: iconSize,
                          color: open ? t.textPrimary : t.textMuted,
                        ),
                      ),
                    ),
                    const SizedBox(width: 2),
                    if (leading case final widget?) ...[
                      widget,
                      const SizedBox(width: 6),
                    ],
                    Expanded(
                      child: renaming && onRenamed != null
                          ? _RenameField(initial: title, onDone: onRenamed!)
                          : Text(title,
                              style: t.bodyPrimary,
                              overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Row(children: actions),
              ),
              if (trailing case final widget?) widget,
            ],
          ),
        ),
      );
}

/// The heading's inline rename editor (K-317): opens with the current name
/// selected — a name is retyped far more often than amended — commits on
/// Enter or on clicking away, like every inline rename (K-243).
class _RenameField extends StatefulWidget {
  final String initial;
  final ValueChanged<String> onDone;
  const _RenameField({required this.initial, required this.onDone});

  @override
  State<_RenameField> createState() => _RenameFieldState();
}

class _RenameFieldState extends State<_RenameField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  )..selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.initial.length,
    );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => HouseTextField(
        key: const ValueKey('fx-rename-field'),
        controller: _controller,
        width: fxNameColumnWidth - 40,
        autofocus: true,
        submitOnLostFocus: true,
        onSubmitted: widget.onDone,
      );
}

/// One property row's two columns: [name] down the left, [control] down the
/// right, both left-aligned within their column.
///
/// [keyframeControls] leads the name column, and its space is reserved even when
/// there are none so a row that cannot animate lines up with one that can.
///
/// [name] is a widget rather than a string because a name is not only text: it
/// is the row's handle for the graph editor (docs/07 §4.3) — tappable, tinted to
/// its curve's colour while selected, and carrying a dot per axis on a
/// multi-axis property. The row that owns the property builds it once and hands
/// the same widget to whichever layout it draws, so the two cannot drift.
Widget fxTwoColumnRow({
  required BuildContext context,
  required Widget name,
  Widget? keyframeControls,
  required Widget control,
}) =>
    Row(
      children: [
        SizedBox(
          width: fxNameColumnWidth,
          child: Row(
            children: [
              keyframeControls ?? const SizedBox(width: fxKeyframeGutter),
              const SizedBox(width: 4),
              Expanded(child: name),
            ],
          ),
        ),
        Expanded(
          child: Align(alignment: Alignment.centerLeft, child: control),
        ),
      ],
    );

/// A section heading's text action — Reset. Sits in the value column, so it
/// reads as an action *on* the values rather than on the panel.
Widget fxTextAction(
  BuildContext context, {
  required String label,
  required String tip,
  required String keyName,
  required VoidCallback onPressed,
}) {
  final t = ThemeScope.of(context).theme;
  return LumitTooltip(
    message: tip,
    child: HouseButton(
      key: ValueKey<String>(keyName),
      frameless: true,
      small: true,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      onPressed: onPressed,
      child: Text(label, style: t.small.copyWith(color: t.textMuted)),
    ),
  );
}
