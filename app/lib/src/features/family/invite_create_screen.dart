import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/api/api_exception.dart';
import '../../data/api/relatives_dto.dart';
import '../../data/db/database.dart';
import '../../data/providers.dart';
import '../../links/invite_link.dart';
import '../../links/link_providers.dart';
import '../../theme/palette.dart';
import '../../theme/spacing.dart';
import '../common/banner_tone.dart';
import '../common/error_snack_bar.dart';
import '../common/gap.dart';
import '../common/pillpal_banner.dart';
import '../common/section_header.dart';
import 'family_overview.dart';
import 'family_providers.dart';
import 'invite_disclosure.dart';
import 'invite_share_view.dart';
import 'profile_context.dart';
import 'relatives_errors.dart';
import 'role_cards.dart';

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
    final asking = profile != null && profile.canManageLinks && created == null;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.inviteTitle)),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: PillPalSpacing.form,
                children: [
                  if (profile == null || !profile.canManageLinks)
                    Text(
                      l10n.inviteNotAllowed,
                      key: const Key('invite-not-allowed'),
                    )
                  else if (created != null)
                    InviteShareView(
                        invite: created, onDone: () => context.pop())
                  else
                    ..._form(context, profile),
                ],
              ),
            ),
            // Pinned: the one action stays in reach however long the
            // disclosure is or large the text (B2-README section 9).
            if (asking)
              Padding(
                padding: PillPalSpacing.sheet,
                child: FilledButton(
                  key: const Key('invite-create'),
                  onPressed: _busy ? null : _create,
                  child: Text(l10n.inviteCreate),
                ),
              ),
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
        style: Theme.of(context)
            .textTheme
            .bodyLarge
            ?.copyWith(color: context.palette.inkMuted),
      ),
      SectionHeader(l10n.inviteRoleTitle),
      RoleCards(
        roles: roles,
        selected: _role,
        onSelected: (role) => setState(() => _role = role),
        keyPrefix: 'invite-role',
      ),
      const Gap.v(PillPalSpacing.xxl),
      InviteDisclosure(role: _role, forSelf: !profile.isManaged),
      if (_errorCode != null) ...[
        const Gap.v(PillPalSpacing.md),
        PillPalBanner(
          tone: BannerTone.danger,
          liveRegion: true,
          body: relativesErrorMessage(l10n, _errorCode!),
          bodyKey: const Key('invite-error'),
        ),
      ],
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
