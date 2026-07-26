// The popout window's app: one panel, over the document the main window is
// already editing.
//
// `desktop_multi_window` gives each window its own Flutter engine but the same
// *process*, and the Rust project registry is process-wide — so this adopts the
// open project by asking for it rather than loading a second copy of the file.
// That is the whole difference from the v0 popout, whose separate copy is where
// its resync gap came from: there is nothing to resync when there is one
// document.
//
// It starts no render worker. A second worker rendering the same composition
// would compete with the main window's for the GPU, and every poppable panel is
// read-mostly.

import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/main.dart';
import 'package:provider/provider.dart';

import '../panels/panels_frb.dart';
import '../theme/theme.dart';
import '../widgets/controls.dart';
import 'popout_arguments.dart';

class PopoutHostFrb extends StatefulWidget {
  final PopoutArguments args;

  /// Injected by tests so no engine call is made; production passes null and
  /// the host adopts whatever this process has open.
  final LumitState? state;

  const PopoutHostFrb({super.key, required this.args, this.state});

  @override
  State<PopoutHostFrb> createState() => _PopoutHostFrbState();
}

class _PopoutHostFrbState extends State<PopoutHostFrb> {
  late final LumitState _state = widget.state ?? LumitState();
  late final LumitUiState _uiState = LumitUiState(_state);
  bool _adopted = false;

  @override
  void initState() {
    super.initState();
    _adopted = widget.state != null || _state.adoptCurrentProject();
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.args.theme;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ChangeNotifierProvider<LumitState>.value(
        value: _state,
        child: ChangeNotifierProvider<LumitUiState>.value(
          value: _uiState,
          child: ThemeScope(
            theme: theme,
            animationLevel: AnimationLevel.all,
            showTooltips: true,
            child: Overlay(
              initialEntries: [
                OverlayEntry(
                  builder: (context) => Container(
                    color: theme.surface0,
                    child: _adopted
                        ? buildPanelBodyFrb(context, widget.args.panel)
                        : Center(
                            child: Text(
                              'No project is open in the main window',
                              key: const ValueKey('popout-nothing-open'),
                              style: theme.small,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
