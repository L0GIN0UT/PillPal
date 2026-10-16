import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/gen/app_localizations.dart';
import 'routing/router.dart';
import 'settings/app_settings.dart';
import 'theme/app_theme.dart';

/// Root widget: theme, localisation and routing.
class PillPalApp extends ConsumerWidget {
  /// Creates the app.
  const PillPalApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
      debugShowCheckedModeBanner: false,
      theme: buildPillPalTheme(
        brightness: Brightness.light,
        senior: settings.seniorMode,
      ),
      darkTheme: buildPillPalTheme(
        brightness: Brightness.dark,
        senior: settings.seniorMode,
      ),
      themeMode: settings.themeMode,
      locale: settings.locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      routerConfig: router,
      builder: (context, child) => SeniorTextScale(
        enabled: settings.seniorMode,
        child: child ?? const SizedBox.shrink(),
      ),
    );
  }
}

/// Multiplies the system text scale in senior mode.
class SeniorTextScale extends StatelessWidget {
  /// Wraps [child]; does nothing unless [enabled].
  const SeniorTextScale({
    required this.enabled,
    required this.child,
    super.key,
  });

  /// Whether senior mode is on.
  final bool enabled;

  /// The subtree to scale.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!enabled) {
      return child;
    }
    final media = MediaQuery.of(context);
    const reference = 14.0;
    final systemFactor = media.textScaler.scale(reference) / reference;
    return MediaQuery(
      data: media.copyWith(
        textScaler: TextScaler.linear(
          systemFactor * PillPalSizes.seniorTextScale,
        ),
      ),
      child: child,
    );
  }
}
