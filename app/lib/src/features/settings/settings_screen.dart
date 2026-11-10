import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../routing/routes.dart';
import '../../settings/app_settings.dart';
import '../../theme/spacing.dart';
import '../catalog/catalog_providers.dart';
import '../common/choice_group.dart';
import '../common/gap.dart';
import '../common/group_label.dart';
import '../reminders/reminder_settings_sections.dart';
import 'account_section.dart';
import 'delete_account_dialog.dart';

/// Language choice in settings; `system` follows the device.
enum LanguageChoice {
  /// Follow the device language.
  system,

  /// Russian.
  ru,

  /// English.
  en,
}

/// Theme, senior mode, language, reminders, sync and sign-out.
class SettingsScreen extends ConsumerWidget {
  /// Creates the screen.
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final settings = ref.watch(settingsProvider);
    final controller = ref.read(settingsProvider.notifier);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: ListView(
        padding: const EdgeInsets.all(PillPalSpacing.xl),
        children: [
          ..._appearance(l10n, settings, controller),
          const Gap.v(PillPalSpacing.xxl),
          GroupLabel(l10n.settingsLanguage),
          ChoiceGroup<LanguageChoice>(
            selected: _choiceOf(settings.locale),
            onSelected: (choice) => controller.setLocale(_localeOf(choice)),
            options: {
              LanguageChoice.system: l10n.languageSystem,
              LanguageChoice.ru: 'Русский',
              LanguageChoice.en: 'English',
            },
          ),
          const Gap.v(PillPalSpacing.xxl),
          const ReminderDefaultsSection(),
          const Divider(height: PillPalSpacing.xxxl),
          const SyncSection(),
          const Divider(height: PillPalSpacing.xxxl),
          if (ref.watch(catalogEnabledProvider)) ...[
            ListTile(
              key: const Key('settings-catalog-sources'),
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.catalogSourcesTile),
              subtitle: Text(l10n.catalogSourcesTileHint),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push(AppRoutes.catalogSources),
            ),
            const Divider(height: PillPalSpacing.xxxl),
          ],
          const SignOutButton(),
          const Gap.v(PillPalSpacing.md),
          const DeleteAccountButton(),
        ],
      ),
    );
  }

  /// Theme and senior mode.
  List<Widget> _appearance(
    AppLocalizations l10n,
    AppSettings settings,
    SettingsController controller,
  ) {
    return [
      GroupLabel(l10n.settingsTheme),
      ChoiceGroup<ThemeMode>(
        selected: settings.themeMode,
        onSelected: controller.setThemeMode,
        options: {
          ThemeMode.system: l10n.themeSystem,
          ThemeMode.light: l10n.themeLight,
          ThemeMode.dark: l10n.themeDark,
        },
      ),
      const Gap.v(PillPalSpacing.xxl),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(l10n.settingsSeniorMode),
        subtitle: Text(l10n.settingsSeniorModeHint),
        value: settings.seniorMode,
        onChanged: (enabled) => controller.setSeniorMode(enabled: enabled),
      ),
    ];
  }

  static LanguageChoice _choiceOf(Locale? locale) {
    switch (locale?.languageCode) {
      case 'ru':
        return LanguageChoice.ru;
      case 'en':
        return LanguageChoice.en;
      default:
        return LanguageChoice.system;
    }
  }

  static Locale? _localeOf(LanguageChoice choice) {
    switch (choice) {
      case LanguageChoice.system:
        return null;
      case LanguageChoice.ru:
        return const Locale('ru');
      case LanguageChoice.en:
        return const Locale('en');
    }
  }
}
