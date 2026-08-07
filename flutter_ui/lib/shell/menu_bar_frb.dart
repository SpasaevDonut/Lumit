// The menu bar: nine menus in the After Effects arrangement (K-244).
//
// **One tree, two renderers.** [lumitMenus] returns the whole bar as data —
// labels, shortcuts, enablement, ticks — and nothing in it knows how a menu is
// drawn. Windows and Linux get the in-app bar at the bottom of this file;
// macOS hands the same tree to the operating system through `PlatformMenuBar`,
// so Lumit's menus live in the Mac menu bar where every other Mac app's do,
// with Settings and About in the application menu as Apple's guidelines ask.
// Neither renderer holds a list of its own, which is the only way the two
// cannot drift apart.
//
// **What a row can say.** Every engine-backed item calls straight through a
// reference handle. An item with no action yet is still *listed*, marked
// "(Not implemented)" and disabled, so the shape of the finished application is
// visible while it is being built and nobody has to guess whether a command is
// missing or broken. An item whose command needs something that is not there —
// no project, no composition, no selected layer — greys out rather than failing
// when pressed: an item you can see is disabled tells you the state of the
// document, where one that does nothing when pressed does not.
//
// **Shortcuts are the engine's** (K-199). A row shows whatever chord the keymap
// currently binds to its action id, so rebinding in Settings ▸ Keymap changes
// the menus too, and a row whose action has no binding simply shows nothing.

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/main.dart';
import 'package:provider/provider.dart';

import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:lumit_flutter/src/rust/api/effect.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';

import '../panels/timeline_extras_frb.dart';
import '../state/clipboard.dart';
import '../state/dock.dart';
import '../state/file_dialogs.dart';
import '../state/keymap.dart';
import '../theme/theme.dart';
import '../widgets/controls.dart';
import 'about_window_frb.dart';
import 'command_palette_frb.dart';
import 'comp_settings_frb.dart';
import 'precompose_dialog_frb.dart';
import 'export_dialog_frb.dart';
import 'recovery_dialog_frb.dart';
import 'project_settings_frb.dart';
import 'settings_window_frb.dart';
import 'update_dialog_frb.dart';

/// One row of a menu: a label with an action, a submenu, or a divider.
///
/// [action] is a keymap action id, not a callback — the chord beside the row is
/// looked up from the live keymap when the bar is built. [todo] marks a command
/// that is specified but not built; it draws disabled with "(Not implemented)"
/// after its name. [checked] makes the row a toggle, drawn with a tick column.
class MenuEntry {
  final String? label;
  final VoidCallback? onPressed;
  final List<MenuEntry>? children;
  final bool isDivider;
  final String? action;
  final bool todo;
  final bool? checked;

  /// What this row watches, for the few rows whose wording changes while the
  /// menu is open. Null for every ordinary row — see [MenuEntry.live].
  final Listenable? live;

  /// How to rebuild this row when [live] fires. Null unless [live] is set.
  final MenuEntry Function()? rebuild;

  const MenuEntry(
    this.label,
    this.onPressed, {
    this.action,
    this.checked,
  })  : isDivider = false,
        children = null,
        todo = false,
        live = null,
        rebuild = null;

  const MenuEntry.divider()
      : label = null,
        onPressed = null,
        children = null,
        isDivider = true,
        action = null,
        todo = false,
        checked = null,
        live = null,
        rebuild = null;

  const MenuEntry.submenu(this.label, this.children)
      : onPressed = null,
        isDivider = false,
        action = null,
        todo = false,
        checked = null,
        live = null,
        rebuild = null;

  /// A command the specification has and the build has not.
  const MenuEntry.todo(this.label, {this.action})
      : onPressed = null,
        children = null,
        isDivider = false,
        todo = true,
        checked = null,
        live = null,
        rebuild = null;

  /// A row that redraws itself while its menu is open, from [rebuild], every
  /// time [live] fires — and which does *not* close the menu when pressed.
  ///
  /// Only for rows where the press has visible consequences in the row itself:
  /// Check for updates is the one, and it is the whole reason this exists
  /// (K-296). Pressing it starts a check, the row greys and says so, and the
  /// answer arrives in the same row a second or two later. A row that closed
  /// the menu would leave the user pressing Help again to find out what
  /// happened, and one that did not redraw would still say "Check for updates"
  /// while it was checking.
  const MenuEntry.live(Listenable this.live, MenuEntry Function() this.rebuild)
      : label = null,
        onPressed = null,
        children = null,
        isDivider = false,
        action = null,
        todo = false,
        checked = null;

  /// This row as it currently reads. The same row for everything except a
  /// [MenuEntry.live] one, which asks its builder.
  MenuEntry get current => rebuild == null ? this : rebuild!();

  /// What the row reads as, suffix and all.
  String get text => todo ? '$label (Not implemented)' : (label ?? '');

  /// Whether pressing this row does anything. A submenu is never "pressed" but
  /// is still live, so it counts as enabled when it has children.
  bool get enabled => onPressed != null || (children?.isNotEmpty ?? false);
}

/// One top-level menu.
typedef MenuSection = ({String title, List<MenuEntry> items});

class LumitMenuBarFrb extends StatelessWidget {
  final LumitState app;

  /// File-picker seams. Defaulted to the real dialogues; a test injects its own,
  /// because a plugin channel cannot open in a widget test.
  final Future<String?> Function()? openPicker;
  final Future<String?> Function()? savePicker;
  final Future<List<String>> Function()? footagePicker;

  const LumitMenuBarFrb({
    super.key,
    required this.app,
    this.openPicker,
    this.savePicker,
    this.footagePicker,
  });

