// The Settings window, on the flutter_rust_bridge API.
//
// Four groups: appearance (scheme, shape, accent), the rendered-frame cache
// (its live numbers, a budget and a Clear), playback (the measured quality tier
// and a Reset), and what this build of the engine is (the boot log).
//
// Appearance is Dart's own — the theme lives here and the engine has no opinion
// about it. Everything else is a readout of the engine with at most a button:
// the cache budget is the one number here that changes engine behaviour, and
// even that is not part of the document, so none of this is undoable.

import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/src/rust/api/cache.dart';
import 'package:lumit_flutter/src/rust/api/shell.dart';
import 'package:provider/provider.dart';

import '../theme/theme.dart';
import '../widgets/controls.dart';

/// The budgets the picker offers, in MiB. A cache smaller than this is not worth
/// keeping and a larger one is a decision for a machine, not a default.
const List<int> _budgets = [128, 256, 512, 1024, 2048, 4096];

Future<void> showSettingsWindowFrb(BuildContext context) =>
    showLumitModal<void>(
      context: context,
      builder: (close) => _SettingsWindow(onClose: () => close(null)),
    );

class _SettingsWindow extends StatefulWidget {
  final VoidCallback onClose;
  const _SettingsWindow({required this.onClose});

  @override
  State<_SettingsWindow> createState() => _SettingsWindowState();
}

class _SettingsWindowState extends State<_SettingsWindow> {
  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final ui = Provider.of<LumitUiState>(context);
    final stats = cacheStats();
    final vram = vramCacheStats();
    final tier = playbackTier();

    return FloatSurface(
      width: 460,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(10),
            child: Text('Settings', style: t.bodyPrimary),
          ),
          _group(t, 'Appearance', [
            _row(
              t,
              'Colour scheme',
              SizedBox(
                width: 110,
                child: BareDropdown<LumitColorScheme>(
                  key: const ValueKey('settings-scheme'),
                  value: ui.scheme,
                  options: LumitColorScheme.values,
                  // The enum names them; a label written here would be a
                  // second list to keep in step for no gain.
                  label: (s) => s.label,
                  onChanged: (s) => setState(() => ui.setScheme(s)),
                ),
              ),
            ),
            _row(
              t,
              'Corners',
              SizedBox(
                width: 110,
                child: BareDropdown<ThemeShape>(
                  key: const ValueKey('settings-shape'),
                  value: ui.shape,
                  options: ThemeShape.values,
                  label: (s) => s == ThemeShape.sharp ? 'Sharp' : 'Round',
                  onChanged: (s) => setState(() => ui.setShape(s)),
                ),
              ),
            ),
          ]),
          _group(t, 'Rendered-frame cache', [
            _row(
              t,
              'Budget',
              SizedBox(
                width: 110,
                child: BareDropdown<int>(
                  key: const ValueKey('settings-cache-budget'),
                  value: _nearestBudget(stats.budgetBytes.toInt()),
                  options: _budgets,
                  label: (mib) => '$mib MB',
                  onChanged: (mib) => setState(
                      () => setCacheBudget(bytes: BigInt.from(mib) << 20)),
                ),
              ),
            ),
            _row(
              t,
              'In use',
              Text(
                '${_mib(stats.usedBytes.toInt())} MB in '
                '${stats.entries} frame${stats.entries == BigInt.one ? '' : 's'}',
                key: const ValueKey('settings-cache-used'),
                style: t.small,
              ),
            ),
            _row(
              t,
              'Served from cache',
              Text('${stats.hits} of ${stats.hits + stats.misses}',
                  style: t.small),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: HouseButton(
                  key: const ValueKey('settings-cache-clear'),
                  small: true,
                  onPressed: () => setState(clearCache),
                  child: Text('Clear cache', style: t.small),
                ),
              ),
            ),
          ]),
          _group(t, 'Preview cache on the graphics card', [
            _row(
              t,
              'Budget',
              SizedBox(
                width: 110,
                child: BareDropdown<int>(
                  key: const ValueKey('settings-vram-budget'),
                  value: _nearestBudget(vram.budgetBytes.toInt()),
                  options: _budgets,
                  label: (mib) => '$mib MB',
                  onChanged: (mib) => setState(
                      () => setVramCacheBudget(bytes: BigInt.from(mib) << 20)),
                ),
              ),
            ),
            _row(
              t,
              'In use',
              Text(
                '${_mib(vram.usedBytes.toInt())} MB in '
                '${vram.entries} frame${vram.entries == BigInt.one ? '' : 's'}',
                key: const ValueKey('settings-vram-used'),
                style: t.small,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: HouseButton(
                  key: const ValueKey('settings-vram-clear'),
                  small: true,
                  onPressed: () => setState(clearVramCache),
                  child: Text('Clear cache', style: t.small),
                ),
              ),
            ),
          ]),
          _group(t, 'Playback', [
            _row(
              t,
              'Quality tier',
              Text(_tierLabel(tier.tier),
                  key: const ValueKey('settings-tier'), style: t.small),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: LumitTooltip(
                  message:
                      'Start the quality controller again, optimistic at full',
                  child: HouseButton(
                    key: const ValueKey('settings-tier-reset'),
                    small: true,
                    onPressed: () => setState(resetRealtime),
                    child: Text('Reset', style: t.small),
                  ),
                ),
              ),
            ),
            _row(
              t,
              'Frame transport',
              Text(
                // The shared texture is the only frame transport (K-183); this
                // row reports which zero-copy path the build carries.
                switch (viewerTransport()) {
                  BridgeViewerTransport.sharedTexture =>
                    'Shared texture (no copy)',
                  BridgeViewerTransport.dmaBuf => 'DMA-BUF (no copy)',
                  BridgeViewerTransport.readBack =>
                    'None — this build has no zero-copy path',
                },
                key: const ValueKey('settings-transport'),
                style: t.small,
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ]),
          _group(t, 'This build', [
            for (final line in bootLog())
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
                child: Text(line,
                    style: t.small.copyWith(color: t.textMuted)),
              ),
          ]),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                HouseButton(
                  key: const ValueKey('settings-close'),
                  small: true,
                  onPressed: widget.onClose,
                  child: const Text('Close'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _group(LumitTheme t, String title, List<Widget> rows) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: t.surface1,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            child: Text(title, style: t.small.copyWith(color: t.textMuted)),
          ),
          ...rows,
          const SizedBox(height: 4),
        ],
      );

  Widget _row(LumitTheme t, String label, Widget control) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        child: Row(
          children: [
            Expanded(child: Text(label, style: t.body)),
            // Flexible, not bare: a long value — a transport name, a path —
            // otherwise runs past the edge of the window and paints the
            // overflow stripe over it.
            Flexible(child: control),
          ],
        ),
      );

  /// The offered budget nearest what the engine actually holds — the dropdown
  /// has to show one of its own options, and the engine's default need not be
  /// one of them.
  static int _nearestBudget(int bytes) {
    final mib = bytes >> 20;
    var best = _budgets.first;
    for (final option in _budgets) {
      if ((option - mib).abs() < (best - mib).abs()) best = option;
    }
    return best;
  }

  static String _mib(int bytes) => (bytes / (1 << 20)).toStringAsFixed(0);

  static String _tierLabel(int tier) => switch (tier) {
        1 => 'Full',
        2 => 'Half',
        3 => 'Third',
        _ => 'Quarter',
      };
}
