import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/app/widgets/chat_room_list.dart';
import 'package:wbrs/presentation/screens/chat_screen/chatscreen.dart';
import 'package:wbrs/service/chat_submission.dart';
import 'package:wbrs/service/submission_journal.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'support/layout_firebase_fakes.dart';
import 'support/memory_submission_journal.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });
  late LayoutFirestore db;
  late LayoutAuth auth;
  late MemorySubmissionJournal journal;
  var sequence = 0;
  late String chat;
  setUp(() {
    chat = 'personal-${sequence++}';
    db = LayoutFirestore();
    auth = LayoutAuth();
    journal = MemorySubmissionJournal();
    firebaseFirestore = db;
    firebaseAuth = auth;
    firebaseMessaging = LayoutMessaging();
    db.documents['chats/$chat'] = {
      'user1': 'viewer',
      'user2': 'other',
      'usersWOutNotifications': <String>[],
      'unreadMessage': 0
    };
    db.documents['users/viewer'] = {'uid': 'viewer'};
    db.documents['users/other'] = {
      'uid': 'other',
      'fullName': 'Очень длинное имя собеседника с несколькими словами',
      'profilePic': '',
      'группа': 'синяя',
      'online': false
    };
  });
  tearDown(() => db.close());
  ChatSubmissionService service({SubmissionJournal? storage}) =>
      ChatSubmissionService(
          firestore: db, auth: auth, journal: storage ?? journal);
  Future<void> pump(WidgetTester tester, Size size, double scale,
      {double keyboard = 0, bool emitInitial = true}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        theme: LrsTheme.theme,
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                viewInsets: EdgeInsets.only(bottom: keyboard)),
            child: child!),
        home: ChatScreen(
            chatWithUsername:
                'Очень длинное имя собеседника с несколькими словами',
            photoUrl: '',
            id: 'other',
            chatId: chat,
            submissions: service(),
            writeTimeout: const Duration(milliseconds: 20))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    if (emitInitial) {
      db.emit('chats/$chat/chats', [
        for (var n = 0; n < 15; n++)
          {
            'message':
                'Длинное сообщение, которое переносится на несколько строк. ' * 3,
            'sendBy': 'Очень длинное имя отправителя',
            'sendByID': 'other',
            'isRead': true,
            'ts': Timestamp.fromDate(DateTime(2026, 9, 22, 15, 5)),
          }
      ]);
      await tester.pumpAndSettle();
    }
  }

  for (final size in [
    const Size(320, 640),
    const Size(390, 844),
    const Size(640, 320)
  ]) {
    for (final scale in [1.3, 2.0]) {
      testWidgets('Personal chat fits $size at $scale with keyboard',
          (tester) async {
        await pump(tester, size, scale,
            keyboard: size.width > size.height ? 100 : 180);
        expect(tester.takeException(), isNull);
        expect(find.byType(TextField).hitTestable(), findsOneWidget);
        expect(find.byTooltip('Отправить сообщение').hitTestable(),
            findsOneWidget);
        await tester.enterText(
            find.byType(TextField), 'Текст не должен теряться');
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets('Personal chat loads older messages only on request',
      (tester) async {
    await pump(tester, const Size(390, 844), 1, emitInitial: false);
    db.serveEmittedQueries = true;
    final messages = [
      for (var n = 0; n < 75; n++)
        {
          'message': 'Сообщение $n',
          'sendBy': 'Другой пользователь',
          'sendByID': 'other',
          'isRead': true,
          'ts': Timestamp.fromDate(DateTime(2026, 9, 22, 15, 5)),
        }
    ];
    final ids = [for (var n = 0; n < messages.length; n++) 'm$n'];
    db.emit('chats/$chat/chats', messages, ids: ids);
    await tester.pumpAndSettle();
    var list = tester.widget<ListView>(find.byType(ListView));
    expect((list.childrenDelegate as SliverChildBuilderDelegate).childCount, 61);
    await tester.scrollUntilVisible(find.text('Загрузить ещё'), 400,
        scrollable: find.descendant(
            of: find.byType(ListView), matching: find.byType(Scrollable)).first);
    await tester.tap(find.text('Загрузить ещё'));
    await tester.pumpAndSettle();
    list = tester.widget<ListView>(find.byType(ListView));
    expect((list.childrenDelegate as SliverChildBuilderDelegate).childCount, 75);
    expect(db.streamedDocuments, 61);
    expect(db.fetchedDocuments, 15);
    expect(db.fetchedQueries, 1);
    db.emit('chats/$chat/chats', [
      {
        'message': 'Новое сообщение',
        'sendBy': 'Другой пользователь',
        'sendByID': 'other',
        'isRead': true,
        'ts': Timestamp.fromDate(DateTime(2026, 9, 22, 15, 6)),
      },
      ...messages,
    ], ids: ['new', ...ids]);
    await tester.pumpAndSettle();
    list = tester.widget<ListView>(find.byType(ListView));
    expect((list.childrenDelegate as SliverChildBuilderDelegate).childCount, 76);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Silent personal chat stream offers retry', (tester) async {
    await pump(tester, const Size(390, 844), 1, emitInitial: false);
    await tester.pump(const Duration(seconds: 21));
    expect(find.textContaining('Не удалось загрузить сообщения'), findsOneWidget);
    await tester.tap(find.text('Повторить'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    db.emit('chats/$chat/chats', [
      {
        'message': 'После повтора',
        'sendBy': 'Другой пользователь',
        'sendByID': 'other',
        'isRead': true,
        'ts': Timestamp.fromDate(DateTime(2026, 9, 22, 15, 5)),
      }
    ]);
    await tester.pumpAndSettle();
    expect(find.text('После повтора'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  test(
      'Repeated timeout checks share one write; late completion creates one message',
      () async {
    db.commitGate = Completer<void>();
    final firstService = service();
    final request =
        firstService.start(chatId: chat, recipientId: 'other', text: 'once');
    expect(await request.write.wait(timeout: const Duration(milliseconds: 1)),
        isFalse);
    final reopened = await service().restore(chat);
    expect(identical(request, reopened), isTrue);
    expect(await reopened!.write.wait(timeout: const Duration(milliseconds: 1)),
        isFalse);
    db.commitGate!.complete();
    expect(await reopened.write.wait(), isTrue);
    expect(
        db.documents.keys.where((key) => key.startsWith('chats/$chat/chats/')),
        hasLength(1));
    expect(db.commits, 1);
    expect(db.documents['chats/$chat']!['lastMessage'], 'once');
    firstService.acknowledge(chat, request);
    expect(await firstService.restore(chat), isNull);
  });
  test(
      'Durable identity reconciles an already committed message after process restart',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('clrs-chat-journal-');
    addTearDown(() => directory.delete(recursive: true));
    final disk = SubmissionJournal(directory: () async => directory);
    final saved = await disk.prepare(
        'viewer',
        'chatMessage/$chat',
        {
          'text': 'already committed',
          'recipientId': 'other',
          'reply': null,
          'timestamp': DateTime(2026, 9, 22).toIso8601String(),
        },
        null);
    db.documents['chats/$chat/chats/${saved['id']}'] = {
      'message': 'already committed'
    };
    final restored = await service(storage: disk).restore(chat);
    expect(restored!.text, 'already committed');
    expect(await restored.write.wait(), isTrue);
    expect(
        db.documents.keys.where((key) => key.startsWith('chats/$chat/chats/')),
        hasLength(1));
    expect(db.updates, 0,
        reason:
            'Reconciliation does not increment unread count or rewrite the preview.');
    expect(await disk.load('viewer', 'chatMessage/$chat'), isNull);
  });
  for (final alreadyCommitted in [false, true]) {
    test(
        'Group composer disk journal reconciles stable ID (committed=$alreadyCommitted)',
        () async {
      final directory =
          await Directory.systemTemp.createTemp('clrs-group-journal-');
      addTearDown(() => directory.delete(recursive: true));
      final disk = SubmissionJournal(directory: () async => directory);
      db.documents['meets/$chat'] = {
        'users': ['viewer', 'other']
      };
      db.documents['users/viewer'] = {
        'uid': 'viewer',
        'fullName': 'Stored sender',
        'группа': 'синяя'
      };
      final saved = await disk.prepare(
          'viewer',
          'meetingMessage/$chat',
          {
            'text': 'survives restart',
            'recipientId': null,
            'reply': null,
            'timestamp': DateTime(2026, 9, 22).toIso8601String(),
          },
          null);
      final path = 'meets/$chat/messages/${saved['id']}';
      if (alreadyCommitted)
        db.documents[path] = {'message': 'survives restart'};
      final restored = await service(storage: disk).restore(chat, group: true);
      expect(restored!.text, 'survives restart');
      expect(await restored.write.wait(), isTrue);
      expect(
          db.documents.keys
              .where((key) => key.startsWith('meets/$chat/messages/')),
          [path]);
      expect(db.updates, alreadyCommitted ? 0 : 1);
      if (!alreadyCommitted) {
        expect(db.documents[path]!['name'], 'Stored sender');
        expect(db.documents[path]!['group'], 'синяя');
        expect(
            db.documents['meets/$chat']!['recentMessage'], 'survives restart');
      }
      expect(await disk.load('viewer', 'meetingMessage/$chat'), isNull);
    });
  }
  test('Account change during recipient load prevents all transaction writes',
      () async {
    final gate = Completer<DocumentSnapshot<Map<String, dynamic>>>();
    db.gets['users/other'] = gate.future;
    final request = service()
        .start(chatId: chat, recipientId: 'other', text: 'must not send');
    expect(await request.write.wait(timeout: const Duration(milliseconds: 1)),
        isFalse);
    auth.user = null;
    gate.complete(
        LayoutSnapshot(db, 'users/other', db.documents['users/other']));
    await expectLater(request.write.wait(), throwsStateError);
    expect(db.commits, 0);
    expect(
        db.documents.keys.where((key) => key.startsWith('chats/$chat/chats/')),
        isEmpty);
  });
  testWidgets(
      'Late initial load after leaving chat causes no lifecycle exception',
      (tester) async {
    final gate = Completer<DocumentSnapshot<Map<String, dynamic>>>();
    db.gets['users/other'] = gate.future;
    await tester.pumpWidget(MaterialApp(
        home: ChatScreen(
            chatWithUsername: 'Other',
            photoUrl: '',
            id: 'other',
            chatId: chat,
            submissions: service())));
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    gate.complete(
        LayoutSnapshot(db, 'users/other', db.documents['users/other']));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  test('Retained profile tombstone blocks a new message transaction', () async {
    db.documents['users/other']!['status'] = 'deleted';
    final request =
        service().start(chatId: chat, recipientId: 'other', text: 'blocked');
    await expectLater(request.write.wait(), throwsStateError);
    expect(db.commits, 0);
    expect(
        db.documents.keys.where((key) => key.startsWith('chats/$chat/chats/')),
        isEmpty);
  });
  testWidgets(
      'Retained profile tombstone hides identity in list and disables composer',
      (tester) async {
    db.documents['users/other']!['status'] = 'deleted';
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ChatRoomList(
                snapshot: LayoutSnapshot(
                    db, 'chats/$chat', db.documents['chats/$chat'])))));
    await tester.pumpAndSettle();
    expect(find.text('Удаленный пользователь'), findsOneWidget);
    expect(find.text(db.documents['users/other']!['fullName'] as String),
        findsNothing);
    await pump(tester, const Size(390, 844), 1.3);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Аккаунт пользователя был удален. Чат больше недоступен.'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  test('Group replies verify the existing users membership field', () async {
    db.documents['meets/$chat'] = {
      'users': ['viewer', 'other']
    };
    final request = service().start(
        chatId: chat,
        group: true,
        replyId: 'quoted',
        text: 'reply',
        reply: {'message': 'quote'});
    expect(await request.write.wait(), isTrue);
    expect(
        db.documents.entries
            .where((entry) => entry.key.startsWith('meets/$chat/messages/'))
            .single
            .value['replyMessage'],
        {'message': 'quote'});
  });
}
