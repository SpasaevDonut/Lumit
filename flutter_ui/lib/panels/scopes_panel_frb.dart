// The Scopes panel, on the flutter_rust_bridge API.
//
// One of the four traces — waveform, parade, vectorscope, histogram — of the
// frame at the playhead. The binning runs on the GPU and only the finished
// 256x256 picture crosses, which is why a scope costs a fraction of what
// reading the frame back would.
//
// **Why it asks for its own render.** The trace needs CPU pixels, and the
// zero-copy Viewer paths never bring any back — so a scope cannot borrow the
// picture on screen and has to render its own. That is real work per trace, so
// this throttles rather than tracing every frame the playhead touches, and
// nothing happens at all while the panel is not on screen.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/src/rust/api/state.dart';
import 'package:provider/provider.dart';

import '../icons/icons.dart';
import '../theme/theme.dart';
import '../widgets/controls.dart';
import 'placeholder.dart';

/// The trace codes the engine reads.
enum ScopeKind { waveform, parade, vectorscope, histogram }

/// The engine's fixed trace size.
const int _traceEdge = 256;

/// No more than one trace request in flight per this long. A trace is a real
/// render, so a scrub must not queue one per frame it passes through.
const Duration _throttle = Duration(milliseconds: 120);

class ScopesPanelFrb extends StatefulWidget {
  const ScopesPanelFrb({super.key});

  @override
  State<ScopesPanelFrb> createState() => _ScopesPanelFrbState();
}

class _ScopesPanelFrbState extends State<ScopesPanelFrb> {
  ScopeKind _kind = ScopeKind.waveform;
  ui.Image? _trace;
  StreamSubscription<WorkerResponse>? _responses;

  final Stopwatch _since = Stopwatch()..start();
  Duration _lastRequest = Duration.zero;
  int _lastFrame = -1;

  @override
  void initState() {
    super.initState();
    final state = Provider.of<LumitState>(context, listen: false);
    _responses = state.onWorkerResponse.listen(_onResponse);
  }

  @override
  void dispose() {
    _responses?.cancel();
    _trace?.dispose();
    super.dispose();
  }

  /// Scope traces ride the same worker stream as the frames, so this ignores
  /// everything that is not one.
  void _onResponse(WorkerResponse response) {
    if (response is! WorkerResponse_Scope) return;
    ui.decodeImageFromPixels(
      Uint8List.fromList(response.field0.rgba),
      _traceEdge,
      _traceEdge,
      ui.PixelFormat.rgba8888,
      (image) {
        if (!mounted) {
          image.dispose();
          return;
        }
        setState(() {
          _trace?.dispose();
          _trace = image;
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final ui_ = Provider.of<LumitUiState>(context);
    final comp = ui_.selectedComp;
    if (comp == null) {
      return const PlaceholderPanel(
        icon: LumitIcon.graphCurve,
        title: 'Scopes',
        hint: 'Select a composition in the Project panel.',
      );
    }

    return ValueListenableBuilder<int>(
      valueListenable: ui_.playheadFrame,
      builder: (context, frame, _) {
        _requestIfDue(ui_, frame);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 26,
              color: t.surface1,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(
                children: [
                  SizedBox(
                    width: 110,
                    child: BareDropdown<ScopeKind>(
                      key: const ValueKey('scope-kind'),
                      value: _kind,
                      options: ScopeKind.values,
                      label: _label,
                      onChanged: (k) => setState(() {
                        _kind = k;
                        // A new trace kind is worth an immediate request rather
                        // than waiting out the throttle on a picture the user
                        // just asked to change.
                        _lastFrame = -1;
                      }),
                    ),
                  ),
                  const Spacer(),
                  Text('frame $frame',
                      style: t.small.copyWith(color: t.textMuted)),
                ],
              ),
            ),
            Expanded(
              child: Container(
                color: t.surface0,
                child: Center(
                  child: _trace == null
                      ? Text('Waiting for a trace', style: t.small)
                      : AspectRatio(
                          aspectRatio: 1,
                          child: RawImage(
                            key: const ValueKey('scope-trace'),
                            image: _trace,
                            fit: BoxFit.contain,
                            filterQuality: FilterQuality.none,
                          ),
                        ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Ask for a trace when the frame has moved and the throttle has elapsed.
  ///
  /// Called from `build`, so it must never call `setState` — it only sends, and
  /// the reply arrives on the worker stream.
  void _requestIfDue(LumitUiState state, int frame) {
    final comp = state.selectedComp;
    if (comp == null) return;
    // Same frame, and too soon — nothing to ask for. A *different* frame is
    // always worth a request, and so is `_lastFrame = -1`, which is how the
    // kind picker forces one through without waiting out the throttle. A second
    // unconditional throttle check used to sit here and swallow both.
    if (frame == _lastFrame && _since.elapsed - _lastRequest < _throttle) {
      return;
    }

    _lastFrame = frame;
    _lastRequest = _since.elapsed;
    final t = ThemeScope.of(context).theme;
    comp.renderScope(
      frame: BigInt.from(frame),
      scale: state.viewerScale,
      kind: _kind.index,
      colours: scopeColoursFor(t),
    );
  }

  static String _label(ScopeKind kind) => switch (kind) {
        ScopeKind.waveform => 'Waveform',
        ScopeKind.parade => 'RGB parade',
        ScopeKind.vectorscope => 'Vectorscope',
        ScopeKind.histogram => 'Histogram',
      };
}

/// Background, trace, then the R, G and B tints — the five triples the engine
/// takes, from the theme rather than from constants, so a scope drawn in the
/// light scheme is legible in it.
List<Uint8List> scopeColoursFor(LumitTheme t) {
  Uint8List rgb(Color c) => Uint8List.fromList([
        (c.r * 255).round(),
        (c.g * 255).round(),
        (c.b * 255).round(),
      ]);
  return [
    rgb(t.surface0),
    rgb(t.textPrimary),
    rgb(t.layer.footage),
    rgb(t.layer.solid),
    rgb(t.accent),
  ];
}
