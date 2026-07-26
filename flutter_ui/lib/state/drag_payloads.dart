// What a drag carries between panels.
//
// Each of these types is the *contract* between one panel that produces a drag
// and another that accepts it: nothing else produces a `FootageDragData`, and
// the Timeline's drop target accepts nothing else. Changing a payload therefore
// breaks a gesture silently — the drop simply stops matching — which is why they
// live here together rather than beside whichever panel happened to need one
// first.

/// A footage item dragged from the Project panel onto the Timeline.
class FootageDragData {
  final String itemId;
  final String name;
  const FootageDragData(this.itemId, this.name);
}

/// An effect dragged from the Effects & presets panel onto a layer.
class EffectDragData {
  /// The stable match name `addEffect` takes.
  final String name;
  final String label;
  const EffectDragData(this.name, this.label);
}
