import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import '../lib/service/timeweb_auth_client.dart';

final _now = DateTime.utc(2026, 10, 1);

class _SecureStore implements TimewebSecureTokenStore {
  TimewebSession? value;
  int reads = 0;
  int writes = 0;
  int clears = 0;
  bool failClear = false;
  bool failWrite = false;
  Completer<void>? pendingWrite;
  Completer<void>? writeStarted;
  Completer<TimewebSession?>? pendingRead;
  Completer<void>? pendingClear;
  Completer<void>? clearStarted;

  @override
  Future<TimewebSession?> read() async {
    reads++;
    final pending = pendingRead;
    pendingRead = null;
    return pending == null ? value : await pending.future;
  }

  @override
  Future<void> write(TimewebSession session) async {
    writes++;
    writeStarted?.complete();
    final pending = pendingWrite;
    pendingWrite = null;
    if (pending != null) await pending.future;
    if (failWrite) throw StateError('store unavailable');
    value = session;
  }

  @override
  Future<void> clear() async {
    clears++;
    clearStarted?.complete();
    clearStarted = null;
    final pending = pendingClear;
    pendingClear = null;
    if (pending != null) await pending.future;
    if (failClear) throw StateError('store unavailable');
    value = null;
  }
}

class _Transport extends http.BaseClient {
  _Transport(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  final requests = <http.BaseRequest>[];
  int closed = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
    return handler(request);
  }

  @override
  void close() => closed++;
}

http.StreamedResponse _reply(
  Object value, {
  int status = 200,
  bool noStore = true,
}) => http.StreamedResponse(
  Stream.value(utf8.encode(jsonEncode(value))),
  status,
  headers: {
    'content-type': 'application/json; charset=utf-8',
    if (noStore) 'cache-control': 'no-store',
  },
);

Map<String, dynamic> _tokens(String uid, {String revision = 'first'}) => {
  'uid': uid,
  'emailVerified': true,
  'accessToken': 'na1.$uid.$revision',
  'refreshToken': 'nr1.$uid.$revision',
  'expiresIn': 900,
  'refreshExpiresIn': 1209600,
};

TimewebSession _session(String uid, {String revision = 'first'}) =>
    TimewebSession(
      uid: uid,
      emailVerified: true,
      accessToken: 'na1.$uid.$revision',
      refreshToken: 'nr1.$uid.$revision',
      accessExpiresAt: _now.add(const Duration(minutes: 15)),
      refreshExpiresAt: _now.add(const Duration(days: 14)),
    );

TimewebAuthClient _client(
  _SecureStore store,
  _Transport wire, {
  bool enabled = true,
  Duration deadline = const Duration(seconds: 1),
  DateTime Function()? clock,
}) => TimewebAuthClient(
  configuration: TimewebAuthConfiguration(
    endpoint: Uri.parse('https://clrs-api.example.invalid'),
    enabled: enabled,
  ),
  secureStore: store,
  transport: wire,
  requestDeadline: deadline,
  clock: clock ?? () => _now,
);

Future<TimewebSession> _login(TimewebAuthClient client, String who) =>
    client.login(
      email: '$who@example.invalid',
      password: ' synthetic password ',
      deviceId: 'test-device',
    );

Map<String, dynamic> _body(http.BaseRequest request) =>
    jsonDecode((request as http.Request).body) as Map<String, dynamic>;
Matcher _error(TimewebAuthError value) => isA<TimewebAuthException>().having(
  (error) => error.error,
  'safe error',
  value,
);

