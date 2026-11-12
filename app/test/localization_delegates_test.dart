import 'dart:async';
import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/l10n/gen/app_localizations.dart';
import 'package:pillpal/src/localization_delegates.dart';

import 'helpers.dart';

// Flutter 3.50 moved Material and Cupertino to material_ui and cupertino_ui.
// The gen-l10n delegate list still localizes only the deprecated framework
// types, so without pillPalLocalizationsDelegates every material_ui and
// cupertino_ui string falls back to English.

/// The generated list, split so that this file does not match its own scan.
const String _generatedList = 'AppLocalizations' '.localizationsDelegates';

void main() {
  testWidgets('material_ui and cupertino_ui strings are Russian',
      (tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ru'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: pillPalLocalizationsDelegates,
        home: Builder(
          builder: (inner) {
            context = inner;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    final material = MaterialLocalizations.of(context);
    expect(material.backButtonTooltip, 'Назад');
    expect(material.cancelButtonLabel, isNot('Cancel'));
    expect(material.cancelButtonLabel, 'Отмена');

    final cupertino = CupertinoLocalizations.of(context);
    expect(cupertino.cutButtonLabel, isNot('Cut'));
    expect(cupertino.cutButtonLabel, 'Вырезать');
  });

  testWidgets('the app time picker cancels in Russian', (tester) async {
    await pumpApp(tester, locale: const Locale('ru'));

    unawaited(
      showTimePicker(
        context: tester.element(find.byType(NavigationBar)),
        initialTime: const TimeOfDay(hour: 8, minute: 0),
      ),
    );
    await tester.pumpAndSettle();

    final dialog = find.byType(TimePickerDialog);
    expect(dialog, findsOneWidget);
    String? label(Widget widget) =>
        widget is Text ? widget.data?.toLowerCase() : null;
    expect(
      find.descendant(
        of: dialog,
        matching: find.byWidgetPredicate((w) => label(w) == 'отмена'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: dialog,
        matching: find.byWidgetPredicate((w) => label(w) == 'cancel'),
      ),
      findsNothing,
    );
  });

  test('only the shared delegate list uses the generated one', () {
    const allowed = 'lib/src/localization_delegates.dart';
    final offenders = [
      for (final dir in const ['lib', 'test'])
        for (final entity in Directory(dir).listSync(recursive: true))
          if (entity is File && entity.path.endsWith('.dart'))
            entity.path.replaceAll(r'\', '/'),
    ].where((path) {
      if (path == allowed || path.startsWith('lib/l10n/gen/')) {
        return false;
      }
      return File(path).readAsStringSync().contains(_generatedList);
    }).toList();
    expect(
      offenders,
      isEmpty,
      reason: 'use pillPalLocalizationsDelegates: the generated list has no '
          'material_ui or cupertino_ui strings',
    );
  });
}
