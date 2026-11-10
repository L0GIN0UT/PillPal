import 'package:flutter/material.dart';

import 'banner_tone.dart';
import 'pillpal_banner.dart';

/// Deprecated: use `PillPalBanner(tone: BannerTone.info)`. A thin alias kept
/// until the screens move over (redesign R3-R7; counted by
/// `.github/scripts/check_ui_tokens.py`, removed in R8). [trailing] (a dismiss
/// button, for example) sits at the end of the row.
class InfoNote extends StatelessWidget {
  /// Creates the note.
  const InfoNote({required this.text, this.textKey, this.trailing, super.key});

  /// The explanation.
  final String text;

  /// Key of the text, for tests.
  final Key? textKey;

  /// A widget at the end of the row, such as a dismiss button.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return PillPalBanner(
      tone: BannerTone.info,
      body: text,
      bodyKey: textKey,
      trailing: trailing,
    );
  }
}
