import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/api/api_exception.dart';
import '../../data/api/relatives_dto.dart';
import '../../data/db/database.dart';
import '../../data/providers.dart';
import '../common/choice_button.dart';
import '../common/error_snack_bar.dart';
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
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
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
      const SizedBox(height: 16),
      Text(l10n.inviteRoleTitle, style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final role in roles)
            ChoiceButton(
              key: ValueKey('invite-role-$role'),
              label: roleLabel(l10n, role),
              selected: role == _role,
              onTap: () => setState(() => _role = role),
            ),
        ],
      ),
      const SizedBox(height: 24),
      InviteDisclosure(role: _role, forSelf: !profile.isManaged),
      if (_errorCode != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            relativesErrorMessage(l10n, _errorCode!),
            key: const Key('invite-error'),
          ),
        ),
      const SizedBox(height: 16),
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
      final created = await ref.read(familyActionsProvider).createInvite(
            profileId: widget.profileId,
            inviteId: _inviteId,
            role: _role,
            disclosureVersion: inviteDisclosureVersion,
          );
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
