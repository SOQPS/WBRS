import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:wbrs/service/meeting_write_service.dart';
import 'package:wbrs/service/submission_journal.dart';
import 'package:wbrs/shared/geo_catalog.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/shared/meeting_form.dart';
import 'support/safe_write_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await GeoCatalog.load();
    await initializeDateFormatting('ru');
  });
  late Directory root;
  late SubmissionJournal journal;
  late SafeWriteFirestore db;
  String? uid;
  var sequence = 0;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('clrs-meeting-journal-');
    journal = SubmissionJournal(directory: () async => root);
    db = SafeWriteFirestore();
    uid = 'owner-${sequence++}';
  });
  tearDown(() async {
    await db.close();
    if (await root.exists()) await root.delete(recursive: true);
  });
  MeetingWriteService newProcess() => MeetingWriteService(
      firestore: db,
      currentUid: () => uid,
      journal: SubmissionJournal(directory: () async => root),
      registry: MeetingWriteRegistry());
  const fields = {
    'name': 'Сохранённое название',
    'description': 'Исходное описание',
    'countryCode': 'RU',
    'country': 'Россия',
    'city': 'Москва',
    'region': 'Москва',
    'datetime': '10.10.2027 10:10',
    'type': 'групповая'
  };
  Map<String, dynamic> createData() => {
        ...fields,
        'admin': uid,
        'users': [uid],
        'timeStamp': DateTime(2026, 9, 22).toIso8601String(),
        'recentMessage': '',
        'recentMessageSender': ''
      };

  test(
      'Process restart before first server write restores the durable ID and exact creation payload',
      () async {
    final record = await journal.prepare(
        uid!,
        'meeting-create',
        {
          'operation': 'create',
          'meetingId': 'persisted-id',
          'data': createData()
        },
        null);
    final service = newProcess();
    final request = (await service.restore())!;
    expect(request.id, 'persisted-id');
    expect(request.requestId, record['id']);
    await request.write.wait();
    expect(db.documents.keys, ['meets/persisted-id']);
    expect(db.documents['meets/persisted-id']!['name'], fields['name']);
    expect(db.documents['meets/persisted-id']!['admin'], uid);
    await service.acknowledge(request, creating: true);
    expect(await journal.load(uid!, 'meeting-create'), isNull);
  });

  test('Personal invitation is sent once and only to an existing recipient',
      () async {
    db.documents['users/guest'] = {'fullName': 'Гость', 'status': 'active'};
    final service = newProcess();
    final request = await service.create({
      ...fields,
      'type': 'индивидуальная',
      'invitedUid': 'guest',
      'invitedName': 'Гость',
    });
    expect(await request.write.wait(), isTrue);
    expect(db.documents['meets/${request.id}']!['invitedUid'], 'guest');
    expect(
        db.documents['users/guest/notifications/meeting_invite_${request.id}']![
            'kind'],
        'invitation');
    final before = db.writes.length;
    final restored = (await newProcess().restore())!;
    expect(await restored.write.wait(), isTrue);
    expect(db.writes.length, before);
  });

  test('Personal invitation cannot target self or missing user', () async {
    final service = newProcess();
    await expectLater(
        service
            .create({...fields, 'type': 'индивидуальная', 'invitedUid': uid}),
        throwsStateError);
    final request = await service.create({
      ...fields,
      'type': 'индивидуальная',
      'invitedUid': 'missing',
    });
    await expectLater(request.write.wait(), throwsStateError);
    expect(db.documents.keys.where((key) => key.startsWith('meets/')), isEmpty);
  });

  test(
      'Process restart after create commit never resets newer participants or chat messages',
      () async {
    final first = await newProcess().create(fields);
    await first.write.wait();
    db.documents['meets/${first.id}']!.addAll({
      'users': [uid, 'guest'],
      'recentMessage': 'Новое сообщение',
      'recentMessageSender': 'guest'
    });
    final before =
        Map<String, dynamic>.from(db.documents['meets/${first.id}']!);
    final service = newProcess();
    final restored = (await service.restore())!;
    await restored.write.wait();
    expect(restored.id, first.id);
    expect(restored.requestId, first.requestId);
    expect(db.documents['meets/${first.id}'], before);
    expect(db.writes.length, 1);
    await service.acknowledge(restored, creating: true);
  });

  test(
      'Edit receipt makes recovery a no-op after a later edit on another device',
      () async {
    db.documents['meets/existing'] = {
      'admin': uid,
      'name': 'До',
      'users': [uid, 'guest'],
      'recentMessage': 'Сообщение',
      'type': 'индивидуальная'
    };
    final first = await newProcess()
        .edit('existing', uid!, {'name': 'Первое редактирование', 'users': []});
    await first.write.wait();
    db.documents['meets/existing']!['name'] = 'Позднее редактирование';
    final service = newProcess();
    final restored = (await service.restore(meetingId: 'existing'))!;
    await restored.write.wait();
    expect(db.documents['meets/existing']!['name'], 'Позднее редактирование');
    expect(db.documents['meets/existing']!['users'], [uid, 'guest']);
    expect(db.documents['meets/existing']!['type'], 'индивидуальная');
    expect(db.writes.length, 1);
    await service.acknowledge(restored, creating: false);
  });

  test(
      'Delete recovery confirms an absent document without recreating or deleting anything else',
      () async {
    db.documents['meets/existing'] = {'admin': uid, 'name': 'Удалить'};
    db.documents['meets/other'] = {'admin': uid, 'name': 'Сохранить'};
    final first = await newProcess().delete('existing', uid!);
    await first.write.wait();
    final service = newProcess();
    final restored = (await service.restore(meetingId: 'existing'))!;
    expect(restored.deleting, isTrue);
    await restored.write.wait();
    expect(db.documents.keys, ['meets/other']);
    expect(db.writes.length, 1);
    await service.acknowledge(restored, creating: false);
  });

  test('Concurrent preparation produces one identity and one server mutation',
      () async {
    final service = newProcess();
    final requests = await Future.wait([
      service.create(fields),
      service.create({...fields, 'name': 'Повтор'})
    ]);
    expect(requests[0], same(requests[1]));
    await requests.first.write.wait();
    expect(db.writes.length, 1);
    expect(db.documents.length, 1);
    expect(db.documents.values.single['name'], fields['name']);
    await service.acknowledge(requests.first, creating: true);
  });

  test(
      'Denied transaction retains an intact disk intent and recovers with the same document ID',
      () async {
    db.error =
        FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied');
    final first = await newProcess().create(fields);
    await expectLater(first.write.wait(), throwsA(isA<FirebaseException>()));
    expect(db.documents, isEmpty);
    expect(await journal.load(uid!, 'meeting-create'), isNotNull);
    db.error = null;
    final service = newProcess();
    final restored = (await service.restore())!;
    expect(restored.id, first.id);
    expect(restored.requestId, first.requestId);
    await restored.write.wait();
    expect(db.documents.length, 1);
    await service.acknowledge(restored, creating: true);
  });

  test(
      'Server organizer is checked even when the client supplied the current UID',
      () async {
    db.documents['meets/other'] = {
      'admin': 'someone-else',
      'name': 'Чужая встреча',
      'users': ['someone-else']
    };
    final service = newProcess();
    final request = await service.edit('other', uid!, {'name': 'Нельзя'});
    await expectLater(request.write.wait(), throwsStateError);
    expect(db.documents['meets/other']!['name'], 'Чужая встреча');
    expect(db.writes, isEmpty);
  });

  test(
      'Changing UID while the disk intent is loading prevents any server mutation',
      () async {
    final service = newProcess();
    final pending = service.create(fields);
    uid = 'another-user';
    await expectLater(pending, throwsStateError);
    expect(db.writes, isEmpty);
    expect(db.documents, isEmpty);
  });

  test(
      'A corrupt pending journal blocks a new create instead of silently risking duplication',
      () async {
    await journal.prepare(
        uid!,
        'meeting-create',
        {
          'operation': 'create',
          'meetingId': 'persisted-id',
          'data': createData()
        },
        null);
    final file = await root
        .list(recursive: true)
        .where((entry) => entry.path.endsWith('request.json'))
        .first;
    await File(file.path).writeAsString('{incomplete');
    await expectLater(newProcess().create(fields), throwsFormatException);
    expect(db.writes, isEmpty);
  });

  testWidgets(
      'A fresh form restores disk fields and acknowledges the committed create instead of making another one',
      (tester) async {
    final first = (await tester.runAsync(() async {
      final request = await newProcess().create(fields);
      await request.write.wait();
      return request;
    }))!;
    var saved = 0;
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
          theme: LrsTheme.theme,
          home: MeetingForm(service: newProcess(), onSaved: () => saved++)));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        fields['name']);
    expect(find.text('Проверить результат'), findsOneWidget);
    expect(db.writes.length, 1);
    await tester.ensureVisible(find.text('Проверить результат'));
    await tester.runAsync(() async {
      await tester.tap(find.text('Проверить результат'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(saved, 1);
    expect(db.documents.keys, ['meets/${first.id}']);
    expect(await tester.runAsync(() => journal.load(uid!, 'meeting-create')),
        isNull);
    expect(tester.takeException(), isNull);
  });
}
