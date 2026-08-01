// The Timeline panel, on the flutter_rust_bridge API.
//
// Two columns side by side over one shared time axis: an **outline** on the
// left (layer number, label chip, name, switches, blend mode, parent) and a
// **layer area** on the right (the ruler, the playhead, one bar per layer, the
// work area and the markers). Everything draws from the comp read model
// (state/comp_model.dart, K-184); edits go out through the reference handles.
//
// **What is here.** Adding every layer kind, deleting, duplicating, reordering,
// the eight switches, blend mode, parenting, dragging and trimming a layer's
// bar, scrubbing the playhead, the work area and marker cues.
//
// The **Graph** button swaps the layer area for the graph editor
// (graph_editor_frb.dart), which shapes the selected layer's curves.
//
// **The one rule the drags follow.** A bar drag is a live *preview* of nothing —
// unlike an effect or transform drag there is no cheap render to show, because
// moving a layer in time changes what every frame contains. So a bar drag holds
// its offset in Dart and commits one `set_span` on release: one op, one undo
// step, even when the gesture moved the in point and the start offset together.

import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:lumit_flutter/src/rust/api/effect.dart';
import 'package:lumit_flutter/src/rust/api/keymap.dart';
import 'package:lumit_flutter/src/rust/api/layer.dart';
import 'package:lumit_flutter/src/rust/api/project_item.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../icons/icons.dart';
import '../state/comp_model.dart';
import '../state/comp_time.dart';
import '../state/drag_payloads.dart';
import '../state/timecode.dart';
import '../state/timeline_columns.dart';
import '../state/tools.dart';
import '../theme/theme.dart';
import '../widgets/controls.dart';
import '../widgets/marquee.dart';
// The ruler helpers moved with the ruler (shared with the graph editor); the
// re-export keeps their long-standing import path alive for their tests.
export 'timeline_extras_frb.dart' show rulerLabelStepSeconds, rulerLabelOf;

import 'placeholder.dart';
import 'graph_editor_frb.dart';
import 'graph_maths.dart';
import 'package:lumit_flutter/state/preview_throttle.dart';
import 'timeline_extras_frb.dart';
import 'timeline_razor.dart';
import 'effect_param_row_frb.dart';
import 'keyframe_controls_frb.dart';
import 'layer_fold_frb.dart';
import 'transform_rows_frb.dart';

/// The blend-mode names, fetched once per session: the list is static for the
/// life of the process, and every outline row was re-fetching it per rebuild.
List<String>? _blendModes;

/// One layer row's height.
const double _rowHeight = 22;

/// The outline's two header rows: the toolbar (timecode, search, the view
/// buttons) and the column-group header under it.
const double _toolbarHeight = 26;
const double _headerHeight = 20;

/// The time ruler's height: the toolbar and column header stay inside the
/// outline (docs/07 §4.1), so the lane side gives their whole height to the
/// ruler — a taller bar is an easier playhead grab — minus the cache bar
/// tucked under it.
const double _rulerHeight =
    _toolbarHeight + _headerHeight - TimelineCacheBar.height;

/// How near the end of a bar counts as grabbing its edge to trim rather than its
/// middle to move.
const double _trimGrab = 8;

/// Which part of a bar [width] pixels wide a press at [dx] takes hold of.
///
/// Each trim zone is [_trimGrab] wide but never more than a third of the bar,
/// so a bar only a few frames long still keeps a middle to move by — without
/// the cap, a short bar was all edge and could not be dragged along the
/// timeline at all.
BarGrab barGrabAt(double dx, double width) {
  final edge = min(_trimGrab, width / 3);
  if (dx < edge) return BarGrab.trimIn;
  if (dx > width - edge) return BarGrab.trimOut;
  return BarGrab.move;
}

/// A layer drag in flight: the index lifted, and the index it would land on.
///
/// **Held by the panel and read by both halves of the table**, which is the
/// point (K-208). The outline owns the gesture — the name is the stack handle
/// — so when only it knew about the drag, only it could move: the lanes sat
/// still while their layers were being reordered beside them. One value, read
/// by the outline rows and the lane blocks alike, and the two halves slide as
/// one row because they are working from the same number.
class LayerDrag {
  final int from;
  final int to;
  const LayerDrag(this.from, this.to);

  @override
  bool operator ==(Object other) =>
      other is LayerDrag && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);
}

/// Every layer's block height: its own row plus whatever fold rows it shows.
///
/// Worked out **once per panel build and handed to both halves**, rather than
/// each half measuring its own rows. Two measurements that must agree are two
/// chances to disagree — and a half-pixel of disagreement is a table whose
/// lanes drift out of line with their names as it scrolls.
List<double> layerBlockHeights({
  required List<BridgeLayerEntry> layers,
  required Set<String> open,
  required Map<String, bool> hasAudio,
}) =>
    [
      for (final entry in layers)
        _rowHeight *
            (1 +
                (open.contains(entry.layer.internallayerId.toString())
                    ? layerFoldRows(
                        entry: entry,
                        open: open,
                        hasAudio: hasAudio[
                                entry.layer.internallayerId.toString()] ??
                            false,
                      ).length
                    : 0)),
    ];

/// How far the block at [index] slides while a drag is in flight, in pixels;
/// positive is down.
///
/// The lifted block travels the whole way to the slot it would take, and every
/// block it passes moves one lift's height the other way — so the stack reads
/// as already reordered before the drop, which is what makes a drop feel
/// decided rather than guessed at. Pure, so the maths both halves depend on is
/// tested without building a Timeline.
double layerDragShift(List<double> heights, LayerDrag? drag, int index) {
  if (drag == null || drag.from == drag.to) return 0;
  if (index < 0 || index >= heights.length) return 0;
  if (drag.from < 0 || drag.from >= heights.length) return 0;
  if (drag.to < 0 || drag.to >= heights.length) return 0;
  if (index == drag.from) {
    var travel = 0.0;
    if (drag.to > drag.from) {
      for (var i = drag.from + 1; i <= drag.to; i++) {
        travel += heights[i];
      }
      return travel;
    }
    for (var i = drag.to; i < drag.from; i++) {
      travel -= heights[i];
    }
    return travel;
  }
  final lifted = heights[drag.from];
  if (drag.to > drag.from) {
    return index > drag.from && index <= drag.to ? -lifted : 0;
  }
  return index >= drag.to && index < drag.from ? lifted : 0;
}

/// Which slot a drag is aiming at, from how far it has travelled.
///
/// [from] is the block lifted, [travel] how far the pointer has moved down the
/// stack since the lift in pixels (negative is up). Returns the index the block
/// would take if dropped now.
///
/// **Measured against the stack as it was when the drag began**, which is the
/// whole point. The rows on screen are slid out of the way while a drag is in
/// flight, so asking "which row is the pointer over?" asks about geometry the
/// drag itself is moving: each answer slides the rows, which changes the next
/// answer, and the block oscillates between two slots without the pointer
/// moving at all. Travel against the original heights cannot do that — it is
/// a function of the pointer alone.
///
/// The threshold is the midpoint of the block being passed, not its edge: an
/// edge means the slot flips the instant a single pixel of overlap appears,
/// which is the other half of the same jitter. Travelling back to where the
/// drag started therefore returns [from] exactly, so a cancelled-by-hand drag
/// leaves the stack alone.
int layerDragTarget(List<double> heights, int from, double travel) {
  if (from < 0 || from >= heights.length) return from;
  var to = from;
  if (travel > 0) {
    var passed = 0.0;
    for (var i = from + 1; i < heights.length; i++) {
      if (travel < passed + heights[i] / 2) break;
      passed += heights[i];
      to = i;
    }
  } else if (travel < 0) {
    var passed = 0.0;
    for (var i = from - 1; i >= 0; i--) {
      if (-travel < passed + heights[i] / 2) break;
      passed += heights[i];
      to = i;
    }
  }
  return to;
}

/// One layer's block, slid out of a dragged layer's way.
///
/// A transform, not a layout change: the rows keep their places, so a drag
/// never reflows the table under itself — and the same widget wraps the block
/// in the outline and the block in the lanes, which is what keeps them
/// together to the pixel.
class LayerDragSlide extends StatelessWidget {
  final ValueListenable<LayerDrag?> drag;
  final List<double> heights;
  final int index;
  final Widget child;

  const LayerDragSlide({
    super.key,
    required this.drag,
    required this.heights,
    required this.index,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    // The user's animation level, not a constant: at *None* the rows must
    // arrive without travelling at all (15-DESIGN §8), and a hard-coded
    // duration here would be one animation the setting could not reach.
    final duration = animationDuration(ThemeScope.of(context).animationLevel);
    return ValueListenableBuilder<LayerDrag?>(
      valueListenable: drag,
      child: child,
      builder: (context, value, child) {
        final height = index < heights.length ? heights[index] : 0.0;
        return AnimatedSlide(
          offset: height <= 0
              ? Offset.zero
              : Offset(0, layerDragShift(heights, value, index) / height),
          duration: duration,
          curve: Curves.easeOut,
          child: child,
        );
      },
    );
  }
}

class TimelinePanelFrb extends StatefulWidget {
  const TimelinePanelFrb({super.key});

  @override
  State<TimelinePanelFrb> createState() => _TimelinePanelFrbState();
}

class _TimelinePanelFrbState extends State<TimelinePanelFrb> {
  /// What is twirled open: layer ids, and the paths of the groups under them
  /// (`<layer>/transform`, `<layer>/effects/<effect>`, `<layer>/audio`). Held by
  /// the panel rather than by each row so the lane side can leave room for
  /// exactly the rows the outline draws — the two halves are one table, and a
  /// name that does not line up with its bar is worse than no fold-out at all.
  final Set<String> _open = {};

  /// Which layers' sources carry sound, by id. Cached because answering it
  /// probes the file with FFmpeg, which must never happen in a build — the same
  /// reason the Project panel caches missing media. Absent means "not asked
  /// yet", and a layer with no entry simply shows no Audio group until the
  /// answer arrives.
  final Map<String, bool> _hasAudio = {};

  /// Each layer's source waveform peaks, by id — fetched once when its
  /// Waveform twirl first opens (decoding a whole track is not work for a
  /// build), then good for the session: peaks belong to the file, so trims
  /// and drags never invalidate them (K-172).
  final Map<String, BridgeAudioPeaks> _peaks = {};

  /// One lane's worth of buckets: plenty for any panel width.
  static const int _peakBuckets = 2048;

  /// Each Footage layer's source length in comp frames, by layer id. Cached
  /// for the same reason [_hasAudio] is: the answer comes from probing the
  /// file with FFmpeg, which must never happen in a build. Absent means "not
  /// asked yet"; a null value means the answer never came (no media feature,
  /// missing file), which leaves that layer's ends free.
  final Map<String, int?> _footageFrames = {};

  /// How far each layer's ends may be dragged, by layer id (K-211) — what the
  /// bars trim within and draw their corner marks from.
  Map<String, BarBounds> _barBounds = {};

  /// The document revision [_barBounds] was worked out at. A precomp's length
  /// and a layer's Retime are both one edit away from changing, so the bounds
  /// are taken again whenever the document moves — and never in between, which
  /// is what keeps a rebuild free of bridge calls (K-184).
  BigInt? _boundsRevision;

  /// Fetch peaks for any layer whose Waveform twirl is open and unanswered.
  void _refreshPeaks(List<BridgeLayerEntry> layers) {
    for (final entry in layers) {
      final id = entry.layer.internallayerId.toString();
      if (!_open.contains(waveformPath(id)) || _peaks.containsKey(id)) {
        continue;
      }
      // Claim the slot first, so a rebuild mid-decode does not decode twice.
      _peaks[id] = BridgeAudioPeaks(durationSeconds: 0, pairs: Float32List(0));
      entry.layer.audioPeaks(buckets: _peakBuckets).then((peaks) {
        if (!mounted) return;
        setState(() => _peaks[id] = peaks);
      });
    }
  }

  /// Work out how far every layer's ends may be dragged (K-211).
  ///
  /// Two costs, kept apart. A **footage** length means opening the file, so it
  /// is asked once per layer, off the build, and kept for the session — the
  /// same bargain [_refreshPeaks] strikes. Everything else is a cheap read that
  /// an edit can change (a precomp lengthened in its comp settings, Retime
  /// switched on), so the whole table is rebuilt when — and only when — the
  /// document revision moves.
  void _refreshBounds(CompModel model, int fpsNum, int fpsDen) {
    final layers = model.layers;
    for (final entry in layers) {
      final id = entry.layer.internallayerId.toString();
      if (entry.info.kind != BridgeLayerKind.footage ||
          _footageFrames.containsKey(id)) {
        continue;
      }
      // Claim the slot first, so a rebuild mid-probe does not probe twice.
      _footageFrames[id] = null;
      final ItemReference? source;
      try {
        source = entry.layer.getSourceItem();
      } catch (_) {
        continue;
      }
      if (source is! ItemReference_Footage) continue;
      source.field0.mediaInfo().then((info) {
        if (!mounted || info == null) return;
        setState(() {
          _footageFrames[id] = frameOfTime(info.duration, fpsNum, fpsDen);
          // The answer changes the bounds, and the document has not moved:
          // forget the revision so the next build works them out again.
          _boundsRevision = null;
        });
      });
    }

    final revision = model.revision;
    if (revision != null && revision == _boundsRevision) return;
    _boundsRevision = revision;
    _barBounds = {
      for (final entry in layers)
        entry.layer.internallayerId.toString():
            _boundsOf(entry, fpsNum, fpsDen),
    };
  }

  /// One layer's bounds, from what its kind can be asked cheaply.
  BarBounds _boundsOf(BridgeLayerEntry entry, int fpsNum, int fpsDen) {
    final info = entry.info;
    // Retime frees both ends (docs/04-RETIMING.md): the Retime property
    // (K-197), and the Source card's speed map, which is the same promise by
    // the older route and is still live in the interface.
    var retimed = info.retime != null;
    int? sourceFrames;
    try {
      switch (info.kind) {
        case BridgeLayerKind.footage:
          retimed = retimed || entry.layer.getRetime() != null;
          sourceFrames = _footageFrames[entry.layer.internallayerId.toString()];
        case BridgeLayerKind.precomp:
          final source = entry.layer.getSourceItem();
          if (source is ItemReference_Composition) {
            sourceFrames = frameOfTime(
                source.field0.getSettings().duration, fpsNum, fpsDen);
          }
        default:
          // Every generated kind: nothing to run out of, both ends free.
          sourceFrames = null;
      }
    } catch (_) {
      // A layer that has gone, or a source that cannot be read: free ends
      // rather than a bar pinned to a guess.
      return BarBounds.free;
    }
    return barBounds(
      startOffsetFrame: frameOfTime(info.span.startOffset, fpsNum, fpsDen),
      sourceFrames: sourceFrames,
      retimed: retimed,
    );
  }

  /// Twirl a fold open or shut. Shutting one drops the selection inside it
  /// (K-203): a selected property that is no longer on screen is a highlight
  /// with nowhere to sit, and it came back as soon as the fold reopened — on a
  /// layer the user had since stopped working on.
  void _toggle(String path) => setState(() {
        if (_open.remove(path)) {
          _dropSelectionUnder(path);
        } else {
          _open.add(path);
        }
      });

  /// Forget any selected property at or below [path], and any keyframes of
  /// theirs the marquee had caught.
  void _dropSelectionUnder(String path) {
    _selectedProperties.removeWhere((p) => p == path || isUnderPath(path, p));
    _laneKeySelection.removeWhere((id) {
      final hash = id.lastIndexOf('#');
      if (hash <= 0) return false;
      final row = id.substring(0, hash);
      return row == path || isUnderPath(path, row);
    });
    _graphKeySelection.clear();
  }

  /// Nothing selected: no layer, no properties, no keyframes (K-203).
  ///
  /// Clicking empty space in either half of the table is how you get here. An
  /// editor with no way *out* of a selection makes every following command
  /// ambiguous — Delete, U and the Retime chord all read the selection first,
  /// and until now the only way to change it was to pick something else.
  void _deselectAll(LumitUiState ui) {
    if (ui.selectedLayer.value == null &&
        _selectedProperties.isEmpty &&
        _laneKeySelection.isEmpty &&
        _graphKeySelection.isEmpty &&
        _highlighted == null) {
      return;
    }
    setState(() {
      // Clears the list as well as the primary — `_syncSelection` only follows
      // the primary the other way (one layer set becomes the whole selection),
      // so dropping it alone would leave the list holding what was let go.
      ui.clearSelection();
      _selectedProperties.clear();
      _laneKeySelection.clear();
      _graphKeySelection.clear();
      _highlighted = null;
    });
  }

  /// Select a layer by click: plain replaces, Ctrl toggles, Shift extends the
  /// range down the stack — the same three rules a property row follows
  /// ([_selectProperty]), because a selection that behaved one way for rows
  /// and another for layers would be two selections to learn.
  ///
  /// The list is the shell's (K-217), so this hands the work to
  /// [LumitUiState.setSelection] and [LumitUiState.toggleSelected] rather than
  /// keeping a second idea of what is selected: the Viewer's boxes, Delete and
  /// the split all read that one list.
  ///
  /// A layer's properties are not selected with it: a click on a layer's name
  /// means "this layer", and leaving a property of the layer before it lit is
  /// the highlight belonging to nothing on screen that K-203 went looking for.
  void _selectLayer(LumitUiState ui, LayerReference? layer,
          {List<BridgeLayerEntry> among = const []}) =>
      setState(() {
        if (ui.selectedLayer.value?.internallayerId != layer?.internallayerId) {
          _selectedProperties.clear();
          _graphKeySelection.clear();
          // The highlight belongs to the property selection just cleared, so
          // it goes with it. Left behind, the previous layer's row stayed lit
          // after a click on a different layer — two layers appearing chosen
          // at once, which is the ambiguity K-203 set out to remove.
          _highlighted = null;
        }
        if (layer == null) {
          ui.clearSelection();
          return;
        }
        final keys = HardwareKeyboard.instance;
        if (keys.isControlPressed || keys.isMetaPressed) {
          ui.toggleSelected(layer);
          return;
        }
        final held = ui.selectedLayer.value;
        if (keys.isShiftPressed && held != null) {
          final a = among.indexWhere(
              (e) => e.layer.internallayerId == held.internallayerId);
          final b = among.indexWhere(
              (e) => e.layer.internallayerId == layer.internallayerId);
          if (a >= 0 && b >= 0) {
            // The clicked layer stays the primary — it is the one just asked
            // for, and everything that acts on one layer acts on that.
            ui.setSelection([
              layer,
              for (var i = a < b ? a : b; i <= (a < b ? b : a); i++)
                if (i != b) among[i].layer,
            ]);
            return;
          }
        }
        ui.setSelection([layer]);
      });

  /// Fill in any layer's has-audio answer we do not have, off the build.
  void _refreshAudio(List<BridgeLayerEntry> layers) {
    for (final entry in layers) {
      final id = entry.layer.internallayerId.toString();
      if (_hasAudio.containsKey(id)) continue;
      // Claim the slot first, so a rebuild mid-probe does not probe twice.
      _hasAudio[id] = false;
      entry.layer.hasAudio().then((has) {
        if (!mounted || _hasAudio[id] == has) return;
        setState(() => _hasAudio[id] = has);
      });
    }
  }

  String _search = '';

  /// The shy filter (docs/07 §4.2): while on, layers whose shy switch is set
  /// disappear from the list — not from the picture; shy never renders.
  bool _hideShy = false;

  /// The outline's column groups in their current order. Dragging a header
  /// group reorders them as a unit; session-lived, like the twirl state.
  List<TimelineGroup> _groupOrder = [...defaultGroupOrder];

  /// Each group's width. Dragging a header seam changes one of these and
  /// leaves the rest alone, so the outline grows by what the drag moved.
  Map<TimelineGroup, double> _groupWidths = {...defaultGroupWidths};

  /// Widen (or narrow) one group, never below what its cells need.
  void _resizeGroup(TimelineGroup group, double delta) => setState(() {
        final next = ((_groupWidths[group] ?? 0) + delta)
            .clamp(minGroupWidth(group), 900.0);
        _groupWidths = {..._groupWidths, group: next};
      });

  /// The layer whose fold-out was last touched — drawn a shade dimmer than
  /// the selected layer, so "which layer do these rows belong to" has an
  /// answer at a glance without stealing the selection.
  String? _highlighted;

  /// The selected properties, as fold paths (`<layer>/effects/<fx>/<param>`),
  /// in selection order — clicking a property's name selects it, Ctrl+click
  /// toggles it, Shift+click extends the range, across layers (docs/07 §4.3,
  /// §5). Each is a coloured curve in the graph editor.
  final List<String> _selectedProperties = [];

  /// The graph editor's selected keyframes, as `channelId#index` — owned here
  /// so the bottom bar's buttons and the shortcuts act on the same set.
  final Set<String> _graphKeySelection = {};

  /// Which reading of the curves the graph shows (docs/07 §5.1).
  GraphLens _graphLens = GraphLens.value;

  /// Auto-fit: the graph frames its curves vertically by itself; toggled off,
  /// the wheel pans and `Alt`+wheel zooms the value axis (docs/07 §5.3).
  bool _graphAutoFit = true;

  final GlobalKey<GraphEditorFrbState> _graphPane = GlobalKey();

  /// The property rows currently on screen, in display order — what a
  /// Shift+click range runs along. Rebuilt by every build.
  List<String> _visiblePropertyPaths = const [];

  /// Select [path] by click: plain replaces, Ctrl toggles, Shift extends from
  /// the last selected along the visible rows. Marks its layer either way.
  void _selectProperty(String path) => setState(() {
        final keys = HardwareKeyboard.instance;
        if (keys.isControlPressed || keys.isMetaPressed) {
          if (!_selectedProperties.remove(path)) _selectedProperties.add(path);
        } else if (keys.isShiftPressed && _selectedProperties.isNotEmpty) {
          final a = _visiblePropertyPaths.indexOf(_selectedProperties.last);
          final b = _visiblePropertyPaths.indexOf(path);
          if (a < 0 || b < 0) {
            if (!_selectedProperties.contains(path)) {
              _selectedProperties.add(path);
            }
          } else {
            for (var i = a < b ? a : b; i <= (a < b ? b : a); i++) {
              if (!_selectedProperties.contains(_visiblePropertyPaths[i])) {
                _selectedProperties.add(_visiblePropertyPaths[i]);
              }
            }
          }
        } else {
          _selectedProperties
            ..clear()
            ..add(path);
        }
        _graphKeySelection.clear();
        final cut = path.indexOf('/');
        if (cut > 0) _highlighted = path.substring(0, cut);
      });

  /// Editing a value or keying a property selects it too (docs/07 §4.3) —
  /// quietly: an already-selected property stays where it is in the order.
  void _selectOnEdit(String path) {
    if (_selectedProperties.contains(path)) return;
    setState(() {
      _selectedProperties
        ..clear()
        ..add(path);
      _graphKeySelection.clear();
      final cut = path.indexOf('/');
      if (cut > 0) _highlighted = path.substring(0, cut);
    });
  }

  /// The graph editor replaces the layer area rather than sitting beside it:
  /// the two want the same width, and a curve squeezed into half a panel is not
  /// a curve you can shape.
  bool _graph = false;

  /// Whether the razor is armed — which is now the *toolbar's* answer (K-220):
  /// the Razor tool (`C`) and this panel's own menu item are two doors into one
  /// state, because two razors that could disagree is one razor too many. The
  /// menu item arms and disarms the tool.
  bool _razorArmed(LumitUiState ui) => ui.tools.tool.group == ToolGroup.razor;

