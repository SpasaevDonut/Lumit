// The toolbar: the strip of tools under the menu bar (docs/07 §1.7, K-214).
//
// **In plain terms.** This is the row every editor has under its menus — the
// arrow, the hand, the pen — and picking one of them says what dragging in the
// Viewer will do. Tools that do the same sort of job share a button the way
// After Effects shares them: the button shows the one you last used, and
// holding it (or right-clicking) opens the rest. Pressing the tool's key does
// the same thing without the flyout, and pressing it again steps through the
// group.
//
// **What it does not do.** It arms a tool; it does not perform one. The armed
// tool is one value on [ToolsState] that panels read — today the Viewer changes
// its cursor from it and nothing else, because the drawing, painting and puppet
// behaviours are not built. That is deliberate: the whole tool set is specified
// (docs/07 §1.7) and shipping the strip with the unbuilt ones missing would
// leave no place to put them and no way to see what is coming. A tool that
// changes nothing yet says so in its tooltip.
//
// The right-hand end carries what the shell has nowhere else to put: the
// snapping switch (docs/07 §4.5) and the workspace strip §1.4 asks for.

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../icons/icons.dart';
import '../main.dart';
import '../state/dock.dart';
import '../state/tools.dart';
import '../theme/theme.dart';
import '../widgets/controls.dart';

/// How tall the strip is, and how big one tool button is.
///
/// 15-DESIGN §7.2 puts toolbar controls on the household's full ≥44px hit
/// extent — this is chrome, not a dense surface, so it takes the gate rather
/// than KD-2's dense-surface compensation. The icon inside still draws at the
/// 16px §5 floor; the button is padding around it.
const double toolBarHeight = 44;
const double _toolButtonSize = 44;

/// The tool groups in the order the strip lists them: the pointer tools first,
/// then the ones that draw, then the ones that paint, then the camera — After
/// Effects' own grouping, which is the order the audience already knows.
const List<ToolGroup> toolBarOrder = [
  ToolGroup.select,
  ToolGroup.hand,
  ToolGroup.zoom,
  ToolGroup.rotate,
  ToolGroup.anchor,
  ToolGroup.razor,
  ToolGroup.shape,
  ToolGroup.pen,
  ToolGroup.type,
  ToolGroup.paint,
  ToolGroup.roto,
  ToolGroup.puppet,
  ToolGroup.camera,
];

/// The keymap action that arms each group, for the tooltips' shortcut text.
String _actionFor(ToolGroup group) =>
    toolActions.entries.firstWhere((e) => e.value == group).key;

class LumitToolBarFrb extends StatelessWidget {
  const LumitToolBarFrb({super.key});

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final ui = context.watch<LumitUiState>();
    return Container(
      height: toolBarHeight,
      decoration: BoxDecoration(
        color: t.surface2,
        border: Border(bottom: BorderSide(color: t.hairline)),
      ),
      child: ListenableBuilder(
        listenable: ui.tools,
        builder: (context, _) => Row(
          children: [
            const SizedBox(width: 4),
            // Scrolls rather than overflowing: a narrow window has less width
            // than thirteen tools want, and an overflow stripe is not a design.
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final group in toolBarOrder)
                      _ToolButton(group: group, tools: ui.tools),
                  ],
                ),
              ),
            ),
            const _ToolBarDivider(),
            _SnapButton(tools: ui.tools),
            const _ToolBarDivider(),
            const _WorkspaceStrip(),
            const SizedBox(width: 6),
          ],
        ),
      ),
    );
  }
}

class _ToolBarDivider extends StatelessWidget {
  const _ToolBarDivider();

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return Container(
      width: 1,
      height: 20,
      margin: const EdgeInsets.symmetric(horizontal: 6),
      color: t.hairline,
    );
  }
}

/// One group's button: the member it stands for, armed by a click, with the
/// rest of the group behind a press-and-hold or a right-click.
class _ToolButton extends StatefulWidget {
  final ToolGroup group;
  final ToolsState tools;

  const _ToolButton({required this.group, required this.tools});

  @override
  State<_ToolButton> createState() => _ToolButtonState();
}

