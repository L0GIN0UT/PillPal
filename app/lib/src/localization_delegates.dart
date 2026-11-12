import 'package:material_ui/material_ui.dart';

import '../l10n/gen/app_localizations.dart';

/// Localization delegates for every `MaterialApp` of the app and its tests.
///
/// The generated [AppLocalizations.localizationsDelegates] lists the
/// flutter_localizations delegates, which only localize the deprecated
/// `package:flutter/material.dart` types. material_ui widgets look up
/// material_ui's own [MaterialLocalizations], so its delegates are added too;
/// without them Material strings (pickers, tooltips) fall back to English.
const List<LocalizationsDelegate<dynamic>> pillPalLocalizationsDelegates = [
  ...AppLocalizations.localizationsDelegates,
  ...GlobalMaterialLocalizations.delegates,
];