  @override
  Widget build(BuildContext context) {
    // Half this bar's enablement is about the *selection* — the Effect menu,
    // Delete, Duplicate, Pre-compose, Retime — and the selection lives in a
    // ValueNotifier that does not notify the shell state. Without this the bar
    // would keep whatever selection it was last built with, and every one of
    // those rows would be greyed out with a layer plainly selected.
    // The updater is the second thing outside the shell state that a menu row
    // reads (K-296): the Help row says what it is doing, and on macOS the whole
    // tree is handed to the system, where there is no rebuilding a single row.
    return ValueListenableBuilder<List<LayerReference>>(
      valueListenable: context.read<LumitUiState>().selectedLayers,
      builder: (context, _, __) => ListenableBuilder(
        listenable: context.read<LumitUiState>().updates,
        builder: (context, _) => _bar(context),
      ),
    );
  }

  Widget _bar(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final menus = lumitMenus(
      context,
      app,
      openPicker: openPicker,
      savePicker: savePicker,
      footagePicker: footagePicker,
      palette: () => _palette(context),
    );

    // macOS puts menus in the system bar, not in the window (K-244). The bar
    // itself draws nothing here; the hotkey holder still has to be in the tree.
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      return PlatformMenuBar(
        menus: platformMenusFor(context, menus),
        child: _PaletteHotkey(onRequested: () => _palette(context)),
      );
    }

    return Container(
      height: 26,
      // **Load-bearing.** The scroll view below shrink-wraps to the width of
      // its Row, so without this the bar is only as wide as its nine headings
      // — and the Column above it, centring by default, puts that stub in the
      // middle of the window with the backdrop showing either side. The bar is
      // chrome: it spans the window, one colour, headings from the left edge.
      width: double.infinity,
      color: t.surface2,
      // Nine menu names do not fit a narrow window, and a menu you cannot
      // reach is worse than one you have to scroll to — so the bar scrolls
      // sideways rather than clipping its last headings away.
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            const SizedBox(width: 4),
            for (final menu in menus)
              _MenuButton(title: menu.title, items: menu.items),
            // Nothing to look at: it is here so `Ctrl+Shift+P` opens the same
            // palette this bar builds, rather than the shell building a second
            // one from a list that would drift out of step with these menus.
            _PaletteHotkey(onRequested: () => _palette(context)),
          ],
        ),
      ),
    );
  }

  /// The palette's commands are declared here, where the menu items are, so the
  /// two cannot drift apart into different ideas of what "New composition" does.
  /// Only shortcuts the key handler genuinely serves are taught — a palette
  /// that teaches a binding that does nothing is worse than one that is shy.
  /// Beyond commands it carries the other three categories docs/07 §12 asks
  /// for: every effect (applies to the selected layer), every comp (fronts
  /// it), and every panel (focuses it) — each under its own badge.
  Future<void> _palette(BuildContext context) async {
    final project = app.project;
    final ui = Provider.of<LumitUiState>(context, listen: false);
    await showCommandPaletteFrb(
      context: context,
      commands: [
        PaletteCommand(
          label: 'New',
          category: 'File',
          run: app.newProject,
        ),
        if (project != null) ...[
          PaletteCommand(
            label: 'Save',
            category: 'File',
            run: () => saveProjectFrb(app, ui, picker: savePicker),
          ),
          PaletteCommand(
            label: 'Save as…',
            category: 'File',
            run: () =>
                saveProjectFrb(app, ui, forcePicker: true, picker: savePicker),
          ),
          PaletteCommand(
            label: 'Import…',
            category: 'File',
            run: () => importFootageFrb(app, picker: footagePicker),
          ),
          PaletteCommand(
            label: 'New composition',
            category: 'Composition',
            run: () => newCompositionFrb(context, app),
          ),
          PaletteCommand(
            label: 'Undo',
            category: 'Edit',
            shortcut: 'Ctrl+Z',
            run: () => undoFrb(app),
          ),
          PaletteCommand(
            label: 'Redo',
            category: 'Edit',
            shortcut: 'Ctrl+Shift+Z',
            run: () => redoFrb(app),
          ),
          PaletteCommand(
            label: 'Export…',
            category: 'File',
            run: () => exportFrb(context),
          ),
          // Every comp, by name: Enter fronts it in the Viewer and Timeline.
          for (final (comp, name) in app.comps())
            PaletteCommand(
              label: name,
              category: 'Comp',
              run: () => ui.setSelectedComp(comp),
            ),
          // Every built-in effect: Enter applies it to the selected layer;
          // with none selected it does nothing, exactly like the browser.
          for (final effect in listEffects())
            PaletteCommand(
              label: effect.label,
              category: 'Effect',
              run: () => ui.selectedLayer.value?.addEffect(name: effect.name),
            ),
        ],
        // Every panel: Enter focuses it in the dock.
        for (final panel in Panel.values)
          PaletteCommand(
            label: panel.title,
            category: 'Panel',
            run: () => ui.activePanel.value = panel,
          ),
        PaletteCommand(
          label: 'Settings…',
          category: 'Edit',
          run: () => showSettingsWindowFrb(context),
        ),
        if (app.project case final project?)
          PaletteCommand(
            label: 'Project settings…',
            category: 'File',
            run: () => showProjectSettingsFrb(context, project),
          ),
      ],
    );
  }
}

// --- The tree -------------------------------------------------------------

