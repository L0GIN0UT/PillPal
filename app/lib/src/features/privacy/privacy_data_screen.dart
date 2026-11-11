import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/api/api_exception.dart';
import '../../data/api/consents_dto.dart';
import '../../data/config.dart';
import '../../routing/routes.dart';
import '../../theme/spacing.dart';
import '../common/banner_tone.dart';
import '../common/confirm_dialog.dart';
import '../common/formatters.dart';
import '../common/gap.dart';
import '../common/list_row.dart';
import '../common/local_time.dart';
import '../common/pillpal_banner.dart';
import '../common/pillpal_card.dart';
import '../common/section_header.dart';
import '../family/danger_text_button.dart';
import '../family/family_providers.dart';
import '../settings/delete_account_dialog.dart';
import '../settings/settings_account_card.dart';
import 'privacy_providers.dart';

/// «Приватность и данные» (board B2-SettingsData, ADR 0016 §4 and §8): the
/// consents the account has given with their date and version, the way to
/// withdraw them, and the export of the account's data.
///
/// Health data, terms and privacy are not withdrawn with a request: the health
/// switch opens the account deletion dialog (relatives, alerts and sync stop
/// at once and the data is erased within the grace period). The catalog
/// contribution is withdrawn here and shown only while a record of it is
/// active. The export row is shown when the server has the export on and the
/// account has a password to confirm it with (the app has no other sign-in
/// provider yet).
class PrivacyDataScreen extends ConsumerStatefulWidget {
  /// Creates the screen.
  const PrivacyDataScreen({super.key});

  @override
  ConsumerState<PrivacyDataScreen> createState() => _PrivacyDataScreenState();
}

class _PrivacyDataScreenState extends ConsumerState<PrivacyDataScreen> {
  bool _withdrawing = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final records = ref.watch(consentRecordsProvider);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.privacyDataTitle)),
      body: ListView(
        padding: PillPalSpacing.screen,
        children: [
          SectionHeader(
            l10n.privacyConsentsHeader,
            first: true,
            titleKey: const Key('privacy-consents-header'),
          ),
          records.when(
            data: _consents,
            loading: () => const Center(
              child: CircularProgressIndicator(key: Key('privacy-loading')),
            ),
            error: (error, stack) => _loadFailed(l10n),
          ),
          if (_exportOffered()) ...[
            SectionHeader(
              l10n.privacyDataHeader,
              titleKey: const Key('privacy-data-header'),
            ),
            PillPalCard.rows(
              rows: [
                PillPalListRow(
                  key: const Key('privacy-export'),
                  title: l10n.exportRowTitle,
                  subtitle:
                      l10n.exportRowHint(ExportPolicy.downloadWindowHours),
                  leadingIcon: Icons.archive_outlined,
                  onTap: () => unawaited(context.push(AppRoutes.dataExport)),
                ),
              ],
            ),
          ],
          const Gap.v(PillPalSpacing.xxl),
        ],
      ),
    );
  }

  /// The server has the export on and the account can confirm it. Unknown
  /// (offline) features mean off; an unknown account counts as one with a
  /// password, like the Settings account rows.
  bool _exportOffered() {
    final enabled = ref.watch(accountFeaturesProvider).valueOrNull;
    final hasPassword =
        ref.watch(settingsAccountProvider).valueOrNull?.hasPassword ?? true;
    return (enabled?.dataExportEnabled ?? false) && hasPassword;
  }

  Widget _loadFailed(AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PillPalBanner(
          key: const Key('privacy-load-failed'),
          tone: BannerTone.danger,
          body: l10n.privacyLoadFailed,
          liveRegion: true,
        ),
        const Gap.v(PillPalSpacing.md),
        OutlinedButton(
          key: const Key('privacy-retry'),
          onPressed: () => ref.invalidate(consentRecordsProvider),
          child: Text(l10n.privacyRetry),
        ),
      ],
    );
  }

  Widget _consents(ConsentsState state) {
    final l10n = AppLocalizations.of(context);
    final contribution = activeRecordOf(state, ConsentKind.catalogContribution);
    return PillPalCard.rows(
      rows: [
        _healthRow(l10n, activeRecordOf(state, ConsentKind.healthData)),
        _recordRow(
          l10n,
          key: const Key('privacy-terms'),
          title: l10n.consentTextTitleTerms,
          record: activeRecordOf(state, ConsentKind.terms),
        ),
        _recordRow(
          l10n,
          key: const Key('privacy-policy'),
          title: l10n.consentTextTitlePrivacy,
          record: activeRecordOf(state, ConsentKind.privacy),
        ),
        if (contribution != null) _contributionRow(l10n, contribution),
      ],
    );
  }

  /// "Given on 1 Nov 2026, version 1", or "Not given".
  String _given(AppLocalizations l10n, ConsentRecord? record) {
    if (record == null) {
      return l10n.privacyConsentNone;
    }
    final locale = Localizations.localeOf(context).toLanguageTag();
    final zone = ref.watch(deviceTimeZoneProvider);
    final day = localDateOf(record.acceptedAt, zone);
    return l10n.privacyConsentGiven(
      formatShortDate(day, locale),
      record.version,
    );
  }

  /// The switch that cannot be switched off here: it opens the deletion
  /// dialog, because withdrawing this consent is a deletion request.
  Widget _healthRow(AppLocalizations l10n, ConsentRecord? record) {
    return SwitchListTile(
      key: const Key('privacy-health'),
      value: record != null,
      onChanged: (_) => unawaited(_openDeletion()),
      title: Text(l10n.privacyHealthTitle),
      subtitle: Text(
        '${_given(l10n, record)}\n${l10n.privacyHealthHint}',
        key: const Key('privacy-health-text'),
      ),
    );
  }

  Widget _recordRow(
    AppLocalizations l10n, {
    required Key key,
    required String title,
    required ConsentRecord? record,
  }) {
    return PillPalListRow(
      key: key,
      title: title,
      subtitle: _given(l10n, record),
    );
  }

  Widget _contributionRow(AppLocalizations l10n, ConsentRecord record) {
    return PillPalListRow(
      key: const Key('privacy-contribution'),
      title: l10n.privacyContributionTitle,
      subtitle: '${l10n.privacyContributionHint}\n${_given(l10n, record)}',
      trailing: dangerTextButton(
        context,
        key: const Key('privacy-contribution-withdraw'),
        onPressed: _withdrawing ? null : _withdrawContribution,
        icon: Icons.undo,
        label: l10n.privacyContributionWithdraw,
      ),
    );
  }

  Future<void> _openDeletion() {
    return showDialog<void>(
      context: context,
      builder: (context) => DeleteAccountDialog(
        lead: AppLocalizations.of(context).privacyHealthWithdrawLead,
      ),
    );
  }

  Future<void> _withdrawContribution() async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await confirmAction(
      context,
      title: l10n.privacyContributionConfirmTitle,
      body: l10n.privacyContributionConfirmBody,
      confirmLabel: l10n.privacyContributionWithdraw,
    );
    if (!confirmed || !mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _withdrawing = true);
    try {
      final actions = ref.read(privacyActionsProvider);
      final reset = await actions.withdrawContribution();
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.privacyContributionWithdrawn(reset))),
      );
    } on ApiException {
      messenger.showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
    } on FormatException {
      messenger.showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
    } finally {
      if (mounted) {
        setState(() => _withdrawing = false);
      }
    }
  }
}
