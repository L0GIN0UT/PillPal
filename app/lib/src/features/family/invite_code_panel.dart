import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/api/api_exception.dart';
import '../../data/api/invite_dto.dart';
import '../../data/api/relatives_api.dart';
import '../../data/clock.dart';
import '../../data/config.dart';
import '../../data/providers.dart';
import '../../data/repositories/relatives_repository.dart';
import '../../links/invite_link.dart';
import '../../links/link_providers.dart';
import 'family_overview.dart';
import 'family_providers.dart';
import 'invite_code_view.dart';
import 'invite_timing.dart';
import 'relative_added_view.dart';
import 'relatives_errors.dart';

/// A code on screen and what happened to it.
class _Code {
  _Code(this.invite, this.url, this.receivedAt, this.knownLinks);

  final InviteCreated invite;

  /// The link rebuilt from the token ([canonicalInviteLink]).
  final String url;

  /// Read on this phone's clock: only the time since then counts, so a
  /// skewed clock neither shortens nor stretches the code.
  final DateTime receivedAt;

  /// The links that existed before this code: a link not among them after
  /// the code was accepted is the new relative.
  final Set<String> knownLinks;

  /// The link went out through the share sheet: it may be in a message, so
  /// leaving the screen does not revoke it.
  bool shared = false;

  /// Someone accepted it: there is nothing to revoke.
  bool accepted = false;
}

/// The QR code of an invite for [profileId] with [role] (docs/adr/0020):
/// made when the panel appears (the owner confirmed the disclosure of this
/// role before; a parent shows a new panel for another role), counted down
/// from the server's own `created_at` / `expires_at`, renewed on «Обновить
/// код». While it is on screen, with the app in front, the invite's state is
/// polled; when someone accepts it, [onAccepted] says who. A code that was
/// never shared is revoked when it is replaced or the panel goes; a shared
/// one lives out its minutes. The token is kept in memory only.
class InviteCodePanel extends ConsumerStatefulWidget {
  /// Creates the panel.
  const InviteCodePanel({
    required this.profileId,
    required this.role,
    required this.onAccepted,
    this.belowCode,
    this.secondaryAction,
    super.key,
  });

  /// The profile the invite opens.
  final String profileId;

  /// The role it grants (fixed for the panel's life).
  final String role;

  /// Someone accepted the code.
  final ValueChanged<AcceptedRelative> onAccepted;

  /// A control under the code; `locked` while an acceptance is announced.
  final Widget Function(bool locked)? belowCode;

  /// A second button under the main one («Готово»).
  final Widget? secondaryAction;

  @override
  ConsumerState<InviteCodePanel> createState() => InviteCodePanelState();
}

/// The state of [InviteCodePanel]; a parent reaches it with a [GlobalKey]
/// only to call [revokeEvenIfShared].
class InviteCodePanelState extends ConsumerState<InviteCodePanel> {
  // Read in initState, not lazily: a request that lands after dispose (and
  // dispose itself) still revokes its code, when `ref` is gone.
  late final FamilyActions _actions;
  late final RelativesApi _api;
  late final RelativesRepository _links;
  late final Clock _clock;
  late final IdGenerator _newId;
  late final LinkConfig _linkConfig;
  late final AppLifecycleListener _lifecycle;

