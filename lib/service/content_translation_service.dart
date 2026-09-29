import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/service/app_backend.dart';
import 'package:wbrs/service/on_device_content_translation.dart';

enum TranslationFailure {
  notConfigured,
  signedOut,
  sessionChanged,
  tooLong,
  rateLimited,
  unsupportedLanguage,
  unavailable,
}

class ContentTranslationException implements Exception {
  const ContentTranslationException(this.failure);
  final TranslationFailure failure;
}

class ContentTranslation {
  const ContentTranslation({
    required this.text,
    required this.sourceLanguage,
    required this.targetLanguage,
    this.googlePowered = false,
  });
  final String text, sourceLanguage, targetLanguage;
  final bool googlePowered;
  bool get alreadyTarget =>
      ClrsLocalizations.normalizeCode(sourceLanguage) == targetLanguage;
}

/// Authenticated, display-only translation. Originals never enter a write API.
/// Cache is bounded, memory-only, partitioned by account and invalidated on logout.
/// Without a backend, mobile builds use the original Google ML Kit translator.
class ContentTranslationService extends ChangeNotifier {
  ContentTranslationService({
    required this.endpoint,
    required String? Function() currentUserId,
    required Future<String?> Function() idToken,
    http.Client? client,
    this.timeout = const Duration(seconds: 25),
    this.onDeviceTimeout = const Duration(seconds: 60),
    this.allowLocalHttp = false,
    this.enableOnDevice = false,
    this.enableRemoteFallback = false,
    OnDeviceContentTranslator? onDeviceTranslator,
    this.maxCacheEntries = 200,
  })  : _currentUserId = currentUserId,
        _idToken = idToken,
        _client = client ?? http.Client(),
        _onDeviceTranslator = onDeviceTranslator ?? MlKitContentTranslator(),
        _ownsClient = client == null;

  static final instance = ContentTranslationService(
    endpoint: Uri.tryParse(const String.fromEnvironment(
        'CLRS_TRANSLATION_ENDPOINT',
        defaultValue: '')),
    currentUserId: () => firebaseAuth.currentUser?.uid,
    idToken: () async => firebaseAuth.currentUser?.getIdToken(),
    allowLocalHttp: AppBackend.useEmulators,
    enableOnDevice: true,
    enableRemoteFallback: const bool.fromEnvironment(
        'CLRS_TRANSLATION_REMOTE_FALLBACK',
        defaultValue: false),
  );

  final Uri? endpoint;
  final String? Function() _currentUserId;
  final Future<String?> Function() _idToken;
  final http.Client _client;
  final OnDeviceContentTranslator _onDeviceTranslator;
  final bool _ownsClient, allowLocalHttp, enableOnDevice, enableRemoteFallback;
  final Duration timeout, onDeviceTimeout;
  final int maxCacheEntries;
  static const maxTextCodePoints = 20000;
  static const maxRequestCodePoints = 5000;
  // Leave room below Amazon TranslateText's 10 KB UTF-8 text limit.
  static const maxRequestUtf8Bytes = 9000;
  final _cache = LinkedHashMap<String, ContentTranslation>();
  final _pending = <String, Future<ContentTranslation>>{};
  final _devicePending = <String, Future<ContentTranslation>>{};
  String? _cacheUser;
  int _epoch = 0;

