// Local SDK boundaries only; no Firebase project, rules or real account data.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wbrs/localization/locale_controller.dart';
import 'package:wbrs/service/push_language_sync.dart';

import 'support/layout_firebase_fakes.dart';

class _Update {
  _Update(this.path, this.fields);
  final String path;
  final Map<String, dynamic> fields;
}

class _Database extends LayoutFirestore {
  _Database() {
    updateHandler = (path, fields) async {
      final update = _Update(path, fields.cast<String, dynamic>());
      attempts.add(update);
      await beforeWrite?.call(update);
      if (error != null) throw error!;
      final profile = documents[path];
      if (profile == null) throw StateError('profile-missing');
      profile.addAll(update.fields);
      applied.add(update);
    };
  }

  final attempts = <_Update>[];
  final applied = <_Update>[];
  Future<void> Function(_Update update)? beforeWrite;
  Object? error;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Database db;
  String? currentUid;
  String? readyUid;
  late bool mounted;

  setUp(() {
    currentUid = readyUid = 'account-a';
    mounted = true;
    db = _Database()
      ..documents.addAll({
        'users/account-a': {
          'fullName': 'A',
          'language': 'ru',
          'role': 'user',
          'status': 'active',
        },
        'users/account-b': {'fullName': 'B', 'language': 'de'},
        'TOKENS/account-a': {'token': 'unchanged-token'},
      });
  });
  tearDown(() => db.close());

  PushLanguageSync service({bool enabled = true}) => PushLanguageSync(
        firestore: db,
        currentUid: () => currentUid,
        readyUid: () => readyUid,
        isMounted: () => mounted,
        enabled: enabled,
      );

  Map<String, Map<String, dynamic>> snapshot() => {
        for (final entry in db.documents.entries)
          entry.key: Map<String, dynamic>.from(entry.value),
      };

  test('The shared rollout default makes no new production language write',
      () async {
    expect(serverSocialNoticesEnabled, isFalse);
    final sync = PushLanguageSync(
      firestore: db,
      currentUid: () => currentUid,
      readyUid: () => readyUid,
      isMounted: () => mounted,
    );
    final before = snapshot();
    await sync.sync('en');
    expect(db.attempts, isEmpty);
    expect(db.documents, before);
  });

  test('An explicitly disabled rollout also ignores language changes',
      () async {
    await service(enabled: false).sync('fr');
    expect(db.attempts, isEmpty);
    expect(db.documents['users/account-a']!['language'], 'ru');
  });

  test('Enabled rollout updates only the captured ready profile language',
      () async {
    final before = snapshot();
    await service().sync('sr_Latn');
    before['users/account-a']!['language'] = 'sr';
    expect(db.documents, before);
    expect(db.attempts, hasLength(1));
    expect(db.attempts.single.path, 'users/account-a');
    expect(db.attempts.single.fields, {'language': 'sr'});
  });

  test('No writes before an authenticated matching ready profile is mounted',
      () async {
    final sync = service();
    currentUid = null;
    await sync.sync('en');
    currentUid = 'account-a';
    readyUid = null;
    await sync.sync('en');
    readyUid = 'account-b';
    await sync.sync('en');
    readyUid = 'account-a';
    mounted = false;
    await sync.sync('en');
    expect(db.attempts, isEmpty);
    mounted = true;
    await sync.sync('es');
    expect(db.attempts, hasLength(1));
    expect(db.documents['users/account-a']!['language'], 'es');
  });

  test('Unsupported codes cannot become profile language metadata', () async {
    await service().sync('unsupported');
    expect(db.attempts, isEmpty);
  });

  test('The account and mount guards are rechecked after queued waiting',
      () async {
    final sync = service();
    final replaced = sync.sync('en');
    currentUid = readyUid = 'account-b';
    await replaced;
    expect(db.attempts, isEmpty);
    final unmounted = sync.sync('fr');
    mounted = false;
    await unmounted;
    expect(db.attempts, isEmpty);
    mounted = true;
    await sync.sync('pt');
    expect(db.attempts.single.path, 'users/account-b');
    expect(db.documents['users/account-a']!['language'], 'ru');
    expect(db.documents['users/account-b']!['language'], 'pt');
  });

  test('A slow earlier write cannot overwrite the latest rapid language choice',
      () async {
    final sync = service();
    final entered = Completer<void>();
    final gate = Completer<void>();
    db.beforeWrite = (_) async {
      if (db.attempts.length == 1) {
        entered.complete();
        await gate.future;
      }
    };
    final earlier = sync.sync('en');
    await entered.future;
    final superseded = sync.sync('de');
    final latest = sync.sync('fr');
    expect(db.attempts, hasLength(1));
    expect(db.documents['users/account-a']!['language'], 'ru');
    gate.complete();
    await Future.wait([earlier, superseded, latest]);
    expect(db.applied.map((update) => update.fields), [
      {'language': 'en'},
      {'language': 'fr'},
    ]);
    expect(db.documents['users/account-a']!['language'], 'fr');
  });

