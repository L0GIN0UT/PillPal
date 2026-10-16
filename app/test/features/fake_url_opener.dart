import 'package:pillpal/src/features/pharmacies/pharmacy_search.dart';

/// Records opened links; [handled] decides which schemes an app accepts.
class FakeUrlOpener implements UrlOpener {
  /// Creates the fake.
  FakeUrlOpener({this.handled = const {}, this.installed = const {}});

  /// Schemes [open] succeeds for.
  final Set<String> handled;

  /// Schemes [canOpen] reports as installed.
  final Set<String> installed;

  /// Every link [open] was called with, in order.
  final List<Uri> opened = [];

  @override
  Future<bool> canOpen(Uri uri) async => installed.contains(uri.scheme);

  @override
  Future<bool> open(Uri uri) async {
    opened.add(uri);
    return handled.contains(uri.scheme);
  }
}
