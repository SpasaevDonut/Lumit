// The Settings window, on the flutter_rust_bridge API.
//
// **The shape (K-193).** A sidebar of pages down the left, one page at a time
// on the right: a page is a stack of named *sections*, and a section is a card
// of rows. Every row reads the same way — what it is, a line saying what it
// does, and its control on the right edge — which is the arrangement the egui
// shell used and the one the owner asked to come back. It replaces a single
// scrolling column of five groups that had grown past the height of a window.
//
// **What lives where.** Appearance is Dart's own: the theme is the frontend's
// and the engine has no opinion about it. Interface is likewise a set of
// working preferences, persisted in the workspace file. Performance is mostly
// a readout of the engine with a button — the cache budgets are the numbers
// here that change engine behaviour, and even those are not part of the
// document, so nothing in this window is undoable.
//
// **Keymap (K-199)** is the one page that is not a settings form: it is a
// table of every shortcut, grouped by where it is live, with the action on the
// left and its chord on the right — click a chord and press the keys you want.
// It edits the engine's keymap, not a copy, so what the table shows is what the
// keyboard does.
//
// Pages the settings do not have yet (Export defaults, colour management —
// docs/TODO.md) are not listed: an empty page is a promise the window cannot
// keep.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/src/rust/api/cache.dart';
import 'package:lumit_flutter/src/rust/api/keymap.dart';
import 'package:lumit_flutter/src/rust/api/project.dart';
import 'package:lumit_flutter/src/rust/api/shell.dart';
import 'package:lumit_flutter/src/rust/api/system.dart';
import 'package:provider/provider.dart';

import '../l10n/engine_labels.dart';
import '../l10n/strings.dart';
import '../state/file_dialogs.dart';
import '../state/keymap.dart';
import '../state/settings.dart';
import '../state/updates.dart';
import '../state/workspace.dart';
import '../theme/theme.dart';
import '../widgets/controls.dart';
import 'about_window_frb.dart';
import 'cache_confirm_frb.dart';
import 'menu_bar_frb.dart';
import 'settings_rows.dart';
import 'theme_editor_frb.dart';
import 'update_dialog_frb.dart';

/// The smallest budget worth setting, in MiB. Below this the cache holds a
/// frame or two and costs more in bookkeeping than it saves.
const double _minBudgetMib = 64;

/// The ceiling when the machine will not say how much it has (K-194): every
/// platform but Windows, so far. Generous rather than clever — the engine
/// clamps to what it can actually allocate either way.
const double _unknownMemoryMib = 16384;

/// One page in the sidebar.
enum SettingsPage {
  general,
  appearance,
  interface,
  keymap,
  performance;

  /// The name in the sidebar. A getter rather than a constructor argument
  /// because an enum constant is built once, at start-up, and the language can
  /// change after that.
  String get label => switch (this) {
        SettingsPage.general => l10n.settingsPageGeneral,
        SettingsPage.appearance => l10n.settingsPageAppearance,
        SettingsPage.interface => l10n.settingsPageInterface,
        SettingsPage.keymap => l10n.settingsPageKeymap,
        SettingsPage.performance => l10n.settingsPagePerformance,
      };
}

/// The size the window opens at the first time (K-242). Bigger than the 700×460
/// it was fixed at, because that was sized for the smallest laptop and left the
/// Keymap table scrolling four rows at a time on anything larger; the corner
/// grip takes it from here, and where it is left is remembered.
const Size _settingsSize = Size(880, 640);

/// Below this the sidebar and the widest setting row stop fitting side by side.
const Size _settingsMinSize = Size(560, 380);

Future<void> showSettingsWindowFrb(BuildContext context) =>
    showLumitModal<void>(
      context: context,
      id: 'settings',
      initialSize: _settingsSize,
      minSize: _settingsMinSize,
      builder: (close) => _SettingsWindow(onClose: () => close(null)),
    );

class _SettingsWindow extends StatefulWidget {
  final VoidCallback onClose;
  const _SettingsWindow({required this.onClose});

  @override
  State<_SettingsWindow> createState() => _SettingsWindowState();
}

/// Whether a cache-location choice is this project's or the application's
/// (docs/07 §15). Interface-only: the engine stores the two in different places —
/// one in the document, one in the settings file — and this is the control that
/// says which the user means.
enum CacheScope { everywhere, thisProject }

class _SettingsWindowState extends State<_SettingsWindow> {
  SettingsPage _page = SettingsPage.general;

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final ui = Provider.of<LumitUiState>(context);

