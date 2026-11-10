import 'package:flutter/widgets.dart';

import '../../theme/sizes.dart';

/// Whether the text is scaled so far (system scale times the senior
/// multiplier) that rows stack their parts and drop decorations
/// (docs/design.md, narrow screens).
bool isCompactText(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(1) >= PillPalSizes.compactScale;
