// House controls, owned rather than Material (docs/archive/flutter-port/04): every
// colour and metric reads the theme, idle widgets are borderless, hover and
// press bring an edge back (the K-084 owner amendment).

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../state/workspace.dart';
import '../theme/theme.dart';

/// The theme + workspace scope: an InheritedNotifier the whole tree reads.
class ThemeScope extends InheritedWidget {
  final LumitTheme theme;
  final AnimationLevel animationLevel;
  final bool showTooltips;

  const ThemeScope({
    super.key,
    required this.theme,
    required this.animationLevel,
    required this.showTooltips,
    required super.child,
  });

  static ThemeScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ThemeScope>()!;

  @override
  bool updateShouldNotify(ThemeScope old) =>
      old.theme != theme ||
      old.animationLevel != animationLevel ||
      old.showTooltips != showTooltips;
}

/// A borderless hover-reactive button: idle `surface3` fill (or nothing when
/// `frameless`), hover `surface4` + strong hairline, press strong fill +
/// accent edge — the egui widget-state table.
class HouseButton extends StatefulWidget {
  final Widget child;
  final VoidCallback? onPressed;
  final bool frameless;
  final bool small;
  final EdgeInsets? padding;

  /// The default action of the window it sits in — what `Enter` presses
  /// (K-243). Drawn with the accent edge it would otherwise only get under the
  /// pointer, which is what docs/15 §2 keeps the one accent for.
  final bool primary;

  const HouseButton({
    super.key,
    required this.child,
    this.onPressed,
    this.frameless = false,
    this.small = false,
    this.padding,
    this.primary = false,
  });

  @override
  State<HouseButton> createState() => _HouseButtonState();
}

class _HouseButtonState extends State<HouseButton> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final scope = ThemeScope.of(context);
    final t = scope.theme;
    final enabled = widget.onPressed != null;
    Color? fill;
    Color? edge;
    if (!enabled) {
      fill = widget.frameless ? null : t.surface2;
    } else if (_down) {
      fill = t.hairlineStrong;
      edge = t.accent;
    } else if (_hover) {
      fill = t.surface4;
      edge = t.hairlineStrong;
    } else {
      fill = widget.frameless ? null : t.surface3;
      if (widget.primary) edge = t.accent;
    }
    final pad = widget.padding ??
        (widget.small
            ? const EdgeInsets.symmetric(horizontal: 5, vertical: 2)
            : const EdgeInsets.symmetric(horizontal: 8, vertical: 3));
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _down = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => setState(() => _down = true) : null,
        onTapUp: enabled ? (_) => setState(() => _down = false) : null,
        onTapCancel: enabled ? () => setState(() => _down = false) : null,
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: animationDuration(scope.animationLevel),
          padding: pad,
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(t.tokens.controlRadius),
            // Always a border, transparent when there is nothing to show. A
            // BoxDecoration's border insets its child, so appearing on hover
            // grew the control by 2 px each way and nudged everything beside
            // it — the whole row visibly shifting as the pointer crossed it.
            border:
                Border.all(color: edge ?? const Color(0x00000000), width: 1),
          ),
          child: DefaultTextStyle(
            style: enabled
                ? t.bodyPrimary
                : t.body.copyWith(color: t.textDisabled),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// One row in a dropdown/menu popup.
class MenuRow extends StatefulWidget {
  final Widget child;
  final VoidCallback onPressed;
  final bool selected;

  /// What this row calls itself in its surface's hover state, for the rows that
  /// have to know which of them the pointer is over. Defaults to the row's own
  /// state; [SubmenuRow] passes its own, because the flyout belongs to the
  /// submenu row rather than to the plain row it draws itself with.
  final Object? hoverId;

  const MenuRow({
    super.key,
    required this.child,
    required this.onPressed,
    this.selected = false,
    this.hoverId,
  });

  @override
  State<MenuRow> createState() => _MenuRowState();
}

class _MenuRowState extends State<MenuRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final fill = _hover
        ? t.surface4
        : widget.selected
            ? t.accent.withValues(alpha: 0.5)
            : null;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        setState(() => _hover = true);
        // Tell the surface which row the pointer is on, so a submenu that is
        // out can take itself back when the pointer moves to another row.
        FloatSurface.hoveredRow(context)?.value = widget.hoverId ?? this;
      },
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(t.tokens.controlRadius),
          ),
          child: DefaultTextStyle(style: t.bodyPrimary, child: widget.child),
        ),
      ),
    );
  }
}

/// The floating popup surface every menu and dropdown shares: `surface3`
/// fill, hairline edge, the float radius and the real drop shadow.
///
/// It also carries the surface's hover state — which of its rows the pointer is
/// over — because opening a flyout is one row's business and closing it again is
/// every other row's (see [SubmenuRow]). Scoped to the surface, so the rows of a
/// flyout never disturb the menu the flyout came from.
class FloatSurface extends StatefulWidget {
  final Widget child;
  final double? width;
  const FloatSurface({super.key, required this.child, this.width});

