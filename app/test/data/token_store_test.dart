import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/api/auth_dto.dart';
import 'package:pillpal/src/data/auth/access_claims.dart';
import 'package:pillpal/src/data/auth/token_store.dart';

final _pair = TokenPair(
  accessToken: 'a.b.c',
  refreshToken: 'refresh',
  accessExpiresAt: DateTime.utc(2026, 10, 16, 9, 15),
);

void main() {
  test('tokens are one JSON value under one key', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final store = SecureTokenStore(isFreshInstall: () async => false);
    await store.write(_pair);
    final raw = await const FlutterSecureStorage().readAll();
    expect(raw.keys, ['pillpal.session']);
    final read = (await store.read())!;
    expect(read.accessToken, 'a.b.c');
    expect(read.refreshToken, 'refresh');
    expect(read.accessExpiresAt, _pair.accessExpiresAt);
    await store.clear();
    expect(await store.read(), isNull);
  });

  test('a new installation clears what an old one left behind', () async {
    FlutterSecureStorage.setMockInitialValues({
      'pillpal.session': SecureTokenStore.encode(_pair),
    });
    var fresh = true;
    final store = SecureTokenStore(
      isFreshInstall: () async {
        final result = fresh;
        fresh = false;
        return result;
      },
    );
    expect(await store.read(), isNull);
    await store.write(_pair);
    expect(await store.read(), isNotNull);
  });

  test('damaged values read as signed out', () {
    expect(SecureTokenStore.decode('not json'), isNull);
    expect(SecureTokenStore.decode('{"access_token": 1}'), isNull);
    expect(SecureTokenStore.decode(SecureTokenStore.encode(_pair)), isNotNull);
  });

  test('access claims come from the JWT payload', () {
    // {"sub":"u-1","region":"eu"}
    const token = 'eyJhbGciOiJub25lIn0.eyJzdWIiOiJ1LTEiLCJyZWdpb24iOiJldSJ9.x';
    expect(
      AccessClaims.fromToken(token),
      const AccessClaims(userId: 'u-1', region: 'eu'),
    );
    expect(AccessClaims.fromToken('opaque'), isNull);
    expect(AccessClaims.fromToken('a.%%%.c'), isNull);
  });
}
