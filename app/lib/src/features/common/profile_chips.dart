import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/radius.dart';
import '../../theme/spacing.dart';
import 'gap.dart';
import 'sheet_scaffold.dart';

/// One person in [ProfileChips]: an opaque id and the name to show.
@immutable
class ProfileChipItem {
  /// Creates an item.
  const ProfileChipItem({required this.id, required this.label});

  /// Id of the profile; passed back to `onSelected`.
  final String id;

  /// Name or short label of the person.
  final String label;
}

/// "Whose medications" under the title of Today and Family (B2-README
/// `profileChips`, section 9.5): at most [maxVisible] chips, the selected one
/// always first, and, when there are more profiles, a pinned «Все N» chip that
/// opens a sheet with everyone. The row scrolls sideways instead of wrapping,
/// and a 32 px fade to the page colour shows that there is more while it does.
///
/// The chips are drawn for the page background (`bg`): the fade ends in it,
/// so do not put the row on a card.
///
/// Chips are 44 high (64 in senior mode); the selected one is `actionSoft`
/// with a check, so it is not told apart by colour alone. A chip has the key
/// `profile-switch-<id>`, the «Все N» chip `profile-chips-all`, a row of the
/// sheet `profile-sheet-<id>`, the fade `profile-chips-fade`.
class ProfileChips extends StatefulWidget {
  /// Creates the chips for [profiles].
  const ProfileChips({
    required this.profiles,
    required this.selectedId,
    required this.onSelected,
    super.key,
  });

  /// How many chips are visible before the «Все N» chip appears.
  static const int maxVisible = 4;

  /// Everyone the user may switch to, in display order.
  final List<ProfileChipItem> profiles;

  /// The current profile.
  final String selectedId;

  /// Called with the id of the profile the user picks.
  final ValueChanged<String> onSelected;

  @override
  State<ProfileChips> createState() => _ProfileChipsState();
}

class _ProfileChipsState extends State<ProfileChips> {
  final ScrollController _scroll = ScrollController();

  /// Whether the row scrolls on to the end.
  bool _more = false;

  @override
  void didUpdateWidget(ProfileChips oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The selected chip moves to the front: show the front.
    if (oldWidget.selectedId != widget.selectedId && _scroll.hasClients) {
      _scroll.jumpTo(0);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  List<ProfileChipItem> get _visible {
    final selected = widget.profiles.where((p) => p.id == widget.selectedId);
    final others = widget.profiles.where((p) => p.id != widget.selectedId);
    return [...selected, ...others].take(ProfileChips.maxVisible).toList();
  }

  bool _onScroll(ScrollMetrics metrics) {
    final more = metrics.extentAfter > 0;
    if (more != _more) {
      setState(() => _more = more);
    }
    return false;
  }

  Future<void> _showAll() {
    final l10n = AppLocalizations.of(context);
    return showPillPalSheet<void>(
      context,
      (sheetContext) => SheetScaffold(
        title: l10n.profilesSheetTitle,
        children: [
          for (final profile in widget.profiles)
            ListTile(
              key: ValueKey('profile-sheet-${profile.id}'),
              minTileHeight: context.metrics.touchTarget,
              selected: profile.id == widget.selectedId,
              title: Text(profile.label),
              trailing: profile.id == widget.selectedId
                  ? const Icon(Icons.check)
                  : null,
              onTap: () {
                Navigator.of(sheetContext).pop();
                widget.onSelected(profile.id);
              },
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    assert(
      widget.profiles.any((p) => p.id == widget.selectedId),
      'selectedId must be one of the profiles',
    );
    final showAll = widget.profiles.length > ProfileChips.maxVisible;
    final visible = _visible;
    return Row(
      children: [
        Expanded(
          child: Stack(
            children: [
              NotificationListener<ScrollMetricsNotification>(
                onNotification: (n) => _onScroll(n.metrics),
                child: NotificationListener<ScrollNotification>(
                  onNotification: (n) => _onScroll(n.metrics),
                  child: SingleChildScrollView(
                    controller: _scroll,
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (var i = 0; i < visible.length; i++) ...[
                          if (i > 0) const Gap.h(PillPalSpacing.sm),
                          _Chip(
                            key: ValueKey('profile-switch-${visible[i].id}'),
                            label: visible[i].label,
                            selected: visible[i].id == widget.selectedId,
                            onTap: () => widget.onSelected(visible[i].id),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              if (_more) const _Fade(),
            ],
          ),
        ),
        if (showAll) ...[
          const Gap.h(PillPalSpacing.sm),
          _Chip(
            key: const Key('profile-chips-all'),
            label: l10n.profileAll(widget.profiles.length),
            selected: false,
            onTap: _showAll,
          ),
        ],
      ],
    );
  }
}

/// The 32 px gradient from transparent to the page colour at the end of the
/// scrolling row. It lets touches through.
class _Fade extends StatelessWidget {
  const _Fade();

  @override
  Widget build(BuildContext context) {
    final page = context.palette.background;
    return Positioned.directional(
      textDirection: Directionality.of(context),
      end: 0,
      top: 0,
      bottom: 0,
      width: PillPalSizes.chipFade,
      child: IgnorePointer(
        child: DecoratedBox(
          key: const Key('profile-chips-fade'),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: AlignmentDirectional.centerStart,
              end: AlignmentDirectional.centerEnd,
              // The page colour at no opacity: fading from transparent
              // black would grey the middle of the gradient.
              colors: [page.withAlpha(0), page],
            ),
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final height =
        math.max(PillPalSizes.profileChip, context.metrics.touchTarget);
    final foreground = selected ? palette.onActionSoft : palette.ink;
    return Semantics(
      label: label,
      button: true,
      selected: selected,
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
        color: selected ? palette.actionSoft : palette.surface,
        shape: StadiumBorder(
          side: selected
              ? BorderSide.none
              : BorderSide(color: palette.border, width: PillPalSizes.hairline),
        ),
        child: InkWell(
          customBorder: PillPalRadius.pill,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: height, minWidth: height),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: PillPalSpacing.lg),
              // heightFactor: the chip is as high as its content or the
              // minimum, never as high as the space the parent offers.
              child: Center(
                widthFactor: 1,
                heightFactor: 1,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (selected) ...[
                      Icon(
                        Icons.check,
                        size: PillPalSizes.chipIcon,
                        color: foreground,
                      ),
                      const Gap.h(PillPalSpacing.xs),
                    ],
                    // Cut long names; screen readers still get the whole label.
                    ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: PillPalSizes.chipLabelMaxWidth,
                      ),
                      child: Text(
                        label,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .labelMedium
                            ?.copyWith(color: foreground),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
