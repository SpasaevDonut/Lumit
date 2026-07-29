// The maths both halves of the Timeline slide by while a layer is dragged
// (K-208). Pure, so it is tested without an engine or a widget tree — and it
// has to be right in one place only, which is the point of it being shared.

import 'package:flutter_test/flutter_test.dart';
import 'package:lumit_flutter/panels/timeline_panel_frb.dart';

void main() {
  // Three layers: the middle one twirled open with two fold rows, so the
  // heights are not all the same and a shift cannot accidentally be right.
  const heights = [22.0, 66.0, 22.0];

  test('nothing moves when nothing is being dragged', () {
    for (var i = 0; i < heights.length; i++) {
      expect(layerDragShift(heights, null, i), 0);
      expect(layerDragShift(heights, const LayerDrag(1, 1), i), 0);
    }
  });

  test('dragging down carries the block past what it passes', () {
    const drag = LayerDrag(0, 2);
    // The lifted block travels the height of both blocks it overtakes.
    expect(layerDragShift(heights, drag, 0), 66.0 + 22.0);
    // Each of those moves one lift's height the other way.
    expect(layerDragShift(heights, drag, 1), -22.0);
    expect(layerDragShift(heights, drag, 2), -22.0);
  });

  test('dragging up is the same in reverse', () {
    const drag = LayerDrag(2, 0);
    expect(layerDragShift(heights, drag, 2), -(22.0 + 66.0));
    expect(layerDragShift(heights, drag, 0), 22.0);
    expect(layerDragShift(heights, drag, 1), 22.0);
  });

  test('a block outside the moved span stays put', () {
    const four = [22.0, 22.0, 22.0, 22.0];
    const drag = LayerDrag(0, 1);
    expect(layerDragShift(four, drag, 2), 0);
    expect(layerDragShift(four, drag, 3), 0);
  });

  test('an index that has gone away is left alone', () {
    // The stack can shrink under a drag — a delete, a filter, a search.
    expect(layerDragShift(heights, const LayerDrag(0, 9), 0), 0);
    expect(layerDragShift(heights, const LayerDrag(9, 0), 0), 0);
    expect(layerDragShift(heights, const LayerDrag(0, 2), 7), 0);
  });
}
