import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/presentation/screens/list_of_meets/show/about_individual_meet.dart';
import 'package:wbrs/presentation/screens/meet_chat_screen/chat_page.dart';
import 'package:wbrs/service/meeting_membership_service.dart';
import 'package:wbrs/service/chat_submission.dart';
import 'package:wbrs/service/submission_journal.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'support/layout_firebase_fakes.dart';
import 'support/memory_submission_journal.dart';

class _UnclearedJournal extends SubmissionJournal {
  _UnclearedJournal({required super.directory});
  @override
  Future<void> acknowledge(String uid, String scope, String requestId) async {}
}

// Collection fixture supplies the real archived messages to the service.
// ignore: subtype_of_sealed_class
class _ArchiveDb extends LayoutFirestore {
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      _ArchiveCollection(this, path);
}

// ignore: subtype_of_sealed_class
class _ArchiveCollection extends LayoutCollection {
  _ArchiveCollection(super.db, super.path);
  @override
  DocumentReference<Map<String, dynamic>> doc([String? id]) =>
      _ArchiveReference(db, '$path/${id ?? 'fixture'}');
  @override
  Future<QuerySnapshot<Map<String, dynamic>>> get(
          [GetOptions? options]) async =>
      LayoutQuerySnapshot([
        for (final e in db.documents.entries.where((e) =>
            e.key.startsWith('$path/') &&
            e.key.split('/').length == path.split('/').length + 1))
          LayoutSnapshot(db, e.key, e.value)
      ]);
}

