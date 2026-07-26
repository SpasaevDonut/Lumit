// The Project panel of the flutter_rust_bridge test shell — the item list
// reachable from `LumitAppNew` in main.dart.
//
// This is deliberately *not* the shipping Project panel. It is the worked
// example of the frb reading pattern, and it is short on purpose: a
// `ProjectReference` from the `LumitState` provider, `getItems()` straight off
// it, and the generated `ItemReference` sum type matched with a Dart switch.
// Note what it does *not* need — no snapshot JSON, no `BridgeItem` mirror class,
// no id-keyed lookups: the generated reference types are the identity.
//
// The shipping panel in project_panel.dart still runs on the v0 JSON bridge and
// carries what this cannot yet express: the folder tree, missing-media detection
// and the relink flow, decoded thumbnails off the UI isolate, in-place rename,
// drag-to-timeline and the context menu. Each of those moves across as the frb
// API grows to cover it (docs/TODO.md, "Bridge").

import 'package:flutter/widgets.dart';
import 'package:lumit_flutter/main.dart';
import 'package:lumit_flutter/src/rust/api/project_item.dart';
import 'package:provider/provider.dart';

import '../icons/icons.dart';
import '../widgets/controls.dart';

class ProjectPanelFrb extends StatelessWidget {
  const ProjectPanelFrb({super.key});

  @override
  Widget build(BuildContext context) {
    final t = ThemeScope.of(context).theme;
    final state = Provider.of<LumitState>(context);
    final uiState = Provider.of<LumitUiState>(context);
    final items = state.project?.getItems() ?? const <ItemReference>[];

    if (items.isEmpty) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 240),
          child: Text(
            'No items yet — import footage or create a composition',
            style: t.small,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return SizedBox(
          height: 24,
          child: HouseButton(
            // Selecting a composition fronts it for the Timeline and Viewer;
            // anything else clears the selection, since only a comp can be open.
            onPressed: () => uiState.setSelectedComp(
              item is ItemReference_Composition ? item.field0 : null,
            ),
            child: Row(
              spacing: 8,
              children: [
                lumitIcon(
                  switch (item) {
                    ItemReference_Footage() => LumitIcon.footage,
                    ItemReference_Solid() => LumitIcon.solid,
                    ItemReference_Composition() => LumitIcon.comp,
                    ItemReference_Folder() => LumitIcon.folder,
                  },
                  size: 16,
                  color: t.accent,
                ),
                Text(item.name(), style: t.small),
              ],
            ),
          ),
        );
      },
    );
  }
}
