// The dropper's magnifier: the viewfinder that follows the pointer over the
// Viewer while a pick is armed.
//
// **In plain terms.** It is a little window showing the nine-by-nine block of
// pixels under the pointer, each one blown up to a square you can actually aim
// at, with dashed lines between them so you can tell one pixel from the next.
// A solid border rings the pixels that will actually be taken — just the middle
// one to start with, and Shift+scroll grows it to 3×3, 5×5, 7×7, 9×9 so a noisy
// patch averages out instead of grabbing one grainy pixel. Under the grid sits
// a strip saying what would be picked: the colour and its numbers for a colour
// pick, or — when the dropper is being used to read something else, like a
// depth-of-field focal point — the layer those numbers are coming from and the
// value read off it.
//
// Every colour and corner here comes from the theme; the only colours not from
// it are the sampled pixels themselves, which are the document's (K-004,
// docs/15 §11).

import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/src/rust/api/state.dart';

import '../state/dropper.dart';
import '../theme/theme.dart';
import 'controls.dart';

/// One magnified pixel's side, and the padding round the grid.
const double _cell = 13;
const double _pad = 6;
const double _barHeight = 20;

/// The hairline round the whole viewfinder. Counted in the size below because
/// a border is laid out *inside* the box: leaving it out is two pixels the
/// content does not have, which the grid then overflows by.
const double _border = 1;

/// The whole viewfinder's size — fixed, so the panel that positions it can keep
/// it inside the picture without measuring.
const Size dropperViewfinderSize = Size(
  _cell * dropperGrid + (_pad + _border) * 2,
  _cell * dropperGrid + (_pad + _border) * 2 + _barHeight + _pad,
);

/// Where the viewfinder goes for a pointer at [cursor], kept inside [bounds].
///
/// Below and right of the pointer, like the egui build, so the hand does not
/// cover what is being read — but pulled back on screen at the edges, where
/// "below and right" would put it off the picture entirely.
Offset dropperViewfinderOrigin(Offset cursor, Rect bounds) {
  final wanted = cursor + const Offset(18, 18);
  final maxX = (bounds.right - dropperViewfinderSize.width).clamp(
    bounds.left,
    double.infinity,
  );
  final maxY = (bounds.bottom - dropperViewfinderSize.height).clamp(
    bounds.top,
    double.infinity,
  );
  return Offset(
    wanted.dx.clamp(bounds.left, maxX),
    wanted.dy.clamp(bounds.top, maxY),
  );
}

/// The viewfinder itself: the grid, the region border, and the info strip.
class DropperViewfinder extends StatelessWidget {
  /// What is armed — which decides what the strip below the grid says.
  final DropperArm arm;

  /// The window last read back, or null while the first read is in flight. The
  /// magnifier's nine-by-nine is cut out of it here, around [centre], so moving
  /// the pointer inside the window costs nothing at all.
  final BridgeSampledPixels? window;

  /// The pixel under the pointer, in the picture's own grid.
  final (int, int) centre;

  /// How many pixels a side are being averaged.
  final int region;

  const DropperViewfinder({
    super.key,
    required this.arm,
    required this.window,
    required this.centre,
    required this.region,
  });

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final grid = _cell * dropperGrid;
    return Container(
      width: dropperViewfinderSize.width,
      height: dropperViewfinderSize.height,
      decoration: BoxDecoration(
        color: t.surface3,
        borderRadius: BorderRadius.circular(t.tokens.cardRadius),
        border: Border.all(color: t.hairlineStrong, width: _border),
        boxShadow: t.tokens.cardShadow,
      ),
      padding: const EdgeInsets.all(_pad),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The pixels sit behind the panel's own rounded edge rather than
          // spilling over it, so the corner reads as one shape.
          ClipRRect(
            borderRadius: BorderRadius.circular(
              (t.tokens.cardRadius - _pad).clamp(0.0, _cell),
            ),
            child: SizedBox(
              width: grid,
              height: grid,
              child: CustomPaint(
                painter: _GridPainter(
                  window: window,
                  centre: centre,
                  region: region,
                  hairline: t.hairline,
                  accent: t.accent,
                  empty: t.surface2,
                  regionRadius: t.tokens.controlRadius,
                ),
              ),
            ),
          ),
          const SizedBox(height: _pad),
          SizedBox(height: _barHeight, child: _infoBar(t)),
        ],
      ),
    );
  }

  /// What is about to be picked, said in the terms of whatever armed the
  /// dropper. A colour pick shows the colour and its numbers; a pick that is
  /// reading something else names the layer it is reading and the value it
  /// found there, because a swatch of the composite would be a colour nobody is
  /// choosing (docs/07 §6.1).
  Widget _infoBar(LumitTheme t) {
    final held = window;
    // Only read when the window actually holds every pixel the region needs.
    // A window the pointer has outrun — a frame just changed, a fast sweep —
    // would otherwise average whatever cells happened to be inside it and show
    // that as the value about to be picked, which is worse than saying nothing.
    final covered =
        held != null && windowCovers(held, centre.$1, centre.$2);
    final sample = covered
        ? sampleFromWindow(held, region, centre.$1, centre.$2)
        : null;
    final round = t.shape == ThemeShape.round;
    return Container(
      decoration: BoxDecoration(
        color: t.surface2,
        borderRadius:
            BorderRadius.circular(round ? _barHeight / 2 : t.tokens.controlRadius),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          if (arm.reads == DropperReads.colour && sample != null) ...[
            _swatch(t, documentColour(srgbEncode(sample.r), srgbEncode(sample.g),
                srgbEncode(sample.b), 0xff)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '${srgbEncode(sample.r)} ${srgbEncode(sample.g)} '
                '${srgbEncode(sample.b)}',
                style: t.mono.copyWith(color: t.textSecondary),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ] else if (sample != null) ...[
            Expanded(
              child: Text(
                _readingLabel(sample, held!),
                style: t.small.copyWith(color: t.textSecondary),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ] else
            Expanded(
              child: Text(
                'Reading…',
                style: t.small.copyWith(color: t.textMuted),
              ),
            ),
          const SizedBox(width: 6),
          Text('$region×$region', style: t.small.copyWith(color: t.textMuted)),
        ],
      ),
    );
  }

  /// The line a non-colour pick shows: where the number came from, and what it
  /// is. Named rather than swatched, so "why is that grey?" never arises.
  ///
  /// The source is taken from the *patch* rather than from what was asked for:
  /// the reply says whether it is of one layer alone or of the composite, and a
  /// caption that named a layer the pixels did not come from would be worse
  /// than no caption at all.
  String _readingLabel(DropperSample sample, BridgeSampledPixels window) {
    final from = window.layerAlone
        ? (arm.sampleLayerName ?? 'That layer')
        : 'Composite';
    return switch (arm.reads) {
      DropperReads.depth => '$from · ${sample.depth.toStringAsFixed(3)}',
      DropperReads.position => '${sample.x}, ${sample.y}',
      DropperReads.colour => '',
    };
  }

  Widget _swatch(LumitTheme t, Color colour) => Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          color: colour,
          borderRadius: BorderRadius.circular(t.tokens.controlRadius),
          border: Border.all(color: t.hairlineStrong),
        ),
      );
}

