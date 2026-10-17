import 'package:flutter/material.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/db/database.dart';
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

/// A heading of a Family section.
class FamilySectionHeader extends StatelessWidget {
  /// Creates the heading.
  const FamilySectionHeader(this.title, {super.key});

  /// Section title.
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 8),
      child: Text(title, style: Theme.of(context).textTheme.titleLarge),
    );
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
        minVerticalPadding: 12,
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
    return Card(
      child: ListTile(
        key: ValueKey('link-${link.id}'),
        minVerticalPadding: 12,
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
        trailing: IconButton(
          key: ValueKey('link-settings-${link.id}'),
          tooltip: l10n.relativeSettings,
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          icon: const Icon(Icons.tune),
          onPressed: onSettings,
        ),
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
    return Card(
      child: ListTile(
        key: ValueKey('ward-${access.id}'),
        minVerticalPadding: 12,
        title: Text(access.profile.displayName),
        subtitle: Text(
          [
            roleLabel(l10n, access.role),
            if (access.archived) l10n.wardArchived,
          ].join(' · '),
        ),
        onTap: onOpen,
        trailing: edit == null
            ? null
            : IconButton(
                key: ValueKey('ward-edit-${access.id}'),
                tooltip: l10n.wardEdit,
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                icon: const Icon(Icons.edit_outlined),
                onPressed: edit,
              ),
      ),
    );
  }
}
