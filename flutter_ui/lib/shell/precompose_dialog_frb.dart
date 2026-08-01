// The Pre-compose dialog (Ctrl+Shift+C / layer.precompose).
//
// Prompts the user before creating a new intermediate composition from one or
// more selected layers. Remembers attribute mode, duration adjustment, and
// open new comp choices in the workspace settings.

import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';
import 'package:lumit_flutter/src/rust/api/project_item.dart';

import '../main.dart';
import '../state/workspace.dart';
import '../widgets/controls.dart';

bool _isPrecomposeShowing = false;

/// Show the Pre-compose dialogue and execute precompose on confirm.
Future<void> showPrecomposeDialogFrb({
  required BuildContext context,
  required CompositionReference comp,
  required List<LayerReference> selectedLayers,
  required LumitUiState ui,
  required Workspace workspace,
}) async {
  var layers = selectedLayers;
  if (layers.isEmpty && ui.selectedLayer.value != null) {
    layers = [ui.selectedLayer.value!];
  }
  if (layers.isEmpty) return;
  if (_isPrecomposeShowing) return;

  _isPrecomposeShowing = true;

  try {
    final compInfo = comp.getSettings();
    final parentCompName = compInfo.name;
    final firstLayerName = layers.first.getName();

    final defaultName = layers.length == 1
        ? '$firstLayerName Comp 1'
        : 'Clips Comp 1';

    await showLumitModal<void>(
      context: context,
      builder: (close) => _PrecomposeBody(
        parentCompName: parentCompName,
        firstLayerName: firstLayerName,
        selectedCount: layers.length,
        defaultName: defaultName,
        initialMoveAttributes: workspace.precomposeMoveAttributes,
        initialAdjustDuration: workspace.precomposeAdjustDuration,
        initialOpenNewComp: workspace.precomposeOpenNewComp,
        onConfirm: (name, moveAttributes, adjustDuration, openNewComp) async {
          // Save user's working preferences for precompose
          workspace.setPrecomposeSettings(
            moveAttributes: moveAttributes,
            adjustDuration: adjustDuration,
            openNewComp: openNewComp,
          );

          final layerIds = layers.map((l) => l.internallayerId).toList();
          final leaveAttributes = !moveAttributes && layers.length == 1;

          final newPrecompLayer = comp.precompose(
            layerIds: layerIds,
            name: name,
            leaveAttributes: leaveAttributes,
            adjustDuration: adjustDuration,
          );

          ui.setSelection([newPrecompLayer]);
          ui.notifyListeners();

          if (openNewComp) {
            final sourceItem = newPrecompLayer.getSourceItem();
            if (sourceItem case ItemReference_Composition(:final field0)) {
              ui.setSelectedComp(field0);
            }
          }
          close(null);
        },
        onCancel: () => close(null),
      ),
    );
  } finally {
    _isPrecomposeShowing = false;
  }
}

class _PrecomposeBody extends StatefulWidget {
  final String parentCompName;
  final String firstLayerName;
  final int selectedCount;
  final String defaultName;
  final bool initialMoveAttributes;
  final bool initialAdjustDuration;
  final bool initialOpenNewComp;
  final void Function(
    String name,
    bool moveAttributes,
    bool adjustDuration,
    bool openNewComp,
  ) onConfirm;
  final VoidCallback onCancel;

  const _PrecomposeBody({
    required this.parentCompName,
    required this.firstLayerName,
    required this.selectedCount,
    required this.defaultName,
    required this.initialMoveAttributes,
    required this.initialAdjustDuration,
    required this.initialOpenNewComp,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  State<_PrecomposeBody> createState() => _PrecomposeBodyState();
}

class _PrecomposeBodyState extends State<_PrecomposeBody> {
  late final TextEditingController _nameController;
  late bool _moveAttributes;
  late bool _adjustDuration;
  late bool _openNewComp;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.defaultName);
    // If >1 layers are selected, "Leave attributes" is impossible, so force move
    _moveAttributes = widget.selectedCount > 1 ? true : widget.initialMoveAttributes;
    _adjustDuration = widget.initialAdjustDuration;
    _openNewComp = widget.initialOpenNewComp;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameController.text.trim().isEmpty
        ? widget.defaultName
        : _nameController.text.trim();
    widget.onConfirm(name, _moveAttributes, _adjustDuration, _openNewComp);
  }

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final isSingleLayer = widget.selectedCount == 1;

