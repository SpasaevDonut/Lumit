// The toolbar's tools: what they are, which of them is armed, and how a
// keyboard chord picks one (docs/07 §1.7, K-214).
//
// **In plain terms.** A tool is the answer to "what does dragging in the Viewer
// do?" — nudge a layer about, pan the picture, draw a mask, cut a clip. Every
// editor has a strip of them under the menu, and picking one is the whole of
// what this file models: one value, held in one place, that the rest of the app
// reads. Tools that share a job are grouped the way After Effects groups them —
// all five shape tools sit under one button, and the button remembers which of
// the five you last used — so the strip stays short.
//
// Nothing here does any editing. Which tool is armed is a *state*, and the
// panels decide what to make of it; a tool whose behaviour is not built yet is
// still a real, selectable tool that simply changes nothing on the picture yet
// ([ToolMode.ready] says which are which, and the toolbar says so in the
// tooltip rather than hiding the button).

import 'package:flutter/foundation.dart';

import '../icons/icons.dart';

/// A cluster of tools that share one toolbar button, in the order the button's
/// flyout lists them.
///
/// A group with one member is just a button; a group with several is After
/// Effects' hidden-tools flyout — press and hold, or right-click, to see the
/// rest, and the shortcut cycles through them.
enum ToolGroup {
  select,
  hand,
  zoom,
  rotate,
  anchor,
  razor,
  shape,
  pen,
  type,
  paint,
  roto,
  puppet,
  camera,
}

/// One tool.
///
/// [ready] is honest bookkeeping rather than decoration: it says whether
/// choosing this tool changes what a drag does *today*. The toolbar draws the
/// unbuilt ones the same as the rest — they are the specified tool set, not a
/// wish list — and only its tooltip mentions that the behaviour is still to
/// come.
enum ToolMode {
  select(ToolGroup.select, 'Selection', LumitIcon.pointer, ready: true),
  hand(ToolGroup.hand, 'Hand', LumitIcon.move, ready: true),
  zoom(ToolGroup.zoom, 'Zoom', LumitIcon.zoomIn, ready: true),
  rotate(ToolGroup.rotate, 'Rotation', LumitIcon.rotate),
  anchor(ToolGroup.anchor, 'Anchor point', LumitIcon.anchorPoint),
  razor(ToolGroup.razor, 'Razor', LumitIcon.razor),

  // The shape tools draw a mask on the selected layer, or a shape layer with
  // nothing selected — AE's rule, and the reason they are one group.
  shapeRectangle(ToolGroup.shape, 'Rectangle', LumitIcon.rectangle),
  shapeRoundedRectangle(
      ToolGroup.shape, 'Rounded rectangle', LumitIcon.roundedRectangle),
  shapeEllipse(ToolGroup.shape, 'Ellipse', LumitIcon.ellipse),
  shapePolygon(ToolGroup.shape, 'Polygon', LumitIcon.polygon),
  shapeStar(ToolGroup.shape, 'Star', LumitIcon.star),

  pen(ToolGroup.pen, 'Pen', LumitIcon.pen),
  penAddVertex(ToolGroup.pen, 'Add vertex', LumitIcon.vertexAdd),
  penDeleteVertex(ToolGroup.pen, 'Delete vertex', LumitIcon.vertexDelete),
  penConvertVertex(ToolGroup.pen, 'Convert vertex', LumitIcon.vertexConvert),
  penMaskFeather(ToolGroup.pen, 'Mask feather', LumitIcon.maskFeather),

  typeHorizontal(ToolGroup.type, 'Horizontal type', LumitIcon.text),
  typeVertical(ToolGroup.type, 'Vertical type', LumitIcon.textVertical),

  brush(ToolGroup.paint, 'Brush', LumitIcon.brush),
  cloneStamp(ToolGroup.paint, 'Clone stamp', LumitIcon.cloneStamp),
  eraser(ToolGroup.paint, 'Eraser', LumitIcon.eraser),

  rotoBrush(ToolGroup.roto, 'Roto brush', LumitIcon.rotoBrush),
  refineEdge(ToolGroup.roto, 'Refine edge', LumitIcon.refineEdge),

  puppetPosition(ToolGroup.puppet, 'Puppet position pin', LumitIcon.puppetPin),
  puppetStarch(ToolGroup.puppet, 'Puppet starch pin', LumitIcon.puppetStarch),
  puppetOverlap(ToolGroup.puppet, 'Puppet overlap pin', LumitIcon.puppetOverlap),
  puppetBend(ToolGroup.puppet, 'Puppet bend pin', LumitIcon.puppetBend),

