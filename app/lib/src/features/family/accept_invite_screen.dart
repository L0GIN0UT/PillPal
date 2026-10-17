import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/api/api_exception.dart';
import '../../data/api/relatives_dto.dart';
import '../../data/db/database.dart';
import '../../data/providers.dart';
import '../../links/invite_link.dart';
import '../../links/link_providers.dart';
import '../../routing/routes.dart';
import '../common/error_snack_bar.dart';
import 'family_providers.dart';
import 'family_tiles.dart';
import 'relatives_errors.dart';

/// Accepting an invite: a link opened from outside (app_links) or a pasted
/// one. The link is parsed for this build's region, previewed (nothing
/// changes yet), and accepted only after the invitee confirms; a guardian
/// invite carries its own warning. The token stays in memory.
class AcceptInviteScreen extends ConsumerStatefulWidget {
  /// Creates the screen.
  const AcceptInviteScreen({super.key});

  @override
  ConsumerState<AcceptInviteScreen> createState() => _AcceptInviteState();
}

class _AcceptInviteState extends ConsumerState<AcceptInviteScreen> {
  final TextEditingController _paste = TextEditingController();
  String? _token;
  InviteLinkProblem? _problem;
  InvitePreview? _preview;
  IncomingGrant? _accepted;
  String? _errorCode;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final held = ref.read(inviteIntakeProvider);
    if (held != null) {
      _token = held.result.token;
      _problem = held.result.problem;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      // The link now lives in this screen; the next link starts afresh.
      ref.read(inviteIntakeProvider.notifier).take();
      if (_token != null) {
        unawaited(_loadPreview());
      }
    });
  }

  @override
  void dispose() {
    _paste.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final accepted = _accepted;
    final preview = _preview;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.acceptInviteTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            if (accepted != null)
              _AcceptedView(grant: accepted)
            else if (preview != null)
              _PreviewView(
                preview: preview,
                busy: _busy,
                errorCode: _errorCode,
                onAccept: _accept,
                onDecline: () => context.pop(),
              )
            else
              ..._pasteForm(context),
          ],
        ),
      ),
    );
  }

  List<Widget> _pasteForm(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final problem = _problem;
    final code = _errorCode;
    return [
      Text(l10n.acceptInviteHint, style: Theme.of(context).textTheme.bodyLarge),
      const SizedBox(height: 16),
      if (problem != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            _problemText(l10n, problem),
            key: const Key('accept-problem'),
          ),
        ),
      if (code != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            relativesErrorMessage(l10n, code),
            key: const Key('accept-error'),
          ),
        ),
      TextField(
        key: const Key('accept-link-field'),
        controller: _paste,
        keyboardType: TextInputType.url,
        autocorrect: false,
        enableSuggestions: false,
        minLines: 1,
        maxLines: 3,
        decoration: InputDecoration(labelText: l10n.acceptLinkLabel),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          TextButton.icon(
            key: const Key('accept-paste'),
            onPressed: () => unawaited(_pasteFromClipboard()),
            icon: const Icon(Icons.content_paste),
            label: Text(l10n.pasteLink),
          ),
        ],
      ),
      const SizedBox(height: 8),
      FilledButton(
        key: const Key('accept-check'),
        onPressed: _busy ? null : _checkPasted,
        child: Text(l10n.checkInvite),
      ),
    ];
  }

  String _problemText(AppLocalizations l10n, InviteLinkProblem problem) {
    switch (problem) {
      case InviteLinkProblem.otherRegion:
        return l10n.inviteOtherRegion;
      case InviteLinkProblem.unknownHost:
        return l10n.inviteUnknownHost;
      case InviteLinkProblem.malformed:
        return l10n.inviteMalformed;
    }
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && mounted) {
      _paste.text = data!.text!;
    }
  }

  void _checkPasted() {
    final result = parseInviteLink(
      _paste.text,
      ref.read(linkConfigProvider),
    );
    setState(() {
      _token = result.token;
      _problem = result.problem;
      _errorCode = null;
    });
    if (result.token != null) {
      _paste.clear();
      unawaited(_loadPreview());
    }
  }

  Future<void> _loadPreview() async {
    final token = _token;
    if (token == null) {
      return;
    }
    setState(() => _busy = true);
    try {
      final preview = await ref.read(relativesApiProvider).previewInvite(token);
      if (mounted) {
        setState(() {
          _preview = preview;
          _busy = false;
        });
      }
    } on ApiException catch (error) {
      _fail(error.code);
    }
  }

  Future<void> _accept() async {
    final token = _token;
    if (token == null) {
      return;
    }
    setState(() {
      _busy = true;
      _errorCode = null;
    });
    try {
      final grant = await ref.read(familyActionsProvider).acceptInvite(token);
      if (mounted) {
        setState(() {
          _accepted = grant;
          _token = null;
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
    if (!mounted) {
      return;
    }
    setState(() {
      _busy = false;
      _errorCode = code;
      // A link that cannot be previewed is useless: back to the paste form.
      if (_preview == null) {
        _token = null;
      }
    });
  }
}

class _PreviewView extends StatelessWidget {
  const _PreviewView({
    required this.preview,
    required this.busy,
    required this.errorCode,
    required this.onAccept,
    required this.onDecline,
  });

  final InvitePreview preview;
  final bool busy;
  final String? errorCode;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final guardian = preview.role == ScopeRole.guardian;
    final inviter = preview.inviterDisplayName ?? l10n.relativeUnnamed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.invitePreviewTitle(inviter),
          key: const Key('invite-preview-title'),
          style: textTheme.headlineSmall,
        ),
        const SizedBox(height: 12),
        Text(
          preview.profileKind == 'managed'
              ? l10n.invitePreviewManaged(preview.profileDisplayName)
              : l10n.invitePreviewSelf(inviter),
          style: textTheme.bodyLarge,
        ),
        const SizedBox(height: 8),
        Text(
          '${roleLabel(l10n, preview.role)}. '
          '${roleExplanation(l10n, preview.role)}',
          key: const Key('invite-preview-role'),
          style: textTheme.bodyLarge,
        ),
        if (guardian) ...[
          const SizedBox(height: 12),
          Card(
            key: const Key('guardian-warning'),
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                l10n.guardianWarning,
                style: textTheme.bodyLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
            ),
          ),
        ],
        if (errorCode != null) ...[
          const SizedBox(height: 12),
          Text(
            relativesErrorMessage(l10n, errorCode!),
            key: const Key('accept-error'),
          ),
        ],
        const SizedBox(height: 20),
        FilledButton(
          key: const Key('accept-confirm'),
          onPressed: busy ? null : onAccept,
          child: Text(l10n.acceptInviteConfirm),
        ),
        const SizedBox(height: 8),
        TextButton(
          key: const Key('accept-decline'),
          onPressed: busy ? null : onDecline,
          child: Text(l10n.acceptInviteDecline),
        ),
      ],
    );
  }
}

class _AcceptedView extends ConsumerWidget {
  const _AcceptedView({required this.grant});

  final IncomingGrant grant;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.inviteAcceptedTitle(grant.profileDisplayName),
          key: const Key('invite-accepted'),
          style: textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text(l10n.inviteAcceptedHint, style: textTheme.bodyLarge),
        const SizedBox(height: 20),
        FilledButton(
          key: const Key('accepted-open'),
          onPressed: () => unawaited(
            context.pushReplacement(AppRoutes.profileToday(grant.profileId)),
          ),
          child: Text(l10n.openProfile),
        ),
        const SizedBox(height: 8),
        TextButton(
          key: const Key('accepted-done'),
          onPressed: () => context.pop(),
          child: Text(l10n.done),
        ),
      ],
    );
  }
}
