// The first-run screen: one question, asked once (K-246, docs/07 §13.1).
//
// On the very first launch — a machine with no settings file — Lumit asks how
// the user edits, and sets the two preferences of K-246 from the answer. That
// is the whole screen: a preference primer, not a tour, and not a wizard. Every
// setting it writes is an ordinary row in Settings ▸ Interface ▸ Editing
// afterwards, so nothing here is a decision anybody is stuck with.
//
// It is deliberately plain for now. The four cards of docs/07 §13.1, each with
// a small image showing what the choice does, are the destination; the owner
// asked for the simple version first and the polish is in docs/TODO.md.

import 'package:flutter/widgets.dart';

import '../state/workspace.dart';
import '../widgets/controls.dart';

/// Show the screen if this machine has never answered it, and record the
/// answer. Does nothing at all on any later launch, so callers can call it
/// unconditionally at start-up.
Future<void> maybeShowFirstRunFrb(
    BuildContext context, Workspace workspace) async {
  if (workspace.firstRunDone) return;
  final vegas = await showLumitModal<bool>(
    context: context,
    initialSize: const Size(560, 340),
    minSize: const Size(460, 300),
    builder: (close) => _FirstRun(onChoose: close),
  );
  // Null is the skip — the button, or a click on the scrim. Either way the
  // question has been put, so it is not put again; skipping keeps the defaults,
  // which is the After Effects shape.
  if (vegas == null) {
    workspace.skipFirstRun();
  } else {
    workspace.setEditingStyle(vegas: vegas);
  }
}

class _FirstRun extends StatelessWidget {
  final ValueChanged<bool?> onChoose;
  const _FirstRun({required this.onChoose});

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return FloatSurface(
      child: SizedBox.expand(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
              child: Text('How do you edit?', style: t.bodyPrimary),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: Text(
                'Lumit can start out shaped like the editor you already know. '
                'Either answer can be changed later in Settings.',
                style: t.small.copyWith(color: t.textMuted),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _Choice(
                        id: 'first-run-ae',
                        title: 'After Effects',
                        blurb: 'Footage arrives as a layer, and the Retime '
                            'graph shows which moment of the source is on '
                            'screen.',
                        onTap: () => onChoose(false),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _Choice(
                        id: 'first-run-vegas',
                        title: 'Vegas',
                        blurb: 'Video arrives as a Sequence layer you can cut '
                            'into clips, and the Retime graph shows playback '
                            'speed you drag up to ramp and below zero to '
                            'reverse.',
                        onTap: () => onChoose(true),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  HouseButton(
                    key: const ValueKey('first-run-skip'),
                    small: true,
                    frameless: true,
                    onPressed: () => onChoose(null),
                    child: Text('Skip', style: t.small),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One answer: a tall card that is entirely the button, because the blurb is
/// as much a part of the choice as the name at the top of it.
class _Choice extends StatelessWidget {
  final String id;
  final String title;
  final String blurb;
  final VoidCallback onTap;

  const _Choice({
    required this.id,
    required this.title,
    required this.blurb,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return GestureDetector(
      key: ValueKey<String>(id),
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: t.surface2,
          borderRadius: BorderRadius.circular(t.tokens.controlRadius),
          border: Border.all(color: t.hairline, width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: t.bodyPrimary),
            const SizedBox(height: 6),
            Text(blurb, style: t.small.copyWith(color: t.textMuted)),
          ],
        ),
      ),
    );
  }
}
