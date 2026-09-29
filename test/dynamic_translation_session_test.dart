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

const _source = 'Личное сообщение прежнего аккаунта';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final catalogs = {
    for (final code in ['en', 'de'])
      code: ClrsLocalizations(
          Locale(code),
          jsonDecode(File('assets/l10n/$code.json').readAsStringSync())
              as Map<String, dynamic>),
  };
  late ContentTranslationService service;
  String? uid;
  final requests = <Map<String, dynamic>>[];
  setUp(() {
    uid = 'account-a';
    requests.clear();
    service = ContentTranslationService(
      endpoint: Uri.parse('https://translation.example.test/translate'),
      currentUserId: () => uid,
      idToken: () async => 'token-$uid',
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        requests
            .add({...body, 'authorization': request.headers['authorization']});
        return http.Response(
            jsonEncode({
              'translatedText': '[${body['targetLanguage']}] ${body['text']}',
              'detectedSourceLanguage': 'ru',
              'targetLanguage': body['targetLanguage'],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      }),
    );
  });
  tearDown(() => service.dispose());

  Future<void> pump(WidgetTester tester,
      {String code = 'en',
      bool automatic = false,
      Key textKey = const ValueKey('same-opened-text')}) async {
    await tester.pumpWidget(ContentTranslationScope(
      service: service,
      child: MaterialApp(
        locale: Locale(code),
        supportedLocales: const [Locale('en'), Locale('de')],
        localizationsDelegates: [
          _CatalogDelegate(catalogs),
          ...ClrsLocalizations.delegates.skip(1),
        ],
        home: Scaffold(
            body: TranslatableText(_source,
                key: textKey, autoTranslate: automatic, showAction: true)),
      ),
    ));
    await tester.pumpAndSettle();
  }

  for (final automatic in [false, true]) {
    testWidgets(
        'A to B invalidates completed translation and stays locked after locale change auto=$automatic',
        (tester) async {
      await pump(tester, automatic: automatic);
      final openedState = tester.state(find.byType(TranslatableText));
      if (!automatic) {
        expect(requests, isEmpty);
        await tester.tap(find.text('Translate'));
        await tester.pumpAndSettle();
      }
      expect(find.text('[en] $_source'), findsOneWidget);
      expect(requests, hasLength(1));
      expect(requests.single['authorization'], 'Bearer token-account-a');

      uid = 'account-b';
      service.clear(); // Same invalidation fired by the MyApp auth UID hook.
      await tester.pumpAndSettle();
      expect(find.text('[en] $_source'), findsNothing);
      expect(find.text(_source), findsOneWidget);
      expect(
          find.text(
              catalogs['en']!.text('Сеанс изменился. Откройте текст заново.')),
          findsOneWidget);
      expect(
          tester.widget<TextButton>(find.byType(TextButton)).onPressed, isNull);
      await tester.tap(find.text('Translate'));
      await tester.pumpAndSettle();
      expect(requests, hasLength(1));

      // Keep the same State: locale refresh must not rebind private source text
      // to the new account or schedule automatic work on the next frame.
      await pump(tester, code: 'de', automatic: automatic);
      expect(
          identical(tester.state(find.byType(TranslatableText)), openedState),
          isTrue);
      expect(
          find.text(
              catalogs['de']!.text('Сеанс изменился. Откройте текст заново.')),
          findsOneWidget);
      expect(
          tester.widget<TextButton>(find.byType(TextButton)).onPressed, isNull);
      await tester.tap(find.text('Übersetzen'));
      await tester.pumpAndSettle();
      expect(requests, hasLength(1));
      expect(find.text('[de] $_source'), findsNothing);

      // A genuinely reopened field creates a new owner scope and can translate
      // under B. Invalidation must not permanently disable the shared service.
      await pump(tester,
          code: 'de',
          automatic: automatic,
          textKey: const ValueKey('reopened-under-b'));
      if (!automatic) {
        await tester.tap(find.text('Übersetzen'));
        await tester.pumpAndSettle();
      }
      expect(requests, hasLength(2));
      expect(requests.last['authorization'], 'Bearer token-account-b');
      expect(requests.last['targetLanguage'], 'de');
      expect(find.text('[de] $_source'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Logout followed by login cannot unlock the old mounted field',
      (tester) async {
    await pump(tester);
    await tester.tap(find.text('Translate'));
    await tester.pumpAndSettle();
    uid = null;
    service.clear();
    await tester.pumpAndSettle();
    uid = 'account-b';
    service.clear();
    await tester.pumpAndSettle();
    await pump(tester, code: 'de');
    expect(find.text(_source), findsOneWidget);
    expect(
        tester.widget<TextButton>(find.byType(TextButton)).onPressed, isNull);
    await tester.tap(find.text('Übersetzen'));
    await tester.pumpAndSettle();
    expect(requests, hasLength(1));
    expect(tester.takeException(), isNull);
  });
}

class _CatalogDelegate extends LocalizationsDelegate<ClrsLocalizations> {
  const _CatalogDelegate(this.catalogs);
  final Map<String, ClrsLocalizations> catalogs;
  @override
  bool isSupported(Locale locale) => catalogs.containsKey(locale.languageCode);
  @override
  Future<ClrsLocalizations> load(Locale locale) =>
      SynchronousFuture(catalogs[locale.languageCode]!);
  @override
  bool shouldReload(_CatalogDelegate old) => old.catalogs != catalogs;
}
