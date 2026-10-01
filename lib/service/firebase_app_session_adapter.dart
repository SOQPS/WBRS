import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';

import 'app_session.dart';

/// Maps only real Firebase SDK users. Pass the existing AuthService.signOut
/// action to retain notification-token detachment and local-clear behavior.
/// This adapter is not installed in AppBackend/SessionGate by this change.
final class FirebaseAppSessionAdapter implements AppSessionAdapter {
  FirebaseAppSessionAdapter({
    required FirebaseAuth auth,
    required Future<void> Function() signOut,
  }) : _auth = auth,
       _signOut = signOut {
    _previousUid = auth.currentUser?.uid;
    _subscription = auth.userChanges().listen(
      (user) {
        final uid = user?.uid;
        if (uid != _previousUid) _revision++;
        _previousUid = uid;
        if (!_changes.isClosed) _changes.add(_identity(user));
      },
      onError: (Object _) {
        if (!_changes.isClosed) {
          _changes.addError(
            const AppSessionException(AppSessionError.unavailable),
          );
        }
      },
    );
  }

  final FirebaseAuth _auth;
  final Future<void> Function() _signOut;
  final _changes = StreamController<AppSessionIdentity?>.broadcast();
  late final StreamSubscription<User?> _subscription;
  String? _previousUid;
  int _revision = 0;
  bool _closed = false;
  Future<bool>? _closeFlight;
  @override
  AppSessionBackend get backend => AppSessionBackend.firebase;
  @override
  AppSessionIdentity? get currentIdentity =>
      _closed ? null : _identity(_auth.currentUser);
  @override
  Stream<AppSessionIdentity?> get identityChanges => _changes.stream;

  AppSessionIdentity? _identity(User? user) => user == null
      ? null
      : AppSessionIdentity(
          backend: backend,
          uid: user.uid,
          emailVerified: user.emailVerified,
          email: user.email,
          displayName: user.displayName,
        );

  void _checkOpen() {
    if (_closed) throw const AppSessionException(AppSessionError.closed);
  }

  Future<T> _call<T>(
    Future<T> Function() action, {
    bool identityMutation = false,
  }) async {
    _checkOpen();
    try {
      return await action();
    } on AppSessionException {
      rethrow;
    } on FirebaseAuthException catch (error) {
      final mapped = switch (error.code) {
        'invalid-email' || 'missing-password' => AppSessionError.invalidRequest,
        'wrong-password' ||
        'user-not-found' ||
        'invalid-credential' ||
        'user-disabled' ||
        'requires-recent-login' => AppSessionError.unauthorized,
        'network-request-failed' => AppSessionError.network,
        'operation-not-allowed' => AppSessionError.disabled,
        _ => AppSessionError.unavailable,
      };
      throw AppSessionException(
        mapped,
        remoteOutcomeUnknown:
            identityMutation &&
            (mapped == AppSessionError.network ||
                mapped == AppSessionError.unavailable),
      );
    } catch (_) {
      throw AppSessionException(
        AppSessionError.unknown,
        remoteOutcomeUnknown: identityMutation,
      );
    }
  }

  @override
  Future<AppSessionIdentity?> restore() => _call(() async => currentIdentity);

  @override
  Future<AppSessionIdentity> login({
    required String email,
    required String password,
    required String deviceId,
  }) => _call(() async {
    // Match the existing AuthService switch sequence: a failed B login must
    // not leave A's Firebase credentials available for a later silent restore.
    if (_auth.currentUser != null) {
      try {
        await _signOut();
      } catch (_) {
        throw const AppSessionException(AppSessionError.secureStore);
      }
      if (_auth.currentUser != null) {
        throw const AppSessionException(AppSessionError.secureStore);
      }
    }
    // Await the original SDK Future. A bounded facade wait does not cancel it.
    final credential = await _auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    final user = credential.user;
    if (_closed || user == null || _auth.currentUser?.uid != user.uid) {
      throw const AppSessionException(AppSessionError.staleSession);
    }
    return _identity(user)!;
  }, identityMutation: true);

  @override
  Future<AppSessionIdentity> refresh() => _call(() async {
    final user = _auth.currentUser;
    if (user == null) {
      throw const AppSessionException(AppSessionError.notAuthenticated);
    }
    final revision = _revision;
    await user.getIdToken(true);
    if (_closed ||
        _auth.currentUser?.uid != user.uid ||
        revision != _revision) {
      throw const AppSessionException(AppSessionError.staleSession);
    }
    return currentIdentity!;
  });

  @override
  Future<AppSessionLogout> logout({required bool allSessions}) => _call(
    () async {
      await _signOut();
      if (_auth.currentUser != null) {
        throw const AppSessionException(AppSessionError.secureStore);
      }
      // Firebase SDK signOut removes this device's credentials. It does not
      // revoke refresh tokens on the server or confirm logout of other devices.
      return AppSessionLogout(
        remote: allSessions
            ? AppSessionRemoteLogout.unknown
            : AppSessionRemoteLogout.localOnly,
        localCleared: true,
        allSessions: allSessions,
      );
    },
    identityMutation: true,
  );

  @override
  Future<bool> close() {
    final existing = _closeFlight;
    if (existing != null) return existing;
    _closed = true;
    return _closeFlight = (() async {
      var cleared = false;
      try {
        await _signOut();
        cleared = _auth.currentUser == null;
      } catch (_) {
        /* Never present an uncertain clear as successful. */
      }
      await _subscription.cancel();
      await _changes.close();
      return cleared;
    })();
  }
}
