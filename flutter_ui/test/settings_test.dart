// Settings defaults must be a no-op for existing installs, and the workspace
// JSON must round-trip.

import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumit_flutter/state/settings.dart';
import 'package:lumit_flutter/state/workspace.dart';
import 'package:lumit_flutter/theme/theme.dart';

/// A settings file of this test's own, never the developer's real one — every
/// setter calls `save()`, and the store is machine state a test must not reach.
String _scratchStore(String name) =>
    '${Directory.systemTemp.path}${Platform.pathSeparator}'
    'lumit-test-$name${Platform.pathSeparator}workspace.json';

void main() {
  test('performance defaults are the shipped ones', () {
    final p = PerformanceSettings();
    expect(p.playback, PlaybackMode.adaptive);
  });

  test('interface defaults are a no-op for existing installs', () {
    final i = InterfaceSettings();
    expect(i.uiScale, 1.0);
    expect(i.showTooltips, isTrue);
    // The Vegas pair (K-246) defaults off: the shipped behaviour is the
    // After Effects one, and a new setting must never change an editor on
    // somebody who has not asked for it.
    expect(i.retimeOpensToSpeed, isFalse);
    expect(i.videoAsSequenceLayer, isFalse);
    // The Retime row reads as a clock by default (K-287); seconds are the
    // deviation, not the shipped state.
    expect(i.retimeInSeconds, isFalse);
  });

  test('a settings file written before the Vegas pair loads as After Effects',
      () {
    final i = InterfaceSettings.fromJson(const {'ui_scale': 1.25});
    expect(i.retimeOpensToSpeed, isFalse);
    expect(i.videoAsSequenceLayer, isFalse);
    expect(i.retimeInSeconds, isFalse);
  });

  test('the Retime seconds preference round-trips', () {
    final i = InterfaceSettings(retimeInSeconds: true);
    expect(InterfaceSettings.fromJson(i.toJson()).retimeInSeconds, isTrue);
  });

  /// The returning playhead is the *new* default (K-254), so unlike the Vegas
  /// pair it does not defer to what a settings file leaves out — an install
  /// that predates the field adopts the new behaviour rather than being pinned
  /// to the old one by its own silence.
  test('the playhead returns on stop unless a settings file says otherwise',
      () {
    expect(InterfaceSettings().playheadStaysOnStop, isFalse);
    expect(
        InterfaceSettings.fromJson(const {'ui_scale': 1.25}).playheadStaysOnStop,
        isFalse);
    final on = InterfaceSettings()..playheadStaysOnStop = true;
    expect(InterfaceSettings.fromJson(on.toJson()).playheadStaysOnStop, isTrue);
  });

  test('the Vegas pair survives a settings round-trip', () {
    final i = InterfaceSettings()
      ..retimeOpensToSpeed = true
      ..videoAsSequenceLayer = true;
    final back = InterfaceSettings.fromJson(i.toJson());
    expect(back.retimeOpensToSpeed, isTrue);
    expect(back.videoAsSequenceLayer, isTrue);
  });

  test('the Vegas answer sets both preferences and answers the question', () {
    Workspace.storeOverride = _scratchStore('vegas');
    final ws = Workspace()..setEditingStyle(vegas: true);
    expect(ws.interface.retimeOpensToSpeed, isTrue);
    expect(ws.interface.videoAsSequenceLayer, isTrue);
    expect(ws.firstRunDone, isTrue);
    Workspace.storeOverride = null;
  });

  test('the After Effects answer leaves both off, and is still an answer', () {
    Workspace.storeOverride = _scratchStore('ae');
    final ws = Workspace()..setEditingStyle(vegas: false);
    expect(ws.interface.retimeOpensToSpeed, isFalse);
    expect(ws.interface.videoAsSequenceLayer, isFalse);
    // The point of the flag: answering "After Effects" must not leave the
    // screen asking again on the next launch just because nothing changed.
    expect(ws.firstRunDone, isTrue);
    Workspace.storeOverride = null;
  });

  // The whole first-run rule in two lines: no file means ask, a file means
  // do not. Anything else — a `Workspace` built by a test, a corrupt file —
  // counts as "do not", or the screen appears where it has no business.
  test('only a missing settings file counts as a first run', () {
    expect(Workspace().firstRunDone, isTrue,
        reason: 'a Workspace built directly is not a first run');

    final missing = _scratchStore('missing');
    File(missing).parent.createSync(recursive: true);
    if (File(missing).existsSync()) File(missing).deleteSync();
    Workspace.storeOverride = missing;
    expect((Workspace()..load()).firstRunDone, isFalse);

    final corrupt = _scratchStore('corrupt');
    File(corrupt).parent.createSync(recursive: true);
    File(corrupt).writeAsStringSync('{ this is not json');
    Workspace.storeOverride = corrupt;
    expect((Workspace()..load()).firstRunDone, isTrue,
        reason: 'a corrupt file belongs to somebody who already uses Lumit');

    Workspace.storeOverride = null;
  });

  test('an answered first run survives a restart', () {
    final path = _scratchStore('restart');
    File(path).parent.createSync(recursive: true);
    if (File(path).existsSync()) File(path).deleteSync();
    Workspace.storeOverride = path;

    final first = Workspace()..load();
    expect(first.firstRunDone, isFalse);
    first.setEditingStyle(vegas: true);

    final second = Workspace()..load();
    expect(second.firstRunDone, isTrue);
    expect(second.interface.retimeOpensToSpeed, isTrue);
    Workspace.storeOverride = null;
  });

  test('an unknown playback name falls back to adaptive', () {
    final p = PerformanceSettings.fromJson(const {'playback': 'warp-speed'});
    expect(p.playback, PlaybackMode.adaptive);
  });

  // The bug: the budgets were live engine state with nothing behind them, so
  // they reset on every launch while every other setting survived.
  test('cache budgets survive a settings round-trip', () {
    final p = PerformanceSettings()
      ..cacheBudgetBytes = 3 * 1024 * 1024 * 1024
      ..vramBudgetBytes = 2 * 1024 * 1024 * 1024;
    final back = PerformanceSettings.fromJson(p.toJson());
    expect(back.cacheBudgetBytes, 3 * 1024 * 1024 * 1024);
    expect(back.vramBudgetBytes, 2 * 1024 * 1024 * 1024);
  });

  test('untouched budgets stay absent rather than freezing a default', () {
    final json = PerformanceSettings().toJson();
    expect(json.containsKey('cache_budget_bytes'), isFalse);
    expect(json.containsKey('vram_budget_bytes'), isFalse);
    expect(PerformanceSettings.fromJson(json).cacheBudgetBytes, isNull);
  });

  test('a nonsense budget in the file loads as absent', () {
    final p = PerformanceSettings.fromJson(const {
      'playback': 'adaptive',
      'cache_budget_bytes': 'lots',
      'vram_budget_bytes': -1,
    });
    expect(p.cacheBudgetBytes, isNull);
    expect(p.vramBudgetBytes, isNull);
  });

  test('workspace JSON round-trips appearance and settings', () {
    final ws = Workspace();
    ws.colorScheme = LumitColorScheme.gruvboxDark;
    ws.themeShape = ThemeShape.round;
    ws.accentOverride = const Color(0xff804060);
    ws.animationLevel = AnimationLevel.minimal;
    ws.performance.playback = PlaybackMode.everyFrame;
    ws.lastProjectPath = 'C:/edit/last.lum';
    ws.recompose();

    final j = ws.toJson();
    final back = Workspace()..applyJson(Map<String, dynamic>.from(j));
    expect(back.colorScheme, LumitColorScheme.gruvboxDark);
    expect(back.lastProjectPath, 'C:/edit/last.lum');
    expect(back.themeShape, ThemeShape.round);
    expect(back.animationLevel, AnimationLevel.minimal);
    expect(back.performance.playback, PlaybackMode.everyFrame);
    expect((back.accentOverride!.r * 255).round(), 0x80);
    // The rebuilt theme carries the override and the shape tokens.
    expect(back.theme.tokens, ShapeTokens.round);
    expect((back.theme.accent.r * 255).round(), 0x80);
  });
}
