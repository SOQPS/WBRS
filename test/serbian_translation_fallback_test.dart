import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/service/content_translation_service.dart';
import 'package:wbrs/service/on_device_content_translation.dart';

class _Device implements OnDeviceContentTranslator {
  @override
  bool get available => true;
  final models = <String>[];
  var detections = 0, translations = 0;
  String source = 'ru';
  Future<String> Function(String, String, String)? translate;
  @override
  bool supportsLanguage(String code) =>
      ClrsLocalizations.codes.contains(code) && code != 'sr';
  @override
  Future<String> identifyLanguage(String text) async {
    detections++;
    return source;
  }

  @override
  Future<void> ensureModel(String code) async => models.add(code);
  @override
  Future<String> translateText(
      String text, String source, String target) async {
    translations++;
    return translate == null
        ? 'Native $target'
        : translate!(text, source, target);
  }
}

Matcher _fails(TranslationFailure failure) =>
    throwsA(isA<ContentTranslationException>()
        .having((error) => error.failure, 'failure', failure));

http.Response _reply(String text, String target,
        {String source = 'ru', Object googlePowered = true}) =>
    http.Response(
        jsonEncode({
          'translatedText': text,
          'targetLanguage': target,
          'detectedSourceLanguage': source,
          'googlePowered': googlePowered,
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  String? uid;
  late _Device device;
  late ContentTranslationService service;
  late List<http.Request> requests;
  var tokens = 0;
  ContentTranslationService create({
    bool fallback = true,
    String? endpoint =
        'https://translation.example.invalid/translateContentGoogle',
    bool sandbox = false,
    Duration timeout = const Duration(seconds: 25),
    Future<String?> Function()? token,
    Future<http.Response> Function(http.Request)? remote,
  }) =>
      ContentTranslationService(
        endpoint: endpoint == null ? null : Uri.parse(endpoint),
        currentUserId: () => uid,
        idToken: token ??
            () async {
              tokens++;
              return 'fixture-token';
            },
        enableOnDevice: true,
        enableRemoteFallback: fallback,
        allowLocalHttp: sandbox,
        timeout: timeout,
        onDeviceTranslator: device,
        client: MockClient((request) {
          requests.add(request);
          if (remote != null) return remote(request);
          final target =
              (jsonDecode(request.body) as Map)['targetLanguage'] as String;
          return Future.value(_reply('Remote $target', target));
        }),
      );

  setUp(() {
    uid = 'account-a';
    device = _Device();
    requests = [];
    tokens = 0;
  });
  tearDown(() => service.dispose());

  test(
      'configured fallback preserves all 22 supported ML Kit targets without a paid request',
      () async {
    service = create();
    expect(service.usesOnDevice, isTrue);
    for (final target
        in ClrsLocalizations.codes.where((code) => code != 'sr')) {
      final result =
          await service.translate('Пользовательский текст $target', target);
      expect(result.targetLanguage, target);
      expect(result.text,
          target == 'ru' ? 'Пользовательский текст ru' : 'Native $target');
    }
    expect(requests, isEmpty);
    expect(tokens, 0);
    expect(device.translations, 21);
  });

  test(
      'RU to Serbian uses authenticated backend only and preserves the original body',
      () async {
    service = create();
    const original = 'Мне нравятся прогулки, книги и семейные традиции.';
    final result = await service.translate(original, 'sr');
    expect(result.text, 'Remote sr');
    expect(result.googlePowered, isTrue);
    expect(result.sourceLanguage, 'ru');
    expect(result.targetLanguage, 'sr');
    expect(requests.single.followRedirects, isFalse);
    expect(requests.single.headers['authorization'], 'Bearer fixture-token');
    expect(jsonDecode(requests.single.body),
        {'text': original, 'targetLanguage': 'sr'});
    expect(device.detections, 0);
    expect(device.models, isEmpty);
    expect(device.translations, 0);
  });

  test(
      'Serbian Latin and Cyrillic sources fall back after native detection without downloading models',
      () async {
    service = create(
        remote: (_) async => _reply('Любовь и семья', 'ru', source: 'sr'));
    for (final source in ['sr', 'sr-Latn']) {
      device.source = source;
      final result = await service.translate('Ljubav, porodica $source', 'ru');
      expect(result.text, 'Любовь и семья');
      expect(result.sourceLanguage, 'sr');
      expect(result.googlePowered, isTrue);
    }
    expect(requests, hasLength(2));
    expect(device.detections, 2);
    expect(device.models, isEmpty);
    expect(device.translations, 0);
  });

  test(
      'no endpoint preserves explicit unsupported language and never pretends to translate',
      () async {
    service = create(endpoint: null);
    await expectLater(service.translate('Привет', 'sr'),
        _fails(TranslationFailure.unsupportedLanguage));
    expect(requests, isEmpty);
    expect(device.models, isEmpty);
    expect(tokens, 0);
  });

  test('non-opt-in legacy remote mode remains compatible', () async {
    service = create(fallback: false);
    expect(service.usesOnDevice, isFalse);
    expect((await service.translate('Привет', 'en')).text, 'Remote en');
    expect(requests, hasLength(1));
    expect(device.detections, 0);
  });

  test(
      'parallel Serbian requests are shared and cached, including Google attribution',
      () async {
    final result = Completer<http.Response>();
    service = create(remote: (_) => result.future);
    final first = service.translate('Привет', 'sr');
    final second = service.translate('Привет', 'sr');
    await Future<void>.delayed(Duration.zero);
    expect(requests, hasLength(1));
    result.complete(_reply('Zdravo', 'sr'));
    for (final value in await Future.wait([first, second])) {
      expect(value.text, 'Zdravo');
      expect(value.googlePowered, isTrue);
    }
    expect((await service.translate('Привет', 'sr')).googlePowered, isTrue);
    expect(requests, hasLength(1));
    uid = 'account-b';
    expect((await service.translate('Привет', 'sr')).text, 'Zdravo');
    expect(requests, hasLength(2));
  });

  test(
      'account switch during fallback never returns or caches the old account result',
      () async {
    final old = Completer<http.Response>();
    service = create(
        remote: (_) => requests.length == 1
            ? old.future
            : Future.value(_reply('New account', 'sr')));
    final pending = service.translate('Привет', 'sr');
    final rejected =
        expectLater(pending, _fails(TranslationFailure.sessionChanged));
    await Future<void>.delayed(Duration.zero);
    uid = 'account-b';
    old.complete(_reply('Old account', 'sr'));
    await rejected;
    expect((await service.translate('Привет', 'sr')).text, 'New account');
    expect(requests, hasLength(2));
  });

  test('clear invalidates a late result even if the same UID logs back in',
      () async {
    final old = Completer<http.Response>();
    service = create(
        remote: (_) => requests.length == 1
            ? old.future
            : Future.value(_reply('New session', 'sr')));
    final pending = service.translate('Привет', 'sr');
    final rejected =
        expectLater(pending, _fails(TranslationFailure.sessionChanged));
    await Future<void>.delayed(Duration.zero);
    service.clear();
    old.complete(_reply('Old session', 'sr'));
    await rejected;
    expect((await service.translate('Привет', 'sr')).text, 'New session');
  });

  test(
      'account switch while obtaining token stops the remote request before send',
      () async {
    final token = Completer<String?>();
    service = create(token: () => token.future);
    final pending = service.translate('Привет', 'sr');
    final rejected =
        expectLater(pending, _fails(TranslationFailure.sessionChanged));
    await Future<void>.delayed(Duration.zero);
    uid = 'account-b';
    token.complete('old-account-token');
    await rejected;
    expect(requests, isEmpty);
  });

  test(
      'offline fallback keeps an explicit retryable error without native substitution',
      () async {
    service = create(
        remote: (_) async =>
            throw const SocketException('private text and diagnostics'));
    await expectLater(service.translate('Привет', 'sr'),
        _fails(TranslationFailure.unavailable));
    await expectLater(service.translate('Привет', 'sr'),
        _fails(TranslationFailure.unavailable));
    expect(requests, hasLength(2));
    expect(device.translations, 0);
  });

  test(
      'timed out fallback cannot publish a late translation, a retry obtains a fresh result',
      () async {
    final old = Completer<http.Response>();
    service = create(
        timeout: const Duration(milliseconds: 10),
        remote: (_) => requests.length == 1
            ? old.future
            : Future.value(_reply('Fresh', 'sr')));
    await expectLater(service.translate('Привет', 'sr'),
        _fails(TranslationFailure.unavailable));
    old.complete(_reply('Late', 'sr'));
    await Future<void>.delayed(Duration.zero);
    expect((await service.translate('Привет', 'sr')).text, 'Fresh');
  });

  test(
      'malformed attribution metadata is rejected instead of silently dropping it',
      () async {
    service = create(
        remote: (_) async => _reply('Zdravo', 'sr', googlePowered: 'true'));
    await expectLater(service.translate('Привет', 'sr'),
        _fails(TranslationFailure.unavailable));
  });

  test(
      'native model or translation failure does not trigger an unnecessary paid fallback',
      () async {
    device.translate =
        (_, __, ___) async => throw StateError('private diagnostic');
    service = create();
    await expectLater(service.translate('Привет', 'en'),
        _fails(TranslationFailure.unavailable));
    expect(requests, isEmpty);
    expect(tokens, 0);
  });

  test(
      'unknown detected language is not guessed as Serbian or sent to the paid fallback',
      () async {
    device.source = 'und';
    service = create();
    await expectLater(service.translate('?', 'en'),
        _fails(TranslationFailure.unsupportedLanguage));
    expect(requests, isEmpty);
  });

  test('sandbox never sends Serbian content to a production endpoint',
      () async {
    service = create(sandbox: true);
    await expectLater(service.translate('Привет', 'sr'),
        _fails(TranslationFailure.unsupportedLanguage));
    expect(requests, isEmpty);
    expect(tokens, 0);
  });
}
