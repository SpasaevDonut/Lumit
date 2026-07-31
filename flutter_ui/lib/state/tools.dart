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
import 'package:lumit_flutter/src/rust/api/assets.dart';

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
  rotate(ToolGroup.rotate, 'Rotation', LumitIcon.rotate, ready: true),
  anchor(ToolGroup.anchor, 'Anchor point', LumitIcon.anchorPoint, ready: true),
  razor(ToolGroup.razor, 'Razor', LumitIcon.razor, ready: true),

  // The shape tools draw a mask on the selected layer, or a shape layer with
  // nothing selected — AE's rule, and the reason they are one group. The shape
  // layer half needs an engine layer kind that does not exist (K-220), so with
  // nothing selected they say so rather than acting.
  shapeRectangle(ToolGroup.shape, 'Rectangle', LumitIcon.rectangle,
      ready: true),
  shapeRoundedRectangle(
      ToolGroup.shape, 'Rounded rectangle', LumitIcon.roundedRectangle,
      ready: true),
  shapeEllipse(ToolGroup.shape, 'Ellipse', LumitIcon.ellipse, ready: true),
  shapePolygon(ToolGroup.shape, 'Polygon', LumitIcon.polygon, ready: true),
  shapeStar(ToolGroup.shape, 'Star', LumitIcon.star, ready: true),

  // The Pen builds a mask path point by point (K-221). Its four siblings edit a
  // *finished* path, which is not built.
  pen(ToolGroup.pen, 'Pen', LumitIcon.pen, ready: true),
  penAddVertex(ToolGroup.pen, 'Add vertex', LumitIcon.vertexAdd),
  penDeleteVertex(ToolGroup.pen, 'Delete vertex', LumitIcon.vertexDelete),
  penConvertVertex(ToolGroup.pen, 'Convert vertex', LumitIcon.vertexConvert),
  penMaskFeather(ToolGroup.pen, 'Mask feather', LumitIcon.maskFeather),

  // Making and editing text layers on the picture (K-223). Vertical type would
  // need the engine to lay a line out downwards; it lays out one horizontal
  // line, so that member stays unbuilt.
  typeHorizontal(ToolGroup.type, 'Horizontal type', LumitIcon.text,
      ready: true),
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

  // Moving the composition's active camera by dragging on the picture
  // (K-227): orbit round what it is looking at, track across, dolly in.
  cameraOrbit(ToolGroup.camera, 'Orbit camera', LumitIcon.cameraOrbit,
      ready: true),
  cameraPan(ToolGroup.camera, 'Track camera', LumitIcon.cameraPan, ready: true),
  cameraDolly(ToolGroup.camera, 'Dolly camera', LumitIcon.cameraDolly,
      ready: true);

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

  /// The members of [group] that do something today (K-226). Empty for a group
  /// nothing in which is built, which is what makes its button disabled.
  static List<ToolMode> builtMembersOf(ToolGroup group) =>
      membersOf(group).where((m) => m.ready).toList(growable: false);
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

/// A colour the toolbar holds, in the document's own scene-linear channels — the
/// same numbers a fill crosses the bridge as, so nothing is converted twice
/// (K-223).
@immutable
class ToolColour {
  final double r;
  final double g;
  final double b;

  const ToolColour(this.r, this.g, this.b);

  static const ToolColour white = ToolColour(1, 1, 1);
  static const ToolColour black = ToolColour(0, 0, 0);

  @override
  bool operator ==(Object other) =>
      other is ToolColour && other.r == r && other.g == g && other.b == b;

  @override
  int get hashCode => Object.hash(r, g, b);
}

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

  /// The **fill** the drawing tools use: the colour new text is set in (K-223),
  /// and the colour a shape layer's fill will take once there are shape layers.
  ToolColour _fill = ToolColour.white;
  ToolColour get fill => _fill;
  set fill(ToolColour value) {
    if (_fill == value) return;
    _fill = value;
    notifyListeners();
  }

  /// The fill as the bridge wants it. Opaque: a fill's transparency is the
  /// layer's Opacity, which is a transform property and animatable, rather than
  /// a fourth number hidden in a swatch.
  BridgeColourRgba get fillRgba =>
      BridgeColourRgba(r: _fill.r, g: _fill.g, b: _fill.b, a: 1);

  /// The point size new text is set at.
  double _textSize = 72;
  double get textSize => _textSize;
  set textSize(double value) {
    final next = value.clamp(1.0, 2000.0);
    if (_textSize == next) return;
    _textSize = next;
    notifyListeners();
  }

  /// The **stroke** the drawing tools would use, and its width in pixels.
  ///
  /// Held, shown and remembered — and nothing reads them yet. A stroke needs
  /// something to draw it round: a shape layer's outline or a paint stroke,
  /// neither of which the engine has (docs/TODO.md). The toolbar draws both
  /// controls disabled rather than pretending, for the same reason
  /// [ToolMode.ready] exists.
  ToolColour _stroke = ToolColour.black;
  ToolColour get stroke => _stroke;
  set stroke(ToolColour value) {
    if (_stroke == value) return;
    _stroke = value;
    notifyListeners();
  }

  double _strokeWidth = 2;
  double get strokeWidth => _strokeWidth;
  set strokeWidth(double value) {
    final next = value.clamp(0.0, 1000.0);
    if (_strokeWidth == next) return;
    _strokeWidth = next;
    notifyListeners();
  }

  /// Which member of [group] its button currently stands for.
  ///
  /// The first *built* one where there is one, so a group with a working tool
  /// under a not-yet-built first member (the Pen's editing siblings, vertical
  /// type) opens on the one that works.
  ToolMode memberOf(ToolGroup group) =>
      _lastUsed[group] ??
      (ToolMode.builtMembersOf(group).firstOrNull ??
          ToolMode.membersOf(group).first);

  /// Arm [tool], if it is a tool that does anything (K-226).
  ///
  /// A tool whose behaviour is not built cannot be armed — by click, by flyout
  /// or by chord. It stays on the strip, drawn disabled, because the tool set
  /// *is* the specification and a missing button teaches the wrong shape of the
  /// application; but arming one would have handed the user a pointer that does
  /// nothing, which is worse than a button that visibly cannot be pressed.
  void select(ToolMode tool) {
    if (!tool.ready) return;
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
    // Only the built ones are in the walk (K-226): a chord that stepped onto a
    // tool that does nothing would be a chord that appears to do nothing.
    final members = ToolMode.builtMembersOf(group);
    if (members.isEmpty) return;
    if (_tool.group != group || members.length == 1) {
      selectGroup(group);
      return;
    }
    final at = members.indexOf(_tool);
    select(members[at < 0 ? 0 : (at + 1) % members.length]);
  }

  /// Run a keymap action if it is one of the toolbar's, and say whether it was.
  bool handleAction(String action) {
    final group = toolActions[action];
    if (group == null) return false;
    cycleGroup(group);
    return true;
  }
}
