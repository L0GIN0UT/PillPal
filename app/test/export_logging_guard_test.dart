import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// The export archive is the most concentrated medical artefact (privacy rule
// 1): nothing that handles its id, path, password or content may log. This is
// a static guard over the code that does: it fails on any print, debugPrint,
// developer.log or logger.

final RegExp _logging = RegExp(
  r'\bprint\s*\(|\bdebugPrint\b|\bdeveloper\.log\b|\bLogger\b|'
  r"import\s+'dart:developer'|package:logging",
);

Iterable<File> _guarded() sync* {
  final privacy = Directory('lib/src/features/privacy');
  yield* privacy.listSync().whereType<File>().where(
        (file) => file.path.endsWith('.dart'),
      );
  for (final name in [
    'export_api.dart',
    'export_dto.dart',
    'download_stream.dart',
    'api_client.dart',
    'api_response.dart',
  ]) {
    yield File('lib/src/data/api/$name');
  }
}

String _code(File file) => file
    .readAsLinesSync()
    .where((line) => !line.trimLeft().startsWith('//'))
    .join('\n');

void main() {
  test('the guard looks at the files that handle the archive', () {
    final names = [for (final file in _guarded()) file.uri.pathSegments.last];

    expect(
      names,
      containsAll([
        'export_controller.dart',
        'export_files.dart',
        'privacy_data_screen.dart',
        'download_stream.dart',
        'api_client.dart',
      ]),
    );
  });

  test('none of them prints or logs', () {
    final offenders = [
      for (final file in _guarded())
        if (_logging.hasMatch(_code(file))) file.path,
    ];

    expect(offenders, isEmpty);
  });
}
