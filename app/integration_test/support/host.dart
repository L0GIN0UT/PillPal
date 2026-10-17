import 'dart:convert';

import 'package:http/http.dart' as http;

/// The runner-side helper of the emulator job
/// (`.github/scripts/emulator/host_control.py`), reached from the emulator
/// through the host loopback alias `10.0.2.2`. Test-only: it tells the app
/// which journey phase to run and hands over the e-mail verification code
/// the backend logged (dev mode, `LOG_EMAIL_CODES=true`).
class HostControl {
  /// Connects to `PILLPAL_E2E_HOST` (a `--dart-define`).
  HostControl()
      : _base = Uri.parse(
          const String.fromEnvironment(
            'PILLPAL_E2E_HOST',
            defaultValue: 'http://10.0.2.2:8090',
          ),
        );

  static const Duration _requestTimeout = Duration(seconds: 10);
  static const Duration _actionTimeout = Duration(seconds: 90);
  static const Duration _codeTimeout = Duration(seconds: 30);
  static const Duration _pollInterval = Duration(milliseconds: 250);

  final Uri _base;
  final http.Client _client = http.Client();

  /// The phase the workflow is at (`onboarding`, `taken`, ...).
  Future<String> phase() async => (await _get('/phase'))['phase'] as String;

  /// How many verification codes the backend has logged so far.
  Future<int> codeCount() async => (await _get('/code'))['count'] as int;

  /// The first code logged after [count] codes; waits for it.
  Future<String> codeAfter(int count) async {
    final deadline = DateTime.now().add(_codeTimeout);
    while (DateTime.now().isBefore(deadline)) {
      final json = await _get('/code');
      final code = json['code'];
      if ((json['count'] as int) > count && code is String) {
        return code;
      }
      await Future<void>.delayed(_pollInterval);
    }
    throw StateError('No new verification code in the backend log');
  }

  /// Asks the host to play the owner of a profile: an account with a
  /// `shared`, an `anonymous` and a `hidden` medication and a viewer invite.
  /// Returns the medication names by privacy level.
  Future<Map<String, String>> relativesSetup() async {
    final json = await _post('/relatives/setup');
    return {
      for (final entry in json.entries) entry.key: entry.value as String,
    };
  }

  /// Asks the host to deliver the invite link to the running app (`adb shell
  /// am start`, explicit package).
  Future<void> relativesOpenLink() async {
    await _post('/relatives/open-link');
  }

  /// Asks the host to revoke the owner's grant.
  Future<void> relativesRevoke() async {
    await _post('/relatives/revoke');
  }

  /// Closes the HTTP client.
  void close() => _client.close();

  Future<Map<String, Object?>> _post(String path) async {
    final response =
        await _client.post(_base.resolve(path)).timeout(_actionTimeout);
    if (response.statusCode != 200) {
      throw StateError('Host helper $path answered ${response.statusCode}');
    }
    return jsonDecode(response.body) as Map<String, Object?>;
  }

  Future<Map<String, Object?>> _get(String path) async {
    final response =
        await _client.get(_base.resolve(path)).timeout(_requestTimeout);
    if (response.statusCode != 200) {
      throw StateError('Host helper $path answered ${response.statusCode}');
    }
    return jsonDecode(response.body) as Map<String, Object?>;
  }
}
