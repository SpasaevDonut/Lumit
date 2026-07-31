// The toolbar's state machine (K-214): which tool is armed, what a group button
// stands for, and what pressing a tool's key twice does.
//
// Pure state, so this needs no engine and no widgets — the parts of a toolbar
// that are easy to get subtly wrong (a group forgetting the variant you chose,
// a shortcut cycling when it should not) are all here rather than in the paint.

import 'package:flutter_test/flutter_test.dart';
import 'package:lumit_flutter/state/tools.dart';

void main() {
  group('Arming a tool', () {
    test('the session opens on the selection tool', () {
      expect(ToolsState().tool, ToolMode.select);
    });

    test('selecting notifies once, and re-selecting the armed tool does not',
        () {
      final tools = ToolsState();
      var notices = 0;
      tools.addListener(() => notices++);

      tools.select(ToolMode.pen);
      expect(tools.tool, ToolMode.pen);
      expect(notices, 1);

      tools.select(ToolMode.pen);
      expect(notices, 1, reason: 'nothing changed, so nothing redraws');
    });
  });

  group('Groups remember the variant you chose', () {
    test('a group button stands for its first member until one is picked', () {
      final tools = ToolsState();
      expect(tools.memberOf(ToolGroup.shape), ToolMode.shapeRectangle);

      tools.select(ToolMode.shapeStar);
      expect(tools.memberOf(ToolGroup.shape), ToolMode.shapeStar);
    });

    test('the memory survives arming another group and coming back', () {
      final tools = ToolsState()..select(ToolMode.penMaskFeather);
      tools.select(ToolMode.hand);

      tools.selectGroup(ToolGroup.pen);
      expect(tools.tool, ToolMode.penMaskFeather,
          reason: 'pressing the button gives back the tool you last had');
    });
  });

  group('A tool chord arms, then cycles', () {
    test('the first press arms the remembered member', () {
      final tools = ToolsState()..select(ToolMode.shapeEllipse);
      tools.select(ToolMode.select);

      tools.cycleGroup(ToolGroup.shape);
      expect(tools.tool, ToolMode.shapeEllipse);
    });

    test('pressing again steps through the group and wraps', () {
      final tools = ToolsState();
      final shapes = ToolMode.membersOf(ToolGroup.shape);
      expect(shapes.length, 5, reason: 'AE\'s five shape tools');

      tools.cycleGroup(ToolGroup.shape);
      for (var i = 1; i <= shapes.length; i++) {
        tools.cycleGroup(ToolGroup.shape);
        expect(tools.tool, shapes[i % shapes.length]);
      }
      expect(tools.tool, shapes.first, reason: 'a full lap comes home');
    });

    test('a group of one stays put however often its key is pressed', () {
      final tools = ToolsState();
      tools.cycleGroup(ToolGroup.hand);
      tools.cycleGroup(ToolGroup.hand);
      expect(tools.tool, ToolMode.hand);
    });
  });

  group('Keymap actions', () {
    test('every group has exactly one action, and every action a group', () {
      for (final group in ToolGroup.values) {
        expect(toolActions.values.where((g) => g == group).length, 1,
            reason: '$group needs one and only one chord to arm it');
      }
      // The ids are the engine's (docs/07 §15); a typo here would silently
      // leave a tool unreachable from the keyboard.
      for (final action in toolActions.keys) {
        expect(action, startsWith('tool.'));
      }
    });

    test('a tool action is handled and anything else is left alone', () {
      final tools = ToolsState();
      expect(tools.handleAction('tool.razor'), isTrue);
      expect(tools.tool, ToolMode.razor);

      expect(tools.handleAction('edit.undo'), isFalse);
      expect(tools.tool, ToolMode.razor, reason: 'and nothing moved');
    });
  });

  group('The tool set itself', () {
    test('every group has at least one tool, in declaration order', () {
      for (final group in ToolGroup.values) {
        final members = ToolMode.membersOf(group);
        expect(members, isNotEmpty, reason: '$group would be an empty button');
        expect(members.first.group, group);
      }
    });

    test('the tools that claim to be built are the ones that are', () {
      // A guard on honesty rather than on behaviour: `ready` is what the
      // tooltip promises, so it may only be true where something reads the
      // armed tool and does the work. Selection and Hand both pan the picture
      // today; everything else is a cursor and a place to build into.
      expect(ToolMode.values.where((t) => t.ready).toSet(),
          {ToolMode.select, ToolMode.hand});
    });
  });

  group('Snapping', () {
    test('it is on by default and toggles once per real change', () {
      final tools = ToolsState();
      var notices = 0;
      tools.addListener(() => notices++);

      expect(tools.snapping, isTrue);
      tools.snapping = false;
      tools.snapping = false;
      expect(tools.snapping, isFalse);
      expect(notices, 1);
    });
  });
}
