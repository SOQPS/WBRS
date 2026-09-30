import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/service/session_service.dart';
import 'package:flutter_test/flutter_test.dart' hide group;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/core/utils/account_destination.dart';
import 'package:wbrs/presentation/screens/auth/session_gate.dart';
import 'package:wbrs/presentation/screens/auth/login_screen/login_page.dart';
import 'package:wbrs/presentation/screens/auth/writing_profile_page/writing_data_user.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/service/auth_service.dart';
import 'package:wbrs/service/database_service.dart';
import 'package:wbrs/service/profile_draft_store.dart';
import 'package:wbrs/service/profile_registration_service.dart';
import 'package:wbrs/shared/geo_catalog.dart';
import 'support/stage2_auth_fakes.dart';

const fields = <String, dynamic>{
  'fullName': 'Сохранённое имя',
  'countryCode': 'RU',
  'region': 'Москва',
  'age': '31',
  'height': '175',
  'children': 'нет',
  'gender': 'ж',
  'relationStatus': 'свободен',
  'is18': true,
  'interests': 'Книги, путешествия и общение',
  'about':
      'Я люблю знакомиться с новыми людьми, изучать мир и проводить время с семьёй.'
};
// A valid 1x1 PNG. The previous fixture had an incorrect IDAT CRC, which
// strict/native decoders could reject even though its zlib data decompressed.
const _profilePhotoPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
    await GeoCatalog.load();
  });
  late Directory root;
  late ProfileDraftStore store;
  late Stage2Auth auth;
  late Stage2Database db;
  var index = 0;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('clrs-registration-test-');
    store = ProfileDraftStore(rootDirectory: () async => root);
    auth = Stage2Auth()
      ..user = Stage2User('owner-${index++}', 'owner@example.test',
          name: 'Исходное имя');
    db = Stage2Database();
    firebaseAuth = auth;
    firebaseFirestore = db;
    firebaseMessaging = Stage2Messaging();
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  AuthService authentication(
          {Duration timeout = const Duration(seconds: 20)}) =>
      AuthService(
          auth: auth,
          firestore: db,
          messaging: Stage2Messaging(),
          clearLocal: () async {},
          waitTimeout: timeout);

  Future<ProfileDraft> draftWithPhotos() async {
    final source = File('${root.path}/picker-cache.jpg');
    await source.writeAsBytes(base64Decode(_profilePhotoPng));
    final photos = <ProfileDraftPhoto>[];
    for (var i = 0; i < 3; i++) {
      photos.add(await store.importPhoto(auth.user!.uid, source.path));
    }
    return ProfileDraft(
        uid: auth.user!.uid,
        fields: fields,
        photos: photos,
        mainPhotoId: photos[1].id);
  }

  test('Registration photo fixture decodes through the native image codec',
      () async {
    final codec =
        await ui.instantiateImageCodec(base64Decode(_profilePhotoPng));
    try {
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 1);
      expect(frame.image.height, 1);
      frame.image.dispose();
    } finally {
      codec.dispose();
    }
  });

  test(
      'All sixteen valid saved groups survive stale flags, random strings do not',
      () {
    const bases = ['красная', 'синяя', 'белая', 'коричневая'];
    const stems = ['красно', 'сине', 'бело', 'коричнево'];
    for (var a = 0; a < 4; a++) {
      for (var b = 0; b < 4; b++) {
        final group = a == b ? bases[a] : '${stems[a]}-${bases[b]}';
        expect(
            accountDestination({'isRegistrationEnd': false, 'группа': group}),
            AccountDestination.search);
      }
    }
    expect(accountDestination({'группа': 'случайная строка'}),
        AccountDestination.registration);
    expect(accountDestination({}), AccountDestination.registration);
    expect(accountDestination({'profileDetailsSaved': true}),
        AccountDestination.test);
    expect(accountDestination({'status': 'blocked', 'группа': 'белая'}),
        AccountDestination.blocked);
    expect(accountDestination({'status': 'deleted', 'isRegistrationEnd': true}),
        AccountDestination.deleted);
  });

  test('Auth account creation succeeds even when optional display name fails',
      () async {
    auth.user = null;
    auth.nameError = FirebaseAuthException(code: 'network-request-failed');
    final service = authentication();
    expect(
        await service.registerUserWithEmailAndPassword(
            ' Ник ', 'new@example.test', 'correct-password'),
        isTrue);
    expect(auth.creates, 1);
    expect(auth.currentUser, isNotNull);
    expect(await AuthService.registrationName(auth.currentUser!), 'Ник');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys().any((key) => key.toLowerCase().contains('password')),
        isFalse);
  });

  test(
      'Existing-email registration does not overwrite account and ordinary login works after reinstall',
      () async {
    final existing =
        Stage2User('saved-owner', 'saved@example.test', name: 'Старое имя');
    auth = Stage2Auth(accounts: {'saved@example.test': existing});
    final service = authentication();
    await expectLater(
        service.registerUserWithEmailAndPassword(
            'Новый ник', 'saved@example.test', 'correct-password'),
        throwsA(isA<FirebaseAuthException>()
            .having((e) => e.code, 'code', 'email-already-in-use')));
    expect(existing.displayName, 'Старое имя');
    expect(await AuthService.registrationName(existing), 'Старое имя');
    expect(
        (await SharedPreferences.getInstance())
            .getString('registration_intent_v1'),
        isNull);
    expect(
        await service.loginWithUserNameAndPassword(
            'saved@example.test', 'correct-password'),
        'ok');
    expect(auth.currentUser?.uid, 'saved-owner');
    expect(auth.accounts.length, 1);
  });

  test(
      'Auth timeout checks the original request and never creates a duplicate account',
      () async {
    auth.user = null;
    auth.createGate = Completer<void>();
    final service = authentication(timeout: const Duration(milliseconds: 1));
    expect(
        await service.registerUserWithEmailAndPassword(
            'Ник', 'slow@example.test', 'correct-password'),
        isFalse);
    expect(
        await service.registerUserWithEmailAndPassword(
            'Ник', 'slow@example.test', 'correct-password'),
        isFalse);
    expect(auth.creates, 1);
    auth.createGate!.complete();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(
        await service.registerUserWithEmailAndPassword(
            'Ник', 'slow@example.test', 'correct-password'),
        isTrue);
    expect(auth.creates, 1);
  });

  test(
      'Draft fields, main photo and durable images survive a new store and missing picker cache',
      () async {
    final draft = await draftWithPhotos();
    await store.save(draft);
    await File('${root.path}/picker-cache.jpg').delete();
    final fresh = ProfileDraftStore(rootDirectory: () async => root);
    final restored = (await fresh.load(draft.uid))!;
    expect(restored.id, draft.id);
    expect(restored.fields, fields);
    expect(restored.mainPhotoId, draft.photos[1].id);
    for (final photo in restored.photos) {
      expect(
          await (await fresh.photoFile(restored.uid, photo)).exists(), isTrue);
    }
    expect(await fresh.load('another-user'), isNull);
  });

  test(
      'Queued draft saves retain the latest complete manifest and no passwords',
      () async {
    final draft = await draftWithPhotos();
    await Future.wait(List.generate(30,
        (i) => store.save(draft.copyWith(fields: {...fields, 'age': '$i'}))));
    final restored = (await store.load(draft.uid))!;
    expect(restored.fields['age'], '29');
    expect(jsonEncode(restored.toJson()), isNot(contains('password')));
  });

  test(
      'Partial photo success is persisted; retry reuses object IDs and skips completed uploads',
      () async {
    final draft = await draftWithPhotos();
    final attempts = <String>[];
    var fail = true;
    Future<String> upload(String path, File file) async {
      attempts.add(path);
      if (fail && attempts.length == 2) throw StateError('storage denied');
      return 'https://test.invalid/$path';
    }

    Future<void> write(
        ProfileDraft draft, List<String> urls, String name) async {
      db.documents['users/${draft.uid}'] = {
        'profileDetailsSaved': true,
        'fullName': name
      };
    }

    final service = ProfileRegistrationService(
        store: store,
        auth: auth,
        firestore: db,
        uploader: upload,
        writer: write);
    await expectLater(service.start(draft).write.wait(), throwsStateError);
    final recovered = (await ProfileDraftStore(rootDirectory: () async => root)
        .load(draft.uid))!;
    expect(recovered.photos.first.uploadedUrl, isNotNull);
    expect(recovered.photos[1].uploadedUrl, isNull);
    fail = false;
    final resumed = ProfileRegistrationService(
        store: store,
        auth: auth,
        firestore: db,
        uploader: upload,
        writer: write);
    final request = resumed.start(recovered);
    expect(await request.write.wait(), isTrue);
    expect(attempts.length, 4);
    expect(attempts[1], attempts[2]);
    expect(
        attempts
            .where((path) => path.endsWith('${draft.photos.first.id}.jpg'))
            .length,
        1);
    await resumed.acknowledge(request);
    expect(await store.load(draft.uid), isNull);
  });

  test('Registration accepts 20-character interests and about text', () async {
    final source = await draftWithPhotos();
    final draft = source.copyWith(fields: {
      ...source.fields,
      'interests': '12345678901234567890',
      'about': '12345678901234567890',
    });
    var writes = 0;
    final service = ProfileRegistrationService(
        store: store,
        auth: auth,
        firestore: db,
        uploader: (path, _) async => 'https://test.invalid/$path',
        writer: (saved, _, name) async {
          writes++;
          db.documents['users/${saved.uid}'] = {
            'profileDetailsSaved': true,
            'fullName': name,
          };
        });
    expect(await service.start(draft).write.wait(), isTrue);
    expect(writes, 1);
  });

  test(
      'Process recovery after server commit confirms existing profile without uploading or overwriting it',
      () async {
    final draft = (await draftWithPhotos()).copyWith(commitStarted: true);
    await store.save(draft);
    final profile = {
      'fullName': 'Сохранённый профиль',
      'группа': 'белая',
      'profilePic': 'saved-photo',
      'balance': 91
    };
    db.documents['users/${draft.uid}'] = Map.from(profile);
    final service = ProfileRegistrationService(
        store: store,
        auth: auth,
        firestore: db,
        uploader: (_, __) async => throw StateError('must not upload'),
        writer: (_, __, ___) async => throw StateError('must not overwrite'));
    final restored = (await store.load(draft.uid))!;
    final request = service.start(restored);
    expect(await request.write.wait(), isTrue);
    expect(db.documents['users/${draft.uid}'], profile);
    await service.acknowledge(request);
  });

  test(
      'Pending profile save cannot be resubmitted and session changes prevent a new profile write',
      () async {
    final draft = await draftWithPhotos();
    final gate = Completer<String>();
    var uploads = 0;
    var writes = 0;
    final service = ProfileRegistrationService(
        store: store,
        auth: auth,
        firestore: db,
        uploader: (_, __) {
          uploads++;
          return gate.future;
        },
        writer: (_, __, ___) async {
          writes++;
        });
    final request = service.start(draft);
    expect(await request.write.wait(timeout: const Duration(milliseconds: 10)),
        isFalse);
    expect(service.start(draft), same(request));
    expect(uploads, 1);
    auth.user = Stage2User('different', 'other@example.test');
    gate.complete('test-url');
    await expectLater(request.write.wait(), throwsStateError);
    expect(writes, 0);
  });

  Future<void> saveDatabaseProfile() =>
      DatabaseService().savingUserDataAfterRegister(
          fullName: 'Ник',
          email: 'owner@example.test',
          profilePic: 'url-1',
          profileImages: ['url-0', 'url-1', 'url-2'],
          age: 31,
          rost: '175',
          country: 'Россия',
          countryCode: 'RU',
          region: 'Москва',
          deti: false,
          hobbi: fields['interests'],
          about: fields['about'],
          pol: 'ж');

  test(
      'Partial Firestore profile completes without changing balance, roles, status or existing flags',
      () async {
    final path = 'users/${auth.user!.uid}';
    db.documents[path] = {
      'uid': auth.user!.uid,
      'balance': 63,
      'role': 'moderator',
      'status': 'active',
      'isRegistrationEnd': false
    };
    await saveDatabaseProfile();
    final saved = db.documents[path]!;
    expect(saved.containsKey('email'), isFalse);
    expect(saved['balance'], 63);
    expect(saved['role'], 'moderator');
    expect(saved['status'], 'active');
    expect(saved['isRegistrationEnd'], false);
    expect(saved['profileDetailsSaved'], true);
    expect(
        db.documents.keys
            .where((key) => key.startsWith('$path/images/'))
            .length,
        3);
    expect(accountDestination(saved), AccountDestination.test);
  });

  test(
      'Completed server profile and old photos remain byte-for-byte equivalent after accidental registration save',
      () async {
    final path = 'users/${auth.user!.uid}';
    final old = {
      'uid': auth.user!.uid,
      'balance': 63,
      'role': 'moderator',
      'status': 'active',
      'isRegistrationEnd': false,
      'группа': 'белая',
      'profilePic': 'old-main'
    };
    db.documents[path] = Map.from(old);
    db.documents['$path/images/old'] = {'url': 'old-photo'};
    await saveDatabaseProfile();
    expect(db.documents[path], old);
    expect(db.documents.keys.where((k) => k.startsWith('$path/images/')),
        ['$path/images/old']);
  });

  test(
      'Denied Firestore commit preserves the draft and reuses completed uploads on retry',
      () async {
    final draft = await draftWithPhotos();
    var uploads = 0;
    db.transactionError =
        FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied');
    final service = ProfileRegistrationService(
        store: store,
        auth: auth,
        firestore: db,
        uploader: (path, _) async {
          uploads++;
          return 'https://test.invalid/$path';
        });
    await expectLater(
        service.start(draft).write.wait(), throwsA(isA<FirebaseException>()));
    expect(db.documents, isEmpty);
    final recovered = (await store.load(draft.uid))!;
    expect(
        recovered.photos.every((photo) => photo.uploadedUrl != null), isTrue);
    expect(recovered.fields, fields);
    db.transactionError = null;
    final request = service.start(recovered);
    expect(await request.write.wait(), isTrue);
    expect(uploads, 3);
    expect(db.commits, 1);
    expect(db.documents['users/${draft.uid}']!['balance'], 27);
    expect(db.documents['users/${draft.uid}']!['profilePic'],
        endsWith('${draft.photos[1].id}.jpg'));
    await service.acknowledge(request);
  });

  for (final invalidField in ['interests', 'about']) {
    test('Resumed draft with short $invalidField is rejected before upload',
        () async {
      final original = await draftWithPhotos();
      final draft = original.copyWith(fields: {
        ...original.fields,
        invalidField: 'Слишком коротко',
      });
      var uploads = 0;
      final service = ProfileRegistrationService(
          store: store,
          auth: auth,
          firestore: db,
          uploader: (path, file) async {
            uploads++;
            return 'https://test.invalid/$path';
          });
      await expectLater(service.start(draft).write.wait(), throwsArgumentError);
      expect(uploads, 0);
      expect(db.commits, 0);
    });
  }

  test(
      'UID change inside the Firestore transaction prevents all questionnaire and image mutations',
      () async {
    db.afterTransactionRead =
        () => auth.user = Stage2User('other-user', 'other@example.test');
    await expectLater(saveDatabaseProfile(), throwsStateError);
    expect(db.documents, isEmpty);
    expect(db.commits, 0);
  });

  test(
      'Blocked and deleted profiles have priority and are never rewritten by questionnaire retries',
      () async {
    for (final status in ['blocked', 'deleted']) {
      final path = 'users/${auth.user!.uid}';
      final old = {
        'status': status,
        'isRegistrationEnd': true,
        'группа': 'белая',
        'balance': 55
      };
      db.documents[path] = Map.from(old);
      await expectLater(saveDatabaseProfile(), throwsStateError);
      expect(db.documents[path], old);
      expect(db.documents.length, 1);
    }
  });

  testWidgets(
      'Unavailable server does not mistake empty cache for a missing account; retry restores the saved profile',
      (tester) async {
    db.readError =
        FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
    db.documents['users/${auth.user!.uid}'] = {
      'группа': 'белая',
      'profilePic': 'saved-image'
    };
    await tester.pumpWidget(MaterialApp(
        home: SessionGate(
            auth: auth,
            firestore: db,
            draftStore: store,
            destinationBuilder: (destination, data) =>
                Text('restored:${data!['profilePic']}'))));
    await tester.pumpAndSettle();
    expect(find.byType(AboutUserWriting), findsNothing);
    expect(find.textContaining('Не удалось загрузить профиль'), findsOneWidget);
    expect(SessionService.readyUserId.value, isNull);
    db.readError = null;
    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();
    expect(find.text('restored:saved-image'), findsOneWidget);
    expect(SessionService.readyUserId.value, auth.user!.uid);
    expect(db.sources, [Source.server, Source.server]);
    expect(db.commits, 0);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
  });

  testWidgets(
      'Cold-start session uses the saved server profile with empty local preferences',
      (tester) async {
    final profile = {
      'fullName': 'Серверное имя',
      'isRegistrationEnd': false,
      'группа': 'белая',
      'profilePic': 'old-photo',
      'balance': 63
    };
    db.documents['users/${auth.user!.uid}'] = profile;
    await tester.pumpWidget(MaterialApp(
        home: SessionGate(
            auth: auth,
            firestore: db,
            draftStore: store,
            destinationBuilder: (destination, data) =>
                Text('${destination.name}:${data!['profilePic']}'))));
    await tester.pumpAndSettle();
    expect(find.text('search:old-photo'), findsOneWidget);
    expect(db.sources, [Source.server]);
    expect(db.commits, 0);
    expect(group, 'белая');
    expect(testIsComlpete, isTrue);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
  });

  testWidgets('Only the post-test entry selects the own profile',
      (tester) async {
    db.documents['users/${auth.user!.uid}'] = {
      'fullName': 'Серверное имя',
      'группа': 'белая',
      'isRegistrationEnd': true,
    };
    Widget gate({bool afterTest = false}) => MaterialApp(
        home: SessionGate(
            auth: auth,
            firestore: db,
            draftStore: store,
            showProfileAfterTest: afterTest,
            destinationBuilder: (destination, _) =>
                Text('${destination.name}:$selectedIndex')));

    await tester.pumpWidget(gate());
    await tester.pumpAndSettle();
    expect(find.text('search:1'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(gate(afterTest: true));
    await tester.pumpAndSettle();
    expect(find.text('search:4'), findsOneWidget);
  });

  testWidgets('Cold start honors opt-out but keeps legacy sessions',
      (tester) async {
    db.documents['users/${auth.user!.uid}'] = {
      'fullName': 'Серверное имя',
      'isRegistrationEnd': false,
      'группа': 'белая',
      'profilePic': 'saved-photo',
    };
    await tester.pumpWidget(MaterialApp(
        home: SessionGate(
            enforceRememberMe: true,
            auth: auth,
            firestore: db,
            draftStore: store,
            destinationBuilder: (_, data) =>
                Text('saved:${data!['profilePic']}'))));
    await tester.pumpAndSettle();
    expect(find.text('saved:saved-photo'), findsOneWidget);
    expect(auth.signOuts, 0);

    await tester.pumpWidget(const SizedBox.shrink());
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('remember_me', false);
    await tester.pumpWidget(MaterialApp(
        home: SessionGate(
            auth: auth,
            firestore: db,
            draftStore: store,
            destinationBuilder: (_, data) =>
                Text('saved:${data!['profilePic']}'))));
    await tester.pumpAndSettle();
    expect(find.text('saved:saved-photo'), findsOneWidget);
    expect(auth.signOuts, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(MaterialApp(
        home: SessionGate(
            enforceRememberMe: true,
            auth: auth,
            firestore: db,
            draftStore: store,
            destinationBuilder: (_, data) =>
                Text('saved:${data!['profilePic']}'))));
    await tester.pumpAndSettle();
    expect(auth.signOuts, 1);
    expect(auth.currentUser, isNull);
    expect(db.sources, [Source.server, Source.server]);
    expect(find.text('Вход'), findsOneWidget);
    expect(prefs.getBool('remember_me'), isFalse);
  });
  Future<void> waitForRealState(
      WidgetTester tester, bool Function() ready, String description) async {
    var completed = false;
    await tester.runAsync(() async {
      final clock = Stopwatch()..start();
      while (clock.elapsed < const Duration(seconds: 5)) {
        await tester.pump();
        if (ready()) {
          completed = true;
          return;
        }
        // File-system futures need real time; fake-time settling cannot drive them.
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    expect(completed, isTrue, reason: 'Real IO did not complete: $description');
    await tester.pumpAndSettle();
  }

  Future<void> waitForQuestionnaire(WidgetTester tester) =>
      waitForRealState(tester, () {
        final save = find.byKey(const ValueKey('profile-save'));
        return save.evaluate().length == 1 &&
            tester.widget<ElevatedButton>(save).onPressed != null &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty;
      }, 'restored draft and enabled questionnaire');

  Future<void> pumpQuestionnaire(
      WidgetTester tester, ProfileRegistrationService service,
      {VoidCallback? onSaved}) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
          theme: LrsTheme.theme,
          home: AboutUserWriting(registration: service, onSaved: onSaved)));
    });
    await waitForQuestionnaire(tester);
  }

  testWidgets(
      'Questionnaire saves relationship status and Back returns to login',
      (tester) async {
    final draft = (await tester.runAsync(draftWithPhotos))!;
    await tester.runAsync(() => store.save(draft));
    await pumpQuestionnaire(tester,
        ProfileRegistrationService(store: store, auth: auth, firestore: db));
    await tester.ensureVisible(find.text('Свободен'));
    await tester.tap(find.text('Свободен'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Занят').last);
    await tester.pumpAndSettle();
    await waitForRealState(tester,
        () => find.text('Занят').evaluate().isNotEmpty, 'selected status');
    await tester.tap(find.byIcon(Icons.arrow_back).first);
    await waitForRealState(tester,
        () => find.byType(LoginPage).evaluate().isNotEmpty, 'return to login');
    expect(auth.currentUser, isNull);
    final saved = (await tester.runAsync(() => store.load(draft.uid)))!;
    expect(saved.fields['relationStatus'], 'занят');
    expect(saved.photos.length, 3);
  });

  testWidgets(
      'Questionnaire restores typed fields and chosen main photo from disk after leaving the process state',
      (tester) async {
    final draft = (await tester.runAsync(draftWithPhotos))!;
    await tester.runAsync(() => store.save(draft));
    final service =
        ProfileRegistrationService(store: store, auth: auth, firestore: db);
    await pumpQuestionnaire(tester, service);
    expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        '31');
    expect(find.text('Главное фото'), findsOneWidget);
    expect(find.textContaining('Черновик анкеты восстановлен'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.enterText(find.byType(TextField).first, '32');
      // load is serialized after the controller-triggered save; await the barrier.
      await store.load(draft.uid);
    });
    await tester.pumpAndSettle();
    final saved = (await tester.runAsync(() => store.load(draft.uid)))!;
    expect(saved.fields['age'], '32');
    expect(saved.mainPhotoId, draft.photos[1].id);
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpQuestionnaire(
        tester,
        ProfileRegistrationService(
            store: ProfileDraftStore(rootDirectory: () async => root),
            auth: auth,
            firestore: db));
    expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        '32');
    expect(tester.takeException(), isNull);
  });

  testWidgets('New questionnaire cannot save without three photos',
      (tester) async {
    await tester.runAsync(
        () => store.save(ProfileDraft(uid: auth.user!.uid, fields: fields)));
    var writes = 0;
    final service = ProfileRegistrationService(
        store: store,
        auth: auth,
        firestore: db,
        writer: (_, __, ___) async {
          writes++;
        });
    await pumpQuestionnaire(tester, service);
    await tester.ensureVisible(find.text('Пройти тест'));
    await tester.tap(find.text('Пройти тест'));
    await tester.pumpAndSettle();
    expect(find.text('Добавьте минимум 3 фотографии.'), findsOneWidget);
    expect(writes, 0);
    expect(db.commits, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Larger photo recommendation wraps on a narrow screen',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => store.save(
        ProfileDraft(uid: auth.user!.uid, fields: {...fields, 'gender': 'м'})));
    final service =
        ProfileRegistrationService(store: store, auth: auth, firestore: db);
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
          theme: LrsTheme.theme,
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!),
          home: AboutUserWriting(registration: service)));
    });
    await waitForQuestionnaire(tester);
    final recommendation = find.textContaining('Рекомендация: мужчинам');
    expect(recommendation, findsOneWidget);
    expect(tester.widget<Text>(recommendation).style!.fontSize, 22);
    await tester.ensureVisible(recommendation);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Questionnaire translates the selected country without changing its code',
      (tester) async {
    final service =
        ProfileRegistrationService(store: store, auth: auth, firestore: db);
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
          theme: LrsTheme.theme,
          locale: const Locale('en'),
          supportedLocales: ClrsLocalizations.supportedLocales,
          localizationsDelegates: ClrsLocalizations.delegates,
          home: AboutUserWriting(registration: service)));
    });
    await waitForQuestionnaire(tester);
    expect(find.text('Russia'), findsOneWidget);
    expect(find.text('Россия'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Rapid questionnaire save taps upload once and preserve the selected main photo',
      (tester) async {
    final draft = (await tester.runAsync(draftWithPhotos))!;
    await tester.runAsync(() => store.save(draft));
    var uploads = 0, writes = 0, navigations = 0;
    String? mainId;
    final service = ProfileRegistrationService(
        store: store,
        auth: auth,
        firestore: db,
        uploader: (path, _) async {
          uploads++;
          return 'https://test.invalid/$path';
        },
        writer: (value, urls, name) async {
          writes++;
          mainId = value.mainPhotoId;
          db.documents['users/${value.uid}'] = {'profileDetailsSaved': true};
        });
    await pumpQuestionnaire(tester, service, onSaved: () => navigations++);
    final callback = tester
        .widget<ElevatedButton>(find.byKey(const ValueKey('profile-save')))
        .onPressed!;
    await tester.runAsync(() async {
      callback();
      callback();
    });
    await waitForRealState(tester, () => navigations == 1,
        'one confirmed save and acknowledged navigation');
    expect(uploads, 3);
    expect(writes, 1);
    expect(navigations, 1);
    expect(mainId, draft.photos[1].id);
    expect(tester.takeException(), isNull);
  });
  for (final sample in [
    (const Size(320, 568), 1.0),
    (const Size(320, 568), 2.0),
    (const Size(390, 844), 1.0),
    (const Size(844, 390), 1.3),
  ]) {
    testWidgets(
        'Questionnaire fits ${sample.$1} scale ${sample.$2} with long translated labels',
        (tester) async {
      tester.view.physicalSize = sample.$1;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final draft = (await tester.runAsync(draftWithPhotos))!;
      await tester.runAsync(() => store.save(draft));
      final service =
          ProfileRegistrationService(store: store, auth: auth, firestore: db);
      await tester.runAsync(() async {
        await tester.pumpWidget(MaterialApp(
            theme: LrsTheme.theme,
            localizationsDelegates: const [_LongLabels()],
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(sample.$2)),
                child: child!),
            home: AboutUserWriting(registration: service)));
      });
      await waitForQuestionnaire(tester);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byKey(const ValueKey('profile-save')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('profile-save')), findsOneWidget);
    });
  }
}

class _LongLabels extends LocalizationsDelegate<ClrsLocalizations> {
  const _LongLabels();
  @override
  bool isSupported(Locale locale) => true;
  @override
  Future<ClrsLocalizations> load(Locale locale) =>
      SynchronousFuture(ClrsLocalizations(locale, {
        'Добавить фото': 'Add another photograph to your profile',
        'Расскажите о себе': 'Tell us a little about yourself',
        'Страна': 'Country of residence',
        'Регион': 'Region or administrative area',
        'Есть дети?': 'Do you have any children?',
        'Интересы и увлечения':
            'Your interests, hobbies and favourite activities',
        'Пройти тест':
            'Continue to the personality questionnaire and discover your group',
      }));
  @override
  bool shouldReload(_LongLabels old) => false;
}
