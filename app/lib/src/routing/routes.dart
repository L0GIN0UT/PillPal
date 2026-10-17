/// Route paths.
abstract final class AppRoutes {
  /// Shown while the stored session is read.
  static const String loading = '/loading';

  /// Onboarding: data region, then register or sign in.
  static const String welcome = '/auth';

  /// Registration form.
  static const String register = '/auth/register';

  /// E-mail verification code.
  static const String verify = '/auth/verify';

  /// Sign-in form.
  static const String login = '/auth/login';

  /// Today's doses (start screen).
  static const String today = '/today';

  /// Medication list.
  static const String medications = '/medications';

  /// New medication.
  static const String newMedication = '/add-medication';

  /// Relatives (Phase 3).
  static const String family = '/family';

  /// History and reports.
  static const String history = '/history';

  /// App settings.
  static const String settings = '/settings';

  /// Accepting an invite: pasted or opened link, preview, confirmation.
  static const String acceptInvite = '/family/accept';

  /// New managed profile.
  static const String newManagedProfile = '/family/managed/new';

  /// Restore of an account in its deletion grace period.
  static const String restore = '/auth/restore';

  /// New invite for profile [profileId].
  static String createInvite(String profileId) => '/family/invite/$profileId';

  /// Detail of link (grant) [linkId].
  static String link(String linkId) => '/family/link/$linkId';

  /// Edit managed profile [profileId].
  static String managedProfile(String profileId) =>
      '/family/managed/$profileId';

  /// Today of profile [profileId] (a relative's day view).
  static String profileToday(String profileId) => '/profile/$profileId/today';

  /// Medications of profile [profileId].
  static String profileMedications(String profileId) =>
      '/profile/$profileId/medications';

  /// History of profile [profileId].
  static String profileHistory(String profileId) =>
      '/profile/$profileId/history';

  /// New medication of profile [profileId].
  static String newProfileMedication(String profileId) =>
      '/profile/$profileId/add-medication';

  /// Edit medication [id].
  static String medication(String id) => '/medication/$id';

  /// New schedule of medication [medicationId].
  static String newSchedule(String medicationId) =>
      '/medication/$medicationId/schedule/new';

  /// Edit schedule [scheduleId] of medication [medicationId].
  static String schedule(String medicationId, String scheduleId) =>
      '/medication/$medicationId/schedule/$scheduleId';
}

/// Where the router sends a user, or null to stay at [location].
///
/// [signedIn] is null while the session is being read.
String? authRedirect({required bool? signedIn, required String location}) {
  final onAuth = location.startsWith(AppRoutes.welcome);
  if (signedIn == null) {
    return location == AppRoutes.loading ? null : AppRoutes.loading;
  }
  if (!signedIn) {
    return onAuth ? null : AppRoutes.welcome;
  }
  if (onAuth || location == AppRoutes.loading) {
    return AppRoutes.today;
  }
  return null;
}
