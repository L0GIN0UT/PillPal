import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/repositories/profile_access.dart';
import '../../routing/routes.dart';
import '../../theme/spacing.dart';
import '../common/gap.dart';
import '../common/section_header.dart';
import '../common/stacked_buttons.dart';
import 'family_overview.dart';
import 'family_providers.dart';
import 'family_tiles.dart';
import 'relative_detail_header.dart';
import 'relative_incoming_detail.dart';
import 'relative_note_editor.dart';
import 'relative_outgoing_detail.dart';
import 'relatives_list.dart';

/// The card of one relative (docs/adr/0020 §4): who it is, the private
/// note only the account sees, then a block per link: what I see of them
/// (alerts, open, disconnect), what they see of mine (privacy, role with
/// its disclosure, disconnect), and for my own managed profile the way to
/// its form.
///
/// Opened by the row's key ([AppRoutes.relative]) or, for older push
/// targets, by one of its links ([AppRoutes.link]), which shows the same
/// card.
class RelativeCardScreen extends ConsumerWidget {
  /// Creates the card of the row [relativeKey], or of the row holding link
  /// [linkId].
  const RelativeCardScreen({this.relativeKey, this.linkId, super.key})
      : assert(
          (relativeKey == null) != (linkId == null),
          'exactly one of relativeKey and linkId',
        );

  /// The row's key (a subject profile id, or a link id).
  final String? relativeKey;

  /// A link (grant) id of the row.
  final String? linkId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final overview = ref.watch(familyOverviewProvider);
    final data = overview.valueOrNull;
    final key = relativeKey;
    final relative = data == null
        ? null
        : key != null
            ? data.byKey(key)
            : data.byLink(linkId ?? '');
    return Scaffold(
      appBar: AppBar(title: Text(l10n.relativeDetailTitle)),
      body: SafeArea(
        child: relative == null
            ? Center(child: _missing(l10n, overview))
            : ListView(
                key: const Key('relative-card'),
                padding: PillPalSpacing.form,
                // One child: the blocks are built at once, so their data
                // streams start with the screen, not when scrolled to.
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: _children(context, l10n, relative),
                  ),
                ],
              ),
      ),
    );
  }

  /// While the list loads, when it failed, and when the person is gone.
  Widget _missing(AppLocalizations l10n, AsyncValue<FamilyOverview> overview) {
    if (overview.hasError) {
      return Text(l10n.errorGeneric, key: const Key('relative-error'));
    }
    if (overview.isLoading) {
      return const CircularProgressIndicator();
    }
    return Text(l10n.relativePersonGone, key: const Key('relative-gone'));
  }

  List<Widget> _children(
    BuildContext context,
    AppLocalizations l10n,
    Relative relative,
  ) {
    final subject = relative.subjectProfileId;
    final incoming = relative.incoming;
    final access = relative.access;
    // Ending one link closes the card only when nothing else relates us.
    final ties = relative.outgoing.length +
        (incoming == null ? 0 : 1) +
        (access == null ? 0 : 1);
    void disconnected() {
      if (ties <= 1 && context.mounted) {
        context.pop();
      }
    }

    return [
      RelativeDetailHeader(
        name: relativeDisplayName(l10n, relative),
        subtitle: relativeRolesLine(l10n, relative),
        // The letter is the person's, never the note's.
        avatarName: relative.name,
      ),
      if (relative.canHaveNote && subject != null) ...[
        const Gap.v(PillPalSpacing.xl),
        RelativeNoteEditor(
          // A fresh editor per person: a typed text never moves to another.
          key: ValueKey('relative-note-$subject'),
          profileId: subject,
          note: relative.note,
        ),
      ],
      if (incoming != null) ...[
        SectionHeader(l10n.relativeISee),
        IncomingDetail(
          key: ValueKey('incoming-${incoming.id}'),
          link: incoming,
          onDisconnected: disconnected,
        ),
      ],
      if (access != null)
        ..._managed(context, l10n, access, withDay: incoming == null),
      for (final link in relative.outgoing) ...[
        SectionHeader(
          link.profileKind == 'managed' && link.profileName.isNotEmpty
              ? l10n.relativeSeesProfile(link.profileName)
              : l10n.relativeSeesMine,
        ),
        OutgoingDetail(
          key: ValueKey('outgoing-${link.id}'),
          link: link,
          onDisconnected: disconnected,
        ),
      ],
    ];
  }

  /// A managed profile I own («веду сам») or guard: its form while it can
  /// be edited, and [withDay] its day (a guardian's link block has its own
  /// «Открыть»).
  List<Widget> _managed(
    BuildContext context,
    AppLocalizations l10n,
    ProfileAccess access, {
    required bool withDay,
  }) {
    if (!withDay && !access.canEditProfile) {
      return const [];
    }
    return [
      SectionHeader(l10n.relativeManagedTitle),
      StackedButtons(
        children: [
          if (withDay)
            FilledButton(
              key: const Key('relative-open-day'),
              onPressed: () =>
                  unawaited(context.push(AppRoutes.profileToday(access.id))),
              child: Text(l10n.openProfile),
            ),
          if (access.canEditProfile)
            OutlinedButton.icon(
              key: const Key('relative-managed-edit'),
              onPressed: () =>
                  unawaited(context.push(AppRoutes.managedProfile(access.id))),
              icon: const Icon(Icons.edit_outlined),
              label: Text(l10n.wardEdit),
            ),
        ],
      ),
    ];
  }
}
