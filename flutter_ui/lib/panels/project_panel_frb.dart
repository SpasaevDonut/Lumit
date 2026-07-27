// The Project panel, on the flutter_rust_bridge API — the first full panel port.
//
// One row per document item, folders nesting their children. A click selects; a
// second click on the selected row renames it in place; a double-click opens a
// composition or places a footage item into the front comp; a right-click raises
// the project menu; a footage row is draggable onto the Timeline. Missing footage
// wears a badge with an inline Relink… button, and a "show only missing" toggle
// appears in the header while anything is missing. Footage rows show a decoded
// thumbnail in place of their type glyph.
//
// **What changed from the v0 panel, and why it is shorter.** v0 read one big
// snapshot, mirrored it into `BridgeItem` trees, and addressed every edit by UUID
// string through `AppStateStub`. Here the handles *are* the identity: a row holds
// an `ItemReference` and calls `rename`/`delete`/`moveToRoot` straight on it, so
// there is no snapshot to diff, no mirror class to keep in step, and no id
// lookup. The thumbnail is the clearest case — v0 needed an isolate, a wire
// protocol and a generation map to keep a cold FFmpeg decode off the UI thread;
// `FootageReference.thumbnail` is simply async, so `FutureBuilder` does it.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/src/rust/api/footage.dart';
import 'package:lumit_flutter/src/rust/api/project_item.dart';
import 'package:lumit_flutter/src/rust/api/state.dart';
import 'package:provider/provider.dart';

import '../icons/icons.dart';
import '../state/drag_payloads.dart';
import '../shell/comp_settings_frb.dart';
import '../state/file_dialogs.dart';
import '../theme/theme.dart';
import '../widgets/controls.dart';

/// The longer edge a row thumbnail is decoded at: ~28 logical px at 2× for
/// crispness on a high-DPI display.
const int _thumbMaxEdge = 56;

/// What a click on a row does to the selection.
enum SelectMode {
  /// Plain click: this row, and only this row.
  replace,

  /// `Ctrl` (or `Cmd`): add this row, or drop it if it was already in.
  toggle,

  /// `Shift`: every row between the anchor and this one.
  range,
}

/// The modifier held right now, as a selection rule. Read from the keyboard
/// rather than carried on the tap because `GestureDetector.onTap` does not
/// report modifiers.
SelectMode _selectModeFromKeyboard() {
  final keys = HardwareKeyboard.instance.logicalKeysPressed;
  bool down(LogicalKeyboardKey a, LogicalKeyboardKey b) =>
      keys.contains(a) || keys.contains(b);
  if (down(LogicalKeyboardKey.shiftLeft, LogicalKeyboardKey.shiftRight)) {
    return SelectMode.range;
  }
  if (down(LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.controlRight) ||
      down(LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.metaRight)) {
    return SelectMode.toggle;
  }
  return SelectMode.replace;
}

/// How far each nesting level indents a row.
const double _indentPerDepth = 14;

class ProjectPanelFrb extends StatefulWidget {
  /// The relink file picker seam (chosen path, or null when cancelled). Defaults
  /// to the real footage picker; tests inject their own so no plugin channel
  /// opens.
  final Future<String?> Function()? relinkPicker;

  /// The import picker seam, for the footer button and the double-click. Same
  /// reason: a widget test must never open a plugin channel.
  final Future<List<String>> Function()? importPicker;

  const ProjectPanelFrb({super.key, this.relinkPicker, this.importPicker});

  @override
  State<ProjectPanelFrb> createState() => _ProjectPanelFrbState();
}

class _ProjectPanelFrbState extends State<ProjectPanelFrb> {
  bool _missingOnly = false;

  StreamSubscription<ScopedChange>? _changes;

