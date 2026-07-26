// The panel dispatcher of the flutter_rust_bridge test shell — what
// `LumitAppNew` in main.dart docks.
//
// These are deliberately *not* the shipping panels. They are the worked examples
// of the frb calling patterns, each one small enough to read in a sitting:
//
// - [ViewerPanelFrb] — frames the Rust worker pushes down a stream: a platform
//   `Texture` on either zero-copy path, or a decoded image on the portable
//   read-back one.
// - [TimelinePanelFrb] — reading a comp's layers off a `CompositionReference`
//   and selecting one, with no snapshot JSON in between.
// - [EffectControlsPanelFrb] — the live-drag pattern: parameter values held in
//   Dart, pushed through `renderFrameWithPreview` while the pointer is down, so
//   the document is never committed to per tick.
//
// The shipping dispatcher is panels.dart, which routes the full panels (still on
// the v0 JSON bridge). Panels move across as the frb API grows to cover what
// they need — see docs/TODO.md, "Bridge".

import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/src/rust/api/effect.dart';
import 'package:lumit_flutter/widgets/controls.dart';
import 'package:provider/provider.dart';

import '../icons/icons.dart';
import '../state/dock.dart';
import 'placeholder.dart';
import 'project_panel_frb.dart';

Widget buildPanelBodyFrb(BuildContext context, Panel panel) => switch (panel) {
      Panel.project => const ProjectPanelFrb(),
      Panel.viewer => const ViewerPanelFrb(),
      Panel.timeline => const TimelinePanelFrb(),
      Panel.effectControls => const EffectControlsPanelFrb(),
      Panel.effectsAndPresets => const PlaceholderPanel(
          icon: LumitIcon.star,
          title: 'Effects & presets',
          hint: 'Not yet ported to the frb bridge.',
        ),
      Panel.scopes => const PlaceholderPanel(
          icon: LumitIcon.nodes,
          title: 'Scopes',
          hint: 'Not yet ported to the frb bridge.',
        ),
      Panel.hierarchy => const PlaceholderPanel(
          icon: LumitIcon.nodes,
          title: 'Hierarchy',
          hint: 'Not yet ported to the frb bridge.',
        ),
    };

/// The Viewer: whatever the Rust render worker last published.
///
/// Two shapes, because the engine has two ways to hand over a frame and which
/// one a build uses is decided at compile time:
///
/// - a **platform texture id** on either zero-copy path (Windows shared D3D12
///   texture, Linux DMA-BUF) — the pixels never cross the FFI boundary at all,
///   Flutter composites the engine's own GPU texture directly (K-177);
/// - a **decoded image** on the portable read-back path, which is the default
///   build on Windows until `--features shared-texture` is turned on.
///
/// The two are mutually exclusive and `LumitUiState` clears whichever is stale,
/// so preferring the texture here is just an ordering choice, not a guess.
class ViewerPanelFrb extends StatelessWidget {
  const ViewerPanelFrb({super.key});

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<LumitUiState>(context);

    // LayoutBuilder because the Viewer is docked: what matters is this panel's
    // box, not the window's, and only the panel knows it.
    return LayoutBuilder(
      builder: (context, constraints) {
        _reportScale(state, constraints);

        return ValueListenableBuilder<int?>(
          valueListenable: state.viewerFrameid,
          builder: (context, textureId, child) {
            if (textureId != null) return Texture(textureId: textureId);

            return ValueListenableBuilder<ui.Image?>(
              valueListenable: state.viewerImage,
              builder: (context, image, child) {
                if (image == null) {
                  return const PlaceholderPanel(
                    icon: LumitIcon.footage,
                    title: 'Viewer',
                    hint:
                        'No frame rendered yet — render one from the Timeline.',
                  );
                }
                // `fit: contain` so a comp of any aspect sits inside the panel
                // rather than being stretched to it.
                return Center(
                  child: RawImage(image: image, fit: BoxFit.contain),
                );
              },
            );
          },
        );
      },
    );
  }

  /// Work out what fraction of comp resolution this panel is showing, and record
  /// it so the next render request asks for that much and no more.
  ///
  /// A plain field write with no notification, so it cannot loop the build it is
  /// called from — the value is read at request time, not watched.
  void _reportScale(LumitUiState state, BoxConstraints constraints) {
    final comp = state.selectedComp;
    if (comp == null || !constraints.hasBoundedWidth) return;

    final size = comp.getSize();
    if (size.width == 0 || size.height == 0) return;

    // Fit: the limiting dimension decides, matching how the frame is drawn.
    final byWidth = constraints.maxWidth / size.width;
    final byHeight = constraints.maxHeight / size.height;
    state.reportViewerScale(byWidth < byHeight ? byWidth : byHeight);
  }
}

/// The Timeline: the front comp's layers, and a button that asks the worker for
/// one frame. Layers come straight off the `CompositionReference` — the
/// reference *is* the identity, so there is no snapshot to diff or id to resolve.
class TimelinePanelFrb extends StatefulWidget {
  const TimelinePanelFrb({super.key});

