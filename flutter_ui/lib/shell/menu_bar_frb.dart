// The menu bar of the flutter_rust_bridge test shell — the File and Edit items
// reachable from `LumitAppNew` in main.dart.
//
// This is deliberately *not* the shipping menu bar. It is the worked example of
// the frb calling pattern (a `LumitState` holding a `ProjectReference`, methods
// invoked straight on the generated reference types) against which the real
// menu_bar.dart is being ported. The full item set — Composition, Window, the
// export and settings dialogs, the shortcut hints — lives in menu_bar.dart and
// still runs on the v0 JSON bridge; it moves across as the frb API grows to
// cover it (docs/TODO.md, "Bridge").

import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/main.dart';

import '../widgets/controls.dart';

class LumitMenuBarFrb extends StatelessWidget {
  final LumitState app;

  const LumitMenuBarFrb({
    super.key,
    required this.app,
  });

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return Container(
      height: 26,
      color: t.surface2,
      child: Row(
        children: [
          const SizedBox(width: 4),
          _menu(context, 'File', [
            _Item('New project', app.newProject),
            _Item('Open project…', () async {
              const XTypeGroup typeGroup = XTypeGroup(
                label: 'Lumit File',
                extensions: <String>['lum'],
              );

              final XFile? file = await openFile(
                acceptedTypeGroups: <XTypeGroup>[typeGroup],
              );

              // Null means the user dismissed the picker — nothing to open.
              if (file == null) return;
              app.openProject(file.path);
            }),
          ]),
          _menu(context, 'Edit', [
            _Item('Undo', app.project?.undo),
            _Item('Redo', app.project?.redo),
          ]),
        ],
      ),
    );
  }

  Widget _menu(BuildContext context, String title, List<_Item> items) =>
      _MenuButton(title: title, items: items);
}

/// One menu row. The shipping menu bar also has submenus and dividers; this
/// example needs neither, so it carries only a label and an action — a null
/// action renders the row disabled.
class _Item {
  final String label;
  final VoidCallback? onPressed;

  _Item(this.label, this.onPressed);
}

class _MenuButton extends StatelessWidget {
  final String title;
  final List<_Item> items;
  const _MenuButton({required this.title, required this.items});

  @override
  Widget build(BuildContext context) {
    return HouseButton(
      frameless: true,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      onPressed: () => _open(context),
      child: Text(title),
    );
  }

  void _open(BuildContext context) {
    final box = context.findRenderObject()! as RenderBox;
    final origin = box.localToGlobal(Offset(0, box.size.height));
    showLumitPopup<void>(
      context: context,
      position: origin,
      builder: (close) => _MenuList(items: items, close: () => close(null)),
    );
  }
}

class _MenuList extends StatelessWidget {
  final List<_Item> items;
  final VoidCallback close;
  const _MenuList({required this.items, required this.close});

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return FloatSurface(
      width: 230,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final item in items)
            MenuRow(
              onPressed: item.onPressed == null
                  ? close
                  : () {
                      close();
                      item.onPressed!();
                    },
              child: Text(
                item.label,
                style: item.onPressed == null
                    ? t.body.copyWith(color: t.textDisabled)
                    : null,
              ),
            ),
        ],
      ),
    );
  }
}
