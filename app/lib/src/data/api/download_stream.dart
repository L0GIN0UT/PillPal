import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'api_exception.dart';
import 'api_response.dart';

/// Sends the download request: a `POST` that asks for a zip.
Future<http.StreamedResponse> openDownload(
  http.Client client,
  Uri uri, {
  required String accessToken,
  required String deviceId,
  required Duration timeout,
}) {
  final request = http.Request('POST', uri)
    ..headers['Accept'] = 'application/zip'
    ..headers['X-Device-ID'] = deviceId
    ..headers['Authorization'] = 'Bearer $accessToken';
  return guardTransport(() => client.send(request).timeout(timeout));
}

/// Streams the body of [response] into [file], never holding it in memory
/// (the sink applies backpressure: the next chunk is read once the last one is
/// written).
///
/// Stops with [ApiException.responseTooLarge] as soon as more than [maxBytes]
/// are announced or received, with [ApiException.networkError] when the
/// connection breaks, stalls for [idleTimeout] between two chunks, takes
/// longer than [deadline] in all, or ends short of the announced length, and
/// with [ApiException.storageError] when the file cannot be written. Whatever
/// else goes wrong is a network error too. On any failure the partial file is
/// deleted and the response stream is cancelled: a half-written archive must
/// never stay on the device. The error never carries the path or any content.
Future<void> streamToFile(
  http.StreamedResponse response,
  File file, {
  required int maxBytes,
  required Duration idleTimeout,
  required Duration deadline,
}) async {
  final announced = response.contentLength;
  if (announced != null && announced > maxBytes) {
    // Nothing is read: cancel the connection instead of draining it.
    await _cancel(response.stream);
    throw const ApiException(ApiException.responseTooLarge, 200);
  }
  IOSink? sink;
  final count = _Count();
  final body = _limited(
    response.stream,
    maxBytes,
    idleTimeout,
    deadline,
    count,
  );
  try {
    await file.parent.create(recursive: true);
    sink = file.openWrite();
    await sink.addStream(body);
    await sink.flush();
    await sink.close();
    sink = null;
    if (announced != null && count.bytes != announced) {
      throw const ApiException(ApiException.networkError, 0);
    }
  } on ApiException {
    await _cancel(response.stream);
    await _discard(file, sink);
    rethrow;
  } on FileSystemException {
    await _cancel(response.stream);
    await _discard(file, sink);
    throw const ApiException(ApiException.storageError, 0);
  } on Object {
    // A broken connection, a stall, or anything unexpected: no partial file.
    await _cancel(response.stream);
    await _discard(file, sink);
    throw const ApiException(ApiException.networkError, 0);
  }
}

class _Count {
  int bytes = 0;
}

/// [source] with the byte cap, the idle timeout between chunks and the
/// overall [deadline] enforced as the chunks pass.
Stream<List<int>> _limited(
  Stream<List<int>> source,
  int maxBytes,
  Duration idleTimeout,
  Duration deadline,
  _Count count,
) async* {
  final clock = Stopwatch()..start();
  await for (final chunk in source.timeout(idleTimeout)) {
    count.bytes += chunk.length;
    if (count.bytes > maxBytes) {
      throw const ApiException(ApiException.responseTooLarge, 200);
    }
    if (clock.elapsed > deadline) {
      throw const ApiException(ApiException.networkError, 0);
    }
    yield chunk;
  }
}

Future<void> _cancel(Stream<List<int>> stream) async {
  try {
    await stream.listen(null).cancel();
  } on Object {
    // Nothing to cancel.
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
