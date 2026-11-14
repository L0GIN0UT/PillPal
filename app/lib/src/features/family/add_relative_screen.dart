import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/db/database.dart';
import '../../routing/routes.dart';
import '../../theme/palette.dart';
import '../../theme/spacing.dart';
import '../common/gap.dart';
import '../common/pillpal_check_tile.dart';
import '../common/section_header.dart';
import '../common/stacked_buttons.dart';
import '../doses/dose_providers.dart';
import 'family_tiles.dart';
import 'invite_code_panel.dart';
import 'invite_disclosure.dart';
import 'invite_scan_sheet.dart';
import 'relative_added_view.dart';

/// The lead text of the screen's sections: one style for all of them.
TextStyle? addRelativeLeadStyle(BuildContext context) => Theme.of(context)
    .textTheme
    .bodyLarge
    ?.copyWith(color: context.palette.inkMuted);

/// «Добавить близкого» (relatives redesign, docs/adr/0020): one screen for
/// both sides of a link, which goes one way only. The data owner picks the
/// role (the box «Может менять мои лекарства»), reads the disclosure of that
/// role and confirms exactly that screen with «Показать мой код»
/// (`disclosure_version` is sent); whoever scans the code sees the owner's
/// medications. Changing the box while the code is shown hides it, revokes
/// it even if it was shared and asks for the confirmation again. The other
/// person scans a code here; a person without a smartphone is managed
/// instead («Веду сам»). No names are asked here.
class AddRelativeScreen extends ConsumerStatefulWidget {
  /// Creates the screen.
  const AddRelativeScreen({super.key});

  @override
  ConsumerState<AddRelativeScreen> createState() => _AddRelativeState();
}

class _AddRelativeState extends ConsumerState<AddRelativeScreen> {
  GlobalKey<InviteCodePanelState> _panel = GlobalKey();
  bool _showing = false;
  bool _editor = false;
  AcceptedRelative? _accepted;

  String get _role => _editor ? ScopeRole.editor : ScopeRole.viewer;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final selfId = ref.watch(selfProfileProvider).valueOrNull?.id;
    final accepted = _accepted;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.addRelativeTitle)),
      body: SafeArea(
        child: ListView(
          key: const Key('add-relative-list'),
          padding: PillPalSpacing.form,
          children: [
            if (accepted != null)
              RelativeAddedView(
                accepted: accepted,
                onDone: () => context.pop(),
              )
            else if (_showing && selfId != null)
              InviteCodePanel(
                key: _panel,
                profileId: selfId,
                role: _role,
                onAccepted: (who) => setState(() => _accepted = who),
                belowCode: (locked) => _roleBox(l10n, enabled: !locked),
                secondaryAction: OutlinedButton(
                  key: const Key('add-relative-done'),
                  onPressed: () => context.pop(),
                  child: Text(l10n.done),
                ),
              )
            else ...[
              ..._confirm(context, enabled: selfId != null),
              // Only before a code is shown: then the screen is about it.
              ..._otherWays(context),
            ],
          ],
        ),
      ),
    );
  }

  /// Before the code: the role, what the relative will see with it, then
  /// «Показать мой код», which confirms exactly this disclosure.
  List<Widget> _confirm(BuildContext context, {required bool enabled}) {
    final l10n = AppLocalizations.of(context);
    return [
      Text(l10n.addRelativeIntro, style: addRelativeLeadStyle(context)),
      const Gap.v(PillPalSpacing.md),
      _roleBox(l10n, enabled: true),
      const Gap.v(PillPalSpacing.md),
      InviteDisclosure(role: _role, forSelf: true),
      const Gap.v(PillPalSpacing.lg),
      StackedButtons(
        children: [
          FilledButton.icon(
            key: const Key('add-relative-show-code'),
            onPressed: enabled ? _showCode : null,
            icon: const Icon(Icons.qr_code_2),
            label: Text(l10n.addRelativeShowCode),
          ),
        ],
      ),
    ];
  }

  void _showCode() {
    setState(() {
      _panel = GlobalKey();
      _showing = true;
    });
  }

  /// Observer by default, helper when ticked; the tick is explained by what
  /// a helper may do. Off while an acceptance is being announced.
  Widget _roleBox(AppLocalizations l10n, {required bool enabled}) {
    return PillPalCheckTile(
      tileKey: const Key('add-relative-editor'),
      value: _editor,
      title: l10n.addRelativeEditor,
      subtitle: roleExplanation(l10n, ScopeRole.editor),
      onChanged: enabled ? _changeRole : null,
    );
  }

  void _changeRole(bool editor) {
    if (_showing) {
      // The code grants the old role: it goes even if it was shared, and
      // the new role's disclosure is confirmed again.
      _panel.currentState?.revokeEvenIfShared();
    }
    setState(() {
      _editor = editor;
      _showing = false;
    });
  }

  /// Scanning someone else's code, and a person without a smartphone.
  List<Widget> _otherWays(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return [
      SectionHeader(l10n.addRelativeScanTitle),
      Text(l10n.addRelativeScanHint, style: addRelativeLeadStyle(context)),
      const Gap.v(PillPalSpacing.md),
      StackedButtons(
        children: [
          OutlinedButton.icon(
            key: const Key('add-relative-scan'),
            onPressed: () => unawaited(_scan()),
            icon: const Icon(Icons.qr_code_scanner),
            label: Text(l10n.addRelativeScan),
          ),
        ],
      ),
      const Gap.v(PillPalSpacing.xl),
      Center(
        child: TextButton(
          key: const Key('add-relative-managed'),
          onPressed: () => unawaited(context.push(AppRoutes.newManagedProfile)),
          child: Text(l10n.addRelativeManaged, textAlign: TextAlign.center),
        ),
      ),
    ];
  }

  Future<void> _scan() async {
    final outcome = await showInviteScanSheet(context);
    if (outcome == null || !mounted) {
      return;
    }
    // A scanned link waits in the invite intake; the accept screen takes it
    // (or shows the paste form when the person chose to paste instead).
    unawaited(context.push(AppRoutes.acceptInvite));
  }
}
