import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/localization/clrs_localizations.dart';

void main() {
  const socialKeys = <String>[
    'Входящие',
    'Исходящие',
    'Отправленных заявок нет',
    'Отозвать заявку',
    'Уже в друзьях',
    'Заявки на роли',
    'Авторы',
    'Модераторы',
    'Заявка одобрена',
    'Заявка отклонена',
    'Не удалось обработать заявку.',
    'Не удалось загрузить заявки.',
    'Отправить в чат',
    'Не удалось загрузить чаты.',
    'На моей странице',
    'Комментарий добавлен на вашу страницу',
    'Репост комментария',
    'Комментарий недоступен',
    'Поделиться',
    'Предлагаемая публикация',
    'Отправить заявку',
  ];

  test('New social actions and feedback are translated in all 23 catalogs',
      () {
    expect(ClrsLocalizations.codes, hasLength(23));
    for (final code in ClrsLocalizations.codes) {
      final catalog = jsonDecode(
        File('assets/l10n/$code.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      for (final key in socialKeys) {
        final value = catalog[key];
        expect(value, isA<String>(), reason: '$code: $key');
        expect((value as String).trim(), isNotEmpty, reason: '$code: $key');
        if (code != 'ru') {
          expect(value, isNot(key), reason: '$code: $key fell back to Russian');
        }
      }
    }
  });

  test('Serbian social labels use the selected Latin-script catalog', () {
    final catalog = jsonDecode(File('assets/l10n/sr.json').readAsStringSync())
        as Map<String, dynamic>;
    for (final key in socialKeys) {
      expect(RegExp(r'[А-Яа-яЁё]').hasMatch(catalog[key] as String), isFalse,
          reason: key);
    }
  });
}