    return FloatSurface(
      width: 440,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header with Title and Close button
          Padding(
            padding: const EdgeInsets.only(left: 12, top: 8, right: 8, bottom: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Pre-compose',
                    style: t.bodyPrimary.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onCancel,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Text('✕', style: t.small.copyWith(color: t.textMuted)),
                  ),
                ),
              ],
            ),
          ),

          // Name row
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Text(
                  'New composition name:',
                  style: t.small,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: HouseTextField(
                    key: const ValueKey('precompose-name-input'),
                    controller: _nameController,
                    width: double.infinity,
                    autofocus: true,
                    onSubmitted: (_) => _submit(),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Radio option 1: Leave all attributes
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: isSingleLayer
                  ? () => setState(() => _moveAttributes = false)
                  : null,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      HouseRadio(
                        key: const ValueKey('precompose-radio-leave'),
                        selected: !_moveAttributes,
                        enabled: isSingleLayer,
                        onChanged: () => setState(() => _moveAttributes = false),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          "Leave all attributes in '${widget.parentCompName}'",
                          style: t.small.copyWith(
                            color: isSingleLayer ? t.textPrimary : t.textMuted,
                          ),
                        ),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 22, top: 4),
                    child: Text(
                      "Use this option to create a new intermediate composition with only "
                      "'${widget.firstLayerName}' in it. The new composition will become the "
                      "source to the current layer.",
                      style: t.caption.copyWith(
                        color: isSingleLayer ? t.textMuted : t.textMuted.withOpacity(0.5),
                        height: 1.3,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Radio option 2: Move all attributes
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _moveAttributes = true),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      HouseRadio(
                        key: const ValueKey('precompose-radio-move'),
                        selected: _moveAttributes,
                        enabled: true,
                        onChanged: () => setState(() => _moveAttributes = true),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Move all attributes into the new composition',
                          style: t.small.copyWith(color: t.textPrimary),
                        ),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 22, top: 4),
                    child: Text(
                      'Use this option to place the currently selected layers together into '
                      'a new intermediate composition.',
                      style: t.caption.copyWith(color: t.textMuted, height: 1.3),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 12),

          // Checkbox 1: Adjust duration
          Padding(
            padding: const EdgeInsets.only(left: 38, right: 16),
            child: Row(
              children: [
                HouseCheckbox(
                  key: const ValueKey('precompose-checkbox-adjust-duration'),
                  value: _adjustDuration,
                  onChanged: (v) => setState(() => _adjustDuration = v),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => _adjustDuration = !_adjustDuration),
                    child: Text(
                      'Adjust composition duration to the time span of the selected layers',
                      style: t.small,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 8),

          // Checkbox 2: Open New Composition
          Padding(
            padding: const EdgeInsets.only(left: 16, right: 16),
            child: Row(
              children: [
                HouseCheckbox(
                  key: const ValueKey('precompose-checkbox-open-new-comp'),
                  value: _openNewComp,
                  onChanged: (v) => setState(() => _openNewComp = v),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => _openNewComp = !_openNewComp),
                    child: Text(
                      'Open New Composition',
                      style: t.small,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // Bottom Actions (OK and Cancel)
          Padding(
            padding: const EdgeInsets.only(left: 16, right: 16, bottom: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                HouseButton(
                  key: const ValueKey('precompose-confirm-ok'),
                  onPressed: _submit,
                  child: Text('OK', style: t.small),
                ),
                const SizedBox(width: 8),
                HouseButton(
                  key: const ValueKey('precompose-cancel'),
                  onPressed: widget.onCancel,
                  child: Text('Cancel', style: t.small),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
