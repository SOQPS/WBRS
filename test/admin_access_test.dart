import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/app/widgets/drawer.dart';
import 'package:wbrs/service/admin_access.dart';
import 'support/layout_firebase_fakes.dart';

class _Claims extends Fake implements IdTokenResult {
  _Claims(this.claims);
  @override
  final Map<String, dynamic>? claims;
}

class _User extends Fake implements User {
  _User(this.uid, this.token);
  @override
  final String uid;
  final Future<IdTokenResult> token;
  @override
  String get displayName => uid;
  @override
  String? get photoURL => null;
  @override
  Future<IdTokenResult> getIdTokenResult([bool forceRefresh = false]) => token;
}

class _Auth extends Fake implements FirebaseAuth {
  _User? user;
  final changes = StreamController<User?>.broadcast();
  @override
  User? get currentUser => user;
  @override
  Stream<User?> authStateChanges() => changes.stream;
  void switchTo(_User next) {
    user = next;
    changes.add(next);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });
  test('Only server claims or approved identities grant admin access', () {
    expect(AdminAccess.authorized('ordinary-user', null), isFalse);
    expect(AdminAccess.authorized('ordinary-user', {'role': 'admin'}), isFalse);
    expect(AdminAccess.authorized('ordinary-user', {'isAdmin': true}), isFalse);
    expect(AdminAccess.authorized('ordinary-user', {'admin': true}), isTrue);
    expect(
        AdminAccess.authorized(AdminAccess.approvedUids.first, null), isTrue);
  });

  testWidgets('Admin route hides previous account while next claim is pending',
      (tester) async {
    final originalAuth = firebaseAuth;
    final auth = _Auth()
      ..user = _User('admin-A', Future.value(_Claims({'admin': true})));
    firebaseAuth = auth;
    addTearDown(() async {
      firebaseAuth = originalAuth;
      await auth.changes.close();
    });
    await tester.pumpWidget(const MaterialApp(
        home: AdminGuard(child: Scaffold(body: Text('ADMIN CONTENT')))));
    await tester.pump();
    expect(find.text('ADMIN CONTENT'), findsOneWidget);

    final nextClaim = Completer<IdTokenResult>();
    auth.switchTo(_User('ordinary-B', nextClaim.future));
    await tester.pump();
    expect(find.text('ADMIN CONTENT'), findsNothing);

    nextClaim.complete(_Claims({}));
    await tester.pump();
    expect(find.text('ADMIN CONTENT'), findsNothing);
  });

  testWidgets('Open drawer clears previous profile before loading next one',
      (tester) async {
    final originalAuth = firebaseAuth;
    final originalDb = firebaseFirestore;
    final auth = _Auth()
      ..user = _User('admin-A', Future.value(_Claims({'admin': true})));
    final db = LayoutFirestore()
      ..documents['users/admin-A'] = {
        'fullName': 'OLD ACCOUNT',
        'profilePic': '',
        'группа': 'белая',
      }
      ..documents['users/ordinary-B'] = {
        'fullName': 'NEW ACCOUNT',
        'profilePic': '',
        'группа': 'синяя',
      };
    firebaseAuth = auth;
    firebaseFirestore = db;
    addTearDown(() async {
      firebaseAuth = originalAuth;
      firebaseFirestore = originalDb;
      await auth.changes.close();
      await db.close();
    });
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: MyDrawer())));
    await tester.pumpAndSettle();
    expect(find.text('OLD ACCOUNT'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Панель для админа'), 250,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Панель для админа'), findsOneWidget);

    final nextClaim = Completer<IdTokenResult>();
    auth.switchTo(_User('ordinary-B', nextClaim.future));
    await tester.pump();
    expect(find.text('OLD ACCOUNT'), findsNothing);
    expect(find.text('Панель для админа'), findsNothing);
    nextClaim.complete(_Claims({}));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, 1800));
    await tester.pumpAndSettle();
    expect(find.text('NEW ACCOUNT'), findsOneWidget);
    expect(find.text('Панель для админа'), findsNothing);
  });
}
