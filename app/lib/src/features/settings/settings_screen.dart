import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../settings/app_settings.dart';

/// Language choice in settings; `system` follows the device.
enum LanguageChoice {
  /// Follow the device language.
  system,

  /// Russian.
  ru,

  /// English.
  en,
}

/// Theme, senior mode and language.
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
          SegmentedButton<ThemeMode>(
            segments: [
              ButtonSegment(
                value: ThemeMode.system,
                label: Text(l10n.themeSystem),
              ),
              ButtonSegment(
                value: ThemeMode.light,
                label: Text(l10n.themeLight),
              ),
              ButtonSegment(
                value: ThemeMode.dark,
                label: Text(l10n.themeDark),
              ),
            ],
            selected: {settings.themeMode},
            onSelectionChanged: (selection) =>
                controller.setThemeMode(selection.first),
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
          SegmentedButton<LanguageChoice>(
            segments: [
              ButtonSegment(
                value: LanguageChoice.system,
                label: Text(l10n.languageSystem),
              ),
              const ButtonSegment(
                value: LanguageChoice.ru,
                label: Text('Русский'),
              ),
              const ButtonSegment(
                value: LanguageChoice.en,
                label: Text('English'),
              ),
            ],
            selected: {_choiceOf(settings.locale)},
            onSelectionChanged: (selection) =>
                controller.setLocale(_localeOf(selection.first)),
          ),
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
