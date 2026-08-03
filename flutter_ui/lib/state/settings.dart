// Application-wide settings the Flutter frontend actually reads. What a setting
// *means* is the engine's business and is reached through the bridge; this file
// holds the working preferences of the interface itself, plus the handful of
// machine-local numbers the engine has nowhere to keep — the cache budgets are
// live engine state with no store behind them, so without a copy here they
// reset to the default on every launch. The keymap blob in `Workspace` is the
// same arrangement: the settings file ferries it, Rust decides what it does.

import 'package:lumit_flutter/src/rust/api/cache.dart';

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

/// The Viewer's working preferences (Settings → Performance). The shared
/// texture is the only frame transport (K-183), so there is no toggle for it.
class PerformanceSettings {
  /// Which playback behaviour the Viewer uses. Kept here rather than only in
  /// the Viewer's own state so the choice survives a restart — it is a working
  /// preference, not a per-session toggle.
  PlaybackMode playback;

  /// The rendered-frame cache budget in bytes, as the user last set it.
  ///
  /// Null means "whatever the engine defaults to" — the shipped default is the
  /// engine's business, and writing a copy of it out at first launch would
  /// freeze today's default into every settings file. Only a deliberate change
  /// puts a number here. The frontend never interprets it; it hands it back to
  /// the engine on the next launch exactly as it received it.
  int? cacheBudgetBytes;

  /// The graphics-card preview cache budget in bytes. Null as for
  /// [cacheBudgetBytes].
  int? vramBudgetBytes;

  /// The disk frame cache's budget in bytes. Null as for [cacheBudgetBytes].
  int? diskBudgetBytes;

  /// Where parked frames live, as the engine's own enum name
  /// (`appData` / `besideProject` / `custom`). Null means the engine's default.
  /// The frontend never interprets it beyond showing the choice — it hands the
  /// name back on the next launch.
  String? diskCacheLocation;

  /// The folder chosen for the `custom` location. Null when none has been
  /// picked, in which case the engine keeps its default rather than pointing
  /// the tier at nothing.
  String? diskCacheFolder;

  PerformanceSettings({
    this.playback = PlaybackMode.adaptive,
    this.cacheBudgetBytes,
    this.vramBudgetBytes,
    this.diskBudgetBytes,
    this.diskCacheLocation,
    this.diskCacheFolder,
  });

  Map<String, dynamic> toJson() => {
        'playback': playback.name,
        if (cacheBudgetBytes != null) 'cache_budget_bytes': cacheBudgetBytes,
        if (vramBudgetBytes != null) 'vram_budget_bytes': vramBudgetBytes,
        if (diskBudgetBytes != null) 'disk_budget_bytes': diskBudgetBytes,
        if (diskCacheLocation != null) 'disk_cache_location': diskCacheLocation,
        if (diskCacheFolder != null) 'disk_cache_folder': diskCacheFolder,
      };

  factory PerformanceSettings.fromJson(Map<String, dynamic> j) =>
      PerformanceSettings(
        // An unknown name (an older or newer build) falls back to adaptive,
        // which is the mode that always plays.
        playback: PlaybackMode.values.firstWhere(
          (m) => m.name == j['playback'],
          orElse: () => PlaybackMode.adaptive,
        ),
        // A value written by a build that stored something else entirely, or a
        // hand-edited file, must not stop the settings loading: anything that
        // is not a positive whole number is treated as absent.
        cacheBudgetBytes: _positiveInt(j['cache_budget_bytes']),
        vramBudgetBytes: _positiveInt(j['vram_budget_bytes']),
        diskBudgetBytes: _positiveInt(j['disk_budget_bytes']),
        diskCacheLocation: _nonEmpty(j['disk_cache_location']),
        diskCacheFolder: _nonEmpty(j['disk_cache_folder']),
      );
}

int? _positiveInt(Object? v) => v is int && v > 0 ? v : null;

String? _nonEmpty(Object? v) => v is String && v.isNotEmpty ? v : null;

