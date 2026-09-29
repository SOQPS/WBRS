import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/service/social_service.dart';
import 'package:wbrs/service/chat_submission.dart';

import 'support/layout_firebase_fakes.dart';
import 'support/memory_submission_journal.dart';

class _Storage extends Fake implements FirebaseStorage {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });

  test('Editable profile role cannot grant publication rights', () async {
    final previousAuth = firebaseAuth;
    firebaseAuth = LayoutAuth();
    final db = LayoutFirestore()
      ..documents['users/viewer'] = {'role': 'admin', 'isAdmin': true};
    addTearDown(() async {
      firebaseAuth = previousAuth;
      await db.close();
    });
    final social = SocialService(
        firestore: db, storage: _Storage(), currentUid: () => 'viewer');
    expect(await social.canPublish(), isFalse);
    db.documents['author_grants/viewer'] = {'status': 'approved'};
    expect(await social.canPublish(), isTrue);
  });

  test('Chat share points to a current post or comment, never a hidden post',
      () async {
    final db = LayoutFirestore()
      ..documents['posts/post-1'] = {
        'status': 'published',
        'authorName': 'Анна',
        'text': 'Новая публикация',
        'nativeLanguage': 'ru',
      }
      ..documents['posts/post-1/comments/reply-1'] = {
        'authorName': 'Павел',
        'text': 'Ответ',
        'parentId': 'root-1',
        'nativeLanguage': 'ru',
      };
    addTearDown(db.close);
    final social = SocialService(
        firestore: db, storage: _Storage(), currentUid: () => 'viewer');
    final post = await social.shareableContent('post-1');
    expect(post['kind'], 'post');
    expect(post['postId'], 'post-1');
    final comment =
        await social.shareableContent('post-1', commentId: 'reply-1');
    expect(comment['kind'], 'comment');
    expect(comment['threadRootId'], 'root-1');
    db.documents['posts/post-1']!['status'] = 'hidden';
    expect(social.shareableContent('post-1'), throwsStateError);
  });

  test('Shared post metadata is saved in the actual private chat message',
      () async {
    final auth = LayoutAuth();
    final db = LayoutFirestore()
      ..documents['chats/feed-share-test'] = {
        'user1': 'viewer',
        'user2': 'other',
        'usersWOutNotifications': ['other'],
        'unreadMessage': 0,
      }
      ..documents['users/other'] = {'fullName': 'Recipient'};
    addTearDown(db.close);
    final submissions = ChatSubmissionService(
        firestore: db, auth: auth, journal: MemorySubmissionJournal());
    final request = submissions.start(
        chatId: 'feed-share-test',
        recipientId: 'other',
        text: 'Публикация CLRS',
        sharedContent: {
          'kind': 'post',
          'postId': 'post-1',
          'commentId': '',
          'threadRootId': '',
          'text': 'Семейные традиции',
          'authorName': 'Анна',
          'imageUrl': '',
        });
    expect(await request.write.wait(), isTrue);
    final messages = db.documents.entries
        .where((entry) => entry.key.startsWith('chats/feed-share-test/chats/'))
        .toList();
    expect(messages, hasLength(1));
    expect((messages.single.value['sharedContent'] as Map)['postId'], 'post-1');
    submissions.acknowledge('feed-share-test', request);
  });
}
