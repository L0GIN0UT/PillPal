import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/api/consents_dto.dart';
import '../../data/providers.dart';
import '../../routing/routes.dart';
import '../../theme/palette.dart';
import '../../theme/spacing.dart';
import '../common/gap.dart';
import '../consent/consent_checklist.dart';
import '../consent/consent_documents.dart';
import 'auth_flow.dart';
import 'auth_widgets.dart';

/// Step 2 of 3 of the registration (B2-Consent, ADR 0016 §3): the terms, the
/// privacy policy and, in a card of its own, the health data consent, each
/// ticked separately. «Create account» registers with these three consents
/// and leads to the code step; it stays off until all three are ticked.
class RegistrationConsentScreen extends ConsumerStatefulWidget {
  /// Creates the screen.
  const RegistrationConsentScreen({super.key});

  @override
  ConsumerState<RegistrationConsentScreen> createState() =>
      _RegistrationConsentScreenState();
}

class _RegistrationConsentScreenState
    extends ConsumerState<RegistrationConsentScreen> {
  final Set<ConsentKind> _accepted = {};

  bool get _complete =>
      ConsentKind.baseline.every((kind) => _accepted.contains(kind));

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final flow = ref.watch(authFlowProvider);
    final region = ref.watch(apiConfigProvider).region;
    return AuthScaffold(
      title: l10n.consentTitle,
      subtitle: l10n.consentSubtitle,
      stepNumber: RegistrationStep.consent.number,
      stepCount: RegistrationStep.total,
      actions: [
        BusyButton(
          key: const Key('consent-submit'),
          label: l10n.consentSubmit,
          busy: flow.busy,
          enabled: _complete,
          onPressed: _submit,
        ),
      ],
      children: [
        AuthErrorBanner(code: flow.errorCode),
        ConsentChecklist(
          documents: ConsentDocuments.forRegion(region),
          accepted: _accepted,
          onChanged: _toggle,
        ),
        if (!_complete) ...[
          const Gap.v(PillPalSpacing.lg),
          Text(
            l10n.consentSubmitHint,
            key: const Key('consent-hint'),
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: context.palette.inkMuted),
          ),
        ],
      ],
    );
  }

  void _toggle(ConsentKind kind, {required bool value}) {
    ref.read(authFlowProvider.notifier).clearError();
    setState(() {
      if (value) {
        _accepted.add(kind);
      } else {
        _accepted.remove(kind);
      }
    });
  }

  Future<void> _submit() async {
    if (!_complete || ref.read(authFlowProvider).busy) {
      return;
    }
    final locale = Localizations.localeOf(context).languageCode;
    final sent =
        await ref.read(authFlowProvider.notifier).register(locale: locale);
    if (sent) {
      // Offers the password manager to save the new credentials: the account
      // exists now (the fields of step 1 are still under this screen).
      TextInput.finishAutofillContext();
    }
    if (sent && mounted) {
      // The account exists now: back must not return to a step that has
      // nothing left to send.
      context.pushReplacement(AppRoutes.verify);
    }
  }
}
