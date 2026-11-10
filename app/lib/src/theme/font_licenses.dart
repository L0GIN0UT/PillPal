import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The SIL Open Font License texts that ship with the bundled fonts
/// (the licence requires the text to travel with the font files).
const List<String> fontLicenseAssets = [
  'assets/fonts/Manrope-OFL.txt',
  'assets/fonts/GolosText-OFL.txt',
];

const Map<String, String> _packageByAsset = {
  'assets/fonts/Manrope-OFL.txt': 'Manrope',
  'assets/fonts/GolosText-OFL.txt': 'GolosText',
};

/// Adds the font licences to the licence page (`showLicensePage`).
/// Call once at start-up, after the binding is initialised.
void registerFontLicenses() {
  LicenseRegistry.addLicense(() async* {
    for (final asset in fontLicenseAssets) {
      final text = await rootBundle.loadString(asset);
      yield LicenseEntryWithLineBreaks([_packageByAsset[asset]!], text);
    }
  });
}