    // No width or height of its own: the window frame around it is what has the
    // size, so the corner grip can change it (K-242).
    return FloatSurface(
      child: SizedBox.expand(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
              child: Row(
                children: [
                  Expanded(
                      child: Text(l10n.settingsTitle, style: t.bodyPrimary)),
                  HouseButton(
                    key: const ValueKey('settings-close'),
                    small: true,
                    onPressed: widget.onClose,
                    child: Text(l10n.done),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: 150, child: _sidebar(t)),
                  Container(width: 1, color: t.hairline),
                  Expanded(child: _pageBody(t, ui)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sidebar(LumitTheme t) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final page in SettingsPage.values)
              GestureDetector(
                key: ValueKey<String>('settings-page-${page.name}'),
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _page = page),
                child: Container(
                  margin: const EdgeInsets.symmetric(vertical: 2),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: _page == page ? t.accent : null,
                    borderRadius: BorderRadius.circular(t.tokens.controlRadius),
                  ),
                  child: Center(
                    child: Text(
                      page.label,
                      style: _page == page ? t.bodyPrimary : t.body,
                    ),
                  ),
                ),
              ),
          ],
        ),
      );

  Widget _pageBody(LumitTheme t, LumitUiState ui) => ListView(
        key: ValueKey<String>('settings-body-${_page.name}'),
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 14),
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(_page.label, style: t.bodyPrimary),
          ),
          ...switch (_page) {
            SettingsPage.general => _general(t, ui),
            SettingsPage.appearance => _appearance(t, ui),
            SettingsPage.interface => _interface(t, ui),
            SettingsPage.keymap => _keymap(t, ui),
            SettingsPage.performance => _performance(t, ui),
          },
        ],
      );

  // ---- the pages -----------------------------------------------------------

  List<Widget> _general(LumitTheme t, LumitUiState ui) => [
        settingsSection(t, l10n.settingsGroupWorkspace, [
          settingsRow(
            t,
            l10n.settingsPanelLayout,
            l10n.settingsHelpPanelLayout,
            HouseButton(
              key: const ValueKey('settings-reset-workspace'),
              small: true,
              onPressed: () => setState(ui.resetLayout),
              child: Text(l10n.menuResetWorkspace, style: t.small),
            ),
          ),
        ]),
        // The same updater the Help menu drives, seen from the other side
        // (K-296): one service, two views, so they can never disagree about
        // whether a check is running or an update is waiting.
        settingsSection(t, l10n.settingsGroupUpdates, [
          settingsRow(
            t,
            l10n.settingsAutomaticUpdates,
            l10n.settingsHelpAutomaticUpdates,
            HouseCheckbox(
              key: const ValueKey('settings-auto-update'),
              value: ui.workspace.autoUpdate,
              onChanged: (on) => setState(() => ui.workspace.setAutoUpdate(on)),
            ),
          ),
          // The whole row watches the service, not just its button: the line
          // under the title is the part that says what was found, and a stale
          // sentence beside a live button would be worse than either alone.
          ListenableBuilder(
            listenable: ui.updates,
            builder: (context, _) => settingsRow(
              t,
              l10n.settingsThisVersion,
              _updateStatusLine(ui),
              HouseButton(
                key: const ValueKey('settings-check-updates'),
                small: true,
                onPressed: ui.updates.busy
                    ? null
                    : () => pressUpdateRow(
                          context,
                          updates: ui.updates,
                          notice: context.read<LumitState>().postNotice,
                          projectIsDirty: () =>
                              context.read<LumitState>().project?.isDirty() ??
                              false,
                          saveProject: () =>
                              saveProjectFrb(context.read<LumitState>(), ui),
                        ),
                child: Text(ui.updates.menuLabel, style: t.small),
              ),
            ),
          ),
        ]),
        // About used to sit here. It is Help ▸ About Lumit now (K-244):
        // Settings is for what you change, and a version number is not that.
      ];

  /// The line under "This version": what is installed, and what the last check
  /// made of it. Rebuilt with the row, so it follows the service too.
  String _updateStatusLine(LumitUiState ui) {
    final installed = 'Lumit ${versionFromBootLine(lumitVersion()) ?? '?'}';
    return switch (ui.updates.stage) {
      UpdateStage.upToDate => l10n.updateUpToDate(installed),
      UpdateStage.available =>
        l10n.updateAvailable(installed, '${ui.updates.release?.version}'),
      UpdateStage.ready =>
        l10n.updateReady(installed, '${ui.updates.release?.version}'),
      UpdateStage.failed =>
        '$installed. ${ui.updates.failure ?? l10n.updateCheckDidNotFinish}',
      _ => installed,
    };
  }

  List<Widget> _appearance(LumitTheme t, LumitUiState ui) => [
        settingsSection(t, l10n.settingsGroupTheme, [
          settingsRow(
            t,
            l10n.settingsColourScheme,
            l10n.settingsHelpColourScheme,
            SizedBox(
              width: 150,
              child: BareDropdown<ThemeChoice>(
                key: const ValueKey('settings-scheme'),
                value: ui.workspace.themeChoice,
                options: ui.workspace.themeChoices,
                label: (c) => c.label,
                // Dark, Light, then the user's own (K-202): seven built-ins
                // and a growing list of custom themes is a long flat menu,
                // and light/dark is the first thing anyone is choosing by.
                group: (c) => c.group,
                onChanged: (c) => setState(() => ui.workspace.choose(c)),
              ),
            ),
          ),
          settingsRow(
            t,
            l10n.settingsCustomColours,
            ui.workspace.customThemeName == null
                ? l10n.settingsHelpCustomColours
                : l10n.settingsHelpEditingTheme(
                    '${ui.workspace.customThemeName}'),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (ui.workspace.customThemeName != null) ...[
                  HouseButton(
                    key: const ValueKey('settings-theme-delete'),
                    small: true,
                    frameless: true,
                    onPressed: () => setState(() => ui.workspace
                        .deleteCustomTheme(ui.workspace.customThemeName!)),
                    child: Text(l10n.delete, style: t.small),
                  ),
                  const SizedBox(width: 6),
                ],
                HouseButton(
                  key: const ValueKey('settings-customise'),
                  small: true,
                  onPressed: () async {
                    await showThemeEditorFrb(context, ui);
                    if (mounted) setState(() {});
                  },
                  child: Text(l10n.customiseEllipsis, style: t.small),
                ),
              ],
            ),
          ),
          settingsRow(
            t,
            l10n.settingsCorners,
            l10n.settingsHelpCorners,
            SizedBox(
              width: 130,
              child: BareDropdown<ThemeShape>(
                key: const ValueKey('settings-shape'),
                value: ui.shape,
                options: ThemeShape.values,
                label: (s) => s == ThemeShape.sharp
                    ? l10n.cornersSharp
                    : l10n.cornersRound,
                onChanged: (s) => setState(() => ui.setShape(s)),
              ),
            ),
          ),
          settingsRow(
            t,
            l10n.settingsMotion,
            l10n.settingsHelpMotion,
            SizedBox(
              width: 130,
              child: BareDropdown<AnimationLevel>(
                key: const ValueKey('settings-animation'),
                value: ui.workspace.animationLevel,
                options: AnimationLevel.values,
                label: (a) => switch (a) {
                  AnimationLevel.all => l10n.motionFull,
                  AnimationLevel.minimal => l10n.motionMinimal,
                  AnimationLevel.none => l10n.none,
                },
                onChanged: (a) =>
                    setState(() => ui.workspace.setAnimationLevel(a)),
              ),
            ),
          ),
        ]),
        settingsSection(t, l10n.settingsGroupScopes, [
          settingsRow(
            t,
            l10n.settingsUseThemeColours,
            l10n.settingsHelpUseThemeColours,
            HouseCheckbox(
              key: const ValueKey('settings-themed-scopes'),
              value: ui.workspace.themedScopes,
              onChanged: (v) => setState(() => ui.workspace.setThemedScopes(v)),
            ),
          ),
        ]),
        settingsSection(t, l10n.settingsGroupViewer, [
          settingsRow(
            t,
            l10n.settingsSurroundTakesThemeColours,
            l10n.settingsHelpSurroundTakesThemeColours,
            HouseCheckbox(
              key: const ValueKey('settings-themed-surround'),
              value: ui.workspace.themedViewerSurround,
              onChanged: (v) =>
                  setState(() => ui.workspace.setThemedViewerSurround(v)),
            ),
          ),
          settingsRow(
            t,
            l10n.settingsSmoothThePictureWhenZoomed,
            l10n.settingsHelpSmoothThePictureWhenZoomed,
            HouseCheckbox(
              key: const ValueKey('settings-smooth-zoomed-viewer'),
              value: ui.workspace.smoothZoomedViewer,
              onChanged: (v) =>
                  setState(() => ui.workspace.setSmoothZoomedViewer(v)),
            ),
          ),
        ]),
      ];

  List<Widget> _interface(LumitTheme t, LumitUiState ui) {
    final settings = ui.workspace.interface;
    return [
      settingsSection(t, l10n.settingsGroupDisplay, [
        settingsRow(
          t,
          l10n.settingsLanguage,
          l10n.settingsHelpLanguage,
          SizedBox(
            width: 170,
            child: BareDropdown<String?>(
              key: const ValueKey('settings-language'),
              // Null first: following the machine is the default, and the one
              // choice that is not a language in the list.
              value: settings.language,
              options: [null, ...languageNames.keys],
              // Each language names itself, so this list reads the same
              // whichever language Lumit is currently in — somebody who picked
              // one they cannot read can still find their way back.
              label: (tag) =>
                  tag == null ? l10n.languageFollowSystem : languageNames[tag]!,
              onChanged: (tag) => setState(() => ui.setLanguage(tag)),
            ),
          ),
        ),
        settingsRow(
          t,
          l10n.settingsInterfaceScale, l10n.settingsHelpInterfaceScale,
          // Intrinsically sized: the slider carries its own track width and
          // its readout beside it, and boxing it narrower only overflows.
          HouseSlider(
            key: const ValueKey('settings-ui-scale'),
            value: settings.uiScale,
            min: 0.75,
            max: 2.0,
            step: 0.05,
            decimals: 2,
            suffix: '×',
            onChanged: (v) => setState(() {
              settings.uiScale = v;
              ui.workspace.settingsChanged();
            }),
          ),
        ),
        settingsRow(
          t,
          l10n.settingsTooltips,
          l10n.settingsHelpTooltips,
          HouseCheckbox(
            key: const ValueKey('settings-tooltips'),
            value: settings.showTooltips,
            onChanged: (on) => setState(() {
              settings.showTooltips = on;
              ui.workspace.settingsChanged();
            }),
          ),
        ),
      ]),
      settingsSection(t, l10n.settingsGroupPanels, [
        settingsRow(
          t,
          l10n.settingsTransformInEffectControls,
          l10n.settingsHelpTransformInEffectControls,
          HouseCheckbox(
            key: const ValueKey('settings-transform-in-fx'),
            value: settings.transformInEffectControls,
            onChanged: (on) => setState(() {
              settings.transformInEffectControls = on;
              ui.workspace.settingsChanged();
            }),
          ),
        ),
      ]),
      // The two the first-run screen sets (K-246), plus the transport's one
      // (K-254). They sit here as ordinary rows, and independently of each
      // other: the screen offers its pair together, but somebody who wants
      // Vegas ramps and After Effects imports is exactly the split docs/07
      // §13.1 expects to be common. The playhead row is not one the screen
      // touches — both answers want the returning playhead, so there is
      // nothing for the question to decide.
      settingsSection(t, l10n.settingsGroupEditing, [
        settingsRow(
          t,
          l10n.settingsRetimeOpensToVelocity,
          l10n.settingsHelpRetimeOpensToVelocity,
          HouseCheckbox(
            key: const ValueKey('settings-retime-speed-lens'),
            value: settings.retimeOpensToSpeed,
            onChanged: (on) => setState(() {
              settings.retimeOpensToSpeed = on;
              ui.workspace.settingsChanged();
            }),
          ),
        ),
        settingsRow(
          t,
          l10n.settingsRetimeValuesInSeconds,
          l10n.settingsHelpRetimeValuesInSeconds,
          HouseCheckbox(
            key: const ValueKey('settings-retime-in-seconds'),
            value: settings.retimeInSeconds,
            onChanged: (on) => setState(() {
              settings.retimeInSeconds = on;
              ui.workspace.settingsChanged();
            }),
          ),
        ),
        settingsRow(
          t,
          l10n.settingsVideoArrivesAsASequence,
          l10n.settingsHelpVideoArrivesAsASequence,
          HouseCheckbox(
            key: const ValueKey('settings-video-as-sequence'),
            value: settings.videoAsSequenceLayer,
            onChanged: (on) => setState(() {
              settings.videoAsSequenceLayer = on;
              ui.workspace.settingsChanged();
            }),
          ),
        ),
        settingsRow(
          t,
          l10n.settingsPasteLayersAtTheirOriginal,
          l10n.settingsHelpPasteLayersAtTheirOriginal,
          HouseCheckbox(
            key: const ValueKey('settings-paste-at-original-time'),
            value: settings.pasteLayersAtOriginalTime,
            onChanged: (on) => setState(() {
              settings.pasteLayersAtOriginalTime = on;
              ui.workspace.settingsChanged();
            }),
          ),
        ),
        settingsRow(
          t,
          l10n.settingsPlayheadStaysWherePlaybackStopped,
          l10n.settingsHelpPlayheadStaysWherePlaybackStopped,
          HouseCheckbox(
            key: const ValueKey('settings-playhead-stays'),
            value: settings.playheadStaysOnStop,
            onChanged: (on) => setState(() {
              settings.playheadStaysOnStop = on;
              ui.workspace.settingsChanged();
            }),
          ),
        ),
        settingsRow(
          t,
          l10n.settingsWaveformsShowTheFrequencyStack,
          l10n.settingsHelpWaveformsShowTheFrequencyStack,
          HouseCheckbox(
            key: const ValueKey('settings-multiwave'),
            value: settings.multiwaveWaveforms,
            onChanged: (on) => setState(() {
              settings.multiwaveWaveforms = on;
              ui.workspace.settingsChanged();
            }),
          ),
        ),
        settingsRow(
          t,
          l10n.settingsWaveformsRiseFromTheBottom,
          l10n.settingsHelpWaveformsRiseFromTheBottom,
          HouseCheckbox(
            key: const ValueKey('settings-waveform-from-bottom'),
            value: settings.waveformsFromBottom,
            onChanged: (on) => setState(() {
              settings.waveformsFromBottom = on;
              ui.workspace.settingsChanged();
            }),
          ),
        ),
      ]),
    ];
  }

  // ---- Keymap (K-199) ------------------------------------------------------

  /// Every shortcut, grouped by where it is live. The table is the engine's —
  /// this walks what `keymap_groups` answered and draws it.
  List<Widget> _keymap(LumitTheme t, LumitUiState ui) {
    final km = ui.keymap;
    final groups = km.visibleGroups;
    return [
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: HouseTextField(
          key: const ValueKey('keymap-search'),
          controller: _searchController(km),
          width: 240,
          hint: l10n.searchShortcuts,
        ),
      ),
      // The presets and the file, wrapped rather than in one row: five controls
      // do not fit the window's width, and a button pushed off the edge is a
      // button nobody can press.
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            HouseButton(
              key: const ValueKey('keymap-preset-lumit'),
              small: true,
              onPressed: () async {
                await km.loadPreset(BridgeKeymapPreset.lumit);
                if (mounted) setState(() {});
              },
              child: Text(l10n.keymapLumitDefault, style: t.small),
            ),
            HouseButton(
              key: const ValueKey('keymap-preset-ae'),
              small: true,
              onPressed: () async {
                await km.loadPreset(BridgeKeymapPreset.afterEffects);
                if (mounted) setState(() {});
              },
              child: Text(l10n.keymapAfterEffects, style: t.small),
            ),
            HouseButton(
              key: const ValueKey('keymap-import'),
              small: true,
              onPressed: () => _importKeymap(km),
              child: Text(l10n.menuImport, style: t.small),
            ),
            HouseButton(
              key: const ValueKey('keymap-export'),
              small: true,
              onPressed: () => _exportKeymap(km),
              child: Text(l10n.menuExport, style: t.small),
            ),
          ],
        ),
      ),
      // What the last import said, when it had something to say. Kept beside
      // the buttons rather than thrown as a dialogue: a keymap that would not
      // read is a fact about the file, not an emergency.
      if (_keymapMessage != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(
            _keymapMessage!,
            key: const ValueKey('keymap-message'),
            style: t.small.copyWith(color: t.textMuted),
          ),
        ),
      // The clash warning. Present only when there is one, because a banner
      // that is always there is a banner nobody reads.
      if (km.conflicts.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Container(
            key: const ValueKey('keymap-conflicts'),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: t.surface1,
              border: Border.all(color: t.warning),
              borderRadius: BorderRadius.circular(t.tokens.floatRadius),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  km.conflicts.length == 1
                      ? l10n.keymapClashGlobal
                      : '${km.conflicts.length} shortcuts run two things',
                  style: t.body,
                ),
                for (final clash in km.conflicts)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '${chordLabel(clash.chord)} — ${clash.actions.join(', ')}',
                      style: t.small.copyWith(color: t.textMuted),
                    ),
                  ),
              ],
            ),
          ),
        ),
      // Panels that have taken a chord over from an app-wide one (K-281). Not
      // a warning — nothing is ambiguous, the focused panel simply wins — so
      // it is a quiet note rather than a bordered banner. It is said at all
      // because the app-wide meaning does stop working in that one panel, and
      // finding that out by pressing the key is worse than reading it here.
      if (km.shadows.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Column(
            key: const ValueKey('keymap-shadows'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                km.shadows.length == 1
                    ? l10n.keymapClashPanel
                    : '${km.shadows.length} shortcuts mean something else in '
                        'one panel',
                style: t.small.copyWith(color: t.textMuted),
              ),
              for (final shadow in km.shadows)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '${chordLabel(shadow.chord)} — ${shadow.action} in the '
                    '${shadow.context}, ${shadow.shadowed} elsewhere',
                    style: t.small.copyWith(color: t.textMuted),
                  ),
                ),
            ],
          ),
        ),
      if (groups.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(l10n.keymapNoMatches,
              style: t.small.copyWith(color: t.textMuted)),
        ),
      for (final group in groups)
        settingsSection(t, engineLabel(group.label), [
          for (final binding in group.bindings)
            settingsRow(
              t,
              engineLabel(binding.description),
              '',
              _ChordCell(
                key: ValueKey('keymap-chord-${binding.context.name}-'
                    '${binding.action}'),
                binding: binding,
                keymap: km,
                onChanged: () {
                  if (mounted) setState(() {});
                },
              ),
            ),
        ]),
    ];
  }

  /// What the last import or export said, shown under the buttons.
  String? _keymapMessage;

  /// Read a keymap file and hand it to the engine, which refuses it whole if it
  /// is not one — so a wrong file costs nothing but the message.
  Future<void> _importKeymap(KeymapState km) async {
    final path = await pickKeymapToOpen();
    if (path == null) return;
    String text;
    try {
      text = await File(path).readAsString();
    } catch (e) {
      if (mounted) {
        setState(() => _keymapMessage = l10n.keymapFileUnreadable);
      }
      return;
    }
    final refusal = await km.fromJson(text);
    if (!mounted) return;
    setState(() => _keymapMessage = refusal ?? l10n.keymapImported);
  }

  /// Write the keymap out as the shareable file docs/07 §15 promises.
  Future<void> _exportKeymap(KeymapState km) async {
    final path = await pickKeymapSaveLocation();
    if (path == null) return;
    try {
      await File(path).writeAsString(km.toJson());
      if (mounted) setState(() => _keymapMessage = l10n.keymapExported);
    } catch (e) {
      if (mounted) {
        setState(() => _keymapMessage = l10n.keymapFileUnwritable);
      }
    }
  }

  /// One controller for the search box, kept across rebuilds so typing does
  /// not reset the cursor, and released with the window.
  TextEditingController? _search;

  @override
  void dispose() {
    _search?.dispose();
    super.dispose();
  }

  TextEditingController _searchController(KeymapState km) {
    final existing = _search;
    if (existing != null) return existing;
    final created = TextEditingController(text: km.query)
      ..addListener(() {
        km.query = _search?.text ?? '';
        if (mounted) setState(() {});
      });
    _search = created;
    return created;
  }

  List<Widget> _performance(LumitTheme t, LumitUiState ui) {
    final stats = cacheStats();
    final vram = vramCacheStats();
    final tier = playbackTier();
    // Only read when it is going to be drawn: the report is a debug-build
    // instrument, and a release build should not be making the call at all.
    final memory = kDebugMode ? memoryReport() : null;

    return [
      settingsSection(t, l10n.settingsGroupPlayback, [
        settingsRow(
          t,
          l10n.settingsWhenTheMachineCannotKeep,
          l10n.settingsHelpWhenTheMachineCannotKeep,
          SizedBox(
            width: 130,
            child: BareDropdown<PlaybackMode>(
              key: const ValueKey('settings-playback-mode'),
              value: ui.workspace.performance.playback,
              options: PlaybackMode.values,
              label: (m) => m == PlaybackMode.adaptive
                  ? l10n.playbackAdaptive
                  : l10n.playbackEveryFrame,
              onChanged: (m) => setState(() {
                ui.workspace.performance.playback = m;
                ui.workspace.settingsChanged();
              }),
            ),
          ),
        ),
        settingsRow(
          t,
          l10n.settingsQualityTier,
          l10n.settingsHelpQualityTier,
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_tierLabel(tier.tier),
                  key: const ValueKey('settings-tier'), style: t.small),
              const SizedBox(width: 8),
              LumitTooltip(
                message: l10n.tipResetQualityTier,
                child: HouseButton(
                  key: const ValueKey('settings-tier-reset'),
                  small: true,
                  onPressed: () => setState(resetRealtime),
                  child: Text(l10n.reset, style: t.small),
                ),
              ),
            ],
          ),
        ),
      ]),
      settingsSection(t, l10n.settingsGroupRenderedFrameCache, [
        _budgetRow(
          t,
          key: 'settings-cache-budget',
          description: l10n.settingsHelpCacheBudget(_gib(_systemMib)),
          bytes: stats.budgetBytes.toInt(),
          ceilingMib: _systemMib,
          onSet: (bytes) => setState(() {
            setCacheBudget(bytes: bytes);
            ui.workspace.setCacheBudgetBytes(bytes.toInt());
          }),
        ),
        settingsRow(
          t,
          l10n.settingsInUse,
          l10n.settingsHelpCacheInUse('${stats.hits}',
              '${stats.hits + stats.misses}', '${stats.compDecodes}'),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${_mib(stats.usedBytes.toInt())} MB in ${stats.entries}',
                key: const ValueKey('settings-cache-used'),
                style: t.small,
              ),
              const SizedBox(width: 8),
              HouseButton(
                key: const ValueKey('settings-cache-clear'),
                small: true,
                onPressed: () => setState(clearCache),
                child: Text(l10n.clear, style: t.small),
              ),
            ],
          ),
        ),
      ]),
      settingsSection(t, l10n.settingsGroupPreviewCacheOnTheGraphics, [
        _budgetRow(
          t,
          key: 'settings-vram-budget',
          description: l10n.settingsHelpVramBudget(_gib(_vramMib)),
          bytes: vram.budgetBytes.toInt(),
          ceilingMib: _vramMib,
          onSet: (bytes) => setState(() {
            setVramCacheBudget(bytes: bytes);
            ui.workspace.setVramBudgetBytes(bytes.toInt());
          }),
        ),
        settingsRow(
          t,
          l10n.settingsInUse,
          l10n.settingsHelpInUse,
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${_mib(vram.usedBytes.toInt())} MB in ${vram.entries}',
                key: const ValueKey('settings-vram-used'),
                style: t.small,
              ),
              const SizedBox(width: 8),
              HouseButton(
                key: const ValueKey('settings-vram-clear'),
                small: true,
                onPressed: () => setState(clearVramCache),
                child: Text(l10n.clear, style: t.small),
              ),
            ],
          ),
        ),
      ]),
      ..._diskCache(t, ui),
      // Where the memory has gone (K-294). Last on the page, under the tiers
      // it weighs: each section above reports one store, and this one reports
      // the whole process and what none of them accounts for. Read downwards it
      // is the summing-up, and it leaves every control above where the hand
      // already knows to find it.
      //
      // **Debug builds only** (owner, 2026-08-06). It is an instrument for
      // hunting a fault, not a setting: a shipped editor asking its user to
      // interpret live texture counts has handed them the engineering rather
      // than the tool. `kDebugMode` is false in both profile and release
      // builds, so what ships is the page without it.
      if (memory != null)
        settingsSection(t, l10n.settingsGroupMemory, [
          settingsRow(
            t,
            l10n.settingsThisProcess,
            l10n.settingsHelpThisProcess,
            Text(
              memory.processBytes == BigInt.zero
                  ? 'not known here'
                  : _bytes(memory.processBytes),
              key: const ValueKey('settings-memory-process'),
              style: t.small,
            ),
          ),
          settingsRow(
            t,
            l10n.settingsNotHeldByAnyCache,
            l10n.settingsHelpNotHeldByAnyCache,
            Text(
              memory.processBytes == BigInt.zero
                  ? '—'
                  : _bytes(memory.unaccountedBytes),
              key: const ValueKey('settings-memory-unaccounted'),
              style: t.small,
            ),
          ),
          settingsRow(
            t,
            l10n.settingsHeldByTheGraphicsDriver,
            l10n.settingsHelpHeldByTheGraphicsDriver,
            Text(
              '${memory.gpuTextures} pictures, ${memory.gpuBuffers} buffers',
              key: const ValueKey('settings-memory-gpu'),
              style: t.small,
            ),
          ),
          // The byte figures are Vulkan and D3D12 only, so the row is not drawn
          // at all on a Mac rather than printing two zeroes and inviting the
          // reader to draw a conclusion from them.
          if (memory.gpuReservedBytes != BigInt.zero)
            settingsRow(
              t,
              l10n.settingsGraphicsMemoryReserved,
              l10n.settingsHelpGraphicsMemoryReserved,
              Text(
                '${_bytes(memory.gpuReservedBytes)} reserved, '
                '${_bytes(memory.gpuAllocatedBytes)} in use',
                key: const ValueKey('settings-memory-gpu-bytes'),
                style: t.small,
              ),
            ),
          settingsRow(
            t,
            l10n.settingsOpenMediaDecoders,
            l10n.settingsHelpOpenMediaDecoders,
            Text(
              '${memory.openDecoders}',
              key: const ValueKey('settings-memory-decoders'),
              style: t.small,
            ),
          ),
          settingsRow(
            t,
            l10n.settingsFramesWaitingToBeWritten,
            l10n.settingsHelpFramesWaitingToBeWritten,
            Text(
              '${memory.parkQueueFrames}',
              key: const ValueKey('settings-memory-parks'),
              style: t.small,
            ),
          ),
        ]),
    ];
  }

  /// The disk tier (docs/06 §5.4, docs/07 §15): its budget, where it lives, and
  /// what it holds. The bottom of the three-tier cache and the only one that
  /// outlives the session, which is why it has a folder at all.
  List<Widget> _diskCache(LumitTheme t, LumitUiState ui) {
    final disk = diskCacheStats();
    // What this project says, if it says anything: a project's own choice
    // overrides the application's, so it is what the controls should show.
    final own = _project(context)?.cacheLocation();
    final scope = own == null ? CacheScope.everywhere : CacheScope.thisProject;
    final where = own?.location ??
        cacheLocationFromName(ui.workspace.performance.diskCacheLocation ??
            BridgeCacheLocation.appData.name);
    return [
      settingsSection(t, l10n.settingsGroupFramesParkedOnDisk, [
        _budgetRow(
          t,
          key: 'settings-disk-budget',
          description: l10n.settingsHelpDiskBudget,
          bytes: disk.budgetBytes.toInt(),
          ceilingMib: _diskCeilingMib,
          onSet: (bytes) => setState(() {
            setDiskCacheBudget(bytes: bytes);
            ui.workspace.setDiskBudgetBytes(bytes.toInt());
          }),
        ),
        settingsRow(
          t,
          l10n.settingsWhere,
          disk.root.isEmpty ? l10n.settingsHelpNowhereToPark : disk.root,
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 150,
                child: BareDropdown<BridgeCacheLocation>(
                  key: const ValueKey('settings-disk-location'),
                  value: where,
                  options: BridgeCacheLocation.values,
                  label: _locationLabel,
                  onChanged: (l) => _setLocation(ui, l, scope),
                ),
              ),
              if (where == BridgeCacheLocation.custom) ...[
                const SizedBox(width: 8),
                LumitTooltip(
                  message: l10n.tipChooseCacheFolder,
                  child: HouseButton(
                    key: const ValueKey('settings-disk-folder'),
                    small: true,
                    onPressed: () => _pickCacheFolder(ui, scope),
                    child: Text(l10n.chooseEllipsis, style: t.small),
                  ),
                ),
              ],
            ],
          ),
        ),
        settingsRow(
          t,
          l10n.settingsAppliesTo,
          scope == CacheScope.thisProject
              ? l10n.settingsHelpScopeThisProject
              : l10n.settingsHelpScopeEverywhere,
          SizedBox(
            width: 150,
            child: BareDropdown<CacheScope>(
              key: const ValueKey('settings-disk-scope'),
              value: scope,
              options: CacheScope.values,
              label: (s) => switch (s) {
                CacheScope.everywhere => l10n.scopeEverything,
                CacheScope.thisProject => l10n.scopeThisProject,
              },
              onChanged: (s) => _setScope(ui, s, where),
            ),
          ),
        ),
        settingsRow(
          t,
          l10n.settingsInUse,
          l10n.settingsHelpInUse2,
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${_mib(disk.usedBytes.toInt())} MB in ${disk.entries}',
                key: const ValueKey('settings-disk-used'),
                style: t.small,
              ),
              const SizedBox(width: 8),
              HouseButton(
                key: const ValueKey('settings-disk-clear'),
                small: true,
                onPressed: () async {
                  final cleared = await confirmClearDiskCache(context);
                  if (cleared && mounted) setState(() {});
                },
                child: Text(l10n.clear, style: t.small),
              ),
            ],
          ),
        ),
      ]),
    ];
  }

  /// The open project, or null before one exists — read through the provider
  /// rather than held, since the settings window outlives no project.
  ProjectReference? _project(BuildContext context) =>
      Provider.of<LumitState>(context, listen: false).project;

  static String _locationLabel(BridgeCacheLocation l) => switch (l) {
        BridgeCacheLocation.appData => l10n.cacheLocationWithLumit,
        BridgeCacheLocation.besideProject => l10n.cacheLocationBesideProject,
        BridgeCacheLocation.custom => l10n.cacheLocationChosenFolder,
      };

  /// Point the cache somewhere, at whichever scope is in force. The project's own
  /// choice is an op (undoable, saved in the `.lum`); the application's is a
  /// setting. Same control, same three options — only the store differs.
  void _setLocation(
    LumitUiState ui,
    BridgeCacheLocation location,
    CacheScope scope,
  ) {
    final folder = scope == CacheScope.thisProject
        ? (_project(context)?.cacheLocation()?.folder ?? '')
        : (ui.workspace.performance.diskCacheFolder ?? '');
    setState(() {
      if (scope == CacheScope.thisProject) {
        _project(context)?.setCacheLocation(
          location:
              BridgeProjectCacheLocation(location: location, folder: folder),
        );
      } else {
        // Choosing the custom option without a folder yet leaves the tier where
        // it is; the engine says so by keeping its default, and the Choose…
        // button appears beside the dropdown.
        setDiskCacheLocation(location: location, folder: folder);
        ui.workspace.setDiskCacheLocation(
            location.name, folder.isEmpty ? null : folder);
      }
    });
  }

  /// Switch between "this project decides" and "the application decides".
  /// Turning it off clears the project's override rather than copying the
  /// application's answer into it, so the project follows along afterwards.
  void _setScope(LumitUiState ui, CacheScope scope, BridgeCacheLocation where) {
    setState(() {
      switch (scope) {
        case CacheScope.thisProject:
          _project(context)?.setCacheLocation(
            location: BridgeProjectCacheLocation(
              location: where,
              folder: ui.workspace.performance.diskCacheFolder ?? '',
            ),
          );
        case CacheScope.everywhere:
          _project(context)?.setCacheLocation(location: null);
      }
    });
  }

  Future<void> _pickCacheFolder(LumitUiState ui, CacheScope scope) async {
    final folder = await pickFolder();
    if (folder == null || !mounted) return;
    setState(() {
      if (scope == CacheScope.thisProject) {
        _project(context)?.setCacheLocation(
          location: BridgeProjectCacheLocation(
              location: BridgeCacheLocation.custom, folder: folder),
        );
      } else {
        setDiskCacheLocation(
            location: BridgeCacheLocation.custom, folder: folder);
        ui.workspace
            .setDiskCacheLocation(BridgeCacheLocation.custom.name, folder);
      }
    });
  }

  /// The ceiling for the disk budget. Free disk space is not something the
  /// engine reports yet (K-194 covers memory only), so the field is generous
  /// rather than guessed at: 500 GB, which no cache should reach and no user
  /// should be stopped short of.
  static const double _diskCeilingMib = 500 * 1024;

  // ---- the shapes every page is built from ---------------------------------

  /// A cache budget: type a number of megabytes, or drag it, up to what the
  /// machine actually has (K-194).
  ///
  /// A typed box rather than a pick from a fixed list — the old dropdown could
  /// not say "3 GB on a 32 GB machine", and its options were a guess at what
  /// hardware would show up.
  Widget _budgetRow(
    LumitTheme t, {
    required String key,
    required String description,
    required int bytes,
    required double ceilingMib,
    required ValueChanged<BigInt> onSet,
  }) =>
      settingsRow(
        t,
        l10n.settingsBudget,
        description,
        SizedBox(
          width: 110,
          child: DragValueField(
            key: ValueKey<String>(key),
            value: (bytes >> 20).toDouble(),
            min: _minBudgetMib,
            max: ceilingMib,
            // A megabyte a pixel is far too fine on a 32 GB ceiling.
            speed: 16,
            decimals: 0,
            suffix: ' MB',
            onChanged: (mib) => onSet(BigInt.from(mib.round()) << 20),
          ),
        ),
      );

  /// What the machine has, in MiB, falling back to a documented ceiling when
  /// it will not say. Installed RAM is answered on all three desktops
  /// (K-204); video memory is Windows-only so far, so that is the one that
  /// still falls back off Windows.
  static double get _systemMib => _mibOf(systemMemoryBytes());
  static double get _vramMib => _mibOf(videoMemoryBytes());

  static double _mibOf(BigInt bytes) {
    final mib = (bytes >> 20).toDouble();
    return mib <= 0 ? _unknownMemoryMib : mib;
  }

  /// A round figure for a sentence: "32 GB", or megabytes when it is small.
  static String _gib(double mib) =>
      mib >= 1024 ? '${(mib / 1024).round()} GB' : '${mib.round()} MB';

  /// Bytes as a person reads them — MB up to a gigabyte, GB above, one
  /// decimal so 85.4 GB does not print as 85.
  static String _bytes(BigInt bytes) {
    final b = bytes.toDouble();
    if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(1)} GB';
    return '${(b / (1 << 20)).toStringAsFixed(0)} MB';
  }

  static String _mib(int bytes) => (bytes / (1 << 20)).toStringAsFixed(0);

  static String _tierLabel(int tier) => switch (tier) {
        1 => l10n.menuFull,
        2 => l10n.menuHalf,
        3 => l10n.resolutionThird,
        _ => l10n.menuQuarter,
      };
}

