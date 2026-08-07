// The dock model: default workspace fidelity to dock.rs::default_layout,
// serialisation round-trip, and the start-up Project-tab rule.

import 'package:flutter_test/flutter_test.dart';
import 'package:lumit_flutter/state/dock.dart';

void main() {
  test('default layout matches default_layout() structure and shares', () {
    final root = defaultLayout();
    expect(root.axis, DockAxis.vertical);
    expect(root.shares, [0.68, 0.32]);
    expect(root.children.length, 2);

    final upper = root.children[0] as DockSplit;
    expect(upper.axis, DockAxis.horizontal);
    expect(upper.shares, [0.22, 0.58, 0.20]);

    final left = upper.children[0] as DockTabs;
    expect(
      [for (final c in left.children) c.panel],
      [
        Panel.project,
        Panel.effectControls,
        Panel.effectsAndPresets,
        Panel.hierarchy,
      ],
    );
    expect(left.active, 0, reason: 'the left group opens on Project');

    expect((upper.children[1] as DockPane).panel, Panel.viewer);
    // The right group tabs the Debug view over Scopes (Airyz's panel).
    final right = upper.children[2] as DockTabs;
    expect(
      [for (final c in right.children) c.panel],
      [Panel.debug, Panel.scopes],
    );
    expect((root.children[1] as DockPane).panel, Panel.timeline);
  });

  test('every panel appears exactly once in the default workspace', () {
    final panels = panelsIn(defaultLayout());
    expect(panels.toSet().length, panels.length);
    expect(panels.toSet(), Panel.values.toSet());
  });

  test('serialisation round-trips the tree', () {
    final root = defaultLayout();
    (root.children[0] as DockSplit).shares[0] = 0.3;
    ((root.children[0] as DockSplit).children[0] as DockTabs).active = 2;
    final json = root.toJson();
    final back = DockNode.fromJson(json) as DockSplit;
    expect(back.toJson(), json);
    expect(((back.children[0] as DockSplit).children[0] as DockTabs).active, 2);
  });

  test('activatePanelTab fronts the tab that holds the panel', () {
    final root = defaultLayout();
    final left = (root.children[0] as DockSplit).children[0] as DockTabs;
    left.active = 3;
    activatePanelTab(root, Panel.project);
    expect(left.active, 0);
    // A panel not in any tab group is a no-op.
    activatePanelTab(root, Panel.viewer);
    expect(left.active, 0);
  });

  test('panel titles are the glossary names', () {
    expect(Panel.project.title, 'Project');
    expect(Panel.effectControls.title, 'Effect controls');
    expect(Panel.effectsAndPresets.title, 'Effects & presets');
  });

  group('panel visibility (the Window menu tick list)', () {
    test('hiding drops the panel and showing puts it back, fronted', () {
      final root = defaultLayout();
      expect(panelVisible(root, Panel.scopes), isTrue);

      setPanelVisible(root, Panel.scopes, false);
      expect(panelVisible(root, Panel.scopes), isFalse);
      expect(panelsIn(root).toSet().length, panelsIn(root).length,
          reason: 'no panel appears twice after a removal');

      setPanelVisible(root, Panel.scopes, true);
      expect(panelVisible(root, Panel.scopes), isTrue);
      // It went into a tab group, fronted — a panel you just asked for is the
      // one you want to look at.
      final tabs = panelsIn(root);
      expect(tabs.where((p) => p == Panel.scopes), hasLength(1));
    });

    test('asking for what is already so changes nothing', () {
      final root = defaultLayout();
      final before = root.toJson();
      setPanelVisible(root, Panel.viewer, true);
      setPanelVisible(root, Panel.debug, true);
      expect(root.toJson(), before);
    });

    test('the last panel standing cannot be hidden', () {
      final root = DockSplit(DockAxis.vertical, [DockPane(Panel.viewer)], [1.0]);
      setPanelVisible(root, Panel.viewer, false);
      expect(panelsIn(root), [Panel.viewer],
          reason: 'an empty dock has no way back');
    });

    test('a tree of bare panes still finds somewhere to put one', () {
      final root = DockSplit(
        DockAxis.vertical,
        [DockPane(Panel.viewer), DockPane(Panel.timeline)],
        [0.5, 0.5],
      );
      setPanelVisible(root, Panel.scopes, true);
      expect(panelVisible(root, Panel.scopes), isTrue);
      expect(root.shares.length, root.children.length);
    });
  });
}
