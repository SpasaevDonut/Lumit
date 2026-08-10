// The two shapes every settings form is built from: a named section, and a row
// inside it.
//
// They live here rather than in the Settings window because the Settings window
// is no longer the only form that uses them — Project settings (K-286) asks its
// questions in the same voice, and two windows that look alike should be alike
// because they share the drawing, not because someone kept them in step.

import 'package:flutter/widgets.dart';

import '../theme/theme.dart';

/// A named group of rows: a quiet label, then one card holding them.
Widget settingsSection(LumitTheme t, String title, List<Widget> rows) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 0, 0, 4),
            child: Text(title, style: t.small.copyWith(color: t.textMuted)),
          ),
          Container(
            decoration: BoxDecoration(
              color: t.surface1,
              borderRadius: BorderRadius.circular(t.tokens.floatRadius),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < rows.length; i++) ...[
                  // A hairline between rows, never above the first or below
                  // the last: the card's own edge is the boundary there.
                  if (i > 0) Container(height: 1, color: t.hairline),
                  rows[i],
                ],
              ],
            ),
          ),
        ],
      ),
    );

/// One row: what it is, a line saying what it does, and its control on the
/// right. An empty [description] leaves the second line out entirely rather
/// than reserving blank space for it.
Widget settingsRow(
  LumitTheme t,
  String title,
  String description,
  Widget control,
) =>
    Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: t.body),
                if (description.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(description,
                        style: t.small.copyWith(color: t.textMuted)),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          control,
        ],
      ),
    );
