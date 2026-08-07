// The windows an update puts up, and the order they come in (K-294).
//
// # In plain terms
//
// `state/updates.dart` knows how to find a newer Lumit and fetch it. This file
// is the part the user sees: the one question before a few hundred megabytes
// are downloaded, the progress while it comes, and the restart at the end —
// with the offer to save first, because the update cannot finish while Lumit is
// running and nobody should lose an evening's work to a version number.
//
// Nothing here decides anything about updating. It asks, it shows, and it calls
// back into the service, so the two can be read separately: what an update *is*
// over there, what it *looks like* here.

import 'package:flutter/widgets.dart';

import '../state/updates.dart';
import '../widgets/controls.dart';

/// Act on the Help ▸ Check for updates row, whatever it currently says.
///
/// One entry point for the menu row and the Settings button both, so the two
/// cannot come to mean different things. [saveProject] is passed in rather than
/// reached for: saving belongs to the shell's File menu, and a dialogue that
/// imported it would tie this file to the menu bar that calls it.
Future<void> pressUpdateRow(
  BuildContext context, {
  required UpdateService updates,
  required void Function(String message, {bool error}) notice,
  required bool Function() projectIsDirty,
  required Future<void> Function() saveProject,
}) async {
  // In flight: the row is disabled anyway, and a second press should not start
  // a second check.
  if (updates.busy) return;

  if (updates.stage == UpdateStage.available) {
    await _offerAndFetch(
      context,
      updates: updates,
      notice: notice,
      projectIsDirty: projectIsDirty,
      saveProject: saveProject,
    );
    return;
  }

  if (updates.stage == UpdateStage.ready) {
    await _askAboutRestart(
      context,
      updates: updates,
      projectIsDirty: projectIsDirty,
      saveProject: saveProject,
    );
    return;
  }

  // Idle, up to date, or a check that did not finish: all three are "ask
  // again", and what comes back is said in the status line as well as in the
  // row, because the row is a menu somebody has probably just closed.
  await updates.check();
  switch (updates.stage) {
    case UpdateStage.upToDate:
      notice('Lumit is up to date');
    case UpdateStage.failed:
      notice(updates.failure ?? 'Could not check for updates', error: true);
    case UpdateStage.available:
      notice('Lumit ${updates.release?.version} is available');
    default:
      break;
  }
}

/// Ask, download, then move on to the restart question.
Future<void> _offerAndFetch(
  BuildContext context, {
  required UpdateService updates,
  required void Function(String message, {bool error}) notice,
  required bool Function() projectIsDirty,
  required Future<void> Function() saveProject,
}) async {
  final release = updates.release;
  if (release == null) return;

  final go = await showLumitModal<bool>(
    context: context,
    builder: (close) => _OfferUpdate(release: release, onChoose: close),
  );
  if (go != true || !context.mounted) return;

  // Started first, shown second: the dialogue watches the service, and the
  // service is what is doing the work.
  final downloading = updates.downloadUpdate();
  // Dismissing this window (the scrim, or Cancel arriving late) does not stop
  // the download — the service owns that, and only the Cancel button asks it
  // to stop. So the flow waits for the download itself below, whichever way the
  // window went.
  await showLumitModal<void>(
    context: context,
    builder: (close) => _DownloadProgress(
      updates: updates,
      release: release,
      onDone: () => close(null),
      onCancel: updates.cancelDownload,
    ),
  );
  await downloading;

  if (updates.stage == UpdateStage.failed) {
    notice(updates.failure ?? 'Could not download the update', error: true);
    return;
  }
  if (updates.stage != UpdateStage.ready || !context.mounted) return;
  await _askAboutRestart(
    context,
    updates: updates,
    projectIsDirty: projectIsDirty,
    saveProject: saveProject,
  );
}

/// The last window: restart now, or later, and save first if there is work
/// open.
Future<void> _askAboutRestart(
  BuildContext context, {
  required UpdateService updates,
  required bool Function() projectIsDirty,
  required Future<void> Function() saveProject,
}) async {
  final answer = await showLumitModal<_RestartAnswer>(
    context: context,
    builder: (close) => _RestartToFinish(
      version: updates.release?.version ?? '',
      dirty: projectIsDirty(),
      quits: updates.installQuits,
      onChoose: close,
    ),
  );
  // Later keeps the downloaded installer and the row that offers it: the
  // update is still ready, and the next press of it comes straight back here.
  if (answer == null || answer == _RestartAnswer.later) return;
  if (answer == _RestartAnswer.saveAndRestart) await saveProject();
  await updates.install();
}

/// What the restart window can be answered with.
enum _RestartAnswer { restart, saveAndRestart, later }

/// "There is a newer Lumit — shall I fetch it?", with what that costs.
class _OfferUpdate extends StatelessWidget {
  final UpdateRelease release;
  final ValueChanged<bool?> onChoose;

