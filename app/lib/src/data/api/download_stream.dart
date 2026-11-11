import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'api_exception.dart';

/// Streams the body of [response] into [file], never holding it in memory.
///
/// Stops with [ApiException.responseTooLarge] as soon as more than [maxBytes]
/// are announced or received, with [ApiException.networkError] when the
/// connection breaks, stalls for [idleTimeout] between two chunks or ends
/// short of the announced length, and with [ApiException.storageError] when
/// the file cannot be written. On any failure the partial file is deleted: a
/// half-written archive must never stay on the device. The error never
/// carries the path or any content.
Future<void> streamToFile(
  http.StreamedResponse response,
  File file, {
  required int maxBytes,
  required Duration idleTimeout,
}) async {
  final announced = response.contentLength;
  if (announced != null && announced > maxBytes) {
    throw const ApiException(ApiException.responseTooLarge, 200);
  }
  IOSink? sink;
  try {
    await file.parent.create(recursive: true);
    sink = file.openWrite();
    var written = 0;
    await for (final chunk in response.stream.timeout(idleTimeout)) {
      written += chunk.length;
      if (written > maxBytes) {
        throw const ApiException(ApiException.responseTooLarge, 200);
      }
      sink.add(chunk);
    }
    await sink.flush();
    await sink.close();
    sink = null;
    if (announced != null && written != announced) {
      throw const ApiException(ApiException.networkError, 0);
    }
  } on ApiException {
    await _discard(file, sink);
    rethrow;
  } on FileSystemException {
    await _discard(file, sink);
    throw const ApiException(ApiException.storageError, 0);
  } on http.ClientException {
    await _discard(file, sink);
    throw const ApiException(ApiException.networkError, 0);
  } on TimeoutException {
    await _discard(file, sink);
    throw const ApiException(ApiException.networkError, 0);
  } on IOException {
    await _discard(file, sink);
    throw const ApiException(ApiException.networkError, 0);
  }
}

/// Closes [sink] and deletes [file]; never throws.
Future<void> _discard(File file, IOSink? sink) async {
  try {
    await sink?.close();
  } on Object {
    // The file goes away anyway.
  }
  try {
    if (await file.exists()) {
      await file.delete();
    }
  } on Object {
    // The next clear of the export folder retries.
  }
}