/// Every menu, in bar order. Pure construction: it reads the document and the
/// shell state and hands back rows, so the two renderers below (and a test)
/// all see exactly the same bar.
List<MenuSection> lumitMenus(
  BuildContext context,
  LumitState app, {
  Future<String?> Function()? openPicker,
  Future<String?> Function()? savePicker,
  Future<List<String>> Function()? footagePicker,
  VoidCallback? palette,
}) {
  final ui = context.read<LumitUiState>();
  final project = app.project;
  // Null while no project is loaded, so every document item is disabled rather
  // than throwing when pressed.
  final history = project?.history();
  final comp = ui.selectedComp;
  final layer = ui.selectedLayer.value;
  final layers = ui.selectedLayers.value;

  /// Wrap a composition action: null (so the item greys out) when no
  /// composition is fronted, else the action followed by a redraw.
  VoidCallback? onComp(void Function(CompositionReference) run) {
    if (comp == null) return null;
    return () {
      run(comp);
      app.notifyDocumentChanged();
    };
  }

  /// The same, for a command that acts on the selected *layer* — greyed out
  /// with nothing selected rather than offered and inert.
  VoidCallback? onLayer(void Function(LayerReference) run) {
    if (layer == null) return null;
    return () => run(layer);
  }

  return [
    (title: 'File', items: [
      MenuEntry('New', app.newProject, action: 'file.new'),
      MenuEntry('Open project…', () => openProjectFrb(app, picker: openPicker),
          action: 'file.open'),
      MenuEntry.submenu('Open recent', [
        if (ui.workspace.recentProjects.isEmpty)
          const MenuEntry('Nothing yet', null)
        else
          for (final path in ui.workspace.recentProjects)
            MenuEntry(path, () => app.openProject(path)),
      ]),
      const MenuEntry.divider(),
      const MenuEntry.todo('Close project'),
      // Save is only meaningful once there is a project; without a path it
      // behaves as Save as, which is what the engine's empty-path refusal
      // makes us handle explicitly.
      MenuEntry(
          'Save',
          project == null
              ? null
              : () => saveProjectFrb(app, ui, picker: savePicker),
          action: 'file.save'),
      MenuEntry(
          'Save as…',
          project == null
              ? null
              : () =>
                  saveProjectFrb(app, ui, forcePicker: true, picker: savePicker),
          action: 'file.save.as'),
      const MenuEntry.divider(),
      MenuEntry(
          'Import…',
          project == null
              ? null
              : () => importFootageFrb(app, picker: footagePicker),
          action: 'file.import'),
      MenuEntry('Export…', comp == null ? null : () => exportFrb(context),
          action: 'file.export'),
      const MenuEntry.divider(),
      // The project's own settings, kept apart from Settings because Settings
      // is this machine's and these travel in the `.lum` (K-286).
      MenuEntry(
          'Project settings…',
          project == null
              ? null
              : () => showProjectSettingsFrb(context, project),
          action: 'project.settings'),
      const MenuEntry.divider(),
      // Not in the specified list, and kept: recovering work beside a project
      // is the one command whose absence costs a day's work.
      MenuEntry('Recover…',
          project?.path() == null ? null : () => _recover(context, app)),
    ]),
    (title: 'Edit', items: [
      MenuEntry('Undo', (history?.canUndo ?? false) ? () => undoFrb(app) : null,
          action: 'edit.undo'),
      MenuEntry('Redo', (history?.canRedo ?? false) ? () => redoFrb(app) : null,
          action: 'edit.redo'),
      const MenuEntry.todo('History'),
      const MenuEntry.divider(),
      // Copy takes the finest thing that is selected (K-300): the keyframes a
      // panel has claimed, else the picked effects, else the selected layer
      // whole — transform, keyframes, masks, paint, effects and switches — as
      // the document text the engine hands back (K-275). Cut is that plus the
      // delete, so the two can never disagree about what "the selection" was.
      MenuEntry(
          'Cut',
          _somethingSelected(ui) ? () => cutSelectionFrb(app, ui) : null,
          action: 'edit.cut'),
      MenuEntry('Copy', _somethingSelected(ui) ? () => copySelectionFrb(ui) : null,
          action: 'edit.copy'),
      // Paste puts a layer at the playhead — or at the time it was copied
      // from, for the person rebuilding a moment in a second comp (Settings →
      // Interface). An effect always lands with its first keyframe at the
      // playhead, whichever way that setting is: what is being placed is an
      // animation rather than a position.
      MenuEntry('Paste', _pasteAction(app, ui, comp, layer),
          action: 'edit.paste'),
      MenuEntry(
          'Delete',
          layers.isEmpty
              ? null
              : () {
                  for (final l in layers) {
                    l.delete();
                  }
                  ui.clearSelection();
                  app.notifyDocumentChanged();
                },
          action: 'edit.delete.selection'),
      const MenuEntry.divider(),
      MenuEntry(
          'Duplicate',
          onLayer((l) {
            l.duplicate();
            app.notifyDocumentChanged();
          }),
          action: 'layer.duplicate'),
      MenuEntry('Split layer', onComp((c) => _splitAtPlayhead(ui)),
          action: 'layer.split'),
      MenuEntry(
          'Select all',
          comp == null ? null : () => ui.setSelection(comp.getLayers()),
          action: 'edit.select.all'),
      MenuEntry('Deselect all', ui.clearSelection,
          action: 'edit.deselect.all'),
      const MenuEntry.divider(),
      // Windows and Linux keep Preferences under Edit, which is where every
      // application those users know puts it. macOS moves this same row into
      // the application menu (see [platformMenusFor]), which is where every
      // application *those* users know puts it.
      MenuEntry('Settings…', () => showSettingsWindowFrb(context),
          action: 'app.settings'),
    ]),
    (title: 'Composition', items: [
      MenuEntry('New composition',
          project == null ? null : () => newCompositionFrb(context, app),
          action: 'comp.new'),
      const MenuEntry.divider(),
      MenuEntry('Composition settings…',
          comp == null ? null : () => _compSettings(context, app),
          action: 'comp.settings'),
      const MenuEntry.todo('Trim comp to work area'),
      const MenuEntry.todo('Crop comp to work area'),
      const MenuEntry.divider(),
      // "Export", never "render", for anything the user sees (glossary §9).
      const MenuEntry.todo('Add to export queue', action: 'export.queue.add'),
      const MenuEntry.divider(),
      // Comp-level markers, including the beat pass, which makes them
      // (docs/09 §10) — the layer's own markers are Layer ▸ Markers.
      MenuEntry('Add marker at playhead', onComp((c) => _markerAtPlayhead(ui, c)),
          action: 'marker.add'),
      // Beat detection reads the whole comp's audio and can take seconds, so
      // it runs off-thread; a comp with no audio does nothing rather than
      // alarming.
      MenuEntry(
          'Detect beats',
          onComp((c) => c
              .detectBeats(sensitivityPercent: 50)
              .then((_) {}, onError: (_) {}))),
      MenuEntry('Clear beat markers', onComp((c) => c.clearBeatMarkers())),
    ]),
    (title: 'Layer', items: [
      MenuEntry.submenu('New', [
        MenuEntry('Solid', onComp((c) => c.addSolidLayer())),
        MenuEntry('Text', onComp((c) => c.addTextLayer())),
        MenuEntry('Camera', onComp((c) => c.addCameraLayer())),
        MenuEntry('Adjustment', onComp((c) => c.addAdjustmentLayer())),
        MenuEntry('Null', onComp((c) => c.addNullLayer())),
        MenuEntry('Sequence', onComp((c) => c.addSequenceLayer())),
      ]),
      const MenuEntry.todo('Layer settings…'),
      const MenuEntry.divider(),
      const MenuEntry.todo('Mask'),
      const MenuEntry.todo('Mask and shape path'),
      const MenuEntry.todo('Transform'),
      // The selected layer's Retime (K-197). In the menu as well as on the
      // keyboard (K-198's lesson: a command whose only route is a chord has no
      // route the day something intercepts the chord). The command names what
      // it will do, so a layer that already has one offers to take it away.
      // Greyed out on a Sequence layer: its clips carry the retiming and are
      // ramped in the sequence view (K-075), so there is nothing here for the
      // command to switch on. Said with a disabled row rather than an error
      // after the click.
      MenuEntry(
          _retimeLabel(layer),
          _retimeable(layer) ? onLayer((l) => app.toggleRetime(l)) : null,
          action: 'layer.retime.enable'),
      // In and out of the clip-editing surface, for anyone — the Vegas
      // preference decides what an *import* becomes (K-246), never what a
      // layer is allowed to be. Offered here and on a layer's right-click.
      // Coming back out is offered whenever going in is, because a user who
      // tries it has to be able to change their mind.
      MenuEntry(
          _sequenced(layer)
              ? 'Convert to footage layer'
              : 'Convert to sequence layer',
          _convertible(layer)
              ? onLayer((l) {
                  try {
                    if (_sequenced(layer)) {
                      l.convertFromSequenced();
                    } else {
                      l.convertToSequenced();
                    }
                    app.notifyDocumentChanged();
                  } catch (_) {
                    // A row of several clips refuses, and says so through the
                    // status line rather than taking the interface down.
                  }
                })
              : null,
          action: 'layer.sequence.convert'),
      const MenuEntry.todo('Flow'),
      const MenuEntry.todo('3D layer'),
      const MenuEntry.todo('Markers'),
      const MenuEntry.divider(),
      const MenuEntry.todo('Preserve transparency'),
      const MenuEntry.todo('Blending mode'),
      const MenuEntry.todo('Next blending mode'),
      const MenuEntry.todo('Previous blending mode'),
      const MenuEntry.todo('Track matte'),
      const MenuEntry.todo('Layer styles'),
      const MenuEntry.divider(),
      const MenuEntry.todo('Reveal'),
      const MenuEntry.todo('Create'),
      const MenuEntry.divider(),
      const MenuEntry.todo('Camera'),
      const MenuEntry.todo('Auto-outline'),
      // Pre-compose… is live only with a comp open and something selected in
      // it — the menu says so by greying out rather than by failing.
      MenuEntry(
          'Pre-compose…',
          comp == null || layers.isEmpty
              ? null
              : () => showPrecomposeDialogFrb(
                    context: context,
                    comp: comp,
                    selectedLayers: layers,
                    ui: ui,
                    workspace: ui.workspace,
                  ),
          action: 'layer.precompose'),
    ]),
    (title: 'Effect', items: _effectMenu(app, layers)),
    (title: 'Animation', items: const [
      MenuEntry.todo('Save animation preset'),
      MenuEntry.todo('Apply animation preset'),
      MenuEntry.divider(),
      MenuEntry.todo('Set keyframe'),
      MenuEntry.todo('Toggle hold keyframe'),
      MenuEntry.todo('Keyframe interpolation…'),
      MenuEntry.todo('Keyframe velocity…'),
      MenuEntry.divider(),
      MenuEntry.todo('Animate text'),
      MenuEntry.todo('Add text selector'),
      MenuEntry.divider(),
      MenuEntry.todo('Add expression'),
      MenuEntry.todo('Separate dimensions'),
      MenuEntry.todo('Track camera'),
      MenuEntry.todo('Track motion'),
      MenuEntry.divider(),
      MenuEntry.todo('Reveal properties with keyframes',
          action: 'reveal.animated'),
      MenuEntry.todo('Reveal properties with animation'),
      MenuEntry.todo('Reveal all modified properties'),
    ]),
    (title: 'View', items: const [
      MenuEntry.todo('Zoom in', action: 'viewer.zoom.in'),
      MenuEntry.todo('Zoom out', action: 'viewer.zoom.out'),
      MenuEntry.todo('Fit', action: 'viewer.zoom.fit'),
      MenuEntry.divider(),
      MenuEntry.submenu('Resolution', [
        MenuEntry.todo('Full', action: 'viewer.res.full'),
        MenuEntry.todo('Half', action: 'viewer.res.half'),
        MenuEntry.todo('Quarter', action: 'viewer.res.quarter'),
      ]),
      MenuEntry.divider(),
      MenuEntry.todo('Show grid', action: 'viewer.grid.toggle'),
      MenuEntry.todo('Show ruler', action: 'viewer.rulers.toggle'),
      MenuEntry.todo('Show wireframe'),
      MenuEntry.todo('Snap to grid'),
    ]),
    (title: 'Window', items: [
      MenuEntry.submenu('Workspace', [
        for (final preset in WorkspacePreset.values)
          MenuEntry(preset.title,
              () => ui.workspace.applyWorkspacePreset(preset),
              checked: ui.workspace.activePreset == preset),
        const MenuEntry.divider(),
        MenuEntry('Reset workspace', ui.resetLayout),
      ]),
      MenuEntry.todo(
          'Assign shortcut to ${ui.workspace.activePreset?.title ?? 'this'} '
          'workspace'),
      const MenuEntry.divider(),
      // Every panel, ticked when it is in the arrangement. Toggling one adds
      // or drops its pane and persists the layout, so a panel you closed stays
      // closed across a restart.
      for (final panel in Panel.values)
        MenuEntry(
          panel.title,
          () {
            setPanelVisible(
                ui.split, panel, !panelVisible(ui.split, panel));
            ui.workspace.touch();
          },
          checked: panelVisible(ui.split, panel),
        ),
      const MenuEntry.divider(),
      MenuEntry('Command palette…', palette, action: 'palette.open'),
    ]),
    (title: 'Help', items: [
      MenuEntry('About Lumit', () => showAboutWindowFrb(context)),
      MenuEntry.live(
        ui.updates,
        () => updateMenuEntry(context, app, ui, savePicker: savePicker),
      ),
      const MenuEntry.divider(),
      const MenuEntry.todo('Lumit help'),
      const MenuEntry.todo('Lumit online guides'),
      const MenuEntry.divider(),
      MenuEntry(
        'Enable debug panel',
        () {
          setPanelVisible(
              ui.split, Panel.debug, !panelVisible(ui.split, Panel.debug));
          ui.workspace.touch();
        },
        checked: panelVisible(ui.split, Panel.debug),
      ),
    ]),
  ];
}

