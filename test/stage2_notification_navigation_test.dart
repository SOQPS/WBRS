// Test-only Firebase interface doubles.
// ignore_for_file: subtype_of_sealed_class

import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/presentation/screens/chat_screen/chatscreen.dart';
import 'package:wbrs/presentation/screens/feed/post_detail_page.dart';
import 'package:wbrs/presentation/screens/notifications_center/notification_destination_page.dart';
import 'package:wbrs/shared/lrs_theme.dart';

import 'support/layout_firebase_fakes.dart';

class _NavigationFirebaseApp extends MockFirebaseApp {
  @override
  Future<List<CoreInitializeResponse>> initializeCore() async {
    final apps = await super.initializeCore();
    for (final app in apps) {
      app.options.storageBucket = 'clrs-test-bucket';
    }
    return apps;
  }
}

class _NavigationFirestore extends LayoutFirestore {
  final reads = <String>[];
  final sources = <Source?>[];
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      _NavigationCollection(this, path);
}

class _NavigationCollection extends LayoutCollection {
  _NavigationCollection(super.db, super.path);
  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) =>
      _NavigationReference(db as _NavigationFirestore, '${this.path}/$path');
}

class _NavigationReference extends LayoutReference {
  _NavigationReference(super.db, super.path);
  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get([GetOptions? options]) {
    final navigation = db as _NavigationFirestore;
    navigation.reads.add(path);
    navigation.sources.add(options?.source);
    return super.get(options);
  }
}

