// The shell's bottom status line: what the engine is doing right now.
//
// One quiet strip under the dock (docs/07-UI-SPEC.md §1), left to right:
// whether the document is saved, the cache meter (how full the rendered-frame
// store is, with the exact megabytes), the latest notice with its close
// button, and the running export — its progress and a Cancel that works from
// anywhere, not only with the dialogue open. The engine's poll latches its
// state between calls, so this and the export dialogue can both ask without
// stealing each other's answer.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/src/rust/api/cache.dart';
import 'package:lumit_flutter/src/rust/api/export.dart';
import 'package:provider/provider.dart';

import '../theme/theme.dart';
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
    // Half a second is fast enough to feel live on a bar this small. Each tick
    // redraws the whole strip: the export poll, the dirty flag and the cache
    // numbers are all sync reads of a few held values, and the strip is 20
    // pixels of mostly text.
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
  }

  void _tick() {
    _export = (widget.poll ?? exportPoll)();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final state = Provider.of<LumitState>(context);
    return Container(
      height: 20,
      color: t.surface1,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        key: const ValueKey('status-line'),
        children: [
          _savedState(t, state),
          _divider(t),
          // Deliberately NOT const: a const child is skipped by the tick's
          // rebuild, which froze the meter at whatever it first read. Two
          // sync stat reads a second is the whole cost of keeping it live.
          // ignore: prefer_const_constructors
          CacheMeterFrb(),
          _divider(t),
          Expanded(
            child: Row(
              children: [
                Flexible(child: _notice(t, state)),
                const Spacer(),
                ..._exportSection(t),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider(LumitTheme t) => Container(
        width: 1,
        height: 12,
        margin: const EdgeInsets.symmetric(horizontal: 8),
        color: t.hairline,
      );

  /// Saved / unsaved, at the far left. Being unsaved is a fact, not a fault,
  /// so it reads in the ordinary text colour — the muted tint is for the
  /// states where nothing is at risk.
  Widget _savedState(LumitTheme t, LumitState state) {
    final project = state.project;
    final dirty = project?.isDirty() ?? false;
    final label = project == null
        ? 'No project'
        : dirty
            ? 'Unsaved changes'
            : project.path() == null
                ? 'Not saved yet'
                : 'Saved';
    return Text(
      label,
      key: const ValueKey('status-saved'),
      style: dirty ? t.small : t.small.copyWith(color: t.textMuted),
    );
  }

  /// The latest notice, with the close button every notice carries.
  Widget _notice(LumitTheme t, LumitState state) {
    return ValueListenableBuilder<LumitNotice?>(
      valueListenable: state.notice,
      builder: (context, notice, _) {
        if (notice == null) return const SizedBox.shrink();
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                notice.message,
                key: const ValueKey('status-notice'),
                style:
                    notice.error ? t.small.copyWith(color: t.warning) : t.small,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            HouseButton(
              key: const ValueKey('status-notice-close'),
              small: true,
              frameless: true,
              onPressed: () => state.notice.value = null,
              child: Text('×', style: t.small.copyWith(color: t.textMuted)),
            ),
          ],
        );
      },
    );
  }

  List<Widget> _exportSection(LumitTheme t) => switch (_export) {
        BridgeExportState_Idle() => const [],
        BridgeExportState_Running(:final frame, :final total, :final encoder) =>
          [
            Flexible(
              child: Text(
                'Exporting frame $frame of $total ($encoder)',
                key: const ValueKey('status-export-progress'),
                style: t.small,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
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
            Flexible(
              child: Text(
                'Exported to $path',
                key: const ValueKey('status-export-done'),
                style: t.small,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        BridgeExportState_Failed(:final error) => [
            Flexible(
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
      };
}

/// How full each tier of the frame cache is — one bar per tier, with the
/// megabytes beside it. Clicking a tier's bar empties that tier.
///
/// **Why one bar each.** The tiers hold different things and fill at different
/// rates: since the zero-copy transport (K-183) the RAM tier is only the scope
/// path's, so a Viewer that is busily banking frames on the card reported
/// "nothing held" here and looked broken. A merged number cannot answer "what is
/// cached" for either tier, so it does not try to.
///
/// Lives on the status line rather than under the Timeline: it measures the
/// whole store, not one comp's frames. Redrawn on the line's own half-second
/// tick rather than per paint — the lock `cacheStats` takes is the one a
/// render holds.
///
/// Named a *meter*, not a bar: the **cache bar** is the stripe under the time
/// ruler showing which frames are held (`TimelineCacheBar`, and the glossary's
/// own definition). This measures how full the store is, which is a different
/// question.
class CacheMeterFrb extends StatelessWidget {
  const CacheMeterFrb({super.key});

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final ram = cacheStats();
    final vram = vramCacheStats();
    final requests = ram.hits.toInt() + ram.misses.toInt();

    return Row(
      key: const ValueKey('cache-meter'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Cache', style: t.small.copyWith(color: t.textMuted)),
        const SizedBox(width: 6),
        _TierMeter(
          keyName: 'cache-meter-ram',
          label: 'RAM',
          used: ram.usedBytes.toInt(),
          budget: ram.budgetBytes.toInt(),
          tip: requests == 0
              ? 'Frames held in memory, of ${_mibText(ram.budgetBytes.toInt())} '
                  'MB — nothing rendered yet. Click to clear'
              : '${ram.hits} served from memory, ${ram.misses} rendered, of '
                  '${_mibText(ram.budgetBytes.toInt())} MB — click to clear',
          onClear: clearCache,
        ),
        const SizedBox(width: 10),
        _TierMeter(
          keyName: 'cache-meter-vram',
          label: 'VRAM',
          used: vram.usedBytes.toInt(),
          budget: vram.budgetBytes.toInt(),
          tip: 'Frames held on the graphics card, ready to show without '
              'compositing, of ${_mibText(vram.budgetBytes.toInt())} MB '
              '— click to clear',
          onClear: clearVramCache,
        ),
      ],
    );
  }
}

/// One tier: its name, how full it is, and the megabytes. Its own widget so a
/// third tier (disk, when that tier actually runs — docs/TODO.md) is one more
/// entry rather than a third copy of this layout.
class _TierMeter extends StatelessWidget {
  final String keyName;
  final String label;
  final int used;
  final int budget;
  final String tip;
  final VoidCallback onClear;

  const _TierMeter({
    required this.keyName,
    required this.label,
    required this.used,
    required this.budget,
    required this.tip,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final fraction = budget <= 0 ? 0.0 : (used / budget).clamp(0.0, 1.0);
    return LumitTooltip(
      message: tip,
      child: GestureDetector(
        key: ValueKey<String>(keyName),
        behavior: HitTestBehavior.opaque,
        onTap: onClear,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: t.small.copyWith(color: t.textMuted)),
            const SizedBox(width: 4),
            SizedBox(
              width: 40,
              child: Stack(children: [
                Container(height: 4, color: t.surface3),
                FractionallySizedBox(
                  widthFactor: fraction,
                  child: Container(height: 4, color: t.accent),
                ),
              ]),
            ),
            const SizedBox(width: 4),
            // Used only: the budget is in the tooltip and in Settings, and the
            // status line is one line shared with the notices and export.
            Text('${_mibText(used)} MB',
                style: t.small.copyWith(color: t.textMuted)),
          ],
        ),
      ),
    );
  }

}

/// Bytes as whole megabytes, for the meter's readouts and its tooltips.
String _mibText(int bytes) => (bytes / (1 << 20)).toStringAsFixed(0);