/// The Effect menu: one submenu per effect category (K-090), each applying its
/// effect to every selected layer. Disabled outright with nothing selected —
/// there is nowhere for an effect to go.
List<MenuEntry> _effectMenu(LumitState app, List<LayerReference> layers) => [
      for (final group in _effectGroups().entries)
        MenuEntry.submenu(group.key, [
          for (final effect in group.value)
            MenuEntry(
              effect.label,
              layers.isEmpty
                  ? null
                  : () {
                      for (final layer in layers) {
                        layer.addEffect(name: effect.name);
                      }
                      app.notifyDocumentChanged();
                    },
            ),
        ]),
    ];

/// Every built-in effect, grouped by its heading, in the engine's own order.
///
/// Read once: the catalogue is fixed for the run, and the menu bar rebuilds on
/// every document change — a bridge call per rebuild is exactly the cost the
/// hover-hot paths are budgeted against.
Map<String, List<BridgeEffectInfo>> _effectGroups() =>
    _effectGroupsCache ??= () {
      final groups = <String, List<BridgeEffectInfo>>{};
      for (final effect in listEffects()) {
        groups.putIfAbsent(effect.categoryLabel, () => []).add(effect);
      }
      return groups;
    }();

Map<String, List<BridgeEffectInfo>>? _effectGroupsCache;