  @override
  State<TimelinePanelFrb> createState() => _TimelinePanelFrbState();
}

class _TimelinePanelFrbState extends State<TimelinePanelFrb> {
  int frame = 161;

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<LumitUiState>(context);
    final comp = state.selectedComp;

    if (comp == null) {
      return const PlaceholderPanel(
        icon: LumitIcon.comp,
        title: 'Timeline',
        hint: 'Select a composition in the Project panel.',
      );
    }

    final layers = comp.getLayers();
    final t = ThemeScope.of(context).theme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            spacing: 8,
            children: [
              HouseButton(
                frameless: false,
                onPressed: () => comp.renderFrame(
                    frame: BigInt.from(frame), scale: state.viewerScale),
                child: Text('Render frame:', style: t.small),
              ),
              DragValueField(
                value: frame,
                min: 0,
                max: 500,
                onChanged: (value) => setState(() => frame = value.toInt()),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: layers.length,
            itemBuilder: (context, index) {
              final layer = layers[index];
              return HouseButton(
                onPressed: () => state.selectedLayer.value = layer,
                child: Text(layer.getName(), style: t.small),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// The Effect controls: the selected layer's effect stack.
class EffectControlsPanelFrb extends StatelessWidget {
  const EffectControlsPanelFrb({super.key});

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<LumitUiState>(context);

    if (state.selectedComp == null) {
      return const PlaceholderPanel(
        icon: LumitIcon.fx,
        title: 'Effect controls',
        hint: 'Select a composition, then a layer.',
      );
    }

    return ValueListenableBuilder(
      valueListenable: state.selectedLayer,
      builder: (context, layer, child) {
        if (layer == null) {
          return const PlaceholderPanel(
            icon: LumitIcon.fx,
            title: 'Effect controls',
            hint: 'Select a layer in the Timeline.',
          );
        }
        final effects = layer.getEffects();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                '${layer.getName()} (${effects.length})',
                style: ThemeScope.of(context).theme.small,
              ),
            ),
            for (int i = 0; i < effects.length; i++)
              EffectEditorFrb(
                effects,
                i,
                key: ValueKey(
                  'effect-editor-${state.selectedComp?.internalid}'
                  '-${layer.internallayerId}-${effects[i].name()}',
                ),
              ),
          ],
        );
      },
    );
  }
}

/// One effect's parameter rows, and the live-drag path.
///
/// While a value is being dragged it is held here in Dart and pushed through
/// `renderFrameWithPreview`, which patches a *clone* of the document engine-side
/// (see `render_comp_with_preview` in the bridge's worker). So a drag produces
/// pixels without producing commits — no undo entry and no journal write per
/// tick — and only the release commits, once. Preview renders are throttled to
/// roughly one per 20 ms so a fast drag cannot outrun the renderer.
class EffectEditorFrb extends StatefulWidget {
  const EffectEditorFrb(this.effects, this.index, {super.key});

  final List<BridgeEffectInstance> effects;
  final int index;

  @override
  State<EffectEditorFrb> createState() => _EffectEditorFrbState();
}

class _EffectEditorFrbState extends State<EffectEditorFrb> {
  late List<BridgeEffectInstance> effects;
  Map<String, double> values = {};
  Duration lastUpdate = Duration.zero;
  final Stopwatch _since = Stopwatch()..start();

  static const _previewInterval = Duration(milliseconds: 20);

  @override
  void initState() {
    super.initState();
    effects = widget.effects;
    final effect = effects[widget.index];

    // A null value means the parameter is not a static scalar — a colour, a
    // point, a choice, or a keyframed float. The bridge cannot express those
    // yet, so they are left out rather than shown as a misleading 0.
    for (final p in effect.getParameters()) {
      final value = effect.getValue(id: p);
      if (value != null) values[p] = value;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final effect = effects[widget.index];

    return Column(
      children: [
        Text(effect.name(), style: t.small),
        // Only the parameters the bridge can currently read and write.
        for (final p in effect.getParameters().where(values.containsKey))
          Row(
            children: [
              Text(p, style: t.mono),
              DragValueField(
                value: values[p] ?? 0.0,
                min: 0,
                max: 200,
                onChanged: (value) {},
                onChangeLive: (value) {
                  setState(() => values[p] = value.toDouble());
                  if (_since.elapsed - lastUpdate > _previewInterval) {
                    doPreview();
                  }
                },
                onChangeEnd: (value) {
                  // TODO: commit the value to the document on release.
                },
              ),
            ],
          ),
      ],
    );
  }

  void doPreview() {
    lastUpdate = _since.elapsed;

    final uiState = Provider.of<LumitUiState>(context, listen: false);
    final comp = uiState.selectedComp;
    final layer = uiState.selectedLayer.value;
    if (comp == null || layer == null) return;

    final override = effects;
    for (final p in values.keys) {
      override[widget.index].setValue(id: p, value: values[p] ?? 0.0);
    }

    comp.renderFrameWithPreview(
      frame: BigInt.from(161),
      scale: uiState.viewerScale,
      layer: layer,
      effects: override,
    );

    effects = layer.getEffects();
  }
}
