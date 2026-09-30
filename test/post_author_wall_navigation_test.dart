// A post opens its author's wall from the feed and from the post details.
// ignore_for_file: subtype_of_sealed_class
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/presentation/screens/feed/feed_page.dart';
import 'package:wbrs/presentation/screens/feed/post_detail_page.dart';
import 'package:wbrs/presentation/screens/feed/profile_wall_page.dart';
import 'package:wbrs/service/comment_submission.dart';
import 'package:wbrs/service/post_submission.dart';
import 'package:wbrs/service/social_service.dart';
import 'package:wbrs/shared/group_avatar.dart';

import 'support/layout_firebase_fakes.dart';
import 'support/memory_submission_journal.dart';

class _WallDatabase extends LayoutFirestore {
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      _WhereCollection(this, path);
}

class _WhereCollection extends LayoutCollection {
  _WhereCollection(super.db, super.path);

  @override
  Query<Map<String, dynamic>> where(
    Object field, {
    Object? isEqualTo,
    Object? isNotEqualTo,
    Object? isLessThan,
    Object? isLessThanOrEqualTo,
    Object? isGreaterThan,
    Object? isGreaterThanOrEqualTo,
    Object? arrayContains,
    Iterable<Object?>? arrayContainsAny,
    Iterable<Object?>? whereIn,
    Iterable<Object?>? whereNotIn,
    bool? isNull,
  }) => this;
}

class _Social extends Fake implements SocialService {
  _Social(this.db, this.post);
  final _WallDatabase db;
  final Map<String, dynamic> post;

  @override
  bool get isCurrentSession => true;
  @override
  Future<bool> canPublish() async => false;
  @override
  Future<bool> canModerateComments() async => false;
  @override
  Future<bool> isPostLiked(String postId) async => false;
  @override
  Stream<QuerySnapshot<Map<String, dynamic>>> feed({int limit = 40}) =>
      Stream.value(
        LayoutQuerySnapshot([LayoutSnapshot(db, 'posts/post', post)]),
      );
  @override
  Stream<QuerySnapshot<Map<String, dynamic>>> comments(String postId) =>
      Stream.value(LayoutQuerySnapshot([]));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });

  late _WallDatabase db;
  late FirebaseFirestore oldDb;
  late FirebaseAuth oldAuth;
  late FirebaseMessaging oldMessaging;
  late _Social social;
  setUp(() {
    oldDb = firebaseFirestore;
    oldAuth = firebaseAuth;
    oldMessaging = firebaseMessaging;
    db = _WallDatabase();
    firebaseFirestore = db;
    firebaseAuth = LayoutAuth();
    firebaseMessaging = LayoutMessaging();
  });
  tearDown(() async {
    firebaseFirestore = oldDb;
    firebaseAuth = oldAuth;
    firebaseMessaging = oldMessaging;
    await db.close();
  });

  testWidgets('Feed author name and avatar open that author wall', (
    tester,
  ) async {
    social = _Social(db, {
      'authorUid': 'ksusha-uid',
      'authorName': 'Ксюша',
      'text': 'Публикация Ксюши',
      'status': 'published',
    });
    await tester.pumpWidget(
      MaterialApp(
        home: FeedPage(
          social: social,
          postSubmissions: PostSubmissionService(
            social: social,
            journal: MemorySubmissionJournal(),
            currentUid: () => 'viewer',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ксюша'));
    await tester.pump(const Duration(milliseconds: 300));
    db.emit('posts', []);
    db.emit('users/ksusha-uid/wall', []);
    await tester.pumpAndSettle();
    expect(
      tester.widget<ProfileWallPage>(find.byType(ProfileWallPage)).userUid,
      'ksusha-uid',
    );
    expect(db.subscriptions['users/ksusha-uid/wall'], 1);

    await tester.pageBack();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byType(GroupAvatar).first);
    await tester.pump(const Duration(milliseconds: 300));
    db.emit('posts', []);
    db.emit('users/ksusha-uid/wall', []);
    await tester.pumpAndSettle();
    expect(
      tester.widget<ProfileWallPage>(find.byType(ProfileWallPage)).userUid,
      'ksusha-uid',
    );
  });

  testWidgets('Post details use legacy authorId and ignore missing ID', (
    tester,
  ) async {
    social = _Social(db, const {});
    Future<void> showPost(Map<String, dynamic> post) async {
      await tester.pumpWidget(
        MaterialApp(
          home: PostDetailPage(
            postId: 'post',
            post: post,
            social: social,
            submissions: CommentSubmissionService(
              social: social,
              journal: MemorySubmissionJournal(),
              currentUid: () => 'viewer',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await showPost({
      'authorUid': ' ',
      'authorId': 'legacy-ksusha',
      'authorName': 'Ксюша',
      'text': 'Старый пост',
    });
    await tester.tap(find.text('Ксюша'));
    await tester.pump(const Duration(milliseconds: 300));
    db.emit('posts', []);
    db.emit('users/legacy-ksusha/wall', []);
    await tester.pumpAndSettle();
    expect(
      tester.widget<ProfileWallPage>(find.byType(ProfileWallPage)).userUid,
      'legacy-ksusha',
    );
    expect(db.subscriptions['users/legacy-ksusha/wall'], 1);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await showPost({'authorName': 'Без UID', 'text': 'Пост'});
    await tester.tap(find.text('Без UID'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ProfileWallPage), findsNothing);
  });
}
