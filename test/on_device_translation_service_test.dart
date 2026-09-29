import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/service/content_translation_service.dart';
import 'package:wbrs/service/on_device_content_translation.dart';

class _DeviceTranslator implements OnDeviceContentTranslator {
  @override
  bool get available => true;
  final detected = <String>[];
  final models = <String>[];
  final translations = <(String, String, String)>[];
  Future<String> Function(String) detector = (_) async => 'ru';
  Future<void> Function(String) model = (_) async {};
  Future<String> Function(String, String, String) translate =
      (_, __, ___) async => 'Hello';

  @override
  bool supportsLanguage(String code) =>
      ClrsLocalizations.codes.contains(code) && code != 'sr';
  @override
  Future<String> identifyLanguage(String text) {
    detected.add(text);
    return detector(text);
  }

  @override
  Future<void> ensureModel(String code) {
    models.add(code);
    return model(code);
  }

  @override
  Future<String> translateText(String text, String source, String target) {
    translations.add((text, source, target));
    return translate(text, source, target);
  }
}

Matcher _fails(TranslationFailure failure) =>
    throwsA(isA<ContentTranslationException>()
        .having((error) => error.failure, 'failure', failure));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  String? uid;
  late _DeviceTranslator device;
  late ContentTranslationService service;
  var httpRequests = 0;
  ContentTranslationService create({
    Uri? endpoint,
    Duration timeout = const Duration(seconds: 60),
  }) =>
      ContentTranslationService(
          endpoint: endpoint,
          currentUserId: () => uid,
          idToken: () async => 'fixture-token',
          enableOnDevice: true,
          onDeviceTranslator: device,
          onDeviceTimeout: timeout,
          client: MockClient((request) async {
            httpRequests++;
            return http.Response(
                jsonEncode({
                  'translatedText': 'Remote fixture',
                  'detectedSourceLanguage': 'ru',
                  'targetLanguage': 'en',
                }),
                200);
          }));

  setUp(() {
    uid = 'account-a';
    device = _DeviceTranslator();
    httpRequests = 0;
  });
  tearDown(() => service.dispose());

  test('ML Kit supports exactly 22 current target languages, excluding Serbian',
      () {
    service = create();
    final native = MlKitContentTranslator();
    expect(
        ClrsLocalizations.codes
            .where(native.supportsLanguage)
            .toList(growable: false),
        ClrsLocalizations.codes.where((code) => code != 'sr').toList());
    expect(native.supportsLanguage('nb'), isTrue);
    expect(native.supportsLanguage('und'), isFalse);
    expect(
        native.available, isFalse); // Desktop test host never invokes ML Kit.
  });

  test('empty endpoint uses on-device translation without HTTP or cloud token',
      () async {
    var tokenReads = 0;
    service = ContentTranslationService(
        endpoint: null,
        currentUserId: () => uid,
        idToken: () async {
          tokenReads++;
          return null;
        },
        enableOnDevice: true,
        onDeviceTranslator: device);
    expect(service.configured, isTrue);
    final result = await service.translate('Привет', 'en');
    expect(result.text, 'Hello');
    expect(result.sourceLanguage, 'ru');
    expect(result.googlePowered, isTrue);
    expect(result.alreadyTarget, isFalse);
    expect(device.models, ['ru', 'en']);
    expect(tokenReads, 0);
    expect(httpRequests, 0);
  });

  test('configured backend remains preferred and has no Google attribution',
      () async {
    service = create(endpoint: Uri.parse('https://translation.example.test'));
    expect(service.usesOnDevice, isFalse);
    final result = await service.translate('Привет', 'en');
    expect(result.text, 'Remote fixture');
    expect(result.googlePowered, isFalse);
    expect(httpRequests, 1);
    expect(device.detected, isEmpty);
  });

  test('Serbian target fails explicitly without detection or model download',
      () async {
    service = create();
    await expectLater(service.translate('Привет', 'sr'),
        _fails(TranslationFailure.unsupportedLanguage));
    expect(device.detected, isEmpty);
    expect(device.models, isEmpty);
    expect(device.translations, isEmpty);
  });

  test('Serbian source fails explicitly without substituting another language',
      () async {
    device.detector = (_) async => 'sr';
    service = create();
    await expectLater(service.translate('Љубав и породица', 'ru'),
        _fails(TranslationFailure.unsupportedLanguage));
    expect(device.models, isEmpty);
    expect(device.translations, isEmpty);
  });

  test(
      'already-target original is not marked as a successful Google translation',
      () async {
    device.detector = (_) async => 'en';
    service = create();
    final result = await service.translate('Original English', 'en');
    expect(result.text, 'Original English');
    expect(result.alreadyTarget, isTrue);
    expect(result.googlePowered, isFalse);
    expect(device.models, isEmpty);
    expect(device.translations, isEmpty);
  });

  test('native result is deduplicated, cached and isolated by account',
      () async {
    final nativeResult = Completer<String>();
    device.translate = (_, __, ___) => nativeResult.future;
    service = create();
    final first = service.translate('Привет', 'en');
    final second = service.translate('Привет', 'en');
    await Future<void>.delayed(Duration.zero);
    nativeResult.complete('Hello');
    final results = await Future.wait([first, second]);
    expect(results.map((value) => value.text), ['Hello', 'Hello']);
    await service.translate('Привет', 'en');
    expect(device.translations, hasLength(1));
    uid = 'account-b';
    device.translate = (_, __, ___) async => 'New account';
    expect((await service.translate('Привет', 'en')).text, 'New account');
    expect(device.translations, hasLength(2));
  });

  test('native failure is sanitised and can be retried', () async {
    var calls = 0;
    device.translate = (_, __, ___) async {
      if (++calls == 1) throw StateError('private native diagnostics');
      return 'Retry succeeded';
    };
    service = create();
    await expectLater(service.translate('Привет', 'en'),
        _fails(TranslationFailure.unavailable));
    expect((await service.translate('Привет', 'en')).text, 'Retry succeeded');
    expect(device.translations, hasLength(2));
  });

  test(
      'model timeout bounds waiting and retry shares the real pending operation',
      () async {
    final downloaded = Completer<void>();
    device.model = (_) => downloaded.future;
    service = create(timeout: const Duration(milliseconds: 20));
    await expectLater(service.translate('Привет', 'en'),
        _fails(TranslationFailure.unavailable));
    expect(device.translations, isEmpty);
    final retried = service.translate('Привет', 'en');
    expect(device.detected, hasLength(1));
    expect(device.models, ['ru', 'en']);
    downloaded.complete();
    expect((await retried).text, 'Hello');
    expect(device.translations, hasLength(1));
  });

  test('timed-out native response does not populate the account cache later',
      () async {
    final result = Completer<String>();
    device.translate = (_, __, ___) => result.future;
    service = create(timeout: const Duration(milliseconds: 20));
    await expectLater(service.translate('Привет', 'en'),
        _fails(TranslationFailure.unavailable));
    result.complete('Late translation');
    await Future<void>.delayed(Duration.zero);
    device.translate = (_, __, ___) async => 'Fresh translation';
    expect((await service.translate('Привет', 'en')).text, 'Fresh translation');
    expect(device.translations, hasLength(2));
  });

  test('account change during model download stops old text before translation',
      () async {
    final downloaded = Completer<void>();
    device.model = (_) => downloaded.future;
    service = create();
    final pending = service.translate('Привет', 'en');
    final assertion =
        expectLater(pending, _fails(TranslationFailure.sessionChanged));
    await Future<void>.delayed(Duration.zero);
    uid = 'account-b';
    service.clear();
    downloaded.complete();
    await assertion;
    expect(device.translations, isEmpty);
    expect((await service.translate('Привет', 'en')).text, 'Hello');
  });

  test('account change takes priority over an old native exception', () async {
    final detected = Completer<String>();
    device.detector = (_) => detected.future;
    service = create();
    final pending = service.translate('Привет', 'en');
    final assertion =
        expectLater(pending, _fails(TranslationFailure.sessionChanged));
    uid = 'account-b';
    detected.completeError(StateError('private native diagnostics'));
    await assertion;
    expect(device.models, isEmpty);
    expect(device.translations, isEmpty);
  });

  test('native model manager shares downloads and retries a failed download',
      () async {
    service = create();
    const channel = MethodChannel('google_mlkit_on_device_translator');
    final calls = <MethodCall>[];
    var downloadCount = 0;
    final firstDownload = Completer<String>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.arguments['task'] == 'check') return false;
      downloadCount++;
      if (downloadCount == 1) return firstDownload.future;
      return 'success';
    });
    try {
      final native = MlKitContentTranslator();
      final first = native.ensureModel('ru');
      final second = native.ensureModel('ru');
      final assertion =
          expectLater(Future.wait([first, second]), throwsA(isA<StateError>()));
      await Future<void>.delayed(Duration.zero);
      firstDownload.complete('failed');
      await assertion;
      expect(downloadCount, 1);
      await native.ensureModel('ru');
      expect(downloadCount, 2);
      expect(calls.every((call) => call.arguments['model'] == 'ru'), isTrue);
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
  });
}
