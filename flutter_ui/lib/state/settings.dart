// Application-wide settings the Flutter frontend actually reads. Everything
// that drives the engine (cache budget, autosave rotation, export presets)
// lives engine-side and is reached through the bridge; only working
// preferences of the interface itself are held and persisted here.

/// Which of the two playback behaviours the Viewer uses (docs/13 §B5).
///
/// Mirrors the engine's `BridgePlaybackMode`. Held separately rather than using
/// that type directly so the settings file does not depend on generated code,
/// and so a value written by an older build still loads.
enum PlaybackMode {
  /// Keep time, lower the resolution.
  adaptive,

  /// Every frame at full resolution, cached, sound silenced.
  everyFrame,
}

/// The Viewer's working preferences (Settings → Performance).
class PerformanceSettings {
  /// Whether the Viewer may use the zero-copy shared-texture path.
  ///
  /// On by default: the path is verified on a real window (a rendered solid
  /// screenshotted arriving through the shared texture — see the integration
  /// test). It spent a day off by default while it silently drew nothing; the
  /// cause was the handle kind (ANGLE takes legacy DXGI share handles, the
  /// engine exported NT ones) and the channel order (ANGLE opens BGRA only).
  /// The never-drawn watchdog stays: if a machine's driver declines the
  /// texture, the Viewer falls back to read-back by itself and Settings says
  /// so, rather than showing nothing.
  bool useSharedTexture;

  /// Which playback behaviour the Viewer uses. Kept here rather than only in
  /// the Viewer's own state so the choice survives a restart — it is a working
  /// preference, not a per-session toggle.
  PlaybackMode playback;

  PerformanceSettings({
    this.useSharedTexture = true,
    this.playback = PlaybackMode.adaptive,
  });

  Map<String, dynamic> toJson() => {
        'use_shared_texture': useSharedTexture,
        'playback': playback.name,
      };

  factory PerformanceSettings.fromJson(Map<String, dynamic> j) =>
      PerformanceSettings(
        useSharedTexture: j['use_shared_texture'] as bool? ?? true,
        // An unknown name (an older or newer build) falls back to adaptive,
        // which is the mode that always plays.
        playback: PlaybackMode.values.firstWhere(
          (m) => m.name == j['playback'],
          orElse: () => PlaybackMode.adaptive,
        ),
      );
}

/// Interface (Settings → Interface): UI scale and tooltips (K-117).
class InterfaceSettings {
  double uiScale;
  bool showTooltips;
  InterfaceSettings({this.uiScale = 1.0, this.showTooltips = true});

  Map<String, dynamic> toJson() =>
      {'ui_scale': uiScale, 'show_tooltips': showTooltips};
  factory InterfaceSettings.fromJson(Map<String, dynamic> j) =>
      InterfaceSettings(
        uiScale: (j['ui_scale'] as num?)?.toDouble() ?? 1.0,
        showTooltips: j['show_tooltips'] as bool? ?? true,
      );
}
