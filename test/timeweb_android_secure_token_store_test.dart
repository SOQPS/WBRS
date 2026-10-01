import 'dart:async';
import 'dart:convert';
import 'package:test/test.dart';

import '../lib/service/timeweb_android_secure_token_store.dart';
import '../lib/service/timeweb_auth_client.dart';

const _operation = '11111111-1111-4111-8111-111111111111';
final _now = DateTime.utc(2026, 10, 1);
TimewebSession _session(String uid) => TimewebSession(
  uid: uid,
  emailVerified: true,
  accessToken: 'na1.synthetic.$uid',
  refreshToken: 'nr1.synthetic.$uid',
  accessExpiresAt: _now.add(const Duration(minutes: 15)),
  refreshExpiresAt: _now.add(const Duration(days: 14)),
);
Matcher _failure(TimewebTokenStoreFailure failure) =>
    isA<TimewebTokenStoreException>().having(
      (error) => error.failure,
      'safe failure',
      failure,
    );

// In-memory protocol fixture only. This does not pretend to be Android crypto.
class _Native {
  final calls = <String>[];
  String? payload;
  bool dirty = false;
  bool confirmFails = false;
  bool clearFails = false;
  Future<Object?> invoke(String method, Map<String, Object?>? args) async {
    calls.add(method);
    switch (method) {
      case 'write':
        expect(args?.keys.toList(), ['payload']);
        payload = args!['payload'] as String;
        dirty = true;
        return {'operationId': _operation};
      case 'confirm':
        expect(args, {'operationId': _operation});
        if (confirmFails) return false;
        dirty = false;
        return true;
      case 'read':
        if (dirty) {
          payload = null;
          dirty = false;
          throw StateError('Synthetic corruption');
        }
        return payload;
      case 'clear':
        if (clearFails) return false;
        payload = null;
        dirty = false;
        return true;
      default:
        throw StateError('Unexpected synthetic method');
    }
  }

  TimewebAndroidSecureTokenStore store() =>
      TimewebAndroidSecureTokenStore(invoke: invoke);
}