  void _toggleRazor(LumitUiState ui) => _razorArmed(ui)
      ? ui.tools.select(ToolMode.select)
      : ui.tools.select(ToolMode.razor);

  /// The toolbar's state, subscribed to once.
  ///
  /// The armed tool lives on its own notifier beside the rest of the shell's UI
  /// state, so watching `LumitUiState` does not hear about it: without this the
  /// lanes kept whatever the razor was when the panel last drew, and arming it
  /// from the toolbar — or from this panel's own menu — changed nothing until
  /// something else happened to rebuild.
  ToolsState? _boundTools;

  void _onToolChanged() {
    if (mounted) setState(() {});
  }

  void _bindTools(LumitUiState ui) {
    if (identical(_boundTools, ui.tools)) return;
    _boundTools?.removeListener(_onToolChanged);
    _boundTools = ui.tools..addListener(_onToolChanged);
  }

  /// Cut at [frame]: the layer that was clicked, or — with Shift — every layer
  /// that spans that moment (docs/07 §4.4).
  void _razorCutAt(
    LumitUiState ui,
    BridgeLayerEntry? clicked,
    int frame,
    VoidCallback onChanged,
  ) {
    final targets = razorTargets(
      ui.model.layers,
      frame,
      clicked: clicked,
      allLayers: HardwareKeyboard.instance.isShiftPressed,
    );
    if (razorCut(targets, frame)) onChanged();
  }

  /// `Ctrl+Shift+D`: cut every selected layer at the playhead (docs/07 §4.4).
  ///
  /// A command, not a tool — it does not care which tool is armed, and it cuts
  /// where the playhead is rather than where the pointer is. The rules are the
  /// razor's, and they are read from the razor rather than written a second
  /// time: [razorTargets] says what a cut at that frame can land on (strictly
  /// inside the layer), [razorCut] makes it, and a cut the engine refuses is
  /// silence.
  bool _splitSelectionAtPlayhead(LumitUiState ui) {
    final frame = ui.playheadFrame.value;
    final selected = ui.selectedLayerIds;
    final targets = [
      for (final entry
          in razorTargets(ui.model.layers, frame,
              clicked: null, allLayers: true))
        if (selected.contains(entry.layer.internallayerId)) entry,
    ];
    if (targets.isEmpty) return false;
    if (razorCut(targets, frame)) ui.model.refresh();
    return true;
  }

  /// `Ctrl+Shift+C`: pack the selection into a comp of its own (docs/07 §4.4).
  ///
  /// The whole move is the engine's — one batch, one undo step — so all this
  /// does is hand it the selection and put the layer it gets back in the
  /// selection's place, because the Precomp layer is what the user is now
  /// working on.
  bool _precomposeSelection(LumitUiState ui) {
    final comp = ui.selectedComp;
    final layers = ui.selectedLayers.value;
    if (comp == null || layers.isEmpty) return false;
    ui.setSelection([comp.precompose(layers: layers)]);
    ui.model.refresh();
    return true;
  }

  /// `[` and `]`: move the selected layers so that end lands on the playhead;
  /// with `Alt`, trim that end to it instead (docs/07 §4.4).
  ///
  /// A move carries the layer's content with it and a trim does not, and
  /// neither may run past the source or turn a bar inside out. Those are the
  /// bar drag's rules, so they are read from the bar drag's own clamp rather
  /// than written a second time here — a key and a drag that disagreed about
  /// where a layer may end would be two different edits wearing one name.
  bool _moveOrTrimSelection(LumitUiState ui, String action) {
    final comp = ui.selectedComp;
    final selected = ui.selectedLayerIds;
    if (comp == null || selected.isEmpty) return false;

    final grab = switch (action) {
      'layer.trim.in' => BarGrab.trimIn,
      'layer.trim.out' => BarGrab.trimOut,
      _ => BarGrab.move,
    };
    final atIn = action == 'layer.move.in' || action == 'layer.trim.in';
    final frame = ui.playheadFrame.value;
    final (fpsNum, fpsDen) = ui.model.fpsExact;

    var changed = false;
    for (final entry in ui.model.layers) {
      if (!selected.contains(entry.layer.internallayerId)) continue;
      final span = entry.info.span;
      final inFrame = frameOfTime(span.inPoint, fpsNum, fpsDen);
      final outFrame = frameOfTime(span.outPoint, fpsNum, fpsDen);
      final delta = clampBarDelta(
        grab: grab,
        delta: frame - (atIn ? inFrame : outFrame),
        inFrame: inFrame,
        outFrame: outFrame,
        bounds: _barBounds[entry.layer.internallayerId.toString()] ??
            BarBounds.free,
      );
      if (delta == 0) continue;
      final newIn = inFrame + (grab == BarGrab.trimOut ? 0 : delta);
      final newOut = outFrame + (grab == BarGrab.trimIn ? 0 : delta);
      if (newOut <= newIn) continue;
      entry.layer.setSpan(
        span: BridgeSpan(
          inPoint: comp.timeOfFrame(frame: newIn),
          outPoint: comp.timeOfFrame(frame: newOut),
          // Moving carries the content with the bar, so time zero travels too.
          startOffset: grab == BarGrab.move
              ? comp.timeOfFrame(
                  frame: frameOfTime(span.startOffset, fpsNum, fpsDen) + delta)
              : span.startOffset,
        ),
      );
      changed = true;
    }
    if (changed) ui.model.refresh();
    return changed;
  }

  /// One reveal key: the selected layers open showing exactly what the key
  /// names, and pressing it again shuts them (docs/07 §4.3).
  ///
  /// AE's `P`, `S`, `R`, `T`, `A`, `E`, `M` and `Shift+L`. `U` is not one of
  /// these — it asks the engine what qualifies and has its own cycle
  /// ([_revealTap]); these know their row up front. `R` on a 3D layer reveals
  /// all three rotation rows, because the engine lists them as three groups.
  bool _reveal(LumitUiState ui, String action) {
    final selected = ui.selectedLayerIds;
    if (selected.isEmpty) return false;
    setState(() {
      for (final entry in ui.model.layers) {
        if (!selected.contains(entry.layer.internallayerId)) continue;
        final id = entry.layer.internallayerId.toString();
        final wanted = _revealPaths(id, entry, action);
        // Already showing this and nothing else: the key is a toggle, so the
        // second press shuts the layer rather than reopening what is open.
        final showing = _open.contains(id) &&
            wanted.every(_open.contains) &&
            !_open.any((p) => isUnderPath(id, p) && !wanted.contains(p));
        // Every reveal starts from the layer closed, so it shows what it says
        // rather than adding to whatever the last one left open.
        _open.removeWhere((p) => p == id || isUnderPath(id, p));
        _dropSelectionUnder(id);
        if (showing) continue;
        _open
          ..add(id)
          ..addAll(wanted);
      }
    });
    return true;
  }

  /// Which fold paths a reveal key opens under [id]. Empty means the layer's
  /// own row and nothing beneath it — what the Retime chord leaves behind, and
  /// what `E` or `M` come to on a layer with no effects or masks to show.
  List<String> _revealPaths(String id, BridgeLayerEntry entry, String action) {
    final axis = switch (action) {
      'reveal.position' => 'position',
      'reveal.scale' => 'scale',
      'reveal.rotation' => 'rotation',
      'reveal.opacity' => 'opacity',
      'reveal.anchor' => 'anchor',
      _ => null,
    };
    if (axis != null) {
      return [
        for (final group in transformGroups(threeD: entry.info.switches.threeD))
          if (group.axes.first.prop.name.startsWith(axis))
            transformGroupPath(id, group),
      ];
    }
    return switch (action) {
      'reveal.effects' =>
        entry.info.effects.isEmpty ? const [] : [effectsPath(id)],
      'reveal.masks' => entry.info.masks.isEmpty ? const [] : [masksPath(id)],
      'reveal.volume' => [audioPath(id)],
      _ => const [],
    };
  }

  /// The bar drag in flight, if any — a notifier rather than panel state so
  /// only the waveform lanes redraw as the pointer moves, not the whole table.
  final ValueNotifier<BarDragPreview?> _barDrag = ValueNotifier(null);

  /// The lane view's selected keyframes, as `rowId#index` (docs/07 §4.3) —
  /// what the marquee gathered. Session state, like the twirl set.
  final Set<String> _laneKeySelection = {};

  /// The layer drag in flight (K-208), read by both halves of the table. A
  /// notifier rather than panel state: a drag slides rows, and rebuilding the
  /// whole panel per pointer move to do it would cost the table its bridge
  /// budget (docs/13).
  final ValueNotifier<LayerDrag?> _layerDrag = ValueNotifier(null);

  /// The outline's and the lanes' vertical scrolls, linked both ways so the
  /// two halves of the table stay one table; the lanes' side owns the visible
  /// scrollbar. In graph view the outline scrolls alone.
  final ScrollController _vOutline = ScrollController();
  final ScrollController _vLane = ScrollController();

  /// The lanes' horizontal scroll, once zoomed past fit.
  final ScrollController _hLane = ScrollController();

  /// Time zoom: 1 is fit-to-panel; the bottom bar's − / + / Fit set it, and
  /// Ctrl+wheel zooms about the pointer.
  double _zoom = 1;

  /// Whether a dragged keyframe sticks to whole frames (docs/07 §4.5). On by
  /// default: landing between frames is the deliberate exception.
  bool _magnet = true;

  bool _syncingScroll = false;

  @override
  void initState() {
    super.initState();
    _vOutline.addListener(() => _followScroll(_vOutline, _vLane));
    _vLane.addListener(() => _followScroll(_vLane, _vOutline));
    HardwareKeyboard.instance.addHandler(_onKey);
    // Claim Delete for the finer selection this panel holds (K-234). The state
    // is kept, not looked up again: `dispose` runs after the element is
    // deactivated, where an ancestor lookup is no longer safe.
    _ui = Provider.of<LumitUiState>(context, listen: false);
    _ui!.deleteClaim = _deleteSelectedMasks;
  }

  /// The shell state this panel claimed Delete on, so the claim can be dropped
  /// again when the panel goes.
  LumitUiState? _ui;

  /// The graph editor's channels right now, resolved from the read model.
  List<GraphChannel> _channelsNow() {
    final ui = Provider.of<LumitUiState>(context, listen: false);
    return graphChannels(
        layers: ui.model.layers, selected: _selectedProperties);
  }

  /// The key selection the current view acts on: the graph's own, or the lane
  /// marquee's translated onto channels (a lane diamond stands for every axis
  /// of its row, so `row#i` fans out to each channel of that path).
  Set<String> _actionKeySelection(List<GraphChannel> channels) {
    if (_graph) return _graphKeySelection;
    final out = <String>{};
    for (final id in _laneKeySelection) {
      final hash = id.lastIndexOf('#');
      if (hash <= 0) continue;
      final path = id.substring(0, hash);
      final index = id.substring(hash + 1);
      for (final channel in channels) {
        if (channel.path == path) out.add('${channel.id}#$index');
      }
    }
    return out;
  }

  /// Set the selected keys' easing (the F9 family and the bottom bar's
  /// Linear / Bezier / Hold): both sides, or one for ease-in/ease-out.
  void _applyInterp(BridgeSideInterp side,
      {bool inSide = true, bool outSide = true}) {
    // In lane view the selection speaks in row paths, so the channels have to
    // cover those too, not only the selected properties.
    final ui = Provider.of<LumitUiState>(context, listen: false);
    final paths = _graph
        ? _selectedProperties
        : {
            for (final id in _laneKeySelection)
              if (id.lastIndexOf('#') > 0) id.substring(0, id.lastIndexOf('#'))
          }.toList();
    final channels = graphChannels(layers: ui.model.layers, selected: paths);
    final selection = _actionKeySelection(channels);
    if (selection.isEmpty) return;
    applyInterpToSelection(
      channels: channels,
      selectedKeys: selection,
      side: side,
      inSide: inSide,
      outSide: outSide,
    );
    ui.model.refresh();
  }

