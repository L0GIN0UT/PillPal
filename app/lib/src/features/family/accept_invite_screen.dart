import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/api/api_exception.dart';
import '../../data/api/relatives_dto.dart';
import '../../data/providers.dart';
import '../../links/invite_link.dart';
import '../../links/link_providers.dart';
import '../common/error_snack_bar.dart';
import 'accept_invite_views.dart';
import 'family_providers.dart';
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

  /// A link that arrives while this screen is open is shown here instead of
  /// stacking a second accept screen (only the top screen takes it; if
  /// nobody does, the app scope opens one).
  void _adopt(InviteIntake held) {
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) {
      return;
    }
    ref.read(inviteIntakeProvider.notifier).take();
    setState(() {
      _token = held.result.token;
      _problem = held.result.problem;
      _preview = null;
      _accepted = null;
      _errorCode = null;
    });
    if (_token != null) {
      unawaited(_loadPreview());
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(inviteIntakeProvider, (previous, held) {
      if (held != null) {
        _adopt(held);
      }
    });
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
              InviteAcceptedView(grant: accepted)
            else if (preview != null)
              InvitePreviewView(
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
        _message(_problemText(l10n, problem), const Key('accept-problem')),
      if (code != null)
        _message(relativesErrorMessage(l10n, code), const Key('accept-error')),
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

  Widget _message(String text, Key key) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(text, key: key),
      );

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
