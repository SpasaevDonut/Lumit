// The Composition settings dialog, and its twin the New composition dialog.
//
// One body serves both, because they ask the same four questions — name, size,
// frame rate, duration — and only differ in what happens when you press the
// button at the bottom. Reached from the menu bar's Composition ▸ Composition
// settings…, from the Project panel's context menu on a comp, and from the
// Project panel's New composition button (including when footage is dropped on
// it, which prefills the fields from the media — docs/07 §3.1).
//
// **The frame rate is one number, and the duration is a length of time.** Both
// are deliberate:
//
// * The rate reads as `600` or `23.976`, not as a numerator over a denominator.
//   The exact pair still crosses the bridge — 23.976 is 24000/1001 and a float
//   round trip would not give that back (docs/14 §2) — but the pair is worked out
//   here from the number typed, and the awkward rates are one click away in the
//   Presets list, so nobody has to know that 1001 exists.
// * The duration is `HH:MM:SS.mmm`, not a frame count, and that is what fixes the
//   old "changing the rate retimes the comp" bug (K-180). A frame count means
//   nothing without the rate it was counted at, so writing yesterday's count back
//   at a new rate changed how long the comp really was while every layer kept its
//   own seconds — which looked exactly like the layers speeding up or slowing
//   down. Seconds are what the document stores, so a rate change is only ever a
//   rate change.

import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:lumit_flutter/src/rust/api/effect.dart';
import 'package:lumit_flutter/src/rust/api/footage.dart';
import 'package:lumit_flutter/src/rust/api/project.dart';

import '../icons/icons.dart';
import '../theme/theme.dart';
import '../widgets/controls.dart';

/// The label column. Shared with the caption under the Duration field, which is
/// indented by exactly this so it lines up with the box it describes.
const double _labelWidth = 86;

/// The frame rates worth one click. The `1001` denominators are the NTSC family,
/// which is the whole reason the rate crosses the bridge as a pair.
const List<(String, int, int)> _ratePresets = [
  ('23.976', 24000, 1001),
  ('24', 24, 1),
  ('25', 25, 1),
  ('29.97', 30000, 1001),
  ('30', 30, 1),
  ('50', 50, 1),
  ('59.94', 60000, 1001),
  ('60', 60, 1),
  ('120', 120, 1),
];

/// Edit an existing comp. Returns true when settings were applied, so the caller
/// can refresh; false when cancelled.
Future<bool> showCompSettingsFrb({
  required BuildContext context,
  required CompositionReference comp,
}) async {
  final applied = await showLumitModal<bool>(
    context: context,
    builder: (close) => _CompSettingsBody(
      title: 'Composition settings',
      confirm: 'Save',
      initial: comp.getSettings(),
      onConfirm: (settings) {
        comp.setSettings(settings: settings);
        close(true);
      },
      onCancel: () => close(false),
    ),
  );
  return applied ?? false;
}

/// Make a comp, asking first. Returns the new comp, or null when cancelled.
///
/// `footage` is what was dropped on the New composition button: the fields open
/// on the media's own size, rate and length, and every item lands in the finished
/// comp as a layer. An empty list is the plain New composition command.
Future<CompositionReference?> showNewCompositionFrb({
  required BuildContext context,
  required ProjectReference project,
  List<FootageReference> footage = const [],
}) async {
  // Probed before the dialog opens rather than inside it: `mediaInfo` reads the
  // container with FFmpeg, and a dialog that popped up and then rearranged itself
  // is worse than one that appears already right.
  var initial = BridgeCompSettings.defaults();
  for (final item in footage) {
    final info = await item.mediaInfo();
    if (info == null) continue;
    initial = BridgeCompSettings(
      name: initial.name,
      // Audio-only media has no picture to size a comp by, so it keeps whatever
      // the previous item (or the default) said.
      width: info.width > 0 ? info.width : initial.width,
      height: info.height > 0 ? info.height : initial.height,
      fpsNum: info.fpsNum > 0 ? info.fpsNum : initial.fpsNum,
      fpsDen: info.fpsNum > 0 ? info.fpsDen : initial.fpsDen,
      // The longest item wins: a comp shorter than something dropped into it
      // would clip the very thing that was asked for.
      duration: _longer(initial.duration, info.duration),
    );
  }
  if (!context.mounted) return null;

  final name = project.nextCompName();
  return showLumitModal<CompositionReference>(
    context: context,
    builder: (close) => _CompSettingsBody(
      title: 'New composition',
      confirm: 'Create',
      initial: BridgeCompSettings(
        name: name,
        width: initial.width,
        height: initial.height,
        fpsNum: initial.fpsNum,
        fpsDen: initial.fpsDen,
        duration: initial.duration,
      ),
      onConfirm: (settings) {
        final comp =
            project.newComposition(name: settings.name, settings: settings);
        for (final item in footage) {
          comp.addFootageLayer(footage: item);
        }
        close(comp);
      },
      onCancel: () => close(null),
    ),
  );
}

