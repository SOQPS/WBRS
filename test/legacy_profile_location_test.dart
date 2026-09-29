import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/presentation/screens/edit_profile/profile_edit_page.dart';
import 'package:wbrs/service/database_service.dart';
import 'package:wbrs/service/session_service.dart';
import 'package:wbrs/shared/geo_catalog.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/shared/meeting_location_fields.dart';

import 'support/layout_firebase_fakes.dart';

class _OwnerUser extends LayoutUser {
  _OwnerUser([this.owner = 'viewer']);
  final String owner;
  int metadataUpdates = 0;
  @override
  String get uid => owner;
  @override
  String get email => 'legacy@example.invalid';
  @override
  Future<void> updateDisplayName(String? displayName) async =>
      metadataUpdates++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LayoutFirestore db;
  late LayoutAuth auth;
  late _OwnerUser user;
  late GeoCountry country;
  late Map<String, dynamic> legacy;

  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
    country = GeoCatalog.byCode(await GeoCatalog.load(), 'RU')!;
  });
  setUp(() {
    db = LayoutFirestore();
    auth = LayoutAuth();
    user = _OwnerUser();
    auth.user = user;
    SessionService.readyUserId.value = user.uid;
    firebaseFirestore = db;
    firebaseAuth = auth;
    firebaseMessaging = LayoutMessaging();
    legacy = {
      'uid': user.uid,
      'status': 'active',
      'fullName': 'Старый профиль',
      'age': 35,
      'pol': 'мужской',
      'rost': '',
      'about': 'Вера и семья',
      'hobbi': 'Прогулки',
      'city': 'Неизвестный исторический город',
      'deti': false,
      'группа': 'красно-белая',
      'balance': 27,
      'gifts': {'original': 1},
      'role': 'author',
      'isRegistrationEnd': true,
      'profilePic': '',
    };
    db.documents['users/viewer'] = legacy;
    db.documents['users/other'] = {'uid': 'other', 'country': 'untouched'};
  });
  tearDown(() async => db.close());

  ProfilePageEdit editor() => ProfilePageEdit(
      email: user.email,
      userName: legacy['fullName'],
      about: legacy['about'],
      age: '35',
      deti: false,
      rost: legacy['rost'],
      city: legacy['city'],
      hobbi: legacy['hobbi']);

  Future<void> page(WidgetTester tester,
      {Size size = const Size(390, 844), double scale = 1}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        theme: LrsTheme.theme,
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!),
        home: editor()));
    await tester.pumpAndSettle();
  }

  Finder locationFields() => find.descendant(
      of: find.byType(MeetingLocationFields),
      matching: find.byType(DropdownButtonFormField<String>));

  Future<void> chooseLocation(WidgetTester tester) async {
    tester
        .widget<DropdownButtonFormField<String>>(locationFields().first)
        .onChanged!(country.code);
    await tester.pump();
    tester
        .widget<DropdownButtonFormField<String>>(locationFields().last)
        .onChanged!(country.regions.first);
    await tester.pump();
  }

  Future<void> saveLocation(WidgetTester tester) async {
    final action = find.byKey(const ValueKey('profile-location-save'));
    await tester.ensureVisible(action);
    await tester.tap(action);
    await tester.pump();
  }

  test('owner location update writes only the selected catalog fields',
      () async {
    final before = Map<String, dynamic>.from(legacy);
    await DatabaseService(uid: user.uid)
        .updateUserLocation(country: country, region: country.regions.first);
    expect(db.transactions, 1);
    expect(db.documents['users/viewer'], {
      ...before,
      'country': country.name,
      'countryCode': country.code,
      'languageGroup': country.languageGroup,
      'countrySegment': country.segment,
      'region': country.regions.first,
      'city': country.regions.first,
    });
    expect(
        db.documents['users/other'], {'uid': 'other', 'country': 'untouched'});
    expect(user.metadataUpdates, 0);
  });

  test('free-form city is never accepted as a selected region', () async {
    await expectLater(
        DatabaseService(uid: user.uid)
            .updateUserLocation(country: country, region: legacy['city']),
        throwsArgumentError);
    expect(db.transactions, 0);
    expect(legacy.containsKey('countryCode'), isFalse);
  });

  test('boolean deleted marker also prevents a location update', () async {
    legacy['deleted'] = true;
    await expectLater(
        DatabaseService(uid: user.uid).updateUserLocation(
            country: country, region: country.regions.first),
        throwsStateError);
    expect(db.updates, 0);
    expect(db.commits, 0);
  });

  for (final region in ['', 'Region absent from catalog']) {
    test('empty or absent catalog region "$region" never writes', () async {
      await expectLater(
          DatabaseService(uid: user.uid)
              .updateUserLocation(country: country, region: region),
          throwsArgumentError);
      expect(db.transactions, 0);
      expect(db.updates, 0);
    });
  }

  test('unknown country code never writes', () async {
    final unknown = GeoCountry(
        code: 'UNKNOWN',
        name: 'Unknown',
        englishName: 'Unknown',
        regionLabel: 'Region',
        regions: ['Unknown'],
        languageGroup: 'ru',
        segment: '');
    await expectLater(
        DatabaseService(uid: user.uid)
            .updateUserLocation(country: unknown, region: 'Unknown'),
        throwsArgumentError);
    expect(db.transactions, 0);
    expect(db.updates, 0);
  });

  test('country metadata comes from the catalog, never a supplied object',
      () async {
    final forged = GeoCountry(
        code: country.code,
        name: 'wrong',
        englishName: 'wrong',
        regionLabel: 'wrong',
        regions: ['invented'],
        languageGroup: 'wrong',
        segment: 'wrong');
    await DatabaseService(uid: user.uid)
        .updateUserLocation(country: forged, region: country.regions.first);
    expect(legacy['country'], country.name);
    expect(legacy['languageGroup'], country.languageGroup);
    expect(legacy['countrySegment'], country.segment);
  });

  test('another owner and a logged-out session cannot start a location write',
      () async {
    await expectLater(
        DatabaseService(uid: 'other').updateUserLocation(
            country: country, region: country.regions.first),
        throwsStateError);
    auth.user = null;
    await expectLater(
        DatabaseService(uid: user.uid).updateUserLocation(
            country: country, region: country.regions.first),
        throwsStateError);
    expect(db.transactions, 0);
    expect(db.updates, 0);
  });

  for (final status in ['blocked', 'deleted', 'missing', 'wrong_uid']) {
    test('location update refuses $status profile', () async {
      if (status == 'missing') {
        db.documents.remove('users/viewer');
      } else if (status == 'wrong_uid') {
        legacy['uid'] = 'other';
      } else {
        legacy['status'] = status;
      }
      await expectLater(
          DatabaseService(uid: user.uid).updateUserLocation(
              country: country, region: country.regions.first),
          throwsStateError);
      expect(db.updates, 0);
      expect(db.commits, 0);
    });
  }

  test('session switch while reading the profile prevents both account writes',
      () async {
    final gate = Completer<DocumentSnapshot<Map<String, dynamic>>>();
    db.gets['users/viewer'] = gate.future;
    final request = DatabaseService(uid: user.uid)
        .updateUserLocation(country: country, region: country.regions.first);
    await Future<void>.delayed(Duration.zero);
    auth.user = _OwnerUser('other');
    gate.complete(LayoutSnapshot(db, 'users/viewer', legacy));
    await expectLater(request, throwsStateError);
    expect(db.updates, 0);
    expect(legacy.containsKey('countryCode'), isFalse);
    expect(db.documents['users/other']!['country'], 'untouched');
  });

  test('failed location commit preserves the profile and can be retried',
      () async {
    db.commitError = StateError('offline');
    await expectLater(
        DatabaseService(uid: user.uid).updateUserLocation(
            country: country, region: country.regions.first),
        throwsStateError);
    expect(legacy.containsKey('countryCode'), isFalse);
    db.commitError = null;
    await DatabaseService(uid: user.uid)
        .updateUserLocation(country: country, region: country.regions.first);
    expect(legacy['countryCode'], country.code);
  });

  for (final intermediate in [null, 'other']) {
    test('ready session ABA through $intermediate cannot commit old selection',
        () async {
      final gate = Completer<DocumentSnapshot<Map<String, dynamic>>>();
      db.gets['users/viewer'] = gate.future;
      final request = DatabaseService(uid: user.uid)
          .updateUserLocation(country: country, region: country.regions.first);
      await Future<void>.delayed(Duration.zero);
      SessionService.readyUserId.value = intermediate;
      SessionService.readyUserId.value = user.uid;
      gate.complete(LayoutSnapshot(db, 'users/viewer', legacy));
      await expectLater(request, throwsStateError);
      expect(db.updates, 0);
      expect(legacy.containsKey('countryCode'), isFalse);
    });
  }

  testWidgets('legacy opening and country selection never backfill data',
      (tester) async {
    final before = Map<String, dynamic>.from(legacy);
    await page(tester);
    final fields = tester
        .widgetList<DropdownButtonFormField<String>>(locationFields())
        .toList();
    expect(fields.first.initialValue, isNull);
    expect(fields.last.initialValue, isNull);
    expect(fields.last.onChanged, isNull);
    await chooseLocation(tester);
    expect(legacy, before);
    expect(db.transactions, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('legacy saves only location despite short historical text',
      (tester) async {
    await page(tester);
    await tester.enterText(find.byType(TextFormField).first, 'Не сохранено');
    await chooseLocation(tester);
    await saveLocation(tester);
    await tester.pumpAndSettle();
    expect(legacy['countryCode'], country.code);
    expect(legacy['region'], country.regions.first);
    expect(legacy['fullName'], 'Старый профиль');
    expect(legacy['about'], 'Вера и семья');
    expect(legacy['hobbi'], 'Прогулки');
    expect(legacy['balance'], 27);
    expect(user.metadataUpdates, 0);
    expect(find.byType(ProfilePageEdit), findsOneWidget,
        reason: 'saving geo must not discard the open full questionnaire');
    expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField).first)
            .controller!
            .text,
        'Не сохранено');
    expect(find.byKey(const ValueKey('profile-location-save')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('geo pending check observes one transaction without double save',
      (tester) async {
    db.commitGate = Completer<void>();
    await page(tester);
    await chooseLocation(tester);
    await saveLocation(tester);
    await tester.pump(const Duration(seconds: 16));
    expect(db.transactions, 1);
    expect(legacy.containsKey('countryCode'), isFalse);
    expect(
        tester
            .widget<TextButton>(
                find.byKey(const ValueKey('profile-location-save')))
            .onPressed,
        isNull);
    final check = find.widgetWithText(ElevatedButton, 'Проверить результат');
    await tester.scrollUntilVisible(check, 220,
        scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(check);
    await tester.tap(check);
    await tester.pump();
    expect(db.transactions, 1);
    db.commitGate!.complete();
    await tester.pumpAndSettle();
    expect(legacy['countryCode'], country.code);
    expect(db.transactions, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('account switch during geo read never shows success or writes',
      (tester) async {
    await page(tester);
    await chooseLocation(tester);
    final gate = Completer<DocumentSnapshot<Map<String, dynamic>>>();
    db.gets['users/viewer'] = gate.future;
    await saveLocation(tester);
    auth.user = _OwnerUser('other');
    gate.complete(LayoutSnapshot(db, 'users/viewer', legacy));
    await tester.pumpAndSettle();
    expect(db.updates, 0);
    expect(find.text('Профиль сохранён'), findsNothing);
    expect(db.documents['users/other']!['country'], 'untouched');
    expect(tester.takeException(), isNull);
  });

  testWidgets('geo action stays reachable on 320dp with enlarged text',
      (tester) async {
    await page(tester, size: const Size(320, 640), scale: 2);
    final action = find.byKey(const ValueKey('profile-location-save'));
    await tester.scrollUntilVisible(action, 220,
        scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(action);
    await tester.pumpAndSettle();
    expect(action.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('editor stays invalid after logout and same UID login',
      (tester) async {
    await page(tester);
    await chooseLocation(tester);
    SessionService.readyUserId.value = null;
    SessionService.readyUserId.value = user.uid;
    await tester.pumpAndSettle();
    expect(find.byType(MeetingLocationFields), findsNothing);
    expect(find.text('Не удалось загрузить профиль.'), findsOneWidget);
    expect(db.updates, 0);
    expect(tester.takeException(), isNull);
  });
}
