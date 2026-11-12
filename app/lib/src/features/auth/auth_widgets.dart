import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/providers.dart';
import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/spacing.dart';
import '../common/banner_tone.dart';
import '../common/clamped_text.dart';
import '../common/gap.dart';
import '../common/pillpal_banner.dart';
import '../common/stacked_buttons.dart';
import 'auth_errors.dart';
import 'auth_flow_state.dart';

/// Common layout of the onboarding screens (B2 boards Welcome, SignIn,
/// Register): a scrolling part with an optional step indicator, the title, the
/// subtitle and the content, and the primary action pinned below it so it is
/// in reach with the keyboard closed however large the text (B2-README
/// section 9.6).
class AuthScaffold extends StatelessWidget {
  /// Creates the layout.
  const AuthScaffold({
    required this.title,
    required this.children,
    this.subtitle,
    this.showBack = true,
    this.header,
    this.stepNumber,
    this.stepCount,
    this.pinnedNotice,
    this.actions = const [],
    super.key,
  }) : assert(
          (stepNumber == null) == (stepCount == null),
          'a step needs both its number and the count',
        );

  /// Screen heading.
  final String title;

  /// Optional explanation under the heading.
  final String? subtitle;

  /// Body widgets.
  final List<Widget> children;

  /// Whether the app bar shows a back button; without it there is no app bar
  /// (the welcome screen).
  final bool showBack;

  /// A block above the title (the brand of the welcome screen).
  final Widget? header;

  /// Which step of the registration this is («Step N of M»), if any.
  final int? stepNumber;

  /// How many steps the registration has.
  final int? stepCount;

  /// A notice pinned above the buttons (an error that must stay in view
  /// however far the content is scrolled).
  final Widget? pinnedNotice;

  /// Buttons pinned to the bottom, the primary one first.
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final step = stepNumber;
    final count = stepCount;
    return Scaffold(
      appBar: showBack ? AppBar() : null,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: PillPalSpacing.form,
                children: [
                  if (header != null) ...[
                    header!,
                    const Gap.v(PillPalSpacing.huge),
                  ],
                  if (step != null && count != null) ...[
                    _StepLine(number: step, count: count),
                    const Gap.v(PillPalSpacing.xs),
                  ],
                  Semantics(
                    header: true,
                    child: ClampedText(
                      title,
                      maxScale: PillPalSizes.titleMaxScale,
                      style: textTheme.displaySmall,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const Gap.v(PillPalSpacing.sm),
                    Text(
                      subtitle!,
                      style: textTheme.bodyLarge
                          ?.copyWith(color: context.palette.inkMuted),
                    ),
                  ],
                  const Gap.v(PillPalSpacing.xxl),
                  ...children,
                ],
              ),
            ),
            if (actions.isNotEmpty)
              Padding(
                padding: PillPalSpacing.pinnedActions,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (pinnedNotice != null) _pinned(context),
                    StackedButtons(children: actions),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// The pinned notice in its own scroll, at most a part of the screen high,
  /// so an error and a reason at a large text size never push the buttons
  /// off screen.
  Widget _pinned(BuildContext context) {
    final maxHeight =
        MediaQuery.sizeOf(context).height * PillPalSizes.stickyBarMaxFraction;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: SingleChildScrollView(child: pinnedNotice),
    );
  }
}

/// «Step N of M» above the title, read as one phrase.
class _StepLine extends StatelessWidget {
  const _StepLine({required this.number, required this.count});

  final int number;
  final int count;

