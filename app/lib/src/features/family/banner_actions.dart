import 'package:flutter/material.dart';

import '../../theme/palette.dart';

/// The style of a text button inside a soft banner: the on-colour of the
/// soft fill (7:1 in senior mode), not `action`, which only has 6:1 on it.
/// Until `PillPalBanner` themes its own actions this is how a feature does.
ButtonStyle bannerActionStyle(BuildContext context) =>
    TextButton.styleFrom(foregroundColor: context.palette.onActionSoft);
