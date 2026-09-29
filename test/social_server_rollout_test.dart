// Local SDK boundaries only; no Firebase project, rules or real account data.
// ignore_for_file: subtype_of_sealed_class
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/service/social_service.dart';

import 'support/layout_firebase_fakes.dart';

class _Storage extends Fake implements FirebaseStorage {}

class _Database extends LayoutFirestore {
  final committedChanges = <List<String>>[];
  final transactionReads = <String>[];
  void Function(String path)? afterRead;
  void Function(List<String> changes)? afterCommit;

  @override
  Future<T> runTransaction<T>(TransactionHandler<T> handler,
      {Duration timeout = const Duration(seconds: 30),
      int maxAttempts = 5}) async {
    transactions++;
    final tx = _Transaction(this);
    final result = await handler(tx);
    await commitGate?.future;
    if (commitError != null) throw commitError!;
    // Apply only after the handler and commit succeed. A rejected transaction
    // leaves both request mirrors and both friendship mirrors untouched.
    for (final operation in tx.operations) {
      operation();
    }
    final changes = List<String>.unmodifiable(tx.changes);
    committedChanges.add(changes);
    commits++;
    afterCommit?.call(changes);
    return result;
  }
}

class _Transaction extends Fake implements Transaction {
  _Transaction(this.db);
  final _Database db;
  final operations = <void Function()>[];
  final changes = <String>[];

  @override
  Future<DocumentSnapshot<T>> get<T extends Object?>(
      DocumentReference<T> ref) async {
    db.transactionReads.add(ref.path);
    final value = await LayoutReference(db, ref.path).get();
    db.afterRead?.call(ref.path);
    return value as DocumentSnapshot<T>;
  }

  @override
  Transaction set<T>(DocumentReference<T> ref, T data, [SetOptions? options]) {
    final value = Map<String, dynamic>.from(data as Map);
    changes.add('set ${ref.path}');
    operations.add(() => db.documents[ref.path] = value);
    return this;
  }

  @override
  Transaction delete(DocumentReference ref) {
    changes.add('delete ${ref.path}');
    operations.add(() => db.documents.remove(ref.path));
    return this;
  }

