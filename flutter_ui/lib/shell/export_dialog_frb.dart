// The export dialogue, on the flutter_rust_bridge API (K-201).
//
// Pick a format and a preset or set the fields yourself, choose where it goes,
// and watch it run. Export is the one long job in Lumit, so this does not
// block: it starts the job and then polls, and the same dialogue shows the
// progress.
//
// **Every field defaults to the truth rather than to a number.** The frame
// rate starts as the composition's own; the range starts as the work area
// when one is set and the whole comp when not — the values a user would have
// typed anyway, already typed. Changing them is the point of the dialogue;
// having to re-derive them would be the failure.
//
// **The encoder it reports is the one actually used.** A hardware encoder that
// is not on this machine falls back to software, and saying "h264_nvenc" when
// the file was written by libx264 would be a lie the user only discovers from
// the export time. The engine reports what it chose; this shows that.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/src/rust/api/composition.dart';
import 'package:lumit_flutter/src/rust/api/export.dart';

import '../state/file_dialogs.dart';
import '../theme/theme.dart';
import '../widgets/controls.dart';

/// The delivery presets offered, with the empty string for a custom export —
/// exactly the names the engine's own preset table knows, because a preset
/// the engine has never heard of stamps nothing and looks broken.
const List<String> _presets = [
  '',
  'youtube_1080p60',
  'youtube_1440p60',
  'youtube_4k60',
  'vertical_1080p60',
];

/// One output format the dialogue offers: the engine key, the reading label,
/// and the file extension its picker filters on.
class _Format {
  final String key;
  final String label;
  final String extension;
  final String pickerLabel;
  const _Format(this.key, this.label, this.extension, this.pickerLabel);

  /// Stills rather than a video container — the shape several rows follow.
  bool get isImages => key == 'png' || key == 'tiff';
}

/// H.264 first because it is the preset default; the sequences last because
/// they are the specialist choice.
const List<_Format> _formats = [
  _Format('h264', 'H.264 video (.mp4)', 'mp4', 'MP4 video'),
  _Format('hevc', 'HEVC video (.mp4)', 'mp4', 'MP4 video'),
  _Format('png', 'PNG image sequence', 'png', 'PNG image'),
  _Format('tiff', 'TIFF image sequence', 'tiff', 'TIFF image'),
];

/// The AAC rates offered, bits per second. 320 leads because it is the
/// delivery-preset rate (docs/06 §7.5); the rest are the customary steps down.
const List<int> _audioRates = [320000, 256000, 192000, 128000];

/// How often the dialogue asks how the export is getting on. Fast enough to
/// feel live, slow enough that polling is not itself work.
const Duration _pollInterval = Duration(milliseconds: 250);

Future<void> showExportDialogFrb({
  required BuildContext context,
  required CompositionReference comp,
  Future<String?> Function()? picker,
}) =>
    showLumitModal<void>(
      context: context,
      id: 'export',
      builder: (close) => _ExportDialog(
        comp: comp,
        picker: picker,
        onClose: () => close(null),
      ),
    );

class _ExportDialog extends StatefulWidget {
  final CompositionReference comp;
  final Future<String?> Function()? picker;
  final VoidCallback onClose;

  const _ExportDialog({
    required this.comp,
    required this.picker,
    required this.onClose,
  });

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  String _preset = '';
  _Format _format = _formats.first;
  int _bitrate = 0;
  double _fps = 60;
  int _rangeStart = 0;
  int _rangeEnd = 1;
  bool _audio = true;
  int _audioRate = _audioRates.first;
  String? _path;
  String? _refused;

  /// The comp's own numbers, held to label the defaults and clamp the range.
  double _compFps = 60;
  int _compFrames = 1;

  Timer? _poll;
  BridgeExportState _state = const BridgeExportState.idle();

