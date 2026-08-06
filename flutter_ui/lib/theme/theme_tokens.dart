// Every colour a theme carries, as a list you can walk (K-202).
//
// **Why this exists.** `LumitTheme` is a struct of named fields, which is the
// right shape for *drawing* — `t.accent` reads better than a map lookup and
// the compiler catches a typo. It is the wrong shape for a settings page that
// has to offer one row per colour, and for a custom theme that has to be
// stored as data. So the tokens are declared once here, each with the reader
// and the writer that reach its field, and both the editor and the stored
// custom theme walk this list rather than restating the struct.
//
// Adding a colour to `LumitTheme` and forgetting to list it here would leave a
// row missing from the editor with nothing to say so — which is why
// `theme_tokens_test.dart` counts the struct's fields against this list.

import 'package:flutter/widgets.dart';

import 'theme.dart';

/// One editable colour: what it is called, what it is for, and how to read or
/// write it on a theme.
class ThemeToken {
  /// The stable key a stored custom theme files this colour under. Never
  /// shown; never changed, or every saved theme loses that colour.
  final String key;

  /// The name the editor puts on the left of the row. Sentence case.
  final String label;

  /// One line saying what the colour does, for the row underneath.
  final String description;

  /// The group heading this token sits under in the editor.
  final String group;

  final Color Function(LumitTheme) read;
  final LumitTheme Function(LumitTheme, Color) write;

  const ThemeToken({
    required this.key,
    required this.label,
    required this.description,
    required this.group,
    required this.read,
    required this.write,
  });
}

/// Rebuild a theme with one field replaced. The struct has no general
/// `copyWith` (its own takes four fields, deliberately), so this is the one
/// place that restates it — every token's writer goes through here.
LumitTheme _with(
  LumitTheme t, {
  Color? surface0,
  Color? surface1,
  Color? surface2,
  Color? surface3,
  Color? surface4,
  Color? textPrimary,
  Color? textSecondary,
  Color? textMuted,
  Color? textDisabled,
  Color? hairline,
  Color? hairlineStrong,
  Color? accent,
  Color? accentHover,
  Color? success,
  Color? warning,
  Color? error,
  Color? cacheDisk,
  List<Color>? curve,
  LayerColours? layer,
  Color? timelineOutOfRange,
  Color? selectionFill,
  Color? marker,
  WaveformColours? waveform,
}) =>
    LumitTheme(
      mode: t.mode,
      shape: t.shape,
      tokens: t.tokens,
      surface0: surface0 ?? t.surface0,
      surface1: surface1 ?? t.surface1,
      surface2: surface2 ?? t.surface2,
      surface3: surface3 ?? t.surface3,
      surface4: surface4 ?? t.surface4,
      // Never a token: the Viewer's surround is strictly neutral by spec
      // (15-DESIGN §2.1/§11) because you cannot judge a grade against a
      // tinted surround. Carried through, never offered.
      viewerSurround: t.viewerSurround,
      textPrimary: textPrimary ?? t.textPrimary,
      textSecondary: textSecondary ?? t.textSecondary,
      textMuted: textMuted ?? t.textMuted,
      textDisabled: textDisabled ?? t.textDisabled,
      hairline: hairline ?? t.hairline,
      hairlineStrong: hairlineStrong ?? t.hairlineStrong,
      accent: accent ?? t.accent,
      accentHover: accentHover ?? t.accentHover,
      success: success ?? t.success,
      warning: warning ?? t.warning,
      error: error ?? t.error,
      cacheDisk: cacheDisk ?? t.cacheDisk,
      curve: curve ?? t.curve,
      layer: layer ?? t.layer,
      timelineOutOfRange: timelineOutOfRange ?? t.timelineOutOfRange,
      selectionFill: selectionFill ?? t.selectionFill,
      marker: marker ?? t.marker,
      waveform: waveform ?? t.waveform,
    );

LayerColours _layerWith(
  LayerColours l, {
  Color? footage,
  Color? sequence,
  Color? precomp,
  Color? solid,
  Color? text,
  Color? camera,
}) =>
    LayerColours(
      footage: footage ?? l.footage,
      sequence: sequence ?? l.sequence,
      precomp: precomp ?? l.precomp,
      solid: solid ?? l.solid,
      text: text ?? l.text,
      camera: camera ?? l.camera,
    );

WaveformColours _waveformWith(
  WaveformColours w, {
  Color? rest,
  Color? low,
  Color? mid,
  Color? high,
}) =>
    WaveformColours(
      rest: rest ?? w.rest,
      low: low ?? w.low,
      mid: mid ?? w.mid,
      high: high ?? w.high,
    );

/// One curve stroke by index, preserving the rest of the ramp.
List<Color> _curveWith(List<Color> curve, int i, Color c) {
  final next = List<Color>.of(curve);
  if (i < next.length) next[i] = c;
  return next;
}

