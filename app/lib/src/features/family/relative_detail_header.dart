import 'package:material_ui/material_ui.dart';

import '../../theme/app_theme.dart';
import '../../theme/spacing.dart';
import '../common/clamped_text.dart';
import '../common/gap.dart';
import '../common/person_row.dart';

/// The head of the screen of one link: the 64 avatar, the name (clamped at
/// x1.5 like a screen title) and a line under it (board B2-RelativeDetail).
class RelativeDetailHeader extends StatelessWidget {
  /// Creates the header of [name]; [subtitle] is the role or the owner.
  const RelativeDetailHeader({
    required this.name,
    this.subtitle,
    this.avatarName,
    super.key,
  });

  /// The person's or profile's name.
  final String name;

  /// The name the avatar takes its letter from, when [name] carries more
  /// (a private note); empty shows the person icon. Null: [name].
  final String? avatarName;

  /// What is under the name, or null.
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final line = subtitle;
    return Row(
      children: [
        PillPalAvatar(
          name: avatarName ?? name,
          size: PillPalSizes.avatarLg,
        ),
        const Gap.h(PillPalSpacing.lg),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClampedText(
                name,
                maxScale: PillPalSizes.titleMaxScale,
                style: textTheme.headlineMedium,
              ),
              if (line != null) Text(line, style: textTheme.bodySmall),
            ],
          ),
        ),
      ],
    );
  }
}
