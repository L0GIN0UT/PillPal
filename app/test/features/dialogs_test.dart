import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/l10n/gen/app_localizations.dart';
import 'package:pillpal/src/features/common/confirm_dialog.dart';
import 'package:pillpal/src/features/common/removal_dialog.dart';
import 'package:pillpal/src/localization_delegates.dart';
import 'package:pillpal/src/theme/app_theme.dart';
import 'package:pillpal/src/theme/palette.dart';
import 'package:pillpal/src/theme/radius.dart';

import '../support/ui_matrix.dart';

// The confirm and removal dialogs in the «Забота» look (redesign R2b): radius
// 28, a danger icon disc, a consequences list, full-width stacked buttons with
// the destructive one first.

Widget _host(Widget Function(BuildContext context) open) {
  return MaterialApp(
    theme: buildPillPalTheme(brightness: Brightness.light, senior: false),
    localizationsDelegates: pillPalLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: Builder(builder: open)),
  );
}

Widget _confirmHost({
  bool destructive = true,
  List<String> consequences = const [],
  void Function(bool result)? onResult,
}) {
  return _host(
    (context) => TextButton(
      key: const Key('ask'),
      onPressed: () async {
        final result = await confirmAction(
          context,
          title: 'Delete the profile?',
          body: 'It cannot be undone.',
          confirmLabel: 'Delete',
          destructive: destructive,
          consequences: consequences,
        );
        onResult?.call(result);
      },
      child: const Text('ask'),
    ),
  );
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('ask')));
  await tester.pumpAndSettle();
}

Color? _fill(WidgetTester tester, Key key) => tester
    .widget<ButtonStyleButton>(find.byKey(key))
    .style
    ?.backgroundColor
    ?.resolve(const {});

