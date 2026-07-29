// Settings defaults must be a no-op for existing installs, and the workspace
// JSON must round-trip.

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumit_flutter/state/settings.dart';
import 'package:lumit_flutter/state/workspace.dart';
import 'package:lumit_flutter/theme/theme.dart';

void main() {
  test('performance defaults are the shipped ones', () {
    final p = PerformanceSettings();
    expect(p.playback, PlaybackMode.adaptive);
  });

  test('interface defaults are a no-op for existing installs', () {
    final i = InterfaceSettings();
    expect(i.uiScale, 1.0);
    expect(i.showTooltips, isTrue);
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
