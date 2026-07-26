// The in-window menu bar (Windows; docs/07-UI-SPEC). Item set ported
// verbatim from shell/app_update.rs — File, Edit, Composition, Window.
// Engine-backed items dispatch to the stub and surface an honest notice.

import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/main.dart';

import '../icons/icons.dart';
import '../state/app_state.dart';
import '../state/settings.dart';
import '../state/workspace.dart';
import '../widgets/controls.dart';
import 'dialogs.dart';
import 'export_dialog.dart';

class LumitMenuBar extends StatelessWidget {
  final LumitState app;

  const LumitMenuBar({
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

                app.openProject(file!.path);
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

class _Item {
  final String? label;
  final VoidCallback? onPressed;
  final List<_Item>? children;
  final bool isDivider;

  _Item(this.label, this.onPressed)
      : children = null,
        isDivider = false;
  _Item.submenu(this.label, this.children)
      : onPressed = null,
        isDivider = false;
  _Item.divider()
      : label = null,
        onPressed = null,
        children = null,
        isDivider = true;
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
            if (item.isDivider)
              Container(
                height: 1,
                margin: const EdgeInsets.symmetric(vertical: 4),
                color: t.hairline,
              )
            else if (item.children != null)
              _SubmenuRow(item: item, closeAll: close)
            else
              MenuRow(
                onPressed: item.onPressed == null
                    ? close
                    : () {
                        close();
                        item.onPressed!();
                      },
                child: Text(
                  item.label!,
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

class _SubmenuRow extends StatefulWidget {
  final _Item item;
  final VoidCallback closeAll;
  const _SubmenuRow({required this.item, required this.closeAll});

  @override
  State<_SubmenuRow> createState() => _SubmenuRowState();
}

class _SubmenuRowState extends State<_SubmenuRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        MenuRow(
          onPressed: () => setState(() => _open = !_open),
          child: Row(
            children: [
              Expanded(child: Text(widget.item.label!)),
              lumitIcon(
                _open ? LumitIcon.twirlOpen : LumitIcon.twirlClosed,
                size: 10,
                color: t.textMuted,
              ),
            ],
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.only(left: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final c in widget.item.children!)
                  MenuRow(
                    onPressed: () {
                      widget.closeAll();
                      c.onPressed?.call();
                    },
                    child: Text(c.label!),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
