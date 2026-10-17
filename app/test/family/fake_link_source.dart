import 'dart:async';

import 'package:pillpal/src/links/link_providers.dart';

/// A [LinkSource] a test drives: the launch link and links that arrive
/// while the app runs.
class FakeLinkSource implements LinkSource {
  /// The link the app "was started with"; set before the app is pumped.
  Uri? initial;

  final StreamController<Uri> _controller = StreamController<Uri>.broadcast();

  @override
  Future<Uri?> initialLink() async => initial;

  @override
  Stream<Uri> get links => _controller.stream;

  /// A link arrives while the app runs.
  void emit(Uri uri) => _controller.add(uri);
}