/// The nine-by-nine block, its dashed rules, and the border round the region
/// that will be averaged.
class _GridPainter extends CustomPainter {
  final BridgeSampledPixels? window;

  /// The pixel under the pointer: the grid's centre cell, and what the window
  /// is indexed around.
  final (int, int) centre;
  final int region;
  final Color hairline;
  final Color accent;
  final Color empty;
  final double regionRadius;

  const _GridPainter({
    required this.window,
    required this.centre,
    required this.region,
    required this.hairline,
    required this.accent,
    required this.empty,
    required this.regionRadius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.width / dropperGrid;
    final held = window;

    // The pixels. Before the first read lands there is nothing to show, so the
    // grid draws as an empty surface rather than as black — which would look
    // like a picture of black pixels.
    for (var y = 0; y < dropperGrid; y++) {
      for (var x = 0; x < dropperGrid; x++) {
        final rect = Rect.fromLTWH(x * cell, y * cell, cell, cell);
        canvas.drawRect(rect, Paint()..color = _pixel(held, x, y) ?? empty);
      }
    }

    // Dashed rules between every pair of pixels, so the grid reads as pixels
    // rather than as a blurry picture.
    final dash = Paint()
      ..color = hairline
      ..strokeWidth = 1;
    for (var k = 1; k < dropperGrid; k++) {
      _dashed(canvas, Offset(k * cell, 0), Offset(k * cell, size.height), dash);
      _dashed(canvas, Offset(0, k * cell), Offset(size.width, k * cell), dash);
    }

    // The region that will be averaged: solid, so it is unmistakably not one of
    // the dashed rules. Its corners take the theme's control radius, so it is
    // rounded under the round shape and square under the sharp one.
    final n = region.clamp(1, dropperGrid);
    final from = (dropperGrid - n) / 2 * cell;
    final box = Rect.fromLTWH(from, from, n * cell, n * cell).deflate(0.8);
    canvas.drawRRect(
      RRect.fromRectAndRadius(box, Radius.circular(regionRadius)),
      Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );
  }

  /// The grid cell at `(x, y)` — cut out of the window around the pointer, so
  /// the centre cell is always the pixel being aimed at. Null when there is no
  /// window to read yet.
  Color? _pixel(BridgeSampledPixels? window, int x, int y) {
    if (window == null) return null;
    final reach = dropperGrid ~/ 2;
    final px = windowPixel(window, centre.$1 + x - reach, centre.$2 + y - reach);
    if (px == null) return null;
    return documentColour(px.r, px.g, px.b, 0xff);
  }

  /// A dashed line, drawn as evenly spaced dots — the same mark the egui
  /// magnifier used, and cheap enough to run per rule per frame.
  void _dashed(Canvas canvas, Offset a, Offset b, Paint paint) {
    const step = 3.0;
    final span = b - a;
    final length = span.distance;
    if (length < 0.5) return;
    final dir = span / length;
    for (var t = 0.0; t <= length; t += step) {
      canvas.drawCircle(a + dir * t, 0.6, paint);
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) =>
      old.window != window ||
      old.centre != centre ||
      old.region != region ||
      old.accent != accent ||
      old.hairline != hairline;
}
