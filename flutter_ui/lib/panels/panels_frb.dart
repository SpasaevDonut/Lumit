// The panel dispatcher of the flutter_rust_bridge test shell — what
// `LumitAppNew` in main.dart docks.
//
// These are deliberately *not* the shipping panels. They are the worked examples
// of the frb calling patterns, each one small enough to read in a sitting:
//
// - [ViewerPanelFrb] — a `Texture` fed by frames the Rust worker pushes down a
//   stream, i.e. the zero-copy path with no pixels crossing the FFI boundary.
// - [TimelinePanelFrb] — reading a comp's layers off a `CompositionReference`
//   and selecting one, with no snapshot JSON in between.
// - [EffectControlsPanelFrb] — the live-drag pattern: parameter values held in
//   Dart, pushed through `renderFrameWithPreview` while the pointer is down, so
//   the document is never committed to per tick.
//
// The shipping dispatcher is panels.dart, which routes the full panels (still on
// the v0 JSON bridge). Panels move across as the frb API grows to cover what
// they need — see docs/TODO.md, "Bridge".

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

/// The Viewer: whatever texture the Rust render worker last published. The
/// frames never cross the FFI boundary as pixels — Rust hands Dart a texture id
/// and Flutter composites it directly (K-177).
class ViewerPanelFrb extends StatelessWidget {
  const ViewerPanelFrb({super.key});

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<LumitUiState>(context);

    return ValueListenableBuilder<int?>(
      valueListenable: state.viewerFrameid,
      builder: (context, value, child) {
        if (value == null) {
          return const PlaceholderPanel(
            icon: LumitIcon.footage,
            title: 'Viewer',
            hint: 'No frame rendered yet — render one from the Timeline.',
          );
        }
        return Texture(textureId: value);
      },
    );
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
                onPressed: () => comp.renderFrame(frame: BigInt.from(frame)),
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

    for (final p in effect.getParameters()) {
      values[p] = effect.getValue(id: p);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final effect = effects[widget.index];

    return Column(
      children: [
        Text(effect.name(), style: t.small),
        for (final p in effect.getParameters())
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
      layer: layer,
      effects: override,
    );

    effects = layer.getEffects();
  }
}
