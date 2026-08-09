// The Ctrl+Space console (K-324): a search bar over the effects, and a radial
// menu of whatever the selection makes sensible.
//
// **In plain terms.** Two ways of reaching the same kinds of thing, stacked in
// one window, because they suit different moments.
//
// The **search bar** at the top is for when you know the name. Type "gau" and
// Gaussian blur is the first row; Enter applies it to the selected layers. It
// is modelled on Video Copilot's FX Console, which is the tool After Effects
// users install first and then cannot work without — including its **snapshot**
// button, which writes the frame you are looking at to a PNG so you can compare
// two versions of a look without setting up an export.
//
// Effects come first in the list and compositions after a divider, because the
// overwhelmingly common thing to want is an effect; comps are there so the one
// window can also be "take me to that comp" rather than needing its own.
//
// The **radial menu** below is for when you do not want to type at all. Its
// entries are chosen by what is selected — the timeline with nothing picked
// offers new layers, a picked effect offers the things you do to an effect —
// and every entry sits at a fixed angle, so the hand learns the direction and
// stops reading. See `widgets/radial_maths.dart` for why direction rather than
// hit-testing decides the choice.
//
// **The console applies things; it does not know how.** Every entry carries a
// callback the caller supplied, exactly as the command palette does (docs/07
// §12), so this file holds no idea about the document and cannot drift out of
// step with what the menus do.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../icons/icons.dart';
import '../l10n/strings.dart';
import '../theme/theme.dart';
import '../widgets/controls.dart';
import '../widgets/radial_maths.dart';

/// What kind of thing a search row is — what the divider separates, and what
/// the row's badge says.
enum FxConsoleKind {
  /// A built-in effect, applied to the selection.
  effect,

  /// A composition, fronted in the Timeline.
  composition,
}

/// One row the console's search can find.
class FxConsoleEntry {
  final String label;
  final FxConsoleKind kind;

  /// The group shown beside the label — an effect's category, or nothing.
  final String? group;
  final VoidCallback run;

  const FxConsoleEntry({
    required this.label,
    required this.kind,
    required this.run,
    this.group,
  });
}

/// One slice of the radial menu.
class RadialEntry {
  final String label;
  final VoidCallback run;

  /// Drawn dimmed and unpickable — an action that belongs in this context but
  /// cannot run right now, so the ring keeps its shape and the direction a
  /// hand has learned still means the same thing.
  final bool enabled;

  const RadialEntry({
    required this.label,
    required this.run,
    this.enabled = true,
  });
}

/// Everything the console shows, gathered by the caller from the live
/// selection — see `menu_bar_frb.dart`, which builds it beside the menus.
class FxConsoleModel {
  final List<FxConsoleEntry> entries;

  /// The radial slices for the current selection, in ring order from straight
  /// up, clockwise. Empty hides the ring entirely rather than drawing a
  /// circle with nothing in it.
  final List<RadialEntry> radial;

  /// What the radial menu is about right now ("Timeline", "Gaussian blur") —
  /// drawn in the middle of the ring so the context is never a guess.
  final String radialTitle;

  /// Save the frame on screen as a PNG. Null where there is nothing to save
  /// (no composition open), which greys the button.
  final VoidCallback? onSnapshot;

  const FxConsoleModel({
    required this.entries,
    required this.radial,
    required this.radialTitle,
    this.onSnapshot,
  });
}

Future<void> showFxConsoleFrb({
  required BuildContext context,
  required FxConsoleModel model,
}) =>
    showLumitModal<void>(
      context: context,
      builder: (close) => _FxConsole(model: model, onClose: () => close(null)),
    );

/// How well `needle` matches `haystack` as a subsequence, or null for no
/// match. Lower is better. Shared shape with the command palette's ranking
/// (docs/07 §12): earlier and tighter wins, so the thing half-remembered comes
/// to the top rather than a coincidence further down.
int? fxConsoleScore(String needle, String haystack) {
  if (needle.isEmpty) return 0;
  final lower = haystack.toLowerCase();
  var at = 0;
  var first = -1;
  var last = 0;
  for (final rune in needle.toLowerCase().runes) {
    final found = lower.indexOf(String.fromCharCode(rune), at);
    if (found < 0) return null;
    if (first < 0) first = found;
    last = found;
    at = found + 1;
  }
  return (last - first) + first;
}