/// Whether this layer is a Sequence layer.
bool _sequenced(LayerReference? layer) {
  if (layer == null) return false;
  try {
    return layer.getKind() == BridgeLayerKind.sequence;
  } catch (_) {
    return false;
  }
}

/// Whether this layer can cross between footage and sequence at all. Only
/// footage has clips to cut, and only a sequence has any to put back.
bool _convertible(LayerReference? layer) {
  if (layer == null) return false;
  try {
    final kind = layer.getKind();
    return kind == BridgeLayerKind.footage || kind == BridgeLayerKind.sequence;
  } catch (_) {
    return false;
  }
}

/// Whether this layer can carry a Retime at all. A Sequence layer cannot: its
/// clips each have one of their own (K-075).
bool _retimeable(LayerReference? layer) {
  if (layer == null) return false;
  try {
    return layer.getKind() != BridgeLayerKind.sequence;
  } catch (_) {
    return false;
  }
}

/// What the Retime item says.
String _retimeLabel(LayerReference? layer) {
  if (layer == null) return 'Enable Retime';
  try {
    if (layer.getKind() == BridgeLayerKind.sequence) {
      return 'Retime (open the layer to ramp its clips)';
    }
    return layer.getRetimeProperty() == null
        ? 'Enable Retime'
        : 'Disable Retime';
  } catch (_) {
    return 'Enable Retime';
  }
}

// --- The commands ---------------------------------------------------------
//
// Free functions, not methods, because the keyboard runs the same commands the
// menu does (K-199 dispatch lives in main.dart) and a shortcut that took a
// different path than its menu item would be two implementations to keep
// honest. [saveProjectFrb] was the first of these (K-203); the rest followed
// when the menu grew shortcuts.

Future<void> openProjectFrb(LumitState app,
    {Future<String?> Function()? picker}) async {
  final path = await (picker ?? pickProjectToOpen)();
  if (path == null) return;
  app.openProject(path);
}

Future<void> importFootageFrb(LumitState app,
        {Future<List<String>> Function()? picker}) async =>
    app.importFootagePaths(await (picker ?? pickFootage)());

/// Make a composition and front it — a comp you just made is the one you want
/// to work on.
Future<void> newCompositionFrb(BuildContext context, LumitState app) async {
  final comp = await app.newComposition(context);
  if (comp != null && context.mounted) {
    context.read<LumitUiState>().setSelectedComp(comp);
  }
}

Future<void> exportFrb(BuildContext context) async {
  final comp = context.read<LumitUiState>().selectedComp;
  if (comp == null) return;
  await showExportDialogFrb(context: context, comp: comp);
}

void undoFrb(LumitState app) {
  app.project?.undo();
  app.notifyDocumentChanged();
}

void redoFrb(LumitState app) {
  app.project?.redo();
  app.notifyDocumentChanged();
}

