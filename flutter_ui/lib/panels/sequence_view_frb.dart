// The sequence view: a Sequence layer's row, grown tall (K-248).
//
// Double-click a Sequence layer — its name in the outline, or its bar in the
// lanes — and the row opens *in place* rather than swapping the Timeline for
// another tab. Cutting is the reason: you cut against the beat you can see, so
// the music, the other layers and the ruler all have to stay on screen while
// you do it. K-071 originally put this in a tab of its own; K-248 supersedes
// that clause.
//
// What opens is two strips under the layer's own bar:
//
//   * **the clips**, each drawn where it sits on the row, with its playback
//     speed on it. The razor and `Ctrl+Shift+D` cut here exactly as they cut
//     the bar above, because they are the same commands on the same layer.
//   * **the speed envelope** (K-247), a point per clip whose height is its
//     speed. Dragging one re-speeds that clip and nothing else: its place on
//     the row is fixed, so an edit point already on a beat stays on it. The
//     line is flat because a clip's speed is one number here — a *ramped* clip
//     shows its two ends, and shaping the ramp further is the graph editor's
//     job, which is where the full envelope lives.
//
// Zero bridge calls to draw: every clip rides in on the comp read model
// (K-184). The bridge is crossed only when a gesture commits.

import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';

import '../theme/theme.dart';
import '../widgets/controls.dart';
import 'timeline_extras_frb.dart';

/// How tall the clip strip and the envelope strip are.
const double sequenceClipStrip = 34;
const double sequenceEnvelopeStrip = 46;

/// The height a Sequence layer's row gains while its view is open.
const double sequenceViewHeight = sequenceClipStrip + sequenceEnvelopeStrip;

/// The envelope's vertical range, in per cent — the same framing the graph
/// editor's Vegas lens opens at (K-247), so the two read alike.
const double _envelopeTop = 100;
const double _envelopeBottom = -25;

/// A Sequence layer's clips and their speed envelope, under its bar.
class SequenceViewFrb extends StatelessWidget {
  final BridgeLayerEntry entry;
  final TimelineAxis axis;

  /// Committed a gesture; the panel refreshes its read model.
  final VoidCallback onChanged;

  const SequenceViewFrb({
    super.key,
    required this.entry,
    required this.axis,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final clips = entry.info.clips;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: sequenceClipStrip,
          child: Stack(children: [for (final c in clips) _clip(t, c)]),
        ),
        SizedBox(
          height: sequenceEnvelopeStrip,
          child: Stack(
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _EnvelopePainter(
                      clips: clips,
                      axis: axis,
                      line: t.hairline,
                      curve: t.curve.first,
                      label: t.small.copyWith(color: t.textMuted),
                    ),
                  ),
                ),
              ),
              for (final c in clips) _envelopePoint(t, c),
            ],
          ),
        ),
      ],
    );
  }

  /// One clip: a box where it sits, saying how fast it plays.
  Widget _clip(LumitTheme t, BridgeClip clip) {
    final left = axis.xOf(clip.startFrame.toInt());
    final width = axis.xOf(clip.endFrame.toInt()) - left;
    final speed = clip.speedPercent;
    return Positioned(
      key: ValueKey<String>('seq-clip-${clip.id}'),
      left: left,
      width: width,
      top: 2,
      bottom: 2,
      child: Container(
        decoration: BoxDecoration(
          color: t.labelColour(entry.info.label),
          border: Border.all(color: t.surface0, width: 1),
          borderRadius: BorderRadius.circular(2),
        ),
        alignment: Alignment.center,
        child: ClipRect(
          child: Text(
            // A ramp has no single number to show, and saying one would be a
            // lie about a curve — the envelope below is what reads it.
            speed == null ? 'ramp' : '${speed.round()}%',
            style: t.small.copyWith(color: t.textPrimary),
            overflow: TextOverflow.clip,
            softWrap: false,
          ),
        ),
      ),
    );
  }

  /// The envelope's grab handle for one clip: drag it up to speed the clip up,
  /// down towards zero to slow it, below zero to run it backwards.
  Widget _envelopePoint(LumitTheme t, BridgeClip clip) {
    final left = axis.xOf(clip.startFrame.toInt());
    final width = axis.xOf(clip.endFrame.toInt()) - left;
    final speed = clip.speedPercent ?? 100;
    return Positioned(
      key: ValueKey<String>('seq-speed-${clip.id}'),
      left: left,
      width: width,
      top: 0,
      bottom: 0,
      child: _EnvelopeHandle(
        speed: speed,
        colour: t.curve.first,
        onSpeed: (next) {
          entry.layer.setClipSpeed(
            clip: clip.id,
            percent: next,
            endPercent: next,
          );
          onChanged();
        },
      ),
    );
  }
}

