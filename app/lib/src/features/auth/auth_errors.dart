import '../../../l10n/gen/app_localizations.dart';
import '../../data/api/api_exception.dart';
import 'auth_flow.dart';

/// Localized text for an auth error [code] (server codes from
/// `backend/app/services/auth.py`, client codes from [AuthClientErrors]).
/// Unknown codes get a generic message; the code itself is never shown.
String authErrorMessage(AppLocalizations l10n, String code) {
  switch (code) {
    case 'invalid_credentials':
      return l10n.errorInvalidCredentials;
    case 'email_not_verified':
      return l10n.errorEmailNotVerified;
    case 'invalid_password':
      return l10n.errorInvalidPassword;
    case 'invalid_token':
      return l10n.errorRestoreFailed;
    case 'invalid_code':
      return l10n.errorInvalidCode;
    case 'rate_limited':
      return l10n.errorRateLimited;
    case 'wrong_region':
      return l10n.errorWrongRegion;
    case 'validation_error':
      return l10n.errorValidation;
    case ApiException.networkError:
      return l10n.errorNetwork;
    case AuthClientErrors.invalidEmail:
      return l10n.errorInvalidEmail;
    case AuthClientErrors.passwordTooShort:
      return l10n.errorPasswordTooShort(AuthLimits.passwordMin);
    case AuthClientErrors.passwordTooLong:
      return l10n.errorPasswordTooLong(AuthLimits.passwordMax);
    case AuthClientErrors.invalidCode:
      return l10n.errorCodeFormat(AuthLimits.codeLength);
    default:
      return l10n.errorGeneric;
  }
}