/// Whether Cut and Copy have anything to act on — an effect picked out of a
/// stack, or a layer. Keyframes are not counted: the panel holding them claims
/// the chord, and a menu row that ungreyed on a selection the menu cannot see
/// would be guessing.
bool _somethingSelected(LumitUiState ui) =>
    ui.selectedEffects.value.isNotEmpty || ui.selectedLayer.value != null;

/// What Copy takes, finest selection first (K-300): the keyframes a panel has
/// claimed, else the picked effects, else the selected layer. Returns whether
/// anything was copied, so the keyboard can leave the chord unhandled when
/// there was nothing to take.
///
/// One function for the Edit menu and the `Mod+C` chord, because a menu row and
/// a shortcut that disagreed about what "the selection" is would be the bug
/// this fixes, one layer down.
bool copySelectionFrb(LumitUiState ui) {
  if (ui.copyClaim?.call() ?? false) return true;
  if (ui.selectedEffectsLayer case final layer?
      when ui.selectedEffects.value.isNotEmpty) {
    try {
      ui.copyEffectsToClipboard(
          layer.copyEffects(effects: ui.selectedEffects.value));
      return true;
    } catch (_) {
      // The effects went away under the selection; the clipboard keeps what it
      // had, and the layer below is not a silent substitute for what was asked.
      return false;
    }
  }
  final layer = ui.selectedLayer.value;
  if (layer == null) return false;
  ui.copyLayerToClipboard(layer.copyLayer());
  return true;
}

/// Cut is Copy plus the removal, so the two can never disagree about what the
/// selection was (K-275, extended to effects by K-300).
bool cutSelectionFrb(LumitState app, LumitUiState ui) {
  final effects = ui.selectedEffects.value;
  final effectsLayer = ui.selectedEffectsLayer;
  final layer = ui.selectedLayer.value;
  if (!copySelectionFrb(ui)) return false;
  if (effectsLayer != null && effects.isNotEmpty) {
    for (final instance in effectsLayer.getEffects()) {
      if (effects.contains(instance.getInfo().id)) {
        effectsLayer.removeEffect(effect: instance);
      }
    }
    ui.clearEffectSelection();
    app.notifyDocumentChanged();
    return true;
  }
  if (layer == null) return false;
  layer.delete();
  ui.clearSelection();
  app.notifyDocumentChanged();
  return true;
}

/// What Paste does with whatever is on the clipboard (K-275), or `null` when
/// there is nothing to paste — or nowhere to put it.
///
/// A layer goes into the composition on screen: at the playhead by default, or
/// at the time it was copied from when Settings → Interface says so. An effect
/// goes onto the selected layer, always with its first keyframe at the
/// playhead.
/// Paste for the `Mod+V` chord: a panel holding keyframes takes it first
/// (K-300, the same claim Delete has used since K-234), else the clipboard's
/// layer or effects go in. Returns whether anything was pasted.
///
/// The Edit menu's own row stays on [_pasteAction]: keyframes have never been
/// one of its cases, and a row that greys on the clipboard being empty must not
/// ungrey merely because the Timeline is open.
Future<bool> pasteSelectionFrb(
  LumitState app,
  LumitUiState ui,
  CompositionReference? comp,
  LayerReference? layer,
) async {
  if (ui.pasteClaim?.call() ?? false) return true;
  // Nothing in the tray: something may have been copied in another Lumit
  // window, or in this one before something else on the machine overwrote the
  // tray's mirror (K-302).
  if (ui.clipboard.isEmpty) await ui.adoptSystemClipboard();
  final paste = _pasteAction(app, ui, comp, layer);
  if (paste == null) return false;
  paste();
  return true;
}

VoidCallback? _pasteAction(
  LumitState app,
  LumitUiState ui,
  CompositionReference? comp,
  LayerReference? layer,
) {
  final text = ui.clipboard.text;
  if (text == null) return null;
  switch (ui.clipboard.kind) {
    case ClipboardKind.layer:
      if (comp == null) return null;
      return () {
        final pasted = comp.pasteLayer(
          text: text,
          atFrame: ui.workspace.interface.pasteLayersAtOriginalTime
              ? null
              : ui.playheadFrame.value,
        );
        // Selecting what was just pasted is what every editor does, and it is
        // also what makes a second paste land somewhere you can see.
        ui.setSelection([pasted]);
        app.notifyDocumentChanged();
      };
    case ClipboardKind.effects:
      if (layer == null) return null;
      return () {
        layer.pasteEffects(text: text, atFrame: ui.playheadFrame.value);
        app.notifyDocumentChanged();
      };
    case null:
      return null;
  }
}

/// Razor the selected layer at the playhead. Only Sequence layers hold clips,
/// so on anything else the engine declines and nothing happens.
void _splitAtPlayhead(LumitUiState ui) {
  final layer = ui.selectedLayer.value;
  if (layer == null) return;
  try {
    layer.cutClipAt(frame: ui.playheadFrame.value);
  } catch (_) {}
}

/// The menu's *Add marker* — the same call the keyboard makes, so the two
/// cannot drift into different ideas of what dropping a marker means (the
/// one-per-frame rule included).
void _markerAtPlayhead(LumitUiState ui, CompositionReference comp) =>
    addMarkerFrb(comp, frame: ui.playheadFrame.value);

Future<void> _compSettings(BuildContext context, LumitState app) async {
  final comp = context.read<LumitUiState>().selectedComp;
  if (comp == null) return;
  final applied = await showCompSettingsFrb(context: context, comp: comp);
  if (applied) app.notifyDocumentChanged();
}

/// Offer to recover work beside the open project.
///
/// Only meaningful once the project has a path — recovery is about a *file*,
/// and a project that has never been saved has nothing beside it.
Future<void> _recover(BuildContext context, LumitState app) async {
  final path = app.project?.path();
  if (path == null) return;
  await showRecoveryDialogFrb(
      context: context, state: app, projectPath: path);
}

