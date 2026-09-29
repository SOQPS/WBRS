import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/app/pages/admin/users.dart';
import 'package:wbrs/presentation/screens/list_of_users/show/somebody_profile.dart';
import 'package:wbrs/service/admin_access.dart';
import 'package:wbrs/service/admin_private_directory.dart';
import 'package:wbrs/service/session_service.dart';
import 'package:wbrs/shared/lrs_theme.dart';

import 'support/layout_firebase_fakes.dart';

class _Claims extends Fake implements IdTokenResult {
  _Claims(this.claims);
  @override
  final Map<String, dynamic> claims;
}

class _User extends LayoutUser {
  _User(this.owner, this.token);
  final String owner;
  final Future<IdTokenResult> token;
  int tokenReads = 0;
  bool? forceRefresh;
  @override
  String get uid => owner;
  @override
  Future<IdTokenResult> getIdTokenResult([bool forceRefresh = false]) {
    tokenReads++;
    this.forceRefresh = forceRefresh;
    return token;
  }
}

class _Auth extends LayoutAuth {
  final changes = StreamController<User?>.broadcast(sync: true);
  @override
  Stream<User?> authStateChanges() => changes.stream;
  void switchTo(User? next) {
    user = next;
    changes.add(next);
  }
}

class _DirectoryDb extends LayoutFirestore {
  int privateQueries = 0;
  Object? privateError;
  final queryBounds = <Map<Symbol, dynamic>>[];
  final profileReads = <String>[];
  final privateDocStreams =
      <String, Stream<DocumentSnapshot<Map<String, dynamic>>>>{};
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) {
    if (path == 'private_users') privateQueries++;
    return _DirectoryCollection(this, path);
  }
}

