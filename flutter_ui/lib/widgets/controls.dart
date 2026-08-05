// House controls, owned rather than Material (docs/archive/flutter-port/04): every
// colour and metric reads the theme, idle widgets are borderless, hover and
// press bring an edge back (the K-084 owner amendment).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/widgets/autofill.dart';

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

  const HouseButton({
    super.key,
    required this.child,
    this.onPressed,
    this.frameless = false,
    this.small = false,
    this.padding,
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
  const MenuRow({
    super.key,
    required this.child,
    required this.onPressed,
    this.selected = false,
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
      onEnter: (_) => setState(() => _hover = true),
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
class FloatSurface extends StatelessWidget {
  final Widget child;
  final double? width;
  const FloatSurface({super.key, required this.child, this.width});

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return Container(
      width: width,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: t.surface3,
        borderRadius: BorderRadius.circular(t.tokens.floatRadius),
        border: Border.all(color: t.hairline, width: 1),
        boxShadow: t.floatShadow,
      ),
      child: child,
    );
  }
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
                        (i == 0 ||
                            group!(options[i - 1]) != group!(options[i])))
                      Padding(
                        padding:
                            EdgeInsets.fromLTRB(10, i == 0 ? 6 : 10, 10, 2),
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
Future<T?> showLumitModal<T>({
  required BuildContext context,
  required Widget Function(void Function(T?) close) builder,
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
        Center(child: builder(close)),
      ],
    ),
  );
  overlay.insert(entry);
  return completer.future;
}

class AutofillSuggestion<T> {
  T value;
  String word;

  AutofillSuggestion(this.value, this.word);
}

/// A single-line text box in the house style. The dialogs each grew their own
/// copy of this; it belongs here.
class HouseTextField extends StatefulWidget {
  final TextEditingController controller;
  final double width;
  final ValueChanged<String>? onSubmitted;
  final bool submitOnLostFocus;
  final TextStyle? style;
  final AutofillGenerator? autofill;

  /// Grab focus on first build — for fields that appear in response to a
  /// gesture (an inline rename), where a second click to focus would be
  /// asking the user to say it twice.
  final bool autofocus;

  /// Muted placeholder shown while the field is empty — what the field is
  /// *for*, on fields whose surroundings do not already say.
  final String? hint;

  const HouseTextField({
    super.key,
    required this.controller,
    this.width = 200,
    this.onSubmitted,
    this.submitOnLostFocus = false,
    this.autofill,
    this.autofocus = false,
    this.style,
    this.hint,
  });

  @override
  State<HouseTextField> createState() => _HouseTextFieldState();
}

class _HouseTextFieldState extends State<HouseTextField>
    implements TextSelectionGestureDetectorBuilderDelegate {
  late FocusNode _focus;
  final GlobalKey<EditableTextState> textFieldKey = GlobalKey();
  final layerLink = LayerLink();
  OverlayEntry? _overlay;

  @override
  void initState() {
    super.initState();
    _focus = FocusNode(onKeyEvent: onKeyEvent);
    // The hint draws only while empty, so emptiness changing must redraw.
    widget.controller.addListener(_changed);
  }

  List<dynamic> suggestions = List.empty();
  int? highlightedSuggestion = null;

  void _changed() {
    if (widget.autofill == null) {
      setState(() {});
      return;
    }

    setState(() {
      suggestions = widget.autofill!.getSuggestions(
          widget.controller.text, widget.controller.selection.baseOffset);
    });

    if (suggestions.isEmpty) {
      setState(() {
        highlightedSuggestion = null;
      });
      hideOverlay();
    } else {
      showOverlay();
    }
  }

  KeyEventResult onKeyEvent(FocusNode node, KeyEvent event) {
    if (suggestions.isNotEmpty) {
      if (event is! KeyDownEvent) {
        return KeyEventResult.ignored;
      }

      if (event.logicalKey == LogicalKeyboardKey.tab) {
        setState(() {
          if (highlightedSuggestion == null) {
            highlightedSuggestion = 0;
          } else {
            highlightedSuggestion =
                (highlightedSuggestion! + 1) % suggestions.length;
          }

          print("Highlighted suggestion: $highlightedSuggestion");
          showOverlay();
        });
        return KeyEventResult.handled;
      }

      if (event.logicalKey == LogicalKeyboardKey.enter) {
        if (highlightedSuggestion != null) {
          setState(() {
            widget.autofill!.applySuggestion(
                suggestions[highlightedSuggestion!], widget.controller);

            highlightedSuggestion = null;
          });

          WidgetsBinding.instance.addPostFrameCallback((_) {
            textFieldKey.currentState!.bringIntoView(
                TextPosition(offset: widget.controller.selection.baseOffset));
          });

          hideOverlay();
          return KeyEventResult.handled;
        }
      }
    }

    return KeyEventResult.ignored;
  }

  void showOverlay() {
    if (_overlay != null) {
      hideOverlay();
    }

    final t = ThemeScope.of(context);
    _overlay?.remove();
    _overlay = null;
    _overlay = OverlayEntry(
      canSizeOverlay: true,
      builder: (c) {
        return Stack(
          children: [
            Material(
              color: Colors.transparent,
              child: ThemeScope(
                  theme: t.theme,
                  animationLevel: t.animationLevel,
                  showTooltips: t.showTooltips,
                  child: CompositedTransformFollower(
                    link: layerLink,
                    offset: const Offset(-5, 16),
                    child: Container(
                      decoration: BoxDecoration(
                          color: t.theme.surface0,
                          border: BoxBorder.fromLTRB(
                              left: BorderSide(color: t.theme.selectionFill),
                              right: BorderSide(color: t.theme.selectionFill),
                              bottom: BorderSide(color: t.theme.selectionFill)),
                          borderRadius: t.theme.shape == ThemeShape.round
                              ? BorderRadius.only(
                                  bottomLeft: Radius.circular(8),
                                  bottomRight: Radius.circular(8))
                              : null),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (int i = 0; i < suggestions.length; i++)
                            HouseButton(
                              frameless: i != highlightedSuggestion,
                              onPressed: () {},
                              child: widget.autofill?.buildSuggestion(
                                      suggestions[i], t.theme) ??
                                  Text(suggestions[i].word),
                            )
                        ],
                      ),
                    ),
                  )),
            ),
          ],
        );
      },
    );

    Overlay.of(context, rootOverlay: true).insert(_overlay!);
  }

  void hideOverlay() {
    _overlay?.remove();
    _overlay = null;
  }

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
          TextSelectionGestureDetectorBuilder(delegate: this)
              .buildGestureDetector(
            child: CompositedTransformTarget(
              link: layerLink,
              child: EditableText(
                key: textFieldKey,
                controller: widget.controller,
                focusNode: _focus,
                autofocus: widget.autofocus,
                style: widget.style ?? t.bodyPrimary,
                cursorColor: t.accent,
                backgroundCursorColor: t.surface2,
                selectionColor: t.accent.withValues(alpha: 0.5),
                onSubmitted: widget.onSubmitted,
                selectionControls: desktopTextSelectionHandleControls,
                onTapOutside: (event) {
                  if (widget.submitOnLostFocus) {
                    widget.onSubmitted?.call(widget.controller.text);
                  }
                  _focus.unfocus();
                  hideOverlay();
                },
              ),
            ),
          )
        ],
      ),
    );
  }

  @override
  GlobalKey<EditableTextState> get editableTextKey => textFieldKey;

  @override
  bool get forcePressEnabled => false;

  @override
  bool get selectionEnabled => true;
}

