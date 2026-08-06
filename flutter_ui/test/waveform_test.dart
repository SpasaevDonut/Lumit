// What a waveform lane asks for, and what it draws (K-280).
//
// No engine here: the request rule and the painter are both plain arithmetic
// over data the bridge hands over, and both are the parts that decide whether
// a zoomed-in wave gains detail or turns into a staircase.

import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumit_flutter/panels/waveform_frb.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';
import 'package:lumit_flutter/theme/theme.dart';

/// Peaks shaped as the bridge returns them: `bands × buckets` triples.
BridgeAudioPeaks peaks({
  required double start,
  required double end,
  required int bands,
  required List<double> values,
}) =>
    BridgeAudioPeaks(
      durationSeconds: 10,
      startSeconds: start,
      endSeconds: end,
      bands: bands,
      buckets: values.length ~/ (3 * bands),
      values: Float32List.fromList(values.map((v) => v.toDouble()).toList()),
    );

/// One full-scale bucket, repeated.
List<double> loud(int buckets) =>
    [for (var i = 0; i < buckets; i++) ...[-1.0, 1.0, 0.5]];

void main() {
  group('what a lane asks for', () {
    test('a zoomed-in view asks for a shorter window, not more buckets',
        (() {
      // The same 800-pixel lane, showing ten seconds and then one.
      final wide = WaveformRequest.forView(
          startSeconds: 0, endSeconds: 10, pixels: 800)!;
      final close = WaveformRequest.forView(
          startSeconds: 4, endSeconds: 5, pixels: 800)!;
      expect(close.endSeconds - close.startSeconds,
          lessThan(wide.endSeconds - wide.startSeconds));
      // Roughly a bucket per pixel either way — the detail comes from the
      // window shrinking, which is exactly what the old fixed-bucket lane
      // could not do (K-172, superseded).
      expect(wide.buckets, greaterThanOrEqualTo(800));
      expect(close.buckets, greaterThanOrEqualTo(800));
      // And the close view has far more buckets per second of audio.
      final wideDensity = wide.buckets / (wide.endSeconds - wide.startSeconds);
      final closeDensity =
          close.buckets / (close.endSeconds - close.startSeconds);
      expect(closeDensity, greaterThan(wideDensity * 5));
    }));

    test('a small scroll asks for nothing new', () {
      final a = WaveformRequest.forView(
          startSeconds: 4, endSeconds: 5, pixels: 800)!;
      // A few pixels' worth of scroll at this zoom.
      final b = WaveformRequest.forView(
          startSeconds: 4.004, endSeconds: 5.004, pixels: 800)!;
      expect(b, a, reason: 'rounded to the same window, so no fetch is sent');
      // A real move does change it.
      final c = WaveformRequest.forView(
          startSeconds: 6, endSeconds: 7, pixels: 800)!;
      expect(c, isNot(a));
    });

    test('the window is padded, so ordinary scrolling stays inside it', () {
      final r = WaveformRequest.forView(
          startSeconds: 4, endSeconds: 5, pixels: 800)!;
      expect(r.startSeconds, lessThan(4));
      expect(r.endSeconds, greaterThan(5));
    });

    test('a lane with no width or no time asks for nothing', () {
      expect(
          WaveformRequest.forView(
              startSeconds: 0, endSeconds: 1, pixels: 0),
          isNull);
      expect(
          WaveformRequest.forView(
              startSeconds: 1, endSeconds: 1, pixels: 800),
          isNull);
    });

    test('the bucket count never exceeds what the engine will give', () {
      final r = WaveformRequest.forView(
          startSeconds: 0, endSeconds: 1, pixels: 100000)!;
      expect(r.buckets, lessThanOrEqualTo(maxPeakBuckets));
    });
  });

  group('what a lane draws', () {
    /// A canvas that records the strokes rather than rasterising them: what a
    /// waveform *is* is a column of lines per bucket, so counting those says
    /// more than counting pixels, and it says it in milliseconds.
    const colours = WaveformColours(
      rest: Color(0xff5d8a96),
      low: Color(0xff4a7f9c),
      mid: Color(0xff6fa48c),
      high: Color(0xffaef3e7),
    );

    /// The envelope is drawn at reduced opacity over the same hue as its core,
    /// so a band is told by its colour, not by its alpha. Compared loosely:
    /// a `Paint` keeps its colour as 32-bit floats, so a channel comes back a
    /// few millionths from the double it went in as.
    bool sameHue(Color a, Color b) =>
        (a.r - b.r).abs() < 1e-4 &&
        (a.g - b.g).abs() < 1e-4 &&
        (a.b - b.b).abs() < 1e-4;

    List<_Stroke> strokes(WaveformPainter painter, Size size) {
      final canvas = _RecordingCanvas();
      painter.paint(canvas, size);
      return canvas.lines;
    }

    test('a single wave draws one lane, centred', () {
      final painter = WaveformPainter(
        peaks: peaks(start: 0, end: 1, bands: 1, values: loud(32)),
        originSeconds: 0,
        secondsPerPixel: 1 / 32,
        left: 0,
        right: 32,
        colours: colours,
      );
      final lines = strokes(painter, const Size(32, 32));
      expect(lines, isNotEmpty);
      expect(lines.every((l) => sameHue(l.colour, colours.rest)), isTrue,
          reason: 'the plain wave draws in the waveform colour, not the accent');
      // Every stroke straddles the middle of the one lane it has.
      for (final line in lines) {
        expect(line.a.dy, lessThanOrEqualTo(16));
        expect(line.b.dy, greaterThanOrEqualTo(16));
      }
    });

    /// The stack is drawn *through* the wave, not beside it: every band shares
    /// one lane and one centre line, so what you read is one silhouette with
    /// its inside showing rather than three small waveforms.
    test('a multiwave stack shares one lane and one centre line', () {
      final painter = WaveformPainter(
        peaks: peaks(
          start: 0,
          end: 1,
          bands: 3,
          values: [...loud(8), ...loud(8), ...loud(8)],
        ),
        originSeconds: 0,
        secondsPerPixel: 1 / 24,
        left: 0,
        right: 24,
        colours: colours,
      );
      final lines = strokes(painter, const Size(24, 30));
      expect(lines, isNotEmpty);
      for (final line in lines) {
        // Every stroke straddles the middle of the whole lane.
        expect(line.a.dy, lessThanOrEqualTo(15));
        expect(line.b.dy, greaterThanOrEqualTo(15));
      }
      // And all three bands are present, none of them boxed into a third.
      for (final c in [colours.low, colours.mid, colours.high]) {
        expect(lines.where((l) => sameHue(l.colour, c)), isNotEmpty);
      }
    });

    /// Back to front: bass first, treble last, so the transients land *on top*
    /// of the body rather than under it.
    test('the treble is drawn over the bass, not beneath it', () {
      final painter = WaveformPainter(
        peaks: peaks(
          start: 0,
          end: 1,
          bands: 3,
          values: [...loud(4), ...loud(4), ...loud(4)],
        ),
        originSeconds: 0,
        secondsPerPixel: 1 / 12,
        left: 0,
        right: 12,
        colours: colours,
      );
      final lines = strokes(painter, const Size(12, 30));
      int firstOf(Color c) => lines.indexWhere((l) => sameHue(l.colour, c));
      expect(firstOf(colours.low), lessThan(firstOf(colours.mid)));
      expect(firstOf(colours.mid), lessThan(firstOf(colours.high)));
    });

    /// A band in the stack is drawn solid; three softened envelopes over one
    /// another would blend into a wash and lose the ranking entirely.
    test('a stacked band is opaque where the single wave is softened', () {
      List<_Stroke> drawn(int bands) => strokes(
            WaveformPainter(
              peaks: peaks(
                start: 0,
                end: 1,
                bands: bands,
                values: [for (var i = 0; i < bands; i++) ...loud(8)],
              ),
              originSeconds: 0,
              secondsPerPixel: 1 / 24,
              left: 0,
              right: 24,
              colours: colours,
            ),
            const Size(24, 30),
          );

      expect(drawn(3).every((l) => l.colour.a > 0.99), isTrue);
      // The single wave keeps its softened envelope, drawn under a solid core.
      final single = drawn(1);
      expect(single.any((l) => l.colour.a < 0.9), isTrue,
          reason: 'the envelope is still softened');
      expect(single.any((l) => l.colour.a > 0.99), isTrue,
          reason: 'and the rms core is still solid over it');
    });

    test('a wave stops where its bar does', () {
      final painter = WaveformPainter(
        peaks: peaks(start: 0, end: 1, bands: 1, values: loud(32)),
        originSeconds: 0,
        secondsPerPixel: 1 / 32,
        // The bar covers only the right half of the canvas.
        left: 16,
        right: 32,
        colours: colours,
      );
      for (final line in strokes(painter, const Size(32, 16))) {
        expect(line.a.dx, greaterThanOrEqualTo(16));
      }
    });

    test('a bucket outside the fetched window is left blank', () {
      // The window covers the first second; the bar runs into the second one,
      // which has not been summarised — and draws nothing there rather than
      // repeating the last bucket to the end.
      final painter = WaveformPainter(
        peaks: peaks(start: 0, end: 1, bands: 1, values: loud(16)),
        originSeconds: 0,
        secondsPerPixel: 1 / 16,
        left: 0,
        right: 32,
        colours: colours,
      );
      for (final line in strokes(painter, const Size(32, 16))) {
        expect(line.a.dx, lessThan(16));
      }
    });

    test('no peaks, or empty peaks, draw nothing at all', () {
      for (final held in [
        null,
        peaks(start: 0, end: 1, bands: 1, values: const []),
      ]) {
        final painter = WaveformPainter(
          peaks: held,
          originSeconds: 0,
          secondsPerPixel: 1 / 32,
          left: 0,
          right: 32,
          colours: colours,
        );
        expect(strokes(painter, const Size(32, 16)), isEmpty);
      }
    });
  });
}

/// One recorded stroke.
class _Stroke {
  final Offset a;
  final Offset b;
  final Color colour;
  const _Stroke(this.a, this.b, this.colour);
}

/// A [Canvas] that keeps the lines instead of drawing them.
class _RecordingCanvas implements Canvas {
  final List<_Stroke> lines = [];

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) =>
      lines.add(_Stroke(p1, p2, paint.color));

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
