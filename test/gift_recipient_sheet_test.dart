// Test-only Firestore double; no SDK or production data is accessed.
// ignore_for_file: subtype_of_sealed_class

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/presentation/screens/shop/shop.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/shared/lrs_theme.dart';

import 'support/layout_firebase_fakes.dart';

class _CatalogDelegate extends LocalizationsDelegate<ClrsLocalizations> {
  const _CatalogDelegate(this.catalog);
  final Map<String, dynamic> catalog;

  @override
  bool isSupported(Locale locale) =>
      const ['en', 'ru'].contains(locale.languageCode);

  @override
  Future<ClrsLocalizations> load(Locale locale) =>
      SynchronousFuture(ClrsLocalizations(locale, catalog));

  @override
  bool shouldReload(_CatalogDelegate old) => false;
}

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

class _OtherUser extends LayoutUser {
  @override
  String get uid => 'another-viewer';
}

const _currentAction = Key('gift-current-recipient');
const _panel = Key('gift-recipient-panel');

void _seedRecipients(_GiftFirestore db, {int count = 1}) {
  db.emit(
    'chats',
    [
      for (var i = 0; i < count; i++)
        {
          'user1': 'viewer',
          'user2': 'person-$i',
          'lastMessageSendTs': Timestamp.fromMillisecondsSinceEpoch(count - i),
        },
    ],
    ids: [for (var i = 0; i < count; i++) 'chat-$i'],
  );
  for (var i = 0; i < count; i++) {
    db.documents['users/person-$i'] = {
      'fullName': 'Собеседник $i',
      'status': 'active',
    };
  }
}

