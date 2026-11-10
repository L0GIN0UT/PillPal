import 'package:flutter/material.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/db/database.dart';
import '../../theme/app_theme.dart';
import '../../theme/spacing.dart';
import '../common/gap.dart';
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
/// (their account or mine is being deleted) stay listed and say so.
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
    return Card(
      child: ListTile(
        key: ValueKey('link-${link.id}'),
        minVerticalPadding: PillPalSpacing.md,
        title: Text(link.counterpartName ?? l10n.relativeUnnamed),
        subtitle: Text(
          [
            roleLabel(l10n, link.role),
            if (managed && link.profileName.isNotEmpty)
              l10n.linkForProfile(link.profileName),
            if (!link.active) l10n.linkInactive,
          ].join(' · '),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

/// Someone's profile I see ("Я вижу"): tapping opens their day, the icon
/// opens the link's settings.
class IncomingLinkTile extends StatelessWidget {
  /// Creates the tile.
  const IncomingLinkTile({
    required this.link,
    required this.onOpen,
    required this.onSettings,
    super.key,
  });

  /// The stored link.
  final RelativeLinkRow link;

  /// Opens the profile's day.
  final VoidCallback onOpen;

  /// Opens the link's settings.
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _TileCard(
      action: IconButton(
        key: ValueKey('link-settings-${link.id}'),
        tooltip: l10n.relativeSettings,
        constraints: _targetConstraints(context),
        icon: const Icon(Icons.tune),
        onPressed: onSettings,
      ),
      tile: ListTile(
        key: ValueKey('link-${link.id}'),
        minVerticalPadding: PillPalSpacing.md,
        contentPadding: _tileContentPadding,
        title: Text(
          link.profileName.isEmpty ? l10n.relativeUnnamed : link.profileName,
        ),
        subtitle: Text(
          [
            roleLabel(l10n, link.role),
            if (link.counterpartName != null) link.counterpartName!,
          ].join(' · '),
        ),
        onTap: onOpen,
      ),
    );
  }
}

/// A managed profile I run ("Подопечные").
class WardTile extends StatelessWidget {
  /// Creates the tile.
  const WardTile({
    required this.access,
    required this.onOpen,
    required this.onEdit,
    super.key,
  });

  /// The profile and my role on it.
  final ProfileAccess access;

  /// Opens the profile's day.
  final VoidCallback onOpen;

  /// Opens the profile's form (null for an archive: nothing to edit).
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final edit = onEdit;
    return _TileCard(
      action: edit == null
          ? null
          : IconButton(
              key: ValueKey('ward-edit-${access.id}'),
              tooltip: l10n.wardEdit,
              constraints: _targetConstraints(context),
              icon: const Icon(Icons.edit_outlined),
              onPressed: edit,
            ),
      tile: ListTile(
        key: ValueKey('ward-${access.id}'),
        minVerticalPadding: PillPalSpacing.md,
        contentPadding: _tileContentPadding,
        title: Text(access.profile.displayName),
        subtitle: Text(
          [
            roleLabel(l10n, access.role),
            if (access.archived) l10n.wardArchived,
          ].join(' · '),
        ),
        onTap: onOpen,
      ),
    );
  }
}

// The tile ends where the action begins: no end padding, so the action sits
// at the same distance from the card edge as a trailing icon would.
const EdgeInsetsDirectional _tileContentPadding =
    EdgeInsetsDirectional.only(start: PillPalSpacing.lg);

BoxConstraints _targetConstraints(BuildContext context) => BoxConstraints(
      minWidth: context.metrics.touchTarget,
      minHeight: context.metrics.touchTarget,
    );

/// A card with a tappable [tile] and, beside it, an icon [action]. The action
/// is not the tile's `trailing`: a ListTile squeezes its trailing widget below
/// the touch target of the senior mode.
class _TileCard extends StatelessWidget {
  const _TileCard({required this.tile, this.action});

  final Widget tile;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final end = action;
    return Card(
      child: end == null
          ? tile
          : Row(
              children: [
                Expanded(child: tile),
                end,
                // The action's edge distance from the card: sm.
                const Gap.h(PillPalSpacing.sm),
              ],
            ),
    );
  }
}