/// The engine's cache-location enum from the name stored in the settings file.
///
/// By name, not by index: the settings file outlives any particular build, and
/// a reordered enum would otherwise silently move a user's cache to a different
/// folder. An unknown name — an older or newer build — falls back to the
/// application's own folder, which always works.
BridgeCacheLocation cacheLocationFromName(String name) =>
    BridgeCacheLocation.values.firstWhere(
      (l) => l.name == name,
      orElse: () => BridgeCacheLocation.appData,
    );

/// Interface (Settings → Interface): UI scale and tooltips (K-117), plus the
/// two editing preferences that make Lumit behave the Vegas way (K-246).
class InterfaceSettings {
  double uiScale;
  bool showTooltips;

  /// Whether the Effect controls panel repeats the layer's Transform rows
  /// above its effect stack.
  ///
  /// Off by default: the Timeline's fold-out already shows Transform, and
  /// the panel is for the *effects* on a layer — the repeat pushed the stack
  /// down a screen on a 3D layer. Kept as a choice because it is a habit
  /// After Effects users bring with them.
  bool transformInEffectControls;

  /// Whether a Retime channel opens in the graph editor showing playback speed
  /// rather than source position (K-246, realising K-075's preference).
  ///
  /// On, the channel opens to its Velocity lens and that lens is the **speed
  /// envelope** of K-247 — one point per key, whose height is the speed. Off,
  /// it opens to Time and the speed view keeps the ordinary two-sided
  /// derivative shape every other property has. Ordinary properties are
  /// unaffected either way; this is a Retime-only preference.
  bool retimeOpensToSpeed;

  /// Whether video footage and image sequences added to a comp arrive as a
  /// one-clip Sequence layer rather than a Footage layer (K-246).
  ///
  /// Still images never do: there is nothing to cut in a single frame.
  bool videoAsSequenceLayer;

  /// Whether stopping playback leaves the playhead on the frame that was on
  /// screen, rather than putting it back where play started (K-254).
  ///
  /// Off by default: playback is a preview of the moment you are working on,
  /// and coming back to a different frame than you left means finding your
  /// place again after every space bar. On is the After Effects behaviour, and
  /// what Lumit did before this existed — hence the phrasing as a deviation
  /// from the default rather than a choice between two equals.
  bool playheadStaysOnStop;

  InterfaceSettings({
    this.uiScale = 1.0,
    this.showTooltips = true,
    this.transformInEffectControls = false,
    this.retimeOpensToSpeed = false,
    this.videoAsSequenceLayer = false,
    this.playheadStaysOnStop = false,
  });

  Map<String, dynamic> toJson() => {
        'ui_scale': uiScale,
        'show_tooltips': showTooltips,
        'transform_in_effect_controls': transformInEffectControls,
        'retime_opens_to_speed': retimeOpensToSpeed,
        'video_as_sequence_layer': videoAsSequenceLayer,
        'playhead_stays_on_stop': playheadStaysOnStop,
      };
  factory InterfaceSettings.fromJson(Map<String, dynamic> j) =>
      InterfaceSettings(
        uiScale: (j['ui_scale'] as num?)?.toDouble() ?? 1.0,
        showTooltips: j['show_tooltips'] as bool? ?? true,
        transformInEffectControls:
            j['transform_in_effect_controls'] as bool? ?? false,
        // Absent means off, which is the After Effects behaviour Lumit had
        // before these existed — a settings file written by an older build
        // must not silently change how the editor works.
        retimeOpensToSpeed: j['retime_opens_to_speed'] as bool? ?? false,
        videoAsSequenceLayer: j['video_as_sequence_layer'] as bool? ?? false,
        // Absent means off here too, but for the opposite reason: the returning
        // playhead is the *new* default (K-254), so a settings file written
        // before this field existed adopts it rather than being pinned to the
        // old behaviour by its own silence.
        playheadStaysOnStop: j['playhead_stays_on_stop'] as bool? ?? false,
      );
}
