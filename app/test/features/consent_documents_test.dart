import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/api/consents_dto.dart';
import 'package:pillpal/src/features/consent/consent_documents.dart';

void main() {
  for (final region in ['ru', 'eu']) {
    test('$region has every baseline kind with a version of 1 or more', () {
      final documents = ConsentDocuments.forRegion(region);
      expect(documents.keys.toSet(), ConsentKind.baseline.toSet());
      for (final document in documents.values) {
        expect(document.version, greaterThanOrEqualTo(1));
        expect(document.version, lessThanOrEqualTo(1000));
      }
    });

    test('$region offers no catalog contribution at registration', () {
      expect(
        ConsentDocuments.forRegion(region),
        isNot(contains(ConsentKind.catalogContribution)),
      );
    });

    test('$region grants are the baseline kinds with their versions', () {
      final grants = ConsentDocuments.grantsFor(region);
      expect(
        grants.map((grant) => grant.kind).toSet(),
        ConsentKind.baseline.toSet(),
      );
      for (final grant in grants) {
        expect(
          grant.version,
          ConsentDocuments.forRegion(region)[grant.kind]!.version,
        );
      }
    });
  }

  test('an unknown region falls back to the RU texts', () {
    expect(ConsentDocuments.forRegion('xx'), ConsentDocuments.forRegion('ru'));
  });
}
