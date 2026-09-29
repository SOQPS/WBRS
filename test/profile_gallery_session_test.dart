import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/app/widgets/show_image.dart';
import 'package:wbrs/service/session_service.dart';

import 'support/layout_firebase_fakes.dart';

class _PhotoUser extends LayoutUser {
  _PhotoUser(this.uid);
  @override
  final String uid;
  int photoUpdates = 0;
  @override
  Future<void> updatePhotoURL(String? photoURL) async => photoUpdates++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });
  late LayoutFirestore db;
  late LayoutAuth auth;
  late _PhotoUser owner;
  setUp(() {
    owner = _PhotoUser('owner');
    auth = LayoutAuth()..user = owner;
    db = LayoutFirestore();
    db.documents['users/owner'] = {'profilePic': 'old'};
    db.documents['users/next'] = {'profilePic': 'next-photo'};
    firebaseAuth = auth;
    firebaseFirestore = db;
    SessionService.readyUserId.value = owner.uid;
  });
  tearDown(() async => db.close());

  Future<void> gallery(WidgetTester tester) async {
    final rows = LayoutQuerySnapshot([
      LayoutSnapshot(
          db, 'users/owner/images/one', {'url': '', 'thumbnailUrl': 'small'}),
    ]);
    await tester.pumpWidget(MaterialApp(
        home: ShowImage(
      urls: const [''],
      index: 0,
      initList: const [],
      snapshot: AsyncSnapshot<QuerySnapshot<Map<String, dynamic>>>.withData(
          ConnectionState.active, rows),
    )));
    await tester.pump();
  }

  testWidgets('old gallery is hidden and cannot assign a photo to next account',
      (tester) async {
    await gallery(tester);
    final next = _PhotoUser('next');
    auth.user = next;
    SessionService.readyUserId.value = next.uid;
    await tester.pump();
    expect(find.text('Сделать аватаром'), findsNothing);
    expect(db.updates, 0);
    expect(db.documents['users/next']!['profilePic'], 'next-photo');
    expect(next.photoUpdates, 0);
  });

  testWidgets('double tap writes once; account switch skips Auth metadata',
      (tester) async {
    final gate = Completer<void>();
    db.updateHandler = (_, __) => gate.future;
    await gallery(tester);
    await tester.tap(find.text('Сделать аватаром'));
    await tester.tap(find.text('Сделать аватаром'));
    expect(db.updates, 1);
    final next = _PhotoUser('next');
    auth.user = next;
    SessionService.readyUserId.value = next.uid;
    gate.complete();
    await tester.pump();
    expect(owner.photoUpdates, 0);
    expect(next.photoUpdates, 0);
    expect(db.documents['users/next']!['profilePic'], 'next-photo');
    expect(tester.takeException(), isNull);
  });
}
