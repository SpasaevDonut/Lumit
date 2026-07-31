// How big a layer is, in its own pixels — the rectangle the Viewer draws a
// wireframe round and hit-tests a click against (K-217).
//
// **In plain terms.** A layer's transform says where it sits, how big it is
// drawn and which way up. It does not say how big the *thing* is: that comes
// from what the layer is made of — a clip's video is 1920×1080, a solid is
// whatever it was made at, a precomp is the size of the comp inside it. Without
// that, "draw a box round this layer" and "is the pointer over this layer?"
// have no answer.
//
// **Why the answers are cached.** A clip's size is a question about a *file*,
// and the only honest way to answer it is to open the file and look — which is
// disk work, and asynchronous. So each footage item is probed once and
// remembered for the session; everything else is a cheap read of the document
// and is remembered for as long as the document does not move. Nothing here
// blocks a paint: while a probe is in flight the layer falls back to the comp's
// own size, and the answer arriving repaints whoever is listening.

import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:lumit_flutter/src/rust/api/footage.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';
import 'package:lumit_flutter/src/rust/api/project_item.dart';
import 'package:uuid/uuid.dart';

/// A Null layer's box, in layer pixels.
///
/// A Null has no pixels at all — it exists to be parented to (docs/01) — so its
/// size is a drawing convention rather than a fact about content. 100×100 is
/// After Effects' own, and the transform the engine gives a new Null anchors on
/// the same square.
const Size nullLayerBounds = Size(100, 100);

/// The box a shape layer's art fills, in the layer's own coordinates, or null
/// when there is no art (K-230).
///
/// The **control points** bound the curve rather than the curve itself — a cubic
/// never leaves its own control hull — which is the same rule `lumit-core`'s
/// `shape::ShapeItem::bounds` follows. The two must agree: the engine sizes the
/// raster with its version and the wireframe is drawn from this one.
Size? shapeContentsBounds(List<BridgeShapeItem> contents) {
  double? minX, minY, maxX, maxY;
  for (final item in contents) {
    final half = item.stroke != null ? item.strokeWidth / 2 : 0.0;
    for (final v in item.vertices) {
      for (final (x, y) in [
        (v.x, v.y),
        (v.x + v.tanInX, v.y + v.tanInY),
        (v.x + v.tanOutX, v.y + v.tanOutY),
      ]) {
        minX = minX == null ? x - half : math.min(minX, x - half);
        minY = minY == null ? y - half : math.min(minY, y - half);
        maxX = maxX == null ? x + half : math.max(maxX, x + half);
        maxY = maxY == null ? y + half : math.max(maxY, y + half);
      }
    }
  }
  if (minX == null || minY == null || maxX == null || maxY == null) return null;
  return Size(math.max(maxX - minX, 1), math.max(maxY - minY, 1));
}

/// Every layer's own size, answered from the document and remembered.
class LayerBoundsCache extends ChangeNotifier {
  /// Sizes by layer id, good for as long as [_revision] is.
  final Map<UuidValue, Size> _byLayer = {};

  /// Probed media sizes by footage item id. Kept for the session: a file's
  /// dimensions do not change under us, and a relink refreshes through the
  /// document revision below anyway.
  final Map<UuidValue, Size> _media = {};

  /// Footage items with a probe in flight, so a repaint does not start a
  /// second one.
  final Set<UuidValue> _probing = {};

  BigInt? _revision;

  /// Forget the per-layer answers when the document has moved on.
  ///
  /// The probed media sizes survive: what a *file* measures does not depend on
  /// the document, and re-probing on every edit would put FFmpeg in the paint
  /// path.
  void _atRevision(BigInt? revision) {
    if (revision == _revision) return;
    _revision = revision;
    _byLayer.clear();
  }

  /// The size of [entry]'s content in layer pixels, at document [revision].
  ///
  /// Never null and never zero: a layer whose real size is not knowable yet —
  /// a clip still being probed, a kind with no content of its own — measures
  /// the comp, which is the same fallback the engine uses when it places a clip
  /// it cannot probe.
  Size boundsOf(
    BridgeLayerEntry entry, {
    required BridgeCompSize compSize,
    required BigInt? revision,
  }) {
    _atRevision(revision);
    final id = entry.layer.internallayerId;
    final held = _byLayer[id];
    if (held != null) return held;
    final measured = _measure(entry, compSize);
    _byLayer[id] = measured;
    return measured;
  }

  Size _compSize(BridgeCompSize s) =>
      Size(s.width.toDouble(), s.height.toDouble());

  Size _measure(BridgeLayerEntry entry, BridgeCompSize compSize) {
    // A Null never draws, so its box is the convention above rather than
    // anything read from the document.
    if (entry.info.kind == BridgeLayerKind.nullLayer) return nullLayerBounds;

    // A shape layer is exactly as big as its art, and **that changes as the art
    // is edited** (K-230) — the first kind whose size is not fixed by a source.
    // The cache follows the document's revision, so it keeps up; this comment
    // is here because the rest of this file was written when "a layer's size"
    // was a constant.
    if (entry.info.kind == BridgeLayerKind.shape) {
      final art = shapeContentsBounds(entry.info.shapeContents);
      return art ?? _compSize(compSize);
    }

    final ItemReference? source;
    try {
      source = entry.layer.getSourceItem();
    } catch (_) {
      // The layer has gone between the model being read and this call.
      return _compSize(compSize);
    }

    switch (source) {
      // A nested comp is exactly as big as the comp inside it.
      case ItemReference_Composition(:final field0):
        try {
          return _compSize(field0.getSize());
        } catch (_) {
          return _compSize(compSize);
        }
      case ItemReference_Solid(:final field0):
        try {
          final def = field0.getDefinition();
          return Size(def.width.toDouble(), def.height.toDouble());
        } catch (_) {
          return _compSize(compSize);
        }
      case ItemReference_Footage(:final field0):
        final item = field0.internalid;
        final probed = _media[item];
        if (probed != null) return probed;
        _probe(field0, item);
        return _compSize(compSize);
      // Text, Sequence, Adjustment, Camera and anything sourceless: the comp.
      // An adjustment layer genuinely is comp-sized (it is a container for
      // effects over everything below it); text has no measured bounds on this
      // frontend yet, and guessing a smaller box would put the handles
      // somewhere the glyphs are not.
      case _:
        return _compSize(compSize);
    }
  }

  /// Ask the engine for a clip's real dimensions, once.
  ///
  /// Fire-and-forget by design: the caller is painting, and the answer landing
  /// notifies listeners so the boxes are redrawn with it. A file that cannot be
  /// probed (missing, unreadable, audio-only) records nothing, so the layer
  /// keeps the comp-sized fallback rather than a box of zero pixels.
  void _probe(FootageReference footage, UuidValue item) {
    if (!_probing.add(item)) return;
    footage.mediaInfo().then((info) {
      _probing.remove(item);
      if (info == null || info.width <= 0 || info.height <= 0) return;
      _media[item] = Size(info.width.toDouble(), info.height.toDouble());
      // The per-layer answers were computed against the fallback.
      _byLayer.clear();
      notifyListeners();
    }, onError: (_) {
      _probing.remove(item);
    });
  }
}
