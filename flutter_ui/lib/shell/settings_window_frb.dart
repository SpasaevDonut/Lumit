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

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/src/rust/api/cache.dart';
import 'package:lumit_flutter/src/rust/api/keymap.dart';
import 'package:lumit_flutter/src/rust/api/project.dart';
import 'package:lumit_flutter/src/rust/api/shell.dart';
import 'package:lumit_flutter/src/rust/api/system.dart';
import 'package:provider/provider.dart';

import '../state/file_dialogs.dart';
import '../state/keymap.dart';
import '../state/settings.dart';
import '../state/workspace.dart';
import '../theme/theme.dart';
import '../widgets/controls.dart';
import 'cache_confirm_frb.dart';
import 'theme_editor_frb.dart';

/// The smallest budget worth setting, in MiB. Below this the cache holds a
/// frame or two and costs more in bookkeeping than it saves.
const double _minBudgetMib = 64;

/// The ceiling when the machine will not say how much it has (K-194): every
/// platform but Windows, so far. Generous rather than clever — the engine
/// clamps to what it can actually allocate either way.
const double _unknownMemoryMib = 16384;

/// One page in the sidebar.
enum SettingsPage {
  general('General'),
  appearance('Appearance'),
  interface('Interface'),
  keymap('Keymap'),
  performance('Performance');

  const SettingsPage(this.label);
  final String label;
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
                  Expanded(child: Text('Settings', style: t.bodyPrimary)),
                  HouseButton(
                    key: const ValueKey('settings-close'),
                    small: true,
                    onPressed: widget.onClose,
                    child: const Text('Done'),
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
        _section(t, 'Workspace', [
          _row(
            t,
            'Panel layout',
            'Return every panel to its default place and size.',
            HouseButton(
              key: const ValueKey('settings-reset-workspace'),
              small: true,
              onPressed: () => setState(ui.resetLayout),
              child: Text('Reset workspace', style: t.small),
            ),
          ),
        ]),
        // About used to sit here. It is Help ▸ About Lumit now (K-244):
        // Settings is for what you change, and a version number is not that.
      ];