  /// The row of the nearest floating surface the pointer is on, or null outside
  /// one, where no menu is being drawn.
  static ValueNotifier<Object?>? hoveredRow(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_MenuHoverScope>()?.hovered;

  @override
  State<FloatSurface> createState() => _FloatSurfaceState();
}

class _FloatSurfaceState extends State<FloatSurface> {
  final _hovered = ValueNotifier<Object?>(null);

  @override
  void dispose() {
    _hovered.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return _MenuHoverScope(
      hovered: _hovered,
      child: Container(
        width: widget.width,
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: t.surface3,
          borderRadius: BorderRadius.circular(t.tokens.floatRadius),
          border: Border.all(color: t.hairline, width: 1),
          boxShadow: t.floatShadow,
        ),
        child: widget.child,
      ),
    );
  }
}

class _MenuHoverScope extends InheritedWidget {
  final ValueNotifier<Object?> hovered;

  const _MenuHoverScope({required this.hovered, required super.child});

  // The notifier itself never changes; the rows listen to it directly.
  @override
  bool updateShouldNotify(_MenuHoverScope old) => false;
}

/// A dropdown drawn as a bare label + caret; the open list floats on the
/// standard menu surface (`bare_dropdown` in the Rust settings window).
class BareDropdown<T> extends StatelessWidget {
  final T value;
  final List<T> options;
  final String Function(T) label;
  final ValueChanged<T> onChanged;

  /// The heading an option sits under, or null for none. Options keep their
  /// given order; a heading is drawn each time the answer changes, so a list
  /// that is already grouped needs nothing else, and one that is not gets no
  /// headings rather than a scrambled list.
  final String? Function(T)? group;

