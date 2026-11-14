import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/db/database.dart';
import '../../theme/palette.dart';
import '../../theme/spacing.dart';
import '../common/gap.dart';
import '../common/section_header.dart';
import '../common/stacked_buttons.dart';
import 'invite_code_panel.dart';
import 'invite_code_view.dart';
import 'invite_disclosure.dart';
import 'profile_context.dart';
import 'role_cards.dart';

/// Creates an invite for [profileId] (a managed profile: a co-guardian, an
/// observer or a helper; the own profile goes through «Добавить близкого»):
/// the role, the disclosure the owner confirms (`disclosure_version` is
/// sent), then the same QR panel as there: countdown, «Обновить код», share
/// and the news when the code is accepted. Guardians can be invited to
/// managed profiles only.
class InviteCreateScreen extends ConsumerStatefulWidget {
  /// Creates the screen.
  const InviteCreateScreen({required this.profileId, super.key});

  /// The profile the invite is for.
  final String profileId;

  @override
  ConsumerState<InviteCreateScreen> createState() => _InviteCreateState();
}

class _InviteCreateState extends ConsumerState<InviteCreateScreen> {
  String _role = ScopeRole.viewer;
  bool _confirmed = false;
  bool _added = false;
  String? _addedName;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final access = ref.watch(profileAccessProvider(widget.profileId));
    final profile = access.valueOrNull;
    final allowed = profile != null && profile.canManageLinks;
    final asking = allowed && !_confirmed;
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
                  else if (_added)
                    RelativeAddedView(
                      name: _addedName,
                      onDone: () => context.pop(),
                    )
                  else if (_confirmed)
                    ..._code(context)
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
                  onPressed: () => setState(() => _confirmed = true),
                  child: Text(l10n.inviteCreate),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _code(BuildContext context) {
    return [
      InviteCodePanel(
        profileId: widget.profileId,
        role: _role,
        onAccepted: (name) => setState(() {
          _added = true;
          _addedName = name;
        }),
      ),
      const Gap.v(PillPalSpacing.sm),
      StackedButtons(
        children: [
          OutlinedButton(
            key: const Key('invite-done'),
            onPressed: () => context.pop(),
            child: Text(AppLocalizations.of(context).done),
          ),
        ],
      ),
    ];
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
    ];
  }
}
