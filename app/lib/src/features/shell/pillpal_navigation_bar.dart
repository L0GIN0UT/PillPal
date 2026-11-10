import 'package:flutter/material.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/radius.dart';
import '../../theme/shadows.dart';
import '../../theme/spacing.dart';
import '../common/gap.dart';

/// The bottom navigation of the four tabs (B2-README `navBar`, sections 3 and
/// 9.9): a `surface` bar with rounded top corners, a soft shadow in light
/// themes and a 1 px `border` line in dark ones. The selected destination is
/// a tonal shape around the icon and the label together.
///
/// The labels stop growing at x1.15 (x1.0 in senior mode) like the system's
/// bar; a label that still
/// does not fit shrinks, and the whole text is the tooltip of the destination
/// (a long press). The widget stays a Material [NavigationBar], which the
/// emulator journeys look for.
class PillPalNavigationBar extends StatelessWidget {
  /// Creates the bar.
  const PillPalNavigationBar({
    required this.selectedIndex,
    required this.onSelected,
    super.key,
  });

  /// The selected tab.
  final int selectedIndex;

  /// Called with the index of the tapped tab.
  final ValueChanged<int> onSelected;

  static const BorderRadius _topCorners =
      BorderRadius.vertical(top: Radius.circular(PillPalRadius.navTop));

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final palette = context.palette;
    final brightness = Theme.of(context).brightness;
    final media = MediaQuery.of(context);
    final items = [
      (Icons.schedule_outlined, Icons.schedule, l10n.navToday),
      (Icons.medication_outlined, Icons.medication, l10n.navMedications),
      (Icons.people_outline, Icons.people, l10n.navFamily),
      (Icons.calendar_month_outlined, Icons.calendar_month, l10n.navHistory),
    ];
    return MediaQuery(
      data: media.copyWith(
        textScaler: media.textScaler.clamp(
          // Senior mode keeps the label at its normal size: its bar is
          // taller, not wider, and «Лекарства» must fit at 320 px.
          maxScaleFactor: context.metrics.isSenior
              ? PillPalSizes.navLabelSeniorMaxScale
              : PillPalSizes.navLabelMaxScale,
        ),
      ),
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: palette.surface,
          shadows: PillPalShadows.forBrightness(brightness, PillPalShadows.nav),
          shape: RoundedRectangleBorder(
            borderRadius: _topCorners,
            side: brightness == Brightness.dark
                ? BorderSide(
                    color: palette.border, width: PillPalSizes.hairline)
                : BorderSide.none,
          ),
        ),
        child: ClipRRect(
          borderRadius: _topCorners,
          child: NavigationBar(
            selectedIndex: selectedIndex,
            onDestinationSelected: onSelected,
            backgroundColor: Colors.transparent,
            // The indicator is drawn by the destination, around icon and
            // label; the bar's own one only reaches the icon.
            indicatorColor: Colors.transparent,
            labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
            destinations: [
              for (var i = 0; i < items.length; i++)
                NavigationDestination(
                  icon: _NavItem(
                    index: i,
                    icon: items[i].$1,
                    label: items[i].$3,
                    selected: false,
                  ),
                  selectedIcon: _NavItem(
                    index: i,
                    icon: items[i].$2,
                    label: items[i].$3,
                    selected: true,
                  ),
                  // The label lives in the item, inside the indicator.
                  label: '',
                  tooltip: items[i].$3,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Icon and label of one destination; when [selected], on the tonal shape
/// (key `nav-indicator-<index>`).
class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.index,
    required this.icon,
    required this.label,
    required this.selected,
  });

  final int index;
  final IconData icon;
  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final labelStyle = NavigationBarTheme.of(context).labelTextStyle?.resolve({
      if (selected) WidgetState.selected,
    });
    final color = selected ? palette.onActionSoft : palette.inkMuted;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: PillPalSpacing.xs),
      child: SizedBox(
        width: double.infinity,
        child: DecoratedBox(
          key: selected ? Key('nav-indicator-$index') : null,
          decoration: BoxDecoration(
            color: selected ? palette.actionSoft : null,
            borderRadius: const BorderRadius.all(
              Radius.circular(PillPalRadius.navIndicator),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: PillPalSpacing.sm),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  color: color,
                  size:
                      context.metrics.isSenior ? PillPalSizes.iconSenior : null,
                ),
                const Gap.v(PillPalSpacing.xs),
                // The destination announces the label through its tooltip.
                ExcludeSemantics(
                  // A label that is wider than its cell shrinks to fit: it is
                  // never cut or broken inside a word (the tooltip has the
                  // text anyway).
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      label,
                      maxLines: 1,
                      textAlign: TextAlign.center,
                      style: labelStyle?.copyWith(color: color),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