  test('Account replacement skips old queued choices and keeps paths captured',
      () async {
    final sync = service();
    final entered = Completer<void>();
    final gate = Completer<void>();
    db.beforeWrite = (_) async {
      if (db.attempts.length == 1) {
        entered.complete();
        await gate.future;
      }
    };
    final submitted = sync.sync('en');
    await entered.future;
    final stale = sync.sync('es');
    currentUid = readyUid = 'account-b';
    sync.invalidate();
    final replacement = sync.sync('fr');
    gate.complete();
    await Future.wait([submitted, stale, replacement]);
    // A submitted Firestore write cannot be cancelled; it still targets A.
    // The stale queued A choice is skipped, and B receives only B's choice.
    expect(db.applied.map((update) => update.path),
        ['users/account-a', 'users/account-b']);
    expect(db.documents['users/account-a']!['language'], 'en');
    expect(db.documents['users/account-b']!['language'], 'fr');
    expect(db.documents['TOKENS/account-a'], {'token': 'unchanged-token'});
  });

  test('Returning to the same UID does not revive an invalidated queued choice',
      () async {
    final sync = service();
    final entered = Completer<void>();
    final gate = Completer<void>();
    db.beforeWrite = (_) async {
      if (db.attempts.length == 1) {
        entered.complete();
        await gate.future;
      }
    };
    final submitted = sync.sync('en');
    await entered.future;
    final stale = sync.sync('de');
    currentUid = readyUid = 'account-b';
    sync.invalidate();
    currentUid = readyUid = 'account-a';
    sync.invalidate();
    gate.complete();
    await Future.wait([submitted, stale]);
    expect(db.attempts, hasLength(1));
    expect(db.documents['users/account-a']!['language'], 'en');
  });

  test('Disposal prevents queued and subsequent writes without cancelling one',
      () async {
    final sync = service();
    final entered = Completer<void>();
    final gate = Completer<void>();
    db.beforeWrite = (_) async {
      entered.complete();
      await gate.future;
    };
    final submitted = sync.sync('en');
    await entered.future;
    final queued = sync.sync('fr');
    sync.dispose();
    gate.complete();
    await Future.wait([submitted, queued]);
    await sync.sync('es');
    expect(db.attempts, hasLength(1));
    expect(db.documents['users/account-a']!['language'], 'en');
  });

  test('A denied update is swallowed with no automatic retry', () async {
    final sync = service();
    db.error = StateError('denied');
    await expectLater(sync.sync('fr'), completes);
    expect(db.attempts, hasLength(1));
    expect(db.applied, isEmpty);
    expect(db.documents['users/account-a']!['language'], 'ru');
    db.error = null;
    await sync.sync('pt');
    expect(db.attempts, hasLength(2));
    expect(db.documents['users/account-a']!['language'], 'pt');
  });

  test('A missing profile remains missing after best-effort update failure',
      () async {
    db.documents.remove('users/account-a');
    final before = snapshot();
    await expectLater(service().sync('en'), completes);
    expect(db.attempts.single.path, 'users/account-a');
    expect(db.attempts.single.fields, {'language': 'en'});
    expect(db.documents, before);
    expect(db.applied, isEmpty);
  });

  test(
      'Local language persistence neither waits for nor fails on metadata write',
      () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final controller = LocaleController();
    await controller.initialize(
        deviceLocale: const Locale('ru'), preferences: preferences);
    final sync = service();
    final entered = Completer<void>();
    final gate = Completer<void>();
    db.beforeWrite = (_) async {
      entered.complete();
      await gate.future;
    };
    Future<void> metadata = Future<void>.value();
    void listener() {
      metadata = sync.sync(controller.locale.languageCode);
      unawaited(metadata);
    }

    controller.addListener(listener);
    addTearDown(() {
      controller.removeListener(listener);
      controller.dispose();
      sync.dispose();
    });
    await controller.setLanguage('fr');
    await entered.future;
    expect(controller.locale.languageCode, 'fr');
    expect(preferences.getString(LocaleController.preferenceKey), 'fr');
    expect(db.documents['users/account-a']!['language'], 'ru');
    gate.complete();
    await metadata;
    db.beforeWrite = null;
    db.error = StateError('denied');
    await controller.setLanguage('en');
    await metadata;
    expect(controller.locale.languageCode, 'en');
    expect(preferences.getString(LocaleController.preferenceKey), 'en');
    expect(db.documents['users/account-a']!['language'], 'fr');
  });
}
