import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/api/api_exception.dart';
import '../../data/db/database.dart';
import '../../theme/spacing.dart';
import '../common/banner_tone.dart';
import '../common/confirm_dialog.dart';
import '../common/error_snack_bar.dart';
import '../common/gap.dart';
import '../common/pillpal_banner.dart';
import '../common/section_header.dart';
import 'danger_text_button.dart';
import 'family_providers.dart';
import 'family_tiles.dart';
import 'invite_disclosure.dart';
import 'relative_privacy_section.dart';
import 'relatives_errors.dart';
import 'role_cards.dart';

/// The block of an outgoing link on a relative's card (someone sees my
/// profile): what they see, the privacy of each medication, the role and
/// disconnecting. The card above it shows who it is.
class OutgoingDetail extends ConsumerStatefulWidget {
  /// Creates the body of [link].
  const OutgoingDetail({required this.link, super.key});

  /// The stored link.
  final RelativeLinkRow link;

  @override
  ConsumerState<OutgoingDetail> createState() => _OutgoingDetailState();
}

class _OutgoingDetailState extends ConsumerState<OutgoingDetail> {
  late String _role = widget.link.role;
  String? _errorCode;
  bool _busy = false;

  RelativeLinkRow get _link => widget.link;

  /// A viewer or an editor sees through the privacy levels; a guardian sees
  /// everything, so there is nothing to choose for them.
  bool get _sees =>
      _link.role == ScopeRole.viewer || _link.role == ScopeRole.editor;

  bool get _roleEditable => _link.active && _sees;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final changed = _role != _link.role;
    final name = _link.counterpartName ?? l10n.relativeUnnamed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!_link.active)
          PillPalBanner(
            tone: BannerTone.info,
            body: l10n.linkInactiveHint,
            bodyKey: const Key('link-inactive'),
          )
        else if (_sees) ...[
          PillPalBanner(
            icon: Icons.info_outline,
            body: l10n.relativeExplainer(name),
            bodyKey: const Key('relative-explainer'),
          ),
          RelativePrivacySection(profileId: _link.profileId, name: name),
        ],
        ..._roleSection(l10n),
        if (_errorCode != null) ...[
          const Gap.v(PillPalSpacing.md),
          PillPalBanner(
            tone: BannerTone.danger,
            liveRegion: true,
            body: relativesErrorMessage(l10n, _errorCode!),
            bodyKey: const Key('detail-error'),
          ),
        ],
        if (_roleEditable) ...[
          const Gap.v(PillPalSpacing.lg),
          FilledButton(
            key: const Key('detail-save-role'),
            onPressed: _busy || !changed ? null : _saveRole,
            child: Text(l10n.saveRole),
          ),
        ],
        const Gap.v(PillPalSpacing.sm),
        Center(
          child: dangerTextButton(
            context,
            key: const Key('detail-revoke'),
            onPressed: _busy ? null : _revoke,
            icon: Icons.link_off,
            label: l10n.relativeDisconnect,
          ),
        ),
      ],
    );
  }

  /// The role choice with its disclosure, or the role as plain text when it
  /// cannot be changed (a guardian, or an inactive link).
  List<Widget> _roleSection(AppLocalizations l10n) {
    if (!_roleEditable) {
      return [
        const Gap.v(PillPalSpacing.lg),
        Text(
          roleExplanation(l10n, _link.role),
          style: Theme.of(context).textTheme.bodyLarge,
        ),
      ];
    }
    return [
      SectionHeader(l10n.inviteRoleTitle),
      RoleCards(
        roles: const [ScopeRole.viewer, ScopeRole.editor],
        selected: _role,
        onSelected: (role) => setState(() => _role = role),
        keyPrefix: 'detail-role',
      ),
      const Gap.v(PillPalSpacing.lg),
      InviteDisclosure(
        role: _role,
        forSelf: _link.profileKind != 'managed',
      ),
    ];
  }

  Future<void> _saveRole() async {
    setState(() {
      _busy = true;
      _errorCode = null;
    });
    try {
      await ref.read(familyActionsProvider).changeRole(_link.id, _role);
      if (mounted) {
        context.pop();
      }
    } on ApiException catch (error) {
      _fail(error.code);
    } on Exception {
      _failGeneric();
    }
  }

  Future<void> _revoke() async {
    final l10n = AppLocalizations.of(context);
    final name = _link.counterpartName ?? l10n.relativeUnnamed;
    final confirmed = await confirmAction(
      context,
      title: l10n.revokeTitle(name),
      body: l10n.revokeBody,
      confirmLabel: l10n.revokeAccess,
    );
    if (!confirmed || !mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(familyActionsProvider).revoke(_link.id);
      if (mounted) {
        context.pop();
      }
    } on ApiException catch (error) {
      _fail(error.code);
    } on Exception {
      _failGeneric();
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

  void _failGeneric() {
    if (mounted) {
      setState(() => _busy = false);
      showErrorSnackBar(context);
    }
  }
}
