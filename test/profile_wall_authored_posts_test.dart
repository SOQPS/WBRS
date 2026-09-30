// A profile wall shows published posts by its owner alongside reposts.
// ignore_for_file: subtype_of_sealed_class
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/presentation/screens/feed/profile_wall_page.dart';

import 'support/layout_firebase_fakes.dart';

class _WallDatabase extends LayoutFirestore {
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      _WhereCollection(this, path);
}

class _WhereCollection extends LayoutCollection {
  _WhereCollection(super.db, super.path);

  @override
  Query<Map<String, dynamic>> where(Object field, {
    Object? isEqualTo, Object? isNotEqualTo, Object? isLessThan,
    Object? isLessThanOrEqualTo, Object? isGreaterThan,
    Object? isGreaterThanOrEqualTo, Object? arrayContains,
    Iterable<Object?>? arrayContainsAny, Iterable<Object?>? whereIn,
    Iterable<Object?>? whereNotIn, bool? isNull,
  }) => this;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });

  testWidgets('Own published post and another repost appear once on wall',
      (tester) async {
    final oldDb = firebaseFirestore;
    final oldAuth = firebaseAuth;
    final db = _WallDatabase();
    firebaseFirestore = db;
    firebaseAuth = LayoutAuth();
    addTearDown(() async {
      firebaseFirestore = oldDb;
      firebaseAuth = oldAuth;
      await db.close();
    });
    final now = Timestamp.fromDate(DateTime.utc(2026, 9, 30));
    db.documents['posts/own'] = {
      'status': 'published', 'authorUid': 'viewer', 'authorName': 'Автор стены',
      'text': '', 'createdAt': now,
    };
    db.documents['posts/shared'] = {
      'status': 'published', 'authorUid': 'other', 'authorName': 'Другой автор',
      'text': '', 'createdAt': now,
    };
    db.documents['posts/legacy'] = {
      'authorId': 'viewer', 'authorName': 'Старый автор', 'text': '',
      'images': <String>[], 'likesCount': 3, 'commentsCount': 1,
      'createdAt': now,
    };
    await tester.pumpWidget(const MaterialApp(
        home: ProfileWallPage(userUid: 'viewer')));
    db.emit('posts', [
      db.documents['posts/own']!, db.documents['posts/shared']!,
      db.documents['posts/legacy']!,
    ], ids: ['own', 'shared', 'legacy']);
    db.emit('users/viewer/wall', [
      {'sharedPostId': 'own', 'createdAt': now},
      {'sharedPostId': 'shared', 'createdAt': now},
    ], ids: ['own', 'shared']);
    await tester.pumpAndSettle();
    expect(find.text('Автор стены'), findsOneWidget,
        reason: 'The authored post must not duplicate its own repost.');
    expect(find.text('Другой автор'), findsOneWidget);
    expect(find.text('Старый автор'), findsOneWidget,
        reason: 'Legacy posts with authorId and no status stay visible.');
    expect(find.text('Репост'), findsOneWidget);
    expect(find.text('Комментарии'), findsNWidgets(2));
    expect(find.text(' 3  '), findsOneWidget);
    expect(find.text(' 1'), findsOneWidget);
  });
}
