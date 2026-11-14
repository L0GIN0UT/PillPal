import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/api/api_exception.dart';
import '../../data/api/relatives_api.dart';
import '../../data/api/relatives_dto.dart';
import '../../data/clock.dart';
import '../../data/config.dart';
import '../../data/db/database.dart';
import '../../data/providers.dart';
import '../../data/repositories/relatives_repository.dart';
import '../../links/invite_link.dart';
import '../../links/link_providers.dart';
import '../../theme/spacing.dart';
import '../common/banner_tone.dart';
import '../common/gap.dart';
import '../common/pillpal_banner.dart';
import 'family_overview.dart';
import 'family_providers.dart';
import 'invite_code_view.dart';
import 'invite_timing.dart';
import 'relatives_errors.dart';

/// A code on screen: the invite, when this phone received it, and whether
/// its link went out through the share sheet.
class _Code {
  _Code(this.invite, this.receivedAt);

  final InviteCreated invite;

  /// Read on this phone's clock: only the time since then counts, so a
  /// skewed clock neither shortens nor stretches the code.
  final DateTime receivedAt;

  /// The link was handed to the share sheet: the code may be in a message
  /// now, so leaving the screen does not revoke it.
  bool shared = false;
}

/// The QR code of an invite for [profileId] with [role] (docs/adr/0020):
/// made when the panel appears (the owner confirmed the disclosure before),
/// counted down from the server's own `created_at` / `expires_at`, renewed on
/// «Обновить код» and on a change of [role]. While it is on screen the
/// invite's state is polled; when someone accepts it, [onAccepted] gets the
/// new relative's name (null when unknown). A code that was never shared is
/// revoked when it is replaced or the panel goes; a shared one lives out its
/// minutes. The token is kept in memory only.
class InviteCodePanel extends ConsumerStatefulWidget {
  /// Creates the panel.
  const InviteCodePanel({
    required this.profileId,
    required this.role,
    required this.onAccepted,
    this.belowCode,
    super.key,
  });

  /// The profile the invite opens.
  final String profileId;

  /// The role it grants.
  final String role;

  /// Someone accepted the code.
  final ValueChanged<String?> onAccepted;

  /// A control under the code (the role box).
  final Widget? belowCode;

  @override
  ConsumerState<InviteCodePanel> createState() => _InviteCodePanelState();
}

class _InviteCodePanelState extends ConsumerState<InviteCodePanel> {
  // Read once: the panel still revokes its code from dispose().
  late final FamilyActions _actions = ref.read(familyActionsProvider);
  late final RelativesApi _api = ref.read(relativesApiProvider);
  late final RelativesRepository _links = ref.read(relativesRepositoryProvider);
  late final Clock _clock = ref.read(clockProvider);
  late final IdGenerator _newId = ref.read(idGeneratorProvider);
  late final LinkConfig _linkConfig = ref.read(linkConfigProvider);

