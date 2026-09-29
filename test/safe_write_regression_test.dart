import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/service/meeting_write_service.dart';
import 'package:wbrs/service/pending_write.dart';
import 'package:wbrs/service/social_service.dart';
import 'support/safe_write_fakes.dart';
import 'support/memory_submission_journal.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const deadline = Duration(milliseconds: 1);
  var userCounter = 0;
  late String? uid;
  late SafeWriteFirestore db;
  late MeetingWriteService meetings;
  late MemorySubmissionJournal journal;
  late SocialService social;
  setUp(() {
    uid = 'owner-${userCounter++}';
    db = SafeWriteFirestore();
    journal = MemorySubmissionJournal();
    meetings = MeetingWriteService(
        firestore: db, currentUid: () => uid, journal: journal);
    social = SocialService(
        firestore: db, storage: SafeWriteStorage(), currentUid: () => uid);
  });
  tearDown(() async => db.close());

  test('A timed out write is awaited again without invoking the writer twice',
      () async {
    var calls = 0;
    final gate = Completer<void>();
    final write = PendingWrite(() {
      calls++;
      return gate.future;
    });
    expect(await write.wait(timeout: deadline), isFalse);
    expect(await write.wait(timeout: deadline), isFalse);
    expect(write.completed, isFalse);
    expect(calls, 1);
    gate.complete();
    expect(await write.wait(), isTrue);
    expect(write.completed, isTrue);
    expect(calls, 1);
  });

  test('Late write rejection remains observable after a UI timeout', () async {
    final gate = Completer<void>();
    final write = PendingWrite(() => gate.future);
    expect(await write.wait(timeout: deadline), isFalse);
    gate.completeError(StateError('permission-denied'));
    await Future<void>.delayed(Duration.zero);
    expect(write.failed, isTrue);
    await expectLater(write.wait(), throwsStateError);
  });

  test(
      'Create restores the exact pending document and payload on route re-entry',
      () async {
    db.gate = Completer<void>();
    final request = await meetings
        .create({'name': 'Первый вариант', 'datetime': '10.10.2027 10:10'});
    expect(await request.write.wait(timeout: deadline), isFalse);
    final reopened = MeetingWriteService(
        firestore: db, currentUid: () => uid, journal: journal);
    expect(reopened.pendingCreate, same(request));
    expect(await reopened.create({'name': 'Случайный повтор'}), same(request));
    expect(db.writes, ['meets/${request.id}']);
    db.gate!.complete();
    await request.write.wait();
    expect(db.documents['meets/${request.id}']!['name'], 'Первый вариант');
    expect(db.documents.length, 1);
    await reopened.acknowledge(request, creating: true);
    expect(reopened.pendingCreate, isNull);
  });

  test('Known rejected create retries with the same document ID', () async {
    db.error = StateError('permission-denied');
    final first = await meetings.create({'name': 'Отказ'});
    await expectLater(first.write.wait(), throwsStateError);
    db.error = null;
    final second = await meetings.create({'name': 'Исправлено'});
    expect(second.id, first.id);
    await second.write.wait();
    expect(db.documents.length, 1);
    expect(db.documents['meets/${second.id}']!['name'], 'Исправлено');
    await meetings.acknowledge(second, creating: true);
  });

  test(
      'Editing only changes form fields and preserves membership and chat state',
      () async {
    final original = <String, dynamic>{
      'name': 'До',
      'admin': uid,
      'users': [uid, 'guest'],
      'type': 'индивидуальная',
      'recentMessage': 'Привет',
      'recentMessageSender': 'guest',
      'timeStamp': DateTime(2026, 1, 1)
    };
    db.documents['meets/existing'] = Map.from(original);
    final edit = await meetings.edit('existing', uid!, {
      'name': 'После',
      'datetime': '10.10.2027 10:10',
      'admin': 'bad',
      'users': [],
      'type': 'групповая',
      'recentMessage': '',
      'timeStamp': DateTime.now()
    });
    await edit.write.wait();
    for (final key in [
      'admin',
      'users',
      'type',
      'recentMessage',
      'recentMessageSender',
      'timeStamp'
    ]) {
      expect(db.documents['meets/existing']![key], original[key], reason: key);
    }
    expect(db.documents['meets/existing']!['name'], 'После');
    await meetings.acknowledge(edit, creating: false);
  });

  test('Pending edit cannot be replaced by another edit or deletion', () async {
    db.documents['meets/existing'] = {'name': 'До', 'admin': uid};
    db.gate = Completer<void>();
    final first = await meetings.edit('existing', uid!, {'name': 'После'});
    expect(await first.write.wait(timeout: deadline), isFalse);
    expect(
        await meetings.edit('existing', uid!, {'name': 'Повтор'}), same(first));
    expect(await meetings.delete('existing', uid!), same(first));
    expect(db.writes, ['meets/existing']);
    db.gate!.complete();
    await first.write.wait();
    await meetings.acknowledge(first, creating: false);
  });

  test('Delete is awaited and retained until the server confirms it', () async {
    db.documents['meets/existing'] = {'name': 'До', 'admin': uid};
    db.gate = Completer<void>();
    final request = await meetings.delete('existing', uid!);
    expect(request.deleting, isTrue);
    expect(await request.write.wait(timeout: deadline), isFalse);
    expect(db.documents.containsKey('meets/existing'), isTrue);
    expect(meetings.pendingEdit('existing'), same(request));
    db.gate!.complete();
    await request.write.wait();
    expect(db.documents.containsKey('meets/existing'), isFalse);
    await meetings.acknowledge(request, creating: false);
  });

  test('Signed-out or changed accounts cannot start or acknowledge writes',
      () async {
    final owner = uid;
    uid = null;
    expect(() => meetings.create({'name': 'Запрещено'}), throwsStateError);
    uid = owner;
    final request = await meetings.create({'name': 'Разрешено'});
    await request.write.wait();
    uid = 'different';
    expect(
        () => meetings.acknowledge(request, creating: true), throwsStateError);
    expect(meetings.isCurrentSession, isFalse);
    expect(() => meetings.edit('existing', owner!, {}), throwsStateError);
    expect(db.writes.length, 1);
    uid = owner;
    await meetings.acknowledge(request, creating: true);
  });

  test('A non-organizer cannot edit or delete a meeting', () {
    expect(() => meetings.edit('existing', 'someone-else', {'name': 'x'}),
        throwsStateError);
    expect(() => meetings.delete('existing', 'someone-else'), throwsStateError);
    expect(db.writes, isEmpty);
  });

  void seedNotifications(int count) {
    for (var i = 0; i < count; i++) {
      db.documents['users/$uid/notifications/$i'] = {'read': false};
    }
  }

  test('Read all sends exactly one atomic batch for 100 notifications',
      () async {
    seedNotifications(100);
    await social.markNotificationsRead(List.generate(100, (i) => '$i'));
    expect(db.batches.length, 1);
    expect(db.batches.single.length, 100);
    expect(db.documents.values.every((data) => data['read'] == true), isTrue);
  });

  test(
      'Duplicate notifications are deduplicated and oversized requests rejected',
      () async {
    seedNotifications(1);
    await social.markNotificationsRead(['0', '0']);
    expect(db.batches.single.length, 1);
    await expectLater(
        social.markNotificationsRead(List.generate(101, (i) => '$i')),
        throwsArgumentError);
    await expectLater(
        social.markNotificationsRead(['../other']), throwsArgumentError);
    expect(db.batches.length, 1);
  });

  test('A rejected batch leaves no partially read notifications', () async {
    seedNotifications(2);
    await expectLater(
        social.markNotificationsRead(['0', 'missing', '1']), throwsStateError);
    expect(db.documents.values.every((data) => data['read'] == false), isTrue);
  });

  test('Offline read-all has one deadline and retries await the same batch',
      () async {
    seedNotifications(100);
    db.gate = Completer<void>();
    final pending = PendingWrite(
        () => social.markNotificationsRead(List.generate(100, (i) => '$i')));
    expect(await pending.wait(timeout: deadline), isFalse);
    expect(await pending.wait(timeout: deadline), isFalse);
    expect(db.batches.length, 1);
    db.gate!.complete();
    expect(await pending.wait(), isTrue);
  });

  test('Account switch never retargets notification writes to a new user',
      () async {
    seedNotifications(2);
    final owner = uid;
    db.gate = Completer<void>();
    final pending = social.markNotificationsRead(['0', '1']);
    uid = 'another-account';
    expect(social.isCurrentSession, isFalse);
    await expectLater(social.markNotificationRead('0'), throwsStateError);
    expect(db.batches.length, 1);
    expect(db.batches.single.every((path) => path.startsWith('users/$owner/')),
        isTrue);
    db.gate!.complete();
    await pending;
  });
}
