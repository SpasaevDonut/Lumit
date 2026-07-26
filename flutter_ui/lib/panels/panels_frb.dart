// The panel dispatcher of the flutter_rust_bridge shell — what `LumitAppNew` in
// main.dart docks.
//
// This routes a Panel to its widget and nothing else; each ported panel lives in
// a file of its own. Project, Viewer, Timeline and Effect controls are here;
// Effects & presets, Scopes and Hierarchy are still placeholders.
//
// The dispatcher for what remains on the v0 JSON bridge is panels.dart. Panels
// move across as the frb API grows to cover what they need — see docs/TODO.md,
// "Bridge".

import 'package:flutter/widgets.dart';

import '../icons/icons.dart';
import '../state/dock.dart';
import 'effect_controls_panel_frb.dart';
import 'placeholder.dart';
import 'project_panel_frb.dart';
import 'timeline_panel_frb.dart';
import 'viewer_panel_frb.dart';

Widget buildPanelBodyFrb(BuildContext context, Panel panel) => switch (panel) {
      Panel.project => const ProjectPanelFrb(),
      Panel.viewer => const ViewerPanelFrb(),
      Panel.timeline => const TimelinePanelFrb(),
      Panel.effectControls => const EffectControlsPanelFrb(),
      Panel.effectsAndPresets => const PlaceholderPanel(
          icon: LumitIcon.star,
          title: 'Effects & presets',
          hint: 'Not yet ported to the frb bridge.',
        ),
      Panel.scopes => const PlaceholderPanel(
          icon: LumitIcon.nodes,
          title: 'Scopes',
          hint: 'Not yet ported to the frb bridge.',
        ),
      Panel.hierarchy => const PlaceholderPanel(
          icon: LumitIcon.nodes,
          title: 'Hierarchy',
          hint: 'Not yet ported to the frb bridge.',
        ),
    };

