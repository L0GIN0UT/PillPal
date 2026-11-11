import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/api/consents_dto.dart';
import '../../data/providers.dart';
import '../auth/auth_flow_state.dart';
import '../../theme/spacing.dart';
import '../auth/auth_widgets.dart';
import '../common/gap.dart';
import '../settings/account_section.dart';
import '../settings/delete_account_dialog.dart';
import 'consent_checklist.dart';
import 'consent_documents.dart';
import 'consent_gate_controller.dart';

/// The blocking consent screen for an account the server still lacks consents
/// of (B2-Consent adapted, ADR 0016 §5): accounts that predate consents, a
/// new version of a text, or an account restored after a deletion request.
/// It lists only what is missing, each text ticked on its own. There is no
/// way past it except accepting, signing out or deleting the account; while
/// the health data consent is missing the medical sync is paused and says so.
class ConsentGateScreen extends ConsumerStatefulWidget {
  /// Creates the screen.
  const ConsentGateScreen({super.key});

  @override
  ConsumerState<ConsentGateScreen> createState() => _ConsentGateScreenState();
}

class _ConsentGateScreenState extends ConsumerState<ConsentGateScreen> {
  final Set<ConsentKind> _accepted = {};

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final gate = ref.watch(consentGateProvider);
    final missing = ref.watch(consentMissingProvider).valueOrNull ?? const [];
    final texts = _regionTexts(ref.watch(apiConfigProvider).region);
    final documents = texts == null ? null : _missingDocuments(texts, missing);
    // A kind the app has no text for cannot be ticked: only an update helps.
    final unknownKind = texts != null && documents == null;
    final paused = ref.watch(medicalSyncPausedProvider);
    final blocked = gate.outdated || documents == null;
    final complete = documents != null &&
        documents.isNotEmpty &&
        documents.keys.every(_accepted.contains);
    return PopScope(
      // The gate is the whole app until it is passed: back does not leave it.
      canPop: false,
      child: AuthScaffold(
        title: l10n.consentGateTitle,
        subtitle: l10n.consentGateSubtitle,
        showBack: false,
        pinnedNotice: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AuthErrorBanner(
              code: texts == null
                  ? AuthClientErrors.generic
                  : gate.errorCode ??
                      (gate.outdated || unknownKind
                          ? AuthClientErrors.consentOutdated
                          : null),
            ),
            AuthDisabledReason(
              text: l10n.consentGateHint,
              visible: !complete && !blocked,
              textKey: const Key('consent-gate-hint'),
            ),
          ],
        ),
        actions: [
          BusyButton(
            key: const Key('consent-gate-submit'),
            label: l10n.consentGateSubmit,
            busy: gate.busy,
            enabled: complete && !blocked,
            disabledReason: l10n.consentGateHint,
            onPressed: _submit,
          ),
        ],
        children: [
          if (paused)
            AuthNotice(
              key: const Key('consent-gate-paused'),
              text: l10n.consentGatePaused,
            ),
          if (documents != null)
            ConsentChecklist(
              documents: documents,
              accepted: _accepted,
              onChanged: _toggle,
            ),
          // The ways out are in the list, not pinned: three pinned buttons
          // would not fit at the largest text size, and the primary one must.
          const Gap.v(PillPalSpacing.xxl),
          TextButton(
            key: const Key('consent-gate-sign-out'),
            onPressed: gate.busy
                ? null
                : () => unawaited(
                      confirmSignOut(context, ref, syncPaused: paused),
                    ),
            child: Text(l10n.signOut),
          ),
          TextButton(
            key: const Key('consent-gate-delete'),
            onPressed: gate.busy
                ? null
                : () => unawaited(
                      showDialog<void>(
                        context: context,
                        builder: (context) => const DeleteAccountDialog(),
                      ),
                    ),
            child: Text(l10n.deleteAccount),
          ),
        ],
      ),
    );
  }

  /// The texts of [region], or null for a build of a region that has none.
  Map<ConsentKind, ConsentDocument>? _regionTexts(String region) {
    try {
      return ConsentDocuments.forRegion(region);
    } on UnknownConsentRegion {
      return null;
    }
  }

  /// The texts of the [missing] kinds, or null when one of them has no text
  /// in this build (a server newer than the app).
  Map<ConsentKind, ConsentDocument>? _missingDocuments(
    Map<ConsentKind, ConsentDocument> texts,
    List<String> missing,
  ) {
    final result = <ConsentKind, ConsentDocument>{};
    for (final wire in missing) {
      final kind = ConsentKind.tryParse(wire);
      final document = kind == null ? null : texts[kind];
      if (kind == null || document == null) {
        return null;
      }
      result[kind] = document;
    }
    return result;
  }

  void _toggle(ConsentKind kind, {required bool value}) {
    setState(() {
      if (value) {
        _accepted.add(kind);
      } else {
        _accepted.remove(kind);
      }
    });
  }

  Future<void> _submit() async {
    if (ref.read(consentGateProvider).busy) {
      return;
    }
    // A kind that was recorded earlier has left the list: send only the ticks
    // of what is still shown.
    final shown = ref.read(consentMissingProvider).valueOrNull ?? const [];
    final kinds = {
      for (final wire in shown)
        if (ConsentKind.tryParse(wire) case final kind?
            when _accepted.contains(kind))
          kind,
    };
    await ref.read(consentGateProvider.notifier).accept(kinds);
  }
}
