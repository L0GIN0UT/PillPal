import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../links/invite_link.dart';
import '../../links/link_providers.dart';
import '../../theme/spacing.dart';
import '../catalog/mobile_scanner_adapter.dart';
import '../catalog/scan_viewfinder.dart';
import '../catalog/scanner_adapter.dart';
import '../common/gap.dart';
import '../common/pillpal_icon_button.dart';
import '../common/sheet_scaffold.dart';
import '../common/stacked_buttons.dart';
import '../common/status_message.dart';

/// Makes the camera of the invite scanner (QR codes only); tests override
/// it with a fake.
final inviteScannerFactoryProvider = Provider<ScannerAdapterFactory>(
  (ref) => () => MobileScannerAdapter(
        formats: MobileScannerAdapter.inviteFormats,
      ),
);

/// How the invite scanner was left.
enum InviteScanOutcome {
  /// A valid invite of this region was read and handed to the invite intake
  /// ([inviteIntakeProvider]): the accept screen takes it from there.
  scanned,

  /// The person chose to paste a link instead.
  paste,
}

/// Opens the invite scanner; null when the person closed it.
Future<InviteScanOutcome?> showInviteScanSheet(BuildContext context) {
  return showPillPalSheet<InviteScanOutcome>(
    context,
    (context) => const InviteScanSheet(),
  );
}

enum _Notice { notPillPal, otherRegion, permission, unavailable }

/// The camera reading a relative's invite QR code (docs/adr/0020). Only our
/// invite link counts: https, a link host of this region, the token in the
/// fragment ([parseInviteLink]); anything else is «Это не код PillPal», a
/// link of the other region says so. The first valid code stops the camera
/// and goes to the invite intake, nowhere else: not into a route, a log or
/// analytics. No image is taken or kept.
class InviteScanSheet extends ConsumerStatefulWidget {
  /// Creates the sheet.
  const InviteScanSheet({super.key});

  @override
  ConsumerState<InviteScanSheet> createState() => _InviteScanSheetState();
}

class _InviteScanSheetState extends ConsumerState<InviteScanSheet> {
  late final ScannerAdapter _adapter;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  bool _done = false;
  _Notice? _notice;

  @override
  void initState() {
    super.initState();
    _adapter = ref.read(inviteScannerFactoryProvider)();
    _subscriptions
      ..add(_adapter.barcodes.listen(_onCode))
      ..add(_adapter.failures.listen(_onFailure));
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_adapter.dispose());
    super.dispose();
  }

  void _onCode(ScanBarcode code) {
    if (_done) {
      return;
    }
    final result = code.format == ScanFormat.qr
        ? parseInviteLink(code.raw, ref.read(linkConfigProvider))
        : const InviteLinkResult.rejected(InviteLinkProblem.unknownHost);
    if (result.token == null) {
      final notice = result.problem == InviteLinkProblem.otherRegion
          ? _Notice.otherRegion
          : _Notice.notPillPal;
      if (notice != _notice) {
        setState(() => _notice = notice);
      }
      return;
    }
    _done = true;
    unawaited(_adapter.pause());
    ref.read(inviteIntakeProvider.notifier).offer(code.raw);
    Navigator.of(context).pop(InviteScanOutcome.scanned);
  }

  void _onFailure(ScannerFailure failure) {
    if (_done) {
      return;
    }
    setState(() {
      _notice = failure == ScannerFailure.permissionDenied
          ? _Notice.permission
          : _Notice.unavailable;
    });
  }

  bool get _cameraLost =>
      _notice == _Notice.permission || _notice == _Notice.unavailable;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final notice = _notice;
    return SheetScaffold(
      children: [
        _Header(title: l10n.inviteScanTitle),
        const Gap.v(PillPalSpacing.md),
        if (!_cameraLost) ...[
          ScanViewfinder(
            preview: _adapter.buildPreview(context),
            torch: _adapter.torch,
            onTorch: () => unawaited(_adapter.toggleTorch()),
          ),
          const Gap.v(PillPalSpacing.md),
        ],
        if (notice != null)
          Semantics(
            liveRegion: true,
            child: StatusMessage(
              key: Key('invite-scan-notice-${notice.name}'),
              icon: _cameraLost ? Icons.no_photography_outlined : Icons.block,
              text: _text(l10n, notice),
            ),
          )
        else
          StatusMessage(
            key: const Key('invite-scan-hint'),
            icon: Icons.info_outline,
            text: l10n.inviteScanHint,
          ),
        const Gap.v(PillPalSpacing.sm),
        StackedButtons(
          children: [
            OutlinedButton.icon(
              key: const Key('invite-scan-paste'),
              onPressed: () =>
                  Navigator.of(context).pop(InviteScanOutcome.paste),
              icon: const Icon(Icons.link),
              label: Text(l10n.inviteScanPasteLink),
            ),
          ],
        ),
      ],
    );
  }

  String _text(AppLocalizations l10n, _Notice notice) {
    return switch (notice) {
      _Notice.notPillPal => l10n.inviteScanNotPillPal,
      _Notice.otherRegion => l10n.inviteOtherRegion,
      _Notice.permission => l10n.inviteScanPermission,
      _Notice.unavailable => l10n.inviteScanUnavailable,
    };
  }
}

/// The title of the sheet and the way to close it.
class _Header extends StatelessWidget {
  const _Header({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Semantics(
            header: true,
            child: Text(title, style: Theme.of(context).textTheme.titleLarge),
          ),
        ),
        PillPalIconButton(
          key: const Key('invite-scan-close'),
          icon: Icons.close,
          tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ],
    );
  }
}