/// The matching entries, effects first and compositions after — the order the
/// divider in the list stands for. Ranked within each kind, never across it:
/// a comp is never allowed to outrank an effect, because the reason to open
/// this window is nearly always an effect.
List<FxConsoleEntry> fxConsoleMatches(
    List<FxConsoleEntry> entries, String query) {
  final needle = query.trim();
  final scored = <(int, int, int, FxConsoleEntry)>[];
  for (var i = 0; i < entries.length; i++) {
    final entry = entries[i];
    final score = fxConsoleScore(needle, entry.label);
    if (score == null) continue;
    // Kind first, then relevance, then the declared order so the ranking is
    // stable for equal scores rather than depending on the sort.
    scored.add((entry.kind.index, score, i, entry));
  }
  scored.sort((a, b) {
    final byKind = a.$1.compareTo(b.$1);
    if (byKind != 0) return byKind;
    final byScore = a.$2.compareTo(b.$2);
    return byScore != 0 ? byScore : a.$3.compareTo(b.$3);
  });
  return [for (final entry in scored) entry.$4];
}

class _FxConsole extends StatefulWidget {
  final FxConsoleModel model;
  final VoidCallback onClose;
  const _FxConsole({required this.model, required this.onClose});

  @override
  State<_FxConsole> createState() => _FxConsoleState();
}

class _FxConsoleState extends State<_FxConsole> {
  final TextEditingController _query = TextEditingController();
  int _highlighted = 0;

