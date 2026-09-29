import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:image/image.dart' as img;

/// Opt-in device timing; never includes file names, URLs, tokens or user IDs.
void profilePhotoMetric(String stage, Duration elapsed,
    {int? bytes, int? count}) {
  if (!const bool.fromEnvironment('CLRS_PHOTO_METRICS')) return;
  // ignore: avoid_print
  print('PHOTO_METRIC stage=$stage elapsedMs=${elapsed.inMilliseconds}'
      '${bytes == null ? '' : ' bytes=$bytes'}'
      '${count == null ? '' : ' count=$count'}');
}

Uint8List _encodeThumbnail(({Uint8List pixels, int width, int height}) data) {
  final image = img.Image.fromBytes(
      width: data.width,
      height: data.height,
      bytes: data.pixels.buffer,
      numChannels: 4);
  return Uint8List.fromList(img.encodeJpg(image, quality: 80));
}

Future<Uint8List?> _createThumbnail(String path) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    // The engine decodes directly at the avatar size. Decoding every source
    // pixel and resizing it in Dart delayed the upload even on fast networks.
    buffer = await ui.ImmutableBuffer.fromFilePath(path);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final longest = descriptor.width > descriptor.height
        ? descriptor.width
        : descriptor.height;
    final scale = longest > 320 ? 320 / longest : 1.0;
    codec = await descriptor.instantiateCodec(
      targetWidth: (descriptor.width * scale).round().clamp(1, 320),
      targetHeight: (descriptor.height * scale).round().clamp(1, 320),
    );
    image = (await codec.getNextFrame()).image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;
    // Only a <=320px image is JPEG-encoded, outside the UI isolate.
    return await compute(_encodeThumbnail, (
      pixels: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      width: image.width,
      height: image.height,
    ));
  } catch (_) {
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

/// The gallery picker supplies a bounded JPEG (at most 1800 px). Keep the
/// portrait and its small avatar separate so lists never download the portrait.
class ProfilePhotoUploadResult {
  const ProfilePhotoUploadResult({
    required this.url,
    required this.sourceBytes,
    required this.processingTime,
    required this.uploadTime,
    required this.totalTime,
    this.thumbnailUrl,
    this.thumbnailBytes = 0,
  });

  final String url;
  final String? thumbnailUrl;
  final int sourceBytes;
  final int thumbnailBytes;
  final Duration processingTime;
  final Duration uploadTime;
  final Duration totalTime;
}

class ProfilePhotoPreparation {
  const ProfilePhotoPreparation({
    required this.sourceBytes,
    required this.thumbnail,
    required this.elapsed,
  });

  final int sourceBytes;
  final Uint8List? thumbnail;
  final Duration elapsed;
}

class ProfilePhotoUpload {
  const ProfilePhotoUpload({BaseCacheManager? cache}) : _cache = cache;
  final BaseCacheManager? _cache;

  Future<ProfilePhotoUploadResult> upload({
    required File file,
    required Reference imageRef,
    required Reference thumbnailRef,
    void Function(double progress)? onProgress,
  }) async {
    final total = Stopwatch()..start();
    final upload = Stopwatch()..start();
    // The picker has already compressed the portrait. Send it immediately;
    // preview preparation/upload runs alongside it, never before it.
    final imageTask = imageRef.putFile(
      file,
      SettableMetadata(contentType: 'image/jpeg'),
    );
    final subscription = imageTask.snapshotEvents.listen((snapshot) {
      if (snapshot.totalBytes > 0) {
        onProgress?.call(.9 * snapshot.bytesTransferred / snapshot.totalBytes);
      }
    }, onError: (Object _) {
      // The awaited UploadTask below reports the same failure to the caller.
    });
    UploadTask? thumbnailTask;
    var cancelled = false;
    ProfilePhotoPreparation? prepared;
    Future<String?> preview() async {
      try {
        prepared = await prepare(file);
        final bytes = prepared!.thumbnail;
        if (bytes == null || cancelled) return null;
        final timer = Stopwatch()..start();
        thumbnailTask = thumbnailRef.putData(
            bytes, SettableMetadata(contentType: 'image/jpeg'));
        await thumbnailTask!;
        profilePhotoMetric('upload_thumb', timer.elapsed, bytes: bytes.length);
        final urlTimer = Stopwatch()..start();
        final url = await thumbnailRef
            .getDownloadURL()
            .timeout(const Duration(seconds: 10));
        profilePhotoMetric('url_thumb', urlTimer.elapsed);
        return url;
      } catch (_) {
        return null; // The original photo remains usable if its preview fails.
      }
    }

    final previewFuture = preview(); // Errors are handled inside preview().
    late String url;
    String? thumbnailUrl;
    try {
      final snapshot = await imageTask.timeout(const Duration(minutes: 2));
      profilePhotoMetric('upload_main', upload.elapsed,
          bytes: snapshot.totalBytes);
      final urlTimer = Stopwatch()..start();
      url =
          await imageRef.getDownloadURL().timeout(const Duration(seconds: 15));
      profilePhotoMetric('url_main', urlTimer.elapsed);
      try {
        thumbnailUrl = await previewFuture.timeout(const Duration(seconds: 10));
      } on TimeoutException {
        cancelled = true;
        try {
          await thumbnailTask?.cancel().timeout(const Duration(seconds: 5));
        } catch (_) {}
      }
    } catch (_) {
      cancelled = true;
      try {
        await Future.wait([
          imageTask.cancel(),
          if (thumbnailTask != null) thumbnailTask!.cancel(),
        ]).timeout(const Duration(seconds: 5));
      } catch (_) {}
      rethrow;
    } finally {
      await subscription.cancel();
    }
    upload.stop();
    // Avoid downloading the same image straight back from Storage just to
    // display the freshly saved profile. URLs are unique to owner + photo ID.
    final cache = Stopwatch()..start();
    try {
      await Future.wait([
        file.readAsBytes().then((bytes) => (_cache ?? DefaultCacheManager())
            .putFile(url, bytes, fileExtension: 'jpg')),
        if (thumbnailUrl != null && prepared?.thumbnail != null)
          (_cache ?? DefaultCacheManager()).putFile(
              thumbnailUrl, prepared!.thumbnail!,
              fileExtension: 'jpg'),
      ]).timeout(const Duration(seconds: 3));
    } catch (_) {
      // A full/unavailable local cache must not fail a completed upload.
    }
    profilePhotoMetric('cache', cache.elapsed);
    total.stop();
    profilePhotoMetric('total', total.elapsed);
    onProgress?.call(1);
    return ProfilePhotoUploadResult(
      url: url,
      thumbnailUrl: thumbnailUrl,
      sourceBytes: prepared?.sourceBytes ?? await file.length(),
      thumbnailBytes: prepared?.thumbnail?.length ?? 0,
      processingTime: prepared?.elapsed ?? Duration.zero,
      uploadTime: upload.elapsed,
      totalTime: total.elapsed,
    );
  }

  Future<ProfilePhotoPreparation> prepare(File file) async {
    final processing = Stopwatch()..start();
    final sourceBytes = await file.length();
    final thumbnail = await _createThumbnail(file.path);
    processing.stop();
    profilePhotoMetric('prepare', processing.elapsed, bytes: sourceBytes);
    return ProfilePhotoPreparation(
      sourceBytes: sourceBytes,
      thumbnail: thumbnail,
      elapsed: processing.elapsed,
    );
  }
}
