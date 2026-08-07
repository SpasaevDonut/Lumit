// About Lumit — the window Help ▸ About Lumit opens (K-244).
//
// It used to be a section at the bottom of Settings ▸ General, which is where
// nobody looks for it: Settings is for things you change, and none of this is.
// The boot log is here rather than in the Debug panel because the first line of
// it *is* the version, and the rest is what someone pastes into a bug report.

import 'package:flutter/widgets.dart';

import 'package:lumit_flutter/src/rust/api/shell.dart';

import '../l10n/strings.dart';
import '../widgets/controls.dart';

Future<void> showAboutWindowFrb(BuildContext context) => showLumitModal<void>(
      context: context,
      builder: (close) => _AboutWindow(onClose: () => close(null)),
    );

/// This build of Lumit, as the engine reports it on boot. "Unknown" rather than
/// an empty line when the log is empty, which is what a test harness sees.
String lumitVersion() => bootLog().isEmpty ? 'unknown' : bootLog().first;

class _AboutWindow extends StatelessWidget {
  final VoidCallback onClose;
  const _AboutWindow({required this.onClose});

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return FloatSurface(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(l10n.menuAboutLumit, style: t.bodyPrimary),
          ),
          Text(lumitVersion(), style: t.small),
          const SizedBox(height: 8),
          Text(
            l10n.aboutBlurb,
            style: t.small,
          ),
          const SizedBox(height: 10),
          for (final line in bootLog().skip(1))
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(line, style: t.small),
            ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: HouseButton(
              key: const ValueKey('about-close'),
              small: true,
              onPressed: onClose,
              child: Text(l10n.close, style: t.small),
            ),
          ),
        ],
      ),
    );
  }
}
