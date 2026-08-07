import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:lumit_flutter/widgets/controls.dart';

class PerformanceMonitor extends StatefulWidget {
  const PerformanceMonitor({super.key});

  @override
  State<PerformanceMonitor> createState() => _PerformanceMonitorState();
}

extension FPS on Duration {
  double get fps => inMicroseconds > 0 ? (1000000 / inMicroseconds) : 0;
  double get ms => inMicroseconds / 1000;
}

class _PerformanceMonitorState extends State<PerformanceMonitor> {
  List<Duration> timings = [];

  double fps = 0.0;
  double frameTime = 0.0;
  double average = 0.0;
  double averageFrameTime = 0;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    super.dispose();
  }

  /// Flutter hands over the timings of frames it has already drawn.
  ///
  /// This used to be a post-frame callback that re-registered itself, which
  /// had two problems. It never stopped — nothing cancelled it, so after the
  /// monitor closed it kept firing and calling setState on a dead State. And
  /// asking for a callback every frame *is* asking for a frame every frame, so
  /// the counter kept the app rendering flat out for as long as it was open
  /// and then reported the frame rate it had itself caused. A test never
  /// settled either, because the tree was never idle.
  ///
  /// `addTimingsCallback` is the measuring version of the same thing: it
  /// reports frames that happened rather than causing them, so an idle app
  /// reads as idle and the numbers describe the app instead of the monitor.
  void _onTimings(List<FrameTiming> reported) {
    if (!mounted || reported.isEmpty) return;

    // `totalSpan` is vsync to raster finish — the whole cost of the frame.
    timings.addAll(reported.map((t) => t.totalSpan));

    const maxFrames = 60;
    if (timings.length > maxFrames) {
      timings = timings.sublist(timings.length - maxFrames);
    }

    final latest = timings.last;
    setState(() {
      fps = latest.fps;
      frameTime = latest.ms;
      average =
          timings.fold(0.0, (v, t) => v + t.fps) / timings.length.toDouble();
      averageFrameTime =
          timings.fold(0.0, (v, t) => v + t.ms) / timings.length.toDouble();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = ThemeScope.of(context).theme;

    return Column(
      children: [
        Row(
          spacing: 10,
          children: [
            Row(
              children: [
                Text(
                  "FPS: ",
                  style: theme.mono,
                ),
                Text(
                  fps.toStringAsFixed(0),
                  style: theme.mono.copyWith(color: msToColor(frameTime)),
                ),
              ],
            ),
            Row(
              children: [
                Text(
                  "Avg: ",
                  style: theme.mono,
                ),
                Text(
                  average.toStringAsFixed(0),
                  style: theme.mono.copyWith(color: msToColor(averageFrameTime)),
                ),
              ],
            )
          ],
        ),
        SizedBox(
          height: 50,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: timings
                .map((i) => Container(
                    color: msToColor(i.ms),
                    child:
                        SizedBox(width: 3, height: (i.ms * 0.5).clamp(0, 50))))
                .toList(),
          ),
        )
      ],
    );
  }

  Color msToColor(double ms) {
    final theme = ThemeScope.of(context).theme;

    if (ms > 30) {
      return Colors.red;
    }

    if (ms > 17) {
      return Colors.amber;
    }

    return theme.textMuted;
  }
}
