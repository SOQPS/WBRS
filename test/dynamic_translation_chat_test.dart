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
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/app/widgets/chat_room_list.dart';
import 'package:wbrs/app/widgets/message_tile.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/service/content_translation_service.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/shared/translatable_text.dart';

import 'support/layout_firebase_fakes.dart';

const _original = 'Hello, this is the original message.';
const _quote = 'This is the original quoted message.';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LayoutFirestore db;
  late ContentTranslationService translator;
  late Directory journalDirectory;
  final requests = <Map<String, dynamic>>[];
  String? copied;
  var sequence = 0;
  late String chatId;
  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
    journalDirectory =
        await Directory.systemTemp.createTemp('clrs-chat-translation-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => journalDirectory.path);
  });
  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'), null);
    if (await journalDirectory.exists()) {
      await journalDirectory.delete(recursive: true);
    }
  });
  setUp(() {
    requests.clear();
    copied = null;
    chatId = 'translation-${sequence++}';
    db = LayoutFirestore();
    firebaseFirestore = db;
    firebaseAuth = LayoutAuth();
    firebaseMessaging = LayoutMessaging();
    db.documents['chats/$chatId'] = {
      'user1': 'viewer',
      'user2': 'other',
      'usersWOutNotifications': ['other'],
      'unreadMessage': 0,
    };
    db.documents['meets/$chatId'] = {
      'users': ['viewer', 'other'],
      'usersWithoutNotification': ['other'],
    };
    db.documents['users/viewer'] = {'fullName': 'Viewer'};
    db.documents['users/other'] = {
      'fullName': 'Alexandra Constantinopoulos',
      'profilePic': '',
      'группа': 'синяя',
    };
    translator = ContentTranslationService(
      endpoint: Uri.parse('https://translation.example.test/translate'),
      currentUserId: () => 'viewer',
      idToken: () async => 'test-token',
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        requests.add(body);
        return http.Response(
            jsonEncode({
              'translatedText': 'Перевод: ${body['text']}',
              'detectedSourceLanguage': 'en',
              'targetLanguage': body['targetLanguage'],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      }),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
  });
  tearDown(() async {
    translator.dispose();
    await db.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  ClrsLocalizations catalog(String code) => ClrsLocalizations(
      ClrsLocalizations.localeFor(code),
      jsonDecode(File('assets/l10n/$code.json').readAsStringSync())
          as Map<String, dynamic>);

  Future<void> pump(WidgetTester tester, Widget child,
      {String code = 'ru',
      double scale = 1,
      Size size = const Size(320, 640),
      double keyboard = 0,
      ContentTranslationService? service}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    final localizations = catalog(code);
    await tester.pumpWidget(ContentTranslationScope(
      service: service ?? translator,
      child: MaterialApp(
        theme: LrsTheme.theme,
        locale: localizations.locale,
        supportedLocales: ClrsLocalizations.supportedLocales,
        localizationsDelegates: [
          _LoadedDelegate(localizations),
          ...ClrsLocalizations.delegates.skip(1),
        ],
        builder: (context, widget) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(
                    textScaler: TextScaler.linear(scale),
                    viewInsets: EdgeInsets.only(bottom: keyboard)),
            child: widget!),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    ));
    await tester.pumpAndSettle();
  }

  MessageTile message(
      {bool personal = true,
      bool own = false,
      String text = _original,
      bool quote = false,
      String quoteText = _quote}) {
    final path =
        '${personal ? 'chats' : 'meets'}/$chatId/${personal ? 'chats' : 'messages'}/original';
    final data = <String, dynamic>{
      'message': text,
      'sendBy': 'Original author',
      'name': 'Original author',
      'sendByID': own ? 'viewer' : 'other',
      'sender': own ? 'viewer' : 'other',
      'isRead': true,
      'time': Timestamp.fromDate(DateTime(2026, 9, 22, 20)),
      if (quote)
        'replyMessage': {
          'message': quoteText,
          'sendBy': 'Quote author',
          'name': 'Quote author',
        },
    };
    db.documents[path] = data;
    return MessageTile(
        message: LayoutSnapshot(db, path, data),
        chatId: chatId,
        sender: own ? 'viewer' : 'other',
        sentByMe: own,
        isRead: true,
        name: 'Original author',
        isChat: personal);
  }

  Future<void> translateMessage(WidgetTester tester) async {
    await tester.ensureVisible(find.text('Перевести'));
    await tester.tap(find.text('Перевести'));
    await tester.pumpAndSettle();
    expect(find.text('Перевод: $_original'), findsOneWidget);
  }

  for (final personal in [false, true]) {
    for (final own in [false, true]) {
      testWidgets(
          'Manual link and original copy personal=$personal outgoing=$own',
          (tester) async {
        final tile = message(personal: personal, own: own);
        await pump(tester, tile);
        expect(requests, isEmpty);
        expect(find.text('Перевести'), findsOneWidget);
        await translateMessage(tester);
        expect(requests.single, {'text': _original, 'targetLanguage': 'ru'});
        expect(tile.message.get('message'), _original);
        expect(db.updates, 0);
        expect(db.commits, 0);
        await tester.longPress(find.text('Перевод: $_original'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Копировать'));
        await tester.pumpAndSettle();
        expect(copied, _original);
        await tester.tap(find.text('Показать оригинал'));
        await tester.pumpAndSettle();
        expect(find.text(_original), findsOneWidget);
        await tester.tap(find.text('Показать перевод'));
        await tester.pumpAndSettle();
        expect(find.text('Перевод: $_original'), findsOneWidget);
        expect(requests, hasLength(1));
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('Editing translated outgoing message opens the original',
      (tester) async {
    await pump(tester, message(own: true));
    await translateMessage(tester);
    await tester.longPress(find.text('Перевод: $_original'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Редактировать'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        _original);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(db.updates, 0);
  });

  for (final personal in [false, true]) {
    testWidgets('Quote auto translates but stores source personal=$personal',
        (tester) async {
      final tile = message(personal: personal, quote: true);
      await pump(tester, tile);
      expect(requests.single['text'], _quote);
      expect(find.text('Перевод: $_quote'), findsOneWidget);
      expect(find.text(_original), findsOneWidget);
      expect(find.text('Перевести'), findsOneWidget);
      expect((tile.message.get('replyMessage') as Map)['message'], _quote);
      await translateMessage(tester);
      await tester.longPress(find.text('Перевод: $_original'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ответить'));
      await tester.pump();
      // The existing durable reply journal performs real file IO. Wait on
      // readiness in real time rather than assuming a fixed fake-time delay.
      final watch = Stopwatch()..start();
      while (tester.widget<TextField>(find.byType(TextField)).readOnly &&
          watch.elapsed < const Duration(seconds: 5)) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      expect(
          tester.widget<TextField>(find.byType(TextField)).readOnly, isFalse);
      final quotePreview = tester
          .widgetList<TranslatableText>(find.descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(TranslatableText)))
          .single;
      expect(quotePreview.text, _original);
      expect(quotePreview.autoTranslate, isTrue);
      expect(quotePreview.showAction, isFalse);
      await tester.enterText(find.byType(TextField), 'My original reply');
      await tester.tap(find.descendant(
          of: find.byType(AlertDialog), matching: find.text('Ответить')));
      final sending = Stopwatch()..start();
      while (find.byType(AlertDialog).evaluate().isNotEmpty &&
          sending.elapsed < const Duration(seconds: 5)) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.byType(AlertDialog), findsNothing);
      final saved = db.documents.entries
          .where((entry) => entry.value['message'] == 'My original reply')
          .single
          .value;
      expect((saved['replyMessage'] as Map)['message'], _original);
      expect(saved['message'], 'My original reply');
      expect(tester.takeException(), isNull);
    });
  }

  for (final width in [320.0, 390.0]) {
    testWidgets('Long quoted reply uses full-width text at ${width}dp',
        (tester) async {
      final longQuote = List.filled(8, 'Длинная исходная цитата без обрезания.')
          .join(' ');
      final longReply = List.filled(10, 'Развёрнутый ответ с полным текстом.')
          .join('\n');
      await pump(tester,
          message(text: longQuote, quote: true, quoteText: longQuote),
          size: Size(width, 640), keyboard: 220);
      final bubbleQuote = tester.widget<TranslatableText>(
          find.byWidgetPredicate((widget) => widget is TranslatableText &&
              widget.text == longQuote && !widget.showAction));
      expect(bubbleQuote.maxLines, isNull);
      expect(bubbleQuote.overflow, isNull);

      final original = find.byWidgetPredicate((widget) =>
          widget is TranslatableText &&
          widget.text == longQuote &&
          widget.showAction);
      await tester.ensureVisible(original);
      await tester.longPress(original);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ответить'));
      await tester.pump();
      final watch = Stopwatch()..start();
      while (tester.widget<TextField>(find.byType(TextField)).readOnly &&
          watch.elapsed < const Duration(seconds: 5)) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      final dialog = find.byType(AlertDialog);
      expect(tester.getSize(dialog).width, greaterThan(width - 32));
      final preview = tester.widget<TranslatableText>(find.descendant(
          of: dialog,
          matching: find.byWidgetPredicate((widget) =>
              widget is TranslatableText && widget.text == longQuote)));
      expect(preview.maxLines, isNull);
      expect(preview.overflow, isNull);
      final input = find.byType(TextField);
      expect(tester.widget<TextField>(input).maxLines, isNull);
      await tester.enterText(input, longReply);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(input).controller!.text, longReply);
      expect(tester.takeException(), isNull);
    });
  }

  for (final own in [false, true]) {
    testWidgets(
        'Room preview translates body without sender name outgoing=$own',
        (tester) async {
      final data = <String, dynamic>{
        ...db.documents['chats/$chatId']!,
        'lastMessage': _original,
        'lastMessageSendByID': own ? 'viewer' : 'other',
        'lastMessageSendBy': 'Name preserved verbatim',
      };
      await pump(tester,
          ChatRoomList(snapshot: LayoutSnapshot(db, 'chats/$chatId', data)),
          scale: 2);
      expect(requests.single['text'], _original);
      expect(find.text('Перевод: $_original'), findsOneWidget);
      expect(
          find.text(own ? 'Вы:' : 'Name preserved verbatim:'), findsOneWidget);
      expect(find.text('Перевести'), findsNothing);
      expect(data['lastMessage'], _original);
      expect(db.updates, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Whitespace-only message has no translation action',
      (tester) async {
    await pump(tester, message(text: '   '));
    expect(find.text('Перевести'), findsNothing);
    expect(requests, isEmpty);
  });

  testWidgets('Gift names use the bundled catalog without dynamic translation',
      (tester) async {
    final data = <String, dynamic>{
      'name': 'Кофе и круассан',
      'image': 'assets/gifts/2.png',
      'time': Timestamp.fromDate(DateTime(2026, 9, 22, 20)),
    };
    await pump(
        tester,
        MessageTile(
            message: LayoutSnapshot(db, 'chats/$chatId/chats/gift', data),
            chatId: chatId,
            sender: 'other',
            sentByMe: false,
            isRead: true,
            name: 'Gift sender',
            isChat: true),
        code: 'de',
        scale: 2);
    expect(find.text(catalog('de').text('Кофе и круассан')), findsOneWidget);
    expect(find.byType(TranslatableText), findsNothing);
    expect(requests, isEmpty);
    expect(data['name'], 'Кофе и круассан');
    expect(tester.takeException(), isNull);
  });

  for (final code in ClrsLocalizations.codes) {
    testWidgets('Actual $code controls and missing provider fit 320dp at 2x',
        (tester) async {
      final offline = ContentTranslationService(
          endpoint: null,
          currentUserId: () => 'viewer',
          idToken: () async => 'test-token');
      addTearDown(offline.dispose);
      final strings = catalog(code);
      await pump(tester, message(), code: code, scale: 2, service: offline);
      final action = find.text(strings.text('Перевести'));
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(find.text(strings.text('Переводчик ещё не подключён.')),
          findsOneWidget);
      expect(find.text(_original), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(requests, isEmpty);
    });
  }
}

class _LoadedDelegate extends LocalizationsDelegate<ClrsLocalizations> {
  const _LoadedDelegate(this.value);
  final ClrsLocalizations value;
  @override
  bool isSupported(Locale locale) => locale == value.locale;
  @override
  Future<ClrsLocalizations> load(Locale locale) => SynchronousFuture(value);
  @override
  bool shouldReload(_LoadedDelegate old) => old.value != value;
}
