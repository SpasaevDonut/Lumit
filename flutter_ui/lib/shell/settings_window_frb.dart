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
// Pages the settings do not have yet (Export defaults, the keymap editor,
// colour management — docs/TODO.md) are not listed: an empty page is a promise
// the window cannot keep.

import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/src/rust/api/cache.dart';
import 'package:lumit_flutter/src/rust/api/shell.dart';
import 'package:lumit_flutter/src/rust/api/system.dart';
import 'package:provider/provider.dart';

import '../state/settings.dart';
import '../theme/theme.dart';
import '../widgets/controls.dart';

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
  performance('Performance');

  const SettingsPage(this.label);
  final String label;
}

Future<void> showSettingsWindowFrb(BuildContext context) =>
    showLumitModal<void>(
      context: context,
      builder: (close) => _SettingsWindow(onClose: () => close(null)),
    );

class _SettingsWindow extends StatefulWidget {
  final VoidCallback onClose;
  const _SettingsWindow({required this.onClose});

  @override
  State<_SettingsWindow> createState() => _SettingsWindowState();
}

class _SettingsWindowState extends State<_SettingsWindow> {
  SettingsPage _page = SettingsPage.general;

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final ui = Provider.of<LumitUiState>(context);

    return FloatSurface(
      width: 700,
      child: SizedBox(
        height: 460,
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
        _section(t, 'About', [
          _row(t, 'Version', 'This build of Lumit.',
              Text(_version(), style: t.small)),
          for (final line in bootLog().skip(1))
            _row(t, line, '', const SizedBox.shrink()),
        ]),
      ];

  List<Widget> _appearance(LumitTheme t, LumitUiState ui) => [
        _section(t, 'Theme', [
          _row(
            t,
            'Colour scheme',
            'The palette every panel draws from.',
            SizedBox(
              width: 130,
              child: BareDropdown<LumitColorScheme>(
                key: const ValueKey('settings-scheme'),
                value: ui.scheme,
                options: LumitColorScheme.values,
                // The enum names them; a label written here would be a
                // second list to keep in step for no gain.
                label: (s) => s.label,
                onChanged: (s) => setState(() => ui.setScheme(s)),
              ),
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
    ];
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
          onSet: (bytes) => setState(() => setCacheBudget(bytes: bytes)),
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
          onSet: (bytes) => setState(() => setVramCacheBudget(bytes: bytes)),
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
    ];
  }

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
  /// it will not say (every platform but Windows so far).
  static double get _systemMib => _mibOf(systemMemoryBytes());
  static double get _vramMib => _mibOf(videoMemoryBytes());

  static double _mibOf(BigInt bytes) {
    final mib = (bytes >> 20).toDouble();
    return mib <= 0 ? _unknownMemoryMib : mib;
  }

  /// A round figure for a sentence: "32 GB", or megabytes when it is small.
  static String _gib(double mib) =>
      mib >= 1024 ? '${(mib / 1024).round()} GB' : '${mib.round()} MB';

  /// The engine's own first boot-log line is the build banner.
  static String _version() => bootLog().isEmpty ? 'unknown' : bootLog().first;

  static String _mib(int bytes) => (bytes / (1 << 20)).toStringAsFixed(0);

  static String _tierLabel(int tier) => switch (tier) {
        1 => 'Full',
        2 => 'Half',
        3 => 'Third',
        _ => 'Quarter',
      };
}