  /// The Timeline's keyboard commands: `Shift+F3` toggles the graph, the F9
  /// family sets easing, `Ctrl+Shift+D` cuts the selection at the playhead,
  /// `F` re-frames the graph, `Ctrl+C`/`Ctrl+V` copy and
  /// paste keyframes, Delete removes the graph's selected keys. Registered on
  /// the hardware keyboard (panels do not hold focus); a focused text field
  /// keeps its keys.
  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent || !mounted) return false;
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused != null &&
        (focused.widget is EditableText ||
            focused.findAncestorWidgetOfExactType<EditableText>() != null)) {
      return false;
    }
    final keyboard = HardwareKeyboard.instance;
    final ctrl = keyboard.isControlPressed || keyboard.isMetaPressed;
    final key = event.logicalKey;

    // What this chord means in the Timeline — or in the graph editor while it
    // is open, which has bindings of its own (K-199). The engine answers;
    // nothing here compares keys except the copy/paste pair below, which §15
    // does not name and so has no action to look up.
    final ui = Provider.of<LumitUiState>(context, listen: false);
    // This panel is one surface with two views, so a chord bound in either
    // context works in both — the view's own context first, the other as the
    // fallback. It used to fall back one way only (graph → timeline), which is
    // why the F9 family did nothing in lane view: easing is bound in the graph
    // context (docs/07 §15) while keyframes are selectable in both, so F9 over
    // the lanes looked up no action at all.
    final action = ui.keymap.actionFor(
          _graph ? BridgeKeyContext.graph : BridgeKeyContext.timeline,
          event,
        ) ??
        ui.keymap.actionFor(
          _graph ? BridgeKeyContext.timeline : BridgeKeyContext.graph,
          event,
        );

    if (action == 'graph.toggle') {
      setState(() => _graph = !_graph);
      return true;
    }
    if (action == 'reveal.animated') {
      return _revealTap();
    }
    if (action == 'layer.split') {
      return _splitSelectionAtPlayhead(ui);
    }
    if (action == 'layer.precompose') {
      return _precomposeSelection(ui);
    }
    if (action == 'layer.move.in' ||
        action == 'layer.move.out' ||
        action == 'layer.trim.in' ||
        action == 'layer.trim.out') {
      return _moveOrTrimSelection(ui, action!);
    }
    // The single-property reveals (docs/07 §4.3). `layer.retime.enable` is the
    // shell's command, not this panel's — it lands here only to *show* the row
    // the shell has just switched on, which is view state and so ours.
    if (action != null &&
        (action.startsWith('reveal.') || action == 'layer.retime.enable')) {
      return _reveal(ui, action);
    }
    if (action == 'graph.ease' ||
        action == 'graph.ease.in' ||
        action == 'graph.ease.out') {
      // Both sides, the way in, or the way out (docs/07 §5.3).
      _applyInterp(
        easyEase,
        inSide: action != 'graph.ease.out',
        outSide: action != 'graph.ease.in',
      );
      return true;
    }
    // Copy and paste work wherever keyframes are selected — the lane view's
    // marquee catch as much as the graph's (K-196).
    if (ctrl && key == LogicalKeyboardKey.keyC) {
      final ui = Provider.of<LumitUiState>(context, listen: false);
      final comp = ui.selectedComp;
      if (comp == null) return false;
      final channels = _channelsNow();
      final selection = _actionKeySelection(channels);
      if (selection.isEmpty) return false;
      copySelectedKeys(
        comp: comp,
        channels: channels,
        selectedKeys: selection,
        fps: ui.model.fps,
      );
      return true;
    }
    if (ctrl && key == LogicalKeyboardKey.keyV) {
      final ui = Provider.of<LumitUiState>(context, listen: false);
      final channels = _channelsNow();
      if (channels.isEmpty) return false;
      final (fpsNum, fpsDen) = ui.model.fpsExact;
      pasteKeysAtPlayhead(
        channels: channels,
        playheadFrame: ui.playheadFrame.value,
        fps: ui.model.fps,
        fpsNum: fpsNum,
        fpsDen: fpsDen,
      ).then((pasted) {
        if (pasted && mounted) ui.model.refresh();
      });
      return true;
    }

    // Delete with a mask row selected is not handled here: every one of these
    // handlers runs, in registration order, so a `true` from this one would not
    // stop the shell's Delete removing the layer as well. The Timeline claims
    // the key through [LumitUiState.deleteClaim] instead, which the shell asks
    // *before* it deletes anything (K-234).

    if (!_graph) return false;

    if (action == 'graph.fit') {
      _graphPane.currentState?.fitNow();
      return true;
    }
    if (action == 'edit.delete.selection' && _graphKeySelection.isNotEmpty) {
      _graphPane.currentState?.deleteSelectedKeys();
      return true;
    }
    return false;
  }

  /// Delete every selected mask row, returning whether there was one (K-234).
  ///
  /// The shell's Delete calls this before it deletes the selected layers, so a
  /// picked mask row is what the key acts on — the mask sits *on* the selected
  /// layer, and deleting the layer instead is the opposite of what was asked.
  ///
  /// The same call the row's own context menu makes, so there is one way a mask
  /// is deleted. One op per mask, as deleting several layers is one op each.
  bool _deleteSelectedMasks() {
    if (!mounted) return false;
    final ui = Provider.of<LumitUiState>(context, listen: false);
    // Mask paths are `<layer>/masks/<mask>`, so the layer and the mask are both
    // read straight off the selection — no lookup table to keep in step.
    final wanted = <String, Set<String>>{};
    for (final path in _selectedProperties) {
      final cut = path.indexOf('/');
      if (cut <= 0) continue;
      final layerId = path.substring(0, cut);
      if (!isUnderPath(masksPath(layerId), path)) continue;
      (wanted[layerId] ??= {})
          .add(path.substring(masksPath(layerId).length + 1));
    }
    if (wanted.isEmpty) return false;

    var deleted = false;
    for (final entry in ui.model.layers) {
      final ids = wanted[entry.layer.internallayerId.toString()];
      if (ids == null) continue;
      for (final mask in entry.info.masks) {
        if (!ids.contains(mask.id.toString())) continue;
        try {
          entry.layer.deleteMask(id: mask.id);
          deleted = true;
        } catch (_) {
          // Gone between the draw and the press; nothing left to delete.
        }
      }
    }
    if (!deleted) return false;
    // The rows are gone, so the highlight that pointed at them goes too.
    setState(() => _selectedProperties.removeWhere((path) {
          final cut = path.indexOf('/');
          return cut > 0 &&
              isUnderPath(masksPath(path.substring(0, cut)), path);
        }));
    ui.model.refresh();
    return true;
  }

  /// When the last `U` was pressed, and how many times in a row — the AE reveal
  /// cycle (docs/07 §4.3). Three taps inside the window are three different
  /// commands, so the count is what tells them apart.
  DateTime? _lastReveal;
  int _revealTaps = 0;

  /// How long a second `U` still counts as the same gesture. AE's own window;
  /// long enough to type deliberately, short enough that a `U` a moment later
  /// starts again rather than collapsing what you just opened.
  static const Duration _revealWindow = Duration(milliseconds: 500);

  /// One press of the reveal key: `U` opens what is animated, `UU` what has
  /// been modified, `UUU` shuts the layer again.
  ///
  /// The *counting* is ours, because a multi-tap is a gesture like a
  /// double-click and gestures are the frontend's. Which groups qualify is the
  /// engine's, and it is asked afresh on each tap — the answer depends on the
  /// document, and the document may have changed between taps.
  bool _revealTap() {
    final ui = Provider.of<LumitUiState>(context, listen: false);
    // With nothing selected the reveal is the whole composition's (K-203):
    // "show me what is animated" is a question about the comp as often as
    // about one layer, and refusing to answer it unless something was selected
    // made the commonest use of the key the one it did not serve.
    final selected = ui.selectedLayer.value;
    final layers = selected != null
        ? [selected]
        : [for (final entry in ui.model.layers) entry.layer];
    if (layers.isEmpty) return false;

    final now = DateTime.now();
    final last = _lastReveal;
    _revealTaps = (last != null && now.difference(last) <= _revealWindow)
        ? _revealTaps + 1
        : 1;
    _lastReveal = now;

    setState(() {
      // Every tap starts from the layers closed, so a reveal shows exactly
      // what it says rather than adding to whatever was already open.
      for (final layer in layers) {
        final id = layer.internallayerId.toString();
        _open.removeWhere((path) => path == id || isUnderPath(id, path));
        _dropSelectionUnder(id);
      }
      if (_revealTaps >= 3) {
        // UUU: shut, and the next U starts the cycle over.
        _revealTaps = 0;
        _lastReveal = null;
        return;
      }
      for (final layer in layers) {
        final id = layer.internallayerId.toString();
        final groups = layer.revealGroups(
          kind: _revealTaps == 1
              ? BridgeRevealKind.animated
              : BridgeRevealKind.modified,
        );
        // Nothing qualifies: leave the layer shut rather than opening it onto
        // a list of headings the reveal just said were empty.
        if (!groups.any) continue;
        _open.add(id);
        if (groups.transform) _open.add(transformPath(id));
        if (groups.effects.isNotEmpty) {
          _open.add(effectsPath(id));
          for (final fx in groups.effects) {
            _open.add(effectPath(id, fx));
          }
        }
        if (groups.audio) _open.add(audioPath(id));
        // Retime needs no path of its own: the row sits above Transform on
        // any open layer that has one, and `groups.any` already counts it, so
        // a layer whose only animation is its Retime opens for `U` here.
      }
    });
    return true;
  }

  /// Mirror one side's scroll onto the other, guarded against the echo.
  void _followScroll(ScrollController from, ScrollController to) {
    if (_syncingScroll || !from.hasClients || !to.hasClients) return;
    if ((to.offset - from.offset).abs() < 0.5) return;
    _syncingScroll = true;
    to.jumpTo(from.offset.clamp(0.0, to.position.maxScrollExtent));
    _syncingScroll = false;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    if (_ui?.deleteClaim == _deleteSelectedMasks) _ui!.deleteClaim = null;
    _boundTools?.removeListener(_onToolChanged);
    _barDrag.dispose();
    _layerDrag.dispose();
    _vOutline.dispose();
    _vLane.dispose();
    _hLane.dispose();
    super.dispose();
  }

  /// A modified wheel over the lanes (docs/07 §4.6). Ctrl zooms time about the
  /// pointer — the frame under the cursor stays under it — and Shift scrolls
  /// sideways. A plain wheel is not touched here, so it still reaches the
  /// scrollable and moves the rows.
  void _wheel(PointerScrollEvent event, double contentX, double perFrame) {
    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed) {
      final next = (event.scrollDelta.dy < 0 ? _zoom * 1.2 : _zoom / 1.2)
          .clamp(1.0, 64.0);
      if (next == _zoom) return;
      // Where the pointer sits in the viewport, and which frame is under it.
      final viewportX = contentX - (_hLane.hasClients ? _hLane.offset : 0);
      final frame = perFrame <= 0 ? 0.0 : contentX / perFrame;
      final grew = next / _zoom;
      setState(() => _zoom = next);
      // Jumped in the SAME turn as the zoom, not from a post-frame callback:
      // deferring it painted one whole frame at the new width with the old
      // offset, which is the sideways slide a zoom visibly made before it
      // settled. `jumpTo` does not clamp — the viewport clamps at layout, and
      // layout this frame already has the wider content — so the only bound
      // needed here is the lower one.
      if (_hLane.hasClients) {
        _hLane.jumpTo(max(0.0, frame * perFrame * grew - viewportX));
      }
      return;
    }
    if (keys.isShiftPressed && _hLane.hasClients) {
      _hLane.jumpTo((_hLane.offset + event.scrollDelta.dy)
          .clamp(0.0, _hLane.position.maxScrollExtent));
    }
  }

  /// The gutter down the right of a scrollable half: a block level with that
  /// half's header (After Effects keeps the same reserved corner), then the
  /// scrollbar itself. Reserved whether or not a thumb shows, so the columns
  /// do not shift when the view changes.
  Widget _scrollGutter(
    LumitTheme t, {
    required ScrollController controller,
    required List<Widget> header,
    required bool showThumb,
  }) =>
      SizedBox(
        width: scrollGutterWidth,
        child: Column(
          children: [
            ...header,
            Expanded(
              child: showThumb
                  ? _GutterScrollbar(controller: controller)
                  : const SizedBox.expand(),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final ui = Provider.of<LumitUiState>(context);
    _bindTools(ui);
    final comp = ui.selectedComp;
    if (comp == null) {
      // Footage dropped with nothing open offers to make the composition it
      // would go in — the same gesture the Project panel's New composition
      // button takes, so "drag a clip in and start" works from either side
      // rather than dead-ending on a placeholder.
      return _EmptyTimelineDrop(state: Provider.of<LumitState>(context));
    }

    // Everything this panel draws comes from the read model (K-184): zero
    // bridge calls per rebuild. The ListenableBuilder repaints the panel when
    // the model refreshes — which happens once per committed change.
    return ListenableBuilder(
      listenable: ui.model,
      builder: (context, _) => _body(context, ui, comp),
    );
  }

  Widget _body(
      BuildContext context, LumitUiState ui, CompositionReference comp) {
    final t = ThemeScope.of(context).theme;
    final frames = ui.model.durationFrames;
    final (fpsNum, fpsDen) = ui.model.fpsExact;
    final needle = _search.trim().toLowerCase();
    final layers = [
      for (final e in ui.model.layers)
        if ((needle.isEmpty || e.info.name.toLowerCase().contains(needle)) &&
            !(_hideShy && e.info.switches.shy))
          e,
    ];
    _refreshAudio(layers);
    _refreshPeaks(layers);
    // Every layer, not the filtered list: a bar hidden by the search box still
    // has ends, and they must be known the moment it comes back.
    _refreshBounds(ui.model, fpsNum, fpsDen);

    // The property rows on screen, in display order — what a Shift+click
    // range runs along — and the graph channels the selection resolves to,
    // each with its stroke colour for the outline's labels to match.
    _visiblePropertyPaths = [
      for (final e in layers)
        if (_open.contains(e.layer.internallayerId.toString()))
          for (final row in layerFoldRows(
            entry: e,
            open: _open,
            hasAudio: _hasAudio[e.layer.internallayerId.toString()] ?? false,
          ))
            if (row is! FoldGroupRow && row is! FoldWaveformRow)
              foldRowPath(e.layer.internallayerId.toString(), row),
    ];
    final channels =
        graphChannels(layers: ui.model.layers, selected: _selectedProperties);
    // The work area, in frames, read once for the whole panel (K-203): the
    // ruler draws it, the lanes and the curves are washed by it, and the two
    // are one span.
    final work = workAreaFrames(comp);
    // One walk of the row stack for the whole panel: both halves slide their
    // blocks by these heights during a drag, so neither can measure the table
    // differently from the other (K-208).
    final blockHeights = layerBlockHeights(
        layers: layers, open: _open, hasAudio: _hasAudio);
    final graphColours = <String, List<Color>>{};
    for (final channel in channels) {
      (graphColours[channel.path] ??= [])
          .add(t.curve[channel.colourIndex % t.curve.length]);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CompTabsFrb(
          state: Provider.of<LumitState>(context, listen: false),
          uiState: ui,
        ),
        Expanded(
          // Dropping footage from the Project panel adds it as a layer, and
          // dropping a composition nests it as a Precomp layer. The target
          // wraps the whole body — outline and layer area both — because
          // "onto the Timeline" is what the gesture means; asking the user to
          // hit one half of it would be a rule with no reason behind it.
          // `Object` with a filter, because a DragTarget accepts exactly one
          // payload type and this drop honestly takes two.
          child: DragTarget<Object>(
            onWillAcceptWithDetails: (details) =>
                details.data is FootageDragData || details.data is CompDragData,
            onAcceptWithDetails: (details) {
              switch (details.data) {
                case FootageDragData(:final footage):
                  // Bottom-up, so a multi-item drop stacks in the order the
                  // panel listed them: each lands at the top of the stack.
                  for (final f in footage.reversed) {
                    comp.addFootageLayer(footage: f);
                  }
                case CompDragData(comp: final dropped):
                  // A comp cannot nest into itself; the engine refuses and
                  // the drop simply does nothing.
                  try {
                    comp.addPrecompLayer(comp: dropped);
                  } catch (_) {}
              }
              ui.model.refresh();
            },
            builder: (context, candidate, _) => Container(
              // A live outline while something is over it, so the drop is
              // visibly going to land rather than being taken on faith.
              foregroundDecoration: candidate.isEmpty
                  ? null
                  : BoxDecoration(
                      border: Border.all(
                          color: ThemeScope.of(context).theme.accent, width: 2),
                    ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // A panel narrower than the outline's columns shows a
                  // horizontally-scrolling slice of them rather than the
                  // overflow stripe — the same answer the Timeline toolbar
                  // gives — keeping the lanes at least a working sliver.
                  // The outline is as wide as its groups make it, and counts
                  // its own scroll gutter so the columns keep their places
                  // when the view changes.
                  final outlineWidth = outlineWidthOf(_groupWidths);
                  final outlineViewport = (constraints.maxWidth - 120)
                      .clamp(120.0, outlineWidth + scrollGutterWidth);
                  // The axis spans the lane viewport times the zoom: at 1 the
                  // whole comp fits the panel (the Viewer's fit-to-panel
                  // habit); zoomed in, the lanes scroll under the bottom
                  // bar's scrollbar.
                  final laneViewport = (constraints.maxWidth -
                          outlineViewport -
                          scrollGutterWidth)
                      .clamp(1.0, 1e6);
                  final axis =
                      TimelineAxis(frames: frames, width: laneViewport * _zoom);

                  // Where the work area falls, read once and handed to the
                  // ruler, the lanes and the curves alike (K-203) — and null
                  // pixels when it covers the whole comp, which is when there
                  // is no out-of-range ground to wash.
                  final graphWork = work.whole
                      ? null
                      : (axis.xOf(work.start), axis.xOf(work.end));

                  // **Not** wrapped in a playhead listener. Every layer row and
                  // every bar used to rebuild each time the playhead moved —
                  // sixty times a second during playback, growing with the layer
                  // count, and asking the engine for each layer's name and span
                  // again every time. Only two things actually care where the
                  // playhead is: the line itself, and the razor (which reads it
                  // when clicked). Both listen for themselves now.
                  //
                  // Dragging never scrolls the timeline — the wheel and the
                  // scrollbars do (docs/07 §4.6). A drag on empty lane space
                  // is the keyframe marquee, and a scrollable competing for
                  // it in the gesture arena would win and eat the box.
                  return ScrollConfiguration(
                    behavior: ScrollConfiguration.of(context)
                        .copyWith(dragDevices: const {}, scrollbars: false),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: outlineViewport,
                          child: Stack(
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(
                                    child: SingleChildScrollView(
                                      scrollDirection: Axis.horizontal,
                                      child: SizedBox(
                                        width: outlineWidth,
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: [
                                            // The toolbar and the column header live in
                                            // the outline, not across the panel: the lane
                                            // side gives their height to a taller, easier
                                            // to grab time ruler (docs/07 §4.1).
                                            _Toolbar(
                                              comp: comp,
                                              model: ui.model,
                                              playhead: ui.playheadFrame,
                                              graph: _graph,
                                              onToggleGraph: () => setState(
                                                  () => _graph = !_graph),
                                              razor: _razorArmed(ui),
                                              onToggleRazor: () =>
                                                  _toggleRazor(ui),
                                              hideShy: _hideShy,
                                              onToggleHideShy: () => setState(
                                                  () => _hideShy = !_hideShy),
                                              onSearch: (v) =>
                                                  setState(() => _search = v),
                                              onChanged: ui.model.refresh,
                                            ),
                                            _ColumnHeader(
                                              order: _groupOrder,
                                              widths: _groupWidths,
                                              onResize: _resizeGroup,
                                              onReorder: (dragged, target) =>
                                                  setState(
                                                () => _groupOrder =
                                                    reorderedGroups(_groupOrder,
                                                        dragged, target),
                                              ),
                                            ),
                                            // The rows scroll under the pinned toolbar
                                            // and header, in step with the lanes.
                                            Expanded(
                                              // A click that misses every row
                                              // deselects (K-203). Translucent
                                              // and outermost, so a name, a
                                              // switch or a property still
                                              // wins its own tap in the arena
                                              // and only the empty ground
                                              // below the last layer reaches
                                              // here.
                                              child: GestureDetector(
                                                key: const ValueKey(
                                                    'tl-outline-ground'),
                                                behavior:
                                                    HitTestBehavior.translucent,
                                                onTap: () => _deselectAll(ui),
                                                child: SingleChildScrollView(
                                                  controller: _vOutline,
                                                  child: _Outline(
                                                    comp: comp,
                                                    layers: layers,
                                                    layerDrag: _layerDrag,
                                                    blockHeights: blockHeights,
                                                    groupOrder: _groupOrder,
                                                    widths: _groupWidths,
                                                    selectedIds:
                                                        ui.selectedLayerIds,
                                                    highlighted: _highlighted,
                                                    selectedProperties:
                                                        _selectedProperties,
                                                    graphColours: graphColours,
                                                    onSelectProperty:
                                                        _selectProperty,
                                                    onEditProperty:
                                                        _selectOnEdit,
                                                    open: _open,
                                                    hasAudio: _hasAudio,
                                                    onToggle: _toggle,
                                                    playheadFrame:
                                                        ui.playheadFrame.value,
                                                    onSeek: (f) => ui
                                                        .playheadFrame
                                                        .value = f,
                                                    onSelect: (l) =>
                                                        _selectLayer(ui, l,
                                                            among: layers),
                                                    onHighlight: (id) =>
                                                        setState(() =>
                                                            _highlighted = id),
                                                    onChanged: ui.model.refresh,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                  // The outline's own gutter: a fixed block level
                                  // with the toolbar and column header, then its
                                  // thumb — which only shows in graph view, where
                                  // the two halves scroll apart.
                                  _scrollGutter(
                                    t,
                                    controller: _vOutline,
                                    showThumb: _graph,
                                    header: [
                                      Container(
                                          height: _toolbarHeight,
                                          color: t.surface1),
                                      Container(
                                          height: _headerHeight,
                                          color: t.surface2),
                                    ],
                                  ),
                                ],
                              ),
                              // The row seams, over the columns *and* the
                              // gutter so they meet the lane area's (K-192);
                              // phased by the scroll so they travel with the
                              // rows they separate.
                              Positioned(
                                top: _toolbarHeight + _headerHeight,
                                left: 0,
                                right: 0,
                                bottom: 0,
                                child: IgnorePointer(
                                  child: AnimatedBuilder(
                                    animation: _vOutline,
                                    builder: (context, _) => CustomPaint(
                                      painter: _RowDividerPainter(
                                        step: _rowHeight,
                                        colour: t.hairline,
                                        phase:
                                            -((_positionOf(_vOutline)?.pixels ??
                                                    0) %
                                                _rowHeight),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: _graph
                              // The graph editor: the same ruler, zoom and
                              // horizontal scroll as the lane view, over one
                              // full-height pane of curves (docs/07 §5).
                              ? Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Expanded(
                                      child: Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          Expanded(
                                            child: SingleChildScrollView(
                                              scrollDirection: Axis.horizontal,
                                              controller: _hLane,
                                              child: SizedBox(
                                                width: axis.width,
                                                child: Stack(
                                                  children: [
                                                    Column(
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .stretch,
                                                      children: [
                                                        TimelineRuler(
                                                          comp: comp,
                                                          axis: axis,
                                                          fps: ui.model.fps,
                                                          height: _rulerHeight,
                                                          work: work,
                                                          onWorkArea: (span) {
                                                            comp.setWorkArea(
                                                                span: span);
                                                            setState(() {});
                                                          },
                                                          onSeek: (f) => ui
                                                                  .playheadFrame
                                                                  .value =
                                                              f.clamp(
                                                                  0,
                                                                  frames == 0
                                                                      ? 0
                                                                      : frames -
                                                                          1),
                                                        ),
                                                        TimelineCacheBar(
                                                          comp: comp,
                                                          axis: axis,
                                                          revision:
                                                              Listenable.merge([
                                                            ui.frameArrived,
                                                            ui.cacheChanged
                                                          ]),
                                                        ),
                                                        Expanded(
                                                          child: Stack(
                                                            children: [
                                                              // The same two-shade
                                                              // ground the lanes
                                                              // get (K-203): the
                                                              // work area runs the
                                                              // full height of
                                                              // whichever view is
                                                              // open, so the span
                                                              // being delivered is
                                                              // never only a mark
                                                              // on the ruler.
                                                              Positioned.fill(
                                                                child:
                                                                    IgnorePointer(
                                                                  child:
                                                                      CustomPaint(
                                                                    painter:
                                                                        WorkAreaGroundPainter(
                                                                      startX:
                                                                          graphWork
                                                                              ?.$1,
                                                                      endX: graphWork
                                                                          ?.$2,
                                                                      inside: t
                                                                          .surface1,
                                                                      outside: t
                                                                          .timelineOutOfRange,
                                                                    ),
                                                                  ),
                                                                ),
                                                              ),
                                                              GraphEditorFrb(
                                                                key: _graphPane,
                                                                comp: comp,
                                                                hScroll: _hLane,
                                                                channels:
                                                                    channels,
                                                                axis: axis,
                                                                frames: frames,
                                                                fps: ui
                                                                    .model.fps,
                                                                fpsNum: fpsNum,
                                                                fpsDen: fpsDen,
                                                                magnet: _magnet,
                                                                lens:
                                                                    _graphLens,
                                                                autoFit:
                                                                    _graphAutoFit,
                                                                selectedKeys:
                                                                    _graphKeySelection,
                                                                onSelectionChanged:
                                                                    () => setState(
                                                                        () {}),
                                                                onChanged: ui
                                                                    .model
                                                                    .refresh,
                                                                onWheelTime: (e,
                                                                        x) =>
                                                                    _wheel(e, x,
                                                                        axis.perFrame),
                                                              ),
                                                            ],
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                    // The playhead, over the
                                                    // ruler and curves alike.
                                                    ValueListenableBuilder<int>(
                                                      valueListenable:
                                                          ui.playheadFrame,
                                                      builder: (context, frame,
                                                              child) =>
                                                          Positioned(
                                                        left: axis.xOf(frame) -
                                                            PlayheadMarker
                                                                .halfWidth,
                                                        top: 0,
                                                        bottom: 0,
                                                        child: child!,
                                                      ),
                                                      child:
                                                          const PlayheadMarker(),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                          // The pane frames itself vertically
                                          // (or the wheel does); the gutter
                                          // block keeps the columns level
                                          // with the lane view's.
                                          _scrollGutter(
                                            t,
                                            controller: _vLane,
                                            showThumb: false,
                                            header: [
                                              Container(
                                                height: _rulerHeight +
                                                    TimelineCacheBar.height,
                                                color: t.surface2,
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                    _LaneBottomBar(
                                      zoom: _zoom,
                                      hScroll: _hLane,
                                      magnet: _magnet,
                                      onToggleMagnet: () =>
                                          setState(() => _magnet = !_magnet),
                                      onZoom: (z) => setState(
                                          () => _zoom = z.clamp(1.0, 64.0)),
                                      lens: _graphLens,
                                      onLens: (lens) =>
                                          setState(() => _graphLens = lens),
                                      autoFit: _graphAutoFit,
                                      onToggleAutoFit: () => setState(
                                          () => _graphAutoFit = !_graphAutoFit),
                                      onInterp: (side) => _applyInterp(side),
                                    ),
                                  ],
                                )
                              : Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Expanded(
                                      child: Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          Expanded(
                                            child: SingleChildScrollView(
                                              scrollDirection: Axis.horizontal,
                                              controller: _hLane,
                                              child: SizedBox(
                                                width: axis.width,
                                                child: _LayerArea(
                                                  comp: comp,
                                                  layers: layers,
                                                  selectedIds:
                                                      ui.selectedLayerIds,
                                                  layerDrag: _layerDrag,
                                                  blockHeights: blockHeights,
                                                  open: _open,
                                                  hasAudio: _hasAudio,
                                                  peaks: _peaks,
                                                  fps: ui.model.fps,
                                                  fpsNum: fpsNum,
                                                  fpsDen: fpsDen,
                                                  magnet: _magnet,
                                                  axis: axis,
                                                  playhead: ui.playheadFrame,
                                                  razor: _razorArmed(ui),
                                                  onRazor: (entry, frame) =>
                                                      _razorCutAt(ui, entry,
                                                          frame,
                                                          ui.model.refresh),
                                                  vScroll: _vLane,
                                                  selectedKeys:
                                                      _laneKeySelection,
                                                  onDeselectAll: () =>
                                                      _deselectAll(ui),
                                                  work: work,
                                                  onKeysSelected: (keys) {
                                                    // Picking keyframes picks
                                                    // their properties too —
                                                    // every distinct one the
                                                    // box caught — so the
                                                    // outline and the graph
                                                    // show what was boxed
                                                    // (docs/07 §4.3).
                                                    setState(() {
                                                      _laneKeySelection
                                                        ..clear()
                                                        ..addAll(keys);
                                                      if (keys.isEmpty) return;
                                                      _selectedProperties
                                                          .clear();
                                                      for (final id in keys) {
                                                        final path =
                                                            id.substring(
                                                                0,
                                                                id.lastIndexOf(
                                                                    '#'));
                                                        if (!_selectedProperties
                                                            .contains(path)) {
                                                          _selectedProperties
                                                              .add(path);
                                                        }
                                                      }
                                                      final first =
                                                          _selectedProperties
                                                              .first;
                                                      final cut =
                                                          first.indexOf('/');
                                                      if (cut > 0) {
                                                        _highlighted = first
                                                            .substring(0, cut);
                                                      }
                                                    });
                                                  },
                                                  onWheel: (e, x) => _wheel(
                                                      e, x, axis.perFrame),
                                                  onSeek: (f) =>
                                                      ui.playheadFrame.value =
                                                          f.clamp(
                                                              0,
                                                              frames == 0
                                                                  ? 0
                                                                  : frames - 1),
                                                  onSelect: (l) =>
                                                      _selectLayer(ui, l,
                                                          among: layers),
                                                  onChanged: ui.model.refresh,
                                                  cacheRevision:
                                                      Listenable.merge([
                                                    ui.frameArrived,
                                                    ui.cacheChanged
                                                  ]),
                                                  dragPreview: _barDrag,
                                                  bounds: _barBounds,
                                                ),
                                              ),
                                            ),
                                          ),
                                          // The lanes' thumb, pinned to the
                                          // viewport's right edge rather than
                                          // riding the scrolled content.
                                          _scrollGutter(
                                            t,
                                            controller: _vLane,
                                            showThumb: true,
                                            header: [
                                              Container(
                                                height: _rulerHeight +
                                                    TimelineCacheBar.height,
                                                color: t.surface2,
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                    _LaneBottomBar(
                                      zoom: _zoom,
                                      hScroll: _hLane,
                                      magnet: _magnet,
                                      onToggleMagnet: () =>
                                          setState(() => _magnet = !_magnet),
                                      onZoom: (z) => setState(
                                          () => _zoom = z.clamp(1.0, 64.0)),
                                    ),
                                  ],
                                ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The Timeline with no composition open: the placeholder, and a drop target
/// over it.
///
/// Dropping footage here asks for the new comp's settings — opened on the
/// media's own size, rate and length — and each dropped item lands in it as a
/// layer; dropping a composition simply opens that one. Without this the
/// panel was a dead end: the drag lifted, showed its feedback, and dropped
/// into nothing.
class _EmptyTimelineDrop extends StatelessWidget {
  final LumitState state;
  const _EmptyTimelineDrop({required this.state});

  @override
  Widget build(BuildContext context) {
    return DragTarget<Object>(
      onWillAcceptWithDetails: (details) =>
          details.data is FootageDragData || details.data is CompDragData,
      onAcceptWithDetails: (details) async {
        switch (details.data) {
          case FootageDragData(:final footage):
            final comp = await state.newComposition(context, footage: footage);
            if (comp == null || !context.mounted) return;
            Provider.of<LumitUiState>(context, listen: false)
                .setSelectedComp(comp);
          case CompDragData(comp: final dropped):
            Provider.of<LumitUiState>(context, listen: false)
                .setSelectedComp(dropped);
        }
      },
      builder: (context, candidate, _) => Container(
        foregroundDecoration: candidate.isEmpty
            ? null
            : BoxDecoration(
                border: Border.all(
                    color: ThemeScope.of(context).theme.accent, width: 2),
              ),
        child: const PlaceholderPanel(
          icon: LumitIcon.comp,
          title: 'Timeline',
          hint: 'Open a composition, or drop footage here to make one.',
        ),
      ),
    );
  }
}

/// One row of a layer's fold-out, in the outline.
///
/// A heading draws its own twirl; a property row draws the same controls the
/// Effect controls panel does, at exactly one lane's height so the two halves of
/// the table stay in step.
class _FoldRow extends StatelessWidget {
  final CompositionReference comp;
  final LayerReference layer;
  final LayerFoldRow row;

  /// Where the value cells go, so they line up under the render-switch group
  /// whatever order the groups are dragged into (docs/07 §4.3).
  final ValueColumn valueColumn;

  /// Where the identity group starts in the current order — the fold-out
  /// hangs off the layer's own twirl, so a group's twirl sits just inside it
  /// rather than at the row's far left.
  final double baseIndent;

  /// This row's path, and the selected properties' — the row draws itself
  /// selected when it is among them, and highlighted when a selection sits
  /// *under* it (an effect's heading while one of its parameters is picked).
  final String path;
  final List<String> selectedProperties;

  /// Each selected path's graph line colours, one per axis — the label text
  /// takes them so the outline names its curves (docs/07 §5).
  final Map<String, List<Color>> graphColours;
  final ValueChanged<String> onSelectProperty;

  /// Editing a value (or keying) selects the property too, without the
  /// click-gesture modifiers.
  final ValueChanged<String> onEditProperty;
  final int playheadFrame;
  final ValueChanged<int> onSeek;
  final ValueChanged<String> onToggle;
  final VoidCallback onChanged;

  const _FoldRow({
    required this.comp,
    required this.layer,
    required this.row,
    required this.valueColumn,
    required this.baseIndent,
    required this.path,
    required this.selectedProperties,
    required this.graphColours,
    required this.onSelectProperty,
    required this.onEditProperty,
    required this.playheadFrame,
    required this.onSeek,
    required this.onToggle,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    // Just inside the layer's twirl, then one step per level, so a parameter
    // sits under its effect and an effect under Effects.
    final indent = baseIndent + 8.0 + (row.depth - 1) * 12.0;

    // No per-row change listener: the whole panel repaints from the read model
    // when anything commits (K-184), so the numbers shown are the document's.
    final t = ThemeScope.of(context).theme;
    final selected = selectedProperties.contains(path);
    final contains =
        !selected && selectedProperties.any((p) => isUnderPath(path, p));
    // Selection rides on the property's *name* (docs/07 §4.3): the label
    // taps inside the row widgets call [onSelectProperty]; a click on the
    // rest of the row — its fields, its empty space — selects nothing.
    return Container(
      height: _rowHeight,
      // Selected is the full surface; a row that merely *contains* the
      // selection — the effect heading over a picked parameter — is the
      // same at half strength, exactly as a layer row marks itself.
      decoration: BoxDecoration(
        color: selected
            ? t.selectionFill
            : contains
                ? t.selectionFill.withValues(alpha: 0.45)
                : null,
      ),
      padding: EdgeInsets.only(left: indent, right: 4),
      child: _control(context),
    );
  }

  Widget _control(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return switch (row) {
      FoldWaveformRow() => const SizedBox.shrink(),
      FoldGroupRow(:final path, :final label, :final open) => GestureDetector(
          key: ValueKey<String>('tl-group-$path'),
          behavior: HitTestBehavior.opaque,
          onTap: () => onToggle(path),
          child: Row(
            children: [
              lumitIcon(
                open ? LumitIcon.twirlOpen : LumitIcon.twirlClosed,
                size: iconSize,
                color: open ? t.textPrimary : t.textMuted,
              ),
              const SizedBox(width: 4),
              Flexible(
                child:
                    Text(label, style: t.body, overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        ),
      FoldTransformRow(:final group, :final transform) => TransformRowFrb(
          comp: comp,
          layer: layer,
          transform: transform,
          group: group,
          playheadFrame: playheadFrame,
          onSeek: onSeek,
          onChanged: () {
            onEditProperty(path);
            onChanged();
          },
          keyPrefix: 'tl-tf',
          rowPadding: EdgeInsets.zero,
          valueColumn: valueColumn,
          onLabelTap: () => onSelectProperty(path),
          graphColours: graphColours[path],
        ),
      FoldEffectParamRow() => _TimelineParamRow(
          comp: comp,
          layer: layer,
          row: row as FoldEffectParamRow,
          valueColumn: valueColumn,
          playheadFrame: playheadFrame,
          onSeek: onSeek,
          onChanged: () {
            onEditProperty(path);
            onChanged();
          },
          onLabelTap: () => onSelectProperty(path),
          graphColour: graphColours[path]?.firstOrNull,
        ),
      FoldVolumeRow() => _VolumeRow(
          comp: comp,
          layer: layer,
          valueColumn: valueColumn,
          playheadFrame: playheadFrame,
          onSeek: onSeek,
          onChanged: () {
            onEditProperty(path);
            onChanged();
          },
        ),
      FoldRetimeRow(:final scalar) => _RetimeRow(
          comp: comp,
          layer: layer,
          scalar: scalar,
          valueColumn: valueColumn,
          playheadFrame: playheadFrame,
          onSeek: onSeek,
          onChanged: onChanged,
        ),
      FoldMaskRow(:final mask) => _MaskRow(
          comp: comp,
          layer: layer,
          mask: mask,
          valueColumn: valueColumn,
          onChanged: () {
            onEditProperty(path);
            onChanged();
          },
          onLabelTap: () => onSelectProperty(path),
        ),
      FoldShapeRow(:final item) => _ShapeItemRow(
          comp: comp,
          layer: layer,
          item: item,
          valueColumn: valueColumn,
          onChanged: onChanged,
        ),
      FoldStrokeRow(:final stroke) => _StrokeRow(
          comp: comp,
          layer: layer,
          stroke: stroke,
          valueColumn: valueColumn,
          onChanged: onChanged,
        ),
    };
  }
}

/// One effect parameter in the Timeline. It owns the staging for its own drag,
/// which is all the state a single row needs — no stack is read to *display*:
/// the value rides in on the fold row from the read model (K-184), and a drag
/// in flight overlays its staged value on top.
class _TimelineParamRow extends StatefulWidget {
  final CompositionReference comp;
  final LayerReference layer;
  final FoldEffectParamRow row;
  final ValueColumn valueColumn;
  final int playheadFrame;
  final ValueChanged<int> onSeek;
  final VoidCallback onChanged;
  final VoidCallback? onLabelTap;
  final Color? graphColour;

  const _TimelineParamRow({
    required this.comp,
    required this.layer,
    required this.row,
    required this.valueColumn,
    required this.playheadFrame,
    required this.onSeek,
    required this.onChanged,
    this.onLabelTap,
    this.graphColour,
  });

  @override
  State<_TimelineParamRow> createState() => _TimelineParamRowState();
}

class _TimelineParamRowState extends State<_TimelineParamRow> {
  final EffectStackEditor _editor = EffectStackEditor();

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final ui = Provider.of<LumitUiState>(context, listen: false);
    return EffectParamRowFrb(
      key: ValueKey<String>('tl-fx-${row.info.id}-${row.param.id}'),
      effectId: row.info.id,
      param: row.param,
      valueColumn: widget.valueColumn,
      // One lane tall, like every other fold row: the card's own vertical
      // padding on top of that clipped the fields.
      rowPadding: EdgeInsets.zero,
      // The staged value while a drag is in flight, the document's otherwise.
      value: _editor.stagedValue(row.info.id, row.param.id) ?? row.value,
      siblings: {for (final v in row.info.values) v.id: v.value},
      comp: widget.comp,
      ownerLayerId: widget.layer.internallayerId,
      ownerLayers: ui.model.layers,
      playheadFrame: widget.playheadFrame,
      onSeek: widget.onSeek,
      onLabelTap: widget.onLabelTap,
      graphColour: widget.graphColour,
      onWrite: (effect, param, value) {
        _editor.write(widget.layer, effect, param, value);
        setState(() {});
        widget.onChanged();
      },
      onLive: (effect, param, value) => setState(() {
        _editor.live(widget.comp, widget.layer, effect, param, value,
            frame: ui.playheadFrame.value, scale: ui.viewerScale);
      }),
    );
  }
}

/// The Audio group's one row: the layer's Volume, in dB.
class _VolumeRow extends StatefulWidget {
  final CompositionReference comp;
  final LayerReference layer;
  final ValueColumn valueColumn;
  final int playheadFrame;
  final ValueChanged<int> onSeek;
  final VoidCallback onChanged;

  const _VolumeRow({
    required this.comp,
    required this.layer,
    required this.valueColumn,
    required this.playheadFrame,
    required this.onSeek,
    required this.onChanged,
  });

  @override
  State<_VolumeRow> createState() => _VolumeRowState();
}

class _VolumeRowState extends State<_VolumeRow> {
  /// The value under the pointer during a drag. Unlike a transform or an effect
  /// there is no preview to render — sound is not redrawn — so a tick only holds
  /// the number and the release commits it.
  double? _staged;

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final scalar = widget.layer.getVolumeDb();
    final animated = scalar is BridgeScalar_Keyframed;
    final playhead =
        Provider.of<LumitUiState>(context, listen: false).playheadFrame;

    return ValueListenableBuilder<int>(
      valueListenable: playhead,
      builder: (context, frame, _) {
        final value = _staged ??
            (animated
                ? sampleScalar(
                    scalar: scalar, time: timeOfFrame(widget.comp, frame))
                : (scalar as BridgeScalar_Static).field0);
        return Row(
          children: [
            KeyframeControlsFrb(
              scalars: [scalar],
              comp: widget.comp,
              playheadFrame: frame,
              onSeek: widget.onSeek,
              rowKey: 'tl-volume',
              onWrite: (next) {
                widget.layer.setVolumeDb(value: next.single);
                widget.onChanged();
              },
            ),
            const SizedBox(width: 4),
            Expanded(child: Text('Volume', style: t.body)),
            SizedBox(
              width: widget.valueColumn.width,
              // Animated: the change lands in the key under the playhead (or
              // plants one) rather than flattening the curve, and the drag is
              // staged so the whole gesture is one undo step.
              child: animated
                  ? KeyedValueField(
                      fieldKey: const ValueKey('tl-volume-db'),
                      value: value,
                      min: -60,
                      max: 12,
                      decimals: 1,
                      suffix: ' dB',
                      speed: 0.2,
                      onCommit: (v) => _commitAt(scalar, v, frame),
                    )
                  : DragValueField(
                      key: const ValueKey('tl-volume-db'),
                      value: value,
                      // The engine's own range (docs/09 §6): silence to a
                      // +12 dB boost.
                      min: -60,
                      max: 12,
                      decimals: 1,
                      suffix: ' dB',
                      speed: 0.2,
                      onChanged: (v) => _commitAt(scalar, v, frame),
                      onChangeLive: (v) =>
                          setState(() => _staged = v.toDouble()),
                      onChangeEnd: (v) => _commitAt(scalar, v, frame),
                      onDragCancel: () => setState(() => _staged = null),
                    ),
            ),
            SizedBox(width: widget.valueColumn.rightInset),
          ],
        );
      },
    );
  }

  void _commitAt(BridgeScalar scalar, num value, int frame) {
    widget.layer.setVolumeDb(
      value: scalarWithValueAt(scalar, value.toDouble(), widget.comp, frame),
    );
    setState(() => _staged = null);
    widget.onChanged();
  }
}

/// The layer's Retime (K-197): which moment of the source, in seconds, the
/// layer shows at this point on its own timeline.
///
/// An ordinary property row — the same stopwatch, the same navigator, the same
/// lane diamonds and the same graph lanes as Position. It sits above Transform
/// and only exists while the layer has been given a Retime (Ctrl+Alt+T), so
/// unlike Volume its scalar arrives on the fold row rather than being read here
/// (K-184: no bridge calls while drawing).
/// One mask's row in the fold-out (K-222): its name, its invert switch and its
/// opacity.
///
/// Read from the model, written through the layer's own handle — the same shape
/// as every other row here. Deleting a mask is on its right-click menu, and on
/// the Delete key once the row is selected; a button per mask on every row is a
/// row of ways to lose work by mistake.
///
/// The row is selectable like any other property (K-234): tapping its name
/// calls [onLabelTap], the outline highlights it, and Delete acts on it.
class _MaskRow extends StatefulWidget {
  final LayerReference layer;
  final BridgeMask mask;
  final ValueColumn valueColumn;
  final VoidCallback onChanged;
  final VoidCallback? onLabelTap;

  /// The composition, for the live preview a drag shows (K-240).
  final CompositionReference comp;

  const _MaskRow({
    required this.layer,
    required this.mask,
    required this.valueColumn,
    required this.onChanged,
    required this.comp,
    this.onLabelTap,
  });

  @override
  State<_MaskRow> createState() => _MaskRowState();
}

class _MaskRowState extends State<_MaskRow> {
  /// The opacity a drag in flight is showing, before it commits. Held here so
  /// the whole gesture is **one** op and so one Ctrl+Z undoes the whole drag:
  /// writing on every tick filled the undo stack with near-identical steps,
  /// and one undo backed out a single percent — which looked like nothing.
  double? _staged;

  /// Keeps the drag's preview requests about one render apart, as every other
  /// dragged value does.
  final PreviewThrottle _throttle = PreviewThrottle();

  @override
  void dispose() {
    _throttle.cancel();
    super.dispose();
  }

  /// Show the opacity the drag is passing through without writing it (K-240).
  ///
  /// The last of the three rows to get this. Staging alone made the drag one
  /// undo step (K-234) and left the picture still until the button came up;
  /// paint and shape art were fixed under K-239 and this is the same fix, in
  /// the same shape, through the same clone-and-patch render path.
  void _preview(double opacity) {
    final ui = Provider.of<LumitUiState>(context, listen: false);
    _throttle.request(() {
      try {
        widget.comp.renderFrameWithMaskPreview(
          frame: BigInt.from(ui.playheadFrame.value),
          scale: ui.viewerScale,
          layer: widget.layer,
          masks: [
            for (final m in widget.layer.getMasks())
              if (m.id == widget.mask.id) _withOpacity(m, opacity) else m,
          ],
        );
      } catch (_) {
        // A preview is a courtesy; the drag carries on without it.
      }
    });
  }

  static BridgeMask _withOpacity(BridgeMask m, double opacity) => BridgeMask(
        id: m.id,
        name: m.name,
        vertices: m.vertices,
        closed: m.closed,
        inverted: m.inverted,
        opacity: opacity,
      );

  /// Write the mask back with one field changed. The engine takes the whole
  /// mask, so this is the only shape an edit has.
  void _write({bool? inverted, double? opacity}) {
    final mask = widget.mask;
    try {
      widget.layer.setMask(
        mask: BridgeMask(
          id: mask.id,
          name: mask.name,
          vertices: mask.vertices,
          closed: mask.closed,
          inverted: inverted ?? mask.inverted,
          opacity: opacity ?? mask.opacity,
        ),
      );
      widget.onChanged();
    } catch (_) {
      // The mask or its layer went away between the draw and the click.
    }
  }

  void _commitOpacity(num v) {
    setState(() => _staged = null);
    _write(opacity: v.toDouble());
  }

  @override
  Widget build(BuildContext context) {
    final mask = widget.mask;
    final valueColumn = widget.valueColumn;
    final t = ThemeScope.of(context).theme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapUp: (details) => _menu(context, details.globalPosition),
      child: Row(
        children: [
          lumitIcon(LumitIcon.rectangle, size: iconSize, color: t.textSecondary),
          const SizedBox(width: 4),
          // The name is the row's handle, exactly as it is on a transform row:
          // tapping it selects the mask, and Delete then acts on it.
          Expanded(
            child: GestureDetector(
              key: ValueKey<String>('tl-mask-name-${mask.id}'),
              behavior: HitTestBehavior.opaque,
              onTap: widget.onLabelTap,
              child: Text(mask.name,
                  style: t.body, overflow: TextOverflow.ellipsis),
            ),
          ),
          SizedBox(
            width: valueColumn.width,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                LumitTooltip(
                  message: 'Invert this mask',
                  child: HouseButton(
                    key: ValueKey<String>('tl-mask-invert-${mask.id}'),
                    small: true,
                    frameless: true,
                    onPressed: () => _write(inverted: !mask.inverted),
                    child: Text(
                      'Inv',
                      style: t.small.copyWith(
                          color: mask.inverted ? t.accent : t.textMuted),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                SizedBox(
                  width: 56,
                  // Staged like every other dragged value here: the drag shows
                  // live and commits once on release, so it is one op and one
                  // undo step.
                  child: DragValueField(
                    key: ValueKey<String>('tl-mask-opacity-${mask.id}'),
                    value: _staged ?? mask.opacity,
                    min: 0,
                    max: 100,
                    suffix: '%',
                    onChanged: _commitOpacity,
                    onChangeLive: (v) {
                      setState(() => _staged = v.toDouble());
                      _preview(v.toDouble());
                    },
                    onChangeEnd: _commitOpacity,
                    onDragCancel: () {
                      setState(() => _staged = null);
                      // The picture is showing a value nobody committed; put
                      // the document's own back on screen.
                      _preview(widget.mask.opacity);
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _menu(BuildContext context, Offset at) {
    showLumitPopup<void>(
      context: context,
      position: at,
      builder: (close) => FloatSurface(
        width: 160,
        child: MenuRow(
          key: ValueKey<String>('tl-mask-delete-${widget.mask.id}'),
          onPressed: () {
            close(null);
            try {
              widget.layer.deleteMask(id: widget.mask.id);
              widget.onChanged();
            } catch (_) {}
          },
          child: const Text('Delete mask'),
        ),
      ),
    );
  }
}

/// One piece of a shape layer's art in the Timeline (K-237): what it is called,
/// how opaque it is, and the menu that deletes it.
///
/// The same shape as the mask and stroke rows: the engine takes the whole
/// contents list, so every edit is "the list, with this item changed".
class _ShapeItemRow extends StatefulWidget {
  final LayerReference layer;
  final BridgeShapeItem item;
  final ValueColumn valueColumn;
  final VoidCallback onChanged;

  /// The composition, for the live preview a drag shows (K-239).
  final CompositionReference comp;

  const _ShapeItemRow({
    required this.layer,
    required this.item,
    required this.valueColumn,
    required this.onChanged,
    required this.comp,
  });

  @override
  State<_ShapeItemRow> createState() => _ShapeItemRowState();
}

class _ShapeItemRowState extends State<_ShapeItemRow> {
  /// The opacity a drag is part way through, or null when nothing is dragging.
  /// Without it the field committed on every tick, so one drag was a stack of
  /// ops and `Ctrl+Z` backed out a hair (K-238, K-239).
  double? _staged;

  final PreviewThrottle _throttle = PreviewThrottle();

  LayerReference get layer => widget.layer;
  BridgeShapeItem get item => widget.item;

  @override
  void dispose() {
    _throttle.cancel();
    super.dispose();
  }

  /// Show the opacity the drag is passing through without writing it (K-239),
  /// exactly as the stroke row above does.
  void _preview(double opacity) {
    final ui = Provider.of<LumitUiState>(context, listen: false);
    _throttle.request(() {
      try {
        widget.comp.renderFrameWithShapePreview(
          frame: BigInt.from(ui.playheadFrame.value),
          scale: ui.viewerScale,
          layer: layer,
          contents: [
            for (final i in layer.getShapeContents())
              if (i.id == item.id) _withOpacity(i, opacity) else i,
          ],
        );
      } catch (_) {
        // A preview is a courtesy; the drag carries on without it.
      }
    });
  }

  static BridgeShapeItem _withOpacity(BridgeShapeItem i, double opacity) =>
      BridgeShapeItem(
        id: i.id,
        name: i.name,
        vertices: i.vertices,
        closed: i.closed,
        fill: i.fill,
        stroke: i.stroke,
        strokeWidth: i.strokeWidth,
        opacity: opacity,
      );

  void _commitOpacity(num v) {
    setState(() => _staged = null);
    _write(opacity: v.toDouble());
  }

  /// Write the contents back with this item changed, or dropped.
  void _write({double? opacity, bool delete = false}) {
    try {
      final contents = <BridgeShapeItem>[
        for (final other in layer.getShapeContents())
          if (other.id != item.id)
            other
          else if (!delete)
            BridgeShapeItem(
              id: other.id,
              name: other.name,
              vertices: other.vertices,
              closed: other.closed,
              fill: other.fill,
              stroke: other.stroke,
              strokeWidth: other.strokeWidth,
              opacity: opacity ?? other.opacity,
            ),
      ];
      layer.setShapeContents(contents: contents);
      widget.onChanged();
    } catch (_) {
      // The item or its layer went away between the draw and the click.
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapUp: (details) => _menu(context, details.globalPosition),
      child: Row(
        children: [
          lumitIcon(LumitIcon.rectangle, size: iconSize, color: t.textSecondary),
          const SizedBox(width: 4),
          Expanded(
            child:
                Text(item.name, style: t.body, overflow: TextOverflow.ellipsis),
          ),
          SizedBox(
            width: widget.valueColumn.width,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                SizedBox(
                  width: 56,
                  // Staged and previewed, like every other dragged value here:
                  // the drag shows live and commits once on release, so it is
                  // one op and one undo step.
                  child: DragValueField(
                    key: ValueKey<String>('tl-shape-opacity-${item.id}'),
                    value: _staged ?? item.opacity,
                    min: 0,
                    max: 100,
                    suffix: '%',
                    onChanged: _commitOpacity,
                    onChangeLive: (v) {
                      setState(() => _staged = v.toDouble());
                      _preview(v.toDouble());
                    },
                    onChangeEnd: _commitOpacity,
                    onDragCancel: () {
                      setState(() => _staged = null);
                      _preview(item.opacity);
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _menu(BuildContext context, Offset at) {
    showLumitPopup<void>(
      context: context,
      position: at,
      builder: (close) => FloatSurface(
        width: 160,
        child: MenuRow(
          key: ValueKey<String>('tl-shape-delete-${item.id}'),
          onPressed: () {
            close(null);
            _write(delete: true);
          },
          child: const Text('Delete shape'),
        ),
      ),
    );
  }
}

/// One paint stroke in the Timeline (K-227): what it is called, how opaque it
/// is, and the menu that deletes it.
///
/// The same shape as [_MaskRow], and for the same reason: the engine takes the
/// whole stroke, so every edit is "this stroke, with one field changed".
class _StrokeRow extends StatefulWidget {
  final LayerReference layer;
  final BridgeStroke stroke;
  final ValueColumn valueColumn;
  final VoidCallback onChanged;

  /// The composition, for the live preview a drag shows (K-239).
  final CompositionReference comp;

  const _StrokeRow({
    required this.layer,
    required this.stroke,
    required this.valueColumn,
    required this.onChanged,
    required this.comp,
  });

  @override
  State<_StrokeRow> createState() => _StrokeRowState();
}

class _StrokeRowState extends State<_StrokeRow> {
  /// The opacity a drag is part way through, or null when nothing is dragging.
  ///
  /// Without this the field committed on every tick of the drag, so pulling a
  /// stroke's opacity across wrote dozens of ops and `Ctrl+Z` walked back one
  /// hair at a time — the reading was "undo doesn't work". One gesture is one
  /// op and one undo step (K-230), the same as the mask row above.
  double? _staged;

  /// Keeps the drag's preview requests to about one render apart, as every
  /// other dragged value does.
  final PreviewThrottle _throttle = PreviewThrottle();

  LayerReference get layer => widget.layer;
  BridgeStroke get stroke => widget.stroke;

  @override
  void dispose() {
    _throttle.cancel();
    super.dispose();
  }

  /// Show the opacity a drag is passing through, without writing it (K-239).
  ///
  /// Staging alone made the drag one undo step (K-238) but left the picture
  /// still until the button came up, which is the wrong half of the bargain: a
  /// value you drag has to show what it is doing. So the tick previews and the
  /// release commits — the same division the Type tool and the transform rows
  /// already use.
  ///
  /// The *whole* stroke list is sent, with this one stroke's opacity replaced,
  /// because paint is stored and committed as a whole list. A preview shaped
  /// differently from the op would be a second description of the same thing.
  void _preview(double opacity) {
    final ui = Provider.of<LumitUiState>(context, listen: false);
    _throttle.request(() {
      try {
        widget.comp.renderFrameWithPaintPreview(
          frame: BigInt.from(ui.playheadFrame.value),
          scale: ui.viewerScale,
          layer: layer,
          strokes: [
            for (final s in layer.getPaint())
              if (s.id == stroke.id) _withOpacity(s, opacity) else s,
          ],
        );
      } catch (_) {
        // A preview is a courtesy; the drag carries on without it.
      }
    });
  }

  static BridgeStroke _withOpacity(BridgeStroke s, double opacity) =>
      BridgeStroke(
        id: s.id,
        name: s.name,
        points: s.points,
        colour: s.colour,
        width: s.width,
        hardness: s.hardness,
        opacity: opacity,
        mode: s.mode,
        cloneOffsetX: s.cloneOffsetX,
        cloneOffsetY: s.cloneOffsetY,
      );

  void _write({double? opacity}) {
    try {
      layer.setStroke(
        stroke: BridgeStroke(
          id: stroke.id,
          name: stroke.name,
          points: stroke.points,
          colour: stroke.colour,
          width: stroke.width,
          hardness: stroke.hardness,
          opacity: opacity ?? stroke.opacity,
          mode: stroke.mode,
          cloneOffsetX: stroke.cloneOffsetX,
          cloneOffsetY: stroke.cloneOffsetY,
        ),
      );
      widget.onChanged();
    } catch (_) {
      // The stroke or its layer went away between the draw and the click.
    }
  }

  void _commitOpacity(num v) {
    setState(() => _staged = null);
    _write(opacity: v.toDouble());
  }

  /// The icon says which of the three tools made it, so a list of marks can be
  /// read at a glance.
  LumitIcon get _icon => switch (stroke.mode) {
        BridgePaintMode.erase => LumitIcon.eraser,
        BridgePaintMode.clone => LumitIcon.cloneStamp,
        BridgePaintMode.paint => LumitIcon.brush,
      };

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapUp: (details) => _menu(context, details.globalPosition),
      child: Row(
        children: [
          lumitIcon(_icon, size: iconSize, color: t.textSecondary),
          const SizedBox(width: 4),
          Expanded(
            child: Text(stroke.name,
                style: t.body, overflow: TextOverflow.ellipsis),
          ),
          SizedBox(
            width: widget.valueColumn.width,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                SizedBox(
                  width: 56,
                  // Staged like every other dragged value here: the drag shows
                  // live and commits once on release, so it is one op and one
                  // undo step.
                  child: DragValueField(
                    key: ValueKey<String>('tl-stroke-opacity-${stroke.id}'),
                    value: _staged ?? stroke.opacity,
                    min: 0,
                    max: 100,
                    suffix: '%',
                    onChanged: _commitOpacity,
                    onChangeLive: (v) {
                      setState(() => _staged = v.toDouble());
                      _preview(v.toDouble());
                    },
                    onChangeEnd: _commitOpacity,
                    onDragCancel: () {
                      setState(() => _staged = null);
                      // The picture is showing a value nobody committed; put
                      // the document's own back on screen.
                      _preview(stroke.opacity);
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _menu(BuildContext context, Offset at) {
    showLumitPopup<void>(
      context: context,
      position: at,
      builder: (close) => FloatSurface(
        width: 160,
        child: MenuRow(
          key: ValueKey<String>('tl-stroke-delete-${stroke.id}'),
          onPressed: () {
            close(null);
            try {
              layer.deleteStroke(id: stroke.id);
              widget.onChanged();
            } catch (_) {}
          },
          child: const Text('Delete stroke'),
        ),
      ),
    );
  }
}

class _RetimeRow extends StatefulWidget {
  final CompositionReference comp;
  final LayerReference layer;
  final BridgeScalar scalar;
  final ValueColumn valueColumn;
  final int playheadFrame;
  final ValueChanged<int> onSeek;
  final VoidCallback onChanged;

  const _RetimeRow({
    required this.comp,
    required this.layer,
    required this.scalar,
    required this.valueColumn,
    required this.playheadFrame,
    required this.onSeek,
    required this.onChanged,
  });

  @override
  State<_RetimeRow> createState() => _RetimeRowState();
}

class _RetimeRowState extends State<_RetimeRow> {
  /// The value under the pointer during a drag, held so the whole gesture is
  /// one undo step. No live preview: a retime drag changes which frame is
  /// decoded, and there is no preview path for that yet — the release commits
  /// and the viewer re-renders then.
  double? _staged;

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final scalar = widget.scalar;
    final animated = scalar is BridgeScalar_Keyframed;
    final playhead =
        Provider.of<LumitUiState>(context, listen: false).playheadFrame;

    return ValueListenableBuilder<int>(
      valueListenable: playhead,
      builder: (context, frame, _) {
        final value = _staged ??
            (animated
                ? sampleScalar(
                    scalar: scalar, time: widget.comp.timeOfFrame(frame: frame))
                : (scalar as BridgeScalar_Static).field0);
        return Row(
          children: [
            KeyframeControlsFrb(
              scalars: [scalar],
              comp: widget.comp,
              playheadFrame: frame,
              onSeek: widget.onSeek,
              rowKey: 'tl-retime',
              onWrite: (next) {
                widget.layer.setRetimeProperty(value: next.single);
                widget.onChanged();
              },
            ),
            const SizedBox(width: 4),
            Expanded(child: Text('Retime', style: t.body)),
            SizedBox(
              width: widget.valueColumn.width,
              child: animated
                  ? KeyedValueField(
                      fieldKey: const ValueKey('tl-retime-seconds'),
                      value: value,
                      // The same open range a transform axis gets: a source
                      // time before zero or past the end simply holds the end
                      // frame (docs/04 §7), so clamping the field would only
                      // fight the drag.
                      min: -100000,
                      max: 100000,
                      decimals: 3,
                      suffix: ' s',
                      speed: 0.02,
                      onCommit: (v) => _commitAt(scalar, v, frame),
                    )
                  : DragValueField(
                      key: const ValueKey('tl-retime-seconds'),
                      value: value,
                      min: -100000,
                      max: 100000,
                      decimals: 3,
                      suffix: ' s',
                      speed: 0.02,
                      onChanged: (v) => _commitAt(scalar, v, frame),
                      onChangeLive: (v) =>
                          setState(() => _staged = v.toDouble()),
                      onChangeEnd: (v) => _commitAt(scalar, v, frame),
                      onDragCancel: () => setState(() => _staged = null),
                    ),
            ),
            SizedBox(width: widget.valueColumn.rightInset),
          ],
        );
      },
    );
  }

  void _commitAt(BridgeScalar scalar, num value, int frame) {
    widget.layer.setRetimeProperty(
      value: scalarWithValueAt(scalar, value.toDouble(), widget.comp, frame),
    );
    setState(() => _staged = null);
    widget.onChanged();
  }
}

/// The live preview of a bar drag in flight: how far each edge and the start
/// offset have moved, in frames. Published by the bar and read by the waveform
/// lane, so the transients travel with the bar rather than jumping on release
/// (K-172). Null between gestures.
class BarDragPreview {
  final String layerId;
  final int deltaIn;
  final int deltaOut;
  final int offsetShift;
  const BarDragPreview(
      this.layerId, this.deltaIn, this.deltaOut, this.offsetShift);
}

/// What a grab of [grab] moved by [delta] frames does to a layer's span.
/// Moving carries the content with the bar, so the start offset travels too;
/// a trim leaves the content where it is and moves one edge over it.
BarDragPreview barDragPreview(String layerId, BarGrab grab, int delta) =>
    switch (grab) {
      BarGrab.move => BarDragPreview(layerId, delta, delta, delta),
      BarGrab.trimIn => BarDragPreview(layerId, delta, 0, 0),
      BarGrab.trimOut => BarDragPreview(layerId, 0, delta, 0),
    };

/// How far a layer's ends may be dragged, in comp frames (K-211).
///
/// **In plain terms:** a Footage, audio or Precomp layer can only show what its
/// source actually holds, so its bar stops where the media does — its head
/// cannot be dragged earlier than the source's first frame, and its tail cannot
/// be dragged past its last. Every generated kind — Solid, Text, Adjustment,
/// Null, Camera, Sequence — has no such source, so both its ends are free and
/// it is whatever length the user drags it to. Switching **Retime** on frees
/// the ends too (docs/04-RETIMING.md): a retimed layer decides for itself which
/// source moment each of its own frames shows, so its length stops being the
/// source's business.
class BarBounds {
  /// The earliest frame the in point may be trimmed to; null = the head is free.
  final int? minIn;

  /// The latest frame the out point may be trimmed to; null = the tail is free.
  final int? maxOut;

  const BarBounds({this.minIn, this.maxOut});

  /// Both ends free: every generated kind, anything retimed, and any source
  /// whose length could not be read.
  static const BarBounds free = BarBounds();

  @override
  bool operator ==(Object other) =>
      other is BarBounds && other.minIn == minIn && other.maxOut == maxOut;

  @override
  int get hashCode => Object.hash(minIn, maxOut);
}

/// The bounds one layer's bar trims within.
///
/// [startOffsetFrame] is where the layer's own time zero sits on the comp
/// timeline, which is where its source's first frame shows; [sourceFrames] is
/// the source's length in comp frames, or null when the layer has no source of
/// its own — or when its length could not be read at all, which leaves the ends
/// free rather than pinning them to a guess (missing media must never silently
/// crop a layer).
BarBounds barBounds({
  required int startOffsetFrame,
  required int? sourceFrames,
  required bool retimed,
}) =>
    retimed || sourceFrames == null
        ? BarBounds.free
        : BarBounds(
            minIn: startOffsetFrame,
            maxOut: startOffsetFrame + sourceFrames,
          );

/// How far a grab of [grab] may actually travel when the gesture has moved
/// [delta] frames: inside the layer's source, and never far enough to turn the
/// bar inside out — a bar always keeps at least one frame.
///
/// A **move** is never clamped. Moving carries the start offset with the bar,
/// so a layer that sits inside its source stays inside it however far it
/// travels; only the two trims can run out of source.
///
/// A bound never drags an edge that is *already* outside it — a layer whose
/// Retime was switched off after being stretched keeps the length it has, and
/// its ends stay where the user left them until they are dragged back in.
int clampBarDelta({
  required BarGrab grab,
  required int delta,
  required int inFrame,
  required int outFrame,
  required BarBounds bounds,
}) {
  switch (grab) {
    case BarGrab.move:
      return delta;
    case BarGrab.trimIn:
      var want = inFrame + delta;
      final earliest = bounds.minIn;
      if (earliest != null) want = max(want, min(earliest, inFrame));
      return min(want, outFrame - 1) - inFrame;
    case BarGrab.trimOut:
      var want = outFrame + delta;
      final latest = bounds.maxOut;
      if (latest != null) want = min(want, max(latest, outFrame));
      return max(want, inFrame + 1) - outFrame;
  }
}

/// An exact time as a comp frame number, without asking the engine (K-184).
///
/// The same floor `FrameRate::frame_at` takes, in whole integers so a long
/// timeline cannot drift the way a double would: a time `num/den` seconds at
/// `fpsNum/fpsDen` frames a second is `num·fpsNum / (den·fpsDen)`, rounded
/// down — and down for negative times too, which is what a layer starting
/// before the comp needs.
int frameOfTime(BridgeRational time, int fpsNum, int fpsDen) {
  final den = time.den.toInt() * fpsDen;
  if (den <= 0) return 0;
  final scaled = time.num.toInt() * fpsNum;
  final quotient = scaled ~/ den;
  return scaled % den != 0 && scaled < 0 ? quotient - 1 : quotient;
}

/// The corner marks that say a bar has run out of source (K-211): a small
/// triangle in the top-left corner when the head is as early as its media
/// allows, and one in the top-right when the tail is as late. Drawn only on the
/// kinds that have a source to run out of, and never on a retimed layer, whose
/// ends are free.
class BarEndMarksPainter extends CustomPainter {
  final bool atIn;
  final bool atOut;
  final Color colour;

  /// The triangle's legs. Small enough to read as a corner cut on a 22px row
  /// rather than as a badge sitting on the bar.
  static const double leg = 5;

  const BarEndMarksPainter({
    required this.atIn,
    required this.atOut,
    required this.colour,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0) return;
    // Never let the two marks meet in the middle of a very short bar: a bar
    // narrower than both legs draws marks scaled to fit it instead.
    final l = min(leg, size.width / 2);
    final paint = Paint()..color = colour;
    if (atIn) {
      canvas.drawPath(
        Path()
          ..moveTo(0, 0)
          ..lineTo(l, 0)
          ..lineTo(0, l)
          ..close(),
        paint,
      );
    }
    if (atOut) {
      canvas.drawPath(
        Path()
          ..moveTo(size.width, 0)
          ..lineTo(size.width - l, 0)
          ..lineTo(size.width, l)
          ..close(),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(BarEndMarksPainter old) =>
      old.atIn != atIn || old.atOut != atOut || old.colour != colour;
}

/// The waveform lane's painter: the layer's source peaks, mapped through its
/// live in/out/offset so dragging or trimming the bar carries the transients
/// with it in realtime (K-172). One vertical min-max line per pixel column.
class _WaveformPainter extends CustomPainter {
  final BridgeAudioPeaks? peaks;

  /// The span as drawn — the document's frames plus any drag in flight.
  final int inFrame;
  final int outFrame;
  final double startOffsetSeconds;
  final TimelineAxis axis;
  final double fps;
  final Color colour;

  const _WaveformPainter({
    required this.peaks,
    required this.inFrame,
    required this.outFrame,
    required this.startOffsetSeconds,
    required this.axis,
    required this.fps,
    required this.colour,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final held = peaks;
    if (held == null || held.pairs.isEmpty || held.durationSeconds <= 0) {
      return;
    }
    final buckets = held.pairs.length ~/ 2;
    final startOffset = startOffsetSeconds;
    final left = axis.xOf(inFrame).clamp(0.0, size.width);
    final right = axis.xOf(outFrame).clamp(0.0, size.width);
    final mid = size.height / 2;
    // Half a pixel of breathing room top and bottom.
    final half = mid - 1;
    final paintLine = Paint()
      ..color = colour
      ..strokeWidth = 1;

    for (var x = left; x < right; x += 1) {
      // Fractional, straight off the axis mapping: frameAt rounds to whole
      // frames, which would staircase the waveform.
      final compSec = x / axis.width * axis.frames / fps;
      final srcSec = compSec - startOffset;
      if (srcSec < 0 || srcSec >= held.durationSeconds) continue;
      final bucket = (srcSec / held.durationSeconds * buckets)
          .floor()
          .clamp(0, buckets - 1);
      final lo = held.pairs[bucket * 2].clamp(-1.0, 1.0);
      final hi = held.pairs[bucket * 2 + 1].clamp(-1.0, 1.0);
      canvas.drawLine(
        Offset(x, mid - hi * half),
        Offset(x, mid - lo * half),
        paintLine,
      );
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.peaks != peaks ||
      old.inFrame != inFrame ||
      old.outFrame != outFrame ||
      old.startOffsetSeconds != startOffsetSeconds ||
      old.fps != fps ||
      old.axis.frames != axis.frames ||
      old.axis.width != axis.width;

  /// A background painter's default is to absorb hits across its whole rect,
  /// which would eat the keyframe marquee underneath. The lane is a picture,
  /// not a control.
  @override
  bool? hitTest(Offset position) => false;
}

/// The outline's toolbar (docs/07 §4.1): the timecode and frame readouts, the
/// layer search, the master motion-blur and shy-filter buttons, the Lane and
/// Graph view buttons, and the ⋯ menu holding the layer/work-area/marker
/// commands the old full-width toolbar carried.
class _Toolbar extends StatelessWidget {
  final CompositionReference comp;

  /// The read model, for the master motion-blur state and the exact rate —
  /// no bridge calls in a build (K-184).
  final CompModel model;

  /// Listened to, not read: only the two readouts redraw as it moves.
  final ValueListenable<int> playhead;
  final bool graph;
  final VoidCallback onToggleGraph;
  final bool razor;
  final VoidCallback onToggleRazor;
  final bool hideShy;
  final VoidCallback onToggleHideShy;
  final ValueChanged<String> onSearch;
  final VoidCallback onChanged;

  const _Toolbar({
    required this.comp,
    required this.model,
    required this.playhead,
    required this.graph,
    required this.onToggleGraph,
    required this.razor,
    required this.onToggleRazor,
    required this.hideShy,
    required this.onToggleHideShy,
    required this.onSearch,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final (fpsNum, fpsDen) = model.fpsExact;
    final mbOn = model.motionBlurEnabled;
    return Container(
      height: _toolbarHeight,
      color: t.surface1,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          // The clock face and the frame count, both zero-based: frame 0 is
          // 00:00:00:00, so three seconds into a 24 fps comp reads f72.
          ValueListenableBuilder<int>(
            valueListenable: playhead,
            builder: (context, frame, _) => Row(
              children: [
                Text(
                  timecodeOfRate(frame, fpsNum, fpsDen),
                  key: const ValueKey('tl-timecode'),
                  style: t.mono,
                ),
                const SizedBox(width: 6),
                Text(
                  'f$frame',
                  key: const ValueKey('tl-frame'),
                  style: t.mono.copyWith(color: t.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: LayerSearchFrb(onChanged: onSearch, width: 1e9)),
          const SizedBox(width: 8),
          _iconButton(
            context,
            keyName: 'tl-mb-master',
            icon: LumitIcon.motionBlur,
            on: mbOn,
            tip: mbOn
                ? 'Master motion blur on — layers with their switch set blur'
                : 'Master motion blur: enable the shutter for this comp',
            onPressed: () {
              comp.setMotionBlurEnabled(on_: !mbOn);
              onChanged();
            },
          ),
          _iconButton(
            context,
            keyName: 'tl-hide-shy',
            icon: LumitIcon.shy,
            on: hideShy,
            tip: hideShy
                ? 'Shy layers hidden from this list'
                : 'Hide shy layers from this list',
            onPressed: onToggleHideShy,
          ),
          const SizedBox(width: 6),
          _iconButton(
            context,
            keyName: 'tl-view-lanes',
            icon: LumitIcon.timelineBars,
            on: !graph,
            tip: 'Lane view',
            onPressed: graph ? onToggleGraph : () {},
          ),
          _iconButton(
            context,
            // Keeps the key the old Graph toolbar button had, so the graph
            // editor's own tests and muscle memory both still find it.
            keyName: 'tl-graph',
            icon: LumitIcon.graphCurve,
            on: graph,
            tip: 'Graph view',
            onPressed: graph ? () {} : onToggleGraph,
          ),
          const SizedBox(width: 6),
          HouseButton(
            key: const ValueKey('tl-more'),
            small: true,
            frameless: true,
            onPressed: () => _showMoreMenu(context),
            child: Text('⋯', style: t.small),
          ),
        ],
      ),
    );
  }

  Widget _iconButton(
    BuildContext context, {
    required String keyName,
    required LumitIcon icon,
    required bool on,
    required String tip,
    required VoidCallback onPressed,
  }) {
    final t = ThemeScope.of(context).theme;
    return LumitTooltip(
      message: tip,
      child: HouseButton(
        key: ValueKey<String>(keyName),
        small: true,
        frameless: true,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        onPressed: onPressed,
        child: lumitIcon(icon, size: iconSize, color: on ? t.accent : t.textMuted),
      ),
    );
  }

  /// The commands that used to line the full-width toolbar, one menu deep:
  /// adding layers, the razor, the work area, markers and beat detection.
  Future<void> _showMoreMenu(BuildContext context) async {
    final t = ThemeScope.of(context).theme;
    final box = context.findRenderObject();
    if (box is! RenderBox) return;
    final playheadNow = playhead.value;
    final picked = await showLumitPopup<String>(
      context: context,
      position: box.localToGlobal(Offset(box.size.width - 190, 24)),
      builder: (close) => FloatSurface(
        width: 190,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MenuRow(
                key: const ValueKey('tl-add-layer'),
                onPressed: () => close('new-layer'),
                child: const Text('New layer')),
            MenuRow(
                key: const ValueKey('tl-razor'),
                onPressed: () => close('razor'),
                child: Text(razor ? 'Disarm razor' : 'Arm razor',
                    style: razor ? t.body.copyWith(color: t.accent) : null)),
            MenuRow(
                key: const ValueKey('tl-work-in'),
                onPressed: () => close('work-in'),
                child: const Text('Work area starts here')),
            MenuRow(
                key: const ValueKey('tl-work-out'),
                onPressed: () => close('work-out'),
                child: const Text('Work area ends here')),
            MenuRow(
                key: const ValueKey('tl-clear-work-area'),
                onPressed: () => close('work-clear'),
                child: const Text('Clear work area')),
            MenuRow(
                key: const ValueKey('tl-markers'),
                onPressed: () => close('markers'),
                child: const Text('Markers')),
            MenuRow(
                key: const ValueKey('tl-detect-beats'),
                onPressed: () => close('beats'),
                child: const Text('Detect beats')),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    switch (picked) {
      case 'new-layer':
        await _showLayerMenu(context, comp, onChanged);
      case 'razor':
        onToggleRazor();
      case 'work-in' || 'work-out':
        comp.setWorkArea(
          span: workAreaWith(
            comp: comp,
            current: comp.getWorkArea(),
            wanted: playheadNow,
            isStart: picked == 'work-in',
          ),
        );
        onChanged();
      case 'work-clear':
        comp.setWorkArea(span: null);
        onChanged();
      case 'markers':
        await showMarkerEditorFrb(
          context: context,
          comp: comp,
          playheadFrame: playheadNow,
        );
        onChanged();
      case 'beats':
        // Seconds-long on a long comp, so it runs off-thread and the markers
        // appear when it finishes; a comp with no audio, or a machine with no
        // pipeline, says so by doing nothing rather than by an alarm.
        comp
            .detectBeats(sensitivityPercent: 50)
            .then((_) => onChanged(), onError: (_) {});
      case _:
        return;
    }
  }
}

/// A controller's scroll position, or null when there is not exactly one
/// view attached.
///
/// `ScrollController.offset` and `.position` both assert on a controller with
/// two views, which happens for a frame whenever a rebuild inserts the new
/// scroll view before the old one detaches — a drop target lighting up over
/// the panel was enough to hit it.
ScrollPosition? _positionOf(ScrollController controller) =>
    controller.positions.length == 1 ? controller.positions.first : null;

/// A scrollbar for a scroll view that is somewhere else in the tree.
///
/// `RawScrollbar` learns where its scrollable is from `ScrollNotification`s
/// rising through *its own* subtree. Sat in a gutter beside the scroll view,
/// it receives none — so it never repainted and the thumb was simply
/// invisible (K-192). This listens to the controller instead, which is the
/// thing it actually needs to know about, and drags it directly.
class _GutterScrollbar extends StatelessWidget {
  final ScrollController controller;
  final Axis axis;
  const _GutterScrollbar({
    required this.controller,
    this.axis = Axis.vertical,
  });

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final position = _positionOf(controller);
        if (position == null || !position.hasContentDimensions) {
          return const SizedBox.expand();
        }
        final viewport = position.viewportDimension;
        final range = position.maxScrollExtent;
        // Nothing overflows: no thumb, and nothing to grab at.
        if (range <= 0.5 || viewport <= 0) return const SizedBox.expand();

        return LayoutBuilder(
          builder: (context, constraints) {
            final track = axis == Axis.vertical
                ? constraints.maxHeight
                : constraints.maxWidth;
            if (track <= 0) return const SizedBox.expand();
            final extent =
                (viewport / (viewport + range) * track).clamp(20.0, track);
            final travel = track - extent;
            final offset = travel <= 0 ? 0.0 : position.pixels / range * travel;

            void dragBy(double delta) {
              if (travel <= 0) return;
              controller.jumpTo(
                  (position.pixels + delta / travel * range).clamp(0.0, range));
            }

            final thumb = MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: GestureDetector(
                key: const ValueKey('tl-gutter-thumb'),
                behavior: HitTestBehavior.opaque,
                onVerticalDragUpdate:
                    axis == Axis.vertical ? (d) => dragBy(d.delta.dy) : null,
                onHorizontalDragUpdate:
                    axis == Axis.horizontal ? (d) => dragBy(d.delta.dx) : null,
                child: Container(
                  margin: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: t.hairlineStrong,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            );

            return Stack(
              children: [
                axis == Axis.vertical
                    ? Positioned(
                        top: offset,
                        left: 0,
                        right: 0,
                        height: extent,
                        child: thumb)
                    : Positioned(
                        left: offset,
                        top: 0,
                        bottom: 0,
                        width: extent,
                        child: thumb),
              ],
            );
          },
        );
      },
    );
  }
}

/// The seam between adjacent column groups, in a row: plain space of exactly
/// [groupDividerWidth]. The header's rule is enough to read the grouping by;
/// repeating it down every row of a tall stack is noise. The width matches
/// the header's seam so the two stay column-aligned.
const Widget _rowSeam = SizedBox(width: groupDividerWidth);

/// The header's seam: the hairline that names the grouping, and the handle
/// that resizes the group to its left (docs/07 §4.2). Everything else keeps
/// its width, so a drag here widens or narrows the whole outline.
class _GroupSeam extends StatelessWidget {
  final ValueChanged<double> onResize;
  const _GroupSeam({super.key, required this.onResize});

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) => onResize(d.delta.dx),
        child: SizedBox(
          width: groupDividerWidth,
          child: Center(
            child: Container(width: 1, height: 14, color: t.hairlineStrong),
          ),
        ),
      ),
    );
  }
}

/// The column-group header (docs/07 §4.2): one icon per column, grouped into
/// the four clusters, each cluster draggable as a unit to reorder them.
class _ColumnHeader extends StatelessWidget {
  final List<TimelineGroup> order;
  final Map<TimelineGroup, double> widths;
  final void Function(TimelineGroup dragged, TimelineGroup target) onReorder;

  /// A seam dragged: widen (or narrow) the group on its left by `delta`.
  final void Function(TimelineGroup group, double delta) onResize;

  const _ColumnHeader({
    required this.order,
    required this.widths,
    required this.onReorder,
    required this.onResize,
  });

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return Container(
      height: _headerHeight,
      color: t.surface2,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          for (var i = 0; i < order.length; i++) ...[
            // The seam resizes the group it follows, which is the one the eye
            // reads it as belonging to.
            if (i > 0)
              _GroupSeam(
                key: ValueKey<String>('tl-seam-${order[i - 1].name}'),
                onResize: (delta) => onResize(order[i - 1], delta),
              ),
            _draggable(context, t, order[i]),
          ],
        ],
      ),
    );
  }

  Widget _draggable(BuildContext context, LumitTheme t, TimelineGroup group) {
    final content = SizedBox(
      width: widths[group],
      child: _cells(t, group, widths[group] ?? 0),
    );
    return DragTarget<TimelineGroup>(
      onWillAcceptWithDetails: (d) => d.data != group,
      onAcceptWithDetails: (d) => onReorder(d.data, group),
      builder: (context, candidate, _) => Draggable<TimelineGroup>(
        key: ValueKey<String>('tl-colgroup-${group.name}'),
        data: group,
        feedback: Container(
          height: _headerHeight,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          color: t.surface2,
          child: Center(
            child: Text(_labelOf(group), style: t.small),
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.4, child: content),
        child: Container(
          color: candidate.isEmpty ? null : t.accent.withValues(alpha: 0.18),
          child: content,
        ),
      ),
    );
  }

  String _labelOf(TimelineGroup group) => switch (group) {
        TimelineGroup.switches => 'A/V',
        TimelineGroup.identity => 'Layer',
        TimelineGroup.render => 'Switches',
        TimelineGroup.compose => 'Matte · Blend · Parent',
      };

  /// The header cells, in the same widths the rows use, so each icon stands
  /// over its column. Indicators only — clicking a header does nothing; the
  /// switches live on the rows (docs/07 §4.2). Each carries a hover hint
  /// naming its column.
  Widget _cells(LumitTheme t, TimelineGroup group, double width) {
    Widget icon(LumitIcon i, String tip) => LumitTooltip(
          message: tip,
          child: Center(child: lumitIcon(i, size: iconSize, color: t.textMuted)),
        );
    Widget cell(LumitIcon i, String tip) =>
        SizedBox(width: switchCellWidth, child: icon(i, tip));
    // The compose titles carry the dropdown's own text inset, so each sits
    // directly over the text in the cell below it.
    Widget title(String text, String tip, double width) => SizedBox(
          width: width,
          child: LumitTooltip(
            message: tip,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: dropdownTextInset),
                child: Text(text, style: t.small),
              ),
            ),
          ),
        );
    return switch (group) {
      TimelineGroup.switches => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            cell(LumitIcon.eye, 'Visible'),
            cell(LumitIcon.audio, 'Audible'),
            cell(LumitIcon.ellipse, 'Solo — render only this layer'),
            cell(LumitIcon.lock, 'Lock — hold the layer still'),
            cell(LumitIcon.shy, 'Shy — hidden while the shy filter is on'),
          ],
        ),
      TimelineGroup.identity => Row(
          children: [
            const SizedBox(width: 16), // the twirl column has no header icon
            SizedBox(width: 16, child: icon(LumitIcon.label, 'Label colour')),
            const SizedBox(width: 4),
            Expanded(
              child: Text('Layer',
                  style: t.small, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      // The switches pack left in ordinary cells; the rest of the group's
      // span is the fold-out's value column, not spare icon room.
      TimelineGroup.render => Row(
          children: [
            cell(LumitIcon.flow, 'Flow · collapse on a Precomp'),
            cell(LumitIcon.fx, 'Effects on or off'),
            cell(LumitIcon.motionBlur, 'Motion blur'),
            cell(LumitIcon.cube3d, '3D layer'),
          ],
        ),
      TimelineGroup.compose => () {
          final (matte, blend, parent) = composeCellWidths(width);
          return Row(
            children: [
              title('Matte', 'Matte — the layer that gates this one', matte),
              const SizedBox(width: cellGap),
              title('Blend', 'Blend mode', blend),
              const SizedBox(width: cellGap),
              title('Parent', 'Parent — transforms follow this layer', parent),
            ],
          );
        }(),
    };
  }
}

Future<void> _showLayerMenu(
  BuildContext context,
  CompositionReference comp,
  VoidCallback onChanged,
) async {
  final box = context.findRenderObject();
  if (box is! RenderBox) return;
  final picked = await showLumitPopup<String>(
    context: context,
    position: box.localToGlobal(Offset(0, box.size.height + 2)),
    builder: (close) => FloatSurface(
      width: 190,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final kind in [
            'Solid',
            'Text',
            'Camera',
            'Adjustment',
            'Null',
            'Sequence'
          ])
            MenuRow(onPressed: () => close(kind), child: Text(kind)),
        ],
      ),
    ),
  );
  switch (picked) {
    case 'Solid':
      comp.addSolidLayer();
    case 'Text':
      comp.addTextLayer();
    case 'Camera':
      comp.addCameraLayer();
    case 'Adjustment':
      comp.addAdjustmentLayer();
    case 'Null':
      comp.addNullLayer();
    case 'Sequence':
      comp.addSequenceLayer();
    case _:
      return;
  }
  onChanged();
}

/// The left column: one row per layer, with its switches and columns.
class _Outline extends StatelessWidget {
  final CompositionReference comp;
  final List<BridgeLayerEntry> layers;

  /// The column groups in their current order and at their current widths
  /// (docs/07 §4.2) — rows draw their cells to match the header's.
  final List<TimelineGroup> groupOrder;
  final Map<TimelineGroup, double> widths;

  /// The whole selection as ids (K-217), worked out once by the panel: a row
  /// asking "am I selected?" is then one set lookup rather than a walk of the
  /// list per row per paint.
  final Set<UuidValue> selectedIds;
  final String? highlighted;

  /// The selected properties' fold paths, in selection order: each is a
  /// curve in the graph, its row draws selected, and every row containing
  /// one highlights (docs/07 §4.3, §5).
  final List<String> selectedProperties;

  /// Each selected path's graph line colours, for tinting its label.
  final Map<String, List<Color>> graphColours;
  final ValueChanged<String> onSelectProperty;
  final ValueChanged<String> onEditProperty;
  final Set<String> open;
  final Map<String, bool> hasAudio;
  final ValueChanged<String> onToggle;
  final int playheadFrame;
  final ValueChanged<int> onSeek;
  final ValueChanged<LayerReference> onSelect;
  final ValueChanged<String> onHighlight;
  final VoidCallback onChanged;

  /// The drag in flight and the block heights it slides by — the panel's, so
  /// the lanes are working from the same two values (K-208).
  final ValueNotifier<LayerDrag?> layerDrag;
  final List<double> blockHeights;

  const _Outline({
    required this.comp,
    required this.layers,
    required this.groupOrder,
    required this.widths,
    required this.selectedIds,
    required this.highlighted,
    required this.selectedProperties,
    required this.graphColours,
    required this.onSelectProperty,
    required this.onEditProperty,
    required this.open,
    required this.hasAudio,
    required this.onToggle,
    required this.playheadFrame,
    required this.onSeek,
    required this.onSelect,
    required this.onHighlight,
    required this.onChanged,
    required this.layerDrag,
    required this.blockHeights,
  });

  @override
  Widget build(BuildContext context) {
    final valueColumn = valueColumnFor(groupOrder, widths);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < layers.length; i++)
          LayerDragSlide(
            drag: layerDrag,
            heights: blockHeights,
            index: i,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _OutlineRow(
            key: ValueKey<String>('tl-row-${layers[i].layer.internallayerId}'),
            comp: comp,
            entry: layers[i],
            layers: layers,
            groupOrder: groupOrder,
            widths: widths,
            index: i,
            count: layers.length,
            // A local compare, not a bridge call: both ids already sit here.
            selected: selectedIds.contains(layers[i].layer.internallayerId),
            // A layer marks itself when its fold was last touched, and when
            // a selected property is one of its own (docs/07 §4.3).
            highlighted: highlighted ==
                    layers[i].layer.internallayerId.toString() ||
                selectedProperties.any((p) =>
                    isUnderPath(layers[i].layer.internallayerId.toString(), p)),
            open: open.contains(layers[i].layer.internallayerId.toString()),
            onToggleOpen: () =>
                onToggle(layers[i].layer.internallayerId.toString()),
            onSelect: () => onSelect(layers[i].layer),
            onChanged: onChanged,
            layerDrag: layerDrag,
            blockHeights: blockHeights,
          ),
          // The fold-out, from the same list the lanes leave room for.
          if (open.contains(layers[i].layer.internallayerId.toString()))
            for (final row in layerFoldRows(
              entry: layers[i],
              open: open,
              hasAudio:
                  hasAudio[layers[i].layer.internallayerId.toString()] ?? false,
            ))
              // A raw pointer listener, not a gesture: touching a sub-item
              // highlights its layer, and it must never fight the row's own
              // taps and drags for the gesture arena.
              Listener(
                onPointerDown: (_) =>
                    onHighlight(layers[i].layer.internallayerId.toString()),
                child: _FoldRow(
                  comp: comp,
                  layer: layers[i].layer,
                  row: row,
                  valueColumn: valueColumn,
                  baseIndent: identityStart(groupOrder, widths),
                  path: foldRowPath(
                      layers[i].layer.internallayerId.toString(), row),
                  selectedProperties: selectedProperties,
                  graphColours: graphColours,
                  onSelectProperty: onSelectProperty,
                  onEditProperty: onEditProperty,
                  playheadFrame: playheadFrame,
                  onSeek: onSeek,
                  onToggle: onToggle,
                  onChanged: onChanged,
                ),
              ),
              ],
            ),
          ),
      ],
    );
  }
}

class _OutlineRow extends StatefulWidget {
  final CompositionReference comp;
  final BridgeLayerEntry entry;

  /// Every layer in the comp, for the parent picker's menu — from the same
  /// read model, so offering them costs nothing.
  final List<BridgeLayerEntry> layers;

  /// The column groups in their current order, and their current widths
  /// (docs/07 §4.2).
  final List<TimelineGroup> groupOrder;
  final Map<TimelineGroup, double> widths;
  final int index;
  final int count;
  final bool selected;

  /// A sub-item of this layer was last touched — drawn a shade dimmer than
  /// selection, so the two states read apart at a glance.
  final bool highlighted;
  final bool open;
  final VoidCallback onToggleOpen;
  final VoidCallback onSelect;
  final VoidCallback onChanged;

  /// The panel's drag state: this row is where the gesture is made — the name
  /// is the stack handle — and setting it here is what lets the lanes beside
  /// the outline move with it (K-208).
  final ValueNotifier<LayerDrag?> layerDrag;

  /// Every block's height, as the stack stood when the panel last built —
  /// what a drag's travel is measured against, so the answer does not depend
  /// on rows the drag is itself moving.
  final List<double> blockHeights;

  const _OutlineRow({
    super.key,
    required this.comp,
    required this.entry,
    required this.layers,
    required this.groupOrder,
    required this.widths,
    required this.index,
    required this.count,
    required this.selected,
    required this.highlighted,
    required this.open,
    required this.onToggleOpen,
    required this.onSelect,
    required this.onChanged,
    required this.layerDrag,
    required this.blockHeights,
  });

  @override
  State<_OutlineRow> createState() => _OutlineRowState();
}

class _OutlineRowState extends State<_OutlineRow> {
  /// The inline rename, entered by double-clicking the name.
  TextEditingController? _rename;

  /// How far this row has been dragged since the lift, in pixels down.
  ///
  /// Accumulated from the gesture's own deltas rather than read back off the
  /// widget's position, because the widget is being slid by the drag: its
  /// position is an output of this number, so reading it back would be the
  /// loop the travel measure exists to break.
  double _dragTravel = 0;

  /// Put the layer where the drag says, and let the rows go.
  ///
  /// A drop that lands where it started is not a reorder — it is the user
  /// changing their mind, and it must cost nothing. Committing it anyway
  /// wrote an undo step for a stack that had not moved.
  void _commitDrag() {
    final drag = widget.layerDrag.value;
    widget.layerDrag.value = null;
    if (drag == null || drag.from == drag.to) return;
    widget.layers[drag.from].layer.reorder(newIndex: BigInt.from(drag.to));
    widget.onChanged();
  }

  LayerReference get layer => widget.entry.layer;
  int get index => widget.index;
  int get count => widget.count;

  @override
  void dispose() {
    _rename?.dispose();
    super.dispose();
  }

  void _commitRename() {
    final text = _rename?.text.trim() ?? '';
    setState(() {
      _rename?.dispose();
      _rename = null;
    });
    if (text.isEmpty || text == widget.entry.info.name) return;
    layer.rename(name: text);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    // ZERO bridge calls: everything this row draws is in the read model
    // (K-184).
    final info = widget.entry.info;

    // Selection happens on the DOWN, for the whole row, outside the gesture
    // arena — the reason the name has always done it that way (see the note by
    // the name cell) applies to every other cell too, and the row's tap used to
    // do it a *second* time on the way up. Two calls per click is invisible for
    // a plain click and exactly wrong for a Ctrl+click, which toggled the layer
    // in and straight back out again.
    return Listener(
      onPointerDown: (event) {
        if (_claimed) {
          _claimed = false;
          return;
        }
        if (event.buttons == kPrimaryButton) widget.onSelect();
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // A tap that does nothing, so that nothing is what happens: the empty
        // ground behind these rows deselects on tap (K-203), and a row that
        // entered no tap into the arena let the ground win and throw away the
        // selection the pointer-down had just made.
        onTap: () {},
        onSecondaryTapDown: (d) => _showRowMenu(context, d.globalPosition),
        child: Container(
          // No drop line: the rows themselves move to where they would land,
          // so a line marking the same slot said it twice.
          child: _rowBody(context, t, info),
        ),
      ),
    );
  }

  /// Set by a control on its way down, so the row above it leaves the
  /// selection alone: pressing a layer's eye, or opening its properties, is
  /// not choosing the layer. The gesture arena used to settle this by itself,
  /// and cannot now that the row selects from a raw listener outside it.
  ///
  /// Cleared by the very next pointer-down the row sees, which is this same
  /// one — Flutter hands a pointer to the innermost target first, so the
  /// control always sets this before the row reads it.
  bool _claimed = false;

  /// Mark [child]'s clicks as the control's own, not the row's.
  Widget _ownClick(Widget child) =>
      Listener(onPointerDown: (_) => _claimed = true, child: child);

  Widget _rowBody(BuildContext context, LumitTheme t, BridgeLayerInfo info) {
    return Container(
        key: ValueKey<String>('tl-rowbody-${layer.internallayerId}'),
        height: _rowHeight,
        decoration: BoxDecoration(
          // Selected is the brighter of the two states; a highlight (this
          // layer's fold-out was last touched) is the same surface at half
          // strength, so they read apart at a glance.
          color: widget.selected
              ? t.selectionFill
              : widget.highlighted
                  ? t.selectionFill.withValues(alpha: 0.45)
                  : null,
          // No seam of its own: K-192's overlay draws the seams for the whole
          // outline, and a border here drew a *second* line a fraction of a
          // pixel from it — the overlay is phased by the scroll offset, which
          // a trackpad leaves fractional, so the two lines pulled apart as the
          // table scrolled and the outline's rows read a hair taller than the
          // lanes beside them.
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            // The cells come in the four column groups, in whatever order
            // the header's drag has put them and at whatever width its seams
            // have been dragged to (docs/07 §4.2).
            for (var i = 0; i < widget.groupOrder.length; i++) ...[
              if (i > 0) _rowSeam,
              SizedBox(
                width: widget.widths[widget.groupOrder[i]],
                // Only the identity group is the layer itself — its name and
                // its number are what you click to choose it. The other three
                // are controls: hiding a layer, or picking its blend mode, is
                // not choosing it, and those cells have never selected.
                child: switch (widget.groupOrder[i]) {
                  TimelineGroup.identity => _identityCells(context, t, info),
                  TimelineGroup.switches =>
                    _ownClick(_switchCells(context, info)),
                  TimelineGroup.render =>
                    _ownClick(_renderCells(context, info)),
                  TimelineGroup.compose => _ownClick(_composeCells(context, t,
                      info, widget.widths[TimelineGroup.compose] ?? 0)),
                },
              ),
            ],
          ],
        ));
  }

  /// Group 1: visibility · audio · solo · lock · shy. The first two swap
  /// their glyph when off — a closed eye, a muted speaker — rather than only
  /// dimming, so the off state reads at a glance.
  Widget _switchCells(BuildContext context, BridgeLayerInfo info) {
    final id = layer.internallayerId.toString();
    final switches = info.switches;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _switch(context, id, 'visible', LumitIcon.eye, switches.visible,
            BridgeLayerSwitch.visible,
            offIcon: LumitIcon.eyeClosed,
            tip: switches.visible ? 'Visible — click to hide' : 'Hidden'),
        _switch(context, id, 'audible', LumitIcon.audio, switches.audible,
            BridgeLayerSwitch.audible,
            offIcon: LumitIcon.mute,
            tip: switches.audible ? 'Audible — click to mute' : 'Muted'),
        // A circle, hollow until soloed.
        _switch(context, id, 'solo', LumitIcon.circleFilled, switches.solo,
            BridgeLayerSwitch.solo,
            offIcon: LumitIcon.ellipse,
            tip: switches.solo
                ? 'Soloed — only soloed layers render'
                : 'Solo this layer'),
        _switch(context, id, 'locked', LumitIcon.lock, switches.locked,
            BridgeLayerSwitch.locked,
            offIcon: LumitIcon.unlock,
            tip: switches.locked
                ? 'Locked — no edits until unlocked'
                : 'Lock this layer'),
        _switch(context, id, 'shy', LumitIcon.shyHidden, switches.shy,
            BridgeLayerSwitch.shy,
            offIcon: LumitIcon.shy,
            tip: switches.shy
                ? 'Shy — hidden while the shy filter is on'
                : 'Mark shy'),
      ],
    );
  }

  /// Group 2: twirl · label chip · layer number · name.
  Widget _identityCells(
      BuildContext context, LumitTheme t, BridgeLayerInfo info) {
    final id = layer.internallayerId.toString();
    return Row(
      children: [
        // The twirl: the layer's properties, where AE puts them. Its own
        // gesture, so opening a layer does not also select it — you often
        // want to look at one layer's values while another is selected.
        LumitTooltip(
          message: widget.open ? 'Fold the properties away' : 'Properties',
          child: _ownClick(GestureDetector(
            key: ValueKey<String>('tl-twirl-$id'),
            behavior: HitTestBehavior.opaque,
            onTap: widget.onToggleOpen,
            child: SizedBox(
              width: 16,
              height: _rowHeight,
              child: Center(
                child: lumitIcon(
                  widget.open ? LumitIcon.twirlOpen : LumitIcon.twirlClosed,
                  size: iconSize,
                  color: widget.open ? t.textPrimary : t.textMuted,
                ),
              ),
            ),
          )),
        ),
        LumitTooltip(
          message: 'Label colour — recolours the bar too',
          child: _ownClick(_labelSwatch(context, t, id, info.label)),
        ),
        const SizedBox(width: 4),
        SizedBox(
          width: 20,
          child:
              Text('${index + 1}', style: t.small.copyWith(color: t.textMuted)),
        ),
        // The name is also the stack handle: drag it up or down to reorder
        // the layer (docs/07 §4.7). A locked layer holds its place.
        //
        // Selection is the row's, on the pointer down — the rename's
        // double-tap holds the gesture arena open for its whole window, so
        // selecting through a tap made a plain click on the name reach the
        // Effect controls a third of a second late.
        //
        // The drag itself: a plain vertical gesture, not a `Draggable`.
        //
        // A `Draggable` carries a floating copy of the thing being moved,
        // which is why this used to show a little name label under the
        // pointer while the real row stayed behind. Both halves of the
        // table already slide (K-208), so the stack shows the move
        // truthfully on its own — the label was a second, worse answer to
        // a question already answered, and the row it named did not move.
        // The row travels; nothing floats.
        Expanded(
          child: info.switches.locked
              ? _name(t, id, info)
              : GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragStart: (_) {
                    _dragTravel = 0;
                    widget.layerDrag.value = LayerDrag(index, index);
                  },
                  onVerticalDragUpdate: (d) {
                    _dragTravel += d.delta.dy;
                    final to = layerDragTarget(
                        widget.blockHeights, index, _dragTravel);
                    final drag = widget.layerDrag.value;
                    if (drag?.to == to && drag?.from == index) return;
                    widget.layerDrag.value = LayerDrag(index, to);
                  },
                  onVerticalDragEnd: (_) => _commitDrag(),
                  onVerticalDragCancel: () => widget.layerDrag.value = null,
                  child: _name(t, id, info),
                ),
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  /// Group 3: flow (collapse on a Precomp) · fx · motion blur · 3D, spread
  /// across the same span the fold-out's value cells use.
  ///
  /// The flow slot: optical flow has no per-layer engine backing yet
  /// (docs/TODO.md), so a Precomp layer shows its collapse switch there —
  /// the spec's flow-or-collapse cell (K-168) — and other kinds leave it
  /// empty rather than offering a control that cannot do anything.
  Widget _renderCells(BuildContext context, BridgeLayerInfo info) {
    final id = layer.internallayerId.toString();
    final switches = info.switches;
    return SizedBox(
      width: renderGroupWidth,
      child: Row(
        children: [
          // Packed left in ordinary switch cells, exactly as group 1 is: the
          // group's remaining span belongs to the fold-out's value column,
          // not to spreading four icons across it.
          info.kind == BridgeLayerKind.precomp
              ? _switch(context, id, 'collapse', LumitIcon.collapse,
                  switches.collapse, BridgeLayerSwitch.collapse,
                  tip: 'Collapse transformations')
              : const SizedBox(width: switchCellWidth),
          _switch(context, id, 'fx', LumitIcon.fx, switches.fx,
              BridgeLayerSwitch.fx,
              tip: switches.fx
                  ? 'Effects render — click to bypass'
                  : 'Effects bypassed'),
          _switch(context, id, 'mb', LumitIcon.motionBlur, switches.motionBlur,
              BridgeLayerSwitch.motionBlur,
              tip: 'Motion blur — needs the comp master on'),
          _switch(context, id, '3d', LumitIcon.cube3d, switches.threeD,
              BridgeLayerSwitch.threeD,
              tip: '3D layer'),
        ],
      ),
    );
  }

  /// Group 4: matte · blend · parent, sharing the group's width so dragging
  /// it wider widens the pickers rather than leaving space beside them.
  Widget _composeCells(
      BuildContext context, LumitTheme t, BridgeLayerInfo info, double width) {
    final (matteWidth, blendWidth, parentWidth) = composeCellWidths(width);
    return Row(
      children: [
        LumitTooltip(
          message: 'Matte — the layer that gates this one',
          child: MattePickerFrb(
            layer: layer,
            info: info,
            all: widget.layers,
            width: matteWidth,
            onChanged: widget.onChanged,
          ),
        ),
        const SizedBox(width: cellGap),
        LumitTooltip(
          message: 'Blend mode',
          child: _blendPicker(context, t, info.blend, blendWidth),
        ),
        const SizedBox(width: cellGap),
        LumitTooltip(
          message: 'Parent — transforms follow this layer',
          child: ParentPickerFrb(
            layer: layer,
            info: info,
            all: widget.layers,
            width: parentWidth,
            onChanged: widget.onChanged,
          ),
        ),
      ],
    );
  }

  /// The name, or the rename editor a double-click turns it into. Submitting
  /// commits; clicking anywhere else commits too (the field loses the row).
  /// A locked layer's name does not open the editor: lock means no edits.
  Widget _name(LumitTheme t, String id, BridgeLayerInfo info) {
    final editor = _rename;
    if (editor != null) {
      return HouseTextField(
        key: ValueKey<String>('tl-rename-$id'),
        controller: editor,
        autofocus: true,
        onSubmitted: (_) => _commitRename(),
      );
    }
    return GestureDetector(
      key: ValueKey<String>('tl-name-$id'),
      behavior: HitTestBehavior.opaque,
      onDoubleTap: info.switches.locked
          ? null
          : () => setState(() {
                _rename = TextEditingController(text: info.name);
              }),
      child: SizedBox(
        height: _rowHeight,
        child: Align(
          alignment: Alignment.centerLeft,
          child:
              Text(info.name, style: t.body, overflow: TextOverflow.ellipsis),
        ),
      ),
    );
  }

  /// The layer's label colour (TL2): a chip that opens the eight-colour
  /// picker. The palette is the theme's own, so no colour literal lives here.
  Widget _labelSwatch(
      BuildContext context, LumitTheme t, String id, int label) {
    return GestureDetector(
      key: ValueKey<String>('tl-label-$id'),
      behavior: HitTestBehavior.opaque,
      onTapDown: (d) async {
        final picked = await showLumitPopup<int>(
          context: context,
          position: d.globalPosition,
          builder: (close) => FloatSurface(
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < LumitTheme.labelCount; i++)
                    GestureDetector(
                      key: ValueKey<String>('tl-label-chip-$i'),
                      onTap: () => close(i),
                      child: Container(
                        width: 14,
                        height: 14,
                        margin: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: t.labelColour(i),
                          borderRadius:
                              BorderRadius.circular(t.tokens.controlRadius),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
        if (picked == null) return;
        layer.setLabel(label: picked);
        widget.onChanged();
      },
      child: SizedBox(
        width: 16,
        height: _rowHeight,
        child: Center(
          child: Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: t.labelColour(label),
              borderRadius: BorderRadius.circular(t.tokens.controlRadius),
            ),
          ),
        ),
      ),
    );
  }

  /// One switch cell: the icon in a small outlined box, so the click targets
  /// read as buttons rather than loose glyphs. With an [offIcon] the glyph
  /// itself flips (closed eye, muted speaker, hollow circle) and keeps full
  /// strength either way; without one the off state dims, as before.
  Widget _switch(
    BuildContext context,
    String id,
    String name,
    LumitIcon icon,
    bool on,
    BridgeLayerSwitch which, {
    LumitIcon? offIcon,
    String? tip,
  }) {
    final t = ThemeScope.of(context).theme;
    final glyph = on || offIcon != null
        ? lumitIcon(on ? icon : offIcon!,
            size: iconSize, color: on ? t.textPrimary : t.textMuted)
        : lumitIcon(icon, size: iconSize, color: t.textDisabled);
    final cell = GestureDetector(
      key: ValueKey<String>('tl-$name-$id'),
      behavior: HitTestBehavior.opaque,
      onTap: () {
        layer.setSwitch(switch_: which, on_: !on);
        widget.onChanged();
      },
      child: SizedBox(
        width: switchCellWidth,
        height: _rowHeight,
        child: Center(
          child: Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: t.surface0,
              borderRadius: BorderRadius.circular(t.tokens.controlRadius),
              border: Border.all(color: t.hairline),
            ),
            child: Center(child: glyph),
          ),
        ),
      ),
    );
    return tip == null ? cell : LumitTooltip(message: tip, child: cell);
  }

  Widget _blendPicker(
      BuildContext context, LumitTheme t, int current, double width) {
    final modes = _blendModes ??= listBlendModes();
    // The cell's share of its group: a dropdown that overflows its cell is a
    // layout error, not a cosmetic one, and the label ellipsises to fit.
    return SizedBox(
      width: width,
      child: BareDropdown<int>(
        key: ValueKey<String>('tl-blend-${layer.internallayerId}'),
        value: current < modes.length ? current : 0,
        options: [for (var i = 0; i < modes.length; i++) i],
        label: (i) => modes[i],
        onChanged: (i) {
          layer.setBlend(index: i);
          widget.onChanged();
        },
      ),
    );
  }

  Future<void> _showRowMenu(BuildContext context, Offset position) async {
    // A locked layer keeps Duplicate — copying is not editing — but its own
    // order and existence are held still until it is unlocked.
    final locked = widget.entry.info.switches.locked;
    final picked = await showLumitPopup<String>(
      context: context,
      position: position,
      builder: (close) => FloatSurface(
        width: 190,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MenuRow(
                onPressed: () => close('duplicate'),
                child: const Text('Duplicate')),
            if (!locked) ...[
              if (index > 0)
                MenuRow(
                    onPressed: () => close('up'),
                    child: const Text('Bring forward')),
              if (index < count - 1)
                MenuRow(
                    onPressed: () => close('down'),
                    child: const Text('Send backward')),
              MenuRow(
                  onPressed: () => close('delete'),
                  child: const Text('Delete')),
            ],
          ],
        ),
      ),
    );
    switch (picked) {
      case 'duplicate':
        layer.duplicate();
      case 'up':
        layer.reorder(newIndex: BigInt.from(index - 1));
      case 'down':
        layer.reorder(newIndex: BigInt.from(index + 1));
      case 'delete':
        layer.delete();
      case _:
        return;
    }
    widget.onChanged();
  }
}

/// The right column: the ruler, the playhead, and one bar per layer.
class _LayerArea extends StatelessWidget {
  final CompositionReference comp;
  final List<BridgeLayerEntry> layers;

  /// The selection as ids, the same set the outline draws from (K-217) — a bar
  /// outlines when its name row is lit, so the two halves of the table never
  /// disagree about what is chosen.
  final Set<UuidValue> selectedIds;

  /// Which layers are twirled open in the outline. Read only to leave the same
  /// room their property rows take, so a bar never drifts away from its name.
  final Set<String> open;

  /// Which layers carry sound — passed through only so the row list this side
  /// builds is identical to the outline's.
  final Map<String, bool> hasAudio;

  /// Each layer's source peaks, for the waveform lanes.
  final Map<String, BridgeAudioPeaks> peaks;

  /// The comp's rate, mapping the lane's pixels onto source seconds.
  final double fps;
  final TimelineAxis axis;

  /// Listened to, not read: only the playhead line moves when it changes.
  final ValueListenable<int> playhead;
  final bool razor;

  /// A razor click on a bar: which layer, and the frame under the pointer.
  final void Function(BridgeLayerEntry entry, int frame) onRazor;
  final ValueChanged<int> onSeek;

  /// Clicking a bar is clicking the layer: the lane side selects too.
  final ValueChanged<LayerReference> onSelect;
  final VoidCallback onChanged;

  /// Fires when something may have changed which frames are held — a frame
  /// arriving or the idle fill banking one — so the bar repaints then rather
  /// than polling the cache on every frame it draws.
  final Listenable cacheRevision;

  /// The bar drag in flight, written by the bars and read by the waveform
  /// lanes, so the peaks move with the gesture rather than on release.
  final ValueNotifier<BarDragPreview?> dragPreview;

  /// How far each layer's ends may be dragged, by layer id (K-211). A layer
  /// with no entry has free ends — the honest answer while a source length is
  /// still being read.
  final Map<String, BarBounds> bounds;

  /// The lanes' vertical scroll — the outline mirrors it, and the thumb in
  /// the gutter beside this area is the one the user grabs.
  final ScrollController vScroll;

  /// The marquee's keyframe selection, as `rowId#index`, and where a new box
  /// reports what it caught.
  final Set<String> selectedKeys;
  final ValueChanged<Set<String>> onKeysSelected;

  /// A click on empty lane space — no bar, no diamond, no drag. Everything
  /// lets go (K-203).
  final VoidCallback onDeselectAll;

  /// The work area in frames, read once by the panel (K-203).
  final ({int start, int end, bool whole}) work;

  /// The layer drag in flight, and the block heights it slides by — the
  /// outline makes the gesture, and these are what let this side move with it
  /// rather than sit still while its layers are reordered (K-208).
  final ValueNotifier<LayerDrag?> layerDrag;
  final List<double> blockHeights;

  /// The comp's exact rate, for the times a key drag commits.
  final int fpsNum;
  final int fpsDen;

  /// Whether a dragged keyframe sticks to whole frames (docs/07 §4.5).
  final bool magnet;

  /// A wheel over the lanes, with the pointer's position in *content* space
  /// (so the zoom can hold the frame under the cursor still). Plain wheels
  /// are left alone, so they still reach the scrollable.
  final void Function(PointerScrollEvent event, double contentX) onWheel;

  const _LayerArea({
    required this.comp,
    required this.layers,
    required this.selectedIds,
    required this.open,
    required this.hasAudio,
    required this.peaks,
    required this.fps,
    required this.axis,
    required this.playhead,
    required this.razor,
    required this.onRazor,
    required this.onSeek,
    required this.onSelect,
    required this.onChanged,
    required this.cacheRevision,
    required this.dragPreview,
    required this.bounds,
    required this.vScroll,
    required this.selectedKeys,
    required this.onKeysSelected,
    required this.onDeselectAll,
    required this.work,
    required this.layerDrag,
    required this.blockHeights,
    required this.fpsNum,
    required this.fpsDen,
    required this.magnet,
    required this.onWheel,
  });

  /// The fold rows the lanes leave room for, per layer — one walk shared by
  /// the lane column, the marquee's hit maths and the diamonds.
  List<LayerFoldRow> _rowsOf(BridgeLayerEntry entry) => layerFoldRows(
        entry: entry,
        open: open,
        hasAudio: hasAudio[entry.layer.internallayerId.toString()] ?? false,
      );

  /// Every keyframe the box caught, walking the same rows the lanes draw —
  /// y from the row stack, x from the key's frame on the axis.
  Set<String> _keysIn(Rect rect) {
    final caught = <String>{};
    var y = 0.0;
    for (final entry in layers) {
      final id = entry.layer.internallayerId.toString();
      y += _rowHeight; // the layer's own bar row
      if (!open.contains(id)) continue;
      for (final row in _rowsOf(entry)) {
        final rowTop = y;
        y += _rowHeight;
        if (rowTop + _rowHeight < rect.top || rowTop > rect.bottom) continue;
        final keys = laneKeysOf(row);
        for (var i = 0; i < keys.length; i++) {
          final x = axis.xOf(laneKeyFrame(keys[i], fps));
          if (x >= rect.left && x <= rect.right) {
            caught.add('${foldRowPath(id, row)}#$i');
          }
        }
      }
    }
    return caught;
  }

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    // Where the work area falls in this area's own pixels, or null when it
    // covers the whole comp — in which case there is no out-of-range ground to
    // wash and the strip stays one colour.
    final workAreaPixels =
        work.whole ? null : (axis.xOf(work.start), axis.xOf(work.end));
    // The blade pointer and the line that says where the cut lands (K-220).
    // Round the whole area rather than inside a bar: the line spans every row,
    // and a pointer clipped to one bar would vanish at its edges. Inert — and
    // free — while the razor is not armed.
    return RazorOverlay(
      active: razor,
      mark: t.textPrimary,
      outline: t.surface0,
      child: Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TimelineRuler(
              comp: comp,
              axis: axis,
              fps: fps,
              height: _rulerHeight,
              work: work,
              onSeek: onSeek,
              onWorkArea: (span) {
                comp.setWorkArea(span: span);
                onChanged();
              },
            ),
            // Directly under the ruler and above the lanes, which is where the
            // interface spec puts it (docs/07 §3.2).
            TimelineCacheBar(comp: comp, axis: axis, revision: cacheRevision),
            // The rows scroll under the pinned ruler, in step with the
            // outline; the thumb lives in the gutter beside this area, so it
            // stays pinned to the viewport's edge rather than riding the
            // horizontally-scrolled content (docs/07 §4.6).
            Expanded(
              // The rows are given at least the viewport's height, so the
              // ground, the row seams and the marquee carry on below the last
              // layer rather than stopping at it: a lane area that ran out of
              // rows half way down read as a hole in the table, and a click in
              // that hole reached nothing to deselect against.
              child: LayoutBuilder(
                  builder: (context, box) => SingleChildScrollView(
                        controller: vScroll,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(minHeight: box.maxHeight),
                          // Innermost, so the pointer-signal resolver hands it
                          // the wheel before the scrollables do — a modified
                          // wheel zooms or pans instead of scrolling, and a
                          // plain one is left alone.
                          child: Listener(
                            // A *modified* wheel is claimed through the resolver, so the
                            // scroll views around this one cannot act on the same event
                            // as well — a Ctrl+wheel zoom that also scrolled the lanes
                            // sideways is what an unclaimed signal looks like. A plain
                            // wheel is deliberately left unregistered: it belongs to the
                            // scrollable, which is what moves the rows (docs/07 §4.6).
                            onPointerSignal: (event) {
                              if (event is! PointerScrollEvent) return;
                              final keys = HardwareKeyboard.instance;
                              if (!keys.isControlPressed && !keys.isShiftPressed) return;
                              GestureBinding.instance.pointerSignalResolver
                                  .register(event, (resolved) {
                                if (resolved is PointerScrollEvent) {
                                  onWheel(resolved, resolved.localPosition.dx);
                                }
                              });
                            },
                            child: Stack(
                              children: [
                                // The ground, in two shades (K-202): the work area keeps
                                // the panel's own surface, and everything outside it is
                                // washed a step darker. Without it the lane area was one
                                // long strip at a single value, which left a selected
                                // row almost nothing to stand out against — and left the
                                // span you are actually delivering invisible below the
                                // ruler.
                                Positioned.fill(
                                  child: IgnorePointer(
                                    child: CustomPaint(
                                      painter: WorkAreaGroundPainter(
                                        startX: workAreaPixels?.$1,
                                        endX: workAreaPixels?.$2,
                                        inside: t.surface1,
                                        outside: t.timelineOutOfRange,
                                      ),
                                    ),
                                  ),
                                ),
                                // Behind the bars: dragging empty lane space boxes up
                                // keyframes (docs/07 §4.3); bars and key handles above
                                // still win their own gestures.
                                Positioned.fill(
                                  child: MarqueeSelect(
                                    key: const ValueKey('tl-lane-marquee'),
                                    onSelect: (rect) => onKeysSelected(_keysIn(rect)),
                                    // A click that caught nothing is a click on empty
                                    // lane space, which is the deselect gesture: the
                                    // bars and the key handles above take their own
                                    // taps, so only the ground reaches here.
                                    onClear: onDeselectAll,
                                  ),
                                ),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    for (var i = 0; i < layers.length; i++)
                                      // The block slides by the same rule and
                                      // the same heights the outline's does, so
                                      // a layer dragged up the stack takes its
                                      // bar and its lanes with it (K-208).
                                      LayerDragSlide(
                                        drag: layerDrag,
                                        heights: blockHeights,
                                        index: i,
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: [
                                            _Bar(
                                              key: ValueKey<String>(
                                                  'tl-bar-${layers[i].layer.internallayerId}'),
                                              comp: comp,
                                              entry: layers[i],
                                              axis: axis,
                                              razor: razor,
                                              selected: selectedIds.contains(
                                                  layers[i]
                                                      .layer
                                                      .internallayerId),
                                              playheadFrame: () =>
                                                  playhead.value,
                                              onRazor: (frame) =>
                                                  onRazor(layers[i], frame),
                                              onSelect: () =>
                                                  onSelect(layers[i].layer),
                                              onChanged: onChanged,
                                              dragPreview: dragPreview,
                                              bounds: bounds[layers[i]
                                                      .layer
                                                      .internallayerId
                                                      .toString()] ??
                                                  BarBounds.free,
                                            ),
                                            // One lane per fold-out row the outline shows,
                                            // from the same list it builds: keyframe rows
                                            // draw their diamonds, the waveform row its
                                            // peaks (K-172), the rest leave their room.
                                            if (open.contains(layers[i]
                                                .layer
                                                .internallayerId
                                                .toString()))
                                              Column(
                                                key: ValueKey<String>(
                                                    'tl-lanes-${layers[i].layer.internallayerId}'),
                                                children: [
                                                  for (final row
                                                      in _rowsOf(layers[i]))
                                                    SizedBox(
                                                      height: _rowHeight,
                                                      child: _lane(
                                                          t, layers[i], row),
                                                    ),
                                                ],
                                              ),
                                          ],
                                        ),
                                      ),
                                  ],
                                ),
                                // The same wash again, over the bars this time: under
                                // them it was invisible along any row that had a layer
                                // in it, which is exactly the rows being looked at. Kept
                                // light, so what is out of range is dimmed rather than
                                // hidden.
                                if (workAreaPixels != null)
                                  Positioned.fill(
                                    child: IgnorePointer(
                                      child: CustomPaint(
                                        painter: WorkAreaGroundPainter(
                                          startX: workAreaPixels.$1,
                                          endX: workAreaPixels.$2,
                                          inside: t.surface1.withValues(alpha: 0),
                                          outside:
                                              t.timelineOutOfRange.withValues(alpha: 0.55),
                                        ),
                                      ),
                                    ),
                                  ),
                                // The row hairlines, over everything and touching
                                // nothing (K-190): they run the full width of the lane
                                // area so the eye can track a row across the table,
                                // and they are drawn rather than given to each row as
                                // a border because a decorated box absorbs pointers —
                                // which would eat the marquee underneath.
                                Positioned.fill(
                                  child: IgnorePointer(
                                    child: CustomPaint(
                                      painter: _RowDividerPainter(
                                        step: _rowHeight,
                                        colour: t.hairline,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  )),
          ],
        ),
        // The playhead rides above every bar so it is never hidden behind one,
        // and it is the only thing here that redraws when it moves.
        ValueListenableBuilder<int>(
          valueListenable: playhead,
          builder: (context, frame, child) => Positioned(
            left: axis.xOf(frame) - PlayheadMarker.halfWidth,
            top: 0,
            bottom: 0,
            child: child!,
          ),
          child: const PlayheadMarker(),
        ),
      ],
    ));
  }

  /// One fold row's lane: diamonds for a keyed property, the waveform for
  /// the waveform row, empty room otherwise.
  Widget? _lane(LumitTheme t, BridgeLayerEntry entry, LayerFoldRow row) {
    final id = entry.layer.internallayerId.toString();
    if (row is FoldWaveformRow) {
      return ValueListenableBuilder<BarDragPreview?>(
        valueListenable: dragPreview,
        builder: (context, preview, _) {
          final p = preview?.layerId == id ? preview : null;
          final span = entry.info.span;
          return CustomPaint(
            key: ValueKey<String>('tl-wave-$id'),
            size: Size(axis.width, _rowHeight),
            painter: _WaveformPainter(
              peaks: peaks[id],
              inFrame: entry.info.inFrame.toInt() + (p?.deltaIn ?? 0),
              outFrame: entry.info.outFrame.toInt() + (p?.deltaOut ?? 0),
              startOffsetSeconds:
                  span.startOffset.num / span.startOffset.den.toDouble() +
                      (p?.offsetShift ?? 0) / fps,
              axis: axis,
              fps: fps,
              colour: t.accent,
            ),
          );
        },
      );
    }
    final keys = laneKeysOf(row);
    if (keys.isEmpty) return null;
    final rowId = foldRowPath(id, row);
    return _KeyLane(
      key: ValueKey<String>('tl-keys-$rowId'),
      entry: entry,
      row: row,
      rowId: rowId,
      keys: keys,
      axis: axis,
      fps: fps,
      fpsNum: fpsNum,
      fpsDen: fpsDen,
      magnet: magnet,
      selectedKeys: selectedKeys,
      onSelectKey: (index, additive) {
        final id = '$rowId#$index';
        // A copy, never the live set: `onKeysSelected` clears it before it
        // reads what it was handed.
        final next = <String>{...selectedKeys};
        if (additive) {
          if (!next.remove(id)) next.add(id);
        } else {
          next
            ..clear()
            ..add(id);
        }
        onKeysSelected(next);
      },
      onChanged: onChanged,
    );
  }
}

/// One keyed property's lane: its keyframes as diamonds, each draggable in
/// time.
///
/// With the magnet on, a drag lands on whole frames; with it off the key may
/// sit *between* frames (docs/07 §4.5) — the times are exact rationals either
/// way. The gesture holds its offset in Dart and commits once on release, so
/// a drag is one undo step; a move onto a neighbour is refused and the key
/// simply stays where it was.
class _KeyLane extends StatefulWidget {
  final BridgeLayerEntry entry;
  final LayerFoldRow row;
  final String rowId;
  final List<BridgeKeyframe> keys;
  final TimelineAxis axis;
  final double fps;
  final int fpsNum;
  final int fpsDen;
  final bool magnet;
  final Set<String> selectedKeys;

  /// Click a diamond to select it — the second way into the key selection the
  /// F9 family and the easing buttons act on, beside the marquee. Additive
  /// (Shift, Ctrl) toggles one in or out of the catch.
  final void Function(int index, bool additive) onSelectKey;
  final VoidCallback onChanged;

  const _KeyLane({
    super.key,
    required this.entry,
    required this.row,
    required this.rowId,
    required this.keys,
    required this.axis,
    required this.fps,
    required this.fpsNum,
    required this.fpsDen,
    required this.magnet,
    required this.selectedKeys,
    required this.onSelectKey,
    required this.onChanged,
  });

  @override
  State<_KeyLane> createState() => _KeyLaneState();
}

class _KeyLaneState extends State<_KeyLane> {
  int? _dragging;

  /// Pixels the gesture has moved. The frame offset is always derived from
  /// this running total rather than summed per event, for the same reason the
  /// bar drag does it: per-event rounding reads as mouse acceleration.
  double _deltaPx = 0;

  /// Where key [i] draws — its own time, plus the drag in flight.
  double _frameOf(int i) {
    final base = laneKeyFrame(widget.keys[i], widget.fps);
    if (_dragging != i) return base;
    final perFrame = widget.axis.perFrame;
    final moved = perFrame <= 0 ? base : base + _deltaPx / perFrame;
    final clamped = moved.clamp(0.0, widget.axis.frames.toDouble());
    return widget.magnet ? clamped.roundToDouble() : clamped;
  }

  void _commit(int index) {
    final frame = _frameOf(index);
    setState(() {
      _dragging = null;
      _deltaPx = 0;
    });
    if (frame == laneKeyFrame(widget.keys[index], widget.fps)) return;
    final moved = moveLaneKey(
      entry: widget.entry,
      row: widget.row,
      index: index,
      time: timeOfSubframe(frame, widget.fpsNum, widget.fpsDen),
    );
    if (moved) widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return Stack(
      children: [
        Positioned.fill(
          child: CustomPaint(
            painter: _LaneKeysPainter(
              frames: [
                for (var i = 0; i < widget.keys.length; i++) _frameOf(i)
              ],
              selected: {
                for (var i = 0; i < widget.keys.length; i++)
                  if (widget.selectedKeys.contains('${widget.rowId}#$i')) i,
              },
              axis: widget.axis,
              colour: t.textPrimary,
              chosen: t.accent,
            ),
          ),
        ),
        for (var i = 0; i < widget.keys.length; i++)
          Positioned(
            left: widget.axis.xOf(_frameOf(i)) - 6,
            top: 0,
            width: 12,
            height: _rowHeight,
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeLeftRight,
              child: GestureDetector(
                key: ValueKey<String>('tl-key-${widget.rowId}#$i'),
                behavior: HitTestBehavior.opaque,
                // Touching a diamond selects it, and a drag is a touch that
                // went somewhere — so the drag's own start is where selection
                // belongs. This recognizer is alone in the arena, which means
                // it wins on release even when the pointer never moved: one
                // callback covers the click and the drag, and no second
                // recognizer competes for the sub-pixel-per-frame movements a
                // lane drag is made of. Without a per-key selection only the
                // marquee could fill the lane catch, so easing one key from
                // the lanes (F9, the bottom bar's buttons) had nothing to act
                // on and looked like it did nothing.
                onHorizontalDragStart: (_) {
                  final keyboard = HardwareKeyboard.instance;
                  widget.onSelectKey(
                    i,
                    keyboard.isShiftPressed ||
                        keyboard.isControlPressed ||
                        keyboard.isMetaPressed,
                  );
                  setState(() {
                    _dragging = i;
                    _deltaPx = 0;
                  });
                },
                onHorizontalDragUpdate: (d) =>
                    setState(() => _deltaPx += d.delta.dx),
                onHorizontalDragEnd: (_) => _commit(i),
                onHorizontalDragCancel: () => setState(() {
                  _dragging = null;
                  _deltaPx = 0;
                }),
              ),
            ),
          ),
      ],
    );
  }
}

/// The lane area's row seams: one hairline per row, the full width of the
/// area (K-190).
///
/// Drawn as one overlay rather than given to each row as a border because a
/// decorated box absorbs pointers — a border per row would quietly eat the
/// keyframe marquee under it — and because the bars fill their whole row, so
/// the seam has to land on top of them to be seen at all.
class _RowDividerPainter extends CustomPainter {
  final double step;
  final Color colour;

  /// How far the first seam sits above the top edge — the outline's overlay
  /// is pinned to the panel rather than to the scrolled rows, so it carries
  /// the scroll offset here instead.
  final double phase;

  const _RowDividerPainter({
    required this.step,
    required this.colour,
    this.phase = 0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (step <= 0) return;
    final paint = Paint()
      ..color = colour
      ..strokeWidth = 1;
    for (var y = phase + step; y <= size.height; y += step) {
      if (y < 0) continue;
      canvas.drawLine(Offset(0, y - 0.5), Offset(size.width, y - 0.5), paint);
    }
  }

  @override
  bool shouldRepaint(_RowDividerPainter old) =>
      old.step != step || old.colour != colour || old.phase != phase;

  /// Never absorbs a pointer: a background painter's default would eat the
  /// gestures on the rows below it.
  @override
  bool? hitTest(Offset position) => false;
}

/// A lane's keyframe diamonds: one per key, the marquee's catch in accent.
class _LaneKeysPainter extends CustomPainter {
  /// Fractional, so a key placed between frames draws between them.
  final List<double> frames;
  final Set<int> selected;
  final TimelineAxis axis;
  final Color colour;
  final Color chosen;

  const _LaneKeysPainter({
    required this.frames,
    required this.selected,
    required this.axis,
    required this.colour,
    required this.chosen,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const half = 4.0;
    final mid = size.height / 2;
    for (var i = 0; i < frames.length; i++) {
      final x = axis.xOf(frames[i]);
      canvas.drawPath(
        Path()
          ..moveTo(x, mid - half)
          ..lineTo(x + half, mid)
          ..lineTo(x, mid + half)
          ..lineTo(x - half, mid)
          ..close(),
        Paint()..color = selected.contains(i) ? chosen : colour,
      );
    }
  }

  @override
  bool shouldRepaint(_LaneKeysPainter old) =>
      !listEquals(old.frames, frames) ||
      !setEquals(old.selected, selected) ||
      old.colour != colour ||
      old.chosen != chosen ||
      old.axis.frames != axis.frames ||
      old.axis.width != axis.width;

  /// A background painter's default is to absorb hits across its whole rect,
  /// which would eat the keyframe marquee underneath (the diamonds are picked
  /// up by the box, not clicked).
  @override
  bool? hitTest(Offset position) => false;
}

/// The lanes' bottom bar (docs/07 §4.5-§4.6): − / + / Fit with the zoom read
/// out, the magnet, and the horizontal scrollbar that moves the zoomed view.
///
/// In graph view it also carries the graph's own commands (docs/07 §5.3):
/// Linear / Bezier / Hold for the selected keys, the value/speed lens
/// switch, and the auto-fit toggle.
class _LaneBottomBar extends StatelessWidget {
  final double zoom;
  final ScrollController hScroll;
  final ValueChanged<double> onZoom;
  final bool magnet;
  final VoidCallback onToggleMagnet;

  /// Set in graph view; null hides the graph commands (the lane view).
  final GraphLens? lens;
  final ValueChanged<GraphLens>? onLens;
  final bool autoFit;
  final VoidCallback? onToggleAutoFit;
  final ValueChanged<BridgeSideInterp>? onInterp;

  const _LaneBottomBar({
    required this.zoom,
    required this.hScroll,
    required this.onZoom,
    required this.magnet,
    required this.onToggleMagnet,
    this.lens,
    this.onLens,
    this.autoFit = true,
    this.onToggleAutoFit,
    this.onInterp,
  });

  Widget _graphButton(
    LumitTheme t, {
    required String keyName,
    required String label,
    required String tip,
    required bool on,
    required VoidCallback onPressed,
  }) =>
      LumitTooltip(
        message: tip,
        child: HouseButton(
          key: ValueKey<String>(keyName),
          small: true,
          frameless: true,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          onPressed: onPressed,
          child: Text(label,
              style: TextStyle(
                  color: on ? t.accent : t.textMuted,
                  fontSize: t.small.fontSize)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return Container(
      height: 20,
      color: t.surface1,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // The buttons scroll sideways when the panel is narrow — the same
          // answer the Timeline toolbar gives; an overflow stripe is a
          // layout fault. The scrollbar keeps its share of the bar whatever
          // the buttons need.
          final buttonRoom =
              (constraints.maxWidth - 120).clamp(0.0, constraints.maxWidth);
          return Row(
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: buttonRoom),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      if (lens != null) ...[
                        // The selected keys' easing, one click each — the F9 family's
                        // buttons (docs/07 §5.3).
                        _graphButton(t,
                            keyName: 'graph-interp-linear',
                            label: 'Linear',
                            tip:
                                'Selected keyframes: straight lines both sides',
                            on: false,
                            onPressed: () => onInterp
                                ?.call(const BridgeSideInterp.linear())),
                        _graphButton(t,
                            keyName: 'graph-interp-bezier',
                            label: 'Bezier',
                            tip:
                                'Selected keyframes: easy ease (F9) — handles appear',
                            on: false,
                            onPressed: () => onInterp?.call(easyEase)),
                        _graphButton(t,
                            keyName: 'graph-interp-hold',
                            label: 'Hold',
                            tip: 'Selected keyframes: hold until the next key',
                            on: false,
                            onPressed: () =>
                                onInterp?.call(const BridgeSideInterp.hold())),
                        const SizedBox(width: 6),
                        _graphButton(t,
                            keyName: 'graph-lens-value',
                            label: 'Value',
                            tip: 'Value graph — value against time',
                            on: lens == GraphLens.value,
                            onPressed: () => onLens?.call(GraphLens.value)),
                        _graphButton(t,
                            keyName: 'graph-lens-speed',
                            label: 'Speed',
                            tip: 'Speed graph — how fast the value changes',
                            on: lens == GraphLens.speed,
                            onPressed: () => onLens?.call(GraphLens.speed)),
                        const SizedBox(width: 6),
                        _graphButton(t,
                            keyName: 'graph-autofit',
                            label: 'Auto fit',
                            tip: autoFit
                                ? 'Auto fit on — the graph frames its curves; click for '
                                    'manual scroll (wheel pans, Alt+wheel zooms)'
                                : 'Auto fit off — the wheel pans and Alt+wheel zooms '
                                    'the value axis',
                            on: autoFit,
                            onPressed: () => onToggleAutoFit?.call()),
                        const SizedBox(width: 6),
                      ],
                      ...[
                        HouseButton(
                          key: const ValueKey('tl-zoom-out'),
                          small: true,
                          frameless: true,
                          onPressed: () => onZoom(zoom / 1.5),
                          child: Text('−', style: t.small),
                        ),
                        SizedBox(
                          width: 44,
                          child: Text('${(zoom * 100).round()}%',
                              key: const ValueKey('tl-zoom-label'),
                              style: t.small.copyWith(color: t.textMuted),
                              textAlign: TextAlign.center),
                        ),
                        HouseButton(
                          key: const ValueKey('tl-zoom-in'),
                          small: true,
                          frameless: true,
                          onPressed: () => onZoom(zoom * 1.5),
                          child: Text('+', style: t.small),
                        ),
                        HouseButton(
                          key: const ValueKey('tl-zoom-fit'),
                          small: true,
                          frameless: true,
                          onPressed: () => onZoom(1),
                          child: Text('Fit', style: t.small),
                        ),
                        const SizedBox(width: 6),
                        LumitTooltip(
                          message: magnet
                              ? 'Magnet on — dragged keyframes land on whole frames'
                              : 'Magnet off — keyframes may sit between frames',
                          child: HouseButton(
                            key: const ValueKey('tl-magnet'),
                            small: true,
                            frameless: true,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 2),
                            onPressed: onToggleMagnet,
                            child: lumitIcon(LumitIcon.magnet,
                                size: iconSize,
                                color: magnet ? t.accent : t.textMuted),
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                    ],
                  ),
                ),
              ),
              Expanded(
                child: _GutterScrollbar(
                  controller: hScroll,
                  axis: Axis.horizontal,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// One layer's bar: drag its middle to move it, its ends to trim.
class _Bar extends StatefulWidget {
  final CompositionReference comp;
  final BridgeLayerEntry entry;
  final TimelineAxis axis;
  final bool razor;

  /// Read when the razor is clicked, not captured when the bar is built.
  final int Function() playheadFrame;

  /// A razor click on this bar, at the frame under the pointer (K-220) — the
  /// panel decides what that cuts, because Shift cuts layers this bar knows
  /// nothing about.
  final void Function(int frame) onRazor;

  /// Clicking (or grabbing) the bar selects its layer.
  final VoidCallback onSelect;
  final VoidCallback onChanged;

  /// Where the live preview is published, for the waveform lane to follow.
  final ValueNotifier<BarDragPreview?> dragPreview;

  /// How far this layer's ends may be dragged (K-211). [BarBounds.free] for
  /// every kind that has no source to run out of.
  final BarBounds bounds;

  /// Whether this layer is in the selection. The bar is the only mark a
  /// selected layer has on the lane side, and with several chosen at once
  /// (K-217) the outline's lit rows are off the side of the panel.
  final bool selected;

  const _Bar({
    super.key,
    required this.comp,
    required this.entry,
    required this.axis,
    required this.razor,
    required this.selected,
    required this.playheadFrame,
    required this.onRazor,
    required this.onSelect,
    required this.onChanged,
    required this.dragPreview,
    required this.bounds,
  });

  @override
  State<_Bar> createState() => _BarState();
}

class _BarState extends State<_Bar> {
  /// Frames the gesture has moved so far, held here rather than committed.
  ///
  /// A bar drag has no cheap preview to show — moving a layer in time changes
  /// what every frame contains — so the bar moves in Dart and the document
  /// learns about it once, on release.
  int _delta = 0;

  /// Pixels the gesture has moved so far. The frame delta is always derived
  /// from this running total: rounding each pointer event's own delta to
  /// frames and summing those threw the sub-frame remainders away, so a slow
  /// drag moved less than the pointer and a fast one more — which reads as
  /// mouse acceleration.
  double _deltaPx = 0;
  BarGrab? _grab;

  /// Where the pointer went DOWN, deciding edge-trim versus move. Down, not
  /// drag-start: a drag's start position is where the slop was exceeded,
  /// which read a fast edge grab as a grab of the middle.
  double _downDx = 0;

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    // ZERO bridge calls (K-184): the span already mapped to comp frames, the
    // kind, and the clip split positions all ride in on the read model.
    final info = widget.entry.info;
    final inFrame = info.inFrame;
    final outFrame = info.outFrame;

    // A locked layer's bar is a fact, not a handle: no move, no trim, no cut
    // — clicking it still selects, so the lock switch stays reachable.
    final held = info.switches.locked;

    final (drawIn, drawOut) = switch (_grab) {
      BarGrab.move => (inFrame + _delta, outFrame + _delta),
      BarGrab.trimIn => (inFrame + _delta, outFrame),
      BarGrab.trimOut => (inFrame, outFrame + _delta),
      null => (inFrame, outFrame),
    };

    final left = widget.axis.xOf(drawIn);
    final width = (widget.axis.xOf(drawOut) - left).clamp(2.0, 1e6);

    // The source's reach travels with a move: sliding a layer along the
    // timeline carries its start offset, so the media it can show moves with
    // it. Without this the marks and the ghost stayed behind while the bar
    // went, and a bar at its limit looked as though it had left the limit.
    final shift = _grab == BarGrab.move ? _delta : 0;
    final minIn = widget.bounds.minIn == null ? null : widget.bounds.minIn! + shift;
    final maxOut =
        widget.bounds.maxOut == null ? null : widget.bounds.maxOut! + shift;
    // Where the untrimmed source would reach (K-212): drawn behind the bar, so
    // what shows past each end is exactly the material trimmed away. Only when
    // there is something to show — a bar filling its source draws no ghost.
    final ghost = (minIn != null && maxOut != null) &&
            (drawIn > minIn || drawOut < maxOut)
        ? (widget.axis.xOf(minIn), widget.axis.xOf(maxOut))
        : null;

    // The bar fills the row's whole height rather than floating inside an
    // inset, so a layer reads as a solid band; the lane area's own hairline
    // overlay draws the row seam over it (K-190).
    return SizedBox(
      height: _rowHeight,
      // **Both children are keyed.** The ghost comes and goes as the bar is
      // trimmed, and without keys the children were matched by position: the
      // ghost appearing took the bar's slot, so the bar's element — and with it
      // the gesture recogniser holding the drag — was rebuilt from scratch
      // mid-gesture. The bar moved by the first update's frames and then went
      // dead, which is what "dragging a footage edge only moves one frame"
      // was. Keys keep each child matched to its own element however many
      // there are.
      child: Stack(
        children: [
          if (ghost != null)
            Positioned(
              key: ValueKey<String>(
                  'tl-bar-ghost-${widget.entry.layer.internallayerId}'),
              left: ghost.$1,
              width: (ghost.$2 - ghost.$1).clamp(1.0, 1e6),
              top: 0,
              bottom: 0,
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    // The layer's own colour, faint: this is the same clip,
                    // shown as far as it goes, not a second object.
                    color: t.labelColour(info.label).withValues(alpha: 0.10),
                    border: Border.all(
                      color: t.labelColour(info.label).withValues(alpha: 0.45),
                      width: 1,
                    ),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          Positioned(
            key: ValueKey<String>(
                'tl-bar-body-${widget.entry.layer.internallayerId}'),
            left: left,
            width: width,
            top: 0,
            bottom: 0,
            // Selection on the raw DOWN, outside the gesture arena: the
            // bar's tap otherwise waits for the move/trim drag recognisers
            // to concede before the Effect controls learn the layer.
            child: Listener(
              onPointerDown: (event) {
                if (event.buttons == kPrimaryButton) widget.onSelect();
              },
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                // Armed razor: a click cuts this layer **where it was clicked**
                // rather than starting a drag (docs/07 §4.4). At the playhead
                // is what Cut-at-playhead is for; a razor's whole point is that
                // the cut lands under the blade. A layer with nothing cuttable
                // there says so through the engine's calm error, which is
                // nothing on screen — the cut simply does not happen.
                onTapUp: widget.razor && !held
                    ? (details) => widget.onRazor(
                          widget.axis.frameAt(left + details.localPosition.dx),
                        )
                    : null,
                // Selection already happened on the down; the tap has nothing
                // left to do, but registering it keeps the click out of any
                // parent recogniser's hands.
                onTap: widget.razor && !held ? null : () {},
                onHorizontalDragDown: widget.razor || held
                    ? null
                    : (d) => _downDx = d.localPosition.dx,
                onHorizontalDragStart: widget.razor || held
                    ? null
                    // No select here: every drag begins with the down, and the
                    // down already selected.
                    : (d) => setState(() {
                          _delta = 0;
                          _deltaPx = 0;
                          _grab = barGrabAt(_downDx, width);
                        }),
                onHorizontalDragUpdate: widget.razor || held
                    ? null
                    : (d) => setState(() {
                          _deltaPx += d.delta.dx;
                          // The pointer keeps travelling; the bar does not.
                          // Held against the source's ends (K-211) and against
                          // itself, so a trim can neither run past the media
                          // nor turn the bar inside out — and dragging back
                          // picks the edge up again from where it stuck.
                          _delta = clampBarDelta(
                            grab: _grab ?? BarGrab.move,
                            delta: widget.axis.frameAt(_deltaPx),
                            inFrame: inFrame,
                            outFrame: outFrame,
                            bounds: widget.bounds,
                          );
                          _publishPreview();
                        }),
                onHorizontalDragEnd: widget.razor || held
                    ? null
                    : (_) => _commit(inFrame, outFrame),
                onHorizontalDragCancel: widget.razor || held
                    ? null
                    : () => setState(() {
                          _delta = 0;
                          _deltaPx = 0;
                          _grab = null;
                          widget.dragPreview.value = null;
                        }),
                child: Container(
                  key: ValueKey<String>(
                      'tl-bar-fill-${widget.entry.layer.internallayerId}'),
                  decoration: BoxDecoration(
                    // The layer's label colour (K-188): the same chip the
                    // outline swatch shows, so recolouring a layer recolours
                    // its bar — and each kind starts on its own colour.
                    color: t.labelColour(info.label),
                    // Selected bars take the accent as an outline rather than a
                    // fill: the fill is the label colour and says which layer
                    // this is, which is not a thing selection may overwrite.
                    border: widget.selected
                        ? Border.all(color: t.accent, width: 1)
                        : null,
                    borderRadius: BorderRadius.circular(2),
                  ),
                  // A Sequence layer draws its clip splits, so the razor has
                  // something to aim at and a cut is visible once made.
                  child: Stack(
                    children: [
                      for (final clipFrame in info.clipFrames)
                        Positioned(
                          left: widget.axis.xOf(clipFrame.toInt()) - 0.5,
                          top: 0,
                          bottom: 0,
                          child: Container(width: 1, color: t.surface0),
                        ),
                      // The two trim zones say so under the pointer: a bar
                      // whose ends can be taken hold of should not have to be
                      // discovered by trial. Inside the gesture detector, not
                      // over it, so hovering never costs the drag its events.
                      if (!held && !widget.razor) ...[
                        _trimCursor(width, left: true),
                        _trimCursor(width, left: false),
                      ],
                      // The corner marks: this bar is as long as its source
                      // allows in that direction (K-211).
                      Positioned.fill(
                        child: IgnorePointer(
                          child: CustomPaint(
                            key: ValueKey<String>(
                                'tl-bar-ends-${widget.entry.layer.internallayerId}'),
                            painter: BarEndMarksPainter(
                              atIn: minIn != null && drawIn <= minIn,
                              atOut: maxOut != null && drawOut >= maxOut,
                              // The same ink the clip splits use, so the bar
                              // keeps one vocabulary of marks.
                              colour: t.surface0,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// One end's hover strip: the pointer becomes the horizontal resize arrow
  /// over exactly the width [barGrabAt] treats as that end.
  Widget _trimCursor(double width, {required bool left}) {
    final edge = min(_trimGrab, width / 3);
    return Positioned(
      left: left ? 0 : null,
      right: left ? null : 0,
      top: 0,
      bottom: 0,
      width: edge,
      child: const MouseRegion(
        cursor: SystemMouseCursors.resizeLeftRight,
        child: SizedBox.expand(),
      ),
    );
  }

  /// Publish where the gesture has the bar right now, for the waveform lane.
  void _publishPreview() {
    final grab = _grab;
    if (grab == null) return;
    widget.dragPreview.value = barDragPreview(
        widget.entry.layer.internallayerId.toString(), grab, _delta);
  }

  /// One `set_span` for the whole gesture, so a move that shifted the in point
  /// and the start offset together is a single undo step.
  void _commit(int inFrame, int outFrame) {
    final grab = _grab;
    // Clamped once more on the way out: a source length that arrived from its
    // probe part-way through the gesture only reaches the bar on the next
    // build, and what is committed must obey the bounds in force at release.
    final delta = grab == null
        ? 0
        : clampBarDelta(
            grab: grab,
            delta: _delta,
            inFrame: inFrame,
            outFrame: outFrame,
            bounds: widget.bounds,
          );
    setState(() {
      _delta = 0;
      _deltaPx = 0;
      _grab = null;
    });
    widget.dragPreview.value = null;
    if (grab == null || delta == 0) return;

    final span = widget.entry.info.span;
    var newIn = inFrame;
    var newOut = outFrame;
    var offsetShift = 0;
    switch (grab) {
      case BarGrab.move:
        newIn += delta;
        newOut += delta;
        // Moving carries the content with the bar, so time 0 travels too.
        offsetShift = delta;
      case BarGrab.trimIn:
        newIn += delta;
      case BarGrab.trimOut:
        newOut += delta;
    }
    // A bar cannot be trimmed past itself; the op refuses it, and refusing here
    // first means the gesture simply stops rather than raising.
    if (newOut <= newIn) return;

    widget.entry.layer.setSpan(
      span: BridgeSpan(
        inPoint: widget.comp.timeOfFrame(frame: newIn),
        outPoint: widget.comp.timeOfFrame(frame: newOut),
        startOffset: offsetShift == 0
            ? span.startOffset
            : widget.comp.timeOfFrame(
                frame: widget.comp.frameAtTime(time: span.startOffset) +
                    offsetShift,
              ),
      ),
    );
    widget.onChanged();
  }
}

/// Which part of a bar a drag grabbed: its middle, or one of its two ends.
enum BarGrab { move, trimIn, trimOut }
