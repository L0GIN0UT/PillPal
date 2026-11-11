import 'package:material_ui/material_ui.dart';

import '../../theme/palette.dart';

/// A text button in the `danger` colour with an icon: the quiet way to start
/// a destructive action (close access, delete a profile), which then asks
/// again in a dialog. Not a filled button: only the dialog's own confirm is
/// solid `danger` (B2-README `button.danger`).
///
/// It returns the [TextButton] itself, so [key] sits on the button.
TextButton dangerTextButton(
  BuildContext context, {
  required Key key,
  required VoidCallback? onPressed,
  required IconData icon,
  required String label,
}) {
  return TextButton.icon(
    key: key,
    onPressed: onPressed,
    style: TextButton.styleFrom(foregroundColor: context.palette.danger),
    icon: Icon(icon),
    label: Text(label),
  );
}
