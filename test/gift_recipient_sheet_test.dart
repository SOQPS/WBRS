// Test-only Firestore double; no SDK or production data is accessed.
// ignore_for_file: subtype_of_sealed_class

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/presentation/screens/shop/shop.dart';
import 'package:wbrs/shared/lrs_theme.dart';

import 'support/layout_firebase_fakes.dart';

class _GiftFirestore extends LayoutFirestore {
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      path == 'chats' ? _GiftCollection(this, path) : super.collection(path);
}

class _GiftCollection extends LayoutCollection {
  _GiftCollection(super.db, super.path);

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #where) return this;
    return super.noSuchMethod(invocation);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });

  testWidgets(
    'Gift recipients use live profiles, omit deleted users and sort like chats',
    (tester) async {
      final db = _GiftFirestore()..serveEmittedQueries = true;
      addTearDown(db.close);
      final auth = LayoutAuth();
      db.documents['users/anastasia'] = {
        'fullName': 'Анастасия',
        'profilePic': '',
      };
      db.documents['users/earlier'] = {
        'fullName': 'Ранний собеседник',
        'profilePic': '',
      };
      db.documents['users/deleted'] = {
        'fullName': 'Удалённый аккаунт',
        'status': 'deleted',
      };
      db.emit(
        'chats',
        [
          {
            'user1': 'viewer',
            'user2': 'earlier',
            'user2Nickname': 'Старое имя',
            'lastMessageSendTs': Timestamp.fromDate(DateTime(2026, 9, 20)),
          },
          {
            'user1': 'viewer',
            'user2': 'deleted',
            'lastMessageSendTs': Timestamp.fromDate(DateTime(2026, 9, 30)),
          },
          {
            'user1': 'viewer',
            'user2': 'anastasia',
            'user2Nickname': 'piston',
            'lastMessageSendTs': Timestamp.fromDate(DateTime(2026, 9, 29)),
          },
        ],
        ids: ['old-chat', 'deleted-chat', 'current-chat'],
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: LrsTheme.theme,
          home: Scaffold(
            body: giftRecipientSheetForTesting(
              db: db,
              auth: auth,
              ownerUid: 'viewer',
              preferredRecipientUid: 'anastasia',
              preferredChatId: 'current-chat',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Анастасия'), findsOneWidget);
      expect(find.text('Ранний собеседник'), findsOneWidget);
      expect(find.text('Старое имя'), findsNothing);
      expect(find.text('Удалённый аккаунт'), findsNothing);
      final tiles = tester.widgetList<ListTile>(find.byType(ListTile)).toList();
      expect((tiles[0].title as Text).data, 'Анастасия');
      expect((tiles[1].title as Text).data, 'Ранний собеседник');
      expect(tiles[0].selected, isTrue);
      await tester.enterText(find.byType(TextField), 'Ана');
      await tester.pumpAndSettle();
      expect(find.text('Анастасия'), findsOneWidget);
      expect(find.text('Ранний собеседник'), findsNothing);
      expect(find.widgetWithText(ElevatedButton, 'Подарить'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Ранний');
      await tester.pumpAndSettle();
      expect(find.text('Анастасия'), findsNothing);
      expect(find.widgetWithText(ElevatedButton, 'Подарить'), findsNothing);
      await tester.tap(find.text('Ранний собеседник'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ElevatedButton, 'Подарить'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
