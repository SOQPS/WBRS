import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/presentation/screens/list_of_meets/meetings.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/lrs_theme.dart';

class _CatalogDelegate extends LocalizationsDelegate<ClrsLocalizations> {
  const _CatalogDelegate(this.catalogs);
  final Map<String, Map<String, dynamic>> catalogs;

  @override
  bool isSupported(Locale locale) => catalogs.containsKey(locale.languageCode);

  @override
  Future<ClrsLocalizations> load(Locale locale) => SynchronousFuture(
      ClrsLocalizations(locale, catalogs[locale.languageCode]!));

  @override
  bool shouldReload(_CatalogDelegate old) => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const steps = [
    'Вы один(одна) и приглашаете кого-то? Создайте индивидуальную встречу: куда идёте и что будете делать.',
    'Вас двое? Один создаёт коллективную встречу. Укажите, кого ждёте и что предлагаете.',
    'Компания планирует что-то масштабное? Один создаёт коллективную встречу и кратко описывает предложение.',
    'При вступлении во встречу создателю придёт уведомление.',
  ];
  final catalogs = <String, Map<String, dynamic>>{
    for (final code in ClrsLocalizations.codes)
      code: Map<String, dynamic>.from(
          jsonDecode(File('assets/l10n/$code.json').readAsStringSync()) as Map),
  };

  setUpAll(() async {
    for (final font in {
      'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
      'Lato': 'assets/fonts/Lato-Regular.ttf',
    }.entries) {
      await (FontLoader(font.key)..addFont(rootBundle.load(font.value))).load();
    }
  });

  Future<void> pumpGuide(WidgetTester tester, String code,
      {double textScale = 1}) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      theme: LrsTheme.theme,
      locale: ClrsLocalizations.localeFor(code),
      supportedLocales: ClrsLocalizations.supportedLocales,
      localizationsDelegates: [
        _CatalogDelegate(catalogs),
        ...ClrsLocalizations.delegates.skip(1),
      ],
      // A normal Android status bar and three-button navigation bar leave
      // less space than a frameless 360x640 preview.
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: const EdgeInsets.only(top: 24, bottom: 48),
            viewPadding: const EdgeInsets.only(top: 24, bottom: 48),
            textScaler: TextScaler.linear(textScale),
          ),
          child: child!),
      home: Builder(
          builder: (context) => Scaffold(
              body: TextButton(
                  key: const ValueKey('open-guide'),
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const MeetingGuidePage())),
                  child: const Text('Open guide')))),
    ));
    await tester.tap(find.byKey(const ValueKey('open-guide')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '$code initial layout');
  }

  Finder guideScroll() => find.descendant(
      of: find.byKey(const ValueKey('meeting-guide-scroll')),
      matching: find.byType(Scrollable));

  for (final code in ClrsLocalizations.codes) {
    testWidgets('meeting guide $code fits 360x640 without scrolling',
        (tester) async {
      await pumpGuide(tester, code);
      final position = tester.state<ScrollableState>(guideScroll()).position;
      expect(position.maxScrollExtent, 0,
          reason: '$code: all four steps and Done must fit on one screen');
      expect(find.byType(ClrsPanel), findsNWidgets(4));

      for (final key in steps) {
        final text = find.text(catalogs[code]![key]);
        expect(text.hitTestable(), findsOneWidget,
            reason: '$code: each complete instruction must be visible');
        expect(
            tester.widget<Text>(text).style!.fontSize, greaterThanOrEqualTo(16),
            reason: 'Fit the text without shrinking the normal body font');
        expect(tester.renderObject<RenderParagraph>(text).didExceedMaxLines,
            isFalse);
      }

      final viewport =
          tester.getRect(find.byKey(const ValueKey('meeting-guide-scroll')));
      for (final panel in find.byType(ClrsPanel).evaluate()) {
        final bounds = tester.getRect(find.byWidget(panel.widget));
        expect(bounds.top, greaterThanOrEqualTo(viewport.top));
        expect(bounds.bottom, lessThanOrEqualTo(viewport.bottom));
      }
      final done =
          find.widgetWithText(ElevatedButton, catalogs[code]!['Понятно']);
      expect(done.hitTestable(), findsOneWidget);
      expect(tester.getRect(done).bottom, lessThanOrEqualTo(viewport.bottom));
      await tester.tap(done);
      await tester.pumpAndSettle();
      expect(find.byType(MeetingGuidePage), findsNothing);
      expect(find.byKey(const ValueKey('open-guide')), findsOneWidget);
      expect(tester.takeException(), isNull, reason: '$code Done navigation');
    });
  }

  testWidgets('meeting guide keeps full text and Done reachable at 200%',
      (tester) async {
    await pumpGuide(tester, 'ru', textScale: 2);
    final scroll = guideScroll();
    expect(tester.state<ScrollableState>(scroll).position.maxScrollExtent,
        greaterThan(0));
    for (final key in steps) {
      final text = find.text(catalogs['ru']![key]);
      await tester.scrollUntilVisible(text, 180, scrollable: scroll);
      await tester.ensureVisible(text);
      await tester.pumpAndSettle();
      expect(text.hitTestable(), findsOneWidget);
      expect(tester.renderObject<RenderParagraph>(text).didExceedMaxLines,
          isFalse);
      expect(tester.takeException(), isNull);
    }
    final done = find.widgetWithText(ElevatedButton, 'Понятно');
    await tester.scrollUntilVisible(done, 180, scrollable: scroll);
    await tester.pumpAndSettle();
    expect(done.hitTestable(), findsOneWidget);
    await tester.tap(done);
    await tester.pumpAndSettle();
    expect(find.byType(MeetingGuidePage), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
