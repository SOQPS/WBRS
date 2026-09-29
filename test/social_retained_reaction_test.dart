// ignore_for_file: subtype_of_sealed_class
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/service/social_service.dart';

import 'support/layout_firebase_fakes.dart';

class _Storage extends Fake implements FirebaseStorage {}

class _Database extends LayoutFirestore {
  @override
  Future<T> runTransaction<T>(TransactionHandler<T> handler,
      {Duration timeout = const Duration(seconds: 30), int maxAttempts = 5}) async {
    transactions++;
    final tx = _Transaction(this);
    final result = await handler(tx);
    await commitGate?.future;
    if (commitError != null) throw commitError!;
    for (final operation in tx.operations) {
      await operation();
    }
    commits++;
    return result;
  }
}

class _Transaction extends LayoutTransaction {
  _Transaction(super.db);
  @override
  Transaction delete(DocumentReference ref) {
    operations.add(() async { db.documents.remove(ref.path); });
    return this;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Database db;
  String? uid;
  setUp(() {
    uid = 'reaction-a';
    db = _Database()
      ..documents['posts/p'] = {'authorUid': '', 'likeCount': 0}
      ..documents['posts/p/comments/c'] = {'authorUid': '', 'likeCount': 0};
  });
  tearDown(() => db.close());
  SocialService service() => SocialService(
      firestore: db, storage: _Storage(), currentUid: () => uid,
      serverSocialNotices: true);

  test('retained post reaction survives a new screen service without a second toggle', () async {
    db.commitGate = Completer<void>();
    final original = service().togglePostLike('p');
    await Future<void>.delayed(Duration.zero);
    final check = service().togglePostLike('p');
    expect(check, same(original));
    expect(db.transactions, 1);
    db.commitGate!.complete();
    await Future.wait([original, check]);
    expect(db.commits, 1);
    expect(db.documents['posts/p']!['likeCount'], 1);
    expect(db.documents['posts/p/likes/reaction-a']!['uid'], 'reaction-a');
    await service().togglePostLike('p');
    expect(db.transactions, 2);
    expect(db.documents['posts/p']!['likeCount'], 0);
  });

  test('retained comment reaction survives a new screen service without a second toggle', () async {
    db.commitGate = Completer<void>();
    final original = service().toggleCommentLike('p', 'c');
    await Future<void>.delayed(Duration.zero);
    final check = service().toggleCommentLike('p', 'c');
    expect(check, same(original));
    expect(db.transactions, 1);
    db.commitGate!.complete();
    await Future.wait([original, check]);
    expect(db.commits, 1);
    expect(db.documents['posts/p/comments/c']!['likeCount'], 1);
    await service().toggleCommentLike('p', 'c');
    expect(db.transactions, 2);
    expect(db.documents['posts/p/comments/c']!['likeCount'], 0);
  });

  test('retained reactions keep posts and comments independent', () async {
    db.commitGate = Completer<void>();
    final social = service();
    final post = social.togglePostLike('p');
    final comment = social.toggleCommentLike('p', 'c');
    await Future<void>.delayed(Duration.zero);
    expect(post, isNot(same(comment)));
    expect(db.transactions, 2);
    db.commitGate!.complete();
    await Future.wait([post, comment]);
    expect(db.documents['posts/p/likes/reaction-a']!['uid'], 'reaction-a');
    expect(db.documents['posts/p/comments/c/likes/reaction-a']!['uid'], 'reaction-a');
  });

  test('retained reaction belongs to its original UID after an account switch', () async {
    db.commitGate = Completer<void>();
    final oldService = service();
    final original = oldService.togglePostLike('p');
    await Future<void>.delayed(Duration.zero);
    uid = 'reaction-b';
    final next = service().togglePostLike('p');
    await Future<void>.delayed(Duration.zero);
    expect(next, isNot(same(original)));
    expect(oldService.isCurrentSession, isFalse);
    expect(db.transactions, 2);
    db.commitGate!.complete();
    await Future.wait([original, next]);
    expect(db.documents['posts/p/likes/reaction-a']!['uid'], 'reaction-a');
    expect(db.documents['posts/p/likes/reaction-b']!['uid'], 'reaction-b');
  });

  test('retained reaction releases a confirmed failure for a deliberate retry', () async {
    db.commitError = StateError('denied');
    final original = service().togglePostLike('p');
    await expectLater(original, throwsStateError);
    expect(db.documents.containsKey('posts/p/likes/reaction-a'), isFalse);
    db.commitError = null;
    final retry = service().togglePostLike('p');
    expect(retry, isNot(same(original)));
    await retry;
    expect(db.transactions, 2);
    expect(db.commits, 1);
    expect(db.documents['posts/p']!['likeCount'], 1);
  });

  test('retained reaction rejects a stale service through its Future without a write', () async {
    final previous = service();
    uid = 'reaction-b';
    final post = previous.togglePostLike('p');
    final comment = previous.toggleCommentLike('p', 'c');
    await Future.wait([
      expectLater(post, throwsStateError),
      expectLater(comment, throwsStateError),
    ]);
    expect(db.transactions, 0);
    expect(db.commits, 0);
  });
}
