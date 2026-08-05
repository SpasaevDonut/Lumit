// The Viewer's preview progress bar (docs/07 §2.5).
//
// **In plain terms.** When a frame takes long enough to notice, this says so: a
// slim bar across the bottom of the picture that fills as the engine works
// through the frame, with a word for what it is doing. When the frame arrives
// the bar goes.
//
// **What it is not.** It is not a playback indicator — nothing appears while
// the transport is running (the engine sends no reports then), because a bar
// blinking at every frame of playback would be the busiest thing on screen and
// would say nothing anyone could act on. And it is not a spinner for every
// render: a frame that lands inside
// [PreviewProgressTracker.appearsAfter] shows nothing at all, so ordinary work
// stays silent and only a genuine wait speaks.
//
// **The motion.** The fill animates towards each report rather than jumping,
// so a bar that advances in five steps reads as one movement; and while it is
// waiting it carries a slow sheen, which is what distinguishes "working" from
// "stuck" at a glance. Both respect the theme's animation level (K-092) — at
// `none` the bar simply sits at its reported fraction.

import 'package:flutter/widgets.dart';

import '../state/preview_progress.dart';
import '../theme/theme.dart';
import '../widgets/controls.dart';

/// How tall the bar's own track is.
const double _trackHeight = 3;

/// How long the fill takes to catch up with a new report.
const Duration _fillDuration = Duration(milliseconds: 180);

/// One sweep of the sheen along the fill.
const Duration _sheenPeriod = Duration(milliseconds: 1400);

/// The transport's own height (`_Toolbar`), which the bar clears in round mode
/// where the transport floats over the picture rather than sitting below it.
const double _transportHeight = 26;

class ViewerProgressBar extends StatefulWidget {
  final PreviewProgressTracker tracker;

  const ViewerProgressBar({super.key, required this.tracker});

  @override
  State<ViewerProgressBar> createState() => _ViewerProgressBarState();
}

class _ViewerProgressBarState extends State<ViewerProgressBar>
    with SingleTickerProviderStateMixin {
  /// Built here rather than lazily: a `late final` controller that is never
  /// touched while the bar stays hidden would be *created* by its own
  /// `dispose`, which looks up the ticker mode on a widget already going away.
  late final AnimationController _sheen;

  @override
  void initState() {
    super.initState();
    _sheen = AnimationController(vsync: this, duration: _sheenPeriod);
    widget.tracker.addListener(_onProgress);
    if (widget.tracker.visible) _sheen.repeat();
  }

  @override
  void didUpdateWidget(ViewerProgressBar old) {
    super.didUpdateWidget(old);
    if (old.tracker != widget.tracker) {
      old.tracker.removeListener(_onProgress);
      widget.tracker.addListener(_onProgress);
    }
  }

  @override
  void dispose() {
    widget.tracker.removeListener(_onProgress);
    _sheen.dispose();
    super.dispose();
  }

  /// The sheen runs only while a bar is on screen: an animation ticking behind
  /// a widget that is not drawn is a frame's work per frame for nothing, and —
  /// as the frame-rate readout found the hard way — it also stops the interface
  /// ever settling, which hangs every widget test that waits for it to.
  void _onProgress() {
    if (!mounted) return;
    final visible = widget.tracker.visible;
    if (visible && !_sheen.isAnimating) {
      _sheen.repeat();
    } else if (!visible && _sheen.isAnimating) {
      _sheen.stop();
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scope = ThemeScope.of(context);
    final t = scope.theme;
    final tracker = widget.tracker;
    // Nothing to say: an empty box rather than a transparent bar, so the
    // Viewer's own hit testing is untouched while no frame is being waited on.
    if (!tracker.visible) return const SizedBox.shrink();
    final still = scope.animationLevel == AnimationLevel.none;

    // In round mode the transport floats over the bottom of the picture (its
    // 26 px plus the window inset), so the bar steps up over it rather than
    // hiding underneath; in sharp mode the transport is a strip below the
    // picture and there is nothing to clear.
    final floatingTransport = t.tokens.windowInset > 0;
    return IgnorePointer(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          t.tokens.windowInset + 8,
          6,
          t.tokens.windowInset + 8,
          floatingTransport ? t.tokens.windowInset * 2 + _transportHeight : 6,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(tracker.label, style: t.small),
                const Spacer(),
                Text(
                  '${(tracker.fraction * 100).round()}%',
                  style: t.small,
                ),
              ],
            ),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(t.tokens.controlRadius),
              child: SizedBox(
                height: _trackHeight,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: ColoredBox(color: t.surface2),
                    ),
                    Positioned.fill(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: _fill(t, still, tracker.fraction),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The filled part, with the sheen travelling along it.
  Widget _fill(LumitTheme t, bool still, double fraction) {
    final bar = LayoutBuilder(
      builder: (context, constraints) => AnimatedBuilder(
        animation: _sheen,
        builder: (context, _) {
          final width = constraints.maxWidth;
          return DecoratedBox(
            decoration: BoxDecoration(
              color: t.accent,
              gradient: still
                  ? null
                  : LinearGradient(
                      // The sheen is one brighter band sliding from the left
                      // edge of the fill to its right, and it is the whole of
                      // the "it is still working" signal.
                      begin: Alignment(-1 + 2 * _sheen.value, 0),
                      end: Alignment(-0.4 + 2 * _sheen.value, 0),
                      colors: [t.accent, t.accentHover, t.accent],
                      stops: const [0.0, 0.5, 1.0],
                    ),
            ),
            child: SizedBox(width: width, height: _trackHeight),
          );
        },
      ),
    );
    return still
        ? FractionallySizedBox(
            widthFactor: fraction.clamp(0.0, 1.0), child: bar)
        : TweenAnimationBuilder<double>(
            tween: Tween<double>(end: fraction.clamp(0.0, 1.0)),
            duration: _fillDuration,
            curve: Curves.easeOut,
            builder: (context, value, child) =>
                FractionallySizedBox(widthFactor: value, child: child),
            child: bar,
          );
  }
}
