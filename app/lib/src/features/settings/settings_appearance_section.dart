import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../settings/app_settings.dart';
import '../../theme/spacing.dart';
import '../common/card_control_block.dart';
import '../common/pillpal_card.dart';
import '../common/pillpal_segmented.dart';

/// Language choice in settings; `system` follows the device.
enum LanguageChoice {
  /// Follow the device language.
  system,

  /// Russian.
  ru,

  /// English.
  en,
}

/// The «Вид» card (board B2-Settings): the senior-mode switch, then the theme
/// and the language as segmented controls. A control whose labels would wrap
/// to three lines (Russian at x2.0 on a 320 px phone) becomes a radio list on
/// its own (B2-README 9).
class SettingsAppearanceCard extends ConsumerWidget {
  /// Creates the card.
  const SettingsAppearanceCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final settings = ref.watch(settingsProvider);
    final controller = ref.read(settingsProvider.notifier);
    return PillPalCard.rows(
      rows: [
        SwitchListTile(
          key: const Key('settings-senior-mode'),
          contentPadding: PillPalSpacing.cardRowSide,
          title: Text(l10n.settingsSeniorMode),
          subtitle: Text(l10n.settingsSeniorModeHint),
          value: settings.seniorMode,
          onChanged: (enabled) => controller.setSeniorMode(enabled: enabled),
        ),
        CardControlBlock(
          label: l10n.settingsTheme,
          child: PillPalSegmented<ThemeMode>(
            key: const Key('settings-theme'),
            selected: settings.themeMode,
            onChanged: controller.setThemeMode,
            keyOf: (mode) => ValueKey('theme-${mode.name}'),
            options: {
              ThemeMode.system: l10n.themeSystem,
              ThemeMode.light: l10n.themeLight,
              ThemeMode.dark: l10n.themeDark,
            },
          ),
        ),
        CardControlBlock(
          label: l10n.settingsLanguage,
          child: PillPalSegmented<LanguageChoice>(
            key: const Key('settings-language'),
            selected: _choiceOf(settings.locale),
            onChanged: (choice) => controller.setLocale(_localeOf(choice)),
            keyOf: (choice) => ValueKey('language-${choice.name}'),
            options: {
              LanguageChoice.system: l10n.languageSystem,
              // Endonyms: a language is named in itself, never translated.
              LanguageChoice.ru: 'Русский',
              LanguageChoice.en: 'English',
            },
          ),
        ),
      ],
    );
  }

  static LanguageChoice _choiceOf(Locale? locale) =>
      switch (locale?.languageCode) {
        'ru' => LanguageChoice.ru,
        'en' => LanguageChoice.en,
        _ => LanguageChoice.system,
      };

  static Locale? _localeOf(LanguageChoice choice) => switch (choice) {
        LanguageChoice.system => null,
        LanguageChoice.ru => const Locale('ru'),
        LanguageChoice.en => const Locale('en'),
      };
}