void main() {
  test(
    'write confirms one native operation; restart reads exact protected session',
    () async {
      final native = _Native();
      final store = native.store();
      final value = _session('A');
      await store.write(value);
      expect(native.calls, ['write', 'confirm']);
      expect(native.dirty, isFalse);
      final restored = await native.store().read();
      expect(restored?.uid, value.uid);
      expect(restored?.emailVerified, value.emailVerified);
      expect(restored?.accessToken, value.accessToken);
      expect(restored?.refreshToken, value.refreshToken);
      expect(restored?.accessExpiresAt, value.accessExpiresAt);
      expect(restored?.refreshExpiresAt, value.refreshExpiresAt);
      await store.clear();
      expect(await native.store().read(), isNull);
    },
  );

  test(
    'only one platform operation is outstanding; concurrent clear does not bypass native IO',
    () async {
      final pending = Completer<Object?>();
      final calls = <String>[];
      final store = TimewebAndroidSecureTokenStore(
        invoke: (method, args) {
          calls.add(method);
          return pending.future;
        },
      );
      final read = store.read();
      await expectLater(
        store.clear(),
        throwsA(_failure(TimewebTokenStoreFailure.busy)),
      );
      expect(calls, ['read']);
      pending.complete(null);
      expect(await read, isNull);
    },
  );

  test(
    'lost write reply does not confirm late A and blocks reads/writes until explicit clear',
    () async {
      final pending = Completer<Object?>();
      final calls = <String>[];
      final store = TimewebAndroidSecureTokenStore(
        platformDeadline: const Duration(milliseconds: 15),
        invoke: (method, args) {
          calls.add(method);
          return method == 'write' ? pending.future : Future.value(true);
        },
      );
      await expectLater(
        store.write(_session('A')),
        throwsA(_failure(TimewebTokenStoreFailure.unknown)),
      );
      expect(store.requiresRecovery, isTrue);
      pending.complete({'operationId': _operation});
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['write']);
      await expectLater(
        store.read(),
        throwsA(_failure(TimewebTokenStoreFailure.recoveryRequired)),
      );
      await expectLater(
        store.write(_session('B')),
        throwsA(_failure(TimewebTokenStoreFailure.recoveryRequired)),
      );
      await store.clear();
      expect(store.requiresRecovery, isFalse);
      expect(calls, ['write', 'clear']);
    },
  );

  test(
    'unconfirmed native write stays dirty on restart; no old session is returned',
    () async {
      final native = _Native()..confirmFails = true;
      final store = native.store();
      await expectLater(
        store.write(_session('A')),
        throwsA(_failure(TimewebTokenStoreFailure.unknown)),
      );
      expect(native.dirty, isTrue);
      expect(store.requiresRecovery, isTrue);
      final restarted = native.store();
      await expectLater(
        restarted.read(),
        throwsA(_failure(TimewebTokenStoreFailure.unknown)),
      );
      expect(native.payload, isNull);
      await restarted.clear();
      expect(await restarted.read(), isNull);
    },
  );

  test(
    'lost confirm reply is unknown; late A cannot confirm or replace B',
    () async {
      final native = _Native();
      final pending = Completer<Object?>();
      var loseConfirm = true;
      final store = TimewebAndroidSecureTokenStore(
        platformDeadline: const Duration(milliseconds: 15),
        invoke: (method, args) {
          if (method == 'confirm' && loseConfirm) {
            native.calls.add(method);
            return pending.future;
          }
          return native.invoke(method, args);
        },
      );
      await expectLater(
        store.write(_session('A')),
        throwsA(_failure(TimewebTokenStoreFailure.unknown)),
      );
      expect(native.dirty, isTrue);
      await store.clear();
      loseConfirm = false;
      await store.write(_session('B'));
      pending.complete(true);
      await Future<void>.delayed(Duration.zero);
      expect((await store.read())?.uid, 'B');
      expect(native.calls, [
        'write',
        'confirm',
        'clear',
        'write',
        'confirm',
        'read',
      ]);
    },
  );

  for (final variant in [
    'bad json',
    'missing field',
    'wrong uid type',
    'wrong token',
    'wrong expiry',
    'oversized',
  ]) {
    test(
      'corrupt $variant response is never returned and triggers fail-closed clearing',
      () async {
        final native = _Native();
        await native.store().write(_session('A'));
        final value = jsonDecode(native.payload!) as Map<String, dynamic>;
        switch (variant) {
          case 'bad json':
            native.payload = '{';
            break;
          case 'missing field':
            value.remove('refreshToken');
            native.payload = jsonEncode(value);
            break;
          case 'wrong uid type':
            value['uid'] = 41;
            native.payload = jsonEncode(value);
            break;
          case 'wrong token':
            value['accessToken'] = 'bad';
            native.payload = jsonEncode(value);
            break;
          case 'wrong expiry':
            value['refreshExpiresAt'] = 1;
            native.payload = jsonEncode(value);
            break;
          default:
            native.payload = 'x' * 32769;
        }
        final store = native.store();
        await expectLater(
          store.read(),
          throwsA(_failure(TimewebTokenStoreFailure.corrupted)),
        );
        expect(native.payload, isNull);
        expect(native.calls.last, 'clear');
        expect(store.requiresRecovery, isFalse);
      },
    );
  }

  test(
    'corruption plus failed clear remains unsafe and explicit clear can later recover',
    () async {
      final native = _Native()
        ..payload = '{}'
        ..clearFails = true;
      final store = native.store();
      await expectLater(
        store.read(),
        throwsA(_failure(TimewebTokenStoreFailure.corrupted)),
      );
      expect(store.requiresRecovery, isTrue);
      await expectLater(
        store.clear(),
        throwsA(_failure(TimewebTokenStoreFailure.unknown)),
      );
      native.clearFails = false;
      await store.clear();
      expect(store.requiresRecovery, isFalse);
    },
  );

  test(
    'malformed write operation acknowledgement fails closed without confirm',
    () async {
      final calls = <String>[];
      final store = TimewebAndroidSecureTokenStore(
        invoke: (method, args) async {
          calls.add(method);
          return {'operationId': 'invalid', 'unexpected': 'Synthetic'};
        },
      );
      await expectLater(
        store.write(_session('A')),
        throwsA(_failure(TimewebTokenStoreFailure.unknown)),
      );
      expect(calls, ['write']);
      expect(store.requiresRecovery, isTrue);
    },
  );

  test(
    'native errors and late exceptions never expose token/UID/raw platform messages',
    () async {
      final store = TimewebAndroidSecureTokenStore(
        invoke: (_, args) async {
          throw StateError(
            'Synthetic private UID token ${args?.values.join()}',
          );
        },
      );
      try {
        await store.write(_session('A'));
        fail('must reject');
      } on TimewebTokenStoreException catch (error) {
        expect(error.toString(), isNot(contains('Synthetic private')));
        expect(error.toString(), isNot(contains('na1.')));
        expect(error.toString(), isNot(contains('nr1.')));
      }
      expect(store.requiresRecovery, isTrue);
    },
  );

  test(
    'lost clear response remains unknown, requires recovery and ignores late acknowledgement',
    () async {
      final pending = Completer<Object?>();
      var calls = 0;
      final store = TimewebAndroidSecureTokenStore(
        platformDeadline: const Duration(milliseconds: 15),
        invoke: (_, args) {
          calls++;
          return calls == 1 ? pending.future : Future.value(true);
        },
      );
      await expectLater(
        store.clear(),
        throwsA(_failure(TimewebTokenStoreFailure.unknown)),
      );
      pending.complete(true);
      await Future<void>.delayed(Duration.zero);
      expect(store.requiresRecovery, isTrue);
      await store.clear();
      expect(store.requiresRecovery, isFalse);
    },
  );

  test('deadline cannot be disabled or expanded indefinitely', () {
    for (final value in [Duration.zero, const Duration(seconds: 31)]) {
      expect(
        () => TimewebAndroidSecureTokenStore(
          invoke: (_, args) async => null,
          platformDeadline: value,
        ),
        throwsArgumentError,
      );
    }
  });
}
