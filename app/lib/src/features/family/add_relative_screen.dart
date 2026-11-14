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
import 'invite_code_view.dart';
import 'invite_disclosure.dart';
import 'invite_scan_sheet.dart';

/// «Добавить близкого» (relatives redesign, docs/adr/0020): one screen for
/// both sides of a link, which goes one way only. The data owner confirms
/// what becomes visible (the disclosure, `disclosure_version` is sent), then
/// shows a QR code; whoever scans it sees the owner's medications, as an
/// observer or, with the box under the code, as a helper. The other person
/// scans a code here. A person without a smartphone is managed instead
/// («Веду сам»). No names are asked here.
class AddRelativeScreen extends ConsumerStatefulWidget {
  /// Creates the screen.
  const AddRelativeScreen({super.key});

  @override
  ConsumerState<AddRelativeScreen> createState() => _AddRelativeState();
}

class _AddRelativeState extends ConsumerState<AddRelativeScreen> {
  bool _showing = false;
  bool _editor = false;
  bool _added = false;
  String? _addedName;

  String get _role => _editor ? ScopeRole.editor : ScopeRole.viewer;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final selfId = ref.watch(selfProfileProvider).valueOrNull?.id;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.addRelativeTitle)),
      body: SafeArea(
        child: ListView(
          key: const Key('add-relative-list'),
          padding: PillPalSpacing.form,
          children: [
            if (_added)
              RelativeAddedView(
                name: _addedName,
                onDone: () => context.pop(),
              )
            else if (_showing && selfId != null)
              InviteCodePanel(
                profileId: selfId,
                role: _role,
                onAccepted: (name) => setState(() {
                  _added = true;
                  _addedName = name;
                }),
                belowCode: _roleBox(l10n),
              )
            else
              ..._confirm(context, enabled: selfId != null),
            if (!_added) ..._otherWays(context),
          ],
        ),
      ),
    );
  }

  /// Before the code: what the relative will see, then «Показать мой код».
  List<Widget> _confirm(BuildContext context, {required bool enabled}) {
    final l10n = AppLocalizations.of(context);
    return [
      Text(
        l10n.addRelativeIntro,
        style: Theme.of(context)
            .textTheme
            .bodyLarge
            ?.copyWith(color: context.palette.inkMuted),
      ),
      const Gap.v(PillPalSpacing.lg),
      const InviteDisclosure(role: ScopeRole.viewer, forSelf: true),
      const Gap.v(PillPalSpacing.lg),
      StackedButtons(
        children: [
          FilledButton.icon(
            key: const Key('add-relative-show-code'),
            onPressed: enabled ? () => setState(() => _showing = true) : null,
            icon: const Icon(Icons.qr_code_2),
            label: Text(l10n.addRelativeShowCode),
          ),
        ],
      ),
    ];
  }

  /// Under the code: observer by default, helper when ticked. The tick is
  /// explained by what a helper may do (part of the disclosure for that
  /// role); changing it makes a new code.
  Widget _roleBox(AppLocalizations l10n) {
    return PillPalCheckTile(
      tileKey: const Key('add-relative-editor'),
      value: _editor,
      title: l10n.addRelativeEditor,
      subtitle: roleExplanation(l10n, ScopeRole.editor),
      onChanged: (ticked) => setState(() => _editor = ticked),
    );
  }

  /// Scanning someone else's code, and a person without a smartphone.
  List<Widget> _otherWays(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final muted = Theme.of(context)
        .textTheme
        .bodyMedium
        ?.copyWith(color: context.palette.inkMuted);
    return [
      SectionHeader(l10n.addRelativeScanTitle),
      Text(l10n.addRelativeScanHint, style: muted),
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
