import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/api/api_exception.dart';
import '../../data/db/database.dart';
import '../../data/repositories/relatives_repository.dart';
import '../../routing/routes.dart';
import '../common/choice_button.dart';
import '../common/confirm_dialog.dart';
import '../common/error_snack_bar.dart';
import 'family_providers.dart';
import 'family_tiles.dart';
import 'invite_disclosure.dart';
import 'relatives_errors.dart';

/// One link to a relative. The owner of an outgoing link changes the role
/// between viewer and editor (after the disclosure, with its version) or
/// revokes it; the grantee of an incoming link chooses whether to be alerted
/// about missed doses, or leaves.
class RelativeDetailScreen extends ConsumerWidget {
  /// Creates the screen for link [linkId].
  const RelativeDetailScreen({required this.linkId, super.key});

  /// The link (grant) id.
  final String linkId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final links = ref.watch(grantLinksProvider);
    RelativeLinkRow? link;
    for (final row in links.valueOrNull ?? const <RelativeLinkRow>[]) {
      if (row.id == linkId) {
        link = row;
      }
    }
    return Scaffold(
      appBar: AppBar(title: Text(l10n.relativeDetailTitle)),
      body: SafeArea(
        child: link == null
            ? Center(
                child: links.isLoading
                    ? const CircularProgressIndicator()
                    : Text(l10n.relativeGone, key: const Key('relative-gone')),
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                children: [
                  link.direction == LinkDirection.outgoing
                      ? _OutgoingDetail(link: link)
                      : _IncomingDetail(link: link),
                ],
              ),
      ),
    );
  }
}

class _OutgoingDetail extends ConsumerStatefulWidget {
  const _OutgoingDetail({required this.link});

  final RelativeLinkRow link;

  @override
  ConsumerState<_OutgoingDetail> createState() => _OutgoingDetailState();
}

class _OutgoingDetailState extends ConsumerState<_OutgoingDetail> {
  late String _role = widget.link.role;
  String? _errorCode;
  bool _busy = false;

  bool get _roleEditable =>
      widget.link.active &&
      (widget.link.role == ScopeRole.viewer ||
          widget.link.role == ScopeRole.editor);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final link = widget.link;
    final changed = _role != link.role;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          link.counterpartName ?? l10n.relativeUnnamed,
          style: textTheme.headlineSmall,
        ),
        if (link.profileKind == 'managed' && link.profileName.isNotEmpty)
          Text(l10n.linkForProfile(link.profileName)),
        if (!link.active)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(l10n.linkInactiveHint, key: const Key('link-inactive')),
          ),
        const SizedBox(height: 16),
        ..._roleSection(l10n, textTheme),
        if (_errorCode != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              relativesErrorMessage(l10n, _errorCode!),
              key: const Key('detail-error'),
            ),
          ),
        const SizedBox(height: 16),
        if (_roleEditable)
          FilledButton(
            key: const Key('detail-save-role'),
            onPressed: _busy || !changed ? null : _saveRole,
            child: Text(l10n.saveRole),
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const Key('detail-revoke'),
          onPressed: _busy ? null : _revoke,
          icon: const Icon(Icons.person_remove_outlined),
          label: Text(l10n.revokeAccess),
        ),
      ],
    );
  }

  /// The role choice with its disclosure, or the role as plain text when it
  /// cannot be changed (a guardian, or an inactive link).
  List<Widget> _roleSection(AppLocalizations l10n, TextTheme textTheme) {
    final link = widget.link;
    if (!_roleEditable) {
      return [
        Text(roleLabel(l10n, link.role), style: textTheme.titleMedium),
        Text(roleExplanation(l10n, link.role)),
      ];
    }
    return [
      Text(l10n.inviteRoleTitle, style: textTheme.titleSmall),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final role in [ScopeRole.viewer, ScopeRole.editor])
            ChoiceButton(
              key: ValueKey('detail-role-$role'),
              label: roleLabel(l10n, role),
              selected: role == _role,
              onTap: () => setState(() => _role = role),
            ),
        ],
      ),
      const SizedBox(height: 16),
      InviteDisclosure(
        role: _role,
        forSelf: link.profileKind != 'managed',
      ),
    ];
  }

  Future<void> _saveRole() async {
    setState(() {
      _busy = true;
      _errorCode = null;
    });
    try {
      await ref.read(familyActionsProvider).changeRole(widget.link.id, _role);
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
    final name = widget.link.counterpartName ?? l10n.relativeUnnamed;
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
      await ref.read(familyActionsProvider).revoke(widget.link.id);
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

class _IncomingDetail extends ConsumerStatefulWidget {
  const _IncomingDetail({required this.link});

  final RelativeLinkRow link;

  @override
  ConsumerState<_IncomingDetail> createState() => _IncomingDetailState();
}

class _IncomingDetailState extends ConsumerState<_IncomingDetail> {
  String? _errorCode;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final link = widget.link;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          link.profileName.isEmpty ? l10n.relativeUnnamed : link.profileName,
          style: textTheme.headlineSmall,
        ),
        if (link.counterpartName != null)
          Text(l10n.linkOwner(link.counterpartName!)),
        const SizedBox(height: 12),
        Text(roleLabel(l10n, link.role), style: textTheme.titleMedium),
        Text(roleExplanation(l10n, link.role)),
        const SizedBox(height: 16),
        SwitchListTile(
          key: const Key('notify-missed'),
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.notifyMissedTitle),
          subtitle: Text(l10n.notifyMissedHint),
          value: link.notifyMissed,
          onChanged: _busy ? null : (value) => _setNotify(enabled: value),
        ),
        if (_errorCode != null)
          Text(
            relativesErrorMessage(l10n, _errorCode!),
            key: const Key('detail-error'),
          ),
        const SizedBox(height: 16),
        FilledButton(
          key: const Key('detail-open'),
          onPressed: () => unawaited(
            context.push(AppRoutes.profileToday(link.profileId)),
          ),
          child: Text(l10n.openProfile),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const Key('detail-leave'),
          onPressed: _busy ? null : _leave,
          icon: const Icon(Icons.logout),
          label: Text(l10n.leaveProfile),
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
      if (mounted) {
        setState(() {
          _busy = false;
          _errorCode = error.code;
        });
      }
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
      if (mounted) {
        setState(() {
          _busy = false;
          _errorCode = error.code;
        });
      }
    }
  }
}
