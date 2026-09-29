import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/service/content_translation_service.dart';

http.Response reply(String text,
        {String target = 'en', String source = 'ru'}) =>
    http.Response(
        jsonEncode({
          'translatedText': text,
          'targetLanguage': target,
          'detectedSourceLanguage': source
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'});

Matcher fails(TranslationFailure failure) =>
    throwsA(isA<ContentTranslationException>()
        .having((e) => e.failure, 'failure', failure));

void main() {
  var uid = 'account-a';
  late List<http.Request> requests;
  late ContentTranslationService service;
  ContentTranslationService create(
      Future<http.Response> Function(http.Request) handler,
      {String? endpoint = 'https://translation.example.test/translate',
      bool local = false,
      int cache = 200,
      Duration? timeout,
      Future<String?> Function()? token}) {
    return ContentTranslationService(
      endpoint: endpoint == null ? null : Uri.parse(endpoint),
      currentUserId: () => uid.isEmpty ? null : uid,
      idToken: token ?? () async => 'fixture-token',
      allowLocalHttp: local,
      maxCacheEntries: cache,
      timeout: timeout ?? const Duration(seconds: 25),
      client: MockClient((request) {
        requests.add(request);
        return handler(request);
      }),
    );
  }

  setUp(() {
    uid = 'account-a';
    requests = [];
  });
  tearDown(() => service.dispose());

  test('authenticated POST disables redirect and preserves original', () async {
    service = create((_) async => reply('I like books.'));
    final translated = await service.translate('Мне нравятся книги.', 'en');
    expect(translated.text, 'I like books.');
    expect(translated.alreadyTarget, isFalse);
    final request = requests.single;
    expect(request.method, 'POST');
    expect(request.followRedirects, isFalse);
    expect(request.headers['authorization'], 'Bearer fixture-token');
    expect(jsonDecode(request.body),
        {'text': 'Мне нравятся книги.', 'targetLanguage': 'en'});
  });

  for (final code in ClrsLocalizations.codes) {
    test('all language targets supported: $code', () async {
      service = create((_) async => reply('Translated fixture', target: code));
      expect((await service.translate('Original fixture', code)).targetLanguage,
          code);
      expect(jsonDecode(requests.single.body)['targetLanguage'], code);
    });
  }

  test('RU/EN and RU/SR directions keep detected source and target', () async {
    const samples = <(String, String, String, String)>[
      ('Привет', 'ru', 'en', 'Hello'),
      ('Hello', 'en', 'ru', 'Привет'),
      ('Привет', 'ru', 'sr', 'Zdravo'),
      ('Zdravo', 'sr', 'ru', 'Привет'),
    ];
    service = create((request) async {
      final payload = jsonDecode(request.body) as Map<String, dynamic>;
      final sample = samples.singleWhere((entry) =>
          entry.$1 == payload['text'] && entry.$3 == payload['targetLanguage']);
      return reply(sample.$4, target: sample.$3, source: sample.$2);
    });
    for (final sample in samples) {
      final result = await service.translate(sample.$1, sample.$3);
      expect(result.text, sample.$4);
      expect(result.sourceLanguage, sample.$2);
      expect(result.targetLanguage, sample.$3);
      expect(result.alreadyTarget, isFalse);
    }
    expect(requests, hasLength(samples.length));
  });

  test('Norwegian aliases become canonical nb and source no is understood',
      () async {
    service = create((_) async => reply('Hei', target: 'nb', source: 'no'));
    expect((await service.translate('Hei', 'no-NO')).alreadyTarget, isTrue);
    expect(jsonDecode(requests.single.body)['targetLanguage'], 'nb');
  });

  for (final endpoint in <String?>[
    null,
    '',
    'http://service.test/',
    'https://user:password@service.test/',
    'https://service.test/#fragment'
  ]) {
    test('unsafe or absent endpoint is not configured: $endpoint', () async {
      service = create((_) async => reply('unused'), endpoint: endpoint);
      await expectLater(service.translate('Original', 'en'),
          fails(TranslationFailure.notConfigured));
      expect(requests, isEmpty);
    });
  }
  test('sandbox only reaches an explicitly local endpoint', () async {
    service = create((_) async => reply('unused'), local: true);
    expect(service.configured, isFalse);
    service.dispose();
    service = create((_) async => reply('ok'),
        local: true, endpoint: 'http://10.0.2.2:8787/translate');
    expect((await service.translate('source', 'en')).text, 'ok');
  });
  test('blank text and unsupported target produce no request', () async {
    service = create((_) async => reply('unused'));
    expect((await service.translate(' \n ', 'en')).text, ' \n ');
    await expectLater(
        service.translate('text', 'xx'), fails(TranslationFailure.unavailable));
    expect(requests, isEmpty);
  });
  test('signed out and absent token never send user content', () async {
    service = create((_) async => reply('unused'), token: () async => null);
    await expectLater(service.translate('private', 'en'),
        fails(TranslationFailure.signedOut));
    uid = '';
    await expectLater(service.translate('private', 'en'),
        fails(TranslationFailure.signedOut));
    expect(requests, isEmpty);
  });
  for (final item in <int, TranslationFailure>{
    401: TranslationFailure.signedOut,
    403: TranslationFailure.unavailable,
    413: TranslationFailure.tooLong,
    429: TranslationFailure.rateLimited,
    302: TranslationFailure.unavailable,
    500: TranslationFailure.unavailable,
    503: TranslationFailure.unavailable
  }.entries) {
    test('status ${item.key} preserves explicit failure', () async {
      service = create(
          (_) async => http.Response('private provider diagnostics', item.key));
      await expectLater(service.translate('private', 'en'), fails(item.value));
    });
  }
  for (final body in [
    'not-json',
    '[]',
    '{}',
    '{"translatedText":null,"targetLanguage":"en","detectedSourceLanguage":"ru"}',
    '{"translatedText":" ","targetLanguage":"en","detectedSourceLanguage":"ru"}',
    '{"translatedText":"hello","targetLanguage":"de","detectedSourceLanguage":"ru"}',
    '{"translatedText":"hello","targetLanguage":"en","detectedSourceLanguage":17}',
    '{"translatedText":"hello","targetLanguage":"en","detectedSourceLanguage":""}'
  ]) {
    test('invalid response fails closed: $body', () async {
      service = create((_) async => http.Response(body, 200));
      await expectLater(service.translate('source', 'en'),
          fails(TranslationFailure.unavailable));
    });
  }
  test('network exception is sanitised and retry is possible', () async {
    var count = 0;
    service = create((_) async {
      if (count++ == 0) throw StateError('private');
      return reply('ok');
    });
    await expectLater(service.translate('source', 'en'),
        fails(TranslationFailure.unavailable));
    expect((await service.translate('source', 'en')).text, 'ok');
    expect(requests, hasLength(2));
  });
  test('request timeout returns safely without late cache population',
      () async {
    final response = Completer<http.Response>();
    service = create((_) => response.future,
        timeout: const Duration(milliseconds: 5));
    await expectLater(service.translate('source', 'en'),
        fails(TranslationFailure.unavailable));
    response.complete(reply('late'));
    await Future<void>.delayed(Duration.zero);
    expect((await service.translate('source', 'en')).text, 'late');
    expect(requests, hasLength(2));
  });
  test('in-flight deduplication, language partition and LRU eviction',
      () async {
    service = create((r) async {
      final data = jsonDecode(r.body);
      return reply(data['text'], target: data['targetLanguage']);
    }, cache: 2);
    await Future.wait(
        [service.translate('one', 'en'), service.translate('one', 'en')]);
    expect(requests, hasLength(1));
    await service.translate('two', 'en');
    await service.translate('one', 'en'); // touch one
    await service.translate('three', 'en'); // evict two
    await service.translate('two', 'en');
    await service.translate('two', 'de');
    expect(requests, hasLength(5));
  });
  test('new account cannot read old cached result', () async {
    service = create((_) async => reply('for $uid'));
    expect((await service.translate('private', 'en')).text, 'for account-a');
    uid = 'account-b';
    expect((await service.translate('private', 'en')).text, 'for account-b');
    expect(requests, hasLength(2));
  });
  test('account switch while acquiring token sends nothing', () async {
    final token = Completer<String?>();
    service = create((_) async => reply('unused'), token: () => token.future);
    final pending = service.translate('private', 'en');
    final assertion =
        expectLater(pending, fails(TranslationFailure.sessionChanged));
    uid = 'account-b';
    token.complete('old-token');
    await assertion;
    expect(requests, isEmpty);
  });
  test('account switch takes priority over an old token failure', () async {
    final token = Completer<String?>();
    service = create((_) async => reply('unused'), token: () => token.future);
    final pending = service.translate('private', 'en');
    final assertion =
        expectLater(pending, fails(TranslationFailure.sessionChanged));
    uid = 'account-b';
    token.completeError(StateError('private token diagnostics'));
    await assertion;
    expect(requests, isEmpty);
  });
  test('account switch takes priority over an old network failure', () async {
    final response = Completer<http.Response>();
    service = create((_) => response.future);
    final pending = service.translate('private', 'en');
    final assertion =
        expectLater(pending, fails(TranslationFailure.sessionChanged));
    await Future<void>.delayed(Duration.zero);
    uid = 'account-b';
    response.completeError(StateError('private network diagnostics'));
    await assertion;
  });
  test('clear invalidates pending result even when same account logs in again',
      () async {
    final response = Completer<http.Response>();
    service = create((_) => response.future);
    final pending = service.translate('private', 'en');
    final assertion =
        expectLater(pending, fails(TranslationFailure.sessionChanged));
    await Future<void>.delayed(Duration.zero);
    service.clear();
    response.complete(reply('late private'));
    await assertion;
    expect((await service.translate('private', 'en')).text, 'late private');
    expect(requests, hasLength(2));
  });
  test('long Unicode content is bounded by codepoints and UTF-8 bytes',
      () async {
    service = create((r) async => reply(jsonDecode(r.body)['text']));
    final original = '  ${'😀' * 4990}\n\n${'Ж' * 5010}\nend  ';
    expect((await service.translate(original, 'en')).text, original);
    expect(requests.length, greaterThan(1));
    for (final request in requests) {
      final part = jsonDecode(request.body)['text'] as String;
      expect(part.runes.length, lessThanOrEqualTo(5000));
      expect(utf8.encode(part).length, lessThanOrEqualTo(9000));
      expect(part, isNot(contains('\uFFFD')));
    }
    await expectLater(service.translate('😀' * 20001, 'en'),
        fails(TranslationFailure.tooLong));
  });
  test('Cyrillic text is split below Amazon TranslateText byte limit',
      () async {
    service = create((r) async => reply(jsonDecode(r.body)['text']));
    final original = '  ${'Ж' * 4800}\n${'я' * 4700}  ';
    expect((await service.translate(original, 'en')).text, original);
    expect(requests.length, greaterThan(2));
    for (final request in requests) {
      final part = jsonDecode(request.body)['text'] as String;
      expect(utf8.encode(part).length, lessThanOrEqualTo(9000));
      expect(part.runes.length, lessThanOrEqualTo(5000));
    }
  });
  test('partial translation is not cached or returned after chunk failure',
      () async {
    var count = 0;
    service = create((r) async {
      if (++count == 2) return http.Response('', 429);
      return reply(jsonDecode(r.body)['text']);
    });
    final original = '${'a' * 4900}\n${'b' * 4900}';
    await expectLater(service.translate(original, 'en'),
        fails(TranslationFailure.rateLimited));
    expect((await service.translate(original, 'en')).text, original);
    expect(requests, hasLength(4));
  });
}
