/// Route paths.
abstract final class AppRoutes {
  /// Shown while the stored session is read.
  static const String loading = '/loading';

  /// Onboarding: data region, then register or sign in.
  static const String welcome = '/auth';

  /// Registration form.
  static const String register = '/auth/register';

  /// Registration step 2: the consent texts; «Create account» registers.
  static const String registerConsent = '/auth/register/consent';

  /// E-mail verification code.
  static const String verify = '/auth/verify';

  /// Sign-in form.
  static const String login = '/auth/login';

  /// Password reset, step 1: the address the code is mailed to.
  static const String forgotPassword = '/auth/forgot';

  /// Password reset, step 2: the mailed code and the new password.
  static const String resetPassword = '/auth/reset';

  /// The blocking consent screen of an account the server lacks consents of
  /// (ADR 0016 §5); every other screen redirects here until they are given.
  static const String consentGate = '/consent';

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

  /// Change of the password with a mailed code (Settings, Account).
  static const String changePassword = '/settings/password';

  /// Where the medication catalog's data comes from (Phase 4).
  static const String catalogSources = '/settings/catalog-sources';

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
/// [signedIn] is null while the session is being read. With
/// [consentRequired] a signed-in user can reach nothing but the consent screen
/// (deep links and notification taps included); without it the consent screen
/// leads to Today. While the consent answer is not known yet
/// ([consentPending]) a signed-in user stays on the loading screen, so
/// neither Today nor a deep link shows for a frame before the gate.
String? authRedirect({
  required bool? signedIn,
  required String location,
  bool consentRequired = false,
  bool consentPending = false,
}) {
  final onAuth = location.startsWith(AppRoutes.welcome);
  if (signedIn == null) {
    return location == AppRoutes.loading ? null : AppRoutes.loading;
  }
  if (!signedIn) {
    return onAuth ? null : AppRoutes.welcome;
  }
  if (consentPending) {
    return location == AppRoutes.loading ? null : AppRoutes.loading;
  }
  if (consentRequired) {
    return location == AppRoutes.consentGate ? null : AppRoutes.consentGate;
  }
  if (onAuth ||
      location == AppRoutes.loading ||
      location == AppRoutes.consentGate) {
    return AppRoutes.today;
  }
  return null;
}
