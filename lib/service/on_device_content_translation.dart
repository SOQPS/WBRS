import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_language_id/google_mlkit_language_id.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

/// The native boundary is replaceable in service tests; production uses ML Kit.
abstract class OnDeviceContentTranslator {
  bool get available;
  bool supportsLanguage(String code);
  Future<String> identifyLanguage(String text);
  Future<void> ensureModel(String code);
  Future<String> translateText(String text, String source, String target);
}

class MlKitContentTranslator implements OnDeviceContentTranslator {
  final _modelDownloads = <String, Future<void>>{};

  @override
  bool get available => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  String _nativeCode(String code) => code == 'nb' ? 'no' : code;

  @override
  bool supportsLanguage(String code) =>
      BCP47Code.fromRawValue(_nativeCode(code)) != null;

  @override
  Future<String> identifyLanguage(String text) async {
    final detector = LanguageIdentifier(confidenceThreshold: 0.3);
    try {
      return await detector.identifyLanguage(text);
    } finally {
      try {
        await detector.close();
      } catch (_) {
        // Cleanup must not replace the result or expose native diagnostics.
      }
    }
  }

  @override
  Future<void> ensureModel(String code) {
    final nativeCode = _nativeCode(code);
    final existing = _modelDownloads[nativeCode];
    if (existing != null) return existing;
    late Future<void> operation;
    operation = (() async {
      final manager = OnDeviceTranslatorModelManager();
      if (!await manager.isModelDownloaded(nativeCode) &&
          !await manager.downloadModel(nativeCode, isWifiRequired: false)) {
        throw StateError('Translation model unavailable');
      }
    })()
        .whenComplete(() {
      if (identical(_modelDownloads[nativeCode], operation)) {
        _modelDownloads.remove(nativeCode);
      }
    });
    // Native downloads cannot be cancelled by Future.timeout. Keep sharing the
    // actual download until it settles, including after a caller stops waiting.
    _modelDownloads[nativeCode] = operation;
    return operation;
  }

  @override
  Future<String> translateText(
      String text, String source, String target) async {
    final translator = OnDeviceTranslator(
        sourceLanguage: BCP47Code.fromRawValue(_nativeCode(source))!,
        targetLanguage: BCP47Code.fromRawValue(_nativeCode(target))!);
    try {
      return await translator.translateText(text);
    } finally {
      try {
        await translator.close();
      } catch (_) {
        // Cleanup must not replace the result or expose native diagnostics.
      }
    }
  }
}
