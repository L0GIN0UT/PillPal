import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../routing/routes.dart';
import '../../theme/spacing.dart';
import '../catalog/catalog_providers.dart';
import '../common/banner_tone.dart';
import '../common/gap.dart';
import '../common/list_row.dart';
import '../common/pillpal_banner.dart';
import '../common/pillpal_card.dart';
import '../common/section_header.dart';
import '../reminders/reminder_permission_card.dart';
import '../reminders/reminder_settings_sections.dart';
import 'account_section.dart';
import 'change_password_controller.dart';
import 'delete_account_dialog.dart';
import 'settings_account_card.dart';
import 'settings_appearance_section.dart';

export 'settings_appearance_section.dart' show LanguageChoice;

/// Settings (boards B2-Settings, B2-SettingsData, TZ §2.6): the account, then
/// four groups of cards: appearance, reminders, privacy and data, account.
/// «Приватность и данные» holds the sync, the way to the privacy screen
/// (consents, export), «Мои отчёты» and the catalog sources; the promo code
/// comes with its own flow.
class SettingsScreen extends ConsumerWidget {
  /// Creates the screen.
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: ListView(
        padding: PillPalSpacing.screen,
        children: [
          const SettingsAccountCard(),
          SectionHeader(
            l10n.settingsGroupAppearance,
            titleKey: const Key('settings-group-appearance'),
          ),
          const SettingsAppearanceCard(),
          SectionHeader(
            l10n.settingsGroupReminders,
            titleKey: const Key('settings-group-reminders'),
          ),
          // Blocking permissions are danger, hints soft (the card decides).
          const ReminderPermissionCard(
            padding: EdgeInsets.only(bottom: PillPalSpacing.md),
          ),
          const ReminderDefaultsSection(),
          SectionHeader(
            l10n.settingsGroupData,
            titleKey: const Key('settings-group-data'),
          ),
          PillPalCard.rows(
            rows: [
              const SyncSection(),
              PillPalListRow(
                key: const Key('settings-privacy-data'),
                title: l10n.settingsPrivacyData,
                subtitle: l10n.settingsPrivacyDataHint,
                leadingIcon: Icons.shield_outlined,
                onTap: () => context.push(AppRoutes.privacyData),
              ),
              PillPalListRow(
                key: const Key('settings-reports'),
                title: l10n.settingsReports,
                subtitle: l10n.settingsReportsHint,
                leadingIcon: Icons.description_outlined,
                onTap: () => context.push(AppRoutes.reports),
              ),
              if (ref.watch(catalogEnabledProvider))
                PillPalListRow(
                  key: const Key('settings-catalog-sources'),
                  title: l10n.catalogSourcesTile,
                  subtitle: l10n.catalogSourcesTileHint,
                  leadingIcon: Icons.menu_book_outlined,
                  onTap: () => context.push(AppRoutes.catalogSources),
                ),
            ],
          ),
          SectionHeader(
            l10n.settingsGroupAccount,
            titleKey: const Key('settings-group-account'),
          ),
          if (ref.watch(passwordChangedNoticeProvider)) ...[
            PillPalBanner(
              key: const Key('change-password-done'),
              tone: BannerTone.info,
              icon: Icons.check_circle_outline,
              title: l10n.changePasswordDoneTitle,
              body: l10n.changePasswordDoneBody,
              liveRegion: true,
            ),
            const Gap.v(PillPalSpacing.md),
          ],
          PillPalCard.rows(
            rows: [
              // Unknown (offline) counts as "has a password": the server
              // refuses with `invalid_password` otherwise.
              if (ref.watch(settingsAccountProvider).valueOrNull?.hasPassword ??
                  true)
                const ChangePasswordRow(),
              const SignOutButton(),
              const DeleteAccountButton(),
            ],
          ),
          const Gap.v(PillPalSpacing.xxl),
        ],
      ),
    );
  }
}
