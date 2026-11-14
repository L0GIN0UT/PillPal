import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/db/database.dart';
import '../common/person_row.dart';
import '../common/pillpal_icon_button.dart';
import '../common/status_kind.dart';
import '../common/status_pill.dart';
import 'day_status_providers.dart';
import 'day_status_view.dart';
import 'relatives_list.dart';

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

/// The short label of [role] in the list and on the card: «подопечный»,
/// «наблюдатель», «опекун · Pat», «веду вместе с Robin».
String relativeRoleLabel(AppLocalizations l10n, RelativeRole role) {
  final base = switch (role.kind) {
    RelativeRoleKind.ward => l10n.relativeRoleWard,
    RelativeRoleKind.wardEditor => l10n.relativeRoleWardEditor,
    RelativeRoleKind.observer => l10n.relativeRoleObserver,
    RelativeRoleKind.helper => l10n.relativeRoleHelper,
    RelativeRoleKind.guardian => l10n.relativeRoleGuardian,
    RelativeRoleKind.managedByMe => l10n.relativeRoleManagedByMe,
    RelativeRoleKind.coGuardian => switch (role.ownerName) {
        final owner? => l10n.relativeRoleCoGuardian(owner),
        null => l10n.relativeRoleGuardian,
      },
  };
  final profile = role.profileName;
  return profile == null ? base : '$base · $profile';
}

/// Every role of [relative], comma-separated (a role may itself hold " · ").
String relativeRolesLine(AppLocalizations l10n, Relative relative) => [
      for (final role in relative.roles) relativeRoleLabel(l10n, role)
    ].join(', ');

/// The name of [relative] as the list shows it: "{note} ({name})" with a
/// note, the name alone without one.
String relativeDisplayName(AppLocalizations l10n, Relative relative) =>
    relativeTitle(
      name: relative.name.isEmpty ? l10n.relativeUnnamed : relative.name,
      note: relative.note,
    );

/// A row of «Близкие»: the note and name, the roles under them and how
/// their day goes. Tapping opens their day when I see their data, else the
/// card; the pencil always opens the card. The row key is
/// `relative-<key>`, the pencil's `relative-edit-<key>`.
class RelativeTile extends StatelessWidget {
  /// Creates the tile.
  const RelativeTile({
    required this.relative,
    required this.onOpen,
    required this.onEdit,
    this.dayStatus,
    super.key,
  });

  /// The row.
  final Relative relative;

  /// Opens the relative's day (or the card when there is no day to see).
  final VoidCallback onOpen;

  /// Opens the relative's card.
  final VoidCallback onEdit;

  /// How the relative's day is going, from the local data; null shows none.
  final ProfileDayStatus? dayStatus;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final name = relativeDisplayName(l10n, relative);
    final quiet = relative.archived || relative.inactive;
    final day = dayStatusParts(
      l10n,
      quiet ? null : dayStatus,
      relative.dayProfileId ?? relative.key,
    );
    final status = relative.archived
        ? StatusPill(StatusKind.inactive, label: l10n.wardArchived)
        : relative.inactive
            ? StatusPill(StatusKind.inactive, label: l10n.linkInactive)
            : day.pill;
    return PillPalPersonRow(
      rowKey: ValueKey('relative-${relative.key}'),
      name: name,
      subtitle: relativeRolesLine(l10n, relative),
      detail: day.detail,
      status: status,
      onTap: onOpen,
      action: PillPalIconButton(
        key: ValueKey('relative-edit-${relative.key}'),
        icon: Icons.edit_outlined,
        tooltip: l10n.relativeEdit(name),
        onPressed: onEdit,
      ),
    );
  }
}
