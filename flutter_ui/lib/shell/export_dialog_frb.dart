// The export dialogue, on the flutter_rust_bridge API.
//
// Pick a preset or set the fields yourself, choose where it goes, and watch it
// run. Export is the one long job in Lumit, so this does not block: it starts
// the job and then polls, and the same dialogue shows the progress.
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

/// The delivery presets offered, with the empty string for a custom export.
const List<String> _presets = [
  '',
  'youtube_1080p60',
  'youtube_4k60',
  'instagram_reel',
  'prores_master',
];

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
  String _codec = 'h264';
  int _bitrate = 0;
  bool _audio = true;
  String? _path;
  String? _refused;

  Timer? _poll;
  BridgeExportState _state = const BridgeExportState.idle();

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final running = _state is BridgeExportState_Running;

    return FloatSurface(
      width: 440,
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
            'Preset',
            SizedBox(
              width: 150,
              child: BareDropdown<String>(
                key: const ValueKey('export-preset'),
                value: _preset,
                options: _presets,
                label: (p) => p.isEmpty ? 'Custom' : p,
                onChanged: (p) => setState(() => _preset = p),
              ),
            ),
          ),
          _row(
            t,
            'Codec',
            SizedBox(
              width: 150,
              child: BareDropdown<String>(
                key: const ValueKey('export-codec'),
                value: _codec,
                options: const ['h264', 'hevc', 'prores'],
                label: (c) => c,
                onChanged: (c) => setState(() => _codec = c),
              ),
            ),
          ),
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
            'Include audio',
            HouseCheckbox(
              key: const ValueKey('export-audio'),
              value: _audio,
              onChanged: (v) => setState(() => _audio = v),
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
        : await pickExportSaveLocation('export.mp4');
    if (path != null) setState(() => _path = path);
  }

  /// Start, and begin polling. A refusal — no GPU, an export already running —
  /// is shown where the progress would be rather than swallowed.
  void _start() {
    final path = _path;
    if (path == null) return;
    setState(() => _refused = null);

    try {
      widget.comp.startExport(
        spec: BridgeExportSpec(
          preset: _preset,
          codec: _codec,
          width: 0,
          height: 0,
          bitrateMbps: _bitrate,
          includeAudio: _audio,
          // Zero takes the preset's own rate rather than a number this
          // dialogue invented.
          audioBitRate: 0,
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