// SDK doubles only; the production service uses real snapshots and references.
// ignore: subtype_of_sealed_class
class _DirectoryCollection extends LayoutCollection {
  _DirectoryCollection(_DirectoryDb db, String path,
      {this.bounds = const [], this.limitValue = 40})
      : super(db, path);
  final List<Map<Symbol, dynamic>> bounds;
  final int limitValue;
  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) =>
      _DirectoryReference(db as _DirectoryDb, '${this.path}/${path ?? 'id'}');
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #where) {
      final row = Map<Symbol, dynamic>.from(invocation.namedArguments);
      (db as _DirectoryDb).queryBounds.add(row);
      return _DirectoryCollection(db as _DirectoryDb, path,
          bounds: [...bounds, row], limitValue: limitValue);
    }
    return super.noSuchMethod(invocation);
  }

  @override
  Query<Map<String, dynamic>> limit(int limit) =>
      _DirectoryCollection(db as _DirectoryDb, path,
          bounds: bounds, limitValue: limit);
  @override
  Stream<QuerySnapshot<Map<String, dynamic>>> snapshots({
    bool includeMetadataChanges = false,
    ListenSource source = ListenSource.defaultSource,
  }) {
    final directoryDb = db as _DirectoryDb;
    if (path == 'private_users' && directoryDb.privateError != null) {
      return Stream.error(directoryDb.privateError!);
    }
    return db.watch(path).map((page) => LayoutQuerySnapshot(page.docs
        .where((doc) {
          if (path != 'private_users') return true;
          final email = doc.data()['email'];
          if (email is! String) return false;
          for (final filter in bounds) {
            final lower = filter[#isGreaterThanOrEqualTo];
            final upper = filter[#isLessThanOrEqualTo];
            if (lower is String && email.compareTo(lower) < 0) return false;
            if (upper is String && email.compareTo(upper) > 0) return false;
          }
          return true;
        })
        .take(limitValue)
        .toList()));
  }
}

// ignore: subtype_of_sealed_class
class _DirectoryReference extends LayoutReference {
  _DirectoryReference(_DirectoryDb super.db, super.path);
  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get([GetOptions? options]) {
    if (path.startsWith('users/')) (db as _DirectoryDb).profileReads.add(path);
    return super.get(options);
  }

  @override
  Stream<DocumentSnapshot<Map<String, dynamic>>> snapshots({
    bool includeMetadataChanges = false,
    ListenSource source = ListenSource.defaultSource,
  }) {
    final directoryDb = db as _DirectoryDb;
    if (path.startsWith('private_users/')) {
      if (directoryDb.privateError != null)
        return Stream.error(directoryDb.privateError!);
      final pending = directoryDb.privateDocStreams[id];
      if (pending != null) return pending;
    }
    return super.snapshots(
        includeMetadataChanges: includeMetadataChanges, source: source);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _DirectoryDb db;
  late _Auth auth;
  late _User admin;
  final directories = <AdminPrivateDirectory>[];
  final target = <String, dynamic>{
    'uid': 'target',
    'fullName': 'Target',
    'balance': 27,
    'status': 'active',
    'profilePic': '',
    'группа': 'красная',
    'online': true,
    'city': 'Москва',
    'age': 35,
    'about': 'Описание',
    'hobbi': 'Интересы',
    'pol': 'мужской',
    'email': 'legacy@example.invalid',
  };
  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });
  setUp(() {
    db = _DirectoryDb();
    auth = _Auth();
    admin = _User('admin', Future.value(_Claims({'admin': true})));
    auth.user = admin;
    firebaseAuth = auth;
    firebaseFirestore = db;
    firebaseMessaging = LayoutMessaging();
    SessionService.readyUserId.value = admin.uid;
    db.documents['users/target'] = Map.from(target);
    db.documents['users/admin'] = {'uid': 'admin', 'fullName': 'Admin'};
    db.documents['private_users/target'] = {'email': 'private@example.invalid'};
  });
  tearDown(() async {
    for (final directory in directories) {
      await directory.dispose();
    }
    directories.clear();
    await auth.changes.close();
    await db.close();
  });
  AdminPrivateDirectory directory({bool enabled = true}) {
    final result =
        AdminPrivateDirectory(firestore: db, auth: auth, enabled: enabled);
    directories.add(result);
    return result;
  }

  Future<void> tick() => Future<void>.delayed(Duration.zero);
  Future<void> show(WidgetTester tester, Widget child) async {
    final actor = auth.currentUser as _User;
    final claims = await tester.runAsync(() => actor.token);
    // Re-create this resolved fixture future in the widget clock's zone.
    auth.user = _User(actor.uid, Future.value(claims!));
    await tester.pumpWidget(MaterialApp(theme: LrsTheme.theme, home: child));
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  test('default private-email mode is off and disabled reads never query',
      () async {
    expect(adminPrivateEmailEnabled, isFalse);
    await expectLater(
        directory(enabled: false).email('target').first, throwsStateError);
    expect(db.privateQueries, 0);
    expect(admin.tokenReads, 0);
  });
  test('ordinary profile roles cannot start any private read', () async {
    auth.user = _User('ordinary', Future.value(_Claims({'role': 'admin'})));
    db.documents['users/ordinary'] = {'role': 'admin', 'isAdmin': true};
    await expectLater(directory().email('target').first, throwsStateError);
    await expectLater(
        directory().searchEmail('private@').first, throwsStateError);
    expect(db.privateQueries, 0);
  });
  test(
      'server-authorized admin reads private email without copying into profile',
      () async {
    final before = Map<String, dynamic>.from(db.documents['users/target']!);
    expect(await directory().email('target').first, 'private@example.invalid');
    expect(admin.forceRefresh, isTrue);
    expect(db.documents['users/target'], before);
    expect(db.updates, 0);
  });
  test('missing private email never falls back to a public legacy field',
      () async {
    db.documents.remove('private_users/target');
    expect(await directory().email('target').first, isNull);
    expect(db.documents['users/target']!['email'], 'legacy@example.invalid');
  });
  test('denied private read returns error without legacy fallback', () async {
    db.privateError =
        FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied');
    await expectLater(
        directory().email('target').first, throwsA(isA<FirebaseException>()));
    expect(db.updates, 0);
  });
  test(
      'email search joins actual users by document UID and keeps email separate',
      () async {
    final request = directory().searchEmail('private@').first;
    await tick();
    db.emit('private_users', [
      {'email': 'private@example.invalid'}
    ], ids: [
      'target'
    ]);
    final page = await request;
    expect(page.docs.map((doc) => doc.id), ['target']);
    expect(page.docs.single.data()!['email'], 'legacy@example.invalid',
        reason: 'the actual snapshot is not rewritten with the private email');
    expect(page.emailByUid, {'target': 'private@example.invalid'});
    expect(db.profileReads, ['users/target']);
    expect(db.queryBounds.first[#isGreaterThanOrEqualTo], 'private@');
    expect(db.queryBounds.last[#isLessThanOrEqualTo], 'private@\uf8ff');
    expect(db.updates, 0);
  });
  test('orphaned or mismatched UID profiles are not joined', () async {
    db.documents['users/wrong'] = {'uid': 'target', 'fullName': 'Wrong'};
    final request = directory().searchEmail('private@').first;
    await tick();
    db.emit('private_users', [
      {'email': 'private@missing.invalid'},
      {'email': 'private@wrong.invalid'}
    ], ids: [
      'missing',
      'wrong'
    ]);
    final page = await request;
    expect(page.docs, isEmpty);
    expect(page.emailByUid, isEmpty);
  });
  test('account switch while claims are pending starts no private query',
      () async {
    final claims = Completer<IdTokenResult>();
    auth.user = _User('admin', claims.future);
    final request = directory().email('target').first;
    await tick();
    auth.switchTo(_User('ordinary', Future.value(_Claims({}))));
    claims.complete(_Claims({'admin': true}));
    await expectLater(request, throwsStateError);
    expect(db.privateQueries, 0);
  });
  for (final intermediate in [null, 'other']) {
    test('Auth ABA through $intermediate invalidates pending private query',
        () async {
      final claims = Completer<IdTokenResult>();
      auth.user = _User('admin', claims.future);
      final request = directory().email('target').first;
      await tick();
      auth.switchTo(intermediate == null
          ? null
          : _User(intermediate, Future.value(_Claims({'admin': true}))));
      auth.switchTo(_User('admin', Future.value(_Claims({'admin': true}))));
      claims.complete(_Claims({'admin': true}));
      await expectLater(request, throwsStateError);
      expect(db.privateQueries, 0);
    });
  }
  test('ready-session ABA invalidates a pending private query', () async {
    final claims = Completer<IdTokenResult>();
    auth.user = _User('admin', claims.future);
    final request = directory().email('target').first;
    await tick();
    SessionService.readyUserId.value = null;
    SessionService.readyUserId.value = 'admin';
    claims.complete(_Claims({'admin': true}));
    await expectLater(request, throwsStateError);
    expect(db.privateQueries, 0);
  });
  test('screen cancellation while claims load starts no private query',
      () async {
    final claims = Completer<IdTokenResult>();
    auth.user = _User('admin', claims.future);
    final subscription = directory().email('target').listen((_) {});
    await tick();
    await subscription.cancel();
    claims.complete(_Claims({'admin': true}));
    await tick();
    expect(db.privateQueries, 0);
  });
  test('account switch during profile join suppresses private search result',
      () async {
    final gate = Completer<DocumentSnapshot<Map<String, dynamic>>>();
    db.gets['users/target'] = gate.future;
    final request = directory().searchEmail('private@').first;
    await tick();
    db.emit('private_users', [
      {'email': 'private@example.invalid'}
    ], ids: [
      'target'
    ]);
    await tick();
    auth.switchTo(_User('ordinary', Future.value(_Claims({}))));
    gate.complete(
        LayoutSnapshot(db, 'users/target', db.documents['users/target']));
    await expectLater(request, throwsStateError);
    expect(db.updates, 0);
  });
  testWidgets('private email widget clears previous data on account change',
      (tester) async {
    final reader = directory();
    await show(
        tester,
        Scaffold(
            body: AdminPrivateEmail(
                directory: reader,
                uid: 'target',
                builder: (email) => Text(email))));
    expect(find.text('private@example.invalid'), findsOneWidget);
    auth.switchTo(_User('ordinary', Future.value(_Claims({}))));
    await tester.pump();
    expect(find.text('private@example.invalid'), findsNothing);
    expect(find.text('legacy@example.invalid'), findsNothing);
  });
  testWidgets('private email widget clears data when its target UID changes',
      (tester) async {
    final reader = directory();
    final pending = StreamController<DocumentSnapshot<Map<String, dynamic>>>();
    db.privateDocStreams['next'] = pending.stream;
    await show(
        tester,
        Scaffold(
            body: AdminPrivateEmail(
                directory: reader,
                uid: 'target',
                builder: (email) => Text(email))));
    expect(find.text('private@example.invalid'), findsOneWidget);
    await show(
        tester,
        Scaffold(
            body: AdminPrivateEmail(
                directory: reader,
                uid: 'next',
                builder: (email) => Text(email))));
    expect(find.text('private@example.invalid'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    // A request canceled before authorization may never subscribe to this
    // single-subscription fixture; its close future would then never finish.
    unawaited(pending.close());
  });
  for (final enabled in [false, true]) {
    testWidgets('admin users display correct email with private mode $enabled',
        (tester) async {
      await show(tester, Users(privateEmail: enabled));
      db.emit('users', [Map.from(target)], ids: ['target']);
      await tester.pump();
      await tester.pump();
      expect(
          find.text(
              enabled ? 'private@example.invalid' : 'legacy@example.invalid'),
          findsOneWidget);
      expect(
          find.text(
              enabled ? 'legacy@example.invalid' : 'private@example.invalid'),
          findsNothing);
      if (!enabled) expect(db.privateQueries, 0);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets(
      'private-mode other profile uses server admin claim and private email',
      (tester) async {
    await show(
        tester,
        SomebodyProfile(
            uid: 'target',
            photoUrl: '',
            name: 'Target',
            userInfo: Map.from(target),
            privateEmail: true));
    db.emit('users/target/images', []);
    await tester.pump();
    await tester.scrollUntilVisible(find.text('Электронная почта'), 220,
        maxScrolls: 40, scrollable: find.byType(Scrollable).first);
    await tester.pump();
    expect(find.text('private@example.invalid'), findsOneWidget);
    expect(find.text('legacy@example.invalid'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('ordinary private-mode profile never queries or renders email',
      (tester) async {
    auth.user = _User('ordinary', Future.value(_Claims({})));
    await show(
        tester,
        SomebodyProfile(
            uid: 'target',
            photoUrl: '',
            name: 'Target',
            userInfo: Map.from(target),
            privateEmail: true));
    db.emit('users/target/images', []);
    await tester.pump();
    await tester.drag(find.byType(ListView).first, const Offset(0, -1800));
    await tester.pump();
    expect(find.text('private@example.invalid'), findsNothing);
    expect(find.text('legacy@example.invalid'), findsNothing);
    expect(db.privateQueries, 0);
    await tester.pumpWidget(const SizedBox());
  });
  test('approved identities remain compatible with existing AdminAccess policy',
      () async {
    auth.user =
        _User(AdminAccess.approvedUids.first, Future.value(_Claims({})));
    expect(await directory().email('target').first, 'private@example.invalid');
  });
}
