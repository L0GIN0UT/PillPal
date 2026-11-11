import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/l10n/gen/app_localizations.dart';
import 'package:pillpal/src/features/common/pillpal_segmented.dart';
import 'package:pillpal/src/features/reminders/reminder_level_picker.dart';
import 'package:pillpal/src/reminders/reminder_settings.dart';
import 'package:pillpal_core/pillpal_core.dart';

// D3 (docs/redesign-plan.md): three segments plus a separate alarm switch,
// a UI-only mapping onto the unchanged `ReminderLevel`.

final _start = ReminderSettings(
  level: ReminderLevel.normal,
  repeatEveryMinutes: 30,
  maxRepeats: 5,
);

/// Pumps the picker with [initial] and records every emitted value.
Future<List<ReminderSettings>> _pump(
  WidgetTester tester,
  ReminderSettings initial,
) async {
  final emitted = <ReminderSettings>[];
  var value = initial;
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Scaffold(
        body: SingleChildScrollView(
          child: StatefulBuilder(
            builder: (context, setState) => ReminderLevelPicker(
              value: value,
              onChanged: (next) => setState(() {
                value = next;
                emitted.add(next);
              }),
            ),
          ),
        ),
      ),
    ),
  );
  return emitted;
}

Finder _segment(String level) => find.byKey(ValueKey('reminder-level-$level'));

Finder get _alarm => find.byKey(const ValueKey('reminder-level-alarm'));

ReminderLevel _shown(WidgetTester tester) => tester
    .widget<PillPalSegmented<ReminderLevel>>(
      find.byType(PillPalSegmented<ReminderLevel>),
    )
    .selected;

bool _alarmOn(WidgetTester tester) =>
    tester.widget<SwitchListTile>(_alarm).value;

Future<void> _tapSegment(WidgetTester tester, String level) async {
  await tester.tap(_segment(level));
  await tester.pumpAndSettle();
}

Future<void> _toggleAlarm(WidgetTester tester) async {
  await tester.tap(_alarm);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('offers three segments and the alarm switch, no 4th segment',
      (tester) async {
    await _pump(tester, _start);

    for (final level in ['quiet', 'normal', 'persistent']) {
      expect(_segment(level), findsOneWidget);
    }
    expect(find.byType(SwitchListTile), findsOneWidget);
    expect(_alarm, findsOneWidget);
    expect(find.text('Repeats with the alarm sound'), findsOneWidget);
    expect(_alarmOn(tester), isFalse);
    expect(_shown(tester), ReminderLevel.normal);
  });

  group('D3 mapping table', () {
    testWidgets('switch on -> alarm; the segment shows persistent',
        (tester) async {
      final emitted = await _pump(tester, _start);

      await _toggleAlarm(tester);

      expect(emitted.single.level, ReminderLevel.alarm);
      expect(_alarmOn(tester), isTrue);
      expect(_shown(tester), ReminderLevel.persistent);
    });

    testWidgets('switch off -> persistent', (tester) async {
      final emitted = await _pump(
        tester,
        _start.copyWith(level: ReminderLevel.alarm),
      );

      await _toggleAlarm(tester);

      expect(emitted.single.level, ReminderLevel.persistent);
      expect(_alarmOn(tester), isFalse);
      expect(_shown(tester), ReminderLevel.persistent);
    });

    for (final (key, level) in [
      ('quiet', ReminderLevel.quiet),
      ('normal', ReminderLevel.normal),
    ]) {
      testWidgets('$key while alarm -> $key and the switch turns off',
          (tester) async {
        final emitted = await _pump(
          tester,
          _start.copyWith(level: ReminderLevel.alarm),
        );
        expect(_shown(tester), ReminderLevel.persistent);

        await _tapSegment(tester, key);

        expect(emitted.single.level, level);
        expect(_alarmOn(tester), isFalse);
        expect(_shown(tester), level);
      });
    }

    testWidgets('persistent while alarm keeps the alarm', (tester) async {
      final emitted = await _pump(
        tester,
        _start.copyWith(level: ReminderLevel.alarm),
      );

      await _tapSegment(tester, 'persistent');

      expect(emitted.every((v) => v.level == ReminderLevel.alarm), isTrue);
      expect(_alarmOn(tester), isTrue);
    });

    testWidgets('persistent from normal is persistent, switch off',
        (tester) async {
      final emitted = await _pump(tester, _start);

      await _tapSegment(tester, 'persistent');

      expect(emitted.single.level, ReminderLevel.persistent);
      expect(_alarmOn(tester), isFalse);
    });
  });

  group('the stored settings equal what the 4-option picker emitted', () {
    // The old picker emitted `value.copyWith(level: level)` for the tapped
    // level; N, M and enabled stayed as they were.
    for (final level in ReminderLevel.values) {
      testWidgets('choice ${level.name}', (tester) async {
        // Start from a level that differs from the target.
        final from = level == ReminderLevel.normal
            ? ReminderLevel.quiet
            : ReminderLevel.normal;
        final emitted = await _pump(tester, _start.copyWith(level: from));

        if (level == ReminderLevel.alarm) {
          await _toggleAlarm(tester);
        } else {
          await _tapSegment(tester, level.name);
        }

        expect(emitted.last, _start.copyWith(level: level));
        expect(emitted.last.repeatEveryMinutes, 30);
        expect(emitted.last.maxRepeats, 5);
      });
    }
  });

  group('N and M', () {
    for (final level in ReminderLevel.values) {
      testWidgets(
          'are ${level.repeats ? 'visible' : 'hidden'} for '
          '${level.name}', (tester) async {
        await _pump(tester, _start.copyWith(level: level));

        final matcher = level.repeats ? findsOneWidget : findsNothing;
        expect(find.byKey(const ValueKey('reminder-interval-30')), matcher);
        expect(find.byKey(const ValueKey('reminder-repeats-5')), matcher);
      });
    }

    testWidgets('edit N and M without changing the level', (tester) async {
      final emitted = await _pump(
        tester,
        _start.copyWith(level: ReminderLevel.alarm),
      );

      for (final key in ['reminder-interval-15', 'reminder-repeats-10']) {
        final chip = find.byKey(ValueKey(key));
        await tester.ensureVisible(chip);
        await tester.tap(chip);
        await tester.pumpAndSettle();
      }

      expect(
        emitted.last,
        ReminderSettings(
          level: ReminderLevel.alarm,
          repeatEveryMinutes: 15,
          maxRepeats: 10,
        ),
      );
    });
  });
}
