import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/service/content_translation_service.dart';
import 'package:wbrs/shared/translatable_text.dart';

class _CatalogDelegate extends LocalizationsDelegate<ClrsLocalizations> {
  const _CatalogDelegate();
  @override
  bool isSupported(Locale locale) =>
      const {'ru', 'en'}.contains(locale.languageCode);
  @override
  Future<ClrsLocalizations> load(Locale locale) =>
      SynchronousFuture(ClrsLocalizations(locale, const {}));
  @override
  bool shouldReload(_CatalogDelegate old) => false;
}

void main() {
  testWidgets('same-language content has no translate action or provider call',
      (tester) async {
    final service = ContentTranslationService(
      endpoint: null,
      currentUserId: () => 'viewer',
      idToken: () async => null,
    );
    addTearDown(service.dispose);

    Future<void> show(String language) async {
      await tester.pumpWidget(ContentTranslationScope(
        service: service,
        child: MaterialApp(
          locale: Locale(language),
          supportedLocales: ClrsLocalizations.supportedLocales,
          localizationsDelegates: const [
            _CatalogDelegate(),
            ...ClrsLocalizations.delegates,
          ],
          home: const Scaffold(
              body: TranslatableText('Русский текст',
                  sourceLanguage: 'ru', autoTranslate: false)),
        ),
      ));
      await tester.pumpAndSettle();
    }

    await show('ru');
    expect(find.text('Русский текст'), findsOneWidget);
    expect(find.byType(TextButton), findsNothing);
    await show('en');
    expect(find.byType(TextButton), findsOneWidget);
  });
}
