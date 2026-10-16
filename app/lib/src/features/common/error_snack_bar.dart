import 'dart:async';

import 'package:flutter/material.dart';

import '../../../l10n/gen/app_localizations.dart';

/// Tells the user an action failed (no details: they could carry medical
/// data, and the code means nothing to the user).
void showErrorSnackBar(BuildContext context) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(AppLocalizations.of(context).errorGeneric)),
  );
}

/// Runs [action] from a widget callback without awaiting it; a failure is
/// shown in a snack bar instead of being lost.
void runShowingErrors(BuildContext context, Future<Object?> action) {
  final messenger = ScaffoldMessenger.of(context);
  final message = AppLocalizations.of(context).errorGeneric;
  unawaited(
    action.then<void>(
      (_) {},
      onError: (Object error) {
        messenger.showSnackBar(SnackBar(content: Text(message)));
      },
    ),
  );
}