  @override
  Transaction update(DocumentReference ref, Map<String, dynamic> data) {
    changes.add('update ${ref.path}');
    operations.add(() => db.documents[ref.path]!.addAll(data));
    return this;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const incoming = 'users/receiver/friend_requests/sender';
  const outgoing = 'users/sender/friend_requests_sent/receiver';
  const receiverFriend = 'users/receiver/friends/sender';
  const senderFriend = 'users/sender/friends/receiver';
  const requestNotice = 'users/receiver/notifications/friend-request-sender';
  const acceptedNotice = 'users/sender/notifications/friend-accepted-receiver';
  late _Database db;
  String? currentUid;

  setUp(() {
    currentUid = 'sender';
    db = _Database()
      ..documents.addAll({
        'users/sender': {
          'fullName': 'Анна',
          'profilePic': 'sender-photo',
          'profilePicThumb': 'sender-thumb',
          'группа': 'красная',
          'status': 'active',
        },
        'users/receiver': {
          'fullName': 'Борис',
          'profilePic': 'receiver-photo',
          'profilePicThumb': 'receiver-thumb',
          'group': 'белая',
          'status': 'active',
        },
      });
  });
  tearDown(() => db.close());

  SocialService social({bool? serverMode}) => serverMode == null
      ? SocialService(
          firestore: db, storage: _Storage(), currentUid: () => currentUid)
      : SocialService(
          firestore: db,
          storage: _Storage(),
          currentUid: () => currentUid,
          serverSocialNotices: serverMode);

  void seedRequest() {
    db.documents[incoming] = {
      'fromUid': 'sender',
      'status': 'pending',
      'createdAt': Timestamp(1, 0),
    };
    db.documents[outgoing] = {
      'toUid': 'receiver',
      'status': 'pending',
      'createdAt': Timestamp(1, 0),
    };
  }

  Map<String, Map<String, dynamic>> snapshot() => {
        for (final entry in db.documents.entries)
          entry.key: Map<String, dynamic>.from(entry.value),
      };

  void expectNoClientInbox() {
    expect(db.documents.keys.where((path) => path.contains('/notifications/')),
        isEmpty);
    expect(
        db.transactionReads.where((path) => path.contains('/notifications/')),
        isEmpty);
    expect(
        db.committedChanges
            .expand((changes) => changes)
            .where((change) => change.contains('/notifications/')),
        isEmpty);
  }

  void expectLegacyNotice(String path, {required bool accepted}) {
    expect(db.documents[path], {
      'type': accepted ? 'friend_accepted' : 'friend_request',
      'title': accepted ? 'Заявка принята' : 'Заявка в друзья',
      'body': accepted
          ? 'Борис теперь у вас в друзьях'
          : 'Анна хочет добавить вас в друзья',
      'entityId': accepted ? 'receiver' : 'sender',
      'read': false,
      'createdAt': FieldValue.serverTimestamp(),
      'actorName': accepted ? 'Борис' : 'Анна',
      'actorPhoto': accepted ? 'receiver-photo' : 'sender-thumb',
    });
  }

  void expectAccepted({required bool serverMode}) {
    expect(db.documents[receiverFriend], {
      'uid': 'sender',
      'fullName': 'Анна',
      'profilePic': 'sender-photo',
      'profilePicThumb': 'sender-thumb',
      'группа': 'красная',
      'createdAt': FieldValue.serverTimestamp(),
      if (serverMode) 'acceptedByUid': 'receiver',
    });
    expect(db.documents[senderFriend], {
      'uid': 'receiver',
      'fullName': 'Борис',
      'profilePic': 'receiver-photo',
      'profilePicThumb': 'receiver-thumb',
      'группа': 'белая',
      'createdAt': FieldValue.serverTimestamp(),
      if (serverMode) 'acceptedByUid': 'receiver',
    });
    expect(db.documents.containsKey(incoming), isFalse);
    expect(db.documents.containsKey(outgoing), isFalse);
    expect(db.committedChanges.first, [
      'set $receiverFriend',
      'set $senderFriend',
      'delete $incoming',
      'delete $outgoing',
    ]);
  }

  for (final serverMode in [false, true]) {
    test('friend nickname mirrors prefer nickName server=$serverMode', () async {
      db.documents['users/sender']!['nickName'] = '  Светлая  ';
      db.documents['users/receiver']!['nickName'] = 'Мирный';
      await social(serverMode: serverMode).sendFriendRequest('receiver');
      expect(db.documents[incoming]!['fromName'], 'Светлая');
      expect(db.documents[outgoing]!['toName'], 'Мирный');
      expect(db.documents[incoming]!.containsKey('nickName'), isFalse);
      expect(db.documents[outgoing]!.containsKey('toNickName'), isFalse);
      currentUid = 'receiver';
      await social(serverMode: serverMode).acceptFriendRequest('sender');
      expect(db.documents[receiverFriend]!['fullName'], 'Светлая');
      expect(db.documents[senderFriend]!['fullName'], 'Мирный');
      expect(db.documents[receiverFriend]!['acceptedByUid'],
          serverMode ? 'receiver' : isNull);
    });

    test('social reaction notices server=$serverMode', () async {
      db.documents['posts/feed'] = {'authorUid': 'receiver', 'likeCount': 0};
      db.documents['posts/feed/comments/root'] = {
        'authorUid': 'receiver', 'likeCount': 0,
      };
      final service = social(serverMode: serverMode);
      await service.togglePostLike('feed');
      await service.toggleCommentLike('feed', 'root');
      expect(db.documents['posts/feed/likes/sender']!['uid'], 'sender');
      expect(db.documents['posts/feed/comments/root/likes/sender']!['uid'], 'sender');
      expect(db.documents['posts/feed']!['likeCount'], 1);
      expect(db.documents['posts/feed/comments/root']!['likeCount'], 1);
      if (serverMode) {
        expectNoClientInbox();
      } else {
        expect(db.documents['users/receiver/notifications/reaction-feed-post-sender']!['type'], 'post_like');
        expect(db.documents['users/receiver/notifications/reaction-feed-root-sender']!['type'], 'comment_like');
      }
    });

    test('social comment notices server=$serverMode', () async {
      db.documents['posts/feed'] = {'authorUid': 'receiver', 'commentCount': 0};
      final service = social(serverMode: serverMode);
      await service.addComment(postId: 'feed', text: 'Проверяемый комментарий', requestId: 'one');
      expect(db.documents['posts/feed/comments/one']!['authorUid'], 'sender');
      expect(db.documents['posts/feed']!['commentCount'], 1);
      if (serverMode) {
        expectNoClientInbox();
      } else {
        expect(db.documents['users/receiver/notifications/comment-one'], {
          'type': 'post_comment', 'title': 'Новый комментарий',
          'body': 'Анна прокомментировал(а) публикацию',
          'entityId': 'feed', 'read': false,
          'createdAt': FieldValue.serverTimestamp(),
          'actorName': 'Анна', 'actorPhoto': 'sender-photo',
        });
      }
    });
  }

  test('friend blank nickname mirrors preserve legacy fullName', () async {
    db.documents['users/sender']!['nickName'] = '   ';
    await social(serverMode: true).sendFriendRequest('receiver');
    expect(db.documents[incoming]!['fromName'], 'Анна');
    expect(db.documents[outgoing]!['toName'], 'Борис');
    currentUid = 'receiver';
    await social(serverMode: true).acceptFriendRequest('sender');
    expect(db.documents[receiverFriend]!['fullName'], 'Анна');
    expect(db.documents[senderFriend]!['fullName'], 'Борис');
  });

  test('No rollout flag keeps both existing client notifications', () async {
    expect(
        const bool.fromEnvironment('CLRS_SERVER_SOCIAL_NOTICES',
            defaultValue: false),
        isFalse);
    await social().sendFriendRequest('receiver');
    expectLegacyNotice(requestNotice, accepted: false);
    currentUid = 'receiver';
    await social().acceptFriendRequest('sender');
    expectLegacyNotice(acceptedNotice, accepted: true);
    expect(db.documents[receiverFriend]!.containsKey('acceptedByUid'), isFalse);
    expect(db.documents[senderFriend]!.containsKey('acceptedByUid'), isFalse);
  });

  for (final serverMode in [false, true]) {
    group(serverMode ? 'Server rollout enabled' : 'Legacy rollout disabled',
        () {
      test('Sending keeps both request schemas and retries do not rewrite them',
          () async {
        final service = social(serverMode: serverMode);
        await service.sendFriendRequest('receiver');
        expect(db.documents[incoming], {
          'fromUid': 'sender',
          'fromName': 'Анна',
          'fromPhoto': 'sender-thumb',
          'группа': 'красная',
          'createdAt': FieldValue.serverTimestamp(),
          'status': 'pending',
        });
        expect(db.documents[outgoing], {
          'toUid': 'receiver',
          'toName': 'Борис',
          'toPhoto': 'receiver-thumb',
          'группа': 'белая',
          'createdAt': FieldValue.serverTimestamp(),
          'status': 'pending',
        });
        expect(db.committedChanges.first, ['set $incoming', 'set $outgoing']);
        final beforeRetry = snapshot();
        await service.sendFriendRequest('receiver');
        expect(db.documents, beforeRetry);
        expect(db.committedChanges.where((changes) => changes.isNotEmpty),
            hasLength(serverMode ? 1 : 2));
        if (serverMode) {
          expectNoClientInbox();
        } else {
          expectLegacyNotice(requestNotice, accepted: false);
        }
      });

      test(
          'Acceptance atomically creates both friends and deletes both requests',
          () async {
        seedRequest();
        currentUid = 'receiver';
        final service = social(serverMode: serverMode);
        await service.acceptFriendRequest('sender');
        expectAccepted(serverMode: serverMode);
        final beforeRetry = snapshot();
        await service.acceptFriendRequest('sender');
        expect(db.documents, beforeRetry);
        expect(db.committedChanges.where((changes) => changes.isNotEmpty),
            hasLength(serverMode ? 1 : 2));
        if (serverMode) {
          expectNoClientInbox();
        } else {
          expectLegacyNotice(acceptedNotice, accepted: true);
        }
      });

      test('Failed commit preserves both requests and retry accepts once',
          () async {
        seedRequest();
        currentUid = 'receiver';
        final service = social(serverMode: serverMode);
        final before = snapshot();
        db.commitError = StateError('offline');
        await expectLater(
            service.acceptFriendRequest('sender'), throwsStateError);
        expect(db.documents, before);
        expect(db.committedChanges, isEmpty);
        db.commitError = null;
        await service.acceptFriendRequest('sender');
        expectAccepted(serverMode: serverMode);
      });

      test('Withdrawn request cannot create friendship or a notice', () async {
        currentUid = 'receiver';
        await expectLater(
            social(serverMode: serverMode).acceptFriendRequest('sender'),
            throwsStateError);
        expect(db.committedChanges, isEmpty);
        expect(db.documents.keys.where((path) => path.contains('/friends/')),
            isEmpty);
        expectNoClientInbox();
      });

      test('Old service cannot send or accept after account replacement',
          () async {
        seedRequest();
        currentUid = 'receiver';
        final service = social(serverMode: serverMode);
        final before = snapshot();
        currentUid = 'next-account';
        await expectLater(
            service.sendFriendRequest('sender'), throwsStateError);
        await expectLater(
            service.acceptFriendRequest('sender'), throwsStateError);
        expect(db.documents, before);
        expect(db.committedChanges, isEmpty);
      });

      test('Account switch during sending aborts both request mirrors',
          () async {
        final service = social(serverMode: serverMode);
        final before = snapshot();
        db.afterRead = (path) {
          if (path == 'users/sender/friend_requests/receiver') {
            currentUid = 'next-account';
          }
        };
        await expectLater(
            service.sendFriendRequest('receiver'), throwsStateError);
        expect(db.documents, before);
        expect(db.committedChanges, isEmpty);
      });

      test('Account switch during acceptance aborts friendship and deletion',
          () async {
        seedRequest();
        currentUid = 'receiver';
        final service = social(serverMode: serverMode);
        final before = snapshot();
        db.afterRead = (path) {
          if (path == receiverFriend) currentUid = 'next-account';
        };
        await expectLater(
            service.acceptFriendRequest('sender'), throwsStateError);
        expect(db.documents, before);
        expect(db.committedChanges, isEmpty);
      });

      test('An acceptance retry still checks its owner before the no-op return',
          () async {
        seedRequest();
        currentUid = 'receiver';
        final service = social(serverMode: serverMode);
        await service.acceptFriendRequest('sender');
        final before = snapshot();
        final previousCommits = db.committedChanges.length;
        db.afterRead = (path) {
          if (path == receiverFriend) currentUid = 'next-account';
        };
        await expectLater(
            service.acceptFriendRequest('sender'), throwsStateError);
        expect(db.documents, before);
        expect(db.committedChanges, hasLength(previousCommits));
      });

      test('Account switch after commit cannot write a notice as the new owner',
          () async {
        seedRequest();
        currentUid = 'receiver';
        final service = social(serverMode: serverMode);
        db.afterCommit = (changes) {
          if (changes.contains('set $receiverFriend')) {
            currentUid = 'next-account';
          }
        };
        await expectLater(
            service.acceptFriendRequest('sender'), throwsStateError);
        expectAccepted(serverMode: serverMode);
        expectNoClientInbox();
        expect(db.documents.keys.where((path) => path.contains('next-account')),
            isEmpty);
      });
    });
  }
}
