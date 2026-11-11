import 'package:intl/intl.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/db/database.dart';
import '../../data/repositories/profile_access.dart';
import '../common/formatters.dart';

// The words around a kept report, shared by the «Отчёт готов» sheet and the
// «Мои отчёты» list. Only dates, a size and the profile's name: never a
// medication or anything from the report itself (docs/adr/0019 §6).

const int _bytesPerKb = 1024;
const int _kbPerMb = 1024;

/// "1 – 11 Nov 2026": the period of [report].
String reportRangeLabel(
  AppLocalizations l10n,
  StoredReport report,
  String locale,
) {
  String day(String value) {
    final date = LocalDate.tryParse(value);
    return date == null ? value : formatShortDate(date, locale);
  }

  return l10n.reportRangeShort(day(report.firstDay), day(report.lastDay));
}

/// "84 KB" / "1.2 MB" (at least 1 KB).
String reportSizeLabel(AppLocalizations l10n, int bytes, String locale) {
  final kb = (bytes / _bytesPerKb).round();
  if (kb < _kbPerMb) {
    return l10n.reportSizeKb(kb < 1 ? 1 : kb);
  }
  final mb = NumberFormat('0.#', locale).format(kb / _kbPerMb);
  return l10n.reportSizeMb(mb);
}

/// When [report] was made, in the device's zone: "Nov 11, 20:04".
String reportCreatedLabel(StoredReport report, String locale) {
  final at = DateTime.fromMicrosecondsSinceEpoch(
    report.createdAt,
    isUtc: true,
  ).toLocal();
  return DateFormat.MMMd(locale).add_Hm().format(at);
}

/// Whose report it is: "Me" for the user's own profile, else the profile's
/// name; null while the profile is unknown (the list reconciles it away).
String? reportProfileLabel(
  AppLocalizations l10n,
  List<ProfileAccess>? profiles,
  String profileId,
) {
  for (final access in profiles ?? const <ProfileAccess>[]) {
    if (access.profile.id == profileId) {
      return access.isOwnSelf ? l10n.profileMe : access.profile.displayName;
    }
  }
  return null;
}