  cameraOrbit(ToolGroup.camera, 'Orbit camera', LumitIcon.cameraOrbit),
  cameraPan(ToolGroup.camera, 'Pan camera', LumitIcon.cameraPan),
  cameraDolly(ToolGroup.camera, 'Dolly camera', LumitIcon.cameraDolly);

  const ToolMode(this.group, this.label, this.icon, {this.ready = false});

  /// The toolbar button this tool lives under.
  final ToolGroup group;

  /// What it is called — in tooltips, in the flyout, and in the status line.
  final String label;

  final LumitIcon icon;

  /// Whether arming it changes what a drag does yet.
  final bool ready;

  /// Every tool in [group], in declaration order — which is flyout order.
  static List<ToolMode> membersOf(ToolGroup group) =>
      ToolMode.values.where((m) => m.group == group).toList(growable: false);
}

/// The keymap action each group answers to (docs/07 §15, K-199). The engine
/// owns the chords; this only says which group an action arms, so rebinding a
/// tool in Settings → Keymap moves the shortcut and nothing here changes.
const Map<String, ToolGroup> toolActions = {
  'tool.select': ToolGroup.select,
  'tool.hand': ToolGroup.hand,
  'tool.zoom': ToolGroup.zoom,
  'tool.rotate': ToolGroup.rotate,
  'tool.anchor': ToolGroup.anchor,
  'tool.razor': ToolGroup.razor,
  'tool.shape': ToolGroup.shape,
  'tool.pen': ToolGroup.pen,
  'tool.type': ToolGroup.type,
  'tool.paint': ToolGroup.paint,
  'tool.roto': ToolGroup.roto,
  'tool.puppet': ToolGroup.puppet,
  'tool.camera': ToolGroup.camera,
};

/// Which tool is armed, which member each group would arm, and the toolbar's
/// own switches.
///
/// Session state, deliberately: which tool you had in your hand is not part of
/// the project (nothing about the document changes when you pick one) and not
/// part of the workspace either (a layout is where the panels are). It starts
/// on Selection every time, exactly as After Effects does.
class ToolsState extends ChangeNotifier {
  ToolMode _tool = ToolMode.select;

  /// The armed tool.
  ToolMode get tool => _tool;

  /// The member each group last had armed, so a group button keeps showing the
  /// variant you chose rather than snapping back to the first one.
  final Map<ToolGroup, ToolMode> _lastUsed = {};

  /// Snapping, the toolbar's own toggle (docs/07 §4.5). Held here because it is
  /// the toolbar's switch and applies wherever snapping applies, not to one
  /// panel.
  bool _snapping = true;
  bool get snapping => _snapping;
  set snapping(bool value) {
    if (_snapping == value) return;
    _snapping = value;
    notifyListeners();
  }

  /// Which member of [group] its button currently stands for.
  ToolMode memberOf(ToolGroup group) =>
      _lastUsed[group] ?? ToolMode.membersOf(group).first;

  /// Arm [tool]. Its group remembers it as the member to show.
  void select(ToolMode tool) {
    _lastUsed[tool.group] = tool;
    if (_tool == tool) return;
    _tool = tool;
    notifyListeners();
  }

  /// Arm [group] the way pressing its button does: the member it last had.
  void selectGroup(ToolGroup group) => select(memberOf(group));

  /// Arm [group] the way pressing its *chord* does.
  ///
  /// The AE rule, and the reason this is not the same as [selectGroup]: the
  /// first press arms the group's remembered member, and pressing again while
  /// that group is already armed steps to the next member and round. So `Q`
  /// walks rectangle → rounded rectangle → ellipse → polygon → star → rectangle
  /// without ever opening the flyout.
  void cycleGroup(ToolGroup group) {
    final members = ToolMode.membersOf(group);
    if (_tool.group != group || members.length == 1) {
      selectGroup(group);
      return;
    }
    final next = members[(members.indexOf(_tool) + 1) % members.length];
    select(next);
  }

  /// Run a keymap action if it is one of the toolbar's, and say whether it was.
  bool handleAction(String action) {
    final group = toolActions[action];
    if (group == null) return false;
    cycleGroup(group);
    return true;
  }
}