void main() {
  test(
    'client is default-off and invalid origins never make a request',
    () async {
      final store = _SecureStore();
      final wire = _Transport((_) async => _reply(_tokens('A')));
      final client = TimewebAuthClient(
        configuration: TimewebAuthConfiguration(
          endpoint: Uri.parse('https://clrs-api.example.invalid'),
        ),
        secureStore: store,
        transport: wire,
      );
      await expectLater(
        _login(client, 'A'),
        throwsA(_error(TimewebAuthError.disabled)),
      );
      expect(wire.requests, isEmpty);
      expect(store.clears, 0);
      for (final url in [
        'http://api.example.invalid',
        'https://localhost',
        'https://127.0.0.1',
        'https://10.0.0.1',
        'https://user:secret@api.example.invalid',
        'https://api.example.invalid?token=secret',
        'https://api.example.invalid/#token',
        'https://api.example.invalid:8443',
        'https://api.example.invalid/v1',
      ]) {
        expect(
          () => TimewebAuthConfiguration(endpoint: Uri.parse(url)),
          throwsArgumentError,
        );
      }
    },
  );

  test(
    'startup restore is shared and a late restored A cannot replace B',
    () async {
      final pending = Completer<TimewebSession?>();
      final store = _SecureStore()..pendingRead = pending;
      final wire = _Transport((_) async => _reply(_tokens('B')));
      final client = _client(store, wire);
      final first = client.restore();
      final second = client.restore();
      expect(identical(first, second), isTrue);
      final rejected = expectLater(
        first,
        throwsA(_error(TimewebAuthError.staleSession)),
      );
      await Future<void>.delayed(Duration.zero);
      final login = _login(client, 'B');
      pending.complete(_session('A'));
      await rejected;
      await login;
      expect(client.currentUid, 'B');
      expect((await client.restore())?.uid, 'B');
      expect(store.reads, 1);
      await client.logout();
      store.value = _session(
        'A',
      ); // A stale protected record must not be re-read.
      expect(await client.restore(), isNull);
      expect(store.reads, 1);
    },
  );

  test(
    'login preserves password, uses strict JSON and protected token store',
    () async {
      final store = _SecureStore();
      final wire = _Transport((request) async {
        expect(request.url.query, isEmpty);
        expect(request.followRedirects, isFalse);
        expect(request.headers['Authorization'], isNull);
        expect(_body(request), {
          'email': 'A@example.invalid',
          'password': ' synthetic password ',
          'deviceId': 'test-device',
        });
        return _reply(_tokens('A'));
      });
      final client = _client(store, wire);
      final result = await _login(client, 'A');
      expect(client.currentUid, 'A');
      expect(store.value, same(result));
      expect(result.toString(), 'TimewebSession(<redacted>)');
      expect(result.toString(), isNot(contains(result.accessToken)));
      expect(store.writes, 1);
      expect(wire.requests.length, 1);
    },
  );

  test(
    'own profiles are fetched again and access token appears only in header',
    () async {
      final store = _SecureStore()..value = _session('A');
      var reads = 0;
      final wire = _Transport((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/v1/me/profile');
        expect(request.url.query, isEmpty);
        expect((request as http.Request).body, isEmpty);
        expect(request.headers['Authorization'], 'Bearer na1.A.first');
        reads++;
        return _reply({
          'profile': {'uid': 'A', 'fullName': 'Synthetic $reads'},
        });
      });
      final client = _client(store, wire);
      await client.restore();
      final first = await client.readOwnProfile();
      final second = await client.readOwnProfile();
      expect(first['fullName'], 'Synthetic 1');
      expect(second['fullName'], 'Synthetic 2');
      expect(reads, 2);
      expect(() => first['uid'] = 'B', throwsUnsupportedError);
    },
  );

  test('parallel refresh shares one Future and one rotation', () async {
    final pending = Completer<http.StreamedResponse>();
    final store = _SecureStore()..value = _session('A');
    final wire = _Transport((request) {
      expect(request.url.path, '/v1/auth/refresh');
      expect(_body(request), {'refreshToken': 'nr1.A.first'});
      expect(request.headers['Authorization'], isNull);
      return pending.future;
    });
    final client = _client(store, wire);
    await client.restore();
    final a = client.refresh();
    final b = client.refresh();
    expect(identical(a, b), isTrue);
    expect(wire.requests.length, 1);
    pending.complete(_reply(_tokens('A', revision: 'rotated')));
    await Future.wait([a, b]);
    expect(store.value?.accessToken, 'na1.A.rotated');
    expect(store.writes, 1);
  });

  test(
    'concurrent expired profile reads rotate once and use the new bearer',
    () async {
      final pending = Completer<http.StreamedResponse>();
      final store = _SecureStore()..value = _session('A');
      final wire = _Transport((request) async {
        if (request.url.path == '/v1/auth/refresh') return pending.future;
        expect(request.headers['Authorization'], 'Bearer na1.A.rotated');
        return _reply({
          'profile': {'uid': 'A'},
        });
      });
      final client = _client(
        store,
        wire,
        clock: () => _now.add(const Duration(minutes: 16)),
      );
      await client.restore();
      final a = client.readOwnProfile();
      final b = client.readOwnProfile();
      expect(
        wire.requests.where((r) => r.url.path == '/v1/auth/refresh').length,
        1,
      );
      pending.complete(_reply(_tokens('A', revision: 'rotated')));
      await Future.wait([a, b]);
      expect(wire.requests.length, 3);
    },
  );

  test(
    'unknown refresh timeout clears session, never retries old refresh or adopts late result',
    () async {
      final pending = Completer<http.StreamedResponse>();
      final store = _SecureStore()..value = _session('A');
      final wire = _Transport((_) => pending.future);
      final client = _client(
        store,
        wire,
        deadline: const Duration(milliseconds: 20),
      );
      await client.restore();
      await expectLater(
        client.refresh(),
        throwsA(isA<TimewebUnknownOutcome>()),
      );
      expect(client.currentUid, isNull);
      expect(store.value, isNull);
      expect(
        () => client.refresh(),
        throwsA(_error(TimewebAuthError.notAuthenticated)),
      );
      pending.complete(_reply(_tokens('A', revision: 'late')));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(wire.requests.length, 1);
      expect(store.writes, 0);
      expect(store.value, isNull);
    },
  );

  for (final kind in [
    '503',
    'wrong uid',
    'invalid JSON',
    'cacheable',
    'redirect',
  ]) {
    test('refresh $kind is unknown and cannot fall back or retry', () async {
      final store = _SecureStore()..value = _session('A');
      final wire = _Transport(
        (_) async => switch (kind) {
          '503' => _reply({'error': 'sensitive server details'}, status: 503),
          'wrong uid' => _reply(_tokens('B')),
          'invalid JSON' => http.StreamedResponse(
            Stream.value(utf8.encode('{')),
            200,
            headers: {
              'content-type': 'application/json',
              'cache-control': 'no-store',
            },
          ),
          'cacheable' => _reply(_tokens('A'), noStore: false),
          _ => _reply({}, status: 302),
        },
      );
      final client = _client(store, wire);
      await client.restore();
      await expectLater(
        client.refresh(),
        throwsA(isA<TimewebUnknownOutcome>()),
      );
      expect(client.hasSession, isFalse);
      expect(store.value, isNull);
      expect(wire.requests.length, 1);
      expect(
        () => client.refresh(),
        throwsA(_error(TimewebAuthError.notAuthenticated)),
      );
    });
  }

  test('login timeout is unknown and late issuance is not persisted', () async {
    final pending = Completer<http.StreamedResponse>();
    final store = _SecureStore();
    final wire = _Transport((_) => pending.future);
    final client = _client(
      store,
      wire,
      deadline: const Duration(milliseconds: 20),
    );
    await expectLater(
      _login(client, 'A'),
      throwsA(isA<TimewebUnknownOutcome>()),
    );
    pending.complete(_reply(_tokens('A')));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(client.currentUid, isNull);
    expect(store.value, isNull);
    expect(store.writes, 0);
    expect(wire.requests.length, 1);
  });

  test(
    'late A login response cannot overwrite B or persist A tokens',
    () async {
      final pending = Completer<http.StreamedResponse>();
      final started = Completer<void>();
      final store = _SecureStore();
      final wire = _Transport((request) {
        if (_body(request)['email'] == 'A@example.invalid') {
          started.complete();
          return pending.future;
        }
        return Future.value(_reply(_tokens('B')));
      });
      final client = _client(store, wire);
      final a = _login(client, 'A');
      final aRejected = expectLater(
        a,
        throwsA(_error(TimewebAuthError.staleSession)),
      );
      await started.future;
      await _login(client, 'B');
      pending.complete(_reply(_tokens('A')));
      await aRejected;
      expect(client.currentUid, 'B');
      expect(store.value?.uid, 'B');
      expect(store.writes, 1);
    },
  );

  test(
    'late A profile/error after logout and B never returns A data',
    () async {
      for (final error in [false, true]) {
        final pending = Completer<http.StreamedResponse>();
        final started = Completer<void>();
        final store = _SecureStore()..value = _session('A');
        final wire = _Transport((request) {
          if (request.method == 'GET' &&
              request.headers['Authorization'] == 'Bearer na1.A.first') {
            started.complete();
            return pending.future;
          }
          if (request.url.path == '/v1/auth/logout')
            return Future.value(_reply({'loggedOut': true}));
          if (request.url.path == '/v1/auth/login')
            return Future.value(_reply(_tokens('B')));
          return Future.value(
            _reply({
              'profile': {'uid': 'B'},
            }),
          );
        });
        final client = _client(store, wire);
        await client.restore();
        final a = client.readOwnProfile();
        final rejected = expectLater(
          a,
          throwsA(_error(TimewebAuthError.staleSession)),
        );
        await started.future;
        await client.logout();
        await _login(client, 'B');
        if (error)
          pending.completeError(StateError('synthetic network failure'));
        else
          pending.complete(
            _reply({
              'profile': {'uid': 'A'},
            }),
          );
        await rejected;
        expect((await client.readOwnProfile())['uid'], 'B');
        expect(store.value?.uid, 'B');
      }
    },
  );

  test(
    'old native storage write settles before logout/B storage and cannot restore A',
    () async {
      final blockedWrite = Completer<void>();
      final store = _SecureStore()
        ..pendingWrite = blockedWrite
        ..writeStarted = Completer<void>();
      final wire = _Transport(
        (request) async => request.url.path == '/v1/auth/logout'
            ? _reply({'loggedOut': true})
            : _reply(
                _tokens(
                  (_body(request)['email'] as String).startsWith('A')
                      ? 'A'
                      : 'B',
                ),
              ),
      );
      final client = _client(store, wire);
      final a = _login(client, 'A');
      final rejected = expectLater(
        a,
        throwsA(_error(TimewebAuthError.staleSession)),
      );
      await store.writeStarted!.future;
      store.writeStarted = null;
      final logout = client.logout(allSessions: true);
      final b = _login(client, 'B');
      expect(client.currentUid, isNull);
      blockedWrite.complete();
      await rejected;
      final loggedOut = await logout;
      await b;
      expect(loggedOut.superseded, isTrue);
      expect(store.value?.uid, 'B');
      expect(client.currentUid, 'B');
    },
  );

  test(
    'logout current/all uses boolean body, header bearer and clears tokens even on unknown/rejection',
    () async {
      for (final all in [false, true]) {
        for (final status in [200, 401, 503]) {
          final store = _SecureStore()..value = _session('A');
          final wire = _Transport((request) async {
            expect(request.url.path, '/v1/auth/logout');
            expect(request.url.query, isEmpty);
            expect(request.headers['Authorization'], 'Bearer na1.A.first');
            expect(_body(request), {'allSessions': all});
            return _reply({'loggedOut': true}, status: status);
          });
          final client = _client(store, wire);
          await client.restore();
          final result = await client.logout(allSessions: all);
          expect(result.remoteConfirmed, status == 200);
          expect(result.secureTokensCleared, isTrue);
          expect(result.allSessions, all);
          expect(client.currentUid, isNull);
          expect(store.value, isNull);
          expect(wire.requests.length, 1);
        }
      }
    },
  );

  test(
    'logout lost response clears locally but does not assert remote/all confirmation',
    () async {
      final pending = Completer<http.StreamedResponse>();
      final store = _SecureStore()..value = _session('A');
      final wire = _Transport((_) => pending.future);
      final client = _client(
        store,
        wire,
        deadline: const Duration(milliseconds: 20),
      );
      await client.restore();
      final result = await client.logout(allSessions: true);
      expect(result.outcome, TimewebLogoutOutcome.remoteUnknown);
      expect(result.remoteConfirmed, isFalse);
      expect(result.secureTokensCleared, isTrue);
      expect(store.value, isNull);
      pending.complete(_reply({'loggedOut': true}));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(wire.requests.length, 1);
      expect(client.hasSession, isFalse);
    },
  );

  test(
    'failed secure clear remains explicit and cannot silently restore old account',
    () async {
      final store = _SecureStore()..value = _session('A');
      final wire = _Transport((_) async => _reply({'loggedOut': true}));
      final client = _client(store, wire);
      await client.restore();
      store.failClear = true;
      final result = await client.logout();
      expect(result.secureTokensCleared, isFalse);
      expect(client.hasSession, isFalse);
      final reads = store.reads;
      await expectLater(
        client.restore(),
        throwsA(_error(TimewebAuthError.secureStore)),
      );
      expect(store.reads, reads);
      store.failClear = false;
      expect(await client.restore(), isNull);
      expect(store.value, isNull);
    },
  );

  test(
    'profile rejects wrong uid and oversized data without serving cache',
    () async {
      for (final oversized in [false, true]) {
        final store = _SecureStore()..value = _session('A');
        final wire = _Transport(
          (_) async => _reply({
            'profile': {
              'uid': oversized ? 'A' : 'B',
              'fullName': oversized ? 'x' * 65536 : 'Synthetic',
            },
          }),
        );
        final client = _client(store, wire);
        await client.restore();
        await expectLater(
          client.readOwnProfile(),
          throwsA(_error(TimewebAuthError.invalidResponse)),
        );
        expect(wire.requests.length, 1);
      }
    },
  );

  test(
    'late old GET401 uses already rotated bearer rather than rotating again',
    () async {
      final late = Completer<http.StreamedResponse>();
      final seen = Completer<void>();
      var firstGet = true;
      var rotations = 0;
      final store = _SecureStore()..value = _session('A');
      final wire = _Transport((request) async {
        if (request.url.path == '/v1/auth/refresh') {
          rotations++;
          return _reply(_tokens('A', revision: 'rotated'));
        }
        if (firstGet) {
          firstGet = false;
          seen.complete();
          return late.future;
        }
        expect(request.headers['Authorization'], 'Bearer na1.A.rotated');
        return _reply({
          'profile': {'uid': 'A'},
        });
      });
      final client = _client(store, wire);
      await client.restore();
      final profile = client.readOwnProfile();
      await seen.future;
      await client.refresh();
      late.complete(_reply({}, status: 401));
      expect((await profile)['uid'], 'A');
      expect(rotations, 1);
    },
  );

  test(
    'refresh401 ends blocked/expired session; explicit rate limit does not replay automatically',
    () async {
      for (final status in [401, 429]) {
        final store = _SecureStore()..value = _session('A');
        final wire = _Transport((_) async => _reply({}, status: status));
        final client = _client(store, wire);
        await client.restore();
        await expectLater(
          client.refresh(),
          throwsA(
            _error(
              status == 401
                  ? TimewebAuthError.unauthorized
                  : TimewebAuthError.rateLimited,
            ),
          ),
        );
        expect(client.hasSession, status == 429);
        expect(wire.requests.length, 1);
      }
    },
  );

  test(
    'expired refresh is cleared without network and errors expose no raw body/password',
    () async {
      final store = _SecureStore()..value = _session('A');
      final wire = _Transport(
        (_) async => _reply({'error': ' synthetic password '}, status: 503),
      );
      final client = _client(
        store,
        wire,
        clock: () => _now.add(const Duration(days: 15)),
      );
      expect(await client.restore(), isNull);
      expect(store.value, isNull);
      expect(wire.requests, isEmpty);
      try {
        await _login(client, 'A');
        fail('503 must not authenticate');
      } on TimewebUnknownOutcome catch (error) {
        expect(error.toString(), isNot(contains('synthetic password')));
        expect(error.toString(), isNot(contains('A@example.invalid')));
      }
    },
  );

  test(
    'concurrent close awaits actual old clear before replacement client writes',
    () async {
      final store = _SecureStore()..value = _session('A');
      final oldWire = _Transport((_) async => _reply(_tokens('A')));
      final old = _client(store, oldWire);
      await old.restore();
      final clear = Completer<void>();
      final started = Completer<void>();
      store.pendingClear = clear;
      store.clearStarted = started;
      final firstClose = old.close();
      final secondClose = old.close();
      expect(identical(firstClose, secondClose), isTrue);
      await started.future;

      final wire = _Transport((_) async => _reply(_tokens('B')));
      final replacement = _client(store, wire);
      final newLogin = secondClose.then((_) => _login(replacement, 'B'));
      await Future<void>.delayed(Duration.zero);
      expect(wire.requests, isEmpty);
      expect(store.writes, 0);
      clear.complete();
      expect(await firstClose, isTrue);
      expect(await secondClose, isTrue);
      await newLogin;
      expect(store.value?.uid, 'B');
      expect(replacement.currentUid, 'B');
      expect(await old.close(), isTrue);
      expect(store.value?.uid, 'B');
    },
  );

  test('UID bound counts Unicode characters and rejects invalid UTF-8', () {
    TimewebSession make(String uid) => TimewebSession(
      uid: uid,
      emailVerified: true,
      accessToken: 'na1.synthetic',
      refreshToken: 'nr1.synthetic',
      accessExpiresAt: _now.add(const Duration(minutes: 15)),
      refreshExpiresAt: _now.add(const Duration(days: 14)),
    );
    final unicodeUid = List.filled(191, '😀').join();
    expect(make(unicodeUid).uid, unicodeUid);
    expect(() => make('$unicodeUid😀'), throwsArgumentError);
    expect(() => make('\ud800'), throwsArgumentError);
  });

  test(
    'close prevents late login adoption and leaves injected transport caller-owned',
    () async {
      final pending = Completer<http.StreamedResponse>();
      final started = Completer<void>();
      final store = _SecureStore();
      final wire = _Transport((_) {
        started.complete();
        return pending.future;
      });
      final client = _client(store, wire);
      final login = _login(client, 'A');
      final rejected = expectLater(
        login,
        throwsA(_error(TimewebAuthError.staleSession)),
      );
      await started.future;
      expect(await client.close(), isTrue);
      pending.complete(_reply(_tokens('A')));
      await rejected;
      expect(store.value, isNull);
      expect(wire.closed, 0);
      await expectLater(
        client.readOwnProfile(),
        throwsA(_error(TimewebAuthError.closed)),
      );
    },
  );
}
