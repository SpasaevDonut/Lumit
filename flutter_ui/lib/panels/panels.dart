// The panel dispatcher: one file per panel (file-length hygiene, K-007 spirit)
// — this module only routes a Panel to its widget. Panels still waiting on a
// phase render the shared PlaceholderPanel naming that phase.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:lumit_flutter/src/rust/api/effect.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';
import 'package:lumit_flutter/widgets/controls.dart';
import 'package:provider/provider.dart';

import '../icons/icons.dart';
import '../state/app_state.dart';
import '../state/dock.dart';
import 'effect_controls_panel.dart';
import 'effects_presets_panel.dart';
import 'hierarchy_panel.dart';
import 'placeholder.dart';
import 'project_panel.dart';
import 'scopes_panel.dart';
import 'timeline_panel.dart';
import 'viewer_panel.dart';

Widget buildPanelBody(BuildContext context, Panel panel) => switch (panel) {
      Panel.project => const ProjectPanel(),
      Panel.viewer => const ViewerPanel(),
      Panel.timeline => const TimelinePanel(),
      Panel.effectControls => const EffectsControlsPanel(),
      Panel.effectsAndPresets => const PlaceholderPanel(
          icon: LumitIcon.star,
          title: 'Effects & presets',
          hint:
              'The searchable effect list and .lumfx presets arrive in phase F4.',
        ),
      Panel.scopes => const PlaceholderPanel(
          icon: LumitIcon.nodes,
          title: 'Scopes',
          hint: 'The composition tree arrives in phase F4.',
        ),
      Panel.hierarchy => const PlaceholderPanel(
          icon: LumitIcon.nodes,
          title: 'Hierarchy',
          hint: 'The composition tree arrives in phase F4.',
        ),
    };

class EffectsControlsPanel extends StatefulWidget {
  const EffectsControlsPanel({super.key});

  @override
  State<EffectsControlsPanel> createState() => _EffectsControlsPanelState();
}

class _EffectsControlsPanelState extends State<EffectsControlsPanel> {
  @override
  Widget build(BuildContext context) {
    var state = Provider.of<LumitUiState>(context);

    if (state.selectedComp == null) return Placeholder();

    return ValueListenableBuilder(
      valueListenable: state.selectedLayer,
      builder: (context, value, child) {
        var effects = value?.getEffects() ?? <BridgeEffectInstance>[];

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Text(
                "${value?.getName()} (${effects.length})",
                style: ThemeScope.of(context).theme.small,
              ),
            ),
            for (int i = 0; i < effects.length; i++)
              EffectEditor(
                effects,
                i,
                key: ValueKey(
                    "effect-editor-${state.selectedComp?.internalid}-${value?.internallayerId}-${effects[i].name()}"),
              ),
          ],
        );
      },
    );
  }
}

class EffectEditor extends StatefulWidget {
  const EffectEditor(this.effects, this.index, {super.key});
  final List<BridgeEffectInstance> effects;

  final int index;
  @override
  State<EffectEditor> createState() => _EffectEditorState();
}

class _EffectEditorState extends State<EffectEditor> {
  late List<BridgeEffectInstance> effects;
  Map<String, double> values = {};
  DateTime lastUpdate = DateTime.now();

  @override
  void initState() {
    effects = widget.effects;
    var effect = effects[widget.index];

    for (var p in effects[widget.index].getParameters()) {
      values[p] = effect.getValue(id: p);
    }

    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    var effect = effects[widget.index];

    return Column(
      children: [
        Text(
          effect.name(),
          style: ThemeScope.of(context).theme.small,
        ),
        for (var p in effect.getParameters())
          Row(
            children: [
              Text(
                p,
                style: ThemeScope.of(context).theme.mono,
              ),
              DragValueField(
                value: values[p] ?? 0.0,
                min: 0,
                max: 200,
                onChanged: (value) {},
                onChangeLive: (value) {
                  print("Live Change: ${value}");

                  setState(() {
                    values[p] = value.toDouble();
                  });

                  var diff = (DateTime.now().millisecondsSinceEpoch -
                          lastUpdate.millisecondsSinceEpoch)
                      .abs();

                  if (diff > 20) {
                    print("Diff: $diff");
                    doPreview();
                  }
                },
                onChangeEnd: (value) {
                  //TODO: commit change to document
                },
              )
            ],
          ),
      ],
    );
  }

  void doPreview() {
    var override = effects;
    lastUpdate = DateTime.now();
    var state = Provider.of<LumitState>(context, listen: false);
    var UIstate = Provider.of<LumitUiState>(context, listen: false);

    for (var p in values.keys) {
      override[widget.index].setValue(id: p, value: values[p] ?? 0.0);
    }

    UIstate.selectedComp!.renderFrameWithPreview(
        frame: BigInt.from(161),
        layer: UIstate.selectedLayer.value!,
        effects: override);

    effects = UIstate.selectedLayer.value!.getEffects();
  }
}

class ViewerPanel extends StatefulWidget {
  const ViewerPanel({super.key});

  @override
  State<ViewerPanel> createState() => _ViewerPanelState();
}

class _ViewerPanelState extends State<ViewerPanel> {
  @override
  Widget build(BuildContext context) {
    var state = Provider.of<LumitUiState>(context);

    return ValueListenableBuilder(
      valueListenable: state.viewerFrameid,
      builder: (context, value, child) {
        if (value == null) return Placeholder();

        return Texture(textureId: value);
      },
    );
  }
}

class TimelinePanel extends StatefulWidget {
  const TimelinePanel({super.key});

  @override
  State<TimelinePanel> createState() => _TimelinePanelState();
}

class _TimelinePanelState extends State<TimelinePanel> {
  int frame = 161;

  @override
  Widget build(BuildContext context) {
    var state = Provider.of<LumitUiState>(context);
    var comp = state.selectedComp;

    if (comp == null) return const Placeholder();

    var layers = comp.getLayers();

    final t = ThemeScope.of(context).theme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            spacing: 8,
            children: [
              HouseButton(
                frameless: false,
                child: Text(
                  "Render Frame:",
                  style: t.small,
                ),
                onPressed: () {
                  print(
                      "Rendering frame: $frame for comp: ${state.selectedComp}");
                  state.selectedComp?.renderFrame(frame: BigInt.from(frame));
                },
              ),
              DragValueField(
                value: frame,
                min: 0,
                max: 500,
                onChanged: (value) {
                  setState(() {
                    frame = value.toInt();
                  });
                },
              )
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: layers.length,
            itemBuilder: (context, index) {
              var layer = layers[index];
              return HouseButton(
                child: Text(
                  layer.getName(),
                  style: t.small,
                ),
                onPressed: () {
                  state.selectedLayer.value = layer;
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
