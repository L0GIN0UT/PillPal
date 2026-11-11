import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/api/consents_dto.dart';
import '../../data/providers.dart';
import '../../theme/app_theme.dart';
import '../../theme/spacing.dart';
import '../auth/auth_flow_state.dart';
import '../auth/auth_widgets.dart';
import '../common/gap.dart';
import '../common/show_pillpal_dialog.dart';
import '../family/danger_text_button.dart';
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
///
/// Three layouts: the list of missing texts; a progress indicator while the
/// list is empty (not loaded yet, or just cleared); and a blocked one when
/// the server asks for a text this app does not have, where only an update
/// helps. The ways out are in the scrolling list in all of them.
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
    final gate = ref.watch(consentGateProvider);
    final missing = ref.watch(consentMissingProvider).valueOrNull ?? const [];
    final texts = _regionTexts(ref.watch(apiConfigProvider).region);
    final documents = texts == null ? null : _missingDocuments(texts, missing);
    final paused = ref.watch(medicalSyncPausedProvider);
    // A text the app does not have (a server newer than the app, or a region
    // without texts) cannot be ticked: only an update helps.
    final Widget body;
    if (gate.outdated || documents == null) {
      body = _blocked(context, gate, paused);
    } else if (documents.isEmpty) {
      body = _loading(context, gate);
    } else {
      body = _list(context, gate, paused, documents);
    }
    return PopScope(
      // The gate is the whole app until it is passed: back does not leave it.
      canPop: false,
      child: body,
    );
  }

  Widget _list(
    BuildContext context,
    ConsentGateState gate,
    bool paused,
    Map<ConsentKind, ConsentDocument> documents,
  ) {
    final l10n = AppLocalizations.of(context);
    final complete = documents.keys.every(_accepted.contains);
    final until = gate.retryUntil;
    final waiting = until != null && until.isAfter(ref.read(clockProvider)());
    return AuthScaffold(
      title: l10n.consentGateTitle,
      subtitle: l10n.consentGateSubtitle,
      showBack: false,
      pinnedNotice: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AuthErrorBanner(code: gate.errorCode),
          AuthDisabledReason(
            text: l10n.consentGateHint,
            visible: !complete,
            textKey: const Key('consent-gate-hint'),
          ),
        ],
      ),
      actions: [
        BusyButton(
          key: const Key('consent-gate-submit'),
          label: l10n.consentGateSubmit,
          busy: gate.busy,
          enabled: complete && !waiting,
          disabledReason: l10n.consentGateHint,
          onPressed: _submit,
        ),
      ],
      children: [
        ConsentChecklist(
          documents: documents,
          accepted: _accepted,
          onChanged: _toggle,
        ),
        if (paused) ...[
          const Gap.v(PillPalSpacing.xxl),
          AuthNotice(
            key: const Key('consent-gate-paused'),
            text: l10n.consentGatePaused,
          ),
        ],
        ..._exits(context, gate, paused),
      ],
    );
  }

  /// The list is empty: it is being loaded or was just cleared and the router
  /// is about to leave. Nothing to tick, so no hint and no button.
  Widget _loading(BuildContext context, ConsentGateState gate) {
    final l10n = AppLocalizations.of(context);
    return AuthScaffold(
      title: l10n.consentGateTitle,
      subtitle: l10n.consentGateSubtitle,
      showBack: false,
      children: [
        Center(
          child: CircularProgressIndicator(
            key: const Key('consent-gate-loading'),
            // «Loading your consents»: the spinner has no text of its own.
            semanticsLabel: l10n.privacyLoading,
          ),
        ),
        ..._exits(context, gate, ref.watch(medicalSyncPausedProvider)),
      ],
    );
  }

  /// A text this app does not have: no way to give the consent here.
  Widget _blocked(BuildContext context, ConsentGateState gate, bool paused) {
    final l10n = AppLocalizations.of(context);
    return AuthScaffold(
      title: l10n.consentBlockedTitle,
      subtitle: l10n.consentBlockedBody,
      showBack: false,
      pinnedNotice: AuthErrorBanner(
        // The body already says the app is out of date.
        code: gate.errorCode == AuthClientErrors.consentOutdated
            ? null
            : gate.errorCode,
      ),
      actions: [
        FilledButton.tonal(
          key: const Key('consent-gate-recheck'),
          onPressed: gate.checking
              ? null
              : () => unawaited(
                    ref.read(consentGateProvider.notifier).refresh(),
                  ),
          child: gate.checking
              ? const SizedBox.square(
                  dimension: PillPalSizes.spinner,
                  child: CircularProgressIndicator(strokeWidth: 3),
                )
              : Text(l10n.consentBlockedRetry),
        ),
      ],
      children: [
        if (paused)
          AuthNotice(
            key: const Key('consent-gate-paused'),
            text: l10n.consentGatePaused,
          ),
        ..._exits(context, gate, paused),
      ],
    );
  }

  /// The ways out, in the scrolling list: three pinned buttons would not fit
  /// at the largest text size, and the primary one must.
  List<Widget> _exits(
    BuildContext context,
    ConsentGateState gate,
    bool paused,
  ) {
    final l10n = AppLocalizations.of(context);
    return [
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
      const Gap.v(PillPalSpacing.sm),
      dangerTextButton(
        context,
        key: const Key('consent-gate-delete'),
        onPressed: gate.busy
            ? null
            : () => unawaited(
                  showPillPalDialog<void>(
                    context: context,
                    builder: (context) => const DeleteAccountDialog(),
                  ),
                ),
        icon: Icons.delete_forever_outlined,
        label: l10n.deleteAccount,
      ),
    ];
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
    for (final item in missing) {
      final kind = ConsentKind.tryParse(StoredConsents.kindOf(item));
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
      for (final item in shown)
        if (ConsentKind.tryParse(StoredConsents.kindOf(item)) case final kind?
            when _accepted.contains(kind))
          kind,
    };
    await ref.read(consentGateProvider.notifier).accept(kinds);
  }
}