/// The draggable band for one clip's speed. The whole clip's width is the grab
/// target, because a single dot over a two-second clip is a small thing to hit
/// and there is nothing else in the band to click.
class _EnvelopeHandle extends StatefulWidget {
  final double speed;
  final Color colour;
  final ValueChanged<double> onSpeed;

  const _EnvelopeHandle({
    required this.speed,
    required this.colour,
    required this.onSpeed,
  });

  @override
  State<_EnvelopeHandle> createState() => _EnvelopeHandleState();
}

class _EnvelopeHandleState extends State<_EnvelopeHandle> {
  /// The speed under the pointer while a drag runs, so the dot follows the
  /// hand and the engine is written to once, on release — one undo step.
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final shown = _dragging ?? widget.speed;
    return LayoutBuilder(
      builder: (context, box) {
        double speedAt(double dy) {
          final f = (dy / box.maxHeight).clamp(0.0, 1.0);
          return _envelopeTop - f * (_envelopeTop - _envelopeBottom);
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragUpdate: (d) =>
              setState(() => _dragging = speedAt(d.localPosition.dy)),
          onVerticalDragEnd: (_) {
            final next = _dragging;
            setState(() => _dragging = null);
            if (next != null) widget.onSpeed(next);
          },
          onVerticalDragCancel: () => setState(() => _dragging = null),
          child: CustomPaint(
            painter: _HandlePainter(speed: shown, colour: widget.colour),
          ),
        );
      },
    );
  }
}

double _envelopeY(double speed, double height) {
  final f = (_envelopeTop - speed) / (_envelopeTop - _envelopeBottom);
  return (f.clamp(0.0, 1.0)) * height;
}

class _HandlePainter extends CustomPainter {
  final double speed;
  final Color colour;
  const _HandlePainter({required this.speed, required this.colour});

  @override
  void paint(Canvas canvas, Size size) {
    final y = _envelopeY(speed, size.height);
    canvas.drawLine(
      Offset(0, y),
      Offset(size.width, y),
      Paint()
        ..color = colour
        ..strokeWidth = 2,
    );
    canvas.drawCircle(
        Offset(size.width / 2, y), 3.5, Paint()..color = colour);
  }

  @override
  bool shouldRepaint(_HandlePainter old) =>
      old.speed != speed || old.colour != colour;
}

/// The envelope's own furniture: the 100% line every clip is measured against,
/// and the zero line that says where backwards begins.
class _EnvelopePainter extends CustomPainter {
  final List<BridgeClip> clips;
  final TimelineAxis axis;
  final Color line;
  final Color curve;
  final TextStyle label;

  const _EnvelopePainter({
    required this.clips,
    required this.axis,
    required this.line,
    required this.curve,
    required this.label,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (final (speed, text) in [(100.0, '100%'), (0.0, '0')]) {
      final y = _envelopeY(speed, size.height);
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        Paint()
          ..color = line
          ..strokeWidth = 1,
      );
      final painter = TextPainter(
        text: TextSpan(text: text, style: label),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(canvas, Offset(2, y - painter.height));
    }
  }

  @override
  bool shouldRepaint(_EnvelopePainter old) =>
      old.clips != clips || old.line != line;
}
