import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/app/pages/policy/rules.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/shared/rules_content.dart';

class _RulesDelegate extends LocalizationsDelegate<ClrsLocalizations> {
  const _RulesDelegate(this.messages);
  final Map<String, Map<String, dynamic>> messages;
  @override
  bool isSupported(Locale locale) => messages.containsKey(locale.languageCode);
  @override
  Future<ClrsLocalizations> load(Locale locale) => SynchronousFuture(
      ClrsLocalizations(locale, messages[locale.languageCode]!));
  @override
  bool shouldReload(_RulesDelegate old) => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final catalogs = <String, Map<String, dynamic>>{
    for (final code in ClrsLocalizations.codes)
      code: Map<String, dynamic>.from(
          jsonDecode(File('assets/l10n/$code.json').readAsStringSync()) as Map),
  };
  final keys = [
    for (final chapter in rulesChapters) ...[chapter.title, ...chapter.items],
    rulesThanks,
  ];
  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
    for (final font in {
      'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
      'Lato': 'assets/fonts/Lato-Regular.ttf',
      'CormorantGaramond': 'assets/fonts/CormorantGaramond-Variable.ttf',
      'Caveat': 'assets/fonts/Caveat-Variable.ttf',
    }.entries) {
      await (FontLoader(font.key)..addFont(rootBundle.load(font.value))).load();
    }
  });

  test('All 23 original numbered instructions and thanks remain complete', () {
    final source = File('assets/rules.txt').readAsStringSync();
    final paragraphs = RegExp(r'^\d+\.\s*(.+)$', multiLine: true)
        .allMatches(source)
        .map((m) => m.group(1)!.trim().replaceFirst('и d теле', 'и теле'))
        .toList();
    expect(rulesChapters.map((chapter) => chapter.items.length), [5, 6, 12]);
    expect(rulesChapters.expand((chapter) => chapter.items), paragraphs);
    expect(paragraphs, hasLength(23));
    expect(source, contains(rulesThanks));
    expect(keys.toSet(), hasLength(27));
  });

  test(
      'All 23 language catalogs contain the full rules without Russian fallback',
      () {
    expect(catalogs, hasLength(23));
    for (final entry in catalogs.entries) {
      for (final key in keys) {
        final translation = entry.value[key];
        expect(translation, isA<String>(), reason: '${entry.key}: $key');
        expect((translation as String).trim(), isNotEmpty);
        if (entry.key != 'ru') {
          expect(translation, isNot(key), reason: '${entry.key}: $key');
        } else {
          expect(translation, key);
        }
        if (key.contains('supp.lrs@ya.ru')) {
          expect(translation, contains('supp.lrs@ya.ru'), reason: entry.key);
        }
      }
    }
    for (final key in keys) {
      expect(catalogs['sr']![key], isNot(matches(RegExp(r'[А-Яа-я]'))),
          reason: 'Serbian locale is explicitly Latn');
    }
  });

  for (final code in ['ru', 'de', 'el', 'is']) {
    final scale = code == 'ru' ? 1.0 : 2.0;
    for (final size in [const Size(320, 640), const Size(640, 320)]) {
      testWidgets(
          'Full $code rules scroll at ${size.width}×${size.height}, ${scale}x',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final captureKey = GlobalKey();
        await tester.pumpWidget(RepaintBoundary(
            key: captureKey,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: LrsTheme.theme,
              locale: ClrsLocalizations.localeFor(code),
              supportedLocales: ClrsLocalizations.supportedLocales,
              localizationsDelegates: [
                _RulesDelegate(catalogs),
                ...ClrsLocalizations.delegates.skip(1),
              ],
              builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!),
              home: const Rule(),
            )));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (const bool.fromEnvironment('CLRS_CAPTURE_RULES')) {
          await tester.runAsync(() => precacheImage(
              const AssetImage('assets/final_design/family_right.png'),
              tester.element(find.byType(Rule))));
          await tester.pumpAndSettle();
          final boundary = captureKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final image = await boundary.toImage();
            final bytes =
                await image.toByteData(format: ui.ImageByteFormat.png);
            await File(
                    'verification/stage2/rules_${code}_${size.width.toInt()}_${scale.toInt()}x.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        // Every complete paragraph is a real screen element, not a
        // shortened preview or an image of text. Parent scroll reaches all of it.
        for (final key in keys) {
          expect(find.text(catalogs[code]![key] as String), findsOneWidget);
        }
        final last = find.text(catalogs[code]![rulesChapters.last.items.last]);
        await tester.ensureVisible(last);
        await tester.pumpAndSettle();
        expect(last.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        // Scroll back to the first paragraph; the long document remains usable.
        final first =
            find.text(catalogs[code]![rulesChapters.first.items.first]);
        await tester.ensureVisible(first);
        await tester.pumpAndSettle();
        expect(first.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }
}