  @override
  Widget build(BuildContext context) {
    final text = AppLocalizations.of(context).stepOf(number, count);
    return Semantics(
      label: text,
      excludeSemantics: true,
      child: Text(
        text,
        style: Theme.of(context)
            .textTheme
            .labelMedium
            ?.copyWith(color: context.palette.inkMuted),
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
    final message = error == null
        ? null
        : authErrorMessage(AppLocalizations.of(context), error);
    // The live region stays in the tree, empty without an error: screen
    // readers announce a change of an existing live region, not one that
    // appears together with its text. It carries the text itself, so the
    // banner below is hidden from semantics to avoid reading it twice.
    return Semantics(
      liveRegion: true,
      container: true,
      label: message,
      child: message == null
          ? const SizedBox.shrink()
          : ExcludeSemantics(
              child: Padding(
                padding: const EdgeInsets.only(bottom: PillPalSpacing.lg),
                child: PillPalBanner(
                  key: const Key('auth-error'),
                  tone: BannerTone.danger,
                  body: message,
                ),
              ),
            ),
    );
  }
}

/// A soft notice (no error), e.g. about data kept on the device.
class AuthNotice extends StatelessWidget {
  /// Creates the notice.
  const AuthNotice({required this.text, this.icon, super.key});

  /// Notice text.
  final String text;

  /// Icon; the info icon when null.
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: PillPalSpacing.lg),
      child: PillPalBanner(
        tone: BannerTone.info,
        icon: icon,
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
    this.enabled = true,
    this.disabledReason,
    super.key,
  });

  /// Button text.
  final String label;

  /// Action; disabled while [busy] or not [enabled].
  final VoidCallback onPressed;

  /// A request is running.
  final bool busy;

  /// Whether the form is complete enough to submit (the consents are ticked).
  final bool enabled;

  /// Why the button is off; read as its hint while it is off. The visible
  /// text is [AuthDisabledReason], pinned above the buttons.
  final String? disabledReason;

  @override
  Widget build(BuildContext context) {
    final button = FilledButton(
      onPressed: busy || !enabled ? null : onPressed,
      child: busy
          ? const SizedBox.square(
              dimension: PillPalSizes.spinner,
              child: CircularProgressIndicator(strokeWidth: 3),
            )
          : Text(label),
    );
    final reason = disabledReason;
    return reason == null || enabled
        ? button
        : Semantics(hint: reason, child: button);
  }
}

/// Why the primary button is off («Tick all three items to continue»), above
/// the pinned buttons. Its space stays reserved once the button is on, so the
/// layout does not jump; a screen reader announces the change.
class AuthDisabledReason extends StatelessWidget {
  /// Creates the line; [textKey] marks the visible text.
  const AuthDisabledReason({
    required this.text,
    required this.visible,
    this.textKey,
    super.key,
  });

  /// The reason.
  final String text;

  /// Whether the button is off.
  final bool visible;

  /// Key of the visible text.
  final Key? textKey;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context)
        .textTheme
        .bodyMedium
        ?.copyWith(color: context.palette.inkMuted);
    return Padding(
      padding: const EdgeInsets.only(bottom: PillPalSpacing.sm),
      child: Semantics(
        liveRegion: true,
        child: Visibility(
          visible: visible,
          maintainSize: true,
          maintainAnimation: true,
          maintainState: true,
          child: Text(
            text,
            key: visible ? textKey : null,
            textAlign: TextAlign.center,
            style: style,
          ),
        ),
      ),
    );
  }
}

/// «Send the code again» for the code screens (verify, reset). After a
/// successful request the label says so and further taps are ignored for
/// [AuthLimits.resendCooldown]; the server rate limit stays the real guard.
class AuthResendButton extends ConsumerStatefulWidget {
  /// Creates the button; [onResend] returns whether the code was sent.
  const AuthResendButton({
    required this.buttonKey,
    required this.busy,
    required this.onResend,
    super.key,
  });

  /// Key of the button (the journeys and tests find it).
  final Key buttonKey;

  /// A request is in flight: the button is off.
  final bool busy;

  /// Asks the server for a new code.
  final Future<bool> Function() onResend;

  @override
  ConsumerState<AuthResendButton> createState() => _AuthResendButtonState();
}

class _AuthResendButtonState extends ConsumerState<AuthResendButton> {
  bool _resent = false;
  DateTime? _sentAt;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return TextButton(
      key: widget.buttonKey,
      onPressed: widget.busy ? null : _resend,
      child: Text(_resent ? l10n.codeResent : l10n.resendCode),
    );
  }

  Future<void> _resend() async {
    final now = ref.read(clockProvider)();
    final last = _sentAt;
    if (last != null && now.difference(last) < AuthLimits.resendCooldown) {
      return;
    }
    setState(() => _resent = false);
    final sent = await widget.onResend();
    if (!mounted) {
      return;
    }
    setState(() {
      _resent = sent;
      if (sent) {
        _sentAt = now;
      }
    });
  }
}
