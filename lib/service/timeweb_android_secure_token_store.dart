import 'dart:async';
import 'dart:convert';

import 'timeweb_auth_client.dart';

typedef TimewebTokenStoreInvoker =
    Future<Object?> Function(String method, Map<String, Object?>? arguments);

enum TimewebTokenStoreFailure {
  busy,
  recoveryRequired,
  unavailable,
  unknown,
  corrupted,
}

class TimewebTokenStoreException implements Exception {
  const TimewebTokenStoreException(this.failure);
  final TimewebTokenStoreFailure failure;
  @override
  String toString() => 'TimewebTokenStoreException(${failure.name})';
}

/// Production transport is the Android Keystore MethodChannel bridge. This
/// pure-Dart part owns validation/unknown-result guards and is testable without
/// Flutter/AVD. It never implements plaintext files/preferences as fallback.
class TimewebAndroidSecureTokenStore implements TimewebSecureTokenStore {
  TimewebAndroidSecureTokenStore({
    required TimewebTokenStoreInvoker invoke,
    this.platformDeadline = const Duration(seconds: 7),
  }) : _invokePlatform = invoke {
    if (platformDeadline <= Duration.zero ||
        platformDeadline > const Duration(seconds: 30)) {
      throw ArgumentError('Invalid protected-store deadline.');
    }
  }

  final Duration platformDeadline;
  final TimewebTokenStoreInvoker _invokePlatform;
  bool _busy = false;
  bool _unsafe = false;
  bool get requiresRecovery => _unsafe;

  Future<Object?> _invoke(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      return await _invokePlatform(method, arguments).timeout(platformDeadline);
    } catch (_) {
      // PlatformException may contain raw details. Late replies have no state
      // continuation. Native singleton/journal still guard the actual IO.
      _unsafe = true;
      throw const TimewebTokenStoreException(TimewebTokenStoreFailure.unknown);
    }
  }

  Future<T> _operation<T>(bool clearing, Future<T> Function() action) async {
    if (_busy)
      throw const TimewebTokenStoreException(TimewebTokenStoreFailure.busy);
    if (_unsafe && !clearing) {
      throw const TimewebTokenStoreException(
        TimewebTokenStoreFailure.recoveryRequired,
      );
    }
    _busy = true;
    try {
      return await action();
    } on TimewebTokenStoreException {
      rethrow;
    } catch (_) {
      _unsafe = true;
      throw const TimewebTokenStoreException(
        TimewebTokenStoreFailure.unavailable,
      );
    } finally {
      _busy = false;
    }
  }

  @override
  Future<TimewebSession?> read() => _operation(false, () async {
    final value = await _invoke('read');
    if (value == null) return null;
    try {
      if (value is! String || utf8.encode(value).length > 32768)
        throw const FormatException();
      final data = jsonDecode(value);
      const fields = {
        'format',
        'uid',
        'emailVerified',
        'accessToken',
        'refreshToken',
        'accessExpiresAt',
        'refreshExpiresAt',
      };
      if (data is! Map<String, dynamic> ||
          data.length != fields.length ||
          !fields.every(data.containsKey) ||
          data['format'] != 1 ||
          data['uid'] is! String ||
          data['emailVerified'] is! bool ||
          data['accessToken'] is! String ||
          data['refreshToken'] is! String ||
          data['accessExpiresAt'] is! int ||
          data['refreshExpiresAt'] is! int ||
          data['accessExpiresAt'] <= 0 ||
          data['refreshExpiresAt'] <= 0)
        throw const FormatException();
      return TimewebSession(
        uid: data['uid'],
        emailVerified: data['emailVerified'],
        accessToken: data['accessToken'],
        refreshToken: data['refreshToken'],
        accessExpiresAt: DateTime.fromMillisecondsSinceEpoch(
          data['accessExpiresAt'],
          isUtc: true,
        ),
        refreshExpiresAt: DateTime.fromMillisecondsSinceEpoch(
          data['refreshExpiresAt'],
          isUtc: true,
        ),
      );
    } catch (_) {
      _unsafe = true;
      try {
        if (await _invoke('clear') == true) _unsafe = false;
      } catch (_) {
        /* remain unsafe */
      }
      throw const TimewebTokenStoreException(
        TimewebTokenStoreFailure.corrupted,
      );
    }
  });

  @override
  Future<void> write(TimewebSession session) => _operation(false, () async {
    final payload = jsonEncode({
      'format': 1,
      'uid': session.uid,
      'emailVerified': session.emailVerified,
      'accessToken': session.accessToken,
      'refreshToken': session.refreshToken,
      'accessExpiresAt': session.accessExpiresAt.millisecondsSinceEpoch,
      'refreshExpiresAt': session.refreshExpiresAt.millisecondsSinceEpoch,
    });
    if (utf8.encode(payload).length > 32768) {
      throw const TimewebTokenStoreException(
        TimewebTokenStoreFailure.unavailable,
      );
    }
    final result = await _invoke('write', {'payload': payload});
    if (result is! Map ||
        result.length != 1 ||
        result['operationId'] is! String ||
        !RegExp(
          r'^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$',
        ).hasMatch(result['operationId'])) {
      _unsafe = true;
      throw const TimewebTokenStoreException(TimewebTokenStoreFailure.unknown);
    }
    if (await _invoke('confirm', {'operationId': result['operationId']}) !=
        true) {
      _unsafe = true;
      throw const TimewebTokenStoreException(TimewebTokenStoreFailure.unknown);
    }
  });

  @override
  Future<void> clear() => _operation(true, () async {
    if (await _invoke('clear') != true) {
      _unsafe = true;
      throw const TimewebTokenStoreException(TimewebTokenStoreFailure.unknown);
    }
    _unsafe = false;
  });
}
