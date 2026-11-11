import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/api/consents_dto.dart';
import '../../data/providers.dart';
import '../../routing/routes.dart';
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
    final documents = _documents(ref.watch(apiConfigProvider).region);
    final complete = _complete;
    // Back (or the system gesture) leaves the registration: the held
    // credentials are dropped, the form starts again.
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          ref.read(authFlowProvider.notifier).abandonRegistration();
        }
      },
      child: AuthScaffold(
        title: l10n.consentTitle,
        subtitle: l10n.consentSubtitle,
        stepNumber: RegistrationStep.consent.number,
        stepCount: RegistrationStep.total,
        // Pinned, so an error is seen and announced wherever the list is
        // scrolled.
        pinnedNotice: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AuthErrorBanner(
              code:
                  documents == null ? AuthClientErrors.generic : flow.errorCode,
            ),
            AuthDisabledReason(
              text: l10n.consentSubmitHint,
              visible: !complete,
              textKey: const Key('consent-hint'),
            ),
          ],
        ),
        actions: [
          BusyButton(
            key: const Key('consent-submit'),
            label: l10n.consentSubmit,
            busy: flow.busy,
            enabled: documents != null && complete,
            disabledReason: l10n.consentSubmitHint,
            onPressed: _submit,
          ),
        ],
        children: [
          if (documents != null)
            ConsentChecklist(
              documents: documents,
              accepted: _accepted,
              onChanged: _toggle,
            ),
        ],
      ),
    );
  }

  /// The texts of [region], or null for a build of a region that has none
  /// (the screen then says so and cannot register).
  Map<ConsentKind, ConsentDocument>? _documents(String region) {
    try {
      return ConsentDocuments.forRegion(region);
    } on UnknownConsentRegion {
      return null;
    }
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