void main() {
  group('confirmAction', () {
    testWidgets('the destructive button is first, full width and danger',
        (tester) async {
      await tester.pumpWidget(_confirmHost());
      await _open(tester);

      final yes = find.byKey(const Key('confirm-yes'));
      final no = find.byKey(const Key('confirm-no'));
      expect(tester.getTopLeft(yes).dy, lessThan(tester.getTopLeft(no).dy));
      expect(tester.getSize(yes).width, tester.getSize(no).width);
      expect(
        tester.getSize(yes).width,
        tester.getSize(find.byType(SingleChildScrollView)).width,
      );
      expect(
        _fill(tester, const Key('confirm-yes')),
        PillPalPalette.light.danger,
      );
      expect(tester.widget(yes), isA<FilledButton>());
      expect(tester.widget(no), isA<OutlinedButton>());
    });

    testWidgets('has a danger icon disc and a 28 radius', (tester) async {
      await tester.pumpWidget(_confirmHost());
      await _open(tester);

      const palette = PillPalPalette.light;
      final disc = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byKey(const Key('dialog-icon')),
          matching: find.byType(DecoratedBox),
        ),
      );
      expect((disc.decoration as BoxDecoration).color, palette.dangerSoft);
      expect(
        tester.widget<Icon>(find.byIcon(Icons.warning_amber_rounded)).color,
        palette.onDangerSoft,
      );
      expect(
        tester.getSize(find.byKey(const Key('dialog-icon'))),
        const Size(48, 48),
      );
      final dialog = tester.widget<Material>(
        find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(
        (dialog.shape! as RoundedRectangleBorder).borderRadius,
        PillPalRadius.dialog,
      );
    });

    testWidgets('lists the consequences', (tester) async {
      await tester.pumpWidget(
        _confirmHost(consequences: const ['Doses are removed', 'Sync stops']),
      );
      await _open(tester);

      expect(find.text('Doses are removed'), findsOneWidget);
      expect(find.text('Sync stops'), findsOneWidget);
    });

    testWidgets('a non-destructive dialog is primary with no danger disc',
        (tester) async {
      await tester.pumpWidget(_confirmHost(destructive: false));
      await _open(tester);

      expect(find.byKey(const Key('dialog-icon')), findsNothing);
      expect(_fill(tester, const Key('confirm-yes')), isNull);
    });

    testWidgets('confirm returns true, cancel returns false', (tester) async {
      final results = <bool>[];
      await tester.pumpWidget(_confirmHost(onResult: results.add));

      await _open(tester);
      await tester.tap(find.byKey(const Key('confirm-no')));
      await tester.pumpAndSettle();
      await _open(tester);
      await tester.tap(find.byKey(const Key('confirm-yes')));
      await tester.pumpAndSettle();

      expect(results, [false, true]);
    });

    testWidgets('fits every cell of the matrix', (tester) async {
      await pumpUiMatrix(
        tester,
        (context) {
          final l10n = AppLocalizations.of(context);
          return TextButton(
            key: const Key('ask'),
            onPressed: () => confirmAction(
              context,
              title: l10n.deleteAccountTitle,
              body: l10n.signOutPendingBody(3),
              confirmLabel: l10n.signOut,
              consequences: [l10n.leaveProfileBody, l10n.revokeBody],
            ),
            child: const Text('ask'),
          );
        },
        check: (tester, cell) async {
          await tester.tap(find.byKey(const Key('ask')));
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('confirm-yes')), findsOneWidget);
          expectTouchTargetsOf(tester, cell);
          // Large text scrolls the dialog: bring the last button into view.
          await tester.ensureVisible(find.byKey(const Key('confirm-no')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('confirm-no')));
          await tester.pumpAndSettle();
        },
      );
    });
  });

  group('PillPalDialog narrow', () {
    testWidgets('three buttons at 320 px, RU, x2.0: no overflow, reachable',
        (tester) async {
      tester.view
        ..physicalSize = const Size(320, 568)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildPillPalTheme(brightness: Brightness.light, senior: false),
          locale: const Locale('ru'),
          localizationsDelegates: pillPalLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, app) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: app!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                key: const Key('ask'),
                onPressed: () => askRemoval(
                  context,
                  title: 'Удалить лекарство?',
                  plainBody: 'Это нельзя отменить.',
                  historyBody: 'История приёма будет удалена вместе с ним.',
                  hasHistory: true,
                  canFinish: true,
                ),
                child: const Text('ask'),
              ),
            ),
          ),
        ),
      );
      await _open(tester);

      expect(tester.takeException(), isNull);
      for (final key in [
        'confirm-delete',
        'confirm-finish',
        'removal-cancel'
      ]) {
        await tester.ensureVisible(find.byKey(Key(key)));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final rect = tester.getRect(find.byKey(Key(key)));
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(320));
      }
    });
  });

  group('askRemoval', () {
    Widget host(void Function(RemovalChoice? choice) onResult) => _host(
          (context) => TextButton(
            key: const Key('ask'),
            onPressed: () async => onResult(
              await askRemoval(
                context,
                title: 'Remove?',
                plainBody: 'plain',
                historyBody: 'history',
                hasHistory: true,
                canFinish: true,
              ),
            ),
            child: const Text('ask'),
          ),
        );

    testWidgets('stacks delete first, then finish, then cancel',
        (tester) async {
      await tester.pumpWidget(host((_) {}));
      await _open(tester);

      double top(String key) => tester.getTopLeft(find.byKey(Key(key))).dy;
      expect(top('confirm-delete'), lessThan(top('confirm-finish')));
      expect(top('confirm-finish'), lessThan(top('removal-cancel')));
      expect(
        _fill(tester, const Key('confirm-delete')),
        PillPalPalette.light.danger,
      );
      // Finishing keeps the history: it is not the danger button.
      expect(_fill(tester, const Key('confirm-finish')), isNull);
    });

    testWidgets('each button returns its choice', (tester) async {
      final results = <RemovalChoice?>[];
      await tester.pumpWidget(host(results.add));

      for (final key in [
        'removal-cancel',
        'confirm-finish',
        'confirm-delete',
      ]) {
        await _open(tester);
        await tester.tap(find.byKey(Key(key)));
        await tester.pumpAndSettle();
      }

      expect(results, [null, RemovalChoice.finish, RemovalChoice.delete]);
    });

    testWidgets('without history there is no finish button', (tester) async {
      await tester.pumpWidget(
        _host(
          (context) => TextButton(
            key: const Key('ask'),
            onPressed: () => askRemoval(
              context,
              title: 'Remove?',
              plainBody: 'plain',
              historyBody: 'history',
              hasHistory: false,
              canFinish: true,
            ),
            child: const Text('ask'),
          ),
        ),
      );
      await _open(tester);

      expect(find.byKey(const Key('confirm-finish')), findsNothing);
      expect(find.text('plain'), findsOneWidget);
    });
  });
}