class _ToolButtonState extends State<_ToolButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scope = ThemeScope.of(context);
    final t = scope.theme;
    final member = widget.tools.memberOf(widget.group);
    final active = widget.tools.tool.group == widget.group;
    final members = ToolMode.membersOf(widget.group);

    // 15-DESIGN §5's icon states, exactly: secondary at rest, primary on hover,
    // accent when this is the tool in your hand.
    final colour = active
        ? t.accent
        : _hover
            ? t.textPrimary
            : t.textSecondary;

    return LumitTooltip(
      message: _tooltip(context, member, members.length > 1),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => widget.tools.select(member),
          // Both routes to the hidden tools, because both are muscle memory:
          // After Effects opens the flyout on a press-and-hold, and every other
          // toolbar on this machine opens a menu on the right button.
          onLongPress: members.length > 1 ? () => _openFlyout(context) : null,
          onSecondaryTapUp:
              members.length > 1 ? (_) => _openFlyout(context) : null,
          child: AnimatedContainer(
            key: ValueKey<String>('tool-${widget.group.name}'),
            duration: animationDuration(scope.animationLevel),
            width: _toolButtonSize,
            height: _toolButtonSize,
            decoration: BoxDecoration(
              color: active
                  ? t.accent.withValues(alpha: 0.16)
                  : _hover
                      ? t.surface4
                      : null,
              borderRadius: BorderRadius.circular(t.tokens.controlRadius),
            ),
            child: Stack(
              children: [
                Center(
                    child:
                        lumitIcon(member.icon, size: iconSize, color: colour)),
                // The corner mark that says there is more under this button —
                // the same promise After Effects' little triangle makes.
                if (members.length > 1)
                  Positioned(
                    right: 4,
                    bottom: 4,
                    child: CustomPaint(
                      size: const Size(4, 4),
                      painter: _FlyoutMarkPainter(colour),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The tooltip: the tool's name, its shortcut as this machine spells it, and
  /// — for a tool whose behaviour is not built — the plain fact that arming it
  /// changes nothing yet. Saying so is cheaper than a user discovering it by
  /// dragging and getting silence.
  String _tooltip(BuildContext context, ToolMode member, bool hasHidden) {
    final chord =
        context.read<LumitUiState>().keymap.chordFor(_actionFor(widget.group));
    final parts = <String>[
      chord == null ? member.label : '${member.label} ($chord)',
      if (hasHidden) 'Hold or right-click for the rest of the group',
      if (!member.ready) 'Not built yet — arming it changes nothing so far',
    ];
    return parts.join(' · ');
  }

  void _openFlyout(BuildContext context) {
    final box = context.findRenderObject();
    if (box is! RenderBox) return;
    final origin = box.localToGlobal(Offset(0, box.size.height));
    final tools = widget.tools;
    showLumitPopup<ToolMode>(
      context: context,
      position: origin,
      builder: (close) => _ToolFlyout(
        group: widget.group,
        armed: tools.tool,
        onPick: (tool) {
          close(tool);
          tools.select(tool);
        },
      ),
    );
  }
}

/// The hidden tools under a group button.
class _ToolFlyout extends StatelessWidget {
  final ToolGroup group;
  final ToolMode armed;
  final ValueChanged<ToolMode> onPick;

  const _ToolFlyout({
    required this.group,
    required this.armed,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return FloatSurface(
      width: 210,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final member in ToolMode.membersOf(group))
            MenuRow(
              key: ValueKey<String>('tool-flyout-${member.name}'),
              selected: member == armed,
              onPressed: () => onPick(member),
              child: Row(
                children: [
                  lumitIcon(member.icon,
                      size: iconSize,
                      color: member == armed ? t.accent : t.textSecondary),
                  const SizedBox(width: 8),
                  Expanded(child: Text(member.label)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The little triangle in a group button's corner.
class _FlyoutMarkPainter extends CustomPainter {
  final Color colour;
  const _FlyoutMarkPainter(this.colour);

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(size.width, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = colour);
  }

  @override
  bool shouldRepaint(_FlyoutMarkPainter old) => old.colour != colour;
}

/// Snapping, on the toolbar because that is where the switch that applies
/// everywhere goes (docs/07 §4.5).
class _SnapButton extends StatefulWidget {
  final ToolsState tools;
  const _SnapButton({required this.tools});

  @override
  State<_SnapButton> createState() => _SnapButtonState();
}

class _SnapButtonState extends State<_SnapButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final on = widget.tools.snapping;
    final colour = on
        ? t.accent
        : _hover
            ? t.textPrimary
            : t.textSecondary;
    return LumitTooltip(
      message: on ? 'Snapping on' : 'Snapping off',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => widget.tools.snapping = !on,
          child: SizedBox(
            key: const ValueKey('tool-snapping'),
            width: _toolButtonSize,
            height: _toolButtonSize,
            child: Center(
              child: lumitIcon(LumitIcon.magnet, size: iconSize, color: colour),
            ),
          ),
        ),
      ),
    );
  }
}

/// The workspace switcher docs/07 §1.4 requires in the window chrome: the four
/// shipped presets by name, the current one ticked in the accent.
class _WorkspaceStrip extends StatelessWidget {
  const _WorkspaceStrip();

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final ui = context.watch<LumitUiState>();
    final active = ui.workspace.activePreset;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final preset in WorkspacePreset.values)
          LumitTooltip(
            message: 'Arrange the panels for ${preset.title}',
            child: HouseButton(
              key: ValueKey<String>('workspace-${preset.name}'),
              frameless: true,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
              onPressed: () => ui.workspace.applyWorkspacePreset(preset),
              child: Text(
                preset.title,
                style: preset == active
                    ? t.body.copyWith(color: t.accent)
                    : t.body.copyWith(color: t.textSecondary),
              ),
            ),
          ),
      ],
    );
  }
}

/// The pointer the Viewer shows while [tool] is armed.
///
/// The one place the armed tool changes anything today, and it is worth having
/// on its own: a cursor is how a toolbar tells you it is listening, and it
/// costs nothing to be honest about which tools are only a cursor so far.
MouseCursor viewerCursorFor(ToolMode tool) => switch (tool) {
      ToolMode.hand => SystemMouseCursors.grab,
      ToolMode.zoom => SystemMouseCursors.zoomIn,
      ToolMode.razor => SystemMouseCursors.precise,
      ToolMode.anchor => SystemMouseCursors.move,
      _ => tool.group == ToolGroup.shape ||
              tool.group == ToolGroup.pen ||
              tool.group == ToolGroup.type
          ? SystemMouseCursors.precise
          : SystemMouseCursors.basic,
    };
