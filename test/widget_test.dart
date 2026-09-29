import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/shared/group_badge.dart';
import 'package:wbrs/shared/geo_catalog.dart';
import 'package:wbrs/core/utils/compatibility.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Mixed group ring preserves both colors and their order',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: GroupBadge(group: 'красно-белая'))));
    expect(groupColors('красно-белая'),
        [const Color(0xFFD75247), const Color(0xFFF2EEE7)]);
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: GroupBadge(group: 'бело-красная'))));
    expect(groupColors('бело-красная'),
        [const Color(0xFFF2EEE7), const Color(0xFFD75247)]);
    expect(find.byIcon(Icons.check_rounded), findsNothing);
  });
  testWidgets('All sixteen groups render a ring, unknown group renders none',
      (tester) async {
    const bases = ['красная', 'синяя', 'белая', 'коричневая'];
    const stems = ['красно', 'сине', 'бело', 'коричнево'];
    for (var a = 0; a < 4; a++) {
      for (var b = 0; b < 4; b++) {
        final group = a == b ? bases[a] : '${stems[a]}-${bases[b]}';
        await tester.pumpWidget(
            MaterialApp(home: Scaffold(body: GroupBadge(group: group))));
        expect(find.byType(GroupRing), findsOneWidget);
        expect(groupColors(group).length, a == b ? 1 : 2);
      }
    }
    await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: GroupBadge(group: ''))));
    expect(find.byType(GroupRing), findsNothing);
    expect(groupColors('unknown'), isEmpty);
  });
  test('Ring paints 3/4 primary and lower-right 1/4 secondary', () async {
    const primary = Color(0xFFED2030), secondary = Color(0xFF2040ED);
    final recorder = ui.PictureRecorder();
    const GroupRingPainter([primary, secondary], strokeWidth: 4)
        .paint(Canvas(recorder), const Size(40, 40));
    final image = await recorder.endRecording().toImage(40, 40);
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!
        .buffer
        .asUint8List();
    Color pixel(int x, int y) {
      final offset = (y * 40 + x) * 4;
      return Color.fromARGB(bytes[offset + 3], bytes[offset], bytes[offset + 1],
          bytes[offset + 2]);
    }

    expect(pixel(33, 33), secondary);
    expect(pixel(33, 7), primary);
    expect(pixel(7, 7), primary);
    expect(pixel(7, 33), primary);
  });
  test('All 23 catalogs provide separable names for all compound groups', () {
    const bases = ['красная', 'синяя', 'белая', 'коричневая'];
    const stems = ['красно', 'сине', 'бело', 'коричнево'];
    for (final file in Directory('assets/l10n').listSync().whereType<File>()) {
      if (!file.path.endsWith('.json')) continue;
      final catalog =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      for (final label in [
        'Моя группа — {group}',
        'Его группа — {group}',
        'Её группа — {group}',
        'Группа: {group}'
      ]) {
        expect((catalog[label] as String).split('{group}').length, 2,
            reason: '${file.path}: $label');
      }
      for (var a = 0; a < 4; a++) {
        for (var b = 0; b < 4; b++) {
          if (a == b) continue;
          final group = '${stems[a]}-${bases[b]}';
          expect((catalog[group] as String).split(RegExp(r'[-–]')).length, 2,
              reason: '${file.path}: $group');
        }
      }
    }
  });
  test('Client catalog complete with selectable regions', () async {
    final countries = await GeoCatalog.load();
    expect(countries.length, 56);
    expect(countries.map((c) => c.code).toSet().length, 56);
    expect(countries.map((c) => c.languageGroup).toSet().length, 23);
    expect(countries.every((c) => c.regions.isNotEmpty), isTrue);
    expect([
      for (var i = 1; i <= 4; i++)
        countries.where((c) => c.segment == 'T-$i').length
    ], [
      13,
      12,
      15,
      16
    ]);
    expect(GeoCatalog.byCode(countries, 'BE')!.languageGroup, 'de');
    expect(GeoCatalog.byCode(countries, 'IL')!.languageGroup, 'ru');
    expect(GeoCatalog.byCode(countries, 'AD')!.languageGroup, 'es');
    expect(GeoCatalog.byCode(countries, 'HR')!.languageGroup, 'sr');
  });
  test('Unknown groups never claim compatibility', () {
    expect(getListOfGroup(''), isEmpty);
    expect(getListOfGroup('unknown'), isEmpty);
    expect(getListOfGroup('красная'), contains('синяя'));
    expect(getListOfGroup('красная'), isNot(contains('красная')));
  });
}
