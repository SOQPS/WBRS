import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/presentation/screens/test/red_group.dart';
import 'package:wbrs/presentation/screens/test/green_group.dart';
import 'package:wbrs/presentation/screens/test/white_group.dart';
import 'package:wbrs/presentation/screens/test/orange_group.dart';
import 'package:wbrs/shared/lrs_theme.dart';

class _QuestionLocale extends LocalizationsDelegate<ClrsLocalizations> {
  const _QuestionLocale(this.messages);
  final Map<String, dynamic> messages;
  @override
  bool isSupported(Locale locale) => true;
  @override
  Future<ClrsLocalizations> load(Locale locale) =>
      SynchronousFuture(ClrsLocalizations(locale, messages));
  @override
  bool shouldReload(_QuestionLocale old) => old.messages != messages;
}

void main() {
  late Map<String, dynamic> german;
  setUpAll(() {
    final finalFile = File('tool/l10n_segments/test_questions.json');
    final file = finalFile.existsSync()
        ? finalFile
        : File('tool/l10n_segments/test_questions.draft.json');
    german = Map<String, dynamic>.from(
        (jsonDecode(file.readAsStringSync()) as Map)['de'] as Map);
  });
  test('Every supported locale has all 80 independently translated statements',
      () {
    final values = Map<String, dynamic>.from(jsonDecode(
            File('tool/l10n_segments/test_questions.json').readAsStringSync())
        as Map);
    expect(values.keys.toSet(), ClrsLocalizations.codes.toSet());
    final russian = Map<String, dynamic>.from(values['ru'] as Map);
    final english = Map<String, dynamic>.from(values['en'] as Map);
    expect(russian.length, 80);
    for (final code in ClrsLocalizations.codes) {
      final translated = Map<String, dynamic>.from(values[code] as Map);
      expect(translated.keys.toSet(), russian.keys.toSet(), reason: code);
      final locale = ClrsLocalizations(Locale(code), translated);
      for (final key in russian.keys) {
        expect(translated[key], isA<String>(), reason: '$code/$key');
        expect((translated[key] as String).trim(), isNotEmpty,
            reason: '$code/$key');
        expect(locale.text(key), translated[key]);
        if (code != 'ru') {
          expect(translated[key], isNot(key),
              reason: 'Russian fallback in $code');
        }
        if (code != 'ru' && code != 'en') {
          expect(translated[key], isNot(english[key]),
              reason: 'English fallback in $code');
        }
      }
    }
  });
  for (final screen in <Widget>[
    const FirstGroupRed(),
    const GreenPage(),
    const WhitePage(),
    const OrangePage()
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
          '${screen.runtimeType} German statements remain usable at 320px scale $scale',
          (tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(MaterialApp(
            theme: LrsTheme.theme,
            localizationsDelegates: [_QuestionLocale(german)],
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!),
            home: screen));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final scrollable = find.byType(SingleChildScrollView).first;
        await tester.drag(scrollable, const Offset(0, -1200));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets('Question controls expose their action to screen readers',
      (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(MaterialApp(
          theme: LrsTheme.theme,
          localizationsDelegates: [
            _QuestionLocale({
              ...german,
              'Выбрать': 'Auswählen',
              'Снять выбор': 'Auswahl aufheben'
            })
          ],
          home: const FirstGroupRed()));
      await tester.pumpAndSettle();
      final control = find.byKey(const ValueKey('question-0'));
      await tester.ensureVisible(control);
      await tester.pumpAndSettle();
      expect(tester.getSemantics(control).label, contains('Auswählen'));
      await tester.tap(control);
      await tester.pumpAndSettle();
      expect(tester.getSemantics(control).label, contains('Auswahl aufheben'));
    } finally {
      semantics.dispose();
    }
  });
  testWidgets(
      'Localized test keeps the 20-statement threshold and toggles each answer once',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        theme: LrsTheme.theme,
        localizationsDelegates: [_QuestionLocale(german)],
        home: const FirstGroupRed()));
    await tester.pumpAndSettle();
    expect(find.text(german['неусидчивы, суетливы'] as String), findsOneWidget);
    for (var i = 0; i < 19; i++) {
      tester
          .widget<IconButton>(find.byKey(ValueKey('question-$i')))
          .onPressed!();
      await tester.pump();
    }
    expect(find.text('Завершить тест'), findsNothing);
    tester
        .widget<IconButton>(find.byKey(const ValueKey('question-19')))
        .onPressed!();
    await tester.pump();
    expect(find.text('Завершить тест'), findsOneWidget);
    tester
        .widget<IconButton>(find.byKey(const ValueKey('question-19')))
        .onPressed!();
    await tester.pump();
    expect(find.text('Завершить тест'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
