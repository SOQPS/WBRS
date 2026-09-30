import 'dart:async';
import 'package:intl/date_symbol_data_local.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/presentation/screens/edit_meet/edit_meet.dart';
import 'package:wbrs/presentation/screens/notifications_center/notifications_page.dart';
import 'package:wbrs/service/meeting_write_service.dart';
import 'package:wbrs/service/session_service.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/shared/geo_catalog.dart';
import 'package:wbrs/shared/meeting_form.dart';
import 'support/layout_firebase_fakes.dart';
import 'support/safe_write_fakes.dart';
import 'support/memory_submission_journal.dart';

const meeting = <String, dynamic>{
  'name': 'Встреча в октябре',
  'description': 'Короткое описание',
  'city': 'Москва',
  'country': 'Россия',
  'countryCode': 'RU',
  'region': 'Москва',
  'datetime': '10.10.2027 10:10',
  'type': 'групповая',
  'admin': 'viewer',
  'users': ['viewer', 'guest'],
  'recentMessage': 'Сохранить это сообщение',
  'recentMessageSender': 'guest',
  'timeStamp': 123,
};

class WidgetFirebaseCoreMock extends MockFirebaseApp {
  @override
  Future<List<CoreInitializeResponse>> initializeCore() async {
    final apps = await super.initializeCore();
    for (final app in apps) {
      app.options.storageBucket = 'test-only-bucket';
    }
    return apps;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    TestFirebaseCoreHostApi.setUp(WidgetFirebaseCoreMock());
    await Firebase.initializeApp();
    await GeoCatalog.load();
    await initializeDateFormatting('ru');
  });
  late SafeWriteFirestore db;
  late MeetingWriteService service;
  late MemorySubmissionJournal journal;
  var userIndex = 0;
  setUp(() {
    db = SafeWriteFirestore();
    firebaseFirestore = db;
    firebaseAuth = LayoutAuth();
    firebaseMessaging = LayoutMessaging();
    final owner = 'form-owner-${userIndex++}';
    journal = MemorySubmissionJournal();
    service = MeetingWriteService(
        firestore: db, currentUid: () => owner, journal: journal);
  });
  tearDown(() async => db.close());

  Future<void> pumpScreen(
    WidgetTester tester,
    Widget screen, {
    Size size = const Size(390, 844),
    double scale = 1.3,
    double keyboard = 0,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        theme: LrsTheme.theme,
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                viewInsets: EdgeInsets.only(bottom: keyboard)),
            child: child!),
        home: screen));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('Edit exposes both date/time pickers and retains the saved date',
      (tester) async {
    await pumpScreen(
        tester,
        EditMeet(
            meet: SafeSnapshot(db, 'meets/example', Map.from(meeting)),
            service: service));
    expect(find.text('Выбрать дату'), findsOneWidget);
    expect(find.text('Выбрать время'), findsOneWidget);
    expect(
        find.textContaining(ClrsLocalizations(const Locale('ru'), const {})
            .dateTime(DateTime(2027, 10, 10, 10, 10))),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final size in [
    const Size(320, 640),
    const Size(390, 844),
    const Size(844, 390)
  ]) {
    for (final scale in [1.3, 2.0]) {
      testWidgets(
          'Meeting form scrolls to save at ${size.width}x${size.height} scale $scale',
          (tester) async {
        await pumpScreen(
            tester, MeetingForm(service: service, initialData: meeting),
            size: size, scale: scale);
        await tester.ensureVisible(find.text('Сохранить'));
        await tester.pumpAndSettle();
        expect(find.text('Сохранить').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('Meeting save remains reachable with keyboard and 2x text',
      (tester) async {
    await pumpScreen(
        tester, MeetingForm(service: service, initialData: meeting),
        size: const Size(320, 640), scale: 2, keyboard: 280);
    await tester.ensureVisible(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(find.text('Сохранить').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Saving a title does not replace stored datetime, members or chat metadata',
      (tester) async {
    db.documents['meets/example'] = Map.from(meeting);
    final ownerService = MeetingWriteService(
        firestore: db, currentUid: () => 'viewer', journal: journal);
    var saved = 0;
    await pumpScreen(
        tester,
        MeetingForm(
            meetingId: 'example',
            initialData: meeting,
            service: ownerService,
            onSaved: () => saved++));
    await tester.enterText(find.byType(TextField).first, 'Новое название');
    await tester.ensureVisible(find.text('Сохранить'));
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(saved, 1);
    expect(db.documents['meets/example']!['datetime'], meeting['datetime']);
    for (final key in [
      'users',
      'admin',
      'type',
      'recentMessage',
      'recentMessageSender',
      'timeStamp'
    ]) {
      expect(db.documents['meets/example']![key], meeting[key], reason: key);
    }
  });

  testWidgets(
      'Create timeout, repeat and leaving the page retain one operation',
      (tester) async {
    db.gate = Completer<void>();
    await pumpScreen(
        tester, MeetingForm(service: service, initialData: meeting));
    await tester.ensureVisible(find.text('Сохранить'));
    await tester.tap(find.text('Сохранить'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 16));
    expect(
        find.textContaining('Подтверждение ещё не получено'), findsOneWidget);
    await tester.ensureVisible(find.text('Проверить результат'));
    await tester.tap(find.text('Проверить результат'));
    await tester.pump();
    expect(db.writes.length, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    db.gate!.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    var saved = 0;
    await pumpScreen(
        tester, MeetingForm(service: service, onSaved: () => saved++));
    await tester.ensureVisible(find.text('Проверить результат'));
    await tester.tap(find.text('Проверить результат'));
    await tester.pumpAndSettle();
    expect(saved, 1);
    expect(db.writes.length, 1);
    expect(db.documents.length, 1);
  });

  void seedNotifications() {
    for (var i = 0; i < 100; i++) {
      db.documents['users/viewer/notifications/$i'] = {
        'title': 'Уведомление $i',
        'body': 'Длинный текст уведомления для проверки переноса',
        'type': 'meeting',
        'read': false,
      };
    }
  }

  testWidgets('Read all uses one batch for a page of 100 notifications',
      (tester) async {
    seedNotifications();
    await pumpScreen(tester, const NotificationsPage());
    db.emit('users/viewer/notifications');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Прочитать все'));
    await tester.pumpAndSettle();
    expect(db.batches.length, 1);
    expect(db.batches.single.length, 100);
    expect(db.documents.values.every((doc) => doc['read'] == true), isTrue);
  });

  testWidgets('Old account notifications disappear immediately on logout',
      (tester) async {
    seedNotifications();
    SessionService.readyUserId.value = 'viewer';
    addTearDown(() => SessionService.readyUserId.value = null);
    await pumpScreen(tester, const NotificationsPage());
    db.emit('users/viewer/notifications');
    await tester.pumpAndSettle();
    expect(find.text('Прочитать все'), findsOneWidget);

    (firebaseAuth as LayoutAuth).user = null;
    SessionService.readyUserId.value = null;
    await tester.pump();
    expect(find.text('Сеанс завершён. Войдите снова'), findsOneWidget);
    expect(find.text('Прочитать все'), findsNothing);
  });

  testWidgets(
      'Read-all timeout is one deadline and retry does not enqueue another batch',
      (tester) async {
    seedNotifications();
    db.gate = Completer<void>();
    await pumpScreen(tester, const NotificationsPage());
    db.emit('users/viewer/notifications');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Прочитать все'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 11));
    final check = find.text('Проверить результат');
    await tester.drag(find.byType(ListView).first, const Offset(0, -180));
    await tester.pumpAndSettle();
    await tester.ensureVisible(check);
    await tester.pumpAndSettle();
    expect(check.hitTestable(), findsOneWidget);
    await tester.tap(check);
    await tester.pump();
    expect(find.text('Сохранение…'), findsOneWidget);
    expect(db.batches.length, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    db.gate!.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Notifications remain scrollable in landscape with 2x text',
      (tester) async {
    seedNotifications();
    await pumpScreen(tester, const NotificationsPage(),
        size: const Size(640, 320), scale: 2);
    db.emit('users/viewer/notifications');
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Прочитать все'), 150,
        scrollable: find.byType(Scrollable).first);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Last notification filter fits a 320 dp Android viewport',
      (tester) async {
    seedNotifications();
    await pumpScreen(tester, const NotificationsPage(),
        size: const Size(320, 640));
    db.emit('users/viewer/notifications');
    await tester.pumpAndSettle();
    final last = find.widgetWithText(ChoiceChip, 'Встречи');
    expect(last, findsOneWidget);
    expect(tester.getTopLeft(last).dx, greaterThanOrEqualTo(16));
    expect(tester.getBottomRight(last).dx, lessThanOrEqualTo(304));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Selected notification filter stays transparent and distinct',
      (tester) async {
    await pumpScreen(tester, const NotificationsPage(),
        size: const Size(320, 640));
    db.emit('users/viewer/notifications');
    await tester.pumpAndSettle();
    final all = find.widgetWithText(ChoiceChip, 'Все');
    final meetings = find.widgetWithText(ChoiceChip, 'Встречи');
    final before = tester.widget<ChoiceChip>(all);
    expect(before.selected, isTrue);
    expect(before.labelStyle!.color, LrsTheme.peachLight);
    expect(before.side!.color, LrsTheme.peachLight);
    expect(before.selectedColor!.alpha, lessThan(255));
    await tester.tap(meetings);
    await tester.pumpAndSettle();
    final selected = tester.widget<ChoiceChip>(meetings);
    expect(selected.selected, isTrue);
    expect(selected.labelStyle!.color, LrsTheme.peachLight);
    expect(selected.side!.color, LrsTheme.peachLight);
    expect(tester.widget<ChoiceChip>(all).selected, isFalse);
    expect(tester.getBottomRight(meetings).dx, lessThanOrEqualTo(304));
    expect(tester.takeException(), isNull);
  });

  test('Meeting datetime pads October, hour ten and minute ten correctly', () {
    expect(formatMeetingDateTime(DateTime(2027, 10, 10, 10, 10)),
        '10.10.2027 10:10');
    expect(parseMeetingDateTime('10.10.2027 10:10'),
        DateTime(2027, 10, 10, 10, 10));
    expect(parseMeetingDateTime('31.02.2027 10:10'), isNull);
    expect(parseMeetingDateTime('legacy value'), isNull);
  });
}
