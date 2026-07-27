// The shell's bottom status line: what the engine is doing right now.
//
// One quiet strip under the dock (docs/07-UI-SPEC.md §1) carrying the running
// export — its progress and a Cancel that works from anywhere, not only with
// the dialogue open — and the outcome of the last one. The engine's poll
// latches its state between calls, so this and the export dialogue can both
// ask without stealing each other's answer.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/src/rust/api/export.dart';

import '../widgets/controls.dart';

class StatusLineFrb extends StatefulWidget {
  /// The poll seam, injected by tests so no engine has to run an export.
  final BridgeExportState Function()? poll;

  const StatusLineFrb({super.key, this.poll});

  @override
  State<StatusLineFrb> createState() => _StatusLineFrbState();
}

class _StatusLineFrbState extends State<StatusLineFrb> {
  BridgeExportState _export = const BridgeExportState.idle();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // Half a second is fast enough to feel live on a bar this small, and the
    // poll is a sync read of a few held numbers.
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
  }

  void _tick() {
    final next = (widget.poll ?? exportPoll)();
    final bothIdle =
        next is BridgeExportState_Idle && _export is BridgeExportState_Idle;
    if (!bothIdle && mounted) setState(() => _export = next);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return Container(
      height: 20,
      color: t.surface1,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        key: const ValueKey('status-line'),
        children: switch (_export) {
          BridgeExportState_Idle() => const [],
          BridgeExportState_Running(
            :final frame,
            :final total,
            :final encoder
          ) =>
            [
              Expanded(
                child: Text(
                  'Exporting frame $frame of $total ($encoder)',
                  key: const ValueKey('status-export-progress'),
                  style: t.small,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              SizedBox(
                width: 120,
                child: Stack(children: [
                  Container(height: 4, color: t.surface3),
                  FractionallySizedBox(
                    widthFactor: total == BigInt.zero
                        ? 0.0
                        : (frame.toDouble() / total.toDouble()).clamp(0.0, 1.0),
                    child: Container(height: 4, color: t.accent),
                  ),
                ]),
              ),
              const SizedBox(width: 8),
              HouseButton(
                key: const ValueKey('status-export-cancel'),
                small: true,
                frameless: true,
                onPressed: exportCancel,
                child: Text('Cancel', style: t.small),
              ),
            ],
          BridgeExportState_Done(:final path) => [
              Expanded(
                child: Text(
                  'Exported to $path',
                  key: const ValueKey('status-export-done'),
                  style: t.small,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          BridgeExportState_Failed(:final error) => [
              Expanded(
                child: Text(
                  error == 'cancelled'
                      ? 'Export cancelled'
                      : 'Export failed: $error',
                  key: const ValueKey('status-export-failed'),
                  style: t.small.copyWith(color: t.warning),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
        },
      ),
    );
  }
}
