import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
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
  String? semanticsLabel,
}) {
  final style = TextButton.styleFrom(foregroundColor: context.palette.danger);
  final text = Text(label, semanticsLabel: semanticsLabel);
  if (icon == null) {
    return TextButton(
      key: key,
      onPressed: onPressed,
      style: style,
      child: text,
    );
  }
  return TextButton.icon(
    key: key,
    onPressed: onPressed,
    style: style,
    icon: Icon(icon),
    label: text,
  );
}

/// «Отключить» of one link block on a relative's card, the same in both
/// directions; [semanticsLabel] says which direction it ends («Отключить:
/// вы видите их лекарства»), since a card may hold two of them. The
/// confirmation dialog follows.
TextButton disconnectButton(
  BuildContext context, {
  required Key key,
  required VoidCallback? onPressed,
  required String semanticsLabel,
}) {
  return dangerTextButton(
    context,
    key: key,
    onPressed: onPressed,
    icon: Icons.link_off,
    label: AppLocalizations.of(context).relativeDisconnect,
    semanticsLabel: semanticsLabel,
  );
}
