import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../settings/app_settings.dart';
import '../common/choice_button.dart';
import '../reminders/reminder_settings_sections.dart';
import 'account_section.dart';

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
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(l10n.settingsTheme, style: textTheme.titleSmall),
          const SizedBox(height: 8),
          // Wrapping chips instead of a segmented control: labels must
          // fit with senior-mode text.
          _Choices<ThemeMode>(
            selected: settings.themeMode,
            onSelected: controller.setThemeMode,
            options: {
              ThemeMode.system: l10n.themeSystem,
              ThemeMode.light: l10n.themeLight,
              ThemeMode.dark: l10n.themeDark,
            },
          ),
          const SizedBox(height: 24),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.settingsSeniorMode),
            subtitle: Text(l10n.settingsSeniorModeHint),
            value: settings.seniorMode,
            onChanged: (enabled) => controller.setSeniorMode(enabled: enabled),
          ),
          const SizedBox(height: 24),
          Text(l10n.settingsLanguage, style: textTheme.titleSmall),
          const SizedBox(height: 8),
          _Choices<LanguageChoice>(
            selected: _choiceOf(settings.locale),
            onSelected: (choice) => controller.setLocale(_localeOf(choice)),
            options: {
              LanguageChoice.system: l10n.languageSystem,
              LanguageChoice.ru: 'Русский',
              LanguageChoice.en: 'English',
            },
          ),
          const SizedBox(height: 24),
          const ReminderDefaultsSection(),
          const Divider(height: 32),
          const SyncSection(),
          const Divider(height: 32),
          const SignOutButton(),
        ],
      ),
    );
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

class _Choices<T> extends StatelessWidget {
  const _Choices({
    required this.selected,
    required this.onSelected,
    required this.options,
  });

  final T selected;
  final ValueChanged<T> onSelected;
  final Map<T, String> options;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final entry in options.entries)
          ChoiceButton(
            label: entry.value,
            selected: entry.key == selected,
            onTap: () => onSelected(entry.key),
          ),
      ],
    );
  }
}