/// Save the project, asking for a location only when there is not one already
/// — or always, for Save as.
///
/// The engine refuses an empty path on a project that has never been saved, so
/// whether to prompt is decided here from `path()` rather than by trying and
/// handling the failure.
///
/// [picker] is the injectable seam a widget test needs: no plugin channel can
/// open a real dialogue in one.
Future<void> saveProjectFrb(
  LumitState app,
  LumitUiState ui, {
  bool forcePicker = false,
  Future<String?> Function()? picker,
}) async {
  final project = app.project;
  if (project == null) return;

  var target = '';
  if (forcePicker || project.path() == null) {
    final picked = await (picker ?? pickProjectSaveLocation)();
    if (picked == null) return;
    target = picked;
  }
  // How the interface is arranged goes into the file, so a project handed to
  // someone else opens the way it was left (K-245). Written here rather than
  // as it changes, because this is the moment it is asked for: recording a
  // panel drag into the document would make moving furniture an unsaved change.
  project.setUiState(uiState: ui.sessionJson());
  try {
    final written = await project.save(path: target);
    app.postNotice('Saved to $written');
    // Save as gives the project a new path, and the session is filed by path —
    // and the title bar carries the name.
    ui.rememberSession();
    app.refreshWindowTitle();
  } catch (_) {
    // The work is still in the document and the journal; say so calmly and let
    // the user pick somewhere writable.
    app.postNotice('Could not save the project', error: true);
  }
  app.notifyDocumentChanged();
}

/// The Help ▸ Check for updates row, reading whatever the updater is doing
/// (K-296).
///
/// Built fresh every time the service notifies, which is what makes one row
/// carry the whole sequence: check, offer, download, restart. Disabled while
/// something is in flight — a second press during a check would start a second
/// one, and there is nothing useful for it to do.
MenuEntry updateMenuEntry(
  BuildContext context,
  LumitState app,
  LumitUiState ui, {
  Future<String?> Function()? savePicker,
}) {
  final updates = ui.updates;
  return MenuEntry(
    updates.menuLabel,
    updates.busy
        ? null
        : () => pressUpdateRow(
              context,
              updates: updates,
              notice: app.postNotice,
              projectIsDirty: () => app.project?.isDirty() ?? false,
              saveProject: () => saveProjectFrb(app, ui, picker: savePicker),
            ),
  );
}

// --- The macOS renderer ---------------------------------------------------

/// The same tree as native macOS menus.
///
/// Two Mac conventions are applied here and nowhere else, because they are only
/// conventions there: the application menu leads the bar, carrying About, the
/// system-provided Services/Hide/Quit rows and Settings — so Settings is lifted
/// out of Edit and About out of Help on that platform alone. Ticks are drawn as
/// a leading mark in the label, since Flutter's platform-menu API has no
/// checked state of its own.
///
/// ponytail: labels carry the tick; a real checkmark needs a channel of our own.
List<PlatformMenuItem> platformMenusFor(
    BuildContext context, List<MenuSection> menus) {
  final keymap = context.read<LumitUiState>().keymap;

  List<PlatformMenuItem> rows(List<MenuEntry> items) {
    final out = <PlatformMenuItem>[];
    var group = <PlatformMenuItem>[];
    void flush() {
      if (group.isEmpty) return;
      out.add(PlatformMenuItemGroup(members: group));
      group = [];
    }

    for (final raw in items) {
      if (raw.isDivider) {
        flush();
        continue;
      }
      // A live row resolves to whatever it currently reads. The Mac menu is
      // rebuilt whenever the bar is, and the bar watches the same object the
      // row does, so this stays in step without the in-app renderer's
      // rebuild-in-place machinery.
      final item = raw.current;
      final label = switch (item.checked) {
        true => '✓ ${item.text}',
        false => '  ${item.text}',
        null => item.text,
      };
      if (item.children case final children?) {
        group.add(PlatformMenu(label: label, menus: rows(children)));
        continue;
      }
      final chord = item.action == null ? null : keymap.rawChordFor(item.action!);
      group.add(PlatformMenuItem(
        label: label,
        // A null callback is how the platform menu draws a row disabled.
        onSelected: item.onPressed,
        shortcut: chord == null ? null : activatorForChord(chord),
      ));
    }
    flush();
    return out;
  }

  // Settings and About move into the application menu; the menus they came
  // from lose exactly those rows.
  MenuEntry? take(String title, String label) {
    for (final menu in menus) {
      if (menu.title != title) continue;
      for (final item in menu.items) {
        if (item.label == label) return item;
      }
    }
    return null;
  }

  final settings = take('Edit', 'Settings…');
  final about = take('Help', 'About Lumit');

  return [
    PlatformMenu(label: 'Lumit', menus: [
      PlatformMenuItemGroup(members: [
        PlatformMenuItem(
            label: 'About Lumit', onSelected: about?.onPressed),
      ]),
      PlatformMenuItemGroup(members: [
        if (settings != null)
          PlatformMenuItem(
            label: 'Settings…',
            onSelected: settings.onPressed,
            shortcut: activatorForChord(
                keymap.rawChordFor('app.settings') ?? ''),
          ),
      ]),
      const PlatformMenuItemGroup(members: [
        PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.servicesSubmenu),
      ]),
      const PlatformMenuItemGroup(members: [
        PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hide),
        PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hideOtherApplications),
        PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.showAllApplications),
      ]),
      const PlatformMenuItemGroup(members: [
        PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit),
      ]),
    ]),
    for (final menu in menus)
      PlatformMenu(
        label: menu.title,
        menus: rows([
          for (final item in menu.items)
            if (!identical(item, settings) && !identical(item, about)) item,
        ]),
      ),
  ];
}

// --- The in-app renderer --------------------------------------------------

/// Watches [LumitUiState.paletteRequest] and opens the palette when the
/// shortcut bumps it. Draws nothing; it exists only to hold the subscription,
/// so the menu bar itself stays a plain stateless widget.
class _PaletteHotkey extends StatefulWidget {
  final VoidCallback onRequested;

