import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

// ignore: depend_on_referenced_packages
import 'package:file/file.dart' as cache_file;
// ignore: depend_on_referenced_packages
import 'package:file/memory.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/service/profile_photo_upload.dart';

class _Snapshot extends Fake implements TaskSnapshot {
  @override
  int get totalBytes => 100;
  @override
  int get bytesTransferred => 100;
}

class _Task extends Fake implements UploadTask {
  _Task(this.future, {this.streamError});
  final Future<TaskSnapshot> future;
  final Object? streamError;
  int cancellations = 0;
  @override
  Stream<TaskSnapshot> get snapshotEvents => streamError == null
      ? Stream.value(_Snapshot())
      : Stream.error(streamError!);
  @override
  Future<bool> cancel() async {
    cancellations++;
    return true;
  }

  @override
  Future<T> then<T>(FutureOr<T> Function(TaskSnapshot) onValue,
          {Function? onError}) =>
      future.then(onValue, onError: onError);
  @override
  Future<TaskSnapshot> timeout(Duration timeLimit,
          {FutureOr<TaskSnapshot> Function()? onTimeout}) =>
      future.timeout(timeLimit, onTimeout: onTimeout);
}

class _Ref extends Fake implements Reference {
  _Ref(this.name, this.task, this.events);
  @override
  final String name;
  final _Task task;
  final List<String> events;
  @override
  UploadTask putFile(File file, [SettableMetadata? metadata]) {
    events.add('$name:putFile');
    return task;
  }

  @override
  UploadTask putData(Uint8List data, [SettableMetadata? metadata]) {
    events.add('$name:putData');
    return task;
  }

  @override
  Future<String> getDownloadURL() async {
    events.add('$name:url');
    return 'https://example.invalid/$name.jpg';
  }
}

class _Cache extends Fake implements BaseCacheManager {
  final files = <String, Uint8List>{};
  Object? error;
  @override
  Future<cache_file.File> putFile(String url, Uint8List fileBytes,
      {String? key,
      String? eTag,
      Duration maxAge = const Duration(days: 30),
      String fileExtension = 'file'}) async {
    if (error != null) throw error!;
    files[url] = fileBytes;
    return MemoryFileSystem().file('unused');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final file = File('assets/family_01.jpg');

  test(
      'main starts immediately, preview is concurrent, returned files are cached',
      () async {
    final events = <String>[];
    final mainGate = Completer<TaskSnapshot>();
    final main = _Ref('main', _Task(mainGate.future), events);
    final thumb = _Ref('thumb', _Task(Future.value(_Snapshot())), events);
    final cache = _Cache();
    final pending = ProfilePhotoUpload(cache: cache)
        .upload(file: file, imageRef: main, thumbnailRef: thumb);
    expect(events, ['main:putFile']);
    // Main upload still in flight while the thumbnail becomes available.
    for (var i = 0; i < 100 && !events.contains('thumb:url'); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(events, contains('thumb:url'));
    mainGate.complete(_Snapshot());
    final result = await pending;
    expect(result.thumbnailUrl, 'https://example.invalid/thumb.jpg');
    expect(cache.files[result.url], await file.readAsBytes());
    expect(cache.files[result.thumbnailUrl], isNotEmpty);
  });

  test('thumbnail or disk-cache failure does not discard the saved portrait',
      () async {
    final events = <String>[];
    final failed = Completer<TaskSnapshot>();
    final main = _Ref('main', _Task(Future.value(_Snapshot())), events);
    final thumb = _Ref('thumb', _Task(failed.future), events);
    final cache = _Cache()..error = const FileSystemException('disk full');
    final pending = ProfilePhotoUpload(cache: cache)
        .upload(file: file, imageRef: main, thumbnailRef: thumb);
    for (var i = 0; i < 100 && !events.contains('thumb:putData'); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    failed.completeError(StateError('preview denied'));
    final result = await pending;
    expect(result.url, 'https://example.invalid/main.jpg');
    expect(result.thumbnailUrl, isNull);
  });

  test('failed upload cancels SDK work and reports failure without stream leak',
      () async {
    final events = <String>[];
    final gate = Completer<TaskSnapshot>();
    final task = _Task(gate.future, streamError: StateError('offline'));
    final main = _Ref('main', task, events);
    final thumbTask = _Task(Future.value(_Snapshot()));
    final thumb = _Ref('thumb', thumbTask, events);
    final cache = _Cache();
    final pending = ProfilePhotoUpload(cache: cache)
        .upload(file: file, imageRef: main, thumbnailRef: thumb);
    final assertion = expectLater(pending, throwsA(isA<TimeoutException>()));
    gate.completeError(TimeoutException('offline'));
    await assertion;
    expect(task.cancellations, 1);
    expect(cache.files, isEmpty);
    // Let native preview preparation complete; it must not start another upload.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(events.where((e) => e == 'thumb:putData'), isEmpty);
  });
}
