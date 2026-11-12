import 'package:material_ui/material_ui.dart';

import '../../theme/app_theme.dart';

/// A [PopupMenuItem] as tall as the touch target of the mode (44, 64 in
/// senior mode), which Material's 48 does not follow. Use it for every popup
/// menu of the app.
PopupMenuItem<T> pillPalPopupItem<T>(
  BuildContext context, {
  required T value,
  required Widget child,
  Key? key,
}) {
  return PopupMenuItem<T>(
    key: key,
    value: value,
    height: context.metrics.touchTarget,
    child: child,
  );
}