  const _OfferUpdate({required this.release, required this.onChoose});

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return FloatSurface(
      width: 400,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(10),
            child: Text('Update to Lumit ${release.version}?',
                style: t.bodyPrimary),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              '${release.assetName} is ${release.sizeLabel}. Lumit downloads '
              'it now and installs it when you restart, so you can carry on '
              'working in the meantime.',
              style: t.small.copyWith(color: t.textMuted),
            ),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                HouseButton(
                  key: const ValueKey('update-offer-no'),
                  small: true,
                  frameless: true,
                  onPressed: () => onChoose(false),
                  child: Text('Not now', style: t.small),
                ),
                const SizedBox(width: 8),
                HouseButton(
                  key: const ValueKey('update-offer-yes'),
                  small: true,
                  onPressed: () => onChoose(true),
                  child: Text('Download', style: t.small),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

/// The download, while it happens. Closes itself the moment the service leaves
/// the downloading stage, however it left — finished, cancelled or failed.
class _DownloadProgress extends StatefulWidget {
  final UpdateService updates;
  final UpdateRelease release;
  final VoidCallback onDone;
  final VoidCallback onCancel;

  const _DownloadProgress({
    required this.updates,
    required this.release,
    required this.onDone,
    required this.onCancel,
  });

  @override
  State<_DownloadProgress> createState() => _DownloadProgressState();
}

class _DownloadProgressState extends State<_DownloadProgress> {
  @override
  void initState() {
    super.initState();
    widget.updates.addListener(_onChange);
    // A download can be over before this window is on screen — a small file, a
    // fast connection, a failure at the first byte. Without this the window
    // would sit there waiting for a notification that has already been sent.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.updates.stage != UpdateStage.downloading) {
        widget.onDone();
      }
    });
  }

  @override
  void dispose() {
    widget.updates.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    if (widget.updates.stage == UpdateStage.downloading) {
      setState(() {});
      return;
    }
    // Closing from inside a notification would be a window disposing itself
    // mid-build; the next frame is soon enough and always safe.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onDone();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final fraction = widget.updates.progress;
    final done = (widget.release.assetBytes * fraction / (1 << 20)).round();
    return FloatSurface(
      width: 400,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(10),
            child: Text('Downloading Lumit ${widget.release.version}',
                style: t.bodyPrimary),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // A plain bar in the theme's own colours: the shell has no
                // progress control of its own, and this is one rectangle.
                Container(
                  height: 6,
                  decoration: BoxDecoration(
                    color: t.surface3,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: fraction.clamp(0.0, 1.0).toDouble(),
                    child: Container(
                      decoration: BoxDecoration(
                        color: t.accent,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '$done MB of ${widget.release.sizeLabel}',
                  style: t.small.copyWith(color: t.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                HouseButton(
                  key: const ValueKey('update-download-cancel'),
                  small: true,
                  frameless: true,
                  onPressed: widget.onCancel,
                  child: Text('Cancel', style: t.small),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

/// The end of the update: it is on disk, and applying it means closing Lumit.
class _RestartToFinish extends StatelessWidget {
  final String version;

  /// Whether the open project has unsaved work, which is what puts the save
  /// button on this window rather than leaving the choice to be regretted.
  final bool dirty;

  /// Whether finishing means quitting at all — on Linux the download is only
  /// revealed, so this window says that instead.
  final bool quits;

  final ValueChanged<_RestartAnswer?> onChoose;

  const _RestartToFinish({
    required this.version,
    required this.dirty,
    required this.quits,
    required this.onChoose,
  });

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return FloatSurface(
      width: 460,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(10),
            child: Text(
              quits
                  ? 'Restart to finish updating'
                  : 'Lumit $version is downloaded',
              style: t.bodyPrimary,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              quits
                  ? 'Lumit $version is downloaded. It installs while Lumit is '
                      'closed, so the update finishes the next time you open '
                      'it.${dirty ? ' This project has unsaved changes.' : ''}'
                  : 'Open the downloaded file to install it. Lumit does not '
                      'unpack it for you, because where it goes is yours to '
                      'choose.',
              style: t.small.copyWith(color: t.textMuted),
            ),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            // A Wrap rather than a Row: with unsaved work there are three
            // buttons and one of them is a whole sentence, which overflowed the
            // window and pushed Save and restart off the right edge. Wrapping
            // holds however wide the UI scale makes these labels, rather than
            // depending on a width that happens to fit at 100%.
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                HouseButton(
                  key: const ValueKey('update-restart-later'),
                  small: true,
                  frameless: true,
                  onPressed: () => onChoose(_RestartAnswer.later),
                  child: Text('Later', style: t.small),
                ),
                if (quits && dirty) ...[
                  HouseButton(
                    key: const ValueKey('update-restart-now'),
                    small: true,
                    frameless: true,
                    onPressed: () => onChoose(_RestartAnswer.restart),
                    child: Text('Restart without saving', style: t.small),
                  ),
                  HouseButton(
                    key: const ValueKey('update-save-restart'),
                    small: true,
                    onPressed: () => onChoose(_RestartAnswer.saveAndRestart),
                    child: Text('Save and restart', style: t.small),
                  ),
                ] else
                  HouseButton(
                    key: const ValueKey('update-restart-now'),
                    small: true,
                    onPressed: () => onChoose(_RestartAnswer.restart),
                    child: Text(quits ? 'Restart now' : 'Show the file',
                        style: t.small),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}
