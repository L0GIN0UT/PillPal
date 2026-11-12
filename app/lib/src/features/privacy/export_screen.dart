import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/api/export_dto.dart';
import '../../data/config.dart';
import '../../theme/palette.dart';
import '../../theme/spacing.dart';
import '../auth/auth_fields.dart';
import '../auth/auth_widgets.dart';
import '../common/banner_tone.dart';
import '../common/gap.dart';
import '../common/pillpal_banner.dart';
import 'export_controller.dart';
import 'export_errors.dart';

/// Export of the account's data (ADR 0016 §8, docs/spec/export.md): the
/// password step-up, a wait while the server builds the archive, the one-time
/// download into the cache directory, the share sheet, and the deletion of the
/// file. The archive is a JSON zip; it never goes by e-mail.
///
/// The password is cleared once it is sent, when the app leaves the
/// foreground and when the screen closes. Leaving the screen deletes the
/// archive, shared or not, and while it is being downloaded the screen cannot
/// be left, because the archive is handed out only once.
class ExportScreen extends ConsumerStatefulWidget {
  /// Creates the screen.
  const ExportScreen({super.key});

  @override
  ConsumerState<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends ConsumerState<ExportScreen> {
  final TextEditingController _password = TextEditingController();
  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    _password.clear();
    _password.dispose();
    super.dispose();
  }

  void _onLifecycle(AppLifecycleState state) {
    // Only a real background: Face ID, autofill and the notification shade
    // pass through `inactive` while the user is typing.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _password.clear();
    }
    if (state == AppLifecycleState.resumed) {
      // Back from the share target: a shared archive is deleted now.
      ref.read(exportControllerProvider.notifier).appResumed();
    }
  }

  @override
  Widget build(BuildContext context) {
    final flow = ref.watch(exportControllerProvider);
    return PopScope(
      canPop: !flow.mustStay,
      child: switch (flow.phase) {
        ExportPhase.form => _form(context, flow),
        ExportPhase.requesting ||
        ExportPhase.building =>
          _waiting(context, building: true),
        ExportPhase.downloading => _waiting(context, building: false),
        ExportPhase.ready => _ready(context, flow),
        ExportPhase.done => _done(context),
        ExportPhase.failed => _failed(context, flow),
      },
    );
  }

  Widget _form(BuildContext context, ExportState flow) {
    final l10n = AppLocalizations.of(context);
    final code = flow.errorCode;
    return AuthScaffold(
      title: l10n.exportTitle,
      subtitle: l10n.exportIntro(ExportPolicy.downloadWindowHours),
      pinnedNotice: code == null
          ? null
          : _error(
              exportErrorMessage(l10n, code, retryAfter: flow.retryAfter),
            ),
      actions: [
        BusyButton(
          key: const Key('export-submit'),
          label: l10n.exportSubmit,
          busy: false,
          onPressed: _submit,
        ),
      ],
      children: [
        Text(
          l10n.exportPasswordHint,
          style: Theme.of(context).textTheme.bodyLarge,
        ),
        const Gap.v(PillPalSpacing.md),
        AuthPasswordField(
          fieldKey: const Key('export-password'),
          controller: _password,
          maxLength: ExportPolicy.passwordMaxLength,
          autofillHint: AutofillHints.password,
          onChanged: (_) =>
              ref.read(exportControllerProvider.notifier).clearError(),
          onSubmitted: _submit,
        ),
      ],
    );
  }

  Widget _waiting(BuildContext context, {required bool building}) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    return AuthScaffold(
      title: l10n.exportTitle,
      children: [
        Center(
          child: CircularProgressIndicator(
            key: Key(building ? 'export-building' : 'export-downloading'),
          ),
        ),
        const Gap.v(PillPalSpacing.lg),
        Semantics(
          liveRegion: true,
          child: Text(
            building ? l10n.exportBuilding : l10n.exportDownloading,
            textAlign: TextAlign.center,
            style: textTheme.titleMedium,
          ),
        ),
        const Gap.v(PillPalSpacing.sm),
        Text(
          building ? l10n.exportBuildingHint : l10n.exportDownloadingHint,
          textAlign: TextAlign.center,
          style: textTheme.bodyLarge?.copyWith(
            color: context.palette.inkMuted,
          ),
        ),
      ],
    );
  }

  Widget _ready(BuildContext context, ExportState flow) {
    final l10n = AppLocalizations.of(context);
    final code = flow.errorCode;
    return AuthScaffold(
      title: l10n.exportReady,
      subtitle: l10n.exportReadyHint,
      pinnedNotice:
          code == null ? null : _error(exportErrorMessage(l10n, code)),
      actions: [
        BusyButton(
          key: const Key('export-share'),
          label: l10n.exportShare,
          busy: flow.sharing,
          onPressed: () => unawaited(
            ref.read(exportControllerProvider.notifier).share(),
          ),
        ),
      ],
      children: const [],
    );
  }

  Widget _done(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AuthScaffold(
      title: l10n.exportDone,
      subtitle: l10n.exportDoneHint,
      actions: [
        BusyButton(
          key: const Key('export-close'),
          label: l10n.done,
          busy: false,
          onPressed: () => context.pop(),
        ),
      ],
      children: const [],
    );
  }

  Widget _failed(BuildContext context, ExportState flow) {
    final l10n = AppLocalizations.of(context);
    final controller = ref.read(exportControllerProvider.notifier);
    final code = flow.errorCode ?? ExportErrors.gone;
    // An archive that is too large will not shrink by asking again.
    final canAskAgain = code != ExportErrors.tooLarge;
    return AuthScaffold(
      title: l10n.exportTitle,
      actions: [
        if (flow.resumable)
          BusyButton(
            key: const Key('export-resume'),
            label: l10n.exportCheckAgain,
            busy: false,
            onPressed: () => unawaited(controller.resume()),
          )
        else if (canAskAgain)
          BusyButton(
            key: const Key('export-restart'),
            label: l10n.exportRequestAgain,
            busy: false,
            onPressed: controller.restart,
          )
        else
          BusyButton(
            key: const Key('export-close'),
            label: l10n.done,
            busy: false,
            onPressed: () => context.pop(),
          ),
      ],
      children: [_error(exportErrorMessage(l10n, code))],
    );
  }

  Widget _error(String message) {
    return Padding(
      padding: const EdgeInsets.only(bottom: PillPalSpacing.lg),
      child: PillPalBanner(
        key: const Key('export-error'),
        tone: BannerTone.danger,
        body: message,
        liveRegion: true,
      ),
    );
  }

  Future<void> _submit() async {
    final controller = ref.read(exportControllerProvider.notifier);
    if (ref.read(exportControllerProvider).busy) {
      return;
    }
    FocusScope.of(context).unfocus();
    final typed = _password.text;
    // Gone from the field as soon as it is sent: only the request holds it.
    _password.clear();
    await controller.start(typed);
  }
}
