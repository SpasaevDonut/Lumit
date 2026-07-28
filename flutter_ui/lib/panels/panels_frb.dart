// The panel dispatcher of the flutter_rust_bridge shell — what `LumitAppNew` in
// main.dart docks.
//
// This routes a Panel to its widget and nothing else; each ported panel lives in
// a file of its own. All seven are ported.
//
// The dispatcher for what remains on the v0 JSON bridge is panels.dart. Panels
// move across as the frb API grows to cover what they need — see docs/TODO.md,
// "Bridge".

import 'package:flutter/widgets.dart';

import '../state/dock.dart';
import 'effect_controls_panel_frb.dart';
import 'effects_presets_panel_frb.dart';
import 'hierarchy_panel_frb.dart';
import 'project_panel_frb.dart';
import 'scopes_panel_frb.dart';
import 'timeline_panel_frb.dart';
import 'viewer_panel_frb.dart';

Widget buildPanelBodyFrb(BuildContext context, Panel panel) => switch (panel) {
      Panel.project => const ProjectPanelFrb(),
      Panel.viewer => const ViewerPanelFrb(),
      Panel.timeline => const TimelinePanelFrb(),
      Panel.effectControls => const EffectControlsPanelFrb(),
      Panel.effectsAndPresets => const EffectsPresetsPanelFrb(),
      Panel.scopes => const ScopesPanelFrb(),
      Panel.hierarchy => const HierarchyPanelFrb(),
    };
