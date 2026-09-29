import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/service/content_translation_service.dart';
import 'package:wbrs/shared/translatable_text.dart';

http.Response translated(String text, String language,
        {String source = 'ru'}) =>
    http.Response(
        jsonEncode({
          'translatedText': text,
          'detectedSourceLanguage': source,
          'targetLanguage': language
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'});

class LoadedCatalog extends LocalizationsDelegate<ClrsLocalizations> {
  const LoadedCatalog(this.catalog);
  final ClrsLocalizations catalog;
  @override
  bool isSupported(Locale locale) => true;
  @override
  Future<ClrsLocalizations> load(Locale locale) => SynchronousFuture(catalog);
  @override
  bool shouldReload(LoadedCatalog old) => catalog.locale != old.catalog.locale;
}

void main() {
  late ContentTranslationService service;
  late List<Map<String, dynamic>> requests;
  var handler = (Map<String, dynamic> body) async =>
      translated('Translated text', body['targetLanguage']);
  setUp(() {
    requests = [];
    handler =
        (body) async => translated('Translated text', body['targetLanguage']);
    service = ContentTranslationService(
        endpoint: Uri.parse('https://translation.example.test'),
        currentUserId: () => 'viewer',
        idToken: () async => 'fixture',
        client: MockClient((r) {
          final body = jsonDecode(r.body) as Map<String, dynamic>;
          requests.add(body);
          return handler(body);
        }));
  });
  tearDown(() => service.dispose());
  Future<void> pump(WidgetTester tester, Widget child,
      {String language = 'en'}) async {
    final catalog = ClrsLocalizations(
        ClrsLocalizations.localeFor(language),
        jsonDecode(File('assets/l10n/$language.json').readAsStringSync())
            as Map<String, dynamic>);
    await tester.pumpWidget(ContentTranslationScope(
        service: service,
        child: MaterialApp(
            locale: catalog.locale,
            supportedLocales: ClrsLocalizations.supportedLocales,
            localizationsDelegates: [
              LoadedCatalog(catalog),
              ...ClrsLocalizations.delegates.skip(1)
            ],
            home: Scaffold(body: SingleChildScrollView(child: child)))));
    await tester.pump();
  }

  testWidgets('automatic translation and original toggle reuse one result',
      (tester) async {
    await pump(tester, const TranslatableText('Исходный свободный текст'));
    await tester.pumpAndSettle();
    expect(find.text('Translated text'), findsOneWidget);
    await tester.tap(find.text('Show original'));
    await tester.pump();
    expect(find.text('Исходный свободный текст'), findsOneWidget);
    await tester.tap(find.text('Show translation'));
    await tester.pump();
    expect(find.text('Translated text'), findsOneWidget);
    expect(requests, hasLength(1));
  });
  testWidgets('Amazon-backed translation shows only the generic action',
      (tester) async {
    await pump(
        tester,
        const SizedBox(
            width: 280,
            child: TranslatableText('Исходный текст', autoTranslate: false)));
    await tester.tap(find.text('Translate'));
    await tester.pumpAndSettle();
    expect(find.text('Translated text'), findsOneWidget);
    expect(find.text('Show original'), findsOneWidget);
    expect(find.textContaining('Google'), findsNothing);
    await tester.tap(find.text('Show original'));
    await tester.pump();
    expect(find.text('Исходный текст'), findsOneWidget);
    await tester.tap(find.text('Show translation'));
    await tester.pump();
    expect(find.text('Translated text'), findsOneWidget);
  });
  testWidgets('Automatic preview remains readable at narrow width',
      (tester) async {
    await pump(
        tester,
        const SizedBox(
            width: 160,
            child: TranslatableText('Исходный длинный текст',
                showAction: false,
                maxLines: 1,
                overflow: TextOverflow.ellipsis)));
    await tester.pumpAndSettle();
    expect(find.text('Translated text'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('manual translation starts only on tap and busy disables repeats',
      (tester) async {
    final pending = Completer<http.Response>();
    handler = (_) => pending.future;
    await pump(
        tester, const TranslatableText('Free text', autoTranslate: false));
    expect(requests, isEmpty);
    await tester.tap(find.text('Translate'));
    await tester.pump();
    expect(
        tester.widget<TextButton>(find.byType(TextButton)).onPressed, isNull);
    expect(requests, hasLength(1));
    pending.complete(translated('Translated text', 'en'));
    await tester.pumpAndSettle();
    expect(find.text('Translated text'), findsOneWidget);
  });
  testWidgets('locale change ignores the previous language response',
      (tester) async {
    final first = Completer<http.Response>();
    handler = (body) => body['targetLanguage'] == 'en'
        ? first.future
        : Future.value(translated('Deutsche Übersetzung', 'de'));
    await pump(tester, const TranslatableText('Свободный текст'));
    await pump(tester, const TranslatableText('Свободный текст'),
        language: 'de');
    await tester.pumpAndSettle();
    expect(find.text('Deutsche Übersetzung'), findsOneWidget);
    first.complete(translated('Wrong late English', 'en'));
    await tester.pumpAndSettle();
    expect(find.text('Wrong late English'), findsNothing);
    expect(find.text('Deutsche Übersetzung'), findsOneWidget);
    expect(requests.map((r) => r['targetLanguage']), ['en', 'de']);
  });
  testWidgets('edited source ignores stale translation', (tester) async {
    final first = Completer<http.Response>();
    handler = (body) => body['text'] == 'First source'
        ? first.future
        : Future.value(translated('New translation', 'en'));
    await pump(tester, const TranslatableText('First source'));
    await pump(tester, const TranslatableText('Changed source'));
    await tester.pumpAndSettle();
    first.complete(translated('Old translation', 'en'));
    await tester.pumpAndSettle();
    expect(find.text('New translation'), findsOneWidget);
    expect(find.text('Old translation'), findsNothing);
  });
  testWidgets('disposed widget safely ignores delayed network response',
      (tester) async {
    final pending = Completer<http.Response>();
    handler = (_) => pending.future;
    await pump(tester, const TranslatableText('Free text'));
    await pump(tester, const SizedBox());
    pending.complete(translated('Late', 'en'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('failure retains original and retry can succeed', (tester) async {
    handler = (_) async => http.Response('private provider data', 503);
    await pump(tester, const TranslatableText('Source stays visible'));
    await tester.pumpAndSettle();
    expect(find.text('Source stays visible'), findsOneWidget);
    expect(find.textContaining('private provider data'), findsNothing);
    expect(find.text('Translate'), findsOneWidget);
    handler = (body) async =>
        translated('Retried translation', body['targetLanguage']);
    await tester.tap(find.text('Translate'));
    await tester.pumpAndSettle();
    expect(find.text('Retried translation'), findsOneWidget);
    expect(requests, hasLength(2));
  });
  testWidgets(
      'already-target text and Serbian script conversion remain displayable',
      (tester) async {
    handler = (_) async => translated('Ljubav i porodica', 'sr', source: 'sr');
    await pump(tester, const TranslatableText('Љубав и породица'),
        language: 'sr');
    await tester.pumpAndSettle();
    expect(find.text('Ljubav i porodica'), findsOneWidget);
    expect(find.text('Љубав и породица'), findsNothing);
    await tester.tap(find.byType(TextButton));
    await tester.pump();
    expect(find.text('Љубав и породица'), findsOneWidget);
  });
  testWidgets('known enum literals use bundled catalog without service',
      (tester) async {
    await pump(tester, const TranslatableText('Мужской'));
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    expect(find.text('Мужской'), findsNothing);
    expect(find.text('Male'), findsOneWidget);
    expect(find.textContaining('Google'), findsNothing);
  });
  testWidgets('parameterized literal-like user text uses dynamic service',
      (tester) async {
    await pump(tester, const TranslatableText('{count} участников'));
    await tester.pumpAndSettle();
    expect(requests.single['text'], '{count} участников');
    expect(tester.takeException(), isNull);
  });
  testWidgets('empty and whitespace-only content has no request or link',
      (tester) async {
    await pump(
        tester,
        const Column(
            children: [TranslatableText(''), TranslatableText(' \n ')]));
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    expect(find.byType(TextButton), findsNothing);
  });
  testWidgets('unconfigured service explicitly keeps original', (tester) async {
    service.dispose();
    service = ContentTranslationService(
        endpoint: null,
        currentUserId: () => 'viewer',
        idToken: () async => 'fixture');
    await pump(tester, const TranslatableText('Unconfigured original'));
    await tester.pumpAndSettle();
    expect(find.text('Unconfigured original'), findsOneWidget);
    expect(find.text('Show original'), findsNothing);
    expect(find.text('Translate'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