  _Code? _code;
  bool _creating = false;
  bool _expired = false;
  bool _accepted = false;
  bool _checking = false;
  String? _errorCode;
  Set<String> _knownLinks = const {};
  Timer? _tick;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _creating = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_create());
      }
    });
  }

  @override
  void didUpdateWidget(InviteCodePanel old) {
    super.didUpdateWidget(old);
    // While a code is being made, _create sees the new role when it lands.
    if (old.role != widget.role && !_creating) {
      _drop();
      unawaited(_create());
    }
  }

  @override
  void dispose() {
    _drop();
    super.dispose();
  }

  /// Stops the timers and revokes the code unless it was shared, accepted
  /// or ran out.
  void _drop() {
    _stopTimers();
    final code = _code;
    _code = null;
    if (code != null && !code.shared && !_accepted && !_expired) {
      unawaited(_actions.discardInvite(widget.profileId, code.invite.id));
    }
  }

  void _stopTimers() {
    _tick?.cancel();
    _poll?.cancel();
    _tick = null;
    _poll = null;
  }

  Future<void> _create() async {
    setState(() {
      _creating = true;
      _expired = false;
      _errorCode = null;
    });
    try {
      final role = widget.role;
      _knownLinks = {for (final link in await _links.links()) link.id};
      final created = await _actions.createInvite(
        profileId: widget.profileId,
        inviteId: _newId(),
        role: role,
        disclosureVersion: inviteDisclosureVersion,
      );
      // Only a link of this region's hosts is shown or shared.
      final trusted = parseInviteLink(created.url, _linkConfig).token != null;
      if (!trusted || !mounted || role != widget.role) {
        unawaited(_actions.discardInvite(widget.profileId, created.id));
        if (!trusted) {
          _fail(RelativesClientErrors.untrustedInviteLink);
        } else if (mounted) {
          // The role changed while the code was made: make the right one.
          unawaited(_create());
        }
        return;
      }
      setState(() {
        _code = _Code(created, _clock());
        _creating = false;
      });
      _tick = Timer.periodic(InviteTiming.tick, (_) => _onTick());
      _poll = Timer.periodic(InviteTiming.poll, (_) => unawaited(_check()));
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

  Duration get _left {
    final code = _code;
    if (code == null) {
      return Duration.zero;
    }
    return code.invite.lifetime - _clock().difference(code.receivedAt);
  }

  void _onTick() {
    if (_left <= Duration.zero) {
      _expire();
    } else {
      setState(() {});
    }
  }

  void _expire() {
    _stopTimers();
    setState(() => _expired = true);
  }

  Future<void> _check() async {
    final code = _code;
    if (code == null || _checking) {
      return;
    }
    _checking = true;
    try {
      final status = await _api.inviteStatus(code.invite.id);
      if (!mounted || _code != code) {
        return;
      }
      switch (status.state) {
        case InviteState.consumed:
          await _announce();
        case InviteState.expired:
        case InviteState.revoked:
          _expire();
      }
    } on ApiException catch (error) {
      // Gone for this account (its profile deleted): nothing to wait for.
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
  Future<void> _announce() async {
    _accepted = true;
    _stopTimers();
    try {
      await _actions.refresh();
    } on Exception {
      // The list refreshes on the next sync; the name is then unknown here.
    }
    RelativeLinkRow? added;
    for (final link in await _links.links()) {
      if (link.direction == LinkDirection.outgoing &&
          link.profileId == widget.profileId &&
          !_knownLinks.contains(link.id)) {
        added = link;
      }
    }
    if (mounted) {
      final name = added?.counterpartName;
      widget.onAccepted(name == null || name.isEmpty ? null : name);
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
    final minutes = code.invite.lifetime.inMinutes;
    try {
      await ref.read(textSharerProvider)(
        l10n.inviteShareText(code.invite.url, minutes),
      );
    } on Exception {
      // No share sheet: the code stays on screen to be scanned.
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final error = _errorCode;
    if (error != null) {
      return _failure(l10n, error);
    }
    final code = _code;
    return InviteCodeView(
      area: _expired
          ? InviteCodeArea.expired
          : code == null || _creating
              ? InviteCodeArea.creating
              : InviteCodeArea.code,
      url: code?.invite.url,
      left: _left,
      onShare: () => unawaited(_share(l10n)),
      onRefresh: _refresh,
      belowCode: widget.belowCode,
    );
  }

  Widget _failure(AppLocalizations l10n, String error) {
    final extra = widget.belowCode;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PillPalBanner(
          tone: BannerTone.danger,
          liveRegion: true,
          body: relativesErrorMessage(l10n, error),
          bodyKey: const Key('invite-error'),
        ),
        if (extra != null) ...[
          const Gap.v(PillPalSpacing.lg),
          extra,
        ],
        const Gap.v(PillPalSpacing.lg),
        OutlinedButton(
          key: const Key('invite-retry'),
          onPressed: _refresh,
          child: Text(l10n.inviteCodeRetry),
        ),
      ],
    );
  }
}
