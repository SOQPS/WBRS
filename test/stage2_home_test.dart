// Test doubles intentionally implement Firebase sealed query interfaces.
// ignore_for_file: subtype_of_sealed_class
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/app/widgets/chat_room_list.dart';
import 'package:wbrs/presentation/screens/home/home_page.dart';
import 'package:wbrs/service/app_backend.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'support/layout_firebase_fakes.dart';

class _HomeFirestore extends LayoutFirestore {
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      _HomeCollection(this, path);
}

class _HomeCollection extends LayoutCollection {
  _HomeCollection(super.db, super.path);
  @override
  Query<Map<String, dynamic>> where(Object field,
          {Object? isEqualTo,
          Object? isNotEqualTo,
          Object? isLessThan,
          Object? isLessThanOrEqualTo,
          Object? isGreaterThan,
          Object? isGreaterThanOrEqualTo,
          Object? arrayContains,
          Iterable<Object?>? arrayContainsAny,
          Iterable<Object?>? whereIn,
          Iterable<Object?>? whereNotIn,
          bool? isNull}) =>
      this;
}

class _MessagingSpy extends LayoutMessaging {
  int permissionCalls = 0, tokenCalls = 0;
  @override
  Future<NotificationSettings> requestPermission(
      {bool alert = true,
      bool announcement = false,
      bool badge = true,
      bool carPlay = false,
      bool criticalAlert = false,
      bool provisional = false,
      bool sound = true,
      bool providesAppNotificationSettings = false}) async {
    permissionCalls++;
    return getNotificationSettings();
  }

  @override
  Future<String?> getToken({String? vapidKey}) async {
    tokenCalls++;
    return 'test-token';
  }
}

