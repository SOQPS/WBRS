import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/service/session_service.dart';
import 'app_backend.dart';
import 'pending_write.dart';

class _AuthAttempt {
  _AuthAttempt(this.email, this.write);
  final String email;
  final PendingWrite write;
}

class AuthService {
  AuthService(
      {FirebaseAuth? auth,
      FirebaseFirestore? firestore,
      FirebaseMessaging? messaging,
      Future<void> Function()? clearLocal,
      this.waitTimeout = const Duration(seconds: 20)})
      : _auth = auth ?? firebaseAuth,
        _dbOverride = firestore,
        _messagingOverride = messaging,
        _clearLocal = clearLocal ?? SessionService.clearLocal;
  final FirebaseAuth _auth;
  final FirebaseFirestore? _dbOverride;
  final FirebaseMessaging? _messagingOverride;
  final Future<void> Function() _clearLocal;
  final Duration waitTimeout;
  FirebaseFirestore get _db => _dbOverride ?? firebaseFirestore;
  FirebaseMessaging get _messaging => _messagingOverride ?? firebaseMessaging;
  static final Map<FirebaseAuth, _AuthAttempt> _attempts = {};
  bool get hasPendingAttempt => _attempts[_auth] != null;
  String? get pendingEmail => _attempts[_auth]?.email;

  /// Passwords are never persisted. Keep only a name/email intent so a created
  /// account survives an interrupted optional display-name update.
  static Future<String?> _saveRegistrationIntent(
      String name, String email) async {
    final prefs = await SharedPreferences.getInstance();
    final previous = prefs.getString('registration_intent_v1');
    await prefs.setString(
        'registration_intent_v1',
        jsonEncode({
          'email': email.trim().toLowerCase(),
          'name': name.trim(),
        }));
    return previous;
  }

  static Future<String> registrationName(User user) async {
    final savedName = user.displayName?.trim() ?? '';
    if (savedName.isNotEmpty) return savedName;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('registration_intent_v1');
    if (raw != null) {
      try {
        final data = jsonDecode(raw) as Map<String, dynamic>;
        if (data['email'] == user.email?.trim().toLowerCase()) {
          return data['name']?.toString() ?? user.displayName ?? '';
        }
      } catch (_) {
        /* A malformed local intent cannot prevent account access. */
      }
    }
    return user.displayName ?? '';
  }

  Future<bool> _attempt(String email, Future<void> Function() action) async {
    var request = _attempts[_auth];
    if (request == null || request.write.failed) {
      request = _AuthAttempt(email.trim(), PendingWrite(action));
      _attempts[_auth] = request;
    }
    try {
      final confirmed = await request.write.wait(timeout: waitTimeout);
      if (confirmed && identical(_attempts[_auth], request)) {
        _attempts.remove(_auth);
      }
      return confirmed;
    } catch (_) {
      if (identical(_attempts[_auth], request)) _attempts.remove(_auth);
      rethrow;
    }
  }

  Future<String> loginWithUserNameAndPassword(
      String email, String password) async {
    try {
      final confirmed = await _attempt(email, () async {
        if (_auth.currentUser != null) await signOut();
        await _clearLocal();
        final credential = await _auth.signInWithEmailAndPassword(
            email: email.trim(), password: password);
        if (_auth.currentUser?.uid != credential.user?.uid) {
          throw StateError('Сеанс изменился. Повторите вход.');
        }
      });
      return confirmed ? 'ok' : 'pending';
    } on FirebaseAuthException catch (e) {
      return e.code;
    } catch (_) {
      return 'unknown';
    }
  }

  Future<bool> registerUserWithEmailAndPassword(
      String fullName, String email, String password) {
    return _attempt(email, () async {
      if (_auth.currentUser != null) await signOut();
      await _clearLocal();
      final previousIntent = await _saveRegistrationIntent(fullName, email);
      late final UserCredential credential;
      try {
        credential = await _auth.createUserWithEmailAndPassword(
            email: email.trim(), password: password);
      } on FirebaseAuthException catch (error) {
        if (error.code == 'email-already-in-use') {
          // A failed attempt must not replace an existing account's draft name.
          final prefs = await SharedPreferences.getInstance();
          if (previousIntent == null) {
            await prefs.remove('registration_intent_v1');
          } else {
            await prefs.setString('registration_intent_v1', previousIntent);
          }
        }
        rethrow;
      }
      final user = credential.user;
      if (user == null) throw StateError('Не получен созданный аккаунт.');
      try {
        await user
            .updateDisplayName(fullName.trim())
            .timeout(const Duration(seconds: 10));
      } catch (_) {
        // Auth already succeeded. The durable intent supplies the questionnaire
        // name; failure here must never invite another createUser request.
      }
      if (_auth.currentUser?.uid != user.uid) {
        throw StateError('Сеанс изменился.');
      }
    });
  }

  Future<void> signOut() async {
    final uid = _auth.currentUser?.uid;
    try {
      if (uid != null && !AppBackend.useEmulators) {
        try {
          final token = await _messaging.getToken().timeout(
                const Duration(seconds: 5),
              );
          if (token != null) {
            final ref = _db.collection('TOKENS').doc(uid);
            await _db.runTransaction((transaction) async {
              final current = await transaction.get(ref);
              // Do not detach a newer token belonging to another device.
              if (current.data()?['token'] == token) {
                transaction.update(ref, {'token': ''});
              }
            }).timeout(const Duration(seconds: 5));
          }
        } catch (_) {
          // Offline logout must still proceed.
        }
        try {
          await _messaging.deleteToken().timeout(
                const Duration(seconds: 5),
              );
        } catch (_) {}
      }
    } finally {
      await _auth.signOut();
      await _clearLocal();
    }
  }
}
