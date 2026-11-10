import 'package:flutter/material.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/spacing.dart';
import '../common/banner_tone.dart';
import '../common/gap.dart';
import '../common/pillpal_banner.dart';
import 'auth_errors.dart';

/// Common layout of the onboarding screens: title, subtitle, content.
class AuthScaffold extends StatelessWidget {
  /// Creates the layout.
  const AuthScaffold({
    required this.title,
    required this.children,
    this.subtitle,
    this.showBack = true,
    super.key,
  });

  /// Screen heading.
  final String title;

  /// Optional explanation under the heading.
  final String? subtitle;

  /// Body widgets.
  final List<Widget> children;

  /// Whether the app bar shows a back button.
  final bool showBack;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(automaticallyImplyLeading: showBack),
      body: SafeArea(
        child: ListView(
          padding: PillPalSpacing.form,
          children: [
            Text(title, style: textTheme.headlineLarge),
            if (subtitle != null) ...[
              const Gap.v(PillPalSpacing.sm),
              Text(subtitle!, style: textTheme.bodyLarge),
            ],
            const Gap.v(PillPalSpacing.xxl),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// Localized auth error in a danger banner; nothing when [code] is null.
class AuthErrorBanner extends StatelessWidget {
  /// Creates the banner.
  const AuthErrorBanner({required this.code, super.key});

  /// Error code to describe.
  final String? code;

  @override
  Widget build(BuildContext context) {
    final error = code;
    if (error == null) {
      return const SizedBox.shrink();
    }
    // A live region: screen readers announce the error when it appears.
    return Padding(
      padding: const EdgeInsets.only(bottom: PillPalSpacing.lg),
      child: PillPalBanner(
        key: const Key('auth-error'),
        tone: BannerTone.danger,
        liveRegion: true,
        body: authErrorMessage(AppLocalizations.of(context), error),
      ),
    );
  }
}

/// A soft notice (no error), e.g. about data kept on the device.
class AuthNotice extends StatelessWidget {
  /// Creates the notice.
  const AuthNotice({required this.text, super.key});

  /// Notice text.
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: PillPalSpacing.lg),
      child: PillPalBanner(
        tone: BannerTone.info,
        icon: Icons.info_outline,
        body: text,
      ),
    );
  }
}

/// Full-width primary button that shows progress while [busy].
class BusyButton extends StatelessWidget {
  /// Creates the button.
  const BusyButton({
    required this.label,
    required this.onPressed,
    required this.busy,
    super.key,
  });

  /// Button text.
  final String label;

  /// Action; disabled while [busy].
  final VoidCallback onPressed;

  /// A request is running.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: busy ? null : onPressed,
      child: busy
          ? const SizedBox.square(
              dimension: PillPalSpacing.xxl,
              child: CircularProgressIndicator(strokeWidth: 3),
            )
          : Text(label),
    );
  }
}