  List<Widget> _appearance(LumitTheme t, LumitUiState ui) => [
        _section(t, 'Theme', [
          _row(
            t,
            'Colour scheme',
            'The palette every panel draws from.',
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
          _row(
            t,
            'Custom colours',
            ui.workspace.customThemeName == null
                ? 'Start from this scheme and set any colour yourself.'
                : 'Edit the colours of ${ui.workspace.customThemeName}.',
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
                    child: Text('Delete', style: t.small),
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
                  child: Text('Customise…', style: t.small),
                ),
              ],
            ),
          ),
          _row(
            t,
            'Corners',
            'How rounded controls and panels are.',
            SizedBox(
              width: 130,
              child: BareDropdown<ThemeShape>(
                key: const ValueKey('settings-shape'),
                value: ui.shape,
                options: ThemeShape.values,
                label: (s) => s == ThemeShape.sharp ? 'Sharp' : 'Round',
                onChanged: (s) => setState(() => ui.setShape(s)),
              ),
            ),
          ),
          _row(
            t,
            'Motion',
            'How much controls animate as they change.',
            SizedBox(
              width: 130,
              child: BareDropdown<AnimationLevel>(
                key: const ValueKey('settings-animation'),
                value: ui.workspace.animationLevel,
                options: AnimationLevel.values,
                label: (a) => switch (a) {
                  AnimationLevel.all => 'Full',
                  AnimationLevel.minimal => 'Minimal',
                  AnimationLevel.none => 'None',
                },
                onChanged: (a) =>
                    setState(() => ui.workspace.setAnimationLevel(a)),
              ),
            ),
          ),
        ]),
        _section(t, 'Scopes', [
          _row(
            t,
            'Use theme colours',
            'Off, a scope reads on the standard near-black graticule '
                'whatever the chrome — which is how a signal is measured. On, '
                'it takes the theme\'s colours instead.',
            HouseCheckbox(
              key: const ValueKey('settings-themed-scopes'),
              value: ui.workspace.themedScopes,
              onChanged: (v) => setState(() => ui.workspace.setThemedScopes(v)),
            ),
          ),
        ]),
        _section(t, 'Viewer', [
          _row(
            t,
            'Surround takes theme colours',
            'Off, the area around the picture is a neutral grey — a grade '
                'cannot be judged against a tinted surround. On, it matches '
                'the rest of the shell.',
            HouseCheckbox(
              key: const ValueKey('settings-themed-surround'),
              value: ui.workspace.themedViewerSurround,
              onChanged: (v) =>
                  setState(() => ui.workspace.setThemedViewerSurround(v)),
            ),
          ),
        ]),
      ];

  List<Widget> _interface(LumitTheme t, LumitUiState ui) {
    final settings = ui.workspace.interface;
    return [
      _section(t, 'Display', [
        _row(
          t,
          'Interface scale',
          'How large every panel draws, for a dense or a distant screen.',
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
        _row(
          t,
          'Tooltips',
          'Show the hint that explains a control when you rest on it.',
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
      _section(t, 'Panels', [
        _row(
          t,
          'Transform in Effect controls',
          'Repeat the layer\'s Transform rows above its effects. The '
              'Timeline already shows them when a layer is twirled open.',
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
      _section(t, 'Editing', [
        _row(
          t,
          'Retime opens to Velocity',
          'The Retime graph opens showing playback speed per cent — one point '
              'per keyframe, dragged up to speed up and below zero to reverse '
              '— instead of which moment of the source is showing.',
          HouseCheckbox(
            key: const ValueKey('settings-retime-speed-lens'),
            value: settings.retimeOpensToSpeed,
            onChanged: (on) => setState(() {
              settings.retimeOpensToSpeed = on;
              ui.workspace.settingsChanged();
            }),
          ),
        ),
        _row(
          t,
          'Video arrives as a Sequence layer',
          'Video and image sequences added to a composition become a Sequence '
              'layer, which can be cut into clips on its own row. Still '
              'images are never wrapped.',
          HouseCheckbox(
            key: const ValueKey('settings-video-as-sequence'),
            value: settings.videoAsSequenceLayer,
            onChanged: (on) => setState(() {
              settings.videoAsSequenceLayer = on;
              ui.workspace.settingsChanged();
            }),
          ),
        ),
        _row(
          t,
          'Paste layers at their original time',
          'A pasted layer keeps the timecode it was copied at, instead of '
              'starting at the playhead. For rebuilding the same moment in a '
              'second composition; leave it off for the everyday "put one '
              'here". Effects always paste with their first keyframe at the '
              'playhead, whichever way this is set.',
          HouseCheckbox(
            key: const ValueKey('settings-paste-at-original-time'),
            value: settings.pasteLayersAtOriginalTime,
            onChanged: (on) => setState(() {
              settings.pasteLayersAtOriginalTime = on;
              ui.workspace.settingsChanged();
            }),
          ),
        ),
        _row(
          t,
          'Playhead stays where playback stopped',
          'Leave the playhead on the frame that was on screen when playback '
              'stopped, instead of putting it back where playing started. '
              'Dragging the ruler while playing always stops and follows the '
              'pointer, whichever way this is set.',
          HouseCheckbox(
            key: const ValueKey('settings-playhead-stays'),
            value: settings.playheadStaysOnStop,
            onChanged: (on) => setState(() {
              settings.playheadStaysOnStop = on;
              ui.workspace.settingsChanged();
            }),
          ),
        ),
        _row(
          t,
          'Waveforms show the frequency stack',
          'A layer\'s waveform draws as three stacked waves — bass, middle '
              'and treble — instead of one. A loud passage is a solid block on '
              'a single wave whichever instrument is playing; the stack shows '
              'the kick apart from the hats, so a cut can be aimed at either. '
              'Turn it off for one plain wave.',
          HouseCheckbox(
            key: const ValueKey('settings-multiwave'),
            value: settings.multiwaveWaveforms,
            onChanged: (on) => setState(() {
              settings.multiwaveWaveforms = on;
              ui.workspace.settingsChanged();
            }),
          ),
        ),
        _row(
          t,
          'Waveforms rise from the bottom',
          'A waveform stands on the floor of its row instead of being centred '
              'about silence, each column reaching up by how far the sound '
              'swung either way. Half of a centred wave is a mirror of the '
              'other half, so this spends the whole row on the half that says '
              'something — useful in a short row. Applies to the single wave '
              'and the frequency stack alike.',
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
          hint: 'Search shortcuts',
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
              child: Text('Lumit default', style: t.small),
            ),
            HouseButton(
              key: const ValueKey('keymap-preset-ae'),
              small: true,
              onPressed: () async {
                await km.loadPreset(BridgeKeymapPreset.afterEffects);
                if (mounted) setState(() {});
              },
              child: Text('After Effects', style: t.small),
            ),
            HouseButton(
              key: const ValueKey('keymap-import'),
              small: true,
              onPressed: () => _importKeymap(km),
              child: Text('Import…', style: t.small),
            ),
            HouseButton(
              key: const ValueKey('keymap-export'),
              small: true,
              onPressed: () => _exportKeymap(km),
              child: Text('Export…', style: t.small),
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
                      ? 'One shortcut runs two things'
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
                    ? 'One shortcut means something else in one panel'
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
          child: Text('No shortcut matches that.',
              style: t.small.copyWith(color: t.textMuted)),
        ),
      for (final group in groups)
        _section(t, group.label, [
          for (final binding in group.bindings)
            _row(
              t,
              binding.description,
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
        setState(() => _keymapMessage = 'That file could not be read.');
      }
      return;
    }
    final refusal = await km.fromJson(text);
    if (!mounted) return;
    setState(() => _keymapMessage = refusal ?? 'Keymap imported.');
  }

  /// Write the keymap out as the shareable file docs/07 §15 promises.
  Future<void> _exportKeymap(KeymapState km) async {
    final path = await pickKeymapSaveLocation();
    if (path == null) return;
    try {
      await File(path).writeAsString(km.toJson());
      if (mounted) setState(() => _keymapMessage = 'Keymap exported.');
    } catch (e) {
      if (mounted) {
        setState(() => _keymapMessage = 'That file could not be written.');
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

    return [
      _section(t, 'Playback', [
        _row(
          t,
          'When the machine cannot keep up',
          'Adaptive keeps time and softens the picture; every frame keeps '
              'the picture and takes the time it needs.',
          SizedBox(
            width: 130,
            child: BareDropdown<PlaybackMode>(
              key: const ValueKey('settings-playback-mode'),
              value: ui.workspace.performance.playback,
              options: PlaybackMode.values,
              label: (m) =>
                  m == PlaybackMode.adaptive ? 'Adaptive' : 'Every frame',
              onChanged: (m) => setState(() {
                ui.workspace.performance.playback = m;
                ui.workspace.settingsChanged();
              }),
            ),
          ),
        ),
        _row(
          t,
          'Quality tier',
          'What the realtime controller has settled on.',
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_tierLabel(tier.tier),
                  key: const ValueKey('settings-tier'), style: t.small),
              const SizedBox(width: 8),
              LumitTooltip(
                message:
                    'Start the quality controller again, optimistic at full',
                child: HouseButton(
                  key: const ValueKey('settings-tier-reset'),
                  small: true,
                  onPressed: () => setState(resetRealtime),
                  child: Text('Reset', style: t.small),
                ),
              ),
            ],
          ),
        ),
      ]),
      _section(t, 'Rendered-frame cache', [
        _budgetRow(
          t,
          key: 'settings-cache-budget',
          description: 'How much memory finished frames may hold, of the '
              '${_gib(_systemMib)} this machine has.',
          bytes: stats.budgetBytes.toInt(),
          ceilingMib: _systemMib,
          onSet: (bytes) => setState(() {
            setCacheBudget(bytes: bytes);
            ui.workspace.setCacheBudgetBytes(bytes.toInt());
          }),
        ),
        _row(
          t,
          'In use',
          '${stats.hits} of ${stats.hits + stats.misses} frames were served '
              'from the cache; ${stats.compDecodes} were decoded.',
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
                child: Text('Clear', style: t.small),
              ),
            ],
          ),
        ),
      ]),
      _section(t, 'Preview cache on the graphics card', [
        _budgetRow(
          t,
          key: 'settings-vram-budget',
          description: 'How much video memory finished frames may hold, of '
              'the ${_gib(_vramMib)} on the card.',
          bytes: vram.budgetBytes.toInt(),
          ceilingMib: _vramMib,
          onSet: (bytes) => setState(() {
            setVramCacheBudget(bytes: bytes);
            ui.workspace.setVramBudgetBytes(bytes.toInt());
          }),
        ),
        _row(
          t,
          'In use',
          'Frames held on the card, ready to show without compositing.',
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
                child: Text('Clear', style: t.small),
              ),
            ],
          ),
        ),
      ]),
      ..._diskCache(t, ui),
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
      _section(t, 'Frames parked on disk', [
        _budgetRow(
          t,
          key: 'settings-disk-budget',
          description: 'How much disk space parked frames may take. These '
              'survive closing Lumit, so a project reopens warm.',
          bytes: disk.budgetBytes.toInt(),
          ceilingMib: _diskCeilingMib,
          onSet: (bytes) => setState(() {
            setDiskCacheBudget(bytes: bytes);
            ui.workspace.setDiskBudgetBytes(bytes.toInt());
          }),
        ),
        _row(
          t,
          'Where',
          disk.root.isEmpty
              ? 'Nowhere: this machine has no folder Lumit may write to.'
              : disk.root,
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
                  message: 'Choose the folder parked frames go in',
                  child: HouseButton(
                    key: const ValueKey('settings-disk-folder'),
                    small: true,
                    onPressed: () => _pickCacheFolder(ui, scope),
                    child: Text('Choose…', style: t.small),
                  ),
                ),
              ],
            ],
          ),
        ),
        _row(
          t,
          'Applies to',
          scope == CacheScope.thisProject
              ? 'Saved inside this project, so it travels with a copy of it.'
              : 'Every project that has not been given a place of its own.',
          SizedBox(
            width: 150,
            child: BareDropdown<CacheScope>(
              key: const ValueKey('settings-disk-scope'),
              value: scope,
              options: CacheScope.values,
              label: (s) => switch (s) {
                CacheScope.everywhere => 'Everything',
                CacheScope.thisProject => 'This project',
              },
              onChanged: (s) => _setScope(ui, s, where),
            ),
          ),
        ),
        _row(
          t,
          'In use',
          'Frames on disk, one promotion away from playing.',
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
                child: Text('Clear', style: t.small),
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
        BridgeCacheLocation.appData => 'With Lumit',
        BridgeCacheLocation.besideProject => 'Beside the project',
        BridgeCacheLocation.custom => 'A folder I choose',
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
          location: BridgeProjectCacheLocation(
              location: location, folder: folder),
        );
      } else {
        // Choosing the custom option without a folder yet leaves the tier where
        // it is; the engine says so by keeping its default, and the Choose…
        // button appears beside the dropdown.
        setDiskCacheLocation(location: location, folder: folder);
        ui.workspace
            .setDiskCacheLocation(location.name, folder.isEmpty ? null : folder);
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

  /// A named group of rows: a quiet label, then one card holding them.
  Widget _section(LumitTheme t, String title, List<Widget> rows) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(2, 0, 0, 4),
              child: Text(title, style: t.small.copyWith(color: t.textMuted)),
            ),
            Container(
              decoration: BoxDecoration(
                color: t.surface1,
                borderRadius: BorderRadius.circular(t.tokens.floatRadius),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < rows.length; i++) ...[
                    // A hairline between rows, never above the first or below
                    // the last: the card's own edge is the boundary there.
                    if (i > 0) Container(height: 1, color: t.hairline),
                    rows[i],
                  ],
                ],
              ),
            ),
          ],
        ),
      );

  /// One row: what it is, a line saying what it does, and its control on the
  /// right. An empty [description] leaves the second line out entirely rather
  /// than reserving blank space for it.
  Widget _row(
    LumitTheme t,
    String title,
    String description,
    Widget control,
  ) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, style: t.body),
                  if (description.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(description,
                          style: t.small.copyWith(color: t.textMuted)),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            control,
          ],
        ),
      );

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
      _row(
        t,
        'Budget',
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

  static String _mib(int bytes) => (bytes / (1 << 20)).toStringAsFixed(0);

  static String _tierLabel(int tier) => switch (tier) {
        1 => 'Full',
        2 => 'Half',
        3 => 'Third',
        _ => 'Quarter',
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
        ? 'Press a shortcut…'
        : chord.isEmpty
            ? 'Not set'
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
          child: Text('Reset', style: t.small),
        ),
      ],
    );
  }
}
