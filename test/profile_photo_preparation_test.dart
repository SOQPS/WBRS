import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:wbrs/service/profile_photo_upload.dart';

Future<(int, int)> _dimensions(List<int> bytes) async {
  final buffer =
      await ui.ImmutableBuffer.fromUint8List(Uint8List.fromList(bytes));
  final descriptor = await ui.ImageDescriptor.encoded(buffer);
  try {
    return (descriptor.width, descriptor.height);
  } finally {
    descriptor.dispose();
    buffer.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('profile photo preparation makes bounded avatar previews', () async {
    for (final path in [
      'assets/family_01.jpg',
      'assets/family_login.jpg',
      'assets/final_design/family_back.png',
    ]) {
      final prepared = await const ProfilePhotoUpload().prepare(File(path));
      final thumbnail = prepared.thumbnail;
      // Local thumbnail timing, not a real network upload.
      // ignore: avoid_print
      print('photo-prep $path: ${prepared.sourceBytes} -> '
          '${thumbnail?.length ?? 0} bytes, ${prepared.elapsed.inMilliseconds} ms');
      expect(thumbnail, isNotNull, reason: path);
      expect(prepared.sourceBytes, greaterThan(0), reason: path);
      final dimensions = await _dimensions(thumbnail!);
      expect(dimensions.$1, inInclusiveRange(1, 320), reason: path);
      expect(dimensions.$2, inInclusiveRange(1, 320), reason: path);
    }
  });

  test('small portrait is not upscaled and source remains untouched', () async {
    final directory = await Directory.systemTemp.createTemp('clrs-photo-test');
    try {
      final bytes = img.encodeJpg(img.Image(width: 24, height: 48));
      final file =
          await File('${directory.path}/small.jpg').writeAsBytes(bytes);
      final prepared = await const ProfilePhotoUpload().prepare(file);
      expect(await _dimensions(prepared.thumbnail!), (24, 48));
      expect(await file.readAsBytes(), bytes);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('camera EXIF orientation is preserved in the avatar', () async {
    final directory = await Directory.systemTemp.createTemp('clrs-photo-exif');
    try {
      final source = img.Image(width: 640, height: 480);
      source.exif.imageIfd.orientation = 6;
      final file = await File('${directory.path}/rotated.jpg')
          .writeAsBytes(img.encodeJpg(source));
      final prepared = await const ProfilePhotoUpload().prepare(file);
      expect(await _dimensions(prepared.thumbnail!), (240, 320));
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('unsupported bytes return no preview without an unhandled error',
      () async {
    final directory = await Directory.systemTemp.createTemp('clrs-photo-bad');
    try {
      final file = await File('${directory.path}/bad.jpg').writeAsString('bad');
      final prepared = await const ProfilePhotoUpload().prepare(file);
      expect(prepared.thumbnail, isNull);
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