// ignore: subtype_of_sealed_class
class _ArchiveReference extends LayoutReference {
  _ArchiveReference(super.db, super.path);
  @override
  CollectionReference<Map<String, dynamic>> collection(String child) =>
      _ArchiveCollection(db, '$path/$child');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });
  late LayoutFirestore db;
  late String? current;
  var serial = 0;
  late String id;
  late MemorySubmissionJournal journal;
  setUp(() {
    id = 'meeting-${serial++}';
    current = 'viewer';
    db = LayoutFirestore();
    journal = MemorySubmissionJournal();
    firebaseFirestore = db;
    firebaseAuth = LayoutAuth();
    firebaseMessaging = LayoutMessaging();
    db.documents['meets/$id'] = {
      'name': 'Прогулка в парке',
      'users': ['organizer'],
      'admin': 'organizer',
      'description': 'Описание встречи на всю ширину',
      'country': 'Россия',
      'region': 'Москва'
    };
    db.documents['users/organizer'] = {
      'fullName': 'Организатор',
      'age': 'legacy',
      'profilePic': '',
      'группа': 'синяя'
    };
    db.documents['users/viewer'] = {
      'fullName': 'Участник',
      'profilePic': '',
      'группа': 'белая'
    };
  });
  tearDown(() async => db.close());
  MeetingMembershipService service({SubmissionJournal? store}) =>
      MeetingMembershipService(
          meetingId: id,
          firestore: db,
          journal: store ?? journal,
          currentUid: () => current,
          actorName: () => 'Участник');

  test('Join atomically writes desired member and one metadata notification',
      () async {
    final s = service(), request = service().change(joined: true);
    expect(await request.write.wait(), isTrue);
    s.acknowledge(request);
    expect(db.documents['meets/$id']!['users'], ['organizer', 'viewer']);
    final notifications =
        db.documents.entries.where((e) => e.key.contains('/notifications/'));
    expect(notifications.length, 1);
    expect(notifications.single.value, containsPair('type', 'meeting'));
    expect(notifications.single.value, containsPair('entityId', id));
    expect(notifications.single.value, containsPair('actorName', 'Участник'));
    final second = s.change(joined: true);
    expect(await second.write.wait(), isTrue);
    s.acknowledge(second);
    expect(
        db.documents.entries
            .where((e) => e.key.contains('/notifications/'))
            .length,
        1);
  });
  test('Notification transaction rejection leaves membership unchanged',
      () async {
    db.commitError = StateError('notification permission denied');
    final r = service().change(joined: true);
    await expectLater(r.write.wait(), throwsStateError);
    expect(db.documents['meets/$id']!['users'], ['organizer']);
    expect(
        db.documents.keys.where((e) => e.contains('/notifications/')), isEmpty);
    expect(await journal.load('viewer', 'membership/$id'), isNotNull);
  });
  test('Unknown outcome uses same request even when opposite action is tapped',
      () async {
    db.commitGate = Completer<void>();
    final s = service(), r = service().change(joined: true);
    expect(
        await r.write.wait(timeout: const Duration(milliseconds: 1)), isFalse);
    expect(identical(s.change(joined: false), r), isTrue);
    db.commitGate!.complete();
    expect(await r.write.wait(), isTrue);
    s.acknowledge(r);
    expect(db.commits, 1);
  });
  test('Already kicked or removed meeting cannot show successful join',
      () async {
    db.documents['meets/$id']!['kicked'] = ['viewer'];
    await expectLater(
        service().change(joined: true).write.wait(), throwsStateError);
    expect(db.documents['meets/$id']!['users'], ['organizer']);
    db.documents.remove('meets/$id');
    await expectLater(
        service().change(joined: true).write.wait(), throwsStateError);
  });
  test('Only the invited user can join a personal meeting', () async {
    db.documents['meets/$id']!['invitedUid'] = 'another-user';
    final request = service().change(joined: true);
    await expectLater(request.write.wait(), throwsStateError);
    expect(db.documents['meets/$id']!['users'], ['organizer']);
  });
  test('Changing UID during transaction read prevents every write', () async {
    final gate = Completer<DocumentSnapshot<Map<String, dynamic>>>();
    db.gets['meets/$id'] = gate.future;
    final r = service().change(joined: true);
    await Future<void>.delayed(Duration.zero);
    current = 'another';
    gate.complete(LayoutSnapshot(db, 'meets/$id', db.documents['meets/$id']));
    await expectLater(r.write.wait(), throwsStateError);
    expect(db.commits, 0);
  });
  test(
      'Durable committed receipt replays without rejoining or duplicate notice',
      () async {
    final folder = await Directory.systemTemp.createTemp('clrs-membership-');
    try {
      final store = _UnclearedJournal(directory: () async => folder);
      final first = service(store: store),
          r = service(store: store).change(joined: true);
      expect(await r.write.wait(), isTrue);
      first.acknowledge(r);
      db.documents['meets/$id']!['users'] = ['organizer'];
      final recovered = await service(store: store).restore();
      expect(await recovered!.write.wait(), isTrue);
      service(store: store).acknowledge(recovered);
      expect(db.documents['meets/$id']!['users'], ['organizer']);
      expect(
          db.documents.keys.where((e) => e.contains('/notifications/')).length,
          1);
    } finally {
      await folder.delete(recursive: true);
    }
  });
  test('Leaving preserves organizer and other members, no join notification',
      () async {
    db.documents['meets/$id']!['users'] = ['organizer', 'viewer', 'third'];
    final s = service(), r = service().change(joined: false);
    expect(await r.write.wait(), isTrue);
    s.acknowledge(r);
    expect(db.documents['meets/$id']!['users'], ['organizer', 'third']);
    expect(
        db.documents.keys.where((e) => e.contains('/notifications/')), isEmpty);
  });
  test('Archive failure keeps membership; retry copies messages before leaving',
      () async {
    final archiveDb = _ArchiveDb();
    archiveDb.documents.addAll({
      'meets/$id': {
        'users': ['organizer', 'viewer'],
        'admin': 'organizer'
      },
      'meets/$id/messages/first': {'message': 'Сохранить историю'}
    });
    archiveDb.commitError = StateError('archive denied');
    final membership = MeetingMembershipService(
        meetingId: id,
        firestore: archiveDb,
        journal: journal,
        currentUid: () => current);
    await expectLater(
        membership.change(joined: false).write.wait(), throwsStateError);
    expect(archiveDb.documents['meets/$id']!['users'], contains('viewer'));
    expect(archiveDb.documents['users/viewer/removed_meets/$id/messages/first'],
        isNull);
    archiveDb.commitError = null;
    final retry = membership.change(joined: false);
    expect(await retry.write.wait(), isTrue);
    membership.acknowledge(retry);
    expect(archiveDb.documents['meets/$id']!['users'], ['organizer']);
    expect(
        archiveDb.documents['users/viewer/removed_meets/$id/messages/first']![
            'message'],
        'Сохранить историю');
    await archiveDb.close();
  });
  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        theme: LrsTheme.theme,
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!),
        home: child));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets(
      'Individual compact page accepts once and survives pending dispose',
      (tester) async {
    db.commitGate = Completer<void>();
    final page = AboutIndividualMeet(
        snapshot: AsyncSnapshot.withData(
            ConnectionState.active,
            LayoutQuerySnapshot(
                [LayoutSnapshot(db, 'meets/$id', db.documents['meets/$id'])])),
        index: 0,
        doc: LayoutSnapshot(
            db, 'users/organizer', db.documents['users/organizer']),
        membershipService: service());
    await pump(tester, page);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
        find.text('Принять приглашение на встречу'), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Принять приглашение на встречу'));
    await tester.pumpAndSettle();
    expect(find.text('Принять приглашение на встречу').hitTestable(),
        findsOneWidget);
    await tester.tap(find.text('Принять приглашение на встречу'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 16));
    await tester.pump();
    await tester.scrollUntilVisible(find.text('Проверить результат'), 150,
        scrollable: find.byType(Scrollable).first);
    await tester.pump();
    expect(find.text('Проверить результат'), findsOneWidget);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    db.commitGate!.complete();
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(db.commits, 1);
    final restored = await service().restore();
    expect(await restored!.write.wait(), isTrue);
    service().acknowledge(restored);
  });
  testWidgets('Individual meeting keeps its participants link and left panel', (
    tester,
  ) async {
    final page = AboutIndividualMeet(
      snapshot: AsyncSnapshot.withData(
        ConnectionState.active,
        LayoutQuerySnapshot([
          LayoutSnapshot(db, 'meets/$id', db.documents['meets/$id']),
        ]),
      ),
      index: 0,
      doc: LayoutSnapshot(
        db,
        'users/organizer',
        db.documents['users/organizer'],
      ),
      membershipService: service(),
    );
    await pump(tester, page);
    await tester.pumpAndSettle();
    final link = find.byKey(
      const ValueKey('individual-meeting-participants-action'),
    );
    await tester.scrollUntilVisible(
      link,
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(link);
    await tester.pumpAndSettle();
    expect(link.hitTestable(), findsOneWidget);
    expect(tester.getRect(link).right, lessThan(250));
    await tester.tap(link);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('individual-meeting-participants')),
      findsOneWidget,
    );
    expect(find.text('Организатор'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Group join pending timeout checks original transaction',
      (tester) async {
    db.commitGate = Completer<void>();
    await pump(
        tester,
        ChatPage(
            submissions:
                ChatSubmissionService(journal: MemorySubmissionJournal()),
            groupId: id,
            groupName: 'Длинное название встречи',
            users: const ['organizer'],
            isUserJoin: false,
            membershipService: service()));
    db.emit('users/viewer/removed_meets/$id/messages', []);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Присоединиться'));
    await tester.pumpAndSettle();
    expect(find.text('Присоединиться').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Присоединиться'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 16));
    await tester.pump();
    expect(find.text('Проверить результат'), findsOneWidget);
    await tester.ensureVisible(find.text('Проверить результат'));
    await tester.pump();
    expect(find.text('Проверить результат').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Проверить результат'));
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    db.commitGate!.complete();
    await tester.pump();
    await tester.pump();
    expect(db.commits, 1);
    expect(tester.takeException(), isNull);
    final r = await service().restore();
    expect(await r!.write.wait(), isTrue);
    service().acknowledge(r);
  });
}
