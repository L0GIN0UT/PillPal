import 'package:flutter/material.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/palette.dart';
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
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            Text(title, style: textTheme.headlineLarge),
            if (subtitle != null) ...[
              const SizedBox(height: 8),
              Text(subtitle!, style: textTheme.bodyLarge),
            ],
            const SizedBox(height: 24),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// Localized auth error in a soft banner; nothing when [code] is null.
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
    final palette = context.palette;
    // A live region: screen readers announce the error when it appears.
    return Semantics(
      liveRegion: true,
      container: true,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Container(
          key: const Key('auth-error'),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: palette.actionSoft,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Icon(Icons.error_outline, color: palette.onActionSoft),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  authErrorMessage(AppLocalizations.of(context), error),
                  style: TextStyle(color: palette.onActionSoft),
                ),
              ),
            ],
          ),
        ),
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
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: palette.surface,
          border: Border.all(color: palette.missed, width: 2),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, color: palette.missed),
            const SizedBox(width: 12),
            Expanded(child: Text(text)),
          ],
        ),
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
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 3),
            )
          : Text(label),
    );
  }
}
