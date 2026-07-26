// The panel dispatcher of the flutter_rust_bridge test shell — what
// `LumitAppNew` in main.dart docks.
//
// These are deliberately *not* the shipping panels. They are the worked examples
// of the frb calling patterns, each one small enough to read in a sitting:
//
// - [ViewerPanelFrb] — frames the Rust worker pushes down a stream: a platform
//   `Texture` on either zero-copy path, or a decoded image on the portable
//   read-back one.
//
// The ported panels live in files of their own and are routed from here:
// [ProjectPanelFrb] and [EffectControlsPanelFrb]. The shipping dispatcher for
// what is still on the v0 JSON bridge is panels.dart. Panels move across as the
// frb API grows to cover what they need — see docs/TODO.md, "Bridge".

import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/main.dart';
import 'package:provider/provider.dart';

import '../icons/icons.dart';
import '../state/dock.dart';
import 'placeholder.dart';
import 'effect_controls_panel_frb.dart';
import 'project_panel_frb.dart';
import 'timeline_panel_frb.dart';

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
