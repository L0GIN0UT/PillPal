import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/db/database.dart';
import '../common/person_row.dart';
import '../common/pillpal_icon_button.dart';
import '../common/status_kind.dart';
import '../common/status_pill.dart';
import 'day_status_providers.dart';
import 'day_status_view.dart';
import 'profile_context.dart';

/// The localized name of a role (`ScopeRole` wire value).
String roleLabel(AppLocalizations l10n, String role) {
  switch (role) {
    case ScopeRole.owner:
      return l10n.roleOwner;
    case ScopeRole.guardian:
      return l10n.roleGuardian;
    case ScopeRole.editor:
      return l10n.roleEditor;
    default:
      return l10n.roleViewer;
  }
}

/// What a role may do, in a sentence (the disclosure and the detail screen).
String roleExplanation(AppLocalizations l10n, String role) {
  switch (role) {
    case ScopeRole.guardian:
      return l10n.roleGuardianHint;
    case ScopeRole.editor:
      return l10n.roleEditorHint;
    default:
      return l10n.roleViewerHint;
  }
}

/// A person who sees one of my profiles ("Видят меня"). Inactive links
/// (their account or mine is being deleted) stay listed and say so with a
/// status pill. The row key is `link-<id>`.
class OutgoingLinkTile extends StatelessWidget {
  /// Creates the tile.
  const OutgoingLinkTile({required this.link, required this.onTap, super.key});

  /// The stored link.
  final RelativeLinkRow link;

  /// Opens the link's detail.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final managed = link.profileKind == 'managed';
    return PillPalPersonRow(
      rowKey: ValueKey('link-${link.id}'),
      name: link.counterpartName ?? l10n.relativeUnnamed,
      subtitle: [
        roleLabel(l10n, link.role),
        if (managed && link.profileName.isNotEmpty)
          l10n.linkForProfile(link.profileName),
      ].join(' · '),
      status: link.active
          ? null
          : StatusPill(StatusKind.inactive, label: l10n.linkInactive),
      chevron: true,
      onTap: onTap,
    );
  }
}

/// Someone's profile I see ("Я вижу"): tapping opens their day, the icon
/// opens the link's settings. The row key is `link-<id>`.
class IncomingLinkTile extends StatelessWidget {
  /// Creates the tile.
  const IncomingLinkTile({
    required this.link,
    required this.onOpen,
    required this.onSettings,
    this.dayStatus,
    super.key,
  });

  /// The stored link.
  final RelativeLinkRow link;

  /// Opens the profile's day.
  final VoidCallback onOpen;

  /// Opens the link's settings.
  final VoidCallback onSettings;

  /// How the profile's day is going, from the local data; null shows none.
  final ProfileDayStatus? dayStatus;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final day = dayStatusParts(l10n, dayStatus, link.profileId);
    return PillPalPersonRow(
      rowKey: ValueKey('link-${link.id}'),
      name: link.profileName.isEmpty ? l10n.relativeUnnamed : link.profileName,
      subtitle: [
        roleLabel(l10n, link.role),
        if (link.counterpartName case final counterpart?) counterpart,
      ].join(' · '),
      detail: day.detail,
      status: day.pill,
      onTap: onOpen,
      action: PillPalIconButton(
        key: ValueKey('link-settings-${link.id}'),
        icon: Icons.tune,
        tooltip: l10n.relativeSettings,
        onPressed: onSettings,
      ),
    );
  }
}

/// A managed profile I run ("Подопечные"). The row key is `ward-<id>`.
class WardTile extends StatelessWidget {
  /// Creates the tile.
  const WardTile({
    required this.access,
    required this.onOpen,
    required this.onEdit,
    this.dayStatus,
    super.key,
  });

  /// The profile and my role on it.
  final ProfileAccess access;

  /// Opens the profile's day.
  final VoidCallback onOpen;

  /// Opens the profile's form (null for an archive: nothing to edit).
  final VoidCallback? onEdit;

  /// How the profile's day is going, from the local data; null shows none.
  /// An archive shows its own pill instead.
  final ProfileDayStatus? dayStatus;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final edit = onEdit;
    final day = dayStatusParts(l10n, dayStatus, access.id);
    return PillPalPersonRow(
      rowKey: ValueKey('ward-${access.id}'),
      name: access.profile.displayName,
      subtitle: roleLabel(l10n, access.role),
      detail: access.archived ? null : day.detail,
      status: access.archived
          ? StatusPill(StatusKind.inactive, label: l10n.wardArchived)
          : day.pill,
      chevron: edit == null,
      onTap: onOpen,
      action: edit == null
          ? null
          : PillPalIconButton(
              key: ValueKey('ward-edit-${access.id}'),
              icon: Icons.edit_outlined,
              tooltip: l10n.wardEdit,
              onPressed: edit,
            ),
    );
  }
}
