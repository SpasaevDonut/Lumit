// The engine's own words have to reach the translators too (K-298).
//
// Effect names, parameter names, choice options and the Add-effect menu's
// category headings are written in Rust, in `crates/lumit-core/src/fx/`, and
// come up over the bridge as plain English. `lib/l10n/engine_labels.dart` looks each
// one up by that English text. Nothing in the type system connects the two, so
// this test reads the schema source and fails if the engine can send a word the
// table has no entry for — which is what would otherwise leave a new effect
// shipping in English inside a translated application.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumit_flutter/l10n/engine_labels.dart';

/// Every user-facing string the effects schema can hand to the interface.
///
/// Read rather than imported: engine crates never depend on the frontend and the
/// frontend cannot call into `lumit-core` without the bridge, so the source text
/// is the only thing the two genuinely share.
Set<String> _engineLabels() {
  final dir = Directory('../crates/lumit-core/src/fx');
  expect(dir.existsSync(), isTrue,
      reason: 'run this from flutter_ui/, beside the crates/ tree');

  final labels = <String>{};
  final label = RegExp(r'\blabel:\s*"([^"]+)"');
  // `options: &["Transparent", "Repeat", …]` and the shared `OPTIONS` consts a
  // schema aliases instead of writing the list out again.
  final options = RegExp(r'(?:options:|OPTIONS[^=]*=)\s*&\[([^\]]*)\]');
  final quoted = RegExp(r'"([^"]+)"');
  // The Add-effect menu's category headings: `FxCategory::label`'s match arms.
  final category = RegExp(r'fn label\(.*?\{(.*?)\n    \}', dotAll: true);
  final arm = RegExp(r'=>\s*"([^"]+)"');

  for (final file in dir.listSync().whereType<File>()) {
    if (!file.path.endsWith('.rs')) continue;
    final src = file.readAsStringSync();
    for (final m in label.allMatches(src)) {
      labels.add(m.group(1)!);
    }
    for (final m in options.allMatches(src)) {
      for (final o in quoted.allMatches(m.group(1)!)) {
        labels.add(o.group(1)!);
      }
    }
    final cat = category.firstMatch(src);
    if (cat != null) {
      for (final m in arm.allMatches(cat.group(1)!)) {
        labels.add(m.group(1)!);
      }
    }
  }
  // Settings -> Keymap: what each shortcut does, and the heading saying where
  // it is live. `"action.id" => "Play or pause"` and
  // `KeyContext::Global => "Anywhere"`.
  final keymap = File('../crates/lumit-keymap/src/lib.rs');
  expect(keymap.existsSync(), isTrue);
  final keymapSrc = keymap.readAsStringSync();
  for (final m
      in RegExp(r'"[a-z0-9._]+"\s*=>\s*"([^"]+)"').allMatches(keymapSrc)) {
    labels.add(m.group(1)!);
  }
  for (final m
      in RegExp(r'KeyContext::\w+\s*=>\s*"([^"]+)"').allMatches(keymapSrc)) {
    labels.add(m.group(1)!);
  }

  // A regex that has stopped matching the schema would pass this test by finding
  // nothing at all, which is the one failure it must not have.
  expect(labels.length, greaterThan(250),
      reason: 'the schema has far more labels than this — the patterns above '
          'have probably drifted from how builtins.rs is written');
  return labels;
}

void main() {
  test('every label the engine can send has a translation entry', () {
    final missing = _engineLabels().where((l) => !hasEngineLabel(l)).toList()
      ..sort();
    expect(
      missing,
      isEmpty,
      reason: 'these appear in the effects schema but not in '
          'lib/l10n/engine_labels.dart. Add each one to the table there, and add '
          'the matching key to lib/l10n/app_en.arb, or it ships untranslated.',
    );
  });

  test('a label with no entry comes back as it arrived', () {
    // The fallback is what keeps a schema change from blanking the panel between
    // the effect landing and this test being satisfied.
    expect(engineLabel('Not a real effect'), 'Not a real effect');
    expect(engineLabel(''), '');
  });

  test('a known label resolves through the table', () {
    expect(hasEngineLabel('Gaussian blur'), isTrue);
    expect(engineLabel('Gaussian blur'), 'Gaussian blur');
  });
}