  const _PaletteHotkey({required this.onRequested});

  @override
  State<_PaletteHotkey> createState() => _PaletteHotkeyState();
}

class _PaletteHotkeyState extends State<_PaletteHotkey> {
  ValueNotifier<int>? _bound;

  @override
  Widget build(BuildContext context) {
    // `read`, not `watch`: this widget draws nothing, so a rebuild per change
    // of the shell state would be pure cost. The state itself outlives the
    // window, so the notifier it hands over never changes under us.
    final requests = context.read<LumitUiState>().paletteRequest;
    if (requests != _bound) {
      _bound?.removeListener(_open);
      _bound = requests..addListener(_open);
    }
    return const SizedBox.shrink();
  }

  void _open() {
    if (mounted) widget.onRequested();
  }

  @override
  void dispose() {
    _bound?.removeListener(_open);
    super.dispose();
  }
}

/// The heading whose menu is up, and the handle that takes it down.
///
/// While one menu is open the bar is *in menus*: crossing another heading hands
/// over to it rather than making the user click a second time, which is how the
/// bar behaves in every application these menus sit beside. One pair for the
/// whole bar, because only one menu is ever open.
String? _openHeading;
VoidCallback? _closeHeading;

class _MenuButton extends StatelessWidget {
  final String title;
  final List<MenuEntry> items;
  const _MenuButton({required this.title, required this.items});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      // Only once a menu is already open: hovering the bar with nothing open
      // must not start dropping menus at a passing pointer.
      onEnter: (_) {
        if (_openHeading != null && _openHeading != title) _open(context);
      },
      child: HouseButton(
        key: ValueKey<String>('menu-$title'),
        frameless: true,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        onPressed: () => _open(context),
        child: Text(title),
      ),
    );
  }

  void _open(BuildContext context) {
    final box = context.findRenderObject();
    if (box is! RenderBox) return;
    final origin = box.localToGlobal(Offset(0, box.size.height));
    _closeHeading?.call();
    _openHeading = title;
    showLumitPopup<void>(
      context: context,
      position: origin,
      // The bar underneath has to keep feeling the pointer; that is the whole
      // mechanism of handing over to the next heading.
      hoverThrough: true,
      builder: (close) {
        if (_openHeading == title) _closeHeading = () => close(null);
        return _OpenMenu(
          title: title,
          child: _MenuList(items: items, close: () => close(null)),
        );
      },
    );
  }
}

/// The open menu itself, which forgets it is open when it goes.
///
/// Told by disposal rather than by the close call, so a menu that goes with its
/// window — a test ending, a reload — leaves the bar out of menus too, rather
/// than with a heading it thinks is still open.
class _OpenMenu extends StatefulWidget {
  final String title;
  final Widget child;
  const _OpenMenu({required this.title, required this.child});

  @override
  State<_OpenMenu> createState() => _OpenMenuState();
}

class _OpenMenuState extends State<_OpenMenu> {
  @override
  Widget build(BuildContext context) => widget.child;

  @override
  void dispose() {
    // Not if another heading has already taken over: this menu's disposal
    // arrives a frame after the one that replaced it opened.
    if (_openHeading == widget.title) {
      _openHeading = null;
      _closeHeading = null;
    }
    super.dispose();
  }
}

class _MenuList extends StatelessWidget {
  final List<MenuEntry> items;
  final VoidCallback close;
  const _MenuList({required this.items, required this.close});

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final keymap = context.read<LumitUiState>().keymap;
    // A tick column only where something in this menu is a toggle, so an
    // ordinary menu is not indented for a mark it never shows.
    final ticks = items.any((i) => i.checked != null);
    // A long menu on a short window would otherwise run off the bottom, where
    // the last items cannot be clicked at all — so it scrolls once it no longer
    // fits. `- 40` leaves the menu bar itself and a margin.
    final maxHeight =
        (MediaQuery.of(context).size.height - 40).clamp(80.0, 1e6);
    return FloatSurface(
      width: 300,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final item in items)
                if (item.isDivider)
                  Container(
                    height: 1,
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    color: t.hairline,
                  )
                else if (item.children case final children?)
                  SubmenuRow(
                    key: ValueKey<String>('menu-sub-${item.label}'),
                    closeParent: close,
                    submenu: (dismiss) =>
                        _MenuList(items: children, close: dismiss),
                    child: _label(t, item, ticks: ticks, shortcut: null),
                  )
                else if (item.live case final listenable?)
                  // Stays open and redraws in place: the point of a live row is
                  // to watch what pressing it did (K-296).
                  ListenableBuilder(
                    listenable: listenable,
                    builder: (context, _) {
                      final row = item.current;
                      return MenuRow(
                        onPressed: row.onPressed ?? () {},
                        child: _label(t, row, ticks: ticks, shortcut: null),
                      );
                    },
                  )
                else
                  MenuRow(
                    onPressed: item.onPressed == null
                        ? close
                        : () {
                            close();
                            item.onPressed!();
                          },
                    child: _label(
                      t,
                      item,
                      ticks: ticks,
                      shortcut: item.action == null
                          ? null
                          : keymap.chordFor(item.action!),
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }

  /// One row's contents: the tick column where the menu has toggles, the name,
  /// and the chord it answers to on the right.
  Widget _label(LumitTheme t, MenuEntry item,
      {required bool ticks, required String? shortcut}) {
    final style = item.enabled ? null : t.body.copyWith(color: t.textDisabled);
    return Row(
      children: [
        if (ticks)
          SizedBox(
            width: 16,
            child: item.checked == true ? Text('✓', style: style) : null,
          ),
        Expanded(child: Text(item.text, style: style)),
        if (shortcut != null)
          Padding(
            padding: const EdgeInsets.only(left: 16),
            child: Text(shortcut, style: t.small.copyWith(color: t.textMuted)),
          ),
      ],
    );
  }
}