  const BareDropdown({
    super.key,
    required this.value,
    required this.options,
    required this.label,
    required this.onChanged,
    this.group,
  });

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return HouseButton(
      onPressed: () async {
        final box = context.findRenderObject()! as RenderBox;
        final origin = box.localToGlobal(Offset.zero);
        final picked = await showLumitPopup<T>(
          context: context,
          position: origin + Offset(0, box.size.height + 2),
          // IntrinsicWidth bounds the stretch: a float in the overlay has
          // unbounded width, and a stretched Column inside one otherwise
          // forces an infinite width (the settings-dropdown crash).
          builder: (close) => FloatSurface(
            child: IntrinsicWidth(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < options.length; i++) ...[
                    if (group != null &&
                        group!(options[i]) != null &&
                        (i == 0 || group!(options[i - 1]) != group!(options[i])))
                      Padding(
                        padding: EdgeInsets.fromLTRB(10, i == 0 ? 6 : 10, 10, 2),
                        child: Text(
                          group!(options[i])!,
                          style: t.small.copyWith(color: t.textMuted),
                        ),
                      ),
                    MenuRow(
                      selected: options[i] == value,
                      onPressed: () => close(options[i]),
                      child: Text(label(options[i])),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
        if (picked != null) onChanged(picked);
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Ellipsised rather than allowed to overflow: a dropdown sits in
          // whatever width its caller has, and a label longer than that is a
          // layout error the user sees as striped tape. `Flexible` keeps the
          // button intrinsic-width when there is room, so nothing that fits
          // changes shape.
          Flexible(child: Text(label(value), overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 4),
          CustomPaint(
            size: const Size(9, 9),
            painter: _CaretPainter(t.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// A [BareDropdown] whose option list is built only when the menu opens.
///
/// For pickers whose options are bridge reads (the Timeline's parent picker):
/// the resting button then costs nothing per rebuild, and the reads happen
/// once per click instead of once per rebuild.
class BareLazyDropdown<T> extends StatelessWidget {
  /// What the closed button shows.
  final String label;

  /// The options, as (value, label) pairs — called when the menu opens.
  final List<(T, String)> Function() options;
  final ValueChanged<T> onChanged;

  const BareLazyDropdown({
    super.key,
    required this.label,
    required this.options,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return HouseButton(
      onPressed: () async {
        final box = context.findRenderObject()! as RenderBox;
        final origin = box.localToGlobal(Offset.zero);
        final built = options();
        final picked = await showLumitPopup<(T,)>(
          context: context,
          position: origin + Offset(0, box.size.height + 2),
          builder: (close) => FloatSurface(
            child: IntrinsicWidth(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (value, optionLabel) in built)
                    MenuRow(
                      selected: optionLabel == label,
                      // Wrapped in a record so a null value survives the
                      // popup's null-means-dismissed contract.
                      onPressed: () => close((value,)),
                      child: Text(optionLabel),
                    ),
                ],
              ),
            ),
          ),
        );
        if (picked != null) onChanged(picked.$1);
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 4),
          CustomPaint(
            size: const Size(9, 9),
            painter: _CaretPainter(t.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _CaretPainter extends CustomPainter {
  final Color color;
  const _CaretPainter(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    final w = size.width, h = size.height;
    canvas.drawLine(Offset(w * 0.2, h * 0.35), Offset(w * 0.5, h * 0.65), p);
    canvas.drawLine(Offset(w * 0.5, h * 0.65), Offset(w * 0.8, h * 0.35), p);
  }

  @override
  bool shouldRepaint(_CaretPainter old) => old.color != color;
}

/// Show a positioned popup and complete with the value handed to `close`.
/// Clicking outside (or Escape, via the route) dismisses with null.
/// A centred modal on the app Overlay, with a dimmed click-to-dismiss backdrop.
/// Completes with whatever `close` was given, or null when dismissed.
///
/// The value-returning sibling of [showLumitPopup]. `dialogs.dart` has a private
/// `_showModal` that returns nothing, which is fine for a dialog that commits
/// through a callback but not for one whose caller needs to know whether anything
/// was applied — hence this, in the house-controls file where both can reach it.
///
/// The window is **movable** — dragging anywhere on it that no control claims
/// moves it — and, when [initialSize] is given, **resizable** from the grip in
/// its bottom-right corner. Give an [id] and where it was left is remembered in
/// the workspace store, so it opens where it was last put, this session and the
/// next (K-242). Windows without an id always open centred at their natural
/// size, which is what a one-question confirmation wants.
Future<T?> showLumitModal<T>({
  required BuildContext context,
  required Widget Function(void Function(T?) close) builder,
  String? id,
  Size? initialSize,
  Size minSize = const Size(320, 240),
}) {
  final overlay = Overlay.of(context);
  final completer = Completer<T?>();
  late OverlayEntry entry;
  void close(T? v) {
    if (completer.isCompleted) return;
    completer.complete(v);
    entry.remove();
  }

  entry = OverlayEntry(
    builder: (_) => Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => close(null),
            child: ColoredBox(
              color: const Color(0x99000000),
            ),
          ),
        ),
        _MovableWindow(
          id: id,
          initialSize: initialSize,
          minSize: minSize,
          child: builder(close),
        ),
      ],
    ),
  );
  overlay.insert(entry);
  return completer.future;
}

/// Where movable windows remember being left. The shell points this at the one
/// [Workspace] it loaded at start-up; it is null in a widget test, which simply
/// means a window there opens centred and forgets where it was dragged.
Workspace? modalPlacementStore;

int _openModals = 0;

/// Whether a modal window is up (K-243).
///
/// The panels register their keyboard commands on the hardware keyboard rather
/// than holding focus, so nothing about a dialogue being open stopped them
/// hearing a keypress meant for it: `Enter` in the Pre-compose dialogue was
/// also `Enter` in the Timeline, and renamed a layer behind the window instead
/// of pressing the button in front of it. A panel command is about the panel,
/// and while a modal is up the panel is not what is being used.
///
/// Counted by the windows themselves as they mount and unmount, rather than by
/// the open and close calls: a window can also leave by having the tree taken
/// down under it, and a count only the close path decremented would stick above
/// zero and leave the keyboard dead for the rest of the session.
bool get lumitModalOpen => _openModals > 0;

/// A window that can be dragged around the app window and, when it has a size,
/// resized from its bottom-right corner.
///
/// It sits at the centre and carries an *offset* from there rather than an
/// absolute position: that way it needs to know nothing about how big it is to
/// open centred, and a placement saved on one monitor still opens on screen on
/// another. The offset is clamped so the middle of the window can never leave
/// the app window — drag it as far as you like, it is always grabbable again.
class _MovableWindow extends StatefulWidget {
  final String? id;
  final Size? initialSize;
  final Size minSize;
  final Widget child;

  const _MovableWindow({
    required this.id,
    required this.initialSize,
    required this.minSize,
    required this.child,
  });

  @override
  State<_MovableWindow> createState() => _MovableWindowState();
}

class _MovableWindowState extends State<_MovableWindow> {
  Offset _offset = Offset.zero;
  Size? _size;

  @override
  void initState() {
    super.initState();
    _openModals++;
    _size = widget.initialSize;
    final id = widget.id;
    final saved =
        id == null ? null : modalPlacementStore?.windowPlacements[id];
    if (saved != null) {
      _offset = saved.offset;
      // A fixed-size window keeps its natural size however big it was when the
      // placement was written — only a resizable one takes a size back.
      if (widget.initialSize != null && saved.size != null) _size = saved.size;
    }
  }

  @override
  void dispose() {
    _openModals--;
    super.dispose();
  }

  void _remember() {
    final id = widget.id;
    if (id == null) return;
    modalPlacementStore?.rememberWindow(id, WindowPlacement(_offset, _size));
  }

  /// Keep the middle of the window inside the app window, so however far it is
  /// dragged there is always something left to grab.
  Offset _clampOffset(Offset o, BoxConstraints box) => Offset(
        o.dx.clamp(-box.maxWidth / 2, box.maxWidth / 2),
        o.dy.clamp(-box.maxHeight / 2, box.maxHeight / 2),
      );

  Size? _clampSize(Size? s, BoxConstraints box) => s == null
      ? null
      : Size(
          s.width.clamp(widget.minSize.width, box.maxWidth),
          s.height.clamp(widget.minSize.height, box.maxHeight),
        );

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return LayoutBuilder(
      builder: (context, box) {
        // The gesture handlers accumulate onto the *state*, never onto these:
        // several pointer moves can arrive between two frames, and every one of
        // them would read the same stale value from this build and the window
        // would move a fraction of the distance dragged.
        final offset = _clampOffset(_offset, box);
        final size = _clampSize(_size, box);

        return Center(
          child: Transform.translate(
            offset: offset,
            // The grip is a *sibling* of the window, not something inside it.
            // Nested drag detectors both join the gesture arena for a pointer
            // that lands on the inner one and neither ends up moving anything;
            // as siblings the topmost — the grip — takes the corner and the
            // window takes everywhere else.
            child: Stack(
              children: [
                GestureDetector(
                  // Anything with its own drag — a slider, a scrolling list, a
                  // text selection — wins the gesture over this, so dragging a
                  // control still does what the control does and dragging the
                  // window's own chrome moves the window.
                  onPanUpdate: (d) => setState(
                    () => _offset = _clampOffset(_offset + d.delta, box),
                  ),
                  onPanEnd: (_) => _remember(),
                  child: SizedBox(
                    width: size?.width,
                    height: size?.height,
                    child: widget.child,
                  ),
                ),
                if (size != null)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.resizeDownRight,
                      child: GestureDetector(
                        key: const ValueKey('window-resize-grip'),
                        behavior: HitTestBehavior.opaque,
                        onPanUpdate: (d) => setState(() {
                          final was = _clampSize(_size, box)!;
                          final now = _clampSize(
                            Size(
                              was.width + d.delta.dx,
                              was.height + d.delta.dy,
                            ),
                            box,
                          )!;
                          // The window is anchored at its centre, so growing it
                          // by one pixel to the right means moving it half a
                          // pixel right for the left edge to stay put.
                          _offset = _clampOffset(
                            _offset +
                                Offset((now.width - was.width) / 2,
                                    (now.height - was.height) / 2),
                            box,
                          );
                          _size = now;
                        }),
                        onPanEnd: (_) => _remember(),
                        child: CustomPaint(
                          size: const Size(14, 14),
                          painter: _GripPainter(t.hairline),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The three short diagonals that say "drag this corner".
class _GripPainter extends CustomPainter {
  final Color color;
  const _GripPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round;
    for (final inset in [3.0, 6.5, 10.0]) {
      canvas.drawLine(
        Offset(size.width - 2, size.height - inset),
        Offset(size.width - inset, size.height - 2),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(_GripPainter old) => old.color != color;
}

/// A single-line text box in the house style. The dialogs each grew their own
/// copy of this; it belongs here.
class HouseTextField extends StatefulWidget {
  final TextEditingController controller;
  final double width;
  final ValueChanged<String>? onSubmitted;

  /// Grab focus on first build — for fields that appear in response to a
  /// gesture (an inline rename), where a second click to focus would be
  /// asking the user to say it twice.
  final bool autofocus;

  /// Muted placeholder shown while the field is empty — what the field is
  /// *for*, on fields whose surroundings do not already say.
  final String? hint;

  /// A pointer went down somewhere that is not this field. What an inline
  /// rename commits on: clicking away is a person finishing the edit, and a
  /// field that kept what was typed only when `Enter` was pressed threw the
  /// work away for everyone who clicks instead (K-243).
  final VoidCallback? onTapOutside;

  const HouseTextField({
    super.key,
    required this.controller,
    this.width = 200,
    this.onSubmitted,
    this.autofocus = false,
    this.hint,
    this.onTapOutside,
  });

  @override
  State<HouseTextField> createState() => _HouseTextFieldState();
}

class _HouseTextFieldState extends State<HouseTextField> {
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // The hint draws only while empty, so emptiness changing must redraw.
    widget.controller.addListener(_changed);
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final hint = widget.hint;
    return Container(
      width: widget.width,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: t.surface0,
        borderRadius: BorderRadius.circular(t.tokens.controlRadius),
        border: Border.all(color: t.hairline),
      ),
      child: Stack(
        children: [
          if (hint != null && widget.controller.text.isEmpty)
            Text(hint, style: t.body.copyWith(color: t.textMuted)),
          EditableText(
            controller: widget.controller,
            focusNode: _focus,
            autofocus: widget.autofocus,
            style: t.bodyPrimary,
            cursorColor: t.accent,
            backgroundCursorColor: t.surface2,
            selectionColor: t.accent.withValues(alpha: 0.5),
            onSubmitted: widget.onSubmitted,
            onTapOutside: widget.onTapOutside == null
                ? null
                : (_) => widget.onTapOutside!(),
          ),
        ],
      ),
    );
  }
}

/// A menu row that opens a submenu beside it (K-194).
///
/// The parent menu stays open underneath while the submenu is up — closing it
/// first would take this row's `BuildContext` with it, and the overlay the
/// submenu needs is reached *through* that context. Picking something in the
/// submenu dismisses both.
///
/// **Hovering is enough.** Resting on the row flies the submenu out and moving
/// on to another row of the same menu takes it back, which is how every menu on
/// every desktop behaves; clicking still works for anyone who clicks. The row
/// cannot see the pointer leave for a sibling — the flyout's own barrier is in
/// the way — so it watches the surface's hover state instead ([FloatSurface]),
/// which the sibling sets when the pointer arrives on it.
class SubmenuRow extends StatefulWidget {
  final Widget child;

  /// Closes the menu this row belongs to.
  final VoidCallback closeParent;

  /// Builds the submenu's surface. `dismiss` closes the submenu *and* the
  /// parent, which is what picking an item means.
  final Widget Function(VoidCallback dismiss) submenu;

  const SubmenuRow({
    super.key,
    required this.child,
    required this.closeParent,
    required this.submenu,
  });

  @override
  State<SubmenuRow> createState() => _SubmenuRowState();
}

class _SubmenuRowState extends State<SubmenuRow> {
  ValueNotifier<Object?>? _hovered;

  /// True from the moment the flyout is asked for; [_close] arrives a frame
  /// later, when the overlay builds it.
  bool _out = false;
  VoidCallback? _close;

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final hovered = FloatSurface.hoveredRow(context);
    if (hovered != _hovered) {
      _hovered?.removeListener(_hoverMoved);
      _hovered = hovered?..addListener(_hoverMoved);
    }
    return MenuRow(
      hoverId: this,
      onPressed: _open,
      child: Row(
        children: [
          Expanded(child: widget.child),
          Text('›', style: t.body.copyWith(color: t.textMuted)),
        ],
      ),
    );
  }

  void _hoverMoved() {
    if (_hovered?.value == this) {
      _open();
    } else {
      _out = false;
      _close?.call();
      _close = null;
    }
  }

  void _open() {
    if (_out) return;
    final box = context.findRenderObject();
    if (box is! RenderBox) return;
    // Beside the row, overlapping it slightly, the way a flyout sits.
    final at = box.localToGlobal(Offset(box.size.width - 6, -4));
    _out = true;
    showLumitPopup<void>(
      context: context,
      position: at,
      // So the menu underneath still feels the pointer: moving to another row
      // is what takes this flyout back.
      hoverThrough: true,
      builder: (close) {
        _close = () => close(null);
        return widget.submenu(() {
          close(null);
          widget.closeParent();
        });
      },
    ).then((_) {
      _out = false;
      _close = null;
    });
  }

  @override
  void dispose() {
    _hovered?.removeListener(_hoverMoved);
    // The menu this row belongs to has gone (another heading took over, say);
    // its flyout goes with it rather than being left behind. After the frame,
    // because removing an overlay entry sets the overlay's state and this is
    // the middle of a tear-down.
    final close = _close;
    if (close != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => close());
    }
    super.dispose();
  }
}

Future<T?> showLumitPopup<T>({
  required BuildContext context,
  required Offset position,
  required Widget Function(void Function(T?) close) builder,
  // Whether what is underneath still feels the pointer while this popup is up.
  // Menus want it — hovering another heading or another row is how a menu is
  // navigated — and nothing else does: a dropdown that let the panel behind it
  // light up under the pointer would be answering to a click it will not get.
  bool hoverThrough = false,
}) {
  final overlay = Overlay.of(context);
  final completer = Completer<T?>();
  late OverlayEntry entry;
  void close(T? v) {
    if (completer.isCompleted) return;
    completer.complete(v);
    entry.remove();
  }

  entry = OverlayEntry(
    // LayoutBuilder, not MediaQuery: what matters is the room the overlay
    // actually has, and the two disagree wherever a MediaQuery has been
    // overridden. A popup taller than that room would run off the bottom of the
    // window with its last rows unreachable — so it is capped at the space
    // below its own top edge, and scrolls inside that if it needs to.
    builder: (_) => LayoutBuilder(
      builder: (context, constraints) => Stack(
        children: [
          Positioned.fill(
            // Translucent still takes the click — it is above whatever it
            // covers, so it wins the gesture arena — but lets hover through to
            // the menu bar and to the menu this one flew out of.
            child: GestureDetector(
              behavior: hoverThrough
                  ? HitTestBehavior.translucent
                  : HitTestBehavior.opaque,
              onTap: () => close(null),
              onSecondaryTap: () => close(null),
            ),
          ),
          Positioned.fill(
            child: CustomSingleChildLayout(
              delegate: _PopupLayout(position),
              // Scrolls only when it has to: a shorter popup shrink-wraps and
              // behaves exactly as before.
              child: SingleChildScrollView(child: builder(close)),
            ),
          ),
        ],
      ),
    ),
  );
  overlay.insert(entry);
  return completer.future;
}

/// Places a popup at its anchor, then pulls it back on screen if it would hang
/// off an edge.
///
/// Anchoring alone was enough while every popup opened from the top of the
/// window. A control near the bottom — the Viewer's transport, now that it sits
/// under the picture — opens a list that would run off the bottom entirely, so
/// the whole thing is shifted up until it fits. The same applies sideways for a
/// control near the right edge.
class _PopupLayout extends SingleChildLayoutDelegate {
  final Offset anchor;
  const _PopupLayout(this.anchor);

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(Size(
        constraints.maxWidth,
        // Never taller than the room above *or* below the anchor, whichever the
        // popup ends up using — the larger of the two is the most it can need.
        (constraints.maxHeight - 16).clamp(80.0, double.infinity),
      ));

  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset(
        anchor.dx.clamp(0.0, (size.width - childSize.width).clamp(0.0, 1e6)),
        anchor.dy.clamp(0.0, (size.height - childSize.height).clamp(0.0, 1e6)),
      );

  @override
  bool shouldRelayout(_PopupLayout old) => old.anchor != anchor;
}

/// A 14 px themed checkbox.
class HouseCheckbox extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  const HouseCheckbox(
      {super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onChanged(!value),
      child: Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          color: value ? t.accent : t.surface3,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: value ? t.accent : t.hairlineStrong),
        ),
        child: value ? CustomPaint(painter: _TickPainter(t.surface0)) : null,
      ),
    );
  }
}

/// One of a set of choices, where the set is exclusive — the dot beside a
/// sentence. [HouseCheckbox] is the independent one; this is the one that says
/// "this, and therefore not that". Disabled it still shows which way the
/// choice fell, dimmed, rather than going blank.
class HouseRadio extends StatelessWidget {
  final bool selected;
  final bool enabled;
  final VoidCallback? onChanged;

  const HouseRadio({
    super.key,
    required this.selected,
    this.enabled = true,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final borderColor = !enabled
        ? t.textMuted.withValues(alpha: 0.4)
        : (selected ? t.accent : t.hairlineStrong);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onChanged : null,
      child: Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          color: t.surface3,
          shape: BoxShape.circle,
          border: Border.all(color: borderColor, width: 1.5),
        ),
        alignment: Alignment.center,
        child: selected
            ? Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: enabled ? t.accent : t.textMuted,
                  shape: BoxShape.circle,
                ),
              )
            : null,
      ),
    );
  }
}

class _TickPainter extends CustomPainter {
  final Color color;
  const _TickPainter(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    final path = Path()
      ..moveTo(size.width * 0.22, size.height * 0.52)
      ..lineTo(size.width * 0.44, size.height * 0.74)
      ..lineTo(size.width * 0.8, size.height * 0.28);
    canvas.drawPath(path, p);
  }

  @override
  bool shouldRepaint(_TickPainter old) => old.color != color;
}

/// egui's DragValue: drag horizontally to adjust, click to type, right-click
/// for Reset / Copy / Paste (egui's built-in drag-value menu). [resetTo] is the
/// field's known default — Reset appears only when a call site supplies one.
class DragValueField extends StatefulWidget {
  final num value;
  final num min;
  final num max;
  final double speed;
  final int decimals;
  final String? suffix;
  final num? resetTo;

  /// The resting background. Defaults to `surface3`, which reads as a field on
  /// a panel — but a dialogue's own surface *is* surface3, so a field there has
  /// to be darker to look like something you can type into. Only the resting
  /// colour: hover stays the standard lift, so the affordance is unchanged.
  final Color? fill;
  final ValueChanged<num> onChanged;

  /// Fired once when a drag begins. Optional — a caller with nothing to do at
  /// drag-start (the common case) simply omits it.
  final VoidCallback? onChangeStart;

  /// Fired with the live value on every accumulated drag tick, in place of
  /// [onChanged], when supplied (a live-preview fast path — see
  /// [onChangeEnd]). Falls back to [onChanged] when null, so every existing
  /// call site behaves exactly as before.
  final ValueChanged<num>? onChangeLive;

  /// Fired once, with the final value, when a drag ends (mouse-up). Falls
  /// back to [onChanged] when null. Reset/Copy/Paste and the text-edit commit
  /// always call [onChanged] directly and never this — they are already
  /// one-shot edits, not a drag.
  final ValueChanged<num>? onChangeEnd;

  /// Fired when a drag is cancelled (a gesture cancel, or a released drag
  /// that never crossed one [speed] increment — so nothing was ever ticked).
  final VoidCallback? onDragCancel;

  const DragValueField({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.speed = 1,
    this.decimals = 0,
    this.suffix,
    this.resetTo,
    this.fill,
    this.onChangeStart,
    this.onChangeLive,
    this.onChangeEnd,
    this.onDragCancel,
  });

  @override
  State<DragValueField> createState() => _DragValueFieldState();
}

class _DragValueFieldState extends State<DragValueField> {
  bool _editing = false;
  bool _hover = false;
  double _dragAccum = 0;

  /// The last value ticked this drag (via [onChangeLive]/[onChanged]), or
  /// null before the first tick / after a commit or cancel. Distinguishes "a
  /// released drag that ticked at least once" (commit the last value) from "a
  /// released drag that never crossed one [DragValueField.speed] increment"
  /// (nothing to commit — a no-op cancel).
  num? _lastDragValue;
  late TextEditingController _controller;
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
    _focus.addListener(() {
      if (!_focus.hasFocus && _editing) _commitText();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  String _format(num v) {
    final s = widget.decimals == 0
        ? v.round().toString()
        : v.toDouble().toStringAsFixed(widget.decimals);
    return widget.suffix == null ? s : '$s${widget.suffix}';
  }

  void _commitText() {
    final raw = _controller.text.replaceAll(widget.suffix ?? '', '').trim();
    final parsed = num.tryParse(raw);
    if (parsed != null) {
      widget.onChanged(parsed.clamp(widget.min, widget.max));
    }
    setState(() => _editing = false);
  }

  /// The plain numeric string (no suffix) — what Copy puts on the clipboard and
  /// what Paste parses back, so a value round-trips between fields.
  String _plain(num v) => widget.decimals == 0
      ? v.round().toString()
      : v.toDouble().toStringAsFixed(widget.decimals);

  /// The egui drag-value right-click menu: Reset (when a default is known),
  /// Copy and Paste, over the system clipboard with the field's own clamp.
  void _contextMenu(BuildContext context, Offset globalPos) {
    showLumitPopup<void>(
      context: context,
      position: globalPos,
      builder: (close) => FloatSurface(
        child: IntrinsicWidth(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.resetTo != null)
                MenuRow(
                  onPressed: () {
                    close(null);
                    widget.onChanged(
                        widget.resetTo!.clamp(widget.min, widget.max));
                  },
                  child: const Text('Reset'),
                ),
              MenuRow(
                onPressed: () {
                  close(null);
                  Clipboard.setData(ClipboardData(text: _plain(widget.value)));
                },
                child: const Text('Copy'),
              ),
              MenuRow(
                onPressed: () async {
                  close(null);
                  final data = await Clipboard.getData(Clipboard.kTextPlain);
                  final raw =
                      data?.text?.replaceAll(widget.suffix ?? '', '').trim();
                  final parsed = raw == null ? null : num.tryParse(raw);
                  if (parsed != null) {
                    widget.onChanged(parsed.clamp(widget.min, widget.max));
                  }
                },
                child: const Text('Paste'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    if (_editing) {
      return SizedBox(
        width: 72,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: t.surface0,
            borderRadius: BorderRadius.circular(t.tokens.controlRadius),
            border: Border.all(color: t.accent),
          ),
          child: EditableText(
            controller: _controller,
            focusNode: _focus,
            style: t.bodyPrimary,
            cursorColor: t.accent,
            backgroundCursorColor: t.surface2,
            selectionColor: t.accent.withValues(alpha: 0.5),
            onSubmitted: (_) => _commitText(),
          ),
        ),
      );
    }
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          setState(() {
            _editing = true;
            _controller.text = widget.decimals == 0
                ? widget.value.round().toString()
                : widget.value.toDouble().toStringAsFixed(widget.decimals);
          });
          _focus.requestFocus();
        },
        onSecondaryTapDown: (d) => _contextMenu(context, d.globalPosition),
        onHorizontalDragStart: (_) {
          _dragAccum = 0;
          _lastDragValue = null;
          widget.onChangeStart?.call();
        },
        onHorizontalDragUpdate: (d) {
          _dragAccum += d.delta.dx * widget.speed;
          if (_dragAccum.abs() >= widget.speed) {
            final next =
                (widget.value + _dragAccum).clamp(widget.min, widget.max);
            _dragAccum = 0;
            _lastDragValue = next;
            (widget.onChangeLive ?? widget.onChanged)(next);
          }
        },
        onHorizontalDragEnd: (_) {
          final v = _lastDragValue;
          _lastDragValue = null;
          if (v != null) {
            (widget.onChangeEnd ?? widget.onChanged)(v);
          } else {
            // Never crossed one speed-increment: nothing was ticked, so a
            // release here is a no-op cancel, not a commit.
            widget.onDragCancel?.call();
          }
        },
        onHorizontalDragCancel: () {
          _lastDragValue = null;
          widget.onDragCancel?.call();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: _hover ? t.surface4 : (widget.fill ?? t.surface3),
            borderRadius: BorderRadius.circular(t.tokens.controlRadius),
            // Reserved even when not hovered — see HouseButton above.
            border: Border.all(
                color: _hover ? t.hairlineStrong : const Color(0x00000000),
                width: 1),
          ),
          child: Text(_format(widget.value), style: t.bodyPrimary),
        ),
      ),
    );
  }
}

/// A thin themed slider. `commitOnRelease` reproduces the UI-scale rule
/// (K-117): the dragged value shows live but `onChanged` fires on release.
class HouseSlider extends StatefulWidget {
  final double value;
  final double min;
  final double max;
  final double? step;
  final int decimals;
  final String? suffix;
  final bool commitOnRelease;
  final ValueChanged<double> onChanged;

  const HouseSlider({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.step,
    this.decimals = 2,
    this.suffix,
    this.commitOnRelease = false,
  });

  @override
  State<HouseSlider> createState() => _HouseSliderState();
}

class _HouseSliderState extends State<HouseSlider> {
  double? _pending;

  double get _shown => _pending ?? widget.value;

  double _fromDx(double dx, double width) {
    var v =
        widget.min + (dx / width).clamp(0.0, 1.0) * (widget.max - widget.min);
    final s = widget.step;
    if (s != null && s > 0) v = (v / s).round() * s;
    return v.clamp(widget.min, widget.max).toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    const width = 140.0;
    final frac =
        ((_shown - widget.min) / (widget.max - widget.min)).clamp(0.0, 1.0);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) => widget.onChanged(_fromDx(d.localPosition.dx, width)),
          onHorizontalDragUpdate: (d) {
            final v = _fromDx(d.localPosition.dx, width);
            if (widget.commitOnRelease) {
              setState(() => _pending = v);
            } else {
              widget.onChanged(v);
            }
          },
          onHorizontalDragEnd: (_) {
            if (_pending != null) {
              widget.onChanged(_pending!);
              setState(() => _pending = null);
            }
          },
          child: SizedBox(
            width: width,
            height: 16,
            child: CustomPaint(
              painter: _SliderPainter(
                track: t.surface0,
                fill: t.accent,
                knob: t.textPrimary,
                frac: frac,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '${_shown.toStringAsFixed(widget.decimals)}${widget.suffix ?? ''}',
          style: t.bodyPrimary,
        ),
      ],
    );
  }
}

class _SliderPainter extends CustomPainter {
  final Color track, fill, knob;
  final double frac;
  const _SliderPainter({
    required this.track,
    required this.fill,
    required this.knob,
    required this.frac,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final trackRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, y - 2, size.width, 4),
      const Radius.circular(2),
    );
    canvas.drawRRect(trackRect, Paint()..color = track);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, y - 2, size.width * frac, 4),
        const Radius.circular(2),
      ),
      Paint()..color = fill,
    );
    canvas.drawCircle(Offset(size.width * frac, y), 5, Paint()..color = knob);
  }

  @override
  bool shouldRepaint(_SliderPainter old) =>
      old.frac != frac || old.fill != fill || old.track != track;
}

/// A tooltip that honours Settings → Interface → Show tooltips app-wide —
/// the one thing Flutter's own Tooltip cannot do.
class LumitTooltip extends StatelessWidget {
  final String message;
  final Widget child;
  const LumitTooltip({super.key, required this.message, required this.child});

  @override
  Widget build(BuildContext context) {
    final scope = ThemeScope.of(context);
    if (!scope.showTooltips) return child;
    return _HoverTip(message: message, child: child);
  }
}

class _HoverTip extends StatefulWidget {
  final String message;
  final Widget child;
  const _HoverTip({required this.message, required this.child});

  @override
  State<_HoverTip> createState() => _HoverTipState();
}

class _HoverTipState extends State<_HoverTip> {
  OverlayEntry? _entry;

  /// The pending show, so leaving cancels it.
  ///
  /// Without this a tooltip could appear *after* the pointer had already gone:
  /// the delay ran to completion regardless, and the `onExit` that should have
  /// stopped it had come and gone while nothing was showing yet. The tip then
  /// stuck on screen with no pointer left to leave and dismiss it — hovering
  /// the control again would clear it, and moving off would bring it back,
  /// which is the loop this was stuck in.
  Timer? _pending;

  void _show(PointerEnterEvent e) {
    _pending?.cancel();
    _pending = Timer(const Duration(milliseconds: 500), _present);
  }

  void _present() {
    if (!mounted || _entry != null) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;
    final origin = box.localToGlobal(Offset(0, box.size.height + 4));
    final scope = ThemeScope.of(context);
    final t = scope.theme;
    _entry = OverlayEntry(
      builder: (_) => Positioned.fill(
        child: IgnorePointer(
          // Pulled back on screen when it would hang off an edge — a control
          // near the bottom (the Viewer's transport) would otherwise tip below
          // the window entirely.
          child: CustomSingleChildLayout(
            delegate: _PopupLayout(origin),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: t.surface3,
                borderRadius: BorderRadius.circular(t.tokens.floatRadius),
                border: Border.all(color: t.hairline),
                boxShadow: t.floatShadow,
              ),
              child: Text(widget.message, style: t.body),
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_entry!);
  }

  void _hide() {
    _pending?.cancel();
    _pending = null;
    _entry?.remove();
    _entry = null;
  }

  @override
  void dispose() {
    _hide();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: _show,
        onExit: (_) => _hide(),
        child: widget.child,
      );
}
