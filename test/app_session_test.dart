import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:flutter_test/flutter_test.dart';

import '../lib/service/app_session.dart';
import '../lib/service/timeweb_auth_client.dart';

AppSessionIdentity identity(
  String uid, [
  AppSessionBackend backend = AppSessionBackend.firebase,
]) => AppSessionIdentity(backend: backend, uid: uid, emailVerified: true);

final class FakeAdapter implements AppSessionAdapter {
  FakeAdapter({this.backend = AppSessionBackend.firebase});
  @override
  final AppSessionBackend backend;
  @override
  AppSessionIdentity? currentIdentity;
  final changes = StreamController<AppSessionIdentity?>.broadcast(sync: true);
  final calls = <String>[];
  final logins = <Completer<AppSessionIdentity>>[];
  Completer<AppSessionIdentity?>? restoring;
  Completer<AppSessionIdentity>? refreshing;
  AppSessionLogout logoutResult = const AppSessionLogout(
    remote: AppSessionRemoteLogout.confirmed,
    localCleared: true,
    allSessions: false,
  );
  Object? logoutError;
  @override
  Stream<AppSessionIdentity?> get identityChanges => changes.stream;
  void external(AppSessionIdentity? value) {
    currentIdentity = value;
    changes.add(value);
  }

  @override
  Future<AppSessionIdentity?> restore() async {
    calls.add('restore');
    return currentIdentity = restoring == null
        ? currentIdentity
        : await restoring!.future;
  }

  @override
  Future<AppSessionIdentity> login({
    required String email,
    required String password,
    required String deviceId,
  }) async {
    calls.add('login:$email');
    final pending = Completer<AppSessionIdentity>();
    logins.add(pending);
    final value = await pending.future;
    external(value);
    return value;
  }

  @override
  Future<AppSessionIdentity> refresh() async {
    calls.add('refresh');
    final value = await refreshing!.future;
    external(value);
    return value;
  }

  @override
  Future<AppSessionLogout> logout({required bool allSessions}) async {
    calls.add('logout');
    if (logoutError != null) throw logoutError!;
    external(null);
    return AppSessionLogout(
      remote: logoutResult.remote,
      localCleared: logoutResult.localCleared,
      allSessions: allSessions,
    );
  }

  @override
  Future<bool> close() async {
    calls.add('close');
    currentIdentity = null;
    await changes.close();
    return true;
  }
}

Future<void> tick() => Future<void>.delayed(Duration.zero);

Future<AppSessionResult> login(AppSession facade, String uid) => facade.login(
  email: '$uid@example.invalid',
  password: 'synthetic',
  deviceId: 'test',
);

final class Store implements TimewebSecureTokenStore {
  TimewebSession? value;
  bool failClear = false;
  @override
  Future<void> clear() async {
    if (failClear) throw StateError('secure store unavailable');
    value = null;
  }

  @override
  Future<TimewebSession?> read() async => value;
  @override
  Future<void> write(TimewebSession session) async {
    value = session;
  }
}

final class Wire extends http.BaseClient {
  Wire(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}

http.StreamedResponse reply(Object data, [int status = 200]) =>
    http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(data))),
      status,
      headers: {
        'content-type': 'application/json',
        'cache-control': 'no-store',
      },
    );