  @override
  void initState() {
    super.initState();
    // Edits made ELSEWHERE reach us here — the menu bar, an undo, another panel.
    // That is the point of the scoped-change stream: no panel has to be told
    // about an edit it did not make, and none has to poll.
    //
    // Only `items` changes concern this panel. Rebuilding on every change meant a
    // layer tweak in the Timeline dropped the whole missing-media cache and
    // re-probed every footage file on disk — see `op_scope` in api/state.rs.
    //
    // This panel's own edits do *not* wait for the round trip; each calls
    // `_documentChanged` directly. Waiting would put a Rust→Dart hop between a
    // click and the row updating, for information this panel already had — and it
    // would make the panel untestable without real async, since a fake-async test
    // never delivers an FFI stream event.
    final state = Provider.of<LumitState>(context, listen: false);
    _changes = state.onChange.listen((event) {
      if (event.items) _documentChanged();
    });
  }

  @override
  void dispose() {
    _changes?.cancel();
    super.dispose();
  }

  /// The items currently selected, by id, in the order the panel lists them.
  /// Held here rather than in `LumitUiState` because nothing outside this panel
  /// reads it yet.
  ///
  /// A set rather than one id because more than one row can be picked:
  /// `Ctrl`-click adds or removes one, `Shift`-click takes the run between the
  /// last click and this one, and a plain click goes back to just that row — the
  /// selection rules every file list has. Multi-selection is what lets several
  /// clips be dropped on the Timeline, or on New composition, in one gesture.
  final Set<String> _selectedIds = {};

  /// The row a `Shift`-click measures its run from — the last one clicked
  /// without `Shift`.
  String? _anchorId;

  /// Every row id currently drawn, top to bottom, so a `Shift`-click knows what
  /// "between these two" means. Rebuilt with the rows.
  final List<String> _visibleIds = [];

  /// The footage handle behind each row, so a drag can carry the whole selection
  /// without walking the tree again. Rebuilt with the rows.
  final Map<String, FootageReference> _footageById = {};

  /// The selected footage, in the order the panel lists it. Anything selected
  /// that is not footage — a folder, a comp — is simply not part of a drag.
  List<FootageReference> get _selectedFootage => [
        for (final id in _visibleIds)
          if (_selectedIds.contains(id) && _footageById[id] != null)
            _footageById[id]!,
      ];

  /// Apply a click to the selection.
  void _select(String id, SelectMode mode) {
    setState(() {
      switch (mode) {
        case SelectMode.replace:
          _selectedIds
            ..clear()
            ..add(id);
          _anchorId = id;
        case SelectMode.toggle:
          if (!_selectedIds.remove(id)) _selectedIds.add(id);
          _anchorId = id;
        case SelectMode.range:
          final from = _visibleIds.indexOf(_anchorId ?? id);
          final to = _visibleIds.indexOf(id);
          if (from < 0 || to < 0) {
            _selectedIds.add(id);
            return;
          }
          // The anchor stays put, so widening and narrowing the run with
          // repeated Shift-clicks both work.
          _selectedIds
            ..clear()
            ..addAll(_visibleIds.sublist(
              from < to ? from : to,
              (from < to ? to : from) + 1,
            ));
      }
    });
  }

  /// The row being renamed in place, by id.
  String? _renamingId;

  /// Which footage items failed to resolve, by id.
  ///
  /// Cached because `getStatus` probes the file, which is far too slow to do in a
  /// build — and because the missing-only filter has to know every item's status
  /// at once to decide what to draw. Dropped when the item list changes, and only
  /// then: a probe of every footage file is far too expensive to repeat because
  /// someone nudged a layer value.
  final Map<String, bool> _missing = {};

  /// Bumped whenever the document changes, to key the thumbnail futures so a
  /// relink re-decodes rather than showing the stale picture. The frb equivalent
  /// of v0's `documentEpoch`.
  int _epoch = 0;

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final state = Provider.of<LumitState>(context);
    final roots = state.project?.getItems() ?? const <ItemReference>[];

