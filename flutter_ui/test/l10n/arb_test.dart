// What app_en.arb is allowed to say (K-298, docs/07-UI-SPEC.md §13.2).
//
// The .arb is the one file a translator reads, so the rules that used to live in
// reviewers' heads live here instead: a tooltip is the control's name, not a
// sentence about it; every string carries a note saying where it appears; and
// the glossary's banned words stay banned in the copy as well as in the code.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Tooltips that are allowed to run long, and why.
///
/// docs/07-UI-SPEC.md §13.2 reserves the sentence-length "rich" tooltip for
/// concepts with Lumit-specific behaviour. These six are the whole list: the
/// cache meters, whose tooltips carry live numbers and warn that clicking
/// throws work away, and the two playback modes, which are the adaptive
/// degradation the spec names outright. Anything else must fit in five words.
const _richTooltips = {
  'tipCacheEmpty',
  'tipCacheRam',
  'tipCacheVram',
  'tipCacheDisk',
  'tipPlaybackAdaptive',
  'tipPlaybackEveryFrame',
};

/// docs/01-GLOSSARY.md §9, as it applies to what the user reads. `render` is
/// missing on purpose: it is banned only for writing a file, and the Timeline's
/// render-time column and the Viewer's render stages are the legitimate sense.
const _banned = {
  'track': 'layer',
  'velocity': 'speed',
  'time remap': 'Retime',
  'time-remap': 'Retime',
  'CTI': 'playhead',
};

/// Strings where a banned word is not the banned *sense*.
///
/// The glossary bans "track" where Lumit means a **layer**. It says nothing
/// about tracking as a verb, and these three are After Effects features whose
/// names contain it: following a camera, following motion, and the matte that
/// After Effects calls a track matte. All three are menu rows for work that is
/// not built yet; if the wording is revisited when they are, revisit this too.
const _bannedWordIsAnotherSense = {
  'menuTrackCamera',
  'menuTrackMotion',
  'menuTrackMatte',
  'toolCameraPan',
};

Map<String, dynamic> _arb() =>
    json.decode(File('lib/l10n/app_en.arb').readAsStringSync())
        as Map<String, dynamic>;

Iterable<MapEntry<String, String>> _messages(Map<String, dynamic> arb) =>
    arb.entries
        .where((e) => !e.key.startsWith('@'))
        .map((e) => MapEntry(e.key, e.value as String));

void main() {
  test('app_en.arb is valid JSON with messages in it', () {
    expect(_messages(_arb()).length, greaterThan(500));
  });

  test('a tooltip is the control name, not a sentence about it', () {
    final long = <String>[];
    for (final m in _messages(_arb())) {
      if (!m.key.startsWith('tip') || _richTooltips.contains(m.key)) continue;
      // A placeholder stands for one word whatever it expands to.
      final words = m.value.replaceAll(RegExp(r'\{\w+\}'), 'x').split(' ');
      if (words.length > 5) long.add('${m.key}: "${m.value}"');
    }
    expect(
      long,
      isEmpty,
      reason: 'tooltips are the control\'s name and its shortcut '
          '(docs/07-UI-SPEC.md §13.2) — under five words, two where two will '
          'do. Shorten these, or add the key to _richTooltips above with a '
          'reason it has to be long.',
    );
  });

  test('every string tells the translator where it appears', () {
    final arb = _arb();
    final undescribed = <String>[];
    for (final m in _messages(arb)) {
      final meta = arb['@${m.key}'] as Map<String, dynamic>?;
      final description = meta?['description'] as String?;
      if (description == null || description.trim().length < 10) {
        undescribed.add(m.key);
      }
    }
    expect(
      undescribed,
      isEmpty,
      reason: 'Crowdin shows the description beside the string, and it is all '
          'the context a translator gets. Say where it appears and what '
          'constrains it.',
    );
  });

  test('the copy uses the glossary words', () {
    final wrong = <String>[];
    for (final m in _messages(_arb())) {
      if (_bannedWordIsAnotherSense.contains(m.key)) continue;
      for (final entry in _banned.entries) {
        final pattern =
            RegExp('\\b${RegExp.escape(entry.key)}\\b', caseSensitive: false);
        if (pattern.hasMatch(m.value)) {
          wrong.add('${m.key} says "${entry.key}" — say "${entry.value}"');
        }
      }
    }
    expect(wrong, isEmpty,
        reason: 'docs/01-GLOSSARY.md §9 is binding for copy');
  });

  test('every placeholder in a string is declared', () {
    // An undeclared placeholder is generated as literal braces, so the user sees
    // "{path}" where the file name should be.
    final arb = _arb();
    final bad = <String>[];
    for (final m in _messages(arb)) {
      final used = RegExp(r'\{(\w+)\}')
          .allMatches(m.value)
          .map((x) => x.group(1)!)
          .toSet();
      if (used.isEmpty) continue;
      final meta = arb['@${m.key}'] as Map<String, dynamic>?;
      final declared =
          (meta?['placeholders'] as Map<String, dynamic>?)?.keys.toSet() ??
              const <String>{};
      final missing = used.difference(declared);
      if (missing.isNotEmpty) bad.add('${m.key}: ${missing.join(', ')}');
    }
    expect(bad, isEmpty);
  });

  test('the target languages have a file to be translated into', () {
    // Crowdin writes these; an empty one is normal and means "not started".
    for (final tag in ['de', 'kk', 'uk', 'zh']) {
      expect(File('lib/l10n/app_$tag.arb').existsSync(), isTrue,
          reason:
              'app_$tag.arb is missing — crowdin.yml expects to land there');
    }
  });
}