void main() {
  test(
    'logout cancels a hanging screen read now and consumes its later error',
    () async {
      final adapter = FakeAdapter()..currentIdentity = identity('A');
      final facade = AppSession(adapter: adapter, clearLocal: () async {});
      await facade.restore();
      final original = Completer<String>();
      final read = facade.runAuthenticated((_) => original.future);
      final rejected = expectLater(read, throwsA(isA<AppSessionException>()));
      final logout = facade.logout();
      await rejected;
      expect(original.isCompleted, false);
      expect((await logout).confirmed, true);
      original.completeError(StateError('late original transport error'));
      await tick();
      await facade.close();
    },
  );

  test(
    'real native unknown refresh keeps unknown result despite its null identity event',
    () async {
      final store = Store();
      final wire = Wire((request) async {
      if (request.url.path.endsWith('/refresh')) {
        return reply({'error': 'unavailable'}, 503);
      }
        return reply({
          'uid': 'A',
          'emailVerified': true,
          'accessToken': 'na1.A.synthetic',
          'refreshToken': 'nr1.A.synthetic',
          'expiresIn': 900,
          'refreshExpiresIn': 1209600,
        });
      });
      final client = TimewebAuthClient(
        configuration: TimewebAuthConfiguration(
          endpoint: Uri.parse('https://clrs-api.example.invalid'),
          enabled: true,
        ),
        secureStore: store,
        transport: wire,
      );
      final facade = AppSession.timeweb(
        client: client,
        clearLocal: () async {},
      );
      await login(facade, 'A');
      final lease = facade.captureLease();
      final result = await facade.refresh();
      expect(result.outcome, AppSessionOutcome.remoteUnknown);
      expect(facade.currentUid, isNull);
      expect(lease.isCurrent, false);
      await tick();
      expect(facade.state.phase, AppSessionPhase.unresolved);
      expect(store.value, isNull);
      await facade.close();
    },
  );

  test(
    'provider bootstrap event does not supersede explicit restore',
    () async {
      final adapter = FakeAdapter()..currentIdentity = identity('A');
      final facade = AppSession(adapter: adapter, clearLocal: () async {});
      final restored = facade.restore();
      adapter.external(identity('A'));
      expect((await restored).confirmed, true);
      expect(facade.currentUid, 'A');
      expect(adapter.calls, ['restore']);
      await facade.close();
    },
  );

  test(
    'repeat login taps and startup restore share the actual login',
    () async {
      final adapter = FakeAdapter();
      final facade = AppSession(adapter: adapter, clearLocal: () async {});
      final one = login(facade, 'A');
      await tick();
      final two = login(facade, 'A');
      final restoring = facade.restore();
      expect(adapter.calls, ['login:A@example.invalid']);
      adapter.logins.single.complete(identity('A'));
      expect((await one).confirmed, true);
      expect((await two).confirmed, true);
      expect((await restoring).confirmed, true);
      expect(adapter.calls, ['login:A@example.invalid']);
      await facade.close();
    },
  );

  test(
    'native confirmed remote logout with failed secure clear blocks next login',
    () async {
      final store = Store();
      var loginCalls = 0;
      final wire = Wire((request) async {
        if (request.url.path.endsWith('/logout')) {
          return reply({'loggedOut': true});
        }
        loginCalls++;
        return reply({
          'uid': 'A',
          'emailVerified': true,
          'accessToken': 'na1.A.synthetic',
          'refreshToken': 'nr1.A.synthetic',
          'expiresIn': 900,
          'refreshExpiresIn': 1209600,
        });
      });
      final client = TimewebAuthClient(
        configuration: TimewebAuthConfiguration(
          endpoint: Uri.parse('https://clrs-api.example.invalid'),
          enabled: true,
        ),
        secureStore: store,
        transport: wire,
      );
      final facade = AppSession.timeweb(
        client: client,
        clearLocal: () async {},
      );
      expect((await login(facade, 'A')).confirmed, true);
      final lease = facade.captureLease();
      store.failClear = true;
      final logout = await facade.logout();
      expect(logout.outcome, AppSessionOutcome.failed);
      expect(logout.error, AppSessionError.secureStore);
      expect(logout.logout!.remoteConfirmed, true);
      expect(logout.logout!.localCleared, false);
      expect(facade.currentUid, isNull);
      expect(lease.isCurrent, false);
      expect((await login(facade, 'B')).error, AppSessionError.secureStore);
      expect(loginCalls, 1);
      store.failClear = false;
      await facade.close();
    },
  );

  test(
    'unknown refresh invalidates identity instead of reusing old credentials',
    () async {
      final adapter = FakeAdapter()..currentIdentity = identity('A');
      adapter.refreshing = Completer<AppSessionIdentity>();
      final facade = AppSession(adapter: adapter, clearLocal: () async {});
      await facade.restore();
      final lease = facade.captureLease();
      final refreshing = facade.refresh();
      adapter.refreshing!.completeError(
        const AppSessionException(
          AppSessionError.network,
          remoteOutcomeUnknown: true,
        ),
      );
      final result = await refreshing;
      expect(result.outcome, AppSessionOutcome.remoteUnknown);
      expect(facade.state.phase, AppSessionPhase.unresolved);
      expect(facade.currentUid, isNull);
      expect(lease.isCurrent, false);
      expect(adapter.calls.where((call) => call == 'refresh'), hasLength(1));
      await facade.close();
    },
  );

  test(
    'Firebase is the default; mismatched provider cannot become fallback',
    () async {
      final firebase = FakeAdapter()..currentIdentity = identity('A');
      final facade = AppSession(adapter: firebase, clearLocal: () async {});
      expect(facade.backend, AppSessionBackend.firebase);
      expect((await facade.restore()).confirmed, true);
      expect(facade.currentUid, 'A');
      expect(
        () => AppSession(
          adapter: FakeAdapter(backend: AppSessionBackend.timeweb),
          clearLocal: () async {},
        ),
        throwsArgumentError,
      );
      expect(
        () => AppSessionIdentity(
          backend: AppSessionBackend.timeweb,
          uid: 'A',
          emailVerified: true,
          admin: AppSessionAdmin.administrator,
        ),
        throwsArgumentError,
      );
      await facade.close();
    },
  );

  test(
    'local clear completes before restore or login adopts identity',
    () async {
      final adapter = FakeAdapter()..currentIdentity = identity('A');
      final pending = Completer<void>();
      var clearCount = 0;
      final facade = AppSession(
        adapter: adapter,
        clearLocal: () async {
          clearCount++;
          if (clearCount == 1) await pending.future;
        },
      );
      final restored = facade.restore();
      await tick();
      expect(adapter.calls, isEmpty);
      expect(facade.currentUid, isNull);
      pending.complete();
      expect((await restored).confirmed, true);
      expect(facade.currentUid, 'A');
      await facade.close();
    },
  );

  test(
    'deadline reports pending; original login settles without a second POST',
    () async {
      final adapter = FakeAdapter();
      final facade = AppSession(
        adapter: adapter,
        clearLocal: () async {},
        waitTimeout: const Duration(milliseconds: 8),
      );
      final pending = await login(facade, 'A');
      expect(pending.outcome, AppSessionOutcome.pending);
      expect(facade.state.phase, AppSessionPhase.authenticating);
      expect(facade.currentUid, isNull);
      expect(adapter.calls, ['login:A@example.invalid']);
      adapter.logins.single.complete(identity('A'));
      expect((await pending.settled!).confirmed, true);
      expect(adapter.calls, ['login:A@example.invalid']);
      expect(facade.currentUid, 'A');
      await facade.close();
    },
  );

  test(
    'started A then B is serialized; late A never becomes visible for B',
    () async {
      final adapter = FakeAdapter();
      final facade = AppSession(adapter: adapter, clearLocal: () async {});
      final visible = <String?>[];
      final subscription = facade.states.listen(
        (state) => visible.add(state.identity?.uid),
      );
      final a = login(facade, 'A');
      await tick();
      final b = login(facade, 'B');
      expect(facade.currentUid, isNull);
      expect(adapter.logins, hasLength(1));
      adapter.logins[0].complete(identity('A'));
      expect((await a).outcome, AppSessionOutcome.superseded);
      await tick();
      expect(adapter.logins, hasLength(2));
      expect(visible.whereType<String>(), isEmpty);
      adapter.logins[1].complete(identity('B'));
      expect((await b).confirmed, true);
      expect(facade.currentUid, 'B');
      await subscription.cancel();
      await facade.close();
    },
  );

  test(
    'external A -> null -> A invalidates held lease and old screen result',
    () async {
      final adapter = FakeAdapter()..currentIdentity = identity('A');
      final facade = AppSession(adapter: adapter, clearLocal: () async {});
      await facade.restore();
      final lease = facade.captureLease();
      final oldRead = Completer<String>();
      final read = facade.runAuthenticated((_) => oldRead.future);
      final rejected = expectLater(read, throwsA(isA<AppSessionException>()));
      adapter.external(null);
      adapter.external(identity('A'));
      await lease.whenInvalidated;
      await tick();
      expect(facade.currentUid, 'A');
      expect(lease.isCurrent, false);
      oldRead.complete('old portrait');
      await rejected;
      await facade.close();
    },
  );

  test(
    'overlapping clears cannot erase B after its identity is adopted',
    () async {
      final adapter = FakeAdapter()..currentIdentity = identity('A');
      final clears = <Completer<void>>[];
      var delay = false;
      final facade = AppSession(
        adapter: adapter,
        clearLocal: () async {
          if (delay) {
            final pending = Completer<void>();
            clears.add(pending);
            await pending.future;
          }
        },
      );
      await facade.restore();
      delay = true;
      adapter.external(identity('B'));
      await tick();
      final b = login(facade, 'B');
      await tick();
      expect(clears, hasLength(1));
      expect(adapter.logins, isEmpty);
      clears[0].complete();
      await tick();
      expect(clears, hasLength(2));
      expect(adapter.logins, isEmpty);
      clears[1].complete();
      await tick();
      adapter.logins.single.complete(identity('B'));
      expect((await b).confirmed, true);
      expect(facade.currentUid, 'B');
      delay = false;
      await facade.close();
    },
  );

  test('refresh is shared; same identity lease survives rotation', () async {
    final adapter = FakeAdapter()..currentIdentity = identity('A');
    adapter.refreshing = Completer<AppSessionIdentity>();
    final facade = AppSession(adapter: adapter, clearLocal: () async {});
    await facade.restore();
    final lease = facade.captureLease();
    final one = facade.refresh();
    final two = facade.refresh();
    expect(adapter.calls.where((call) => call == 'refresh'), hasLength(1));
    adapter.refreshing!.complete(identity('A'));
    expect((await one).confirmed, true);
    expect((await two).confirmed, true);
    expect(lease.isCurrent, true);
    await facade.close();
  });

  test(
    'logout drops UID at submission and waits behind pending login',
    () async {
      final adapter = FakeAdapter();
      final facade = AppSession(adapter: adapter, clearLocal: () async {});
      final signingIn = login(facade, 'A');
      await tick();
      final signingOut = facade.logout(allSessions: true);
      expect(facade.currentUid, isNull);
      expect(facade.state.phase, AppSessionPhase.signingOut);
      expect(adapter.calls, ['login:A@example.invalid']);
      adapter.logins.single.complete(identity('A'));
      expect((await signingIn).outcome, AppSessionOutcome.superseded);
      final result = await signingOut;
      expect(result.confirmed, true);
      expect(result.logout!.allSessions, true);
      expect(result.logout!.remoteConfirmed, true);
      expect(facade.currentUid, isNull);
      expect(adapter.currentIdentity, isNull);
      await facade.close();
    },
  );

  test(
    'unknown logout remains signed out locally and does not claim server confirmation',
    () async {
      final adapter = FakeAdapter()..currentIdentity = identity('A');
      adapter.logoutResult = const AppSessionLogout(
        remote: AppSessionRemoteLogout.unknown,
        localCleared: true,
        allSessions: false,
      );
      final facade = AppSession(adapter: adapter, clearLocal: () async {});
      await facade.restore();
      final result = await facade.logout();
      expect(result.outcome, AppSessionOutcome.remoteUnknown);
      expect(result.logout!.remoteConfirmed, false);
      expect(facade.state.phase, AppSessionPhase.signedOut);
      expect(facade.currentUid, isNull);
      await facade.close();
    },
  );

  test(
    'failed local clear is fail-closed and raw error is never exposed',
    () async {
      final adapter = FakeAdapter()..currentIdentity = identity('A');
      var fail = true;
      final facade = AppSession(
        adapter: adapter,
        clearLocal: () async {
          if (fail) throw StateError('private profile detail');
        },
      );
      final result = await facade.restore();
      expect(result.error, AppSessionError.localClear);
      expect(facade.currentUid, isNull);
      expect(adapter.calls, isEmpty);
      expect(facade.state.toString(), isNot(contains('private')));
      fail = false;
      await facade.close();
    },
  );

  test(
    'close invalidates pending login now, waits actual mutation, and clears afterward',
    () async {
      final adapter = FakeAdapter();
      final facade = AppSession(
        adapter: adapter,
        clearLocal: () async {},
        waitTimeout: const Duration(milliseconds: 8),
      );
      final signingIn = login(facade, 'A');
      await tick();
      final close = await facade.close();
      expect(close.outcome, AppSessionOutcome.pending);
      expect(facade.state.phase, AppSessionPhase.closed);
      expect(facade.currentUid, isNull);
      adapter.logins.single.complete(identity('A'));
      final loginResult = await signingIn;
      if (loginResult.settled != null) await loginResult.settled;
      expect((await close.settled!).confirmed, true);
      expect(adapter.calls.last, 'close');
      expect(adapter.currentIdentity, isNull);
      expect((await facade.restore()).error, AppSessionError.closed);
    },
  );

  test(
    'real native adapter maps token response, rejects unknown POST, and stays non-admin',
    () async {
      final store = Store();
      var valid = true;
      final wire = Wire((request) async {
        if (!valid) return reply({'bad': true});
        return reply({
          'uid': 'A',
          'emailVerified': true,
          'accessToken': 'na1.A.synthetic',
          'refreshToken': 'nr1.A.synthetic',
          'expiresIn': 900,
          'refreshExpiresIn': 1209600,
        });
      });
      final client = TimewebAuthClient(
        configuration: TimewebAuthConfiguration(
          endpoint: Uri.parse('https://clrs-api.example.invalid'),
          enabled: true,
        ),
        secureStore: store,
        transport: wire,
      );
      final facade = AppSession.timeweb(
        client: client,
        clearLocal: () async {},
      );
      expect((await login(facade, 'A')).confirmed, true);
      expect(facade.currentUid, 'A');
      expect(facade.state.identity!.isAdministrator, false);
      expect(facade.state.identity!.admin, AppSessionAdmin.unknown);
      valid = false;
      final result = await login(facade, 'B');
      expect(result.outcome, AppSessionOutcome.remoteUnknown);
      expect(facade.state.phase, AppSessionPhase.unresolved);
      expect(facade.currentUid, isNull);
      expect(store.value, isNull);
      await tick();
      expect(facade.state.phase, AppSessionPhase.unresolved);
      await facade.close();
    },
  );
}