    if (roots.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _importOnDoubleTap(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 240),
                  child: Text(
                    'No items yet — import footage or create a composition',
                    style: t.small,
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          ),
          _footer(t),
        ],
      );
    }

    _refreshMissing(roots);

    // The filter only bites while something is missing, so a healthy project can
    // never trap the user behind an empty "missing only" view.
    final anyMissing = _missing.values.any((m) => m);
    final missingOnly = _missingOnly && anyMissing;

    final rows = <Widget>[];
    _visibleIds.clear();
    void walk(ItemReference item, int depth) {
      final id = _idOf(item);
      final isMissingFootage =
          item is ItemReference_Footage && (_missing[id] ?? false);
      // In missing-only mode every visible row is something to fix (docs/07 §3.3).
      if (!missingOnly || isMissingFootage) {
        _visibleIds.add(id);
        rows.add(_ProjectRowFrb(
          key: ValueKey<String>('project-row-$id'),
          item: item,
          depth: depth,
          missing: isMissingFootage,
          epoch: _epoch,
          selected: _selectedIds.contains(id),
          renaming: _renamingId == id,
          selectionCount: _selectedIds.length,
          selectedFootage: () => _selectedFootage,
          onSelect: (modifier) => _select(id, modifier),
          onStartRename: () => setState(() => _renamingId = id),
          onEndRename: () => setState(() => _renamingId = null),
          onFindMissing: () => setState(() => _missingOnly = true),
          onLocalEdit: _documentChanged,
          relinkPicker: widget.relinkPicker,
        ));
      }
      if (item case ItemReference_Footage(:final field0)) {
        _footageById[id] = field0;
      }
      if (item is ItemReference_Folder) {
        for (final child in item.field0.getChildren()) {
          walk(child, depth + 1);
        }
      }
    }

    _footageById.clear();
    for (final item in roots) {
      walk(item, 0);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (anyMissing)
          _MissingHeaderFrb(
            count: _missing.values.where((m) => m).length,
            active: missingOnly,
            onToggle: () => setState(() => _missingOnly = !_missingOnly),
          ),
        Expanded(
          // Wrapping the list rather than sitting behind it: a sibling under a
          // ListView never sees a pointer, because the list is opaque across
          // its whole extent. As the parent it gets what the rows leave — and
          // a row's own double-tap wins the arena on the row itself.
          child: _importOnDoubleTap(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 4),
              children: rows,
            ),
          ),
        ),
        _footer(t),
      ],
    );
  }

  /// Double-clicking the panel's blank space imports, which is the gesture
  /// every editor has and the one people reach for before finding a menu.
  Widget _importOnDoubleTap({required Widget child}) => GestureDetector(
        key: const ValueKey('project-empty-area'),
        behavior: HitTestBehavior.opaque,
        onDoubleTap: _import,
        child: child,
      );

  /// Import and New composition, where the Project panel can reach them.
  ///
  /// They are on the menu bar too, and that is not duplication worth removing:
  /// the panel is where you are looking when you want them, and a panel that
  /// can only show what someone else put in it is a dead end.
  Widget _footer(LumitTheme t) => Container(
        height: 24,
        color: t.surface1,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        // Scrolls rather than overflowing — this panel is often docked narrow.
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              HouseButton(
                key: const ValueKey('project-import'),
                small: true,
                frameless: true,
                onPressed: _import,
                child: Text('Import…', style: t.small),
              ),
              const SizedBox(width: 6),
              // Footage dropped here makes a comp that matches it (docs/07 §3.1)
              // — the same dialog the button opens, with the media's own size,
              // rate and length already filled in, and every dropped item landing
              // in the finished comp as a layer.
              DragTarget<FootageDragData>(
                onAcceptWithDetails: (d) => _newComposition(d.data.footage),
                builder: (context, candidate, _) => Container(
                  foregroundDecoration: candidate.isEmpty
                      ? null
                      : BoxDecoration(border: Border.all(color: t.accent)),
                  child: HouseButton(
                    key: const ValueKey('project-new-comp'),
                    small: true,
                    frameless: true,
                    onPressed: _newComposition,
                    child: Text('New composition', style: t.small),
                  ),
                ),
              ),
            ],
          ),
        ),
      );

  Future<void> _import() async {
    final state = Provider.of<LumitState>(context, listen: false);
    if (await state
        .importFootagePaths(await (widget.importPicker ?? pickFootage)())) {
      _documentChanged();
    }
  }

  /// Ask for the new comp's settings, then make it. `footage` is whatever was
  /// dropped on the button; empty for a plain click.
  Future<void> _newComposition([
    List<FootageReference> footage = const [],
  ]) async {
    final state = Provider.of<LumitState>(context, listen: false);
    final comp = await state.newComposition(context, footage: footage);
    if (comp == null || !mounted) return;
    // Fronted because a comp you just made is the one you want to work on.
    Provider.of<LumitUiState>(context, listen: false).setSelectedComp(comp);
    _documentChanged();
  }

  /// An edit landed: re-probe and re-decode. Bumping the epoch is what makes a
  /// relink show the new picture rather than the cached one.
  void _documentChanged() {
    setState(() {
      _epoch++;
      _missing.clear();
    });
  }

  /// Fill in any footage status we do not yet know, off the build.
  ///
  /// `getStatus` probes the file, so this must never be awaited inside `build`.
  /// Statuses arrive over one or more frames and each one that changes triggers a
  /// rebuild; an item already known is not re-probed until [_documentChanged]
  /// clears the cache.
  void _refreshMissing(List<ItemReference> roots) {
    void walk(ItemReference item) {
      if (item is ItemReference_Footage) {
        final id = _idOf(item);
        if (!_missing.containsKey(id)) {
          // Claim the slot first, so a rebuild mid-probe does not probe twice.
          _missing[id] = false;
          item.field0.getStatus().then((status) {
            if (!mounted) return;
            final isMissing = status == LumitMediaStatus.missing;
            if (_missing[id] != isMissing) {
              setState(() => _missing[id] = isMissing);
            }
          });
        }
      }
      if (item is ItemReference_Folder) {
        item.field0.getChildren().forEach(walk);
      }
    }

    roots.forEach(walk);
  }
}