/// The longer of two exact durations, compared by cross-multiplication so no
/// float ever decides which of two lengths is bigger.
BridgeRational _longer(BridgeRational a, BridgeRational b) =>
    a.num.toInt() * b.den.toInt() >= b.num.toInt() * a.den.toInt() ? a : b;

class _CompSettingsBody extends StatefulWidget {
  final String title;
  final String confirm;
  final BridgeCompSettings initial;
  final void Function(BridgeCompSettings) onConfirm;
  final VoidCallback onCancel;

  const _CompSettingsBody({
    required this.title,
    required this.confirm,
    required this.initial,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  State<_CompSettingsBody> createState() => _CompSettingsBodyState();
}

class _CompSettingsBodyState extends State<_CompSettingsBody> {
  late final TextEditingController _name;
  late final TextEditingController _fps;
  late final TextEditingController _duration;
  late int _width;
  late int _height;

  /// Keep the shape when one side is edited. On by default, because resizing a
  /// comp to a shape it was never meant to be is nearly always a slip.
  bool _locked = true;

  @override
  void initState() {
    super.initState();
    final s = widget.initial;
    _name = TextEditingController(text: s.name);
    _fps = TextEditingController(text: _formatRate(s.fpsNum, s.fpsDen))
      // The list beside the field names whatever the field says, so it has to
      // follow every keystroke — not wait for the field to be submitted, which
      // would leave it naming the rate before last.
      ..addListener(() => setState(() {}));
    _duration = TextEditingController(text: formatDurationHms(s.duration));
    _width = s.width;
    _height = s.height;
  }

  @override
  void dispose() {
    _name.dispose();
    _fps.dispose();
    _duration.dispose();
    super.dispose();
  }

  /// The preset label matching what is typed, or null for a rate of one's own.
  String? get _presetLabel {
    final rate = parseRate(_fps.text);
    if (rate == null) return null;
    return _ratePresets
        .where((p) => p.$2 == rate.$1 && p.$3 == rate.$2)
        .map((p) => p.$1)
        .firstOrNull;
  }

  void _confirm() {
    final rate = parseRate(_fps.text) ??
        (widget.initial.fpsNum, widget.initial.fpsDen);
    // A duration that cannot be read is the one that was already there rather
    // than a comp of no length: a typo must not be able to throw work away.
    final duration =
        parseDurationHms(_duration.text) ?? widget.initial.duration;
    widget.onConfirm(BridgeCompSettings(
      name: _name.text.trim().isEmpty ? widget.initial.name : _name.text.trim(),
      width: _width,
      height: _height,
      fpsNum: rate.$1,
      fpsDen: rate.$2,
      duration: duration,
    ));
  }

  /// Editing one side of the size, carrying the other with it when locked.
  void _setSize({int? width, int? height}) {
    setState(() {
      if (width != null) {
        final ratio = _height / _width;
        _width = width;
        if (_locked) _height = (width * ratio).round().clamp(16, 16384);
      }
      if (height != null) {
        final ratio = _width / _height;
        _height = height;
        if (_locked) _width = (height * ratio).round().clamp(16, 16384);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return FloatSurface(
      width: 344,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              widget.title,
              style: t.bodyPrimary,
              textAlign: TextAlign.center,
            ),
          ),
          _row(
            t,
            'Name',
            Expanded(
              child: HouseTextField(
                key: const ValueKey('comp-name'),
                controller: _name,
                width: double.infinity,
                onSubmitted: (_) => _confirm(),
              ),
            ),
          ),
          _row(t, 'Size', _sizeRow(t)),
          _row(t, 'Frame rate', _rateRow(t)),
          _row(
            t,
            'Duration',
            Expanded(
              child: HouseTextField(
                key: const ValueKey('comp-duration'),
                controller: _duration,
                width: double.infinity,
                onSubmitted: (_) => _confirm(),
              ),
            ),
          ),
          Padding(
            // Indented to the field column, not the label column: it explains
            // the box above it, so it lines up with that box.
            padding: const EdgeInsets.only(left: _labelWidth, top: 4, bottom: 10),
            child: Text('Duration is HH:MM:SS.mmm.', style: t.caption),
          ),
          Row(
            children: [
              HouseButton(
                key: const ValueKey('comp-apply'),
                onPressed: _confirm,
                child: Text(widget.confirm),
              ),
              const SizedBox(width: 8),
              HouseButton(
                key: const ValueKey('comp-cancel'),
                onPressed: widget.onCancel,
                child: const Text('Cancel'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _sizeRow(LumitTheme t) => Expanded(
        child: Row(
          children: [
            Expanded(
              child: DragValueField(
                key: const ValueKey('comp-width'),
                value: _width,
                min: 16,
                max: 16384,
                fill: t.surface0,
                onChanged: (v) => _setSize(width: v.toInt()),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text('×', style: t.small),
            ),
            Expanded(
              child: DragValueField(
                key: const ValueKey('comp-height'),
                value: _height,
                min: 16,
                max: 16384,
                fill: t.surface0,
                onChanged: (v) => _setSize(height: v.toInt()),
              ),
            ),
            const SizedBox(width: 6),
            LumitTooltip(
              message: _locked
                  ? 'Keep the aspect ratio — click to unlock'
                  : 'Aspect ratio unlocked — click to keep it',
              child: HouseButton(
                key: const ValueKey('comp-size-lock'),
                small: true,
                onPressed: () => setState(() => _locked = !_locked),
                child: lumitIcon(
                  _locked ? LumitIcon.lock : LumitIcon.unlock,
                  size: 12,
                  color: _locked ? t.accent : t.textMuted,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              aspectRatioLabel(_width, _height),
              key: const ValueKey('comp-aspect'),
              style: t.small,
            ),
          ],
        ),
      );

  Widget _rateRow(LumitTheme t) => Expanded(
        child: Row(
          children: [
            Expanded(
              child: HouseTextField(
                key: const ValueKey('comp-fps'),
                controller: _fps,
                width: double.infinity,
                onSubmitted: (_) => _confirm(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text('fps', style: t.small),
            ),
            BareDropdown<String>(
              key: const ValueKey('comp-fps-presets'),
              // A rate of one's own reads as "Custom" rather than as an empty
              // invitation: the list is where you *change* the rate, and what it
              // shows is what the field beside it currently says.
              value: _presetLabel ?? 'Custom',
              options: [..._ratePresets.map((p) => p.$1)],
              label: (s) => s,
              onChanged: (picked) => setState(() => _fps.text = picked),
            ),
          ],
        ),
      );

  Widget _row(LumitTheme t, String label, Widget field) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            SizedBox(width: _labelWidth, child: Text(label, style: t.small)),
            field,
          ],
        ),
      );
}

/// A rate as one number: `60`, `23.976`. Trailing zeros are dropped, so the
/// ordinary rates read as ordinary numbers.
String _formatRate(int num, int den) {
  if (den <= 0) return '$num';
  if (num % den == 0) return '${num ~/ den}';
  final decimal = (num / den).toStringAsFixed(3);
  return decimal.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}

/// A typed rate as the exact `(num, den)` pair the engine stores.
///
/// The NTSC family is matched by name rather than derived, because 23.976 is a
/// *rounding* of 24000/1001 and no amount of arithmetic on the rounded number
/// gets the exact rate back. Anything else is read on the thousandths grid and
/// reduced, so 12.5 is 25/2 rather than 12500/1000.
(int, int)? parseRate(String text) {
  final value = double.tryParse(text.trim());
  if (value == null || value <= 0 || value > 1000000) return null;
  for (final (label, num, den) in _ratePresets) {
    if ((value - double.parse(label)).abs() < 0.0005) return (num, den);
  }
  const den = 1000;
  final num = (value * den).round();
  final g = _gcd(num, den);
  return (num ~/ g, den ~/ g);
}

/// `HH:MM:SS.mmm` for an exact number of seconds.
String formatDurationHms(BridgeRational seconds) {
  final den = seconds.den.toInt();
  final total = den == 0 ? 0 : (seconds.num.toInt() * 1000 / den).round();
  final ms = total % 1000;
  final s = (total ~/ 1000) % 60;
  final m = (total ~/ 60000) % 60;
  final h = total ~/ 3600000;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(h)}:${two(m)}:${two(s)}.${ms.toString().padLeft(3, '0')}';
}

/// `HH:MM:SS.mmm` back to exact seconds, or null when it is not a time.
///
/// Forgiving about the separator before the milliseconds (a colon is what other
/// editors show, a full stop is what this dialog prints) and about missing
/// leading fields, so `11.892` and `1:30` both read as what they obviously mean.
BridgeRational? parseDurationHms(String text) {
  final match = RegExp(r'^(?:(\d+):)?(?:(\d+):)?(\d+)(?:[.:](\d{1,3}))?$')
      .firstMatch(text.trim());
  if (match == null) return null;
  int part(int group) => int.tryParse(match.group(group) ?? '') ?? 0;
  // With one leading field it is minutes, with two it is hours then minutes —
  // which is how everybody reads "1:30".
  final hours = match.group(2) == null ? 0 : part(1);
  final minutes = match.group(2) == null ? part(1) : part(2);
  final ms = int.tryParse((match.group(4) ?? '').padRight(3, '0')) ?? 0;
  final total = ((hours * 3600 + minutes * 60 + part(3)) * 1000) + ms;
  final g = _gcd(total, 1000);
  return BridgeRational(
    num: (total ~/ (g == 0 ? 1 : g)),
    den: 1000 ~/ (g == 0 ? 1 : g),
  );
}

/// `40 : 17` for 1920 × 816 — the shape, in its smallest whole numbers.
String aspectRatioLabel(int width, int height) {
  final g = _gcd(width, height);
  if (g == 0) return '';
  return '${width ~/ g} : ${height ~/ g}';
}

int _gcd(int a, int b) {
  a = a.abs();
  b = b.abs();
  while (b != 0) {
    final t = a % b;
    a = b;
    b = t;
  }
  return a;
}
