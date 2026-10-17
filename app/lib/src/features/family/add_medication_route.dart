import '../../routing/routes.dart';
import 'profile_context.dart';

/// Where "+" on a profile's medications goes; null when the account may not
/// add medications there.
///
/// Fail closed: while the role on another profile is unknown ([access] null:
/// its scope has not arrived yet, or is gone) nothing can be added. The
/// account's own profile ([ownProfile]) is the exception: its scope arrives
/// with the first pull, and nothing of anyone else is at stake before it.
String? addMedicationRoute(
  ProfileAccess? access, {
  required bool ownProfile,
}) {
  if (access == null) {
    return ownProfile ? AppRoutes.newMedication : null;
  }
  if (access.isOwnSelf) {
    return AppRoutes.newMedication;
  }
  return access.canEditMedications
      ? AppRoutes.newProfileMedication(access.id)
      : null;
}
