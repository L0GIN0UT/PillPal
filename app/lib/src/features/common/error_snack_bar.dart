import 'package:flutter/material.dart';

import '../../../l10n/gen/app_localizations.dart';

/// Tells the user an action failed (no details: they could carry medical
/// data, and the code means nothing to the user).
void showErrorSnackBar(BuildContext context) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(AppLocalizations.of(context).errorGeneric)),
  );
}
