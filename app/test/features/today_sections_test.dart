import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/features/doses/dose_status.dart';
import 'package:pillpal/src/features/doses/scheduled_doses.dart';
import 'package:pillpal/src/features/today/today_state.dart';

import '../support/today_fixtures.dart';

List<String> _times(Iterable<ScheduledDose> doses) =>
    [for (final dose in doses) dose.occurrence.localTime];

void main() {
  group('todaySections', () {
    test('splits the day into hero, next and earlier, in time order', () {
      final sections = todaySections(fixtureDay());

      // "Now" is 10:00: the 09:50 dose is snoozed, not yet missed.
      expect(sections.hero?.occurrence.localTime, '09:50');
      expect(_times(sections.upcoming), ['20:00']);
      expect(_times(sections.past), ['07:00', '08:00']);
    });

    test('every dose appears exactly once; the hero is not repeated', () {
      final state = fixtureDay();
      final sections = todaySections(state);

      final keys = [
        if (sections.hero != null) sections.hero!.occurrence.key,
        for (final dose in sections.upcoming) dose.occurrence.key,
        for (final dose in sections.past) dose.occurrence.key,
      ];
      expect(keys.length, state.doses.length);
      expect(keys.toSet(), {for (final d in state.doses) d.occurrence.key});
    });

    test('the hero is the dose to take now, never a missed one', () {
      final state = fixtureState([
        fixtureDose('08:00', DoseStatus.missed),
        fixtureDose('20:00', DoseStatus.pending),
      ]);

      final sections = todaySections(state);

      expect(sections.hero?.occurrence.localTime, '20:00');
      expect(_times(sections.past), ['08:00']);
      expect(sections.upcoming, isEmpty);
    });

    test('a dose that is only due later is the hero when none is due', () {
      final state = fixtureState([
        fixtureDose('07:00', DoseStatus.taken),
        fixtureDose('18:00', DoseStatus.pending),
        fixtureDose('21:00', DoseStatus.pending),
      ]);

      final sections = todaySections(state);

      expect(sections.hero?.occurrence.localTime, '18:00');
      expect(_times(sections.upcoming), ['21:00']);
    });

    test('no hero when nothing is pending; missed stays among the earlier', () {
      final state = fixtureState([
        fixtureDose('07:00', DoseStatus.taken),
        fixtureDose('08:00', DoseStatus.missed),
        fixtureDose('09:00', DoseStatus.skipped),
      ]);

      final sections = todaySections(state);

      expect(sections.hero, isNull);
      expect(sections.upcoming, isEmpty);
      expect(_times(sections.past), ['07:00', '08:00', '09:00']);
    });

    test('without a hero (a relative who may not mark) all open doses wait',
        () {
      final sections = todaySections(fixtureDay(), withHero: false);

      expect(sections.hero, isNull);
      expect(_times(sections.upcoming), ['09:50', '20:00']);
      expect(_times(sections.past), ['07:00', '08:00']);
    });

    test('an empty day has no sections', () {
      final sections = todaySections(fixtureState(const []));

      expect(sections.hero, isNull);
      expect(sections.upcoming, isEmpty);
      expect(sections.past, isEmpty);
    });
  });
}
