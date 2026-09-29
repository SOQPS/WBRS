import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/app/pages/filter_pages/filter_page.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/shared/geo_catalog.dart';
import 'support/layout_firebase_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
    await GeoCatalog.load();
  });
  late LayoutAuth auth;
  setUp(() {
    auth = LayoutAuth();
    firebaseAuth = auth;
    ageStart = 20;
    ageEnd = 60;
    filtrPol = '';
    filterByGroup = false;
    filterCountry.clear();
    filterRegion.clear();
    filterCity.clear();
  });
  Future<void> pump(WidgetTester tester, FilterPage2 filter) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        theme: LrsTheme.theme,
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!),
        home: Scaffold(body: ListView(children: [filter]))));
    await tester.pumpAndSettle();
  }

  Future<void> reach(WidgetTester tester, String label) async {
    await tester.scrollUntilVisible(find.text(label), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(label));
    await tester.pumpAndSettle();
    expect(find.text(label).hitTestable(), findsOneWidget);
  }

  testWidgets('Only All chip has a legible translucent selected state',
      (tester) async {
    await pump(tester, const FilterPage2(initiallyExpanded: true));
    var all = tester.widget<ChoiceChip>(find.byType(ChoiceChip).first);
    expect(all.selected, isTrue);
    expect(all.labelStyle?.color, LrsTheme.peachLight);
    expect(all.selectedColor, const Color(0x8831241D));
    await tester.tap(find.text('Мужчины'));
    await tester.pump();
    all = tester.widget<ChoiceChip>(find.byType(ChoiceChip).first);
    expect(all.selected, isFalse);
    expect(all.labelStyle?.color, LrsTheme.text);
    final men = tester.widget<ChoiceChip>(find.byType(ChoiceChip).at(1));
    expect(men.selected, isTrue);
    expect(men.labelStyle?.color, LrsTheme.peachLight);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Failed apply keeps live filters unchanged and draft editable at 320/2x',
      (tester) async {
    await pump(
        tester,
        FilterPage2(
            initiallyExpanded: true,
            loadGroup: () async => throw StateError('offline')));
    await tester.tap(find.text('Мужчины'));
    await tester.pump();
    expect(filtrPol, '');
    await reach(tester, 'Применить');
    await tester.tap(find.text('Применить'));
    await tester.pumpAndSettle();
    expect(filtrPol, '');
    expect(ageStart, 20);
    expect(
        find.text(
            'Не удалось загрузить профиль. Проверьте соединение и повторите попытку.'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'One pending apply ignores repeated taps and commits all filters once',
      (tester) async {
    final gate = Completer<String>();
    var reads = 0, applied = 0;
    await pump(
        tester,
        FilterPage2(
            initiallyExpanded: true,
            loadGroup: () {
              reads++;
              return gate.future;
            },
            onApplied: (_) => applied++));
    await tester.tap(find.text('Женщины'));
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, '45');
    await reach(tester, 'Применить');
    await tester.tap(find.text('Применить'));
    await tester.pump();
    await tester.tap(find.text('Применить'));
    await tester.pump();
    expect(reads, 1);
    expect(filtrPol, '');
    gate.complete('красная');
    await tester.pumpAndSettle();
    expect(applied, 1);
    expect(filtrPol, 'ж');
    expect(ageStart, 45);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Pending filter read after disposal cannot change active filters',
      (tester) async {
    final gate = Completer<String>();
    var applied = 0;
    await pump(
        tester,
        FilterPage2(
            initiallyExpanded: true,
            loadGroup: () => gate.future,
            onApplied: (_) => applied++));
    await tester.tap(find.text('Женщины'));
    await tester.pump();
    await reach(tester, 'Применить');
    await tester.tap(find.text('Применить'));
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    gate.complete('красная');
    await tester.pumpAndSettle();
    expect(filtrPol, '');
    expect(applied, 0);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'Account change prevents filter publication and reset failure keeps selection',
      (tester) async {
    final gate = Completer<String>();
    await pump(tester,
        FilterPage2(initiallyExpanded: true, loadGroup: () => gate.future));
    await reach(tester, 'Сбросить');
    await tester.tap(find.text('Сбросить'));
    await tester.pump();
    auth.user = null;
    gate.complete('красная');
    await tester.pumpAndSettle();
    expect(ageStart, 20);
    expect(ageEnd, 60);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Timed out read shows retry and preserves draft', (tester) async {
    final gate = Completer<String>();
    await pump(tester,
        FilterPage2(initiallyExpanded: true, loadGroup: () => gate.future));
    await reach(tester, 'Применить');
    await tester.tap(find.text('Применить'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 16));
    await tester.pump();
    expect(
        find.text(
            'Не удалось загрузить профиль. Проверьте соединение и повторите попытку.'),
        findsOneWidget);
    expect(ageStart, 20);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    gate.complete('красная');
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
