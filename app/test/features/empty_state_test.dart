import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/l10n/gen/app_localizations.dart';
import 'package:pillpal/src/features/shell/empty_state.dart';
import 'package:pillpal/src/theme/app_theme.dart';
import 'package:pillpal/src/theme/palette.dart';

import '../support/ui_matrix.dart';

// EmptyState in the «Забота» look (board B2-EmptyMedications): a 96 soft disc
// with a 44 icon, a headline, a body and a primary and a secondary action.

Widget _host(Widget child) {
  return MaterialApp(
    theme: buildPillPalTheme(brightness: Brightness.light, senior: false),
    home: Scaffold(body: child),
  );
}

Widget _full({Key? key}) => EmptyState(
      key: key,
      icon: Icons.medication_outlined,
      headline: 'No medications yet',
      message: 'Add the first one by scanning the package.',
      action: FilledButton(
        key: const Key('primary'),
        onPressed: () {},
        child: const Text('Scan the package'),
      ),
      secondaryAction: OutlinedButton(
        key: const Key('secondary'),
        onPressed: () {},
        child: const Text('Add manually'),
      ),
    );

void main() {
  testWidgets('draws a 96 actionSoft disc with a 44 icon', (tester) async {
    await tester.pumpWidget(_host(_full()));

    const palette = PillPalPalette.light;
    final disc = find.byKey(const Key('empty-state-disc'));
    expect(
      tester.getSize(disc),
      const Size(PillPalSizes.emptyDisc, PillPalSizes.emptyDisc),
    );
    final decoration = tester.widget<DecoratedBox>(
      find.descendant(of: disc, matching: find.byType(DecoratedBox)),
    );
    expect((decoration.decoration as BoxDecoration).color, palette.actionSoft);
    expect(
        decoration.decoration,
        isA<BoxDecoration>().having(
          (box) => box.shape,
          'shape',
          BoxShape.circle,
        ));
    final icon = tester.widget<Icon>(find.byIcon(Icons.medication_outlined));
    expect(icon.size, PillPalSizes.iconEmpty);
    expect(icon.color, palette.onActionSoft);
  });

  testWidgets('shows the headline, the body and both actions full width',
      (tester) async {
    await tester.pumpWidget(_host(_full()));

    expect(find.text('No medications yet'), findsOneWidget);
    expect(find.text('Add the first one by scanning the package.'),
        findsOneWidget);
    final primary = tester.getSize(find.byKey(const Key('primary')));
    final secondary = tester.getSize(find.byKey(const Key('secondary')));
    expect(primary.width, secondary.width);
    expect(
      tester.getTopLeft(find.byKey(const Key('primary'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const Key('secondary'))).dy),
    );
    // The body is muted, the headline is the display style.
    expect(
      tester
          .widget<Text>(find.text('Add the first one by scanning the package.'))
          .style
          ?.color,
      PillPalPalette.light.inkMuted,
    );
  });

  testWidgets('the old parameters still work: message and one action',
      (tester) async {
    await tester.pumpWidget(
      _host(
        EmptyState(
          icon: Icons.group_outlined,
          message: 'Nobody here',
          action: TextButton(
            key: const Key('act'),
            onPressed: () {},
            child: const Text('Go'),
          ),
        ),
      ),
    );

    expect(find.text('Nobody here'), findsOneWidget);
    expect(find.byKey(const Key('act')), findsOneWidget);
    expect(find.byKey(const Key('secondary')), findsNothing);
  });

  testWidgets('two actions fit every cell of the matrix', (tester) async {
    await pumpUiMatrix(
      tester,
      (context) {
        final l10n = AppLocalizations.of(context);
        return SizedBox(
          width: MediaQuery.sizeOf(context).width,
          height: MediaQuery.sizeOf(context).height,
          child: EmptyState(
            icon: Icons.medication_outlined,
            headline: l10n.reminderPermissionNotificationsTitle,
            message: l10n.reminderPermissionNotificationsBody,
            action: FilledButton(
              onPressed: () {},
              child: Text(l10n.reminderPermissionAllow),
            ),
            secondaryAction: OutlinedButton(
              onPressed: () {},
              child: Text(l10n.reminderPermissionOpenSettings),
            ),
          ),
        );
      },
      expectTouchTargets: true,
    );
  });
}
