// The Timeline's render-time column: what each layer's picture cost in the
// frame the playhead is on, and what each effect within it cost (docs/13 §7.1,
// docs/TODO.md "Layer and effect render-time indicator").
//
// **In plain terms.** "This comp is slow" is not something to guess about. With
// the column switched on, every layer row carries the milliseconds its own
// picture took in the last measured frame, and twirling a layer open puts the
// same number on each effect's heading — so the layer that is costing the
// session, and the effect inside it that is doing the costing, are both a
// glance away.
//
// **The switch is the point.** Measuring makes the engine wait for the graphics
// card at every layer and every effect, which is honest — a millisecond then
// means the work rather than the paperwork — and not free: that wait is the
// overlap a brisk preview lives on. So the column's header carries a stopwatch,
// nothing is measured until it is pressed, and playback is never measured
// whatever it says. Off, the column shows dimmed dashes — and a click on any of
// them starts measuring, so the column is its own switch and cannot read as a
// feature that does not work — and the engine does exactly what it did before
// this existed.

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../icons/icons.dart';
import '../main.dart';
import '../state/render_timings.dart';
import '../widgets/controls.dart';

/// The column header: the stopwatch that turns measuring on, and the word for
/// what the column is. Pressed, it is lit in the accent; unpressed it is as
/// quiet as any other header glyph.
class TimingsHeaderCell extends StatelessWidget {
  const TimingsHeaderCell({super.key});

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final timings =
        Provider.of<LumitUiState>(context, listen: false).renderTimings;
    return ListenableBuilder(
      listenable: timings,
      builder: (context, _) {
        final on = timings.measuring;
        return LumitTooltip(
          message: on
              ? 'Render time — measuring. Click to stop; measuring slows each '
                  'frame it measures'
              : 'Render time — click to measure what each layer and effect '
                  'costs (it slows the frames it measures)',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => timings.setMeasuring(!on),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                lumitIcon(
                  LumitIcon.stopwatch,
                  size: iconSize,
                  color: on ? t.accent : t.textMuted,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    'Time',
                    style: t.small,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// One measured cost, right-aligned so a column of them reads as numbers.
///
/// [layerId] and [effectId] are alternatives — a layer row gives the first, an
/// effect's heading the second.
///
/// **A dash, never a blank.** The first version drew nothing at all while the
/// column was idle, and the column was reported as broken within the day: a
/// header called Time over a row per layer and nothing in any of them looks
/// exactly like a feature that does not work, and the switch that would fill it
/// was a glyph in the header nobody had reason to press. So an idle cell shows
/// a dimmed dash and **a click on it starts measuring** — the column is its own
/// switch, wherever you reach for it. A dash at full strength means the
/// opposite: measuring is on and the last measured frame had no such row (it
/// was hidden, outside its span, or inside a Precomp).
class TimingsCell extends StatelessWidget {
  final String? layerId;
  final String? effectId;

  const TimingsCell({super.key, this.layerId, this.effectId});

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final timings =
        Provider.of<LumitUiState>(context, listen: false).renderTimings;
    return ListenableBuilder(
      listenable: timings,
      builder: (context, _) {
        final on = timings.measuring;
        final id = layerId ?? effectId;
        final ms = !on || id == null
            ? null
            : layerId != null
                ? timings.layerMs(id)
                : timings.effectMs(id);
        final cell = Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Text(
              ms == null ? '—' : formatRenderMs(ms),
              style: on ? t.small : t.small.copyWith(color: t.textDisabled),
              maxLines: 1,
              overflow: TextOverflow.clip,
            ),
          ),
        );
        if (on) return cell;
        return LumitTooltip(
          message: 'Render time — click to measure what this costs '
              '(it slows the frames it measures)',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => timings.setMeasuring(true),
            child: cell,
          ),
        );
      },
    );
  }
}
