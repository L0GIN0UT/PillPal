import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/api/api_exception.dart';
import '../../data/db/database.dart';
import '../../routing/routes.dart';
import '../../theme/spacing.dart';
import '../common/banner_tone.dart';
import '../common/confirm_dialog.dart';
import '../common/gap.dart';
import '../common/pillpal_banner.dart';
import '../common/pillpal_card.dart';
import '../common/stacked_buttons.dart';
import 'danger_text_button.dart';
import 'family_providers.dart';
import 'family_tiles.dart';
import 'relative_detail_header.dart';
import 'relatives_errors.dart';

/// The body of an incoming link (I see someone's profile): who, what the
/// role allows, whether to be alerted about missed doses, open or leave.
/// It has no privacy editor: what a relative sees is the owner's decision.
class IncomingDetail extends ConsumerStatefulWidget {
  /// Creates the body of [link].
  const IncomingDetail({required this.link, super.key});

  /// The stored link.
  final RelativeLinkRow link;

  @override
  ConsumerState<IncomingDetail> createState() => _IncomingDetailState();
}

class _IncomingDetailState extends ConsumerState<IncomingDetail> {
  String? _errorCode;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final link = widget.link;
    final owner = link.counterpartName;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RelativeDetailHeader(
          name: link.profileName.isEmpty
              ? l10n.relativeUnnamed
              : link.profileName,
          subtitle: owner == null ? null : l10n.linkOwner(owner),
        ),
        const Gap.v(PillPalSpacing.lg),
        PillPalBanner(
          title: roleLabel(l10n, link.role),
          body: roleExplanation(l10n, link.role),
        ),
        const Gap.v(PillPalSpacing.md),
        PillPalCard(
          padding: EdgeInsets.zero,
          child: SwitchListTile(
            key: const Key('notify-missed'),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: PillPalSpacing.lg,
            ),
            secondary: const Icon(Icons.notifications_outlined),
            title: Text(l10n.notifyMissedTitle),
            subtitle: Text(l10n.notifyMissedHint),
            value: link.notifyMissed,
            onChanged: _busy ? null : (value) => _setNotify(enabled: value),
          ),
        ),
        if (_errorCode != null) ...[
          const Gap.v(PillPalSpacing.md),
          PillPalBanner(
            tone: BannerTone.danger,
            liveRegion: true,
            body: relativesErrorMessage(l10n, _errorCode!),
            bodyKey: const Key('detail-error'),
          ),
        ],
        const Gap.v(PillPalSpacing.xl),
        StackedButtons(
          children: [
            FilledButton(
              key: const Key('detail-open'),
              onPressed: () => unawaited(
                context.push(AppRoutes.profileToday(link.profileId)),
              ),
              child: Text(l10n.openProfile),
            ),
            // Quiet like «Закрыть доступ»: the dialog carries the weight.
            dangerTextButton(
              context,
              key: const Key('detail-leave'),
              onPressed: _busy ? null : _leave,
              icon: Icons.logout,
              label: l10n.leaveProfile,
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _setNotify({required bool enabled}) async {
    setState(() {
      _busy = true;
      _errorCode = null;
    });
    try {
      await ref
          .read(familyActionsProvider)
          .setNotifyMissed(widget.link.id, enabled: enabled);
      if (mounted) {
        setState(() => _busy = false);
      }
    } on ApiException catch (error) {
      _fail(error.code);
    }
  }

  Future<void> _leave() async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await confirmAction(
      context,
      title: l10n.leaveTitle(
        widget.link.profileName.isEmpty
            ? l10n.relativeUnnamed
            : widget.link.profileName,
      ),
      body: l10n.leaveBody,
      confirmLabel: l10n.leaveProfile,
    );
    if (!confirmed || !mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(familyActionsProvider).leaveProfile(widget.link.profileId);
      if (mounted) {
        context.pop();
      }
    } on ApiException catch (error) {
      _fail(error.code);
    }
  }

  void _fail(String code) {
    if (mounted) {
      setState(() {
        _busy = false;
        _errorCode = code;
      });
    }
  }
}
