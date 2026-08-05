// What the last measured frame cost, per layer and per effect (docs/13 §7.1).
//
// **In plain terms.** "Why is this comp slow?" should be answerable by looking
// at it. The engine can measure each layer's own picture and each effect within
// it, and this holds the latest set of those numbers so the Timeline's
// render-time column and the Effect controls panel can show them beside the
// things they are about.
//
// **The measuring is switched on deliberately**, and it is off until it is.
// Measuring is not free — the engine waits for the graphics card at every node,
// so a millisecond means the work rather than the paperwork, and that wait is
// exactly the overlap a brisk preview lives on. A number nobody is reading is
// therefore not worth its cost: the Timeline's render-time column carries the
// switch, one switch for the whole session, and every indicator reads the same
// numbers it turns on.

import 'package:flutter/foundation.dart';

import '../src/rust/api/cache.dart';
import '../src/rust/api/state.dart';

/// The numbers from the last measured frame, and the switch that asks for them.
class RenderTimings extends ChangeNotifier {
  /// How the engine is asked to start or stop measuring. Injectable so the
  /// rules below can be tested without a bridge library loaded; the default is
  /// the real call and every caller in the application uses it.
  final void Function(bool on) _askEngine;

  /// Called when measuring starts, to ask for the frame under the playhead
  /// again. A number only exists for a frame the engine *composites*, and the
  /// frame on screen has already been made — so without a fresh ask the column
  /// would stay empty until something else happened to want a render.
  final void Function()? _onMeasuringStarted;

  RenderTimings({
    void Function(bool on)? askEngine,
    void Function()? onMeasuringStarted,
  })  : _askEngine = askEngine ?? ((on) => setRenderProfiling(on_: on)),
        _onMeasuringStarted = onMeasuringStarted;

  bool _measuring = false;

  int? _frame;
  double? _totalMs;
  Map<String, double> _layers = const {};
  Map<String, double> _effects = const {};

  /// The frame these numbers are of, or null before the first measured frame.
  int? get frame => _frame;

  /// The whole frame's cost, including the stages no layer owns.
  double? get totalMs => _totalMs;

  /// True while the engine is measuring — what the indicators read to tell
  /// "not measured" from "measured, and this layer cost nothing".
  bool get measuring => _measuring;

  /// One layer's cost in milliseconds, or null when the last measured frame
  /// had no such layer (it was hidden, out of its span, or inside a Precomp).
  double? layerMs(String layerId) => _layers[layerId];

  /// One effect instance's cost in milliseconds, or null as above.
  double? effectMs(String effectId) => _effects[effectId];

  /// Turn measuring on or off. Turning it off drops the numbers as well, so an
  /// indicator switched back on never opens on a stale frame's costs — which
  /// would be the one reading worse than none at all.
  void setMeasuring(bool on) {
    if (_measuring == on) return;
    _measuring = on;
    _askEngine(on);
    if (on) {
      _onMeasuringStarted?.call();
    } else {
      _frame = null;
      _totalMs = null;
      _layers = const {};
      _effects = const {};
    }
    notifyListeners();
  }

  /// A measured frame arrived. Ignored once measuring is off: a frame already
  /// in flight when the switch went out is not a reason to put numbers back.
  void report(BridgeFrameProfile profile) {
    if (!_measuring) return;
    _frame = profile.frame.toInt();
    _totalMs = profile.totalMs;
    final layers = <String, double>{};
    final effects = <String, double>{};
    for (final layer in profile.layers) {
      layers[layer.layer] = layer.ms;
      for (final effect in layer.effects) {
        effects[effect.effect] = effect.ms;
      }
    }
    _layers = layers;
    _effects = effects;
    notifyListeners();
  }
}

/// A measured cost as the indicators write it: milliseconds to one decimal
/// place while that is readable, whole milliseconds once the number is large,
/// and seconds past a thousand — so a column of them stays the same width and
/// a slow layer is obvious without arithmetic.
String formatRenderMs(double ms) {
  if (!ms.isFinite || ms < 0) return '—';
  if (ms >= 1000) return '${(ms / 1000).toStringAsFixed(2)} s';
  if (ms >= 100) return '${ms.round()} ms';
  return '${ms.toStringAsFixed(1)} ms';
}