/// A menu row that opens a submenu beside it (K-194).
///
/// The parent menu stays open underneath while the submenu is up — closing it
/// first would take this row's `BuildContext` with it, and the overlay the
/// submenu needs is reached *through* that context. Picking something in the
/// submenu dismisses both.
class SubmenuRow extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return Builder(
      builder: (rowContext) => MenuRow(
        onPressed: () {
          final box = rowContext.findRenderObject();
          if (box is! RenderBox) return;
          // Beside the row, overlapping it slightly, the way a flyout sits.
          final at = box.localToGlobal(Offset(box.size.width - 6, -4));
          showLumitPopup<void>(
            context: rowContext,
            position: at,
            builder: (close) => submenu(() {
              close(null);
              closeParent();
            }),
          );
        },
        child: Row(
          children: [
            Expanded(child: child),
            Text('›', style: t.body.copyWith(color: t.textMuted)),
          ],
        ),
      ),
    );
  }
}

Future<T?> showLumitPopup<T>({
  required BuildContext context,
  required Offset position,
  required Widget Function(void Function(T?) close) builder,
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
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
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

  final VoidCallback? setExpression;

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
    this.setExpression,
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
              if (widget.setExpression != null)
                MenuRow(
                  onPressed: () {
                    close(null);
                    widget.setExpression?.call();
                  },
                  child: const Text('Set Expression'),
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

class HouseContextMenu extends StatelessWidget {
  const HouseContextMenu({this.child, this.itemBuilder, super.key});
  final Widget? child;
  final List<MenuRow> Function(void Function() close)? itemBuilder;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
        child: GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapDown: (d) => _contextMenu(context, d.globalPosition),
      child: child,
    ));
  }

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
              ...(itemBuilder?.call(() => close(())) ?? []),
            ],
          ),
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
