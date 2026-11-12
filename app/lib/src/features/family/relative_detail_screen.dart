import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/db/database.dart';
import '../../data/repositories/relatives_repository.dart';
import '../../theme/spacing.dart';
import 'family_providers.dart';
import 'relative_incoming_detail.dart';
import 'relative_outgoing_detail.dart';

/// One link to a relative. The owner of an outgoing link sees what the
/// relative sees, edits the privacy of each medication (D4), changes the
/// role between viewer and editor (after the disclosure, with its version)
/// or revokes it; the grantee of an incoming link chooses whether to be
/// alerted about missed doses, or leaves.
class RelativeDetailScreen extends ConsumerWidget {
  /// Creates the screen for link [linkId].
  const RelativeDetailScreen({required this.linkId, super.key});

  /// The link (grant) id.
  final String linkId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final links = ref.watch(grantLinksProvider);
    RelativeLinkRow? link;
    for (final row in links.valueOrNull ?? const <RelativeLinkRow>[]) {
      if (row.id == linkId) {
        link = row;
      }
    }
    return Scaffold(
      appBar: AppBar(title: Text(l10n.relativeDetailTitle)),
      body: SafeArea(
        child: link == null
            ? Center(
                child: links.isLoading
                    ? const CircularProgressIndicator()
                    : Text(l10n.relativeGone, key: const Key('relative-gone')),
              )
            : ListView(
                padding: PillPalSpacing.form,
                children: [
                  link.direction == LinkDirection.outgoing
                      ? OutgoingDetail(link: link)
                      : IncomingDetail(link: link),
                ],
              ),
      ),
    );
  }
}
