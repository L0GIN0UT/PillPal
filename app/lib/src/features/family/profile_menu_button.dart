import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/radius.dart';
import '../../theme/spacing.dart';
import '../common/clamped_text.dart';
import '../common/gap.dart';
import '../common/sheet_scaffold.dart';
import 'profile_context.dart';

/// «Whose medications» as a button in the header (board B-Medications): the
/// initial of the shown person on a soft disc and a chevron. It opens a
/// sheet with everyone the account may see; picking one switches the tabs.
/// Nothing is shown while there is only the own profile.
///
/// The button is a stadium with a `border` ring, at least as high as the
/// touch target of the mode. Keys: `medications-profile` (the button),
/// `profile-switch-<id>` (a row of the sheet).
class ProfileMenuButton extends ConsumerWidget {
  /// Creates the button.
  const ProfileMenuButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profiles = ref.watch(accessibleProfilesProvider).valueOrNull;
    if (profiles == null || profiles.length < 2) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);
    final selected = ref.watch(selectedProfileIdProvider);
    // The own profile is selected while nothing else is (null).
    final own = profiles.where((a) => a.isOwnSelf).map((a) => a.id).firstOrNull;
    final current = selected != null && profiles.any((a) => a.id == selected)
        ? selected
        : own ?? profiles.first.id;
    String nameOf(ProfileAccess access) =>
        access.isOwnSelf ? l10n.profileMe : access.profile.displayName;
    final name = nameOf(profiles.firstWhere((a) => a.id == current));
    return _Button(
      name: name,
      onTap: () => showPillPalSheet<void>(
        context,
        (sheetContext) => SheetScaffold(
          title: l10n.profilesSheetTitle,
          children: [
            for (final access in profiles)
              ListTile(
                key: ValueKey('profile-switch-${access.id}'),
                minTileHeight: sheetContext.metrics.touchTarget,
                selected: access.id == current,
                title: Text(nameOf(access)),
                trailing: access.id == current ? const Icon(Icons.check) : null,
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  ref
                      .read(selectedProfileIdProvider.notifier)
                      .select(access.id == own ? null : access.id);
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _Button extends StatelessWidget {
  const _Button({required this.name, required this.onTap});

  final String name;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final height = math.max(PillPalSizes.avatarMd, context.metrics.touchTarget);
    return Semantics(
      label: AppLocalizations.of(context).profileButtonLabel(name),
      button: true,
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
        color: palette.surface,
        shape: StadiumBorder(
          side: BorderSide(
            color: palette.border,
            width: PillPalSizes.fieldBorder,
          ),
        ),
        child: InkWell(
          key: const Key('medications-profile'),
          customBorder: PillPalRadius.pill,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: height, minWidth: height),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: PillPalSpacing.xs),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _Initial(name),
                  const Gap.h(PillPalSpacing.xs),
                  Icon(
                    Icons.expand_more,
                    size: PillPalSizes.iconInline,
                    color: palette.ink,
                  ),
                  const Gap.h(PillPalSpacing.xs),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The first letter of the name on a soft disc.
class _Initial extends StatelessWidget {
  const _Initial(this.name);

  final String name;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final letter = name.trim().isEmpty ? '' : name.trim().characters.first;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: palette.actionSoft,
        shape: const CircleBorder(),
      ),
      child: SizedBox.square(
        dimension: PillPalSizes.avatarSm,
        child: Center(
          child: Text(
            letter.toUpperCase(),
            // Decorative: the button says the whole name.
            style: Theme.of(context)
                .textTheme
                .labelLarge
                ?.copyWith(color: palette.onActionSoft),
            textScaler:
                context.clampedTextScaler(PillPalSizes.navLabelMaxScale),
          ),
        ),
      ),
    );
  }
}
