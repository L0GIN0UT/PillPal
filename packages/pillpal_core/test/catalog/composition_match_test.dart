import 'package:pillpal_core/pillpal_core.dart';
import 'package:test/test.dart';

const profileA = 'profile-a';
const profileB = 'profile-b';
const compositionX = 'composition-x';
const compositionY = 'composition-y';

CompositionCandidate candidate({
  String profileId = profileA,
  String? compositionId = compositionX,
  bool complete = true,
  Set<String> substanceIds = const {'s1'},
}) {
  return CompositionCandidate(
    profileId: profileId,
    compositionId: compositionId,
    complete: complete,
    substanceIds: substanceIds,
  );
}

MedicationComposition med(
  String id, {
  String profileId = profileA,
  String? compositionId = compositionX,
  bool complete = true,
  Set<String> substanceIds = const {'s1'},
  Set<String> manualSubstanceIds = const {},
}) {
  return MedicationComposition(
    medicationId: id,
    profileId: profileId,
    compositionId: compositionId,
    complete: complete,
    catalogSubstanceIds: substanceIds,
    manualSubstanceIds: manualSubstanceIds,
  );
}

void main() {
  group('sameComposition', () {
    test('returns medications with the same complete composition', () {
      final meds = [
        med('m1'),
        med('m2', compositionId: compositionY),
        med('m3'),
      ];
      expect(sameComposition(candidate(), meds), ['m1', 'm3']);
    });

    test('an incomplete composition is never the same', () {
      final meds = [med('m1', complete: false), med('m2')];
      final result = sameComposition(candidate(complete: false), meds);
      expect(result, isEmpty);
    });

    test('an incomplete stored composition is never the same', () {
      final meds = [med('m1', complete: false)];
      expect(sameComposition(candidate(), meds), isEmpty);
    });

    test('a candidate without a composition matches nothing', () {
      final meds = [med('m1', compositionId: null)];
      expect(sameComposition(candidate(compositionId: null), meds), isEmpty);
    });

    test('medications of another profile are ignored', () {
      final meds = [med('m1', profileId: profileB)];
      expect(sameComposition(candidate(), meds), isEmpty);
    });

    test('the edited medication itself is excluded', () {
      final meds = [med('m1'), med('m2')];
      final result = sameComposition(
        candidate(),
        meds,
        excludeMedicationId: 'm1',
      );
      expect(result, ['m2']);
    });
  });

  group('substanceOverlap', () {
    test('lists shared catalog substance ids per medication', () {
      final meds = [
        med('m1', compositionId: compositionY, substanceIds: {'s2', 's3'}),
        med('m2', compositionId: compositionY, substanceIds: {'s9'}),
      ];
      final result = substanceOverlap(
        candidate(substanceIds: {'s1', 's2'}),
        meds,
      );
      expect(result, hasLength(1));
      expect(result.single.medicationId, 'm1');
      expect(result.single.substanceIds, {'s2'});
    });

    test('manual substance ids count', () {
      final meds = [
        med(
          'm1',
          compositionId: null,
          substanceIds: const {},
          manualSubstanceIds: {'s5'},
        ),
      ];
      final result = substanceOverlap(candidate(substanceIds: {'s5'}), meds);
      expect(result.single.substanceIds, {'s5'});
    });

    test('works for incomplete compositions', () {
      final meds = [
        med('m1', complete: false, substanceIds: {'s1'})
      ];
      final result = substanceOverlap(candidate(complete: false), meds);
      expect(result, hasLength(1));
    });

    test('medications of another profile are ignored', () {
      final meds = [med('m1', profileId: profileB)];
      expect(substanceOverlap(candidate(), meds), isEmpty);
    });

    test('no shared substance gives nothing', () {
      final meds = [
        med('m1', substanceIds: {'s7'})
      ];
      expect(substanceOverlap(candidate(), meds), isEmpty);
    });

    test('the edited medication itself is excluded', () {
      final meds = [med('m1')];
      final result = substanceOverlap(
        candidate(),
        meds,
        excludeMedicationId: 'm1',
      );
      expect(result, isEmpty);
    });

    test('allSubstanceIds merges catalog and manual ids', () {
      final merged = med('m1', manualSubstanceIds: {'s2'}).allSubstanceIds;
      expect(merged, {'s1', 's2'});
    });
  });
}
