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
  Duration? previous;
  List<Duration> timings = [];

  double fps = 0.0;
  double frameTime = 0.0;
  double average = 0.0;
  double averageFrameTime = 0;

  @override
  void initState() {
    SchedulerBinding.instance.addPostFrameCallback(update);
    super.initState();
  }

  void update(Duration duration) {
    if (previous != null) {
      final frameDuration = duration - previous!;
      timings.add(frameDuration);

      final currentFps = frameDuration.fps;

      const maxFrames = 60;
      if (timings.length > maxFrames) {
        timings = timings.sublist(timings.length - maxFrames);
      }

      final avg =
          timings.fold(0.0, (v, t) => v + t.fps) / timings.length.toDouble();
      final avgFrameTime =
          timings.fold(0.0, (v, t) => v + t.ms) / timings.length.toDouble();
      setState(() {
        fps = currentFps;
        frameTime = frameDuration.ms;
        average = avg;
        averageFrameTime = avgFrameTime;
      });
    }

    previous = duration;

    SchedulerBinding.instance.addPostFrameCallback(update);
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
                  style:
                      theme.mono.copyWith(color: msToColor(averageFrameTime)),
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
