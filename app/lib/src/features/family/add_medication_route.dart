import '../../routing/routes.dart';
import 'profile_context.dart';

/// The add route of [addRoute] that opens the barcode scanner at once (the
/// scan button of the medication list, docs/ui-pass-plan.md D4).
String scanEntryRoute(String addRoute) => '$addRoute?$scanQueryParameter=1';

/// Query parameter of the add routes that starts the scanner.
const String scanQueryParameter = 'scan';

/// Whether the add route at [uri] asks for the scanner.
bool wantsScan(Uri uri) => uri.queryParameters[scanQueryParameter] == '1';

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
