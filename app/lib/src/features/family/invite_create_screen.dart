import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/api/api_exception.dart';
import '../../data/api/relatives_dto.dart';
import '../../data/db/database.dart';
import '../../data/providers.dart';
import '../../links/invite_link.dart';
import '../../links/link_providers.dart';
import '../../theme/spacing.dart';
import '../common/banner_tone.dart';
import '../common/choice_group.dart';
import '../common/error_snack_bar.dart';
import '../common/gap.dart';
import '../common/group_label.dart';
import '../common/pillpal_banner.dart';
import 'family_overview.dart';
import 'family_providers.dart';
import 'family_tiles.dart';
import 'invite_disclosure.dart';
import 'invite_share_view.dart';
import 'profile_context.dart';
import 'relatives_errors.dart';

/// Creates an invite for [profileId]: the role, the disclosure the owner
/// confirms (`disclosure_version` is sent), then the QR code and share sheet.
/// Guardians can be invited to managed profiles only.
class InviteCreateScreen extends ConsumerStatefulWidget {
  /// Creates the screen.
  const InviteCreateScreen({required this.profileId, super.key});

  /// The profile the invite is for.
  final String profileId;

  @override
  ConsumerState<InviteCreateScreen> createState() => _InviteCreateState();
}

class _InviteCreateState extends ConsumerState<InviteCreateScreen> {
  late final String _inviteId = ref.read(idGeneratorProvider)();
  String _role = ScopeRole.viewer;
  InviteCreated? _created;
  String? _errorCode;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final access = ref.watch(profileAccessProvider(widget.profileId));
    final profile = access.valueOrNull;
    final created = _created;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.inviteTitle)),
      body: SafeArea(
        child: ListView(
          padding: PillPalSpacing.form,
          children: [
            if (profile == null || !profile.canManageLinks)
              Text(l10n.inviteNotAllowed, key: const Key('invite-not-allowed'))
            else if (created != null)
              InviteShareView(invite: created, onDone: () => context.pop())
            else
              ..._form(context, profile),
          ],
        ),
      ),
    );
  }

  List<Widget> _form(BuildContext context, ProfileAccess profile) {
    final l10n = AppLocalizations.of(context);
    final roles = [
      ScopeRole.viewer,
      ScopeRole.editor,
      if (profile.isManaged) ScopeRole.guardian,
    ];
    return [
      Text(
        l10n.inviteForProfile(
          profile.isOwnSelf ? l10n.profileMe : profile.profile.displayName,
        ),
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const Gap.v(PillPalSpacing.lg),
      GroupLabel(l10n.inviteRoleTitle),
      ChoiceGroup<String>(
        options: {for (final role in roles) role: roleLabel(l10n, role)},
        selected: _role,
        onSelected: (role) => setState(() => _role = role),
        keyOf: (role) => ValueKey('invite-role-$role'),
      ),
      const Gap.v(PillPalSpacing.xxl),
      InviteDisclosure(role: _role, forSelf: !profile.isManaged),
      if (_errorCode != null) ...[
        const Gap.v(PillPalSpacing.sm),
        PillPalBanner(
          tone: BannerTone.danger,
          liveRegion: true,
          body: relativesErrorMessage(l10n, _errorCode!),
          bodyKey: const Key('invite-error'),
        ),
      ],
      const Gap.v(PillPalSpacing.lg),
      FilledButton(
        key: const Key('invite-create'),
        onPressed: _busy ? null : _create,
        child: Text(l10n.inviteCreate),
      ),
    ];
  }

  Future<void> _create() async {
    setState(() {
      _busy = true;
      _errorCode = null;
    });
    try {
      final actions = ref.read(familyActionsProvider);
      final created = await actions.createInvite(
        profileId: widget.profileId,
        inviteId: _inviteId,
        role: _role,
        disclosureVersion: inviteDisclosureVersion,
      );
      // The QR code and the share sheet carry whatever the server sent:
      // only a link of this region's hosts is passed on.
      final trusted = parseInviteLink(
        created.url,
        ref.read(linkConfigProvider),
      );
      if (trusted.token == null) {
        await actions.discardInvite(widget.profileId, created.id);
        _fail(RelativesClientErrors.untrustedInviteLink);
        return;
      }
      if (mounted) {
        setState(() {
          _created = created;
          _busy = false;
        });
      }
    } on ApiException catch (error) {
      _fail(error.code);
    } on Exception {
      if (mounted) {
        setState(() => _busy = false);
        showErrorSnackBar(context);
      }
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
