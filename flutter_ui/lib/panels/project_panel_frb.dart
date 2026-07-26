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

import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/src/rust/api/footage.dart';
import 'package:lumit_flutter/src/rust/api/project_item.dart';
import 'package:lumit_flutter/src/rust/api/state.dart';
import 'package:provider/provider.dart';

import '../icons/icons.dart';
import '../state/app_state.dart' show FootageDragData;
import '../state/file_dialogs.dart';
import '../theme/theme.dart';
import '../widgets/controls.dart';

/// The longer edge a row thumbnail is decoded at: ~28 logical px at 2× for
/// crispness on a high-DPI display.
const int _thumbMaxEdge = 56;

/// How far each nesting level indents a row.
const double _indentPerDepth = 14;

class ProjectPanelFrb extends StatefulWidget {
  /// The relink file picker seam (chosen path, or null when cancelled). Defaults
  /// to the real footage picker; tests inject their own so no plugin channel
  /// opens.
  final Future<String?> Function()? relinkPicker;

  const ProjectPanelFrb({super.key, this.relinkPicker});

  @override
  State<ProjectPanelFrb> createState() => _ProjectPanelFrbState();
}

class _ProjectPanelFrbState extends State<ProjectPanelFrb> {
  bool _missingOnly = false;

  StreamSubscription<ScopedChange>? _changes;

  @override
  void initState() {
    super.initState();
    // Every committed edit reaches us here, whoever made it — this panel, the
    // menu bar, an undo. That is the point of the scoped-change stream: no panel
    // has to be told about an edit it did not make, and none has to poll.
    final state = Provider.of<LumitState>(context, listen: false);
    _changes = state.onChange.listen((_) => _documentChanged());
  }

  @override
  void dispose() {
    _changes?.cancel();
    super.dispose();
  }

  /// The item currently selected, by id. Held here rather than in `LumitUiState`
  /// because nothing outside this panel reads it yet.
  String? _selectedId;

  /// The row being renamed in place, by id.
  String? _renamingId;

  /// Which footage items failed to resolve, by id.
  ///
  /// Cached because `getStatus` probes the file, which is far too slow to do in a
  /// build — and because the missing-only filter has to know every item's status
  /// at once to decide what to draw. Refreshed when the document changes.
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
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 240),
          child: Text(
            'No items yet — import footage or create a composition',
            style: t.small,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    _refreshMissing(roots);

    // The filter only bites while something is missing, so a healthy project can
    // never trap the user behind an empty "missing only" view.
    final anyMissing = _missing.values.any((m) => m);
    final missingOnly = _missingOnly && anyMissing;

    final rows = <Widget>[];
    void walk(ItemReference item, int depth) {
      final id = _idOf(item);
      final isMissingFootage = item is ItemReference_Footage && (_missing[id] ?? false);
      // In missing-only mode every visible row is something to fix (docs/07 §3.3).
      if (!missingOnly || isMissingFootage) {
        rows.add(_ProjectRowFrb(
          key: ValueKey<String>('project-row-$id'),
          item: item,
          depth: depth,
          missing: isMissingFootage,
          epoch: _epoch,
          selected: _selectedId == id,
          renaming: _renamingId == id,
          onSelect: () => setState(() => _selectedId = id),
          onStartRename: () => setState(() => _renamingId = id),
          onEndRename: () => setState(() => _renamingId = null),
          onFindMissing: () => setState(() => _missingOnly = true),
          relinkPicker: widget.relinkPicker,
        ));
      }
      if (item is ItemReference_Folder) {
        for (final child in item.field0.getChildren()) {
          walk(child, depth + 1);
        }
      }
    }

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
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 4),
            children: rows,
          ),
        ),
      ],
    );
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
  final VoidCallback onSelect;
  final VoidCallback onStartRename;
  final VoidCallback onEndRename;
  final VoidCallback onFindMissing;
  final Future<String?> Function()? relinkPicker;

  const _ProjectRowFrb({
    super.key,
    required this.item,
    required this.depth,
    required this.missing,
    required this.epoch,
    required this.selected,
    required this.renaming,
    required this.onSelect,
    required this.onStartRename,
    required this.onEndRename,
    required this.onFindMissing,
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
    }
    _rename?.dispose();
    _rename = null;
    widget.onEndRename();
  }

  /// A second click on the already-selected row starts an in-place rename — the
  /// AE click-to-rename-when-selected gesture.
  void _handleTap() {
    if (widget.selected && !widget.renaming) {
      widget.onStartRename();
    } else {
      widget.onSelect();
    }
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
  }

  Future<void> _doRelink(FootageReference footage) async {
    final picker = widget.relinkPicker;
    final path = picker != null
        ? await picker()
        : await pickFootage().then((paths) => paths.isEmpty ? null : paths.first);
    if (path == null) return;
    footage.relink(path: path);
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
          widget.onSelect();
          showProjectMenuFrb(
            context: context,
            item: item,
            missing: widget.missing,
            position: d.globalPosition,
            onFindMissing: widget.onFindMissing,
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

    // Only footage drags onto the Timeline, and the payload must stay
    // `FootageDragData` — the Timeline's drop target consumes exactly that, and
    // nothing else produces it.
    if (item case ItemReference_Footage(:final field0)) {
      final name = _name();
      return Draggable<FootageDragData>(
        data: FootageDragData(field0.internalid.toString(), name),
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: _DragFeedbackFrb(name: name),
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

  (LumitIcon, Color) _iconFor(ItemReference item, LumitTheme t) => switch (item) {
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

enum _ProjectMenuAction { relink, findMissing, moveToRoot, delete }

/// The project context menu.
///
/// Composition settings is deliberately absent for now: the dialog it opens takes
/// an `AppStateStub`, so it cannot be reached from an frb panel until it is
/// ported with the Timeline. The menu bar's own Composition ▸ Composition
/// settings… still reaches it, so the capability is not lost — only this shortcut
/// to it. Tracked in docs/TODO.md.
Future<void> showProjectMenuFrb({
  required BuildContext context,
  required ItemReference item,
  required bool missing,
  required Offset position,
  required VoidCallback onFindMissing,
  Future<void> Function()? onRelink,
}) async {
  final isFootage = item is ItemReference_Footage;
  final action = await showLumitPopup<_ProjectMenuAction>(
    context: context,
    position: position,
    builder: (close) => FloatSurface(
      width: 210,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
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

  switch (action) {
    case _ProjectMenuAction.relink:
      await onRelink?.call();
    case _ProjectMenuAction.findMissing:
      onFindMissing();
    case _ProjectMenuAction.moveToRoot:
      item.moveToRoot();
    case _ProjectMenuAction.delete:
      // No confirmation: it is one undo step, matching egui.
      item.delete();
  }
}
