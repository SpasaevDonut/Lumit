// The Effects & presets panel, on the flutter_rust_bridge API.
//
// Every built-in effect under its category heading, filtered by a search field,
// with the selected layer's `.lumfx` save and load beneath. An effect applies by
// double-click or by dragging it onto the Effect controls panel — the drag
// carries an `EffectDragData`, which is the only thing that produces one.
//
// The list comes from `listEffects`, which is the engine's own schema order, so
// the panel never holds a copy of what effects exist. Adding a built-in to the
// engine puts it here with no Dart change at all.

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/src/rust/api/effect.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';
import 'package:provider/provider.dart';

import '../icons/icons.dart';
import '../state/drag_payloads.dart';
import '../state/file_dialogs.dart';
import '../widgets/controls.dart';

class EffectsPresetsPanelFrb extends StatefulWidget {
  /// The preset file seams, injected by tests so no plugin channel opens.
  final Future<String?> Function()? savePicker;
  final Future<String?> Function()? loadPicker;

  const EffectsPresetsPanelFrb({super.key, this.savePicker, this.loadPicker});

  @override
  State<EffectsPresetsPanelFrb> createState() => _EffectsPresetsPanelFrbState();
}

class _EffectsPresetsPanelFrbState extends State<EffectsPresetsPanelFrb> {
  final TextEditingController _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final ui = Provider.of<LumitUiState>(context);
    final needle = _search.text.trim().toLowerCase();

    // Grouped in schema order, so the headings come out in the order the engine
    // declares rather than alphabetically by accident.
    final grouped = <String, List<BridgeEffectInfo>>{};
    final headings = <String, String>{};
    for (final effect in listEffects()) {
      if (needle.isNotEmpty &&
          !effect.label.toLowerCase().contains(needle) &&
          !effect.categoryLabel.toLowerCase().contains(needle)) {
        continue;
      }
      grouped.putIfAbsent(effect.category, () => []).add(effect);
      headings[effect.category] = effect.categoryLabel;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 26,
          color: t.surface1,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            children: [
              lumitIcon(LumitIcon.star, size: 12, color: t.textMuted),
              const SizedBox(width: 6),
              Expanded(
                child: HouseTextField(
                  key: const ValueKey('fx-search'),
                  controller: _search,
                  width: 160,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: grouped.isEmpty
              ? Center(child: Text('No effects match', style: t.small))
              : ListView(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  children: [
                    for (final entry in grouped.entries) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
                        child: Text(headings[entry.key] ?? entry.key,
                            style: t.small.copyWith(color: t.textMuted)),
                      ),
                      for (final effect in entry.value)
                        _EffectRow(
                          key: ValueKey<String>('fx-item-${effect.name}'),
                          effect: effect,
                          onApply: () => _apply(ui, effect.name),
                        ),
                    ],
                  ],
                ),
        ),
        _PresetBar(
          layer: ui.selectedLayer.value,
          savePicker: widget.savePicker,
          loadPicker: widget.loadPicker,
          onChanged: () => setState(() {}),
        ),
      ],
    );
  }

  /// Apply to the selected layer. With none selected there is nothing to apply
  /// to, and silently doing nothing is better than guessing at a layer.
  void _apply(LumitUiState ui, String name) {
    final layer = ui.selectedLayer.value;
    if (layer == null) return;
    layer.addEffect(name: name);
    setState(() {});
  }
}

class _EffectRow extends StatelessWidget {
  final BridgeEffectInfo effect;
  final VoidCallback onApply;
  const _EffectRow({super.key, required this.effect, required this.onApply});

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final row = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTap: onApply,
      child: Container(
        height: 20,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.centerLeft,
        child: Text(effect.label, style: t.body),
      ),
    );

    return Draggable<EffectDragData>(
      data: EffectDragData(effect.name, effect.label),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: FloatSurface(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Text(effect.label, style: t.small),
        ),
      ),
      child: row,
    );
  }
}

/// Save the selected layer's stack as a `.lumfx`, or load one onto it.
class _PresetBar extends StatelessWidget {
  final LayerReference? layer;
  final Future<String?> Function()? savePicker;
  final Future<String?> Function()? loadPicker;
  final VoidCallback onChanged;

  const _PresetBar({
    required this.layer,
    required this.savePicker,
    required this.loadPicker,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final target = layer;

    return Container(
      height: 26,
      color: t.surface1,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          HouseButton(
            key: const ValueKey('preset-save'),
            small: true,
            frameless: true,
            onPressed: target == null ? null : () => _save(target),
            child: Text('Save preset…', style: t.small),
          ),
          const SizedBox(width: 6),
          HouseButton(
            key: const ValueKey('preset-load'),
            small: true,
            frameless: true,
            onPressed: target == null ? null : () => _load(target),
            child: Text('Load preset…', style: t.small),
          ),
          const Spacer(),
          if (target == null)
            Text('Select a layer', style: t.small.copyWith(color: t.textMuted)),
        ],
      ),
    );
  }

  /// The engine hands back the text; choosing where it goes is the picker's job
  /// and writing it is Dart's, so the engine never opens a file dialogue.
  Future<void> _save(LayerReference target) async {
    final picker = savePicker;
    final path = picker != null
        ? await picker()
        : await pickPresetSaveLocation('preset.lumfx');
    if (path == null) return;
    // The preset's display name is its file's stem, matching the egui frontend.
    final name = path.split(RegExp(r'[/\\]')).last.replaceAll('.lumfx', '');
    File(path).writeAsStringSync(target.savePreset(name: name));
  }

  Future<void> _load(LayerReference target) async {
    final path = await (loadPicker ?? pickPresetToOpen)();
    if (path == null) return;
    final file = File(path);
    if (!file.existsSync()) return;
    try {
      target.loadPreset(text: file.readAsStringSync());
    } catch (_) {
      // Not a preset: the picker will take any file, so this is a normal thing
      // for a user to do and not something to shout about.
      return;
    }
    onChanged();
  }
}
