import 'package:flutter/material.dart';

import '../../theme/palette.dart';

/// A text button in the `danger` colour, with an icon unless [icon] is null
/// (a button in an app bar has no room for it): the quiet way to start
/// a destructive action (close access, delete a profile), which then asks
/// again in a dialog. Not a filled button: only the dialog's own confirm is
/// solid `danger` (B2-README `button.danger`).
///
/// It returns the [TextButton] itself, so [key] sits on the button.
TextButton dangerTextButton(
  BuildContext context, {
  required Key key,
  required VoidCallback? onPressed,
  required String label,
  IconData? icon,
}) {
  final style = TextButton.styleFrom(foregroundColor: context.palette.danger);
  if (icon == null) {
    return TextButton(
      key: key,
      onPressed: onPressed,
      style: style,
      child: Text(label),
    );
  }
  return TextButton.icon(
    key: key,
    onPressed: onPressed,
    style: style,
    icon: Icon(icon),
    label: Text(label),
  );
}
