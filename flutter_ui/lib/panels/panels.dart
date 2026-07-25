// The panel dispatcher: one file per panel (file-length hygiene, K-007 spirit)
// — this module only routes a Panel to its widget. Panels still waiting on a
// phase render the shared PlaceholderPanel naming that phase.

import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/main.dart';
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
      Panel.effectControls => const PlaceholderPanel(
          icon: LumitIcon.fx,
          title: 'Effect controls',
          hint:
              'Transform and effect property rows arrive in phase F4; select a layer to edit it here.',
        ),
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
              );
            },
          ),
        ),
      ],
    );
  }
}