  _Code? _code;
  bool _creating = true;
  bool _expired = false;
  bool _announcing = false;
  bool _checking = false;
  bool _foreground = true;
  bool _visible = true;
  bool _paused = false;
  bool _revokeShared = false;
  String? _errorCode;
  Timer? _tick;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _actions = ref.read(familyActionsProvider);
    _api = ref.read(relativesApiProvider);
    _links = ref.read(relativesRepositoryProvider);
    _clock = ref.read(clockProvider);
    _newId = ref.read(idGeneratorProvider);
    _linkConfig = ref.read(linkConfigProvider);
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_create());
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // False while another screen covers this one.
    _visible = TickerMode.valuesOf(context).enabled;
    _syncPolling();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _drop();
    super.dispose();
  }

  /// The owner changed the role after the code was shown: the code goes
  /// even if its link was shared, because it grants a role the owner no
  /// longer wants to give. Call before removing the panel.
  void revokeEvenIfShared() => _revokeShared = true;

  void _onLifecycle(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _syncPolling();
  }

  /// Polls only a live code on a visible screen of an app in front; on
  /// return it asks at once.
  void _syncPolling() {
    final code = _code;
    final active =
        code != null && !code.accepted && !_expired && _foreground && _visible;
    if (!active) {
      if (_poll != null) {
        _poll?.cancel();
        _poll = null;
        _paused = code != null && !code.accepted && !_expired;
      }
    } else if (_poll == null) {
      _poll = Timer.periodic(InviteTiming.poll, (_) => unawaited(_check()));
      if (_paused) {
        // Back in front: the code may have been scanned meanwhile.
        _paused = false;
        unawaited(_check());
      }
    }
  }

  /// Stops the timers and revokes the code unless it was shared, accepted
  /// or ran out.
  void _drop() {
    _tick?.cancel();
    _poll?.cancel();
    _tick = null;
    _poll = null;
    final code = _code;
    _code = null;
    if (code != null &&
        (!code.shared || _revokeShared) &&
        !code.accepted &&
        !_expired) {
      unawaited(_actions.discardInvite(widget.profileId, code.invite.id));
    }
  }

  Future<void> _create() async {
    setState(() {
      _creating = true;
      _expired = false;
      _errorCode = null;
    });
    try {
      final known = {for (final link in await _links.links()) link.id};
      final created = await _actions.createInvite(
        profileId: widget.profileId,
        inviteId: _newId(),
        role: widget.role,
        disclosureVersion: inviteDisclosureVersion,
      );
      // Only a link of this region's hosts is shown or shared, and as the
      // app spells it, not as the server sent it.
      final token = parseInviteLink(created.url, _linkConfig).token;
      final url =
          token == null ? null : canonicalInviteLink(token, _linkConfig);
      if (url == null || !mounted) {
        unawaited(_actions.discardInvite(widget.profileId, created.id));
        if (url == null) {
          _fail(RelativesClientErrors.untrustedInviteLink);
        }
        return;
      }
      setState(() {
        _code = _Code(created, url, _clock(), known);
        _creating = false;
      });
      _tick = Timer.periodic(InviteTiming.tick, (_) => _onTick());
      _syncPolling();
    } on ApiException catch (error) {
      _fail(error.code);
    } on Exception {
      _fail(ApiException.networkError);
    }
  }

  void _fail(String code) {
    if (mounted) {
      setState(() {
        _creating = false;
        _errorCode = code;
      });
    }
  }

  Duration _left() {
    final code = _code;
    if (code == null) {
      return Duration.zero;
    }
    return code.invite.lifetime - _clock().difference(code.receivedAt);
  }

  void _onTick() {
    if (_left() <= Duration.zero) {
      _expire();
    }
  }

  void _expire() {
    _tick?.cancel();
    _tick = null;
    setState(() => _expired = true);
    _syncPolling();
  }

  Future<void> _check() async {
    final code = _code;
    if (code == null || code.accepted || _checking) {
      return;
    }
    _checking = true;
    try {
      final status = await _api.inviteStatus(code.invite.id);
      if (!mounted || _code != code || code.accepted) {
        return;
      }
      switch (status.state) {
        case InviteState.consumed:
          await _announce(code);
        case InviteState.expired:
        case InviteState.revoked:
          _expire();
      }
    } on ApiException catch (error) {
      // Gone for this account (its profile deleted): nothing to wait for.
      // Any other refusal is passing: the next poll asks again.
      if (mounted && _code == code && error.status == 404) {
        _expire();
      }
    } on Exception {
      // Offline for a moment: the next poll asks again.
    } finally {
      _checking = false;
    }
  }

  /// The code was accepted: the new link comes with the refreshed list.
  /// The owner is told in any case, by name when exactly one new link of
  /// this profile appeared since the code was made.
  Future<void> _announce(_Code code) async {
    code.accepted = true;
    _tick?.cancel();
    _tick = null;
    _syncPolling();
    setState(() => _announcing = true);
    String? linkId;
    String? name;
    try {
      await _actions.refresh();
      if (!mounted || _code != code) {
        return;
      }
      final added = [
        for (final link in await _links.links())
          if (link.direction == LinkDirection.outgoing &&
              link.profileId == widget.profileId &&
              !code.knownLinks.contains(link.id))
            link,
      ];
      if (mounted && _code == code && added.length == 1) {
        linkId = added.single.id;
        final counterpart = added.single.counterpartName;
        name = counterpart == null || counterpart.isEmpty ? null : counterpart;
      }
    } on Exception {
      // The list refreshes with the next sync; the name stays unknown here.
    } finally {
      if (mounted) {
        widget.onAccepted(
          AcceptedRelative(
            role: code.invite.role,
            linkId: linkId,
            name: name,
          ),
        );
      }
    }
  }

  void _refresh() {
    _drop();
    unawaited(_create());
  }

  Future<void> _share(AppLocalizations l10n) async {
    final code = _code;
    if (code == null) {
      return;
    }
    code.shared = true;
    try {
      await ref.read(textSharerProvider)(
        l10n.inviteShareText(code.url, ceilMinutes(_left())),
      );
    } on Exception {
      // No share sheet: the code stays on screen to be scanned.
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final code = _code;
    final error = _errorCode;
    final below = widget.belowCode;
    return InviteCodeView(
      area: error != null
          ? InviteCodeArea.failed
          : _expired
              ? InviteCodeArea.expired
              : code == null || _creating
                  ? InviteCodeArea.creating
                  : InviteCodeArea.code,
      url: code?.url,
      left: _left,
      errorText: error == null ? null : relativesErrorMessage(l10n, error),
      onShare: _announcing ? null : () => unawaited(_share(l10n)),
      onRefresh: _refresh,
      belowCode: below?.call(_announcing),
      secondaryAction: widget.secondaryAction,
    );
  }
}
