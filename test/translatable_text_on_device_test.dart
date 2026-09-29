import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/service/content_translation_service.dart';
import 'package:wbrs/shared/translatable_text.dart';

/// UI fixtures never invoke a native plugin on the desktop test host.
class _GoogleUiFixture extends ContentTranslationService {
  _GoogleUiFixture({this.unsupported = false})
      : super(
            endpoint: null,
            currentUserId: () => 'viewer',
            idToken: () async => null);
  final bool unsupported;
  var requests = 0;

  @override
  bool get usesOnDevice => true;

  @override
  Future<ContentTranslation> translate(String text, String language) async {
    requests++;
    if (unsupported) {
      throw const ContentTranslationException(
          TranslationFailure.unsupportedLanguage);
    }
    return ContentTranslation(
        text: 'Hello from Google fixture',
        sourceLanguage: 'ru',
        targetLanguage: language,
        googlePowered: true);
  }
}

class _Catalog extends LocalizationsDelegate<ClrsLocalizations> {
  const _Catalog(this.catalog);
  final ClrsLocalizations catalog;
  @override
  bool isSupported(Locale locale) => true;
  @override
  Future<ClrsLocalizations> load(Locale locale) => SynchronousFuture(catalog);
  @override
  bool shouldReload(_Catalog old) => old.catalog.locale != catalog.locale;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _GoogleUiFixture service;
  tearDown(() => service.dispose());
  Finder badge() => find.byWidgetPredicate((widget) =>
      widget is Image &&
      widget.image is AssetImage &&
      (widget.image as AssetImage).assetName ==
          'assets/attribution/translated-by-google.png');

  Future<void> pump(WidgetTester tester,
      {String code = 'en', bool automatic = false, double scale = 1}) async {
    final catalog = ClrsLocalizations(
        ClrsLocalizations.localeFor(code),
        jsonDecode(File('assets/l10n/$code.json').readAsStringSync())
            as Map<String, dynamic>);
    await tester.pumpWidget(ContentTranslationScope(
        service: service,
        child: MaterialApp(
            locale: catalog.locale,
            supportedLocales: ClrsLocalizations.supportedLocales,
            localizationsDelegates: [
              _Catalog(catalog),
              ...ClrsLocalizations.delegates.skip(1),
            ],
            home: Scaffold(
                backgroundColor: const Color(0xff302110),
                body: SingleChildScrollView(
                    child: MediaQuery(
                        data: MediaQueryData(
                            textScaler: TextScaler.linear(scale)),
                        child: SizedBox(
                            width: 160,
                            child: TranslatableText('Русский свободный текст',
                                autoTranslate: automatic))))))));
    await tester.pumpAndSettle();
  }

  testWidgets('Google action and badge preserve original toggling',
      (tester) async {
    service = _GoogleUiFixture();
    await pump(tester);
    expect(find.text('Translate with Google'), findsOneWidget);
    expect(badge(), findsNothing);
    await tester.tap(find.text('Translate with Google'));
    await tester.pumpAndSettle();
    expect(find.text('Hello from Google fixture'), findsOneWidget);
    expect(badge(), findsOneWidget);
    await tester.tap(find.text('Show original'));
    await tester.pumpAndSettle();
    expect(find.text('Русский свободный текст'), findsOneWidget);
    expect(badge(), findsNothing);
    await tester.tap(find.text('Show translation'));
    await tester.pumpAndSettle();
    expect(badge(), findsOneWidget);
    expect(service.requests, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Google attribution fits 160dp at text scale 2', (tester) async {
    service = _GoogleUiFixture();
    await pump(tester, automatic: true, scale: 2);
    expect(badge(), findsOneWidget);
    expect(tester.getSize(badge()).width, lessThanOrEqualTo(160));
    expect(tester.getSize(badge()).height, greaterThanOrEqualTo(16));
    expect(find.text('Show original'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Serbian rejection is localized and keeps original without badge',
      (tester) async {
    service = _GoogleUiFixture(unsupported: true);
    await pump(tester, code: 'sr', automatic: true);
    expect(find.text('Русский свободный текст'), findsOneWidget);
    expect(find.text('Prevod za ovaj jezik nije dostupan.'), findsOneWidget);
    expect(badge(), findsNothing);
    expect(
        tester.widget<TextButton>(find.byType(TextButton)).onPressed, isNull);
    expect(service.requests, 1);
    expect(tester.takeException(), isNull);
  });
}
