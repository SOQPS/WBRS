import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/service/admin_access.dart';
import 'package:wbrs/service/session_service.dart';

// Enable only after the email migration and compatible server rules are live.
const adminPrivateEmailEnabled =
    bool.fromEnvironment('CLRS_PRIVATE_EMAIL', defaultValue: false);

/// Keeps private email separate from the public profile maps and snapshots.
class AdminPrivateDirectoryPage {
  const AdminPrivateDirectoryPage(this.docs, this.emailByUid);
  final List<DocumentSnapshot<Map<String, dynamic>>> docs;
  final Map<String, String> emailByUid;
}

/// This is client compatibility, not a substitute for private_users rules.
class AdminPrivateDirectory {
  AdminPrivateDirectory({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    this.enabled = adminPrivateEmailEnabled,
  })  : _db = firestore ?? firebaseFirestore,
        _auth = auth ?? firebaseAuth {
    _owner = _auth.currentUser?.uid;
    _wasReady = _owner != null && SessionService.readyUserId.value == _owner;
    if (enabled) {
      SessionService.readyUserId.addListener(_readyChanged);
      _authChanges = _auth.authStateChanges().listen((user) {
        if (user?.uid != _owner) _invalidate();
      });
    }
  }

  final FirebaseFirestore _db;
  final FirebaseAuth _auth;
  final bool enabled;
  late final String? _owner;
  late final bool _wasReady;
  bool _invalidated = false, _disposed = false;
  StreamSubscription<User?>? _authChanges;
  final _boundaries = StreamController<void>.broadcast(sync: true);
  final _visibility = ValueNotifier<int>(0);
  Listenable get visibility => _visibility;
  Future<bool>? _authorization;

  bool get isCurrentSession =>
      !_disposed &&
      !_invalidated &&
      _owner != null &&
      _auth.currentUser?.uid == _owner;

  void _readyChanged() {
    if (_wasReady && SessionService.readyUserId.value != _owner) _invalidate();
  }

  void _invalidate() {
    if (_invalidated || _disposed) return;
    _invalidated = true;
    _visibility.value++;
    _boundaries.add(null);
  }

  void _requireSession() {
    if (!enabled || !isCurrentSession) throw StateError('Доступ запрещён');
  }

  Future<void> _requireAdmin() async {
    _requireSession();
    final task = _authorization ??= () async {
      final user = _auth.currentUser!;
      final token = await user.getIdTokenResult(true);
      return AdminAccess.authorized(user.uid, token.claims);
    }();
    try {
      final allowed = await task.timeout(const Duration(seconds: 15));
      _requireSession();
      if (!allowed) throw StateError('Доступ запрещён');
    } finally {
      if (identical(_authorization, task)) _authorization = null;
    }
  }

  Stream<T> _guarded<T>(Stream<T> Function() start) {
    late StreamController<T> controller;
    StreamSubscription<T>? source;
    StreamSubscription<void>? boundary;
    var active = false;
    controller = StreamController<T>(onListen: () {
      active = true;
      boundary = _boundaries.stream.listen((_) {
        if (!active) return;
        controller.addError(StateError('Доступ запрещён'));
        unawaited(source?.cancel());
      });
      unawaited(() async {
        try {
          await _requireAdmin();
          if (!active) return;
          _requireSession();
          source = start().listen((data) {
            if (active && isCurrentSession) controller.add(data);
          }, onError: (Object error, StackTrace stack) {
            if (active) controller.addError(error, stack);
          }, onDone: () {
            if (active) unawaited(controller.close());
          });
        } catch (error, stack) {
          if (active) {
            controller.addError(error, stack);
            await controller.close();
          }
        }
      }());
    }, onCancel: () async {
      active = false;
      await source?.cancel();
      await boundary?.cancel();
    });
    return controller.stream;
  }

  Stream<String?> email(String uid) => _guarded(() {
        if (uid.isEmpty || uid.contains('/')) throw ArgumentError('uid');
        return _db.collection('private_users').doc(uid).snapshots().map((doc) {
          _requireSession();
          final value = doc.data()?['email'];
          return value is String && value.isNotEmpty ? value : null;
        });
      });

  Stream<AdminPrivateDirectoryPage> searchEmail(String input) => _guarded(() {
        final prefix = input.trim();
        if (prefix.isEmpty || !prefix.contains('@')) {
          throw ArgumentError('email');
        }
        return _db
            .collection('private_users')
            .where('email', isGreaterThanOrEqualTo: prefix)
            .where('email', isLessThanOrEqualTo: '$prefix\uf8ff')
            .orderBy('email')
            .limit(40)
            .snapshots()
            .asyncMap((snapshot) async {
          _requireSession();
          final emails = <String, String>{};
          final docs = await Future.wait(snapshot.docs.map((private) async {
            _requireSession();
            final value = private.data()['email'];
            if (value is! String || value.isEmpty) return null;
            final profile = await _db
                .collection('users')
                .doc(private.id)
                .get(const GetOptions(source: Source.server))
                .timeout(const Duration(seconds: 15));
            _requireSession();
            if (!profile.exists ||
                (profile.data()?['uid'] != null &&
                    profile.data()?['uid'] != private.id)) return null;
            emails[private.id] = value;
            return profile;
          }));
          _requireSession();
          return AdminPrivateDirectoryPage(
              List.unmodifiable(
                  docs.whereType<DocumentSnapshot<Map<String, dynamic>>>()),
              Map.unmodifiable(emails));
        });
      });

  Future<void> dispose() async {
    if (_disposed) return;
    _invalidate();
    _disposed = true;
    if (enabled) SessionService.readyUserId.removeListener(_readyChanged);
    await _authChanges?.cancel();
    await _boundaries.close();
    _visibility.dispose();
  }
}

/// Never renders a legacy email fallback when the private reader fails.
class AdminPrivateEmail extends StatefulWidget {
  const AdminPrivateEmail(
      {super.key,
      required this.directory,
      required this.uid,
      required this.builder});
  final AdminPrivateDirectory directory;
  final String uid;
  final Widget Function(String email) builder;
  @override
  State<AdminPrivateEmail> createState() => _AdminPrivateEmailState();
}

class _AdminPrivateEmailState extends State<AdminPrivateEmail> {
  late Stream<String?> _email;
  @override
  void initState() {
    super.initState();
    _email = widget.directory.email(widget.uid);
  }

  @override
  void didUpdateWidget(AdminPrivateEmail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uid != widget.uid ||
        oldWidget.directory != widget.directory) {
      _email = widget.directory.email(widget.uid);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: widget.directory.visibility,
      builder: (context, _) => StreamBuilder<String?>(
          key: ValueKey((widget.directory, widget.uid)),
          stream: _email,
          builder: (context, snapshot) {
            if (snapshot.hasError ||
                !widget.directory.isCurrentSession ||
                (snapshot.data ?? '').isEmpty) return const SizedBox.shrink();
            return widget.builder(snapshot.data!);
          }));
}
