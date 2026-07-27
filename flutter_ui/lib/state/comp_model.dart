// The Dart-side read model (K-184): the fronted comp as the panels draw it.
//
// In plain terms: every question a panel used to ask the engine while drawing
// — layer names, switches, bar positions, effect values — is answered from
// this one held copy instead. The copy is refreshed by ONE bridge call
// (`getModel`), and only when the engine says the document changed. So a
// rebuild costs no bridge calls at all, and pure-interface changes (selecting
// a layer, moving the playhead) never touch the engine to redraw.
//
// The model is plain data. Edits still go through the reference handles —
// this holds what to *show*, never what to *do*.

import 'package:flutter/foundation.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:uuid/uuid.dart';

class CompModel extends ChangeNotifier {
  CompositionReference? _comp;
  BridgeCompModel? _model;

  /// The engine revision [_model] was read at, or null before the first read.
  /// Comparing it per read is what makes every rebuild honest: a widget that
  /// rebuilds for any reason sees the current document, exactly as when every
  /// widget re-read the engine itself — for one call instead of dozens.
  BigInt? _revision;

  /// The layers of the fronted comp, top of the stack first. Empty when no
  /// comp is fronted (panels then show their placeholder anyway).
  List<BridgeLayerEntry> get layers {
    _freshen();
    return _model?.layers ?? const [];
  }

  /// The comp's length in frames, matching `durationFrames`.
  int get durationFrames {
    _freshen();
    return _model?.durationFrames.toInt() ?? 0;
  }

  /// The comp's rate as a plain number — what maps seconds onto the time
  /// axis (the waveform lane) without a bridge call per paint. 60 before any
  /// model has loaded, so nothing divides by zero.
  double get fps {
    _freshen();
    final fps = _model?.fps ?? 60.0;
    return fps > 0 ? fps : 60.0;
  }

  /// Point the model at [comp] (or null) and read it.
  void bind(CompositionReference? comp) {
    _comp = comp;
    refresh();
  }

  /// Re-read the whole model — one bridge call — and repaint whoever listens.
  ///
  /// Called when the engine reports a change, and by panels right after they
  /// commit an op, so their own edit is on screen without waiting for the
  /// change stream's round trip.
  void refresh() {
    _revision = null;
    _freshen();
    notifyListeners();
  }

  /// Re-read only if the document has moved since the last read.
  void _freshen() {
    final comp = _comp;
    if (comp == null) {
      _model = null;
      return;
    }
    try {
      final revision = comp.documentRevision();
      if (revision == _revision && _model != null) return;
      _model = comp.getModel();
      _revision = revision;
    } catch (_) {
      // The comp has gone (deleted, or the project closed): an empty model,
      // not a crash — the panels show their placeholders.
      _model = null;
    }
  }

  /// The entry for [id], or null when the layer is gone.
  BridgeLayerEntry? byId(UuidValue id) {
    for (final entry in layers) {
      if (entry.layer.internallayerId == id) return entry;
    }
    return null;
  }
}
