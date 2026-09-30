import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/localization/clrs_localizations.dart';

/// Only a Firebase Auth custom claim grants administration. Profile fields and
/// client-side UID lists cannot authorize privileged access.
class AdminAccess {
  static bool authorized(String uid, Map<String, dynamic>? claims) =>
      uid.isNotEmpty && claims?['admin'] == true;

  static Future<bool> current() async {
    final user = firebaseAuth.currentUser;
    if (user == null) return false;
    // A token refresh also notices roles revoked on the server.
    try {
      final result = await user.getIdTokenResult(true);
      return firebaseAuth.currentUser?.uid == user.uid &&
          authorized(user.uid, result.claims);
    } catch (_) {
      return false;
    }
  }
}

class AdminGuard extends StatefulWidget {
  const AdminGuard({super.key, required this.child});
  final Widget child;

  @override
  State<AdminGuard> createState() => _AdminGuardState();
}

class _AdminGuardState extends State<AdminGuard> {
  String? _checkedUid = firebaseAuth.currentUser?.uid;
  int _revision = 0;
  late Future<bool> _allowed = AdminAccess.current();
  late final StreamSubscription<User?> _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = firebaseAuth.authStateChanges().listen((user) {
      if (!mounted) return;
      setState(() {
        _checkedUid = user?.uid;
        _revision++;
        _allowed = AdminAccess.current();
      });
    });
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // An old route can remain mounted while Auth changes. Never display its
    // previous successful result while the new identity is being checked.
    if (_checkedUid == null || firebaseAuth.currentUser?.uid != _checkedUid) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return FutureBuilder<bool>(
      key: ValueKey(_revision),
      future: _allowed,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }
        if (snapshot.data != true) {
          return Scaffold(
              appBar: AppBar(),
              body: Center(child: Text(context.tr('Доступ запрещён'))));
        }
        return widget.child;
      },
    );
  }
}