  /// Which radial slice the pointer is choosing, or null in the dead zone.
  int? _radialHover;

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() => _highlighted = 0));
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  List<FxConsoleEntry> get _matches =>
      fxConsoleMatches(widget.model.entries, _query.text);

  void _runHighlighted(List<FxConsoleEntry> matches) {
    if (matches.isEmpty) return;
    final entry = matches[_highlighted.clamp(0, matches.length - 1)];
    widget.onClose();
    entry.run();
  }

  void _runSlice(int index) {
    final radial = widget.model.radial;
    if (index < 0 || index >= radial.length) return;
    final entry = radial[index];
    if (!entry.enabled) return;
    widget.onClose();
    entry.run();
  }

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final matches = _matches;

    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        switch (event.logicalKey) {
          case LogicalKeyboardKey.arrowDown:
            setState(() => _highlighted =
                matches.isEmpty ? 0 : (_highlighted + 1) % matches.length);
            return KeyEventResult.handled;
          case LogicalKeyboardKey.arrowUp:
            setState(() => _highlighted = matches.isEmpty
                ? 0
                : (_highlighted - 1 + matches.length) % matches.length);
            return KeyEventResult.handled;
          case LogicalKeyboardKey.enter:
          case LogicalKeyboardKey.numpadEnter:
            _runHighlighted(matches);
            return KeyEventResult.handled;
          case LogicalKeyboardKey.escape:
            widget.onClose();
            return KeyEventResult.handled;
          default:
            return KeyEventResult.ignored;
        }
      },
      child: FloatSurface(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _searchBar(t, matches),
            if (matches.isNotEmpty) _results(t, matches),
            if (widget.model.radial.isNotEmpty) ...[
              Container(height: 1, color: t.hairline),
              _ring(t),
            ],
          ],
        ),
      ),
    );
  }

  Widget _searchBar(LumitTheme t, List<FxConsoleEntry> matches) => Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            Expanded(
              child: HouseTextField(
                key: const ValueKey('fx-console-query'),
                controller: _query,
                width: 340,
                autofocus: true,
                hint: l10n.fxConsoleHint,
                onSubmitted: (_) => _runHighlighted(matches),
              ),
            ),
            const SizedBox(width: 6),
            // The snapshot button, in the corner FX Console puts it: one press
            // writes the frame on screen to a PNG, so two versions of a look
            // can be compared without setting an export up.
            LumitTooltip(
              message: l10n.fxConsoleSnapshotTip,
              child: HouseButton(
                key: const ValueKey('fx-console-snapshot'),
                small: true,
                onPressed: widget.model.onSnapshot == null
                    ? null
                    : () {
                        widget.onClose();
                        widget.model.onSnapshot!();
                      },
                child: lumitIcon(LumitIcon.snapshot,
                    size: iconSize, color: t.textSecondary),
              ),
            ),
          ],
        ),
      );

  Widget _results(LumitTheme t, List<FxConsoleEntry> matches) => ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 260),
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: matches.length,
          itemBuilder: (context, i) {
            final entry = matches[i];
            // The divider between the effects and everything below them: drawn
            // where the kind changes, so it is right however the list is
            // filtered rather than at a fixed row.
            final startsSection = i > 0 && matches[i - 1].kind != entry.kind;
            final row = MenuRow(
              key: ValueKey<String>('fx-console-item-${entry.label}'),
              selected: i == _highlighted,
              onPressed: () {
                widget.onClose();
                entry.run();
              },
              child: Row(
                children: [
                  Expanded(child: Text(entry.label)),
                  if (entry.group != null)
                    Text(entry.group!,
                        style: t.small.copyWith(color: t.textMuted)),
                ],
              ),
            );
            if (!startsSection) return row;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
                  child: Row(
                    children: [
                      Expanded(child: Container(height: 1, color: t.hairline)),
                      const SizedBox(width: 6),
                      Text(_sectionLabel(entry.kind),
                          style: t.small.copyWith(color: t.textMuted)),
                    ],
                  ),
                ),
                row,
              ],
            );
          },
        ),
      );

  String _sectionLabel(FxConsoleKind kind) => switch (kind) {
        FxConsoleKind.effect => l10n.fxConsoleEffects,
        FxConsoleKind.composition => l10n.fxConsoleCompositions,
      };

  /// The ring. A press anywhere in it chooses by direction — see
  /// `radial_maths.dart` — and releasing runs what is chosen, so the whole
  /// menu is one flick. Clicking a label works too, for a hand that would
  /// rather aim than flick.
  Widget _ring(LumitTheme t) {
    final radial = widget.model.radial;
    const size = (radialRadius + 56) * 2;
    return SizedBox(
      height: size,
      child: LayoutBuilder(
        builder: (context, box) {
          final centre = Offset(box.maxWidth / 2, size / 2);
          void track(Offset local) {
            final at = local - centre;
            final slice = radialSliceAt(at.dx, at.dy, radial.length);
            if (slice != _radialHover) setState(() => _radialHover = slice);
          }

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (d) => track(d.localPosition),
            onPanUpdate: (d) => track(d.localPosition),
            onPanEnd: (_) {
              final slice = _radialHover;
              setState(() => _radialHover = null);
              if (slice != null) _runSlice(slice);
            },
            child: MouseRegion(
              onHover: (e) => track(e.localPosition),
              onExit: (_) => setState(() => _radialHover = null),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Center(
                      child: SizedBox(
                        width: radialDeadZone * 2,
                        child: Text(
                          widget.model.radialTitle,
                          textAlign: TextAlign.center,
                          style: t.small.copyWith(color: t.textMuted),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ),
                  for (var i = 0; i < radial.length; i++)
                    _slice(t, i, radial[i], centre),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _slice(LumitTheme t, int index, RadialEntry entry, Offset centre) {
    final at = radialSliceOffset(index, widget.model.radial.length);
    final chosen = _radialHover == index && entry.enabled;
    const width = 108.0;
    const height = 26.0;
    return Positioned(
      left: centre.dx + at.dx - width / 2,
      top: centre.dy + at.dy - height / 2,
      width: width,
      height: height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: entry.enabled ? () => _runSlice(index) : null,
        child: Container(
          key: ValueKey<String>('fx-radial-${entry.label}'),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: chosen ? t.accent : t.surface4,
            borderRadius: BorderRadius.circular(t.tokens.controlRadius),
            border: Border.all(
                color: chosen ? t.accent : t.hairline, width: 1),
          ),
          child: Text(
            entry.label,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: t.small.copyWith(
              color: !entry.enabled
                  ? t.textDisabled
                  : chosen
                      ? t.surface0
                      : t.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}