/// An item's id as a string, for keys and selection.
///
/// The generated references expose their ids under `internalid`; this is the one
/// place that name appears, so a future rename of the frb field is a one-line
/// change here rather than a sweep.
String _idOf(ItemReference item) => switch (item) {
      ItemReference_Footage(:final field0) => field0.internalid.toString(),
      ItemReference_Solid(:final field0) => field0.internalid.toString(),
      ItemReference_Composition(:final field0) => field0.internalid.toString(),
      ItemReference_Folder(:final field0) => field0.internalid.toString(),
    };

/// The header shown while the project has missing footage: a count and a
/// "show only missing" toggle.
class _MissingHeaderFrb extends StatelessWidget {
  final int count;
  final bool active;
  final VoidCallback onToggle;
  const _MissingHeaderFrb({
    required this.count,
    required this.active,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return LumitTooltip(
      message: active
          ? 'Showing only missing footage — click to show everything'
          : 'Show only missing footage',
      child: GestureDetector(
        key: const ValueKey('missing-toggle'),
        behavior: HitTestBehavior.opaque,
        onTap: onToggle,
        child: Container(
          height: 24,
          color: active ? t.accent.withValues(alpha: 0.12) : t.surface1,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              lumitIcon(LumitIcon.unlink, size: 13, color: t.warning),
              const SizedBox(width: 6),
              Text(
                '$count missing file${count == 1 ? '' : 's'}',
                style: t.small.copyWith(color: t.warning),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One Project panel row.
class _ProjectRowFrb extends StatefulWidget {
  final ItemReference item;
  final int depth;
  final bool missing;
  final int epoch;
  final bool selected;
  final bool renaming;

  /// How many rows are selected in all — a second click renames only when this
  /// row is the whole selection.
  final int selectionCount;
  final ValueChanged<SelectMode> onSelect;

  /// The panel's whole footage selection, read when a drag starts so dragging
  /// any selected row brings the rest with it.
  final List<FootageReference> Function() selectedFootage;
  final VoidCallback onStartRename;
  final VoidCallback onEndRename;
  final VoidCallback onFindMissing;

  /// Called after an edit this row made, so the panel re-reads at once rather
  /// than waiting for the engine's change stream to come back around.
  final VoidCallback onLocalEdit;
  final Future<String?> Function()? relinkPicker;

  const _ProjectRowFrb({
    super.key,
    required this.item,
    required this.depth,
    required this.missing,
    required this.epoch,
    required this.selected,
    required this.renaming,
    required this.selectionCount,
    required this.onSelect,
    required this.selectedFootage,
    required this.onStartRename,
    required this.onEndRename,
    required this.onFindMissing,
    required this.onLocalEdit,
    this.relinkPicker,
  });

  @override
  State<_ProjectRowFrb> createState() => _ProjectRowFrbState();
}

class _ProjectRowFrbState extends State<_ProjectRowFrb> {
  bool _hover = false;
  TextEditingController? _rename;
  final FocusNode _renameFocus = FocusNode();

  ItemReference get item => widget.item;

  @override
  void dispose() {
    _rename?.dispose();
    _renameFocus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_ProjectRowFrb old) {
    super.didUpdateWidget(old);
    if (widget.renaming && !old.renaming) {
      _rename = TextEditingController(text: _name());
      _renameFocus.requestFocus();
    }
  }

  String _name() {
    try {
      return item.name();
    } catch (_) {
      // The item was deleted from under us; the row is about to go anyway.
      return '';
    }
  }

  void _commitRename() {
    final text = _rename?.text.trim() ?? '';
    if (text.isNotEmpty && text != _name()) {
      item.rename(name: text);
      widget.onLocalEdit();
    }
    _rename?.dispose();
    _rename = null;
    widget.onEndRename();
  }

  /// A second click on the already-selected row starts an in-place rename — the
  /// AE click-to-rename-when-selected gesture. Held modifiers mean the click is
  /// about the *selection*, so they never start a rename, and neither does a
  /// click on a row that is one of several selected: renaming one row of four is
  /// not what that click asked for.
  void _handleTap() {
    final mode = _selectModeFromKeyboard();
    if (mode == SelectMode.replace &&
        widget.selected &&
        widget.selectionCount <= 1 &&
        !widget.renaming) {
      widget.onStartRename();
      return;
    }
    widget.onSelect(mode);
  }

  void _handleDoubleTap() {
    final uiState = Provider.of<LumitUiState>(context, listen: false);
    switch (item) {
      case ItemReference_Composition(:final field0):
        uiState.setSelectedComp(field0);
      case ItemReference_Footage(:final field0):
        _placeIntoFrontComp(uiState, field0);
      case ItemReference_Folder():
      case ItemReference_Solid():
        break;
    }
  }

  void _placeIntoFrontComp(LumitUiState uiState, FootageReference footage) {
    final comp = uiState.selectedComp;
    if (comp == null) return;
    comp.addFootageLayer(footage: footage);
    widget.onLocalEdit();
  }

  Future<void> _doRelink(FootageReference footage) async {
    final picker = widget.relinkPicker;
    final path = picker != null
        ? await picker()
        : await pickFootage()
            .then((paths) => paths.isEmpty ? null : paths.first);
    if (path == null) return;
    footage.relink(path: path);
    widget.onLocalEdit();
  }

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final row = MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _handleTap,
        onDoubleTap: _handleDoubleTap,
        onSecondaryTapDown: (d) {
          // A right-click on a row already in the selection keeps it: the menu
          // is about what is picked, and collapsing four rows to one because the
          // menu was opened would throw the selection away.
          if (!widget.selected) widget.onSelect(SelectMode.replace);
          showProjectMenuFrb(
            context: context,
            item: item,
            missing: widget.missing,
            position: d.globalPosition,
            onFindMissing: widget.onFindMissing,
            onLocalEdit: widget.onLocalEdit,
            onRelink: item is ItemReference_Footage
                ? () => _doRelink((item as ItemReference_Footage).field0)
                : null,
          );
        },
        child: Container(
          constraints: const BoxConstraints(minHeight: 22),
          color: widget.selected
              ? t.surface2
              : _hover
                  ? t.surface4
                  : null,
          padding: EdgeInsets.only(
            left: 6 + widget.depth * _indentPerDepth,
            right: 6,
          ),
          child: Row(
            children: [
              _leading(t),
              const SizedBox(width: 6),
              Expanded(child: _nameOrEditor(t)),
              if (widget.missing) ...[
                const SizedBox(width: 6),
                Text('missing', style: t.small.copyWith(color: t.warning)),
                const SizedBox(width: 6),
                LumitTooltip(
                  message: 'Relink this file to its new location',
                  child: HouseButton(
                    key: ValueKey<String>('relink-${_idOf(item)}'),
                    small: true,
                    onPressed: () =>
                        _doRelink((item as ItemReference_Footage).field0),
                    child: Text('Relink…', style: t.small),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );

    // Only footage drags onto the Timeline (or onto New composition), and the
    // payload must stay `FootageDragData` — those drop targets consume exactly
    // that, and nothing else produces it.
    if (item case ItemReference_Footage(:final field0)) {
      final name = _name();
      // Dragging a row that is part of the selection brings the whole selection;
      // dragging an unselected row is about that row alone, which is what every
      // file list does and what stops a stale selection following the pointer.
      final selection = widget.selected ? widget.selectedFootage() : const [];
      final dragged = selection.length > 1
          ? List<FootageReference>.from(selection)
          : <FootageReference>[field0];
      return Draggable<FootageDragData>(
        data: FootageDragData(
          dragged,
          dragged.length > 1 ? '${dragged.length} items' : name,
        ),
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: _DragFeedbackFrb(
          name: dragged.length > 1 ? '${dragged.length} items' : name,
        ),
        child: row,
      );
    }
    return row;
  }

  /// A decoded thumbnail for present footage, else the type glyph. Missing
  /// footage keeps the warning-tinted unlink glyph.
  Widget _leading(LumitTheme t) {
    final (icon, tint) = _iconFor(item, t);
    final glyph = lumitIcon(
      widget.missing ? LumitIcon.unlink : icon,
      size: 14,
      color: widget.missing ? t.warning : tint,
    );
    if (item is! ItemReference_Footage || widget.missing) return glyph;

    return _FootageThumbnailFrb(
      key: ValueKey<String>('thumb-${_idOf(item)}'),
      footage: (item as ItemReference_Footage).field0,
      epoch: widget.epoch,
      placeholder: glyph,
    );
  }

  Widget _nameOrEditor(LumitTheme t) {
    final controller = _rename;
    if (widget.renaming && controller != null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(
          color: t.surface0,
          borderRadius: BorderRadius.circular(t.tokens.controlRadius),
          border: Border.all(color: t.accent),
        ),
        child: EditableText(
          key: const ValueKey('rename-field'),
          controller: controller,
          focusNode: _renameFocus,
          style: t.body,
          cursorColor: t.accent,
          backgroundCursorColor: t.surface2,
          selectionColor: t.accent.withValues(alpha: 0.5),
          onSubmitted: (_) => _commitRename(),
          onTapOutside: (_) => _commitRename(),
        ),
      );
    }
    return Text(_name(), style: t.body, overflow: TextOverflow.ellipsis);
  }

  (LumitIcon, Color) _iconFor(ItemReference item, LumitTheme t) =>
      switch (item) {
        ItemReference_Footage() => (LumitIcon.footage, t.layer.footage),
        ItemReference_Folder() => (LumitIcon.folder, t.textMuted),
        ItemReference_Composition() => (LumitIcon.comp, t.layer.precomp),
        ItemReference_Solid() => (LumitIcon.solid, t.layer.solid),
      };
}

/// A footage row's thumbnail.
///
/// `FootageReference.thumbnail` is async on the Rust side, so a `FutureBuilder`
/// is the whole mechanism — the decode is already off the UI isolate. Keyed on
/// the document epoch so a relink re-decodes; the previous picture is held on
/// screen until the new one lands rather than flashing back to the glyph.
class _FootageThumbnailFrb extends StatefulWidget {
  final FootageReference footage;
  final int epoch;
  final Widget placeholder;

  const _FootageThumbnailFrb({
    super.key,
    required this.footage,
    required this.epoch,
    required this.placeholder,
  });

  @override
  State<_FootageThumbnailFrb> createState() => _FootageThumbnailFrbState();
}

class _FootageThumbnailFrbState extends State<_FootageThumbnailFrb> {
  static const double _w = 30;
  static const double _h = 17;

  ui.Image? _image;
  int _loadedEpoch = -1;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_FootageThumbnailFrb old) {
    super.didUpdateWidget(old);
    if (old.epoch != widget.epoch) _load();
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final epoch = widget.epoch;
    if (_loadedEpoch == epoch) return;

    final frame = await widget.footage.thumbnail(maxEdge: _thumbMaxEdge);
    if (!mounted) return;
    if (frame == null || frame.width == 0 || frame.height == 0) {
      // Do not hammer an item that has no thumbnail to give.
      _loadedEpoch = epoch;
      return;
    }

    ui.decodeImageFromPixels(
      frame.rgba,
      frame.width,
      frame.height,
      ui.PixelFormat.rgba8888,
      (image) {
        _loadedEpoch = epoch;
        if (!mounted) {
          image.dispose();
          return;
        }
        setState(() {
          _image?.dispose();
          _image = image;
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final image = _image;
    if (image == null) {
      return SizedBox(
        width: _w,
        height: _h,
        child: Center(child: widget.placeholder),
      );
    }
    return SizedBox(
      width: _w,
      height: _h,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: Container(
          color: t.surface0,
          child: RawImage(image: image, fit: BoxFit.contain),
        ),
      ),
    );
  }
}

/// The floating label shown under the pointer while a footage row is dragged.
class _DragFeedbackFrb extends StatelessWidget {
  final String name;
  const _DragFeedbackFrb({required this.name});

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return FloatSurface(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            lumitIcon(LumitIcon.footage, size: 13, color: t.layer.footage),
            const SizedBox(width: 6),
            Text(name, style: t.small),
          ],
        ),
      ),
    );
  }
}

enum _ProjectMenuAction {
  compSettings,
  relink,
  findMissing,
  moveToRoot,
  delete
}

/// The project context menu.
Future<void> showProjectMenuFrb({
  required BuildContext context,
  required ItemReference item,
  required bool missing,
  required Offset position,
  required VoidCallback onFindMissing,
  required VoidCallback onLocalEdit,
  Future<void> Function()? onRelink,
}) async {
  final isFootage = item is ItemReference_Footage;
  final isComp = item is ItemReference_Composition;
  final action = await showLumitPopup<_ProjectMenuAction>(
    context: context,
    position: position,
    builder: (close) => FloatSurface(
      width: 210,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (isComp)
            MenuRow(
              onPressed: () => close(_ProjectMenuAction.compSettings),
              child: const Text('Composition settings…'),
            ),
          // Relink is offered only on a row that is actually broken.
          if (isFootage && missing)
            MenuRow(
              onPressed: () => close(_ProjectMenuAction.relink),
              child: const Text('Relink…'),
            ),
          if (isFootage)
            MenuRow(
              onPressed: () => close(_ProjectMenuAction.findMissing),
              child: const Text('Find missing footage'),
            ),
          MenuRow(
            onPressed: () => close(_ProjectMenuAction.moveToRoot),
            child: const Text('Move to root'),
          ),
          MenuRow(
            onPressed: () => close(_ProjectMenuAction.delete),
            child: const Text('Delete'),
          ),
        ],
      ),
    ),
  );
  if (action == null) return;

  if (!context.mounted) return;
  switch (action) {
    case _ProjectMenuAction.compSettings:
      if (item case ItemReference_Composition(:final field0)) {
        // Reachable now that the dialog takes a CompositionReference rather than
        // an AppStateStub; the port had to drop this entry until it did.
        if (await showCompSettingsFrb(context: context, comp: field0)) {
          onLocalEdit();
        }
      }
    case _ProjectMenuAction.relink:
      await onRelink?.call();
    case _ProjectMenuAction.findMissing:
      onFindMissing();
    case _ProjectMenuAction.moveToRoot:
      item.moveToRoot();
      onLocalEdit();
    case _ProjectMenuAction.delete:
      // No confirmation: it is one undo step, matching egui.
      item.delete();
      onLocalEdit();
  }
}
