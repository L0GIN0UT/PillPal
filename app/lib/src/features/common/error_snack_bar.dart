import 'dart:async';

import 'package:flutter/material.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/palette.dart';

/// Tells the user an action failed (no details: they could carry medical
/// data, and the code means nothing to the user).
void showErrorSnackBar(BuildContext context) {
  ScaffoldMessenger.of(context).showSnackBar(
    _snackBar(context, AppLocalizations.of(context).errorGeneric),
  );
}

/// Ink on background: readable in every palette. A failed action is not a
/// blocking state, so it is not the danger colour.
SnackBar _snackBar(BuildContext context, String message) {
  final palette = context.palette;
  return SnackBar(
    backgroundColor: palette.ink,
    content: Text(
      message,
      style: Theme.of(context)
          .textTheme
          .bodyMedium
          ?.copyWith(color: palette.background),
    ),
  );
}

/// Runs [action] from a widget callback without awaiting it; a failure is
/// shown in a snack bar instead of being lost.
void runShowingErrors(BuildContext context, Future<Object?> action) {
  final messenger = ScaffoldMessenger.of(context);
  // Built before the await: the context may be gone when the action fails.
  final snackBar =
      _snackBar(context, AppLocalizations.of(context).errorGeneric);
  unawaited(
    action.then<void>(
      (_) {},
      onError: (Object error) {
        messenger.showSnackBar(snackBar);
      },
    ),
  );
}