/// One row's chord cell: what runs this action, and the way to change it.
///
/// Click it and it listens for the next chord you press — the keypress is
/// swallowed while it does, so binding `Ctrl+S` does not also save. Escape
/// leaves it alone; Backspace or Delete clears the binding. It shows *every*
/// chord an action has, because an action can have two (K-198) and one the
/// table did not draw would be a key that works with nothing on screen to say
/// so.
class _ChordCell extends StatefulWidget {
  final BridgeKeyBinding binding;
  final KeymapState keymap;
  final VoidCallback onChanged;

  const _ChordCell({
    super.key,
    required this.binding,
    required this.keymap,
    required this.onChanged,
  });

  @override
  State<_ChordCell> createState() => _ChordCellState();
}

class _ChordCellState extends State<_ChordCell> {
  bool _listening = false;
  String? _refusal;

  /// Take the next chord as this row's binding. Runs on every key event while
  /// listening, and always reports the event handled so nothing else acts on
  /// the keys being bound.
  ///
  /// Listening stops the moment a chord *arrives*, not when the engine answers:
  /// the engine call is a round trip, and a cell that went on saying "press a
  /// shortcut" until it came back would invite a second press that bound the
  /// wrong key. A refusal comes back into the cell as a message beside it.
  Future<bool> _capture(KeyEvent event) async {
    if (event is! KeyDownEvent) return true;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _stopListening();
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.backspace ||
        event.logicalKey == LogicalKeyboardKey.delete) {
      _stopListening();
      await widget.keymap.unbind(widget.binding.context, widget.binding.action);
      widget.onChanged();
      return true;
    }
    final chord = chordText(event);
    // A modifier on its own is half a chord: keep listening rather than
    // binding Shift to something.
    if (chord == null) return true;
    _stopListening();
    final refusal = await widget.keymap
        .rebind(widget.binding.context, widget.binding.action, chord);
    if (mounted) setState(() => _refusal = refusal);
    widget.onChanged();
    return true;
  }

  @override
  void dispose() {
    // The handler outlives the widget otherwise: a row scrolled out of the
    // lazy list mid-capture would go on swallowing every keypress in the app.
    if (_listening) HardwareKeyboard.instance.removeHandler(_handler);
    super.dispose();
  }

  bool _handler(KeyEvent event) {
    unawaited(_capture(event));
    return true;
  }

  void _startListening() {
    if (_listening) return;
    HardwareKeyboard.instance.addHandler(_handler);
    setState(() {
      _listening = true;
      _refusal = null;
    });
  }

  void _stopListening() {
    if (!_listening) return;
    HardwareKeyboard.instance.removeHandler(_handler);
    if (mounted) {
      setState(() => _listening = false);
    } else {
      _listening = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final chord = widget.binding.chord;
    final label = _listening
        ? l10n.keymapPressAShortcut
        : chord.isEmpty
            ? l10n.keymapNotSet
            : chordLabel(chord);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_refusal != null)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Text(_refusal!, style: t.small.copyWith(color: t.error)),
          ),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _startListening,
          child: Container(
            constraints: const BoxConstraints(minWidth: 110),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: _listening ? t.accent : t.surface2,
              borderRadius: BorderRadius.circular(t.tokens.controlRadius),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: chord.isEmpty && !_listening
                  ? t.small.copyWith(color: t.textMuted)
                  : t.small,
            ),
          ),
        ),
        const SizedBox(width: 6),
        HouseButton(
          small: true,
          onPressed: () async {
            await widget.keymap
                .resetBinding(widget.binding.context, widget.binding.action);
            widget.onChanged();
          },
          child: Text(l10n.reset, style: t.small),
        ),
      ],
    );
  }
}
