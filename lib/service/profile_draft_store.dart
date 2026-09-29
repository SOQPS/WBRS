import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:path_provider/path_provider.dart';

String _draftId() =>
    '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
    '-${Random.secure().nextInt(0x7fffffff).toRadixString(36)}';

class ProfileDraftPhoto {
  const ProfileDraftPhoto(
      {required this.id,
      required this.fileName,
      this.uploadedUrl,
      this.thumbnailUrl});
  final String id, fileName;
  final String? uploadedUrl;
  final String? thumbnailUrl;
  ProfileDraftPhoto uploaded(String url, {String? thumbnailUrl}) =>
      ProfileDraftPhoto(
          id: id,
          fileName: fileName,
          uploadedUrl: url,
          thumbnailUrl: thumbnailUrl);
  Map<String, dynamic> toJson() => {
        'id': id,
        'fileName': fileName,
        'uploadedUrl': uploadedUrl,
        'thumbnailUrl': thumbnailUrl
      };
  factory ProfileDraftPhoto.fromJson(Map<String, dynamic> data) =>
      ProfileDraftPhoto(
          id: data['id'] as String,
          fileName: data['fileName'] as String,
          uploadedUrl: data['uploadedUrl'] as String?,
          thumbnailUrl: data['thumbnailUrl'] as String?);
}

class ProfileDraft {
  ProfileDraft(
      {required this.uid,
      String? id,
      Map<String, dynamic>? fields,
      List<ProfileDraftPhoto>? photos,
      this.mainPhotoId,
      this.commitStarted = false})
      : id = id ?? _draftId(),
        fields = Map.unmodifiable(fields ?? {}),
        photos = List.unmodifiable(photos ?? []);
  final String uid, id;
  final Map<String, dynamic> fields;
  final List<ProfileDraftPhoto> photos;
  final String? mainPhotoId;
  final bool commitStarted;
  ProfileDraft copyWith(
          {Map<String, dynamic>? fields,
          List<ProfileDraftPhoto>? photos,
          String? mainPhotoId,
          bool? commitStarted}) =>
      ProfileDraft(
          uid: uid,
          id: id,
          fields: fields ?? this.fields,
          photos: photos ?? this.photos,
          mainPhotoId: mainPhotoId ?? this.mainPhotoId,
          commitStarted: commitStarted ?? this.commitStarted);
  Map<String, dynamic> toJson() => {
        'version': 1,
        'uid': uid,
        'id': id,
        'fields': fields,
        'photos': photos.map((p) => p.toJson()).toList(),
        'mainPhotoId': mainPhotoId,
        'commitStarted': commitStarted
      };
  factory ProfileDraft.fromJson(Map<String, dynamic> data) {
    if (data['version'] != 1) {
      throw const FormatException('Неизвестная версия черновика');
    }
    return ProfileDraft(
        uid: data['uid'] as String,
        id: data['id'] as String,
        fields: Map<String, dynamic>.from(data['fields'] as Map),
        photos: (data['photos'] as List)
            .map((p) =>
                ProfileDraftPhoto.fromJson(Map<String, dynamic>.from(p as Map)))
            .toList(),
        mainPhotoId: data['mainPhotoId'] as String?,
        commitStarted: data['commitStarted'] == true);
  }
}

/// Local, UID-scoped and durable. Photo picker cache paths are never treated as
/// permanent; both the image copies and the manifest are flushed before success.
class ProfileDraftStore {
  ProfileDraftStore({Future<Directory> Function()? rootDirectory})
      : _rootDirectory = rootDirectory ?? getApplicationSupportDirectory;
  final Future<Directory> Function() _rootDirectory;
  static final Map<String, Future<void>> _queues = {};

  Future<Directory> directory(String uid) async {
    final root = await _rootDirectory();
    final safeUid = base64Url.encode(utf8.encode(uid)).replaceAll('=', '');
    return Directory('${root.path}/clrs_profile_drafts/$safeUid')
        .create(recursive: true);
  }

  Future<T> _serialized<T>(String uid, Future<T> Function() action) {
    final key = uid;
    final previous = _queues[key] ?? Future<void>.value();
    final result = previous.then((_) => action());
    // A failed disk operation must not poison later retries.
    _queues[key] =
        result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<ProfileDraft?> load(String uid) => _serialized(uid, () async {
        final file = File('${(await directory(uid)).path}/draft.json');
        if (!await file.exists()) return null;
        final draft = ProfileDraft.fromJson(
            jsonDecode(await file.readAsString()) as Map<String, dynamic>);
        if (draft.uid != uid) {
          throw const FormatException('Черновик другого аккаунта');
        }
        for (final photo in draft.photos) {
          if (photo.fileName.contains('/') ||
              photo.fileName.contains('\\') ||
              photo.fileName == '..') {
            throw const FormatException('Недопустимый путь фотографии');
          }
        }
        return draft;
      });

  Future<void> save(ProfileDraft draft) => _serialized(draft.uid, () async {
        final dir = await directory(draft.uid);
        final temp = File('${dir.path}/draft.json.tmp');
        await temp.writeAsString(jsonEncode(draft.toJson()), flush: true);
        await temp.rename('${dir.path}/draft.json');
      });

  Future<ProfileDraftPhoto> importPhoto(String uid, String sourcePath) async {
    final dir = await directory(uid);
    final id = _draftId();
    final fileName = '$id.jpg';
    final file = File('${dir.path}/$fileName');
    final source = File(sourcePath);
    await source.copy(file.path);
    return ProfileDraftPhoto(id: id, fileName: fileName);
  }

  Future<File> photoFile(String uid, ProfileDraftPhoto photo) async =>
      File('${(await directory(uid)).path}/${photo.fileName}');

  Future<void> clear(String uid) => _serialized(uid, () async {
        final dir = await directory(uid);
        if (await dir.exists()) await dir.delete(recursive: true);
      });
}