class _OtherUser extends LayoutUser {
  @override
  String get uid => 'other-account';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });
  for (final size in [const Size(320, 640), const Size(640, 320)]) {
    testWidgets('Home chat list/error/empty and FCM mode at $size with 2x text',
        (tester) async {
      final db = _HomeFirestore();
      addTearDown(db.close);
      final messaging = _MessagingSpy();
      firebaseFirestore = db;
      firebaseAuth = LayoutAuth();
      firebaseMessaging = messaging;
      SharedPreferences.setMockInitialValues({});
      db.documents['users/viewer'] = {'uid': 'viewer'};
      db.documents['users/other'] = {
        'fullName': 'Очень длинное имя собеседника на узком экране',
        'группа': 'белая',
        'profilePic': '',
        'online': false
      };
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
          theme: LrsTheme.theme,
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!),
          home: const HomePage()));
      await tester.pump();
      db.emit('chats', []);
      await tester.pumpAndSettle();
      expect(find.text('Здесь появятся ваши диалоги'), findsOneWidget);
      expect(messaging.permissionCalls, AppBackend.useEmulators ? 0 : 1);
      expect(messaging.tokenCalls, AppBackend.useEmulators ? 0 : 1);
      db.streams['chats']!.addError(StateError('offline'));
      await tester.pumpAndSettle();
      expect(find.text('Не удалось загрузить чаты. Проверьте подключение.'),
          findsOneWidget);
      await tester.ensureVisible(find.text('Повторить'));
      await tester.pumpAndSettle();
      expect(find.text('Повторить').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Повторить'));
      await tester.pump();
      db.emit('chats', [
        for (var i = 0; i < 8; i++)
          {
            'user1': 'viewer',
            'user2': 'other',
            'lastMessage':
                'Очень длинное сообщение, которое должно быть видно в списке',
            'lastMessageSendBy': 'Другой собеседник',
            'lastMessageSendByID': 'other',
            'unreadMessage': 999
          }
      ]);
      await tester.pumpAndSettle();
      expect(find.text('Очень длинное имя собеседника на узком экране'),
          findsWidgets);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Chat filters keep favorites and archive separate per account',
      (tester) async {
    final db = _HomeFirestore();
    addTearDown(db.close);
    firebaseFirestore = db;
    firebaseAuth = LayoutAuth();
    firebaseMessaging = _MessagingSpy();
    SharedPreferences.setMockInitialValues({});
    db.documents['users/viewer'] = {'uid': 'viewer'};
    db.documents['users/alina'] = {
      'fullName': 'Алина', 'группа': 'синяя', 'profilePic': ''
    };
    db.documents['users/boris'] = {
      'fullName': 'Борис', 'группа': 'красная', 'profilePic': ''
    };
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 780);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        theme: LrsTheme.theme,
        home: const HomePage()));
    db.emit('chats', [
      {'user1':'viewer','user2':'alina','user2Nickname':'Алина',
       'lastMessageSendTs':Timestamp.fromDate(DateTime(2026,9,30)),
       'unreadMessage':2},
      {'user1':'viewer','user2':'boris','user2Nickname':'Борис',
       'lastMessageSendTs':Timestamp.fromDate(DateTime(2026,9,20)),
       'unreadMessage':0},
    ], ids: ['new-chat', 'old-chat']);
    await tester.pumpAndSettle();
    expect(find.byType(ChatRoomList), findsNWidgets(2));
    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('В избранное').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Избранные'));
    await tester.pumpAndSettle();
    expect(find.byType(ChatRoomList), findsOneWidget);
    expect(find.text('Алина'), findsOneWidget);
    await tester.tap(find.text('Все'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PopupMenuButton<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('В архив').last);
    await tester.pumpAndSettle();
    await tester.drag(find.byKey(const ValueKey('chat-filters')),
        const Offset(-220, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Архив'));
    await tester.pumpAndSettle();
    expect(find.byType(ChatRoomList), findsOneWidget);
    expect(find.text('Борис'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Search finds the name shown after a chat peer is renamed',
      (tester) async {
    final db = _HomeFirestore();
    addTearDown(db.close);
    firebaseFirestore = db;
    firebaseAuth = LayoutAuth();
    firebaseMessaging = _MessagingSpy();
    SharedPreferences.setMockInitialValues({});
    db.documents['users/viewer'] = {'uid': 'viewer'};
    db.documents['users/peer'] = {
      'fullName': 'Новое имя', 'profilePic': '',
    };
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 780);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        theme: LrsTheme.theme, home: const HomePage()));
    db.emit('chats', [{
      'user1': 'viewer', 'user2': 'peer',
      'user2Nickname': 'Старое имя',
      'unreadMessage': 0,
    }]);
    await tester.pumpAndSettle();
    expect(find.text('Новое имя'), findsOneWidget);
    await tester.tap(find.byTooltip('Поиск'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Новое');
    await tester.pumpAndSettle();
    expect(find.byType(ChatRoomList), findsOneWidget);
    expect(find.text('Новое имя'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Старое');
    await tester.pumpAndSettle();
    expect(find.byType(ChatRoomList), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Late peer-name read does not reveal a previous account chat',
      (tester) async {
    final db = _HomeFirestore();
    addTearDown(db.close);
    final auth = LayoutAuth();
    firebaseFirestore = db;
    firebaseAuth = auth;
    firebaseMessaging = _MessagingSpy();
    SharedPreferences.setMockInitialValues({});
    db.documents['users/viewer'] = {'uid': 'viewer'};
    final nameRead = Completer<DocumentSnapshot<Map<String, dynamic>>>();
    db.gets['users/peer'] = nameRead.future;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 780);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        theme: LrsTheme.theme, home: const HomePage()));
    db.emit('chats', [{
      'user1': 'viewer', 'user2': 'peer',
      'user2Nickname': 'Старое имя',
    }]);
    await tester.pump();
    await tester.tap(find.byTooltip('Поиск'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Новое');
    await tester.pump();
    auth.user = _OtherUser();
    nameRead.complete(LayoutSnapshot(db, 'users/peer', {
      'fullName': 'Новое имя',
    }));
    await tester.pump();
    await tester.pumpWidget(MaterialApp(
        theme: LrsTheme.theme, home: const HomePage()));
    expect(find.text('Сеанс завершён. Войдите снова.'), findsOneWidget);
    expect(find.text('Новое имя'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
