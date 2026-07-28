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

  /// The rows under the heading, drawn only while [open].
  final List<Widget> rows;

  const FxSection({
    super.key,
    required this.title,
    required this.open,
    required this.onToggle,
    required this.rows,
    this.leading,
    this.actions = const [],
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(t),
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

  Widget _heading(LumitTheme t) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onToggle,
        child: Container(
          color: t.surface2,
          padding: const EdgeInsets.fromLTRB(4, 4, 6, 4),
          child: Row(
            children: [
              SizedBox(
                width: fxNameColumnWidth,
                child: Row(
                  children: [
                    lumitIcon(
                      open ? LumitIcon.twirlOpen : LumitIcon.twirlClosed,
                      size: 12,
                      color: open ? t.textPrimary : t.textMuted,
                    ),
                    const SizedBox(width: 2),
                    if (leading case final widget?) ...[
                      widget,
                      const SizedBox(width: 6),
                    ],
                    Expanded(
                      child: Text(title,
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
