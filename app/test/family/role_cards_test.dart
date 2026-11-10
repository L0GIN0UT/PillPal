import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/features/family/role_cards.dart';

import '../features/common/common_test_host.dart';

// The roles of an invite or a link as radio cards: title and what the role
// may do, the whole card taps (board B2-InviteCreate).

void main() {
  Widget cards(String selected, ValueChanged<String> onSelected) => RoleCards(
        roles: const ['viewer', 'editor'],
        selected: selected,
        onSelected: onSelected,
        keyPrefix: 'invite-role',
      );

  testWidgets('every role has a keyed card with its hint', (tester) async {
    await pumpThemed(tester, cards('viewer', (_) {}));

    expect(find.byKey(const ValueKey('invite-role-viewer')), findsOneWidget);
    expect(find.byKey(const ValueKey('invite-role-editor')), findsOneWidget);
    expect(find.text('Viewer'), findsOneWidget);
    expect(find.text('Editor'), findsOneWidget);
    expect(find.textContaining('Cannot change anything'), findsOneWidget);
  });

  testWidgets('the card is a radio: mark, semantics and tap', (tester) async {
    final handle = tester.ensureSemantics();
    final picked = <String>[];
    await pumpThemed(tester, cards('viewer', picked.add));

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('invite-role-viewer')),
        matching: find.byIcon(Icons.radio_button_checked),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('invite-role-editor')),
        matching: find.byIcon(Icons.radio_button_unchecked),
      ),
      findsOneWidget,
    );
    final node = tester.getSemantics(
      find.byKey(const ValueKey('invite-role-viewer')),
    );
    expect(
      node,
      matchesSemantics(
        label: 'Viewer\n'
            'Sees "Family" medications and their intake status. '
            'Cannot change anything.',
        isButton: true,
        isInMutuallyExclusiveGroup: true,
        isChecked: true,
        hasCheckedState: true,
        hasTapAction: true,
      ),
    );

    await tester.tap(find.byKey(const ValueKey('invite-role-editor')));
    expect(picked, ['editor']);
    handle.dispose();
  });
}