  @override
  void initState() {
    super.initState();
    // The defaults are the composition's facts, read once as the dialogue
    // opens: its own rate, and the work area when one is set (the standing
    // export range, K-037) else the whole comp.
    try {
      final settings = widget.comp.getSettings();
      _compFps = settings.fpsNum / settings.fpsDen;
      _fps = _compFps;
      _compFrames = widget.comp.durationFrames();
      final area = widget.comp.getWorkArea();
      if (area != null) {
        _rangeStart =
            (area.inPoint.num / area.inPoint.den * _compFps).round();
        _rangeEnd = (area.outPoint.num / area.outPoint.den * _compFps)
            .round()
            .clamp(_rangeStart + 1, _compFrames);
      } else {
        _rangeStart = 0;
        _rangeEnd = _compFrames;
      }
    } catch (_) {
      // A comp that cannot be read leaves the placeholder defaults; the
      // export itself will refuse with the engine's own words.
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final running = _state is BridgeExportState_Running;
    final images = _format.isImages;

    return FloatSurface(
      width: 460,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(10),
            child: Text('Export composition', style: t.bodyPrimary),
          ),
          _row(
            t,
            'Format',
            SizedBox(
              width: 190,
              child: BareDropdown<_Format>(
                key: const ValueKey('export-format'),
                value: _format,
                options: _formats,
                label: (f) => f.label,
                onChanged: (f) => setState(() {
                  _format = f;
                  // A chosen path keeps its stem but not its extension —
                  // `shot.mp4` as a PNG sequence would write `shot.mp4.00001`
                  // shaped nonsense.
                  final path = _path;
                  if (path != null) {
                    _path = path.replaceFirst(
                        RegExp(r'\.[A-Za-z0-9]+$'), '.${f.extension}');
                  }
                }),
              ),
            ),
          ),
          if (!images)
            _row(
              t,
              'Preset',
              SizedBox(
                width: 150,
                child: BareDropdown<String>(
                  key: const ValueKey('export-preset'),
                  value: _preset,
                  options: _presets,
                  label: (p) => p.isEmpty ? 'Custom' : p,
                  onChanged: _applyPreset,
                ),
              ),
            ),
          if (!images)
            _row(
              t,
              'Bit rate',
              SizedBox(
                width: 90,
                child: DragValueField(
                  key: const ValueKey('export-bitrate'),
                  value: _bitrate,
                  min: 0,
                  max: 400,
                  suffix: _bitrate == 0 ? null : ' Mb/s',
                  onChanged: (v) => setState(() => _bitrate = v.toInt()),
                ),
              ),
            ),
          _row(
            t,
            'Frame rate',
            SizedBox(
              width: 90,
              child: DragValueField(
                key: const ValueKey('export-fps'),
                value: _fps,
                min: 1,
                max: 240,
                decimals: 2,
                resetTo: _compFps,
                onChanged: (v) => setState(() => _fps = v.toDouble()),
              ),
            ),
          ),
          _row(
            t,
            'From frame',
            SizedBox(
              width: 90,
              child: DragValueField(
                key: const ValueKey('export-range-start'),
                value: _rangeStart,
                min: 0,
                max: _compFrames - 1,
                onChanged: (v) => setState(() {
                  _rangeStart = v.toInt();
                  if (_rangeEnd <= _rangeStart) _rangeEnd = _rangeStart + 1;
                }),
              ),
            ),
          ),
          _row(
            t,
            'To frame',
            SizedBox(
              width: 90,
              child: DragValueField(
                key: const ValueKey('export-range-end'),
                value: _rangeEnd,
                min: 1,
                max: _compFrames,
                onChanged: (v) => setState(() {
                  _rangeEnd = v.toInt().clamp(1, _compFrames);
                  if (_rangeStart >= _rangeEnd) _rangeStart = _rangeEnd - 1;
                }),
              ),
            ),
          ),
          if (!images)
            _row(
              t,
              'Include audio',
              HouseCheckbox(
                key: const ValueKey('export-audio'),
                value: _audio,
                onChanged: (v) => setState(() => _audio = v),
              ),
            ),
          if (!images && _audio)
            _row(
              t,
              'Audio bit rate',
              SizedBox(
                width: 110,
                child: BareDropdown<int>(
                  key: const ValueKey('export-audio-rate'),
                  value: _audioRate,
                  options: _audioRates,
                  label: (r) => '${r ~/ 1000} kb/s',
                  onChanged: (r) => setState(() => _audioRate = r),
                ),
              ),
            ),
          _row(
            t,
            'Write to',
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Flexible(
                    child: Text(
                      _path == null ? 'Not chosen' : _leaf(_path!),
                      key: const ValueKey('export-path'),
                      style: t.small
                          .copyWith(color: _path == null ? t.textMuted : null),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 6),
                  HouseButton(
                    key: const ValueKey('export-choose'),
                    small: true,
                    onPressed: running ? null : _choose,
                    child: Text('Choose…', style: t.small),
                  ),
                ],
              ),
            ),
          ),
          if (images)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 0),
              child: Text(
                'One numbered ${_format.extension.toUpperCase()} per frame, '
                'beside the chosen name.',
                style: t.small.copyWith(color: t.textMuted),
              ),
            ),
          const SizedBox(height: 8),
          _status(t),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (running)
                  HouseButton(
                    key: const ValueKey('export-cancel'),
                    small: true,
                    onPressed: () {
                      exportCancel();
                      _refresh();
                    },
                    child: const Text('Cancel export'),
                  )
                else
                  HouseButton(
                    key: const ValueKey('export-start'),
                    small: true,
                    onPressed: _path == null ? null : _start,
                    child: const Text('Export'),
                  ),
                const SizedBox(width: 6),
                HouseButton(
                  key: const ValueKey('export-close'),
                  small: true,
                  frameless: true,
                  onPressed: widget.onClose,
                  child: const Text('Close'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// A preset stamps the fields the engine says it stamps — codec, bitrate —
  /// and leaves the rate and range alone: where and how much to export is the
  /// user's, whatever the delivery target.
  void _applyPreset(String preset) {
    setState(() => _preset = preset);
    if (preset.isEmpty) return;
    final stamp = exportPreset(preset: preset, compName: '', template: '');
    setState(() {
      _format = _formats.firstWhere(
        (f) => f.key == stamp.codec,
        orElse: () => _formats.first,
      );
      _bitrate = stamp.bitrateMbps;
    });
  }

  /// What the export is doing, in the engine's own words where it has any.
  Widget _status(LumitTheme t) {
    final message = switch (_state) {
      BridgeExportState_Running(:final frame, :final total, :final encoder) =>
        total == BigInt.zero
            ? 'Preparing… ($encoder)'
            : 'Frame $frame of $total ($encoder)',
      BridgeExportState_Done(:final path) => 'Written to ${_leaf(path)}',
      BridgeExportState_Failed(:final error) => error,
      _ => _refused ?? '',
    };
    if (message.isEmpty) return const SizedBox.shrink();

    final bad = _state is BridgeExportState_Failed || _refused != null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Text(
        message,
        key: const ValueKey('export-status'),
        style: t.small.copyWith(color: bad ? t.warning : t.textMuted),
      ),
    );
  }

  Widget _row(LumitTheme t, String label, Widget control) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        child: Row(
          children: [
            SizedBox(width: 110, child: Text(label, style: t.body)),
            if (control is Expanded) control else const Spacer(),
            if (control is! Expanded) control,
          ],
        ),
      );

  Future<void> _choose() async {
    final picker = widget.picker;
    final path = picker != null
        ? await picker()
        : await pickExportSaveLocation(
            'export.${_format.extension}',
            extension: _format.extension,
            label: _format.pickerLabel,
          );
    if (path != null) setState(() => _path = path);
  }

  /// Start, and begin polling. A refusal — no GPU, an export already running —
  /// is shown where the progress would be rather than swallowed.
  void _start() {
    final path = _path;
    if (path == null) return;
    setState(() => _refused = null);

    // The range and rate travel exactly as shown. They were filled from the
    // truth (the work area, the comp's rate) when the dialogue opened, so
    // sending them back changes nothing when untouched — and a user who set
    // the range to the whole comp *over* a work area gets the whole comp,
    // not the work area silently reasserting itself.
    try {
      widget.comp.startExport(
        spec: BridgeExportSpec(
          preset: _preset,
          codec: _format.key,
          width: 0,
          height: 0,
          bitrateMbps: _format.isImages ? 0 : _bitrate,
          fps: _fps,
          rangeStartFrame: _rangeStart,
          rangeEndFrame: _rangeEnd,
          includeAudio: !_format.isImages && _audio,
          audioBitRate: _format.isImages ? 0 : _audioRate,
        ),
        path: path,
      );
    } catch (error) {
      setState(() => _refused = '$error');
      return;
    }

    _poll?.cancel();
    _poll = Timer.periodic(_pollInterval, (_) => _refresh());
    _refresh();
  }

  void _refresh() {
    if (!mounted) return;
    final next = exportPoll();
    setState(() => _state = next);
    if (next is! BridgeExportState_Running) _poll?.cancel();
  }

  static String _leaf(String path) => path.split(RegExp(r'[/\\]')).last;
}
