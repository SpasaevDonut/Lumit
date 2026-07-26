// The Composition settings dialog, on the frb API.
//
// Reached from the menu bar's Composition ▸ Composition settings…, and from the
// Project panel's context menu. The v0 dialog took an `AppStateStub`, which is why
// the ported Project panel had to drop that entry; this one takes a
// `CompositionReference`, so anything holding one can open it.
//
// The frame rate is edited as a `num`/`den` pair, not as a decimal. That is not
// pedantry: 29.97 fps is 30000/1001, and a field that parsed "29.97" into a double
// could not give that back (docs/14 §2, rational time). The common rates are
// offered as presets so nobody has to know that, with the pair editable underneath
// for anything else.

import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';

import '../theme/theme.dart';
import '../widgets/controls.dart';

/// The frame rates worth one click. `1001` denominators are the NTSC family.
const List<(String, int, int)> _ratePresets = [
  ('23.976', 24000, 1001),
  ('24', 24, 1),
  ('25', 25, 1),
  ('29.97', 30000, 1001),
  ('30', 30, 1),
  ('50', 50, 1),
  ('59.94', 60000, 1001),
  ('60', 60, 1),
];

/// Show the dialog for [comp]. Returns true when settings were applied, so the
/// caller can refresh; false when cancelled.
Future<bool> showCompSettingsFrb({
  required BuildContext context,
  required CompositionReference comp,
}) async {
  final applied = await showLumitModal<bool>(
    context: context,
    builder: (close) => _CompSettingsBody(comp: comp, close: close),
  );
  return applied ?? false;
}

class _CompSettingsBody extends StatefulWidget {
  final CompositionReference comp;
  final void Function(bool?) close;
  const _CompSettingsBody({required this.comp, required this.close});

  @override
  State<_CompSettingsBody> createState() => _CompSettingsBodyState();
}

class _CompSettingsBodyState extends State<_CompSettingsBody> {
  late final TextEditingController _name;
  late int _width;
  late int _height;
  late int _fpsNum;
  late int _fpsDen;
  late int _durationFrames;

  @override
  void initState() {
    super.initState();
    // Seeded from the engine, so the dialog always opens on the truth rather than
    // on whatever Dart last remembered.
    final s = widget.comp.getSettings();
    _name = TextEditingController(text: s.name);
    _width = s.width;
    _height = s.height;
    _fpsNum = s.fpsNum;
    _fpsDen = s.fpsDen;
    _durationFrames = s.durationFrames;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// The preset label for the current pair, or null when it is a custom rate.
  String? get _presetLabel => _ratePresets
      .where((p) => p.$2 == _fpsNum && p.$3 == _fpsDen)
      .map((p) => p.$1)
      .firstOrNull;

  void _apply() {
    widget.comp.setSettings(
      settings: BridgeCompSettings(
        name: _name.text.trim().isEmpty ? 'Comp' : _name.text.trim(),
        width: _width,
        height: _height,
        fpsNum: _fpsNum,
        fpsDen: _fpsDen,
        durationFrames: _durationFrames,
      ),
    );
    widget.close(true);
  }

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return FloatSurface(
      width: 340,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Composition settings', style: t.bodyPrimary),
          const SizedBox(height: 10),
          _row(
            t,
            'Name',
            SizedBox(
              width: 180,
              child: HouseTextField(
                key: const ValueKey('comp-name'),
                controller: _name,
              ),
            ),
          ),
          _row(
            t,
            'Width',
            DragValueField(
              key: const ValueKey('comp-width'),
              value: _width,
              min: 16,
              max: 16384,
              onChanged: (v) => setState(() => _width = v.toInt()),
            ),
          ),
          _row(
            t,
            'Height',
            DragValueField(
              key: const ValueKey('comp-height'),
              value: _height,
              min: 16,
              max: 16384,
              onChanged: (v) => setState(() => _height = v.toInt()),
            ),
          ),
          _row(
            t,
            'Frame rate',
            BareDropdown<String>(
              key: const ValueKey('comp-fps'),
              value: _presetLabel ?? 'Custom',
              options: [..._ratePresets.map((p) => p.$1), 'Custom'],
              label: (s) => s,
              onChanged: (picked) {
                final preset =
                    _ratePresets.where((p) => p.$1 == picked).firstOrNull;
                if (preset == null) return; // 'Custom' keeps the current pair.
                setState(() {
                  _fpsNum = preset.$2;
                  _fpsDen = preset.$3;
                });
              },
            ),
          ),
          // The exact pair, always visible, so a rate with no preset is still
          // reachable and the chosen one is never a mystery.
          _row(
            t,
            'Rate (num/den)',
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                DragValueField(
                  key: const ValueKey('comp-fps-num'),
                  value: _fpsNum,
                  min: 1,
                  max: 1000000,
                  onChanged: (v) => setState(() => _fpsNum = v.toInt()),
                ),
                const SizedBox(width: 4),
                Text('/', style: t.small),
                const SizedBox(width: 4),
                DragValueField(
                  key: const ValueKey('comp-fps-den'),
                  value: _fpsDen,
                  min: 1,
                  max: 100000,
                  onChanged: (v) => setState(() => _fpsDen = v.toInt()),
                ),
              ],
            ),
          ),
          _row(
            t,
            'Duration (frames)',
            DragValueField(
              key: const ValueKey('comp-duration'),
              value: _durationFrames,
              min: 1,
              max: 1000000,
              onChanged: (v) => setState(() => _durationFrames = v.toInt()),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              HouseButton(
                key: const ValueKey('comp-cancel'),
                onPressed: () => widget.close(false),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              HouseButton(
                key: const ValueKey('comp-apply'),
                onPressed: _apply,
                child: const Text('Apply'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _row(LumitTheme t, String label, Widget field) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Expanded(child: Text(label, style: t.small)),
            field,
          ],
        ),
      );
}