  bool get _remoteConfigured {
    final uri = endpoint;
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      return false;
    }
    final local =
        const {'localhost', '127.0.0.1', '10.0.2.2'}.contains(uri.host);
    // Sandbox may only contact the explicit local fixture/server endpoint.
    if (allowLocalHttp)
      return local && const {'http', 'https'}.contains(uri.scheme);
    return uri.scheme == 'https';
  }

  bool get _onDeviceAvailable =>
      enableOnDevice && _onDeviceTranslator.available;

  bool get configured => _remoteConfigured || _onDeviceAvailable;

  bool get _useOnDevice =>
      _onDeviceAvailable && (!_remoteConfigured || enableRemoteFallback);
  bool get _remoteFallbackConfigured =>
      enableRemoteFallback && _remoteConfigured;
  bool get usesOnDevice => _useOnDevice;

  String? get sessionId {
    try {
      return _currentUserId();
    } catch (_) {
      return null;
    }
  }

  void clear() {
    _epoch++;
    _cache.clear();
    _pending.clear();
    _devicePending.clear();
    _cacheUser = null;
    notifyListeners();
  }

  Future<ContentTranslation> translate(String text, String language) {
    if (!configured) {
      return Future.error(
          const ContentTranslationException(TranslationFailure.notConfigured));
    }
    final uid = sessionId;
    if (uid == null) {
      return Future.error(
          const ContentTranslationException(TranslationFailure.signedOut));
    }
    if (_cacheUser != uid) {
      _epoch++;
      _cache.clear();
      _pending.clear();
      _devicePending.clear();
      _cacheUser = uid;
    }
    final target = ClrsLocalizations.normalizeCode(language);
    if (!ClrsLocalizations.codes.contains(target)) {
      return Future.error(
          const ContentTranslationException(TranslationFailure.unavailable));
    }
    if (_useOnDevice &&
        !_onDeviceTranslator.supportsLanguage(target) &&
        !_remoteFallbackConfigured) {
      return Future.error(const ContentTranslationException(
          TranslationFailure.unsupportedLanguage));
    }
    if (text.runes.length > maxTextCodePoints) {
      return Future.error(
          const ContentTranslationException(TranslationFailure.tooLong));
    }
    if (text.trim().isEmpty) {
      return Future.value(ContentTranslation(
          text: text, sourceLanguage: target, targetLanguage: target));
    }
    final key = jsonEncode([uid, target, text]);
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached;
      return Future.value(cached);
    }
    final existing = _pending[key];
    if (existing != null) return existing;
    final epoch = _epoch;
    late Future<ContentTranslation> operation;
    operation = _translateParts(text, target, uid, epoch).then((value) {
      _checkSession(uid, epoch);
      _cache[key] = value;
      while (_cache.length > maxCacheEntries) {
        _cache.remove(_cache.keys.first);
      }
      return value;
    }).whenComplete(() {
      if (identical(_pending[key], operation)) _pending.remove(key);
    });
    _pending[key] = operation;
    return operation;
  }

  void _checkSession(String uid, int epoch) {
    if (sessionId != uid || _epoch != epoch) {
      throw const ContentTranslationException(
          TranslationFailure.sessionChanged);
    }
  }

  Future<ContentTranslation> _translateParts(
      String text, String target, String uid, int epoch) async {
    final runes = text.runes.toList(growable: false);
    final translated = StringBuffer();
    final languages = <String>{};
    var googlePowered = false;
    var start = 0;
    while (start < runes.length) {
      _checkSession(uid, epoch);
      var end = start;
      var byteLength = 0;
      while (end < runes.length && end - start < maxRequestCodePoints) {
        final rune = runes[end];
        final runeBytes = rune <= 0x7f
            ? 1
            : rune <= 0x7ff
                ? 2
                : rune <= 0xffff
                    ? 3
                    : 4;
        if (byteLength + runeBytes > maxRequestUtf8Bytes) break;
        byteLength += runeBytes;
        end++;
      }
      // Prefer a nearby word/paragraph boundary; never split a surrogate pair.
      if (end < runes.length) {
        for (var index = end - 1;
            index >= start && index > end - 1000;
            index--) {
          if (String.fromCharCode(runes[index]).trim().isEmpty) {
            end = index + 1;
            break;
          }
        }
      }
      final part = String.fromCharCodes(runes.sublist(start, end));
      final body = part.trim();
      if (body.isEmpty) {
        translated.write(part);
      } else {
        // Providers may normalise surrounding whitespace. Keep the user's
        // paragraph separators verbatim when assembling a long translation.
        final left = part.length - part.trimLeft().length;
        final right = part.trimRight().length;
        final result = _useOnDevice
            ? await _translateOnDevice(body, target, uid, epoch)
            : await _request(body, target, uid, epoch);
        languages.add(ClrsLocalizations.normalizeCode(result.sourceLanguage));
        googlePowered = googlePowered || result.googlePowered;
        translated
          ..write(part.substring(0, left))
          ..write(result.text)
          ..write(part.substring(right));
      }
      start = end;
    }
    return ContentTranslation(
      text: translated.toString(),
      sourceLanguage: languages.length == 1 ? languages.single : 'und',
      targetLanguage: target,
      googlePowered: googlePowered,
    );
  }

  Future<ContentTranslation> _translateOnDevice(
      String text, String target, String uid, int epoch) async {
    try {
      final key = jsonEncode([uid, epoch, target, text]);
      var operation = _devicePending[key];
      if (operation == null) {
        late Future<ContentTranslation> nativeOperation;
        nativeOperation =
            _runOnDevice(text, target, uid, epoch).whenComplete(() {
          if (identical(_devicePending[key], nativeOperation)) {
            _devicePending.remove(key);
          }
        });
        _devicePending[key] = nativeOperation;
        operation = nativeOperation;
      }
      // Bound UI waiting, while keeping the native operation shared until it
      // really ends. A retry must not launch a second model download/translation.
      final result = await operation.timeout(onDeviceTimeout);
      _checkSession(uid, epoch);
      return result;
    } catch (error) {
      _checkSession(uid, epoch);
      if (error is ContentTranslationException) rethrow;
      throw const ContentTranslationException(TranslationFailure.unavailable);
    }
  }

  Future<ContentTranslation> _runOnDevice(
      String text, String target, String uid, int epoch) async {
    _checkSession(uid, epoch);
    if (!_onDeviceTranslator.supportsLanguage(target) &&
        _remoteFallbackConfigured) {
      return _request(text, target, uid, epoch);
    }
    final source = ClrsLocalizations.normalizeCode(
        await _onDeviceTranslator.identifyLanguage(text));
    _checkSession(uid, epoch);
    if (!_onDeviceTranslator.supportsLanguage(source) ||
        !_onDeviceTranslator.supportsLanguage(target)) {
      if (_remoteFallbackConfigured && source == 'sr') {
        return _request(text, target, uid, epoch);
      }
      throw const ContentTranslationException(
          TranslationFailure.unsupportedLanguage);
    }
    if (source == target) {
      return ContentTranslation(
          text: text, sourceLanguage: source, targetLanguage: target);
    }
    await Future.wait([
      _onDeviceTranslator.ensureModel(source),
      _onDeviceTranslator.ensureModel(target),
    ]);
    _checkSession(uid, epoch);
    final translated =
        await _onDeviceTranslator.translateText(text, source, target);
    _checkSession(uid, epoch);
    if (translated.trim().isEmpty || utf8.encode(translated).length > 200000) {
      throw const ContentTranslationException(TranslationFailure.unavailable);
    }
    return ContentTranslation(
        text: translated,
        sourceLanguage: source,
        targetLanguage: target,
        googlePowered: true);
  }

  Future<ContentTranslation> _request(
      String text, String target, String uid, int epoch) async {
    try {
      final token = await _idToken().timeout(timeout);
      _checkSession(uid, epoch);
      if (token == null || token.isEmpty) {
        throw const ContentTranslationException(TranslationFailure.signedOut);
      }
      final request = http.Request('POST', endpoint!)
        ..followRedirects = false
        ..headers.addAll({
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token'
        })
        ..body = jsonEncode({'text': text, 'targetLanguage': target});
      final response = await (() async =>
              http.Response.fromStream(await _client.send(request)))()
          .timeout(timeout);
      _checkSession(uid, epoch);
      if (response.statusCode == 429) {
        throw const ContentTranslationException(TranslationFailure.rateLimited);
      }
      if (response.statusCode == 401) {
        throw const ContentTranslationException(TranslationFailure.signedOut);
      }
      if (response.statusCode == 413) {
        throw const ContentTranslationException(TranslationFailure.tooLong);
      }
      if (response.statusCode != 200 || response.bodyBytes.length > 200000) {
        throw const ContentTranslationException(TranslationFailure.unavailable);
      }
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      if (data is! Map ||
          data['translatedText'] is! String ||
          (data['translatedText'] as String).trim().isEmpty ||
          data['targetLanguage'] != target ||
          data['detectedSourceLanguage'] is! String ||
          (data['googlePowered'] != null && data['googlePowered'] is! bool) ||
          !RegExp(r'^[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$')
              .hasMatch(data['detectedSourceLanguage'] as String)) {
        throw const ContentTranslationException(TranslationFailure.unavailable);
      }
      return ContentTranslation(
          text: data['translatedText'] as String,
          sourceLanguage: data['detectedSourceLanguage'] as String,
          targetLanguage: target,
          googlePowered: data['googlePowered'] == true);
    } catch (error) {
      _checkSession(uid, epoch);
      if (error is ContentTranslationException) rethrow;
      // Provider/network errors can contain private text; never expose or log them.
      throw const ContentTranslationException(TranslationFailure.unavailable);
    }
  }

  @override
  void dispose() {
    _epoch++;
    _cache.clear();
    _pending.clear();
    _devicePending.clear();
    if (_ownsClient) _client.close();
    super.dispose();
  }
}