/// Every editable colour, in the order the editor lists them.
///
/// Grouped the way somebody changing a theme thinks: the grounds first (they
/// set the whole mood), then what sits on them, then the accents, then the
/// two areas with palettes of their own.
final List<ThemeToken> themeTokens = [
  // --- Surfaces -----------------------------------------------------------
  ThemeToken(
    key: 'surface0',
    label: 'Background',
    description: 'The deepest ground — behind panels, and the app backdrop.',
    group: 'Surfaces',
    read: (t) => t.surface0,
    write: (t, c) => _with(t, surface0: c),
  ),
  ThemeToken(
    key: 'surface1',
    label: 'Panel',
    description: 'A panel\'s own ground, and the Timeline inside the work area.',
    group: 'Surfaces',
    read: (t) => t.surface1,
    write: (t, c) => _with(t, surface1: c),
  ),
  ThemeToken(
    key: 'surface2',
    label: 'Raised',
    description: 'Rows and cards lifted off the panel.',
    group: 'Surfaces',
    read: (t) => t.surface2,
    write: (t, c) => _with(t, surface2: c),
  ),
  ThemeToken(
    key: 'surface3',
    label: 'Control',
    description: 'A field or button at rest.',
    group: 'Surfaces',
    read: (t) => t.surface3,
    write: (t, c) => _with(t, surface3: c),
  ),
  ThemeToken(
    key: 'surface4',
    label: 'Control hover',
    description: 'The same, with the pointer over it.',
    group: 'Surfaces',
    read: (t) => t.surface4,
    write: (t, c) => _with(t, surface4: c),
  ),
  ThemeToken(
    key: 'timelineOutOfRange',
    label: 'Timeline outside the work area',
    description:
        'The Timeline\'s ground either side of the work area, so the part '
        'you are delivering reads apart from the rest.',
    group: 'Surfaces',
    read: (t) => t.timelineOutOfRange,
    write: (t, c) => _with(t, timelineOutOfRange: c),
  ),
  ThemeToken(
    key: 'selectionFill',
    label: 'Selected row',
    description:
        'Under a selected layer or property; half as strong under a '
        'highlighted one.',
    group: 'Surfaces',
    read: (t) => t.selectionFill,
    write: (t, c) => _with(t, selectionFill: c),
  ),

  // --- Text ---------------------------------------------------------------
  ThemeToken(
    key: 'textPrimary',
    label: 'Text',
    description: 'Names, values, anything you read first.',
    group: 'Text',
    read: (t) => t.textPrimary,
    write: (t, c) => _with(t, textPrimary: c),
  ),
  ThemeToken(
    key: 'textSecondary',
    label: 'Text, secondary',
    description: 'Supporting text beside the primary.',
    group: 'Text',
    read: (t) => t.textSecondary,
    write: (t, c) => _with(t, textSecondary: c),
  ),
  ThemeToken(
    key: 'textMuted',
    label: 'Text, muted',
    description: 'Hints and the lines under a setting.',
    group: 'Text',
    read: (t) => t.textMuted,
    write: (t, c) => _with(t, textMuted: c),
  ),
  ThemeToken(
    key: 'textDisabled',
    label: 'Text, disabled',
    description: 'A control that cannot be used right now.',
    group: 'Text',
    read: (t) => t.textDisabled,
    write: (t, c) => _with(t, textDisabled: c),
  ),

  // --- Lines --------------------------------------------------------------
  ThemeToken(
    key: 'hairline',
    label: 'Hairline',
    description: 'The line between rows and panels.',
    group: 'Lines',
    read: (t) => t.hairline,
    write: (t, c) => _with(t, hairline: c),
  ),
  ThemeToken(
    key: 'hairlineStrong',
    label: 'Hairline, strong',
    description: 'The same line where it has to carry more weight.',
    group: 'Lines',
    read: (t) => t.hairlineStrong,
    write: (t, c) => _with(t, hairlineStrong: c),
  ),

  // --- Roles --------------------------------------------------------------
  ThemeToken(
    key: 'accent',
    label: 'Accent',
    description: 'The one accent: focus, the playhead, what is chosen.',
    group: 'Roles',
    read: (t) => t.accent,
    write: (t, c) => _with(t, accent: c),
  ),
  ThemeToken(
    key: 'accentHover',
    label: 'Accent hover',
    description: 'The accent with the pointer on it.',
    group: 'Roles',
    read: (t) => t.accentHover,
    write: (t, c) => _with(t, accentHover: c),
  ),
  ThemeToken(
    key: 'success',
    label: 'Success',
    description: 'Something finished, or held in the cache.',
    group: 'Roles',
    read: (t) => t.success,
    write: (t, c) => _with(t, success: c),
  ),
  ThemeToken(
    key: 'warning',
    label: 'Warning',
    description: 'Something worth reading before carrying on.',
    group: 'Roles',
    read: (t) => t.warning,
    write: (t, c) => _with(t, warning: c),
  ),
  ThemeToken(
    key: 'error',
    label: 'Error',
    description: 'Something that did not work.',
    group: 'Roles',
    read: (t) => t.error,
    write: (t, c) => _with(t, error: c),
  ),
  ThemeToken(
    key: 'marker',
    label: 'Marker',
    description: 'Comp markers on the time ruler, and the box holding what '
        'one says. A grey by default — a marker says *here*, not *careful*.',
    group: 'Roles',
    read: (t) => t.marker,
    write: (t, c) => _with(t, marker: c),
  ),
  ThemeToken(
    key: 'cacheDisk',
    label: 'Cache, on disk',
    description: 'The disk tier of the Timeline\'s cache bar.',
    group: 'Roles',
    read: (t) => t.cacheDisk,
    write: (t, c) => _with(t, cacheDisk: c),
  ),

  // --- Waveforms ----------------------------------------------------------
  ThemeToken(
    key: 'waveformRest',
    label: 'Waveform',
    description: 'The single wave a layer or a clip draws. Content, not '
        'state — never the accent.',
    group: 'Waveforms',
    read: (t) => t.waveform.rest,
    write: (t, c) => _with(t, waveform: _waveformWith(t.waveform, rest: c)),
  ),
  ThemeToken(
    key: 'waveformLow',
    label: 'Multiwave, bass',
    description: 'The bottom band of the multiwave stack — kicks and bass.',
    group: 'Waveforms',
    read: (t) => t.waveform.low,
    write: (t, c) => _with(t, waveform: _waveformWith(t.waveform, low: c)),
  ),
  ThemeToken(
    key: 'waveformMid',
    label: 'Multiwave, middle',
    description: 'The middle band — most of a voice, a snare\'s body.',
    group: 'Waveforms',
    read: (t) => t.waveform.mid,
    write: (t, c) => _with(t, waveform: _waveformWith(t.waveform, mid: c)),
  ),
  ThemeToken(
    key: 'waveformHigh',
    label: 'Multiwave, treble',
    description: 'The top band — hats, sibilance, transient edge.',
    group: 'Waveforms',
    read: (t) => t.waveform.high,
    write: (t, c) => _with(t, waveform: _waveformWith(t.waveform, high: c)),
  ),

  // --- Graph curves -------------------------------------------------------
  for (var i = 0; i < 4; i++)
    ThemeToken(
      key: 'curve$i',
      label: 'Curve ${i + 1}',
      description: 'A property\'s stroke in the graph editor.',
      group: 'Graph curves',
      read: (t) => i < t.curve.length ? t.curve[i] : t.accent,
      write: (t, c) => _with(t, curve: _curveWith(t.curve, i, c)),
    ),

  // --- Layer kinds --------------------------------------------------------
  ThemeToken(
    key: 'layerFootage',
    label: 'Footage',
    description: 'Footage layers.',
    group: 'Layer kinds',
    read: (t) => t.layer.footage,
    write: (t, c) => _with(t, layer: _layerWith(t.layer, footage: c)),
  ),
  ThemeToken(
    key: 'layerSequence',
    label: 'Sequence',
    description: 'Sequence layers.',
    group: 'Layer kinds',
    read: (t) => t.layer.sequence,
    write: (t, c) => _with(t, layer: _layerWith(t.layer, sequence: c)),
  ),
  ThemeToken(
    key: 'layerPrecomp',
    label: 'Precomp',
    description: 'Precomp layers.',
    group: 'Layer kinds',
    read: (t) => t.layer.precomp,
    write: (t, c) => _with(t, layer: _layerWith(t.layer, precomp: c)),
  ),
  ThemeToken(
    key: 'layerSolid',
    label: 'Solid',
    description: 'Solid layers.',
    group: 'Layer kinds',
    read: (t) => t.layer.solid,
    write: (t, c) => _with(t, layer: _layerWith(t.layer, solid: c)),
  ),
  ThemeToken(
    key: 'layerText',
    label: 'Text',
    description: 'Text layers.',
    group: 'Layer kinds',
    read: (t) => t.layer.text,
    write: (t, c) => _with(t, layer: _layerWith(t.layer, text: c)),
  ),
  ThemeToken(
    key: 'layerCamera',
    label: 'Camera',
    description: 'Camera layers.',
    group: 'Layer kinds',
    read: (t) => t.layer.camera,
    write: (t, c) => _with(t, layer: _layerWith(t.layer, camera: c)),
  ),
];

/// The token groups, in listing order and without repeats.
List<String> get themeTokenGroups {
  final seen = <String>[];
  for (final token in themeTokens) {
    if (!seen.contains(token.group)) seen.add(token.group);
  }
  return seen;
}

/// Read every token off a theme — what the editor opens with, and what a save
/// writes down.
Map<String, Color> tokensOf(LumitTheme theme) =>
    {for (final token in themeTokens) token.key: token.read(theme)};

/// Apply stored colours to a theme. A key this build does not know is
/// ignored, and a token the stored map does not carry keeps the base's
/// colour — so a theme saved by an older or newer Lumit still opens, with the
/// colours it does have.
LumitTheme applyTokens(LumitTheme base, Map<String, Color> colours) {
  var theme = base;
  for (final token in themeTokens) {
    final colour = colours[token.key];
    if (colour != null) theme = token.write(theme, colour);
  }
  return theme;
}
