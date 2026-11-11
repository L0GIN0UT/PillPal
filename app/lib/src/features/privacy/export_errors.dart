import 'dart:math' as math;

import '../../../l10n/gen/app_localizations.dart';
import '../../data/api/api_exception.dart';
import '../../data/api/export_dto.dart';
import '../auth/auth_errors.dart';
import '../auth/auth_flow_state.dart';

/// Localized text for an export error [code]: the server's, the export's own
/// client codes, or any auth code (a wrong password, no connection, an ended
/// session). [retryAfter] is the wait the server asked for on
/// `export_rate_limited`. Unknown codes get the generic message; the code
/// itself is never shown.
String exportErrorMessage(
  AppLocalizations l10n,
  String code, {
  Duration? retryAfter,
}) {
  switch (code) {
    case ExportErrors.rateLimited:
      if (retryAfter == null) {
        return l10n.exportErrorRateLimitedLater;
      }
      // At least a minute: "0 minutes" would be a lie.
      final minutes = math.max(1, (retryAfter.inSeconds / 60).ceil());
      return l10n.exportErrorRateLimited(minutes);
    case ExportErrors.tooLarge:
      return l10n.exportErrorTooLarge;
    case ExportErrors.buildFailed:
    case ExportErrors.failed:
      return l10n.exportErrorBuildFailed;
    case ExportErrors.gone:
      return l10n.exportErrorGone;
    case ExportClientErrors.transferLost:
      return l10n.exportErrorLost;
    case ExportClientErrors.stillBuilding:
      return l10n.exportErrorStillBuilding;
    case ExportErrors.featureDisabled:
      return l10n.exportErrorDisabled;
    case ApiException.storageError:
      return l10n.exportErrorStorage;
    case ApiException.unauthorized:
    case ApiException.invalidToken:
    case ApiException.accountChanged:
      return l10n.errorSessionEnded;
    case AuthClientErrors.generic:
      return l10n.errorGeneric;
    default:
      return authErrorMessage(l10n, code);
  }
}