Future<void> _openPicker(
  WidgetTester tester, {
  required _GiftFirestore db,
  required LayoutAuth auth,
  String? preferredUid = 'person-0',
  String? preferredChatId = 'chat-0',
  Future<void> Function(String uid, String chatId)? onSend,
  String? localeCode,
  double textScale = 1,
  bool withGiftPreview = false,
}) async {
  final catalog = localeCode == null
      ? null
      : Map<String, dynamic>.from(
          jsonDecode(File('assets/l10n/$localeCode.json').readAsStringSync())
              as Map,
        );
  await tester.pumpWidget(
    MaterialApp(
      theme: LrsTheme.theme,
      locale: localeCode == null ? null : Locale(localeCode),
      supportedLocales: ClrsLocalizations.supportedLocales,
      localizationsDelegates: catalog == null
          ? null
          : [_CatalogDelegate(catalog), ...ClrsLocalizations.delegates.skip(1)],
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => giftRecipientSheetForTesting(
                db: db,
                auth: auth,
                ownerUid: 'viewer',
                preferredRecipientUid: preferredUid,
                preferredChatId: preferredChatId,
                onSend: onSend,
                giftName: withGiftPreview ? 'Кофе и круассан' : null,
                giftImagePath: withGiftPreview ? 'assets/gifts/2.png' : null,
                asDialog: true,
              ),
            ),
            child: const Text('Открыть получателей'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Открыть получателей'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
    for (final font in {
      'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
      'Lato': 'assets/fonts/Lato-Regular.ttf',
      'CormorantGaramond': 'assets/fonts/CormorantGaramond-Variable.ttf',
    }.entries) {
      await (FontLoader(font.key)..addFont(rootBundle.load(font.value))).load();
    }
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

  testWidgets(
    'Current-recipient action sends the real chat once across both buttons',
    (tester) async {
      final db = _GiftFirestore()..serveEmittedQueries = true;
      addTearDown(db.close);
      _seedRecipients(db);
      final pending = Completer<void>();
      final sent = <String>[];
      await _openPicker(
        tester,
        db: db,
        auth: LayoutAuth(),
        onSend: (uid, chatId) {
          sent.add('$uid/$chatId');
          return pending.future;
        },
      );
      final currentCallback = tester
          .widget<TextButton>(find.byKey(_currentAction))
          .onPressed!;
      final ordinaryCallback = tester
          .widget<ElevatedButton>(
            find.widgetWithText(ElevatedButton, 'Подарить'),
          )
          .onPressed!;
      currentCallback();
      currentCallback();
      ordinaryCallback();
      await tester.pump();
      expect(sent, ['person-0/chat-0']);
      expect(
        tester.widget<TextButton>(find.byKey(_currentAction)).onPressed,
        isNull,
      );
      pending.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(_panel), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Current recipient outside the first visible list is still available',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = _GiftFirestore()..serveEmittedQueries = true;
      addTearDown(db.close);
      _seedRecipients(db, count: 30);
      final sent = <String>[];
      await _openPicker(
        tester,
        db: db,
        auth: LayoutAuth(),
        preferredUid: 'person-29',
        preferredChatId: 'chat-29',
        onSend: (uid, chatId) async {
          sent.add('$uid/$chatId');
        },
      );
      expect(find.text('Собеседник 29'), findsNothing);
      expect(
        tester.widget<TextButton>(find.byKey(_currentAction)).onPressed,
        isNotNull,
      );
      await tester.tap(find.byKey(_currentAction));
      await tester.pumpAndSettle();
      expect(sent, ['person-29/chat-29']);
      expect(tester.takeException(), isNull);
    },
  );

  for (final inactive in <String, Map<String, dynamic>?>{
    'missing': null,
    'deleted flag': {'deleted': true},
    'deleted status': {'status': 'deleted'},
    'deleted registration': {'registrationStatus': 'deleted'},
    'blocked': {'status': 'blocked'},
    'disabled': {'disabled': true},
  }.entries) {
    testWidgets('Current action cannot send to ${inactive.key}', (
      tester,
    ) async {
      final db = _GiftFirestore()..serveEmittedQueries = true;
      addTearDown(db.close);
      _seedRecipients(db);
      if (inactive.value == null) {
        db.documents.remove('users/person-0');
      } else {
        db.documents['users/person-0']!.addAll(inactive.value!);
      }
      var sent = 0;
      await _openPicker(
        tester,
        db: db,
        auth: LayoutAuth(),
        onSend: (_, __) async {
          sent++;
        },
      );
      expect(find.text('Собеседник 0'), findsNothing);
      expect(
        tester.widget<TextButton>(find.byKey(_currentAction)).onPressed,
        isNull,
      );
      await tester.tap(find.byKey(_currentAction));
      await tester.pump();
      expect(sent, 0);
      expect(find.widgetWithText(ElevatedButton, 'Подарить'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Preferred UID cannot fabricate a recipient outside own chats', (
    tester,
  ) async {
    final db = _GiftFirestore()..serveEmittedQueries = true;
    addTearDown(db.close);
    _seedRecipients(db);
    db.documents['users/outsider'] = {
      'fullName': 'Чужой собеседник',
      'status': 'active',
    };
    db.emit(
      'chats',
      [
        {'user1': 'someone-else', 'user2': 'outsider'},
      ],
      ids: ['foreign-chat'],
    );
    var sent = 0;
    await _openPicker(
      tester,
      db: db,
      auth: LayoutAuth(),
      preferredUid: 'outsider',
      preferredChatId: 'foreign-chat',
      onSend: (_, __) async {
        sent++;
      },
    );
    expect(
      tester.widget<TextButton>(find.byKey(_currentAction)).onPressed,
      isNull,
    );
    expect(find.text('Чужой собеседник'), findsNothing);
    await tester.tap(find.byKey(_currentAction));
    await tester.pump();
    expect(sent, 0);
  });

  testWidgets(
    'Current action respects search and sends current after another selection',
    (tester) async {
      final db = _GiftFirestore()..serveEmittedQueries = true;
      addTearDown(db.close);
      _seedRecipients(db, count: 2);
      final sent = <String>[];
      await _openPicker(
        tester,
        db: db,
        auth: LayoutAuth(),
        onSend: (uid, chatId) async {
          sent.add('$uid/$chatId');
        },
      );
      await tester.enterText(find.byType(TextField), 'Собеседник 1');
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextButton>(find.byKey(_currentAction)).onPressed,
        isNull,
      );
      await tester.tap(find.byKey(_currentAction));
      await tester.pump();
      expect(sent, isEmpty);
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Собеседник 1'));
      await tester.pump();
      await tester.tap(find.byKey(_currentAction));
      await tester.pumpAndSettle();
      expect(sent, ['person-0/chat-0']);
    },
  );

  testWidgets('Stale current action cannot send after account replacement', (
    tester,
  ) async {
    final db = _GiftFirestore()..serveEmittedQueries = true;
    addTearDown(db.close);
    _seedRecipients(db);
    final auth = LayoutAuth();
    var sent = 0;
    await _openPicker(
      tester,
      db: db,
      auth: auth,
      onSend: (_, __) async {
        sent++;
      },
    );
    final staleCallback = tester
        .widget<TextButton>(find.byKey(_currentAction))
        .onPressed!;
    auth.user = _OtherUser();
    staleCallback();
    await tester.pump();
    expect(sent, 0);
  });

  testWidgets('Completion after sign out does not pop the next screen', (
    tester,
  ) async {
    final db = _GiftFirestore()..serveEmittedQueries = true;
    addTearDown(db.close);
    _seedRecipients(db);
    final auth = LayoutAuth();
    final pending = Completer<void>();
    await _openPicker(
      tester,
      db: db,
      auth: auth,
      onSend: (_, __) => pending.future,
    );
    await tester.tap(find.byKey(_currentAction));
    await tester.pump();
    auth.user = null;
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(_panel), findsOneWidget);
    expect(find.text('Сеанс завершён. Войдите снова.'), findsOneWidget);
    expect(
      tester.widget<TextButton>(find.byKey(_currentAction)).onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Disposed recipient screen ignores pending completion', (
    tester,
  ) async {
    final db = _GiftFirestore()..serveEmittedQueries = true;
    addTearDown(db.close);
    _seedRecipients(db);
    final pending = Completer<void>();
    await _openPicker(
      tester,
      db: db,
      auth: LayoutAuth(),
      onSend: (_, __) => pending.future,
    );
    await tester.tap(find.byKey(_currentAction));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    pending.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('An unconfirmed send stays blocked across both actions', (
    tester,
  ) async {
    final db = _GiftFirestore()..serveEmittedQueries = true;
    addTearDown(db.close);
    _seedRecipients(db);
    var sent = 0;
    await _openPicker(
      tester,
      db: db,
      auth: LayoutAuth(),
      onSend: (_, __) async {
        sent++;
        throw TimeoutException('Synthetic unknown outcome');
      },
    );
    await tester.tap(find.byKey(_currentAction));
    await tester.pumpAndSettle();
    expect(sent, 1);
    expect(
      tester.widget<TextButton>(find.byKey(_currentAction)).onPressed,
      isNull,
    );
    expect(
      tester
          .widget<ElevatedButton>(
            find.widgetWithText(ElevatedButton, 'Подарить'),
          )
          .onPressed,
      isNull,
    );
    expect(
      find.text(
        'Предыдущая отправка ожидает подтверждения. Проверьте результат.',
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    '360 dp dialog leaves the right third free and fits above keyboard',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      final db = _GiftFirestore()..serveEmittedQueries = true;
      addTearDown(db.close);
      _seedRecipients(db);
      await _openPicker(tester, db: db, auth: LayoutAuth());
      expect(tester.getSize(find.byKey(_panel)).width, closeTo(232, .01));
      expect(tester.getTopLeft(find.byKey(_panel)).dx, 0);
      expect(tester.getSize(find.byKey(_panel)).height, 640);
      expect(
        tester.widget<TextButton>(find.byKey(_currentAction)).onPressed,
        isNotNull,
      );
      expect(
        tester.getRect(find.byKey(_currentAction)).right,
        lessThanOrEqualTo(232),
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 220);
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byKey(_panel)).width, closeTo(232, .01));
      expect(tester.getRect(find.byKey(_panel)).bottom, closeTo(420, .01));
      expect(
        tester.getRect(find.widgetWithText(ElevatedButton, 'Подарить')).bottom,
        lessThanOrEqualTo(420),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Dialog width accounts for horizontal safe-area insets', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(left: 18, right: 22);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    final db = _GiftFirestore()..serveEmittedQueries = true;
    addTearDown(db.close);
    _seedRecipients(db);
    await _openPicker(tester, db: db, auth: LayoutAuth());
    expect(tester.getTopLeft(find.byKey(_panel)).dx, 18);
    expect(tester.getSize(find.byKey(_panel)).width, closeTo(205.333333, .01));
    expect(tester.takeException(), isNull);
  });

  for (final code in ['en', 'ru']) {
    for (final keyboardHeight in [274.0, 300.0]) {
      for (final textScale in [1.0, 2.0]) {
        testWidgets(
          'Full $code gift picker remains reachable with $keyboardHeight dp keyboard and ${textScale * 100}% text',
          (tester) async {
            tester.view.physicalSize = const Size(360, 640);
            tester.view.devicePixelRatio = 1;
            tester.view.padding = const FakeViewPadding(
              left: 18,
              top: 24,
              right: 22,
            );
            tester.view.viewPadding = const FakeViewPadding(
              left: 18,
              top: 24,
              right: 22,
              bottom: 48,
            );
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            addTearDown(tester.view.resetPadding);
            addTearDown(tester.view.resetViewPadding);
            addTearDown(tester.view.resetViewInsets);
            final db = _GiftFirestore()..serveEmittedQueries = true;
            addTearDown(db.close);
            _seedRecipients(db);
            final sent = <String>[];
            await _openPicker(
              tester,
              db: db,
              auth: LayoutAuth(),
              localeCode: code,
              textScale: textScale,
              withGiftPreview: true,
              onSend: (uid, chatId) async => sent.add('$uid/$chatId'),
            );
            await tester.ensureVisible(find.byType(TextField));
            await tester.pumpAndSettle();
            await tester.tap(find.byType(TextField));
            tester.view.viewInsets = FakeViewPadding(bottom: keyboardHeight);
            await tester.pumpAndSettle();
            final bounds = tester.getRect(find.byKey(_panel));
            expect(bounds.width, closeTo((360 - 18 - 22 - 12) * 2 / 3, .01));
            expect(bounds.bottom, closeTo(640 - keyboardHeight, .01));
            expect(
              tester.takeException(),
              isNull,
              reason: '$code keyboard initial',
            );
            final scroll = find
                .descendant(
                  of: find.byKey(const Key('gift-recipient-scroll')),
                  matching: find.byType(Scrollable),
                )
                .first;
            Future<void> reach(Finder target) async {
              await tester.scrollUntilVisible(target, 120, scrollable: scroll);
              await tester.ensureVisible(target);
              await tester.pumpAndSettle();
              final rect = tester.getRect(target);
              expect(rect.left, greaterThanOrEqualTo(bounds.left));
              expect(rect.right, lessThanOrEqualTo(bounds.right));
              expect(rect.top, greaterThanOrEqualTo(bounds.top));
              expect(rect.bottom, lessThanOrEqualTo(bounds.bottom));
              expect(
                tester.takeException(),
                isNull,
                reason: '$code reachable action',
              );
            }

            await reach(find.byKey(_currentAction));
            expect(
              tester.widget<TextButton>(find.byKey(_currentAction)).onPressed,
              isNotNull,
            );
            await reach(find.text('Собеседник 0'));
            final footer = find.byType(ElevatedButton);
            await reach(footer);
            await tester.tap(footer);
            await tester.pumpAndSettle();
            expect(sent, ['person-0/chat-0']);
            expect(find.byKey(_panel), findsNothing);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  test(
    'Current-recipient action has a nonempty bundled value for all 23 UI languages',
    () {
      const key = 'Подарить текущему собеседнику';
      expect(ClrsLocalizations.codes.length, 23);
      for (final code in ClrsLocalizations.codes) {
        final catalog =
            jsonDecode(File('assets/l10n/$code.json').readAsStringSync())
                as Map;
        expect(catalog[key], isA<String>(), reason: code);
        expect((catalog[key] as String).trim(), isNotEmpty, reason: code);
      }
    },
  );
}
