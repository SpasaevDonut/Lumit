// What Copy put down, for Paste to pick up (K-275).
//
// **In plain terms.** Copying a layer or an effect asks the engine for it as
// text — the same document a project file is made of, so everything on it
// travels: keyframes, masks, paint, switches, the lot. This holds that text
// until something pastes it.
//
// **Why the application's own clipboard and not the system one.** The payload
// is a Lumit document, and the system clipboard is shared with every other
// application: a stray copy from a text editor would arrive here as something
// to refuse, and Lumit's own JSON pasted into a chat window is noise. Keeping
// it here also means Copy in a text field and Copy on a layer never fight over
// the same tray. The cost is that copying between two running Lumit windows
// does not work yet; when that is wanted, this is the one place that changes
// (docs/TODO.md).

/// What kind of thing is on the clipboard, so Paste knows what to do with the
/// text rather than guessing from its shape.
enum ClipboardKind { layer, effects }

/// The one tray. Held by the shell state, read by the Edit menu.
class LumitClipboard {
  ClipboardKind? _kind;
  String? _text;

  /// What is on it, or null when nothing has been copied this session.
  ClipboardKind? get kind => _kind;

  bool get isEmpty => _text == null;

  /// The copied document, or null. Paired with [kind]: a caller reads both or
  /// neither, which is why they are not two fields to keep in step by hand.
  String? get text => _text;

  /// Put a layer document down (from `LayerReference.copyLayer`).
  void putLayer(String text) {
    _kind = ClipboardKind.layer;
    _text = text;
  }

  /// Put an effect document down (from `LayerReference.copyEffects`) — one
  /// effect or a whole stack; both are the same `.lumfx` shape, so both paste
  /// the same way.
  void putEffects(String text) {
    _kind = ClipboardKind.effects;
    _text = text;
  }

  void clear() {
    _kind = null;
    _text = null;
  }
}
