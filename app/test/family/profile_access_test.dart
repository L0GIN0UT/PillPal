import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/data/repositories/profile_access.dart';

ProfileAccess _access(
  String role, {
  String kind = 'self',
  bool archived = false,
  DateTime? purgeAfter,
}) {
  return ProfileAccess(
    profile: ProfileRow(
      id: 'p1',
      kind: kind,
      displayName: 'Test',
      timezone: 'Europe/Berlin',
      clientUpdatedAt: 1,
      updatedByDevice: 'd',
      missedAlertMinutes: 30,
      missedAlertsEnabled: true,
    ),
    role: role,
    archived: archived,
    archivePurgeAfter: purgeAfter,
  );
}

void main() {
  group('role matrix (ADR 0005 §2, D3)', () {
    test('owner and guardian do everything on a live profile', () {
      for (final role in [ScopeRole.owner, ScopeRole.guardian]) {
        final access = _access(role, kind: 'managed');
        expect(access.canMarkDoses, isTrue, reason: role);
        expect(access.canEditMedications, isTrue, reason: role);
        expect(access.canDelete, isTrue, reason: role);
        expect(access.canChangePrivacy, isTrue, reason: role);
        expect(access.canEditProfile, isTrue, reason: role);
        expect(access.mayRemind, isTrue, reason: role);
        expect(
          access.canEditMedication(privacy: 'hidden', redacted: false),
          isTrue,
          reason: role,
        );
      }
    });

    test('only the owner manages links; everyone else may leave', () {
      expect(_access(ScopeRole.owner).canManageLinks, isTrue);
      expect(_access(ScopeRole.owner).canLeave, isFalse);
      for (final role in [
        ScopeRole.guardian,
        ScopeRole.editor,
        ScopeRole.viewer,
      ]) {
        expect(_access(role).canManageLinks, isFalse, reason: role);
        expect(_access(role).canLeave, isTrue, reason: role);
      }
    });

    test('an editor edits shared medications only and never marks or deletes',
        () {
      final editor = _access(ScopeRole.editor);
      expect(editor.canMarkDoses, isFalse);
      expect(editor.canDelete, isFalse);
      expect(editor.canChangePrivacy, isFalse);
      expect(editor.canEditProfile, isFalse);
      expect(editor.mayRemind, isFalse);
      expect(editor.canEditMedications, isTrue);
      expect(
        editor.canEditMedication(privacy: 'shared', redacted: false),
        isTrue,
      );
      for (final privacy in ['anonymous', 'hidden']) {
        expect(
          editor.canEditMedication(privacy: privacy, redacted: false),
          isFalse,
          reason: privacy,
        );
      }
      // A redacted row hides the privacy level it came with.
      expect(
        editor.canEditMedication(privacy: 'shared', redacted: true),
        isFalse,
      );
    });

    test('a viewer changes nothing', () {
      final viewer = _access(ScopeRole.viewer);
      expect(viewer.canMarkDoses, isFalse);
      expect(viewer.canEditMedications, isFalse);
      expect(viewer.canDelete, isFalse);
      expect(
        viewer.canEditMedication(privacy: 'shared', redacted: false),
        isFalse,
      );
    });

    test('an archive is read-only for everyone', () {
      for (final role in [ScopeRole.owner, ScopeRole.guardian]) {
        final archive = _access(role, kind: 'managed', archived: true);
        expect(archive.canMarkDoses, isFalse, reason: role);
        expect(archive.canEditMedications, isFalse, reason: role);
        expect(archive.canDelete, isFalse, reason: role);
        expect(archive.canEditProfile, isFalse, reason: role);
        expect(archive.canManageLinks, isFalse, reason: role);
        expect(archive.mayRemind, isFalse, reason: role);
      }
    });

    test('an archive can be purged only after its owner was erased', () {
      final pending = _access(ScopeRole.guardian, archived: true);
      expect(pending.canPurgeArchive, isFalse);
      final erased = _access(
        ScopeRole.guardian,
        archived: true,
        purgeAfter: DateTime.utc(2026, 12),
      );
      expect(erased.canPurgeArchive, isTrue);
      // A live profile has nothing to purge.
      expect(
        _access(ScopeRole.owner, purgeAfter: DateTime.utc(2026, 12))
            .canPurgeArchive,
        isFalse,
      );
    });
  });

  group('zone rule (D4)', () {
    test('the own profile follows the device, every other its own zone', () {
      final own = _access(ScopeRole.owner);
      expect(own.isOwnSelf, isTrue);
      expect(own.localZone('Asia/Tokyo'), 'Asia/Tokyo');

      final ward = _access(ScopeRole.owner, kind: 'managed');
      expect(ward.isOwnSelf, isFalse);
      expect(ward.localZone('Asia/Tokyo'), 'Europe/Berlin');

      // A relative's self profile (a guardian role on a self profile or a
      // viewer) is never "mine".
      expect(
        _access(ScopeRole.viewer).localZone('Asia/Tokyo'),
        'Europe/Berlin',
      );
    });
  });
}
