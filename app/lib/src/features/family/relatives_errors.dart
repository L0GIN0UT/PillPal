import '../../../l10n/gen/app_localizations.dart';
import '../auth/auth_errors.dart';

/// Error codes the app itself raises (not the server's).
abstract final class RelativesClientErrors {
  /// The server answered an invite link of a host this build does not serve.
  static const String untrustedInviteLink = 'untrusted_invite_link';
}

/// Localized text for an error [code] of the relatives endpoints (stable
/// codes of `backend/app/services/invites.py`, `grants.py`, `archives.py`);
/// others fall back to the account messages. Never shows the code itself.
String relativesErrorMessage(AppLocalizations l10n, String code) {
  switch (code) {
    case 'invite_invalid':
      return l10n.errorInviteInvalid;
    case RelativesClientErrors.untrustedInviteLink:
      return l10n.errorInviteLinkInvalid;
    case 'invite_expired':
      return l10n.errorInviteExpired;
    case 'invite_used':
      return l10n.errorInviteUsed;
    case 'invite_own_profile':
      return l10n.errorInviteOwnProfile;
    case 'already_linked':
      return l10n.errorAlreadyLinked;
    case 'relatives_limit_reached':
      return l10n.errorRelativesLimit;
    case 'too_many_invites':
      return l10n.errorTooManyInvites;
    case 'read_only':
      return l10n.errorReadOnlyProfile;
    default:
      return authErrorMessage(l10n, code);
  }
}
