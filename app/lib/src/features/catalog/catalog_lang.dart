import 'package:flutter/widgets.dart';

/// The catalog language (`ru` or `en`) for the UI language of [context];
/// every other UI language gets English names.
String catalogLanguage(BuildContext context) {
  return Localizations.localeOf(context).languageCode == 'ru' ? 'ru' : 'en';
}