class _OtherUser extends LayoutUser {
  @override
  String get uid => 'other-viewer';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUpAll(() async {
    setupFirebaseCoreMocks();
    TestFirebaseCoreHostApi.setUp(_NavigationFirebaseApp());
    await Firebase.initializeApp();
    directory = await Directory.systemTemp.createTemp('clrs-notification-nav-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => directory.path);
  });
  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'), null);
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  late _NavigationFirestore db;
  late LayoutAuth auth;
  setUp(() {
    db = _NavigationFirestore();
    auth = LayoutAuth();
    firebaseFirestore = db;
    firebaseAuth = auth;
    firebaseMessaging = LayoutMessaging();
    db.documents['posts/valid'] = {
      'status': 'published',
      'text': 'Текущий серверный текст',
      'authorName': 'Автор',
      'authorUid': 'author',
    };
  });
  tearDown(() => db.close());

  Future<void> open(
      WidgetTester tester, Map<String, dynamic> notification) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
          theme: LrsTheme.theme,
          home: NotificationDestinationPage(notification: notification)));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
  }

  Future<void> emitComments(WidgetTester tester,
      [List<QueryDocumentSnapshot<Map<String, dynamic>>> rows =
          const []]) async {
    // Journal loading uses real temporary files; mount/IO finish outside fake time.
    await tester.runAsync(() async {
      await tester.pump();
      db.streams['posts/valid/comments']!.add(LayoutQuerySnapshot(rows));
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() async {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 25));
      });
      await tester.pump();
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
    }
    await tester.pumpAndSettle();
  }

  testWidgets(
      'Published reply notification opens and expands only its root thread',
      (tester) async {
    await open(tester, {
      'type': 'comment_reply',
      'entityId': 'valid',
      'rootCommentId': 'root',
      'text': 'Устаревшее содержимое уведомления',
    });
    await emitComments(tester, [
      LayoutSnapshot(db, 'posts/valid/comments/root', {
        'authorName': 'Родитель',
        'text': 'Нужный корневой комментарий',
      }),
      LayoutSnapshot(db, 'posts/valid/comments/child', {
        'authorName': 'Ответивший',
        'text': 'Ответ в нужной ветке',
        'parentId': 'root',
      }),
      LayoutSnapshot(db, 'posts/valid/comments/unrelated', {
        'authorName': 'Другой',
        'text': 'Чужая ветка',
      }),
    ]);
    final page = tester.widget<PostDetailPage>(find.byType(PostDetailPage));
    expect(page.postId, 'valid');
    expect(page.threadRootId, 'root');
    expect(page.post['text'], 'Текущий серверный текст');
    expect(find.text('Ветка комментариев'), findsOneWidget);
    expect(find.text('Нужный корневой комментарий'), findsOneWidget);
    expect(find.text('Ответ в нужной ветке'), findsOneWidget);
    expect(find.text('Чужая ветка'), findsNothing);
    expect(db.reads, ['posts/valid']);
    expect(db.sources, [Source.server]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Missing unpublished and invalid resources show unavailable safely',
      (tester) async {
    db.documents['posts/unpublished'] = {'status': 'draft'};
    for (final id in ['missing', 'unpublished', '', 'post/invalid']) {
      await tester.pumpWidget(const SizedBox());
      final previousReads = db.reads.length;
      await open(tester, {'type': 'post', 'entityId': id});
      await tester.pumpAndSettle();
      expect(
          find.text('Материал удалён или больше недоступен.'), findsOneWidget,
          reason: id);
      expect(find.byType(PostDetailPage), findsNothing, reason: id);
      expect(find.text('Повторить'), findsNothing, reason: id);
      if (id.isEmpty || id.contains('/')) {
        expect(db.reads.length, previousReads,
            reason: 'Malformed IDs must be rejected before a Firestore read.');
      }
      expect(tester.takeException(), isNull, reason: id);
    }
  });

  testWidgets('Gift notification opens only a chat owned by this account',
      (tester) async {
    db.documents['chats/gift-room'] = {
      'user1': 'viewer',
      'user2': 'friend',
    };
    db.documents['users/friend'] = {
      'fullName': 'Friend',
      'profilePic': '',
    };
    await open(tester, {'type': 'gift', 'entityId': 'gift-room'});
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(
        tester.widget<ChatScreen>(find.byType(ChatScreen)).chatId, 'gift-room');
    expect(db.reads.take(2), ['chats/gift-room', 'users/friend']);
    expect(db.sources.take(2), [Source.server, Source.server]);

    await tester.pumpWidget(const SizedBox.shrink());
    db.documents['chats/other-room'] = {
      'user1': 'stranger',
      'user2': 'friend',
    };
    await open(tester, {'type': 'gift', 'entityId': 'other-room'});
    await tester.pumpAndSettle();
    expect(find.byType(ChatScreen), findsNothing);
    expect(find.text('Материал удалён или больше недоступен.'), findsOneWidget);
    expect(db.reads.last, 'chats/other-room');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Backend denial offers retry and re-reads the published resource',
      (tester) async {
    final denied = Completer<DocumentSnapshot<Map<String, dynamic>>>();
    db.gets['posts/valid'] = denied.future;
    await open(tester, {'type': 'post', 'entityId': 'valid'});
    denied.completeError(FirebaseException(
        plugin: 'cloud_firestore', code: 'permission-denied'));
    await tester.pumpAndSettle();
    expect(find.byType(PostDetailPage), findsNothing);
    expect(find.text('Не удалось открыть уведомление. Проверьте подключение.'),
        findsOneWidget);
    expect(find.text('Повторить').hitTestable(), findsOneWidget);
    db.gets.remove('posts/valid');
    await tester.runAsync(() async {
      await tester.tap(find.text('Повторить'));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await emitComments(tester);
    expect(find.byType(PostDetailPage), findsOneWidget);
    expect(find.text('Текущий серверный текст'), findsOneWidget);
    expect(db.reads, ['posts/valid', 'posts/valid']);
    expect(db.sources, [Source.server, Source.server]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'UID change during resource load never renders the old destination',
      (tester) async {
    final loaded = Completer<DocumentSnapshot<Map<String, dynamic>>>();
    db.gets['posts/valid'] = loaded.future;
    await open(tester, {
      'type': 'comment_reply',
      'entityId': 'valid',
      'rootCommentId': 'root',
    });
    auth.user = _OtherUser();
    loaded.complete(
        LayoutSnapshot(db, 'posts/valid', db.documents['posts/valid']));
    await tester.pumpAndSettle();
    expect(find.byType(PostDetailPage), findsNothing);
    expect(find.text('Текущий серверный текст'), findsNothing);
    expect(db.subscriptions['posts/valid/comments'], isNull,
        reason: 'The stale destination must not start a comment stream.');
    expect(find.text('Повторить'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Leaving before the server read completes does not open a late page',
      (tester) async {
    final loaded = Completer<DocumentSnapshot<Map<String, dynamic>>>();
    db.gets['posts/valid'] = loaded.future;
    await open(tester, {'type': 'post', 'entityId': 'valid'});
    await tester.pumpWidget(const MaterialApp(home: Text('Другой экран')));
    loaded.complete(
        LayoutSnapshot(db, 'posts/valid', db.documents['posts/valid']));
    await tester.pumpAndSettle();
    expect(find.text('Другой экран'), findsOneWidget);
    expect(find.byType(PostDetailPage), findsNothing);
    expect(db.subscriptions['posts/valid/comments'], isNull);
    expect(tester.takeException(), isNull);
  });
}
