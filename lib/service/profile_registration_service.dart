import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/core/utils/account_destination.dart';
import 'package:wbrs/shared/geo_catalog.dart';
import 'auth_service.dart';
import 'database_service.dart';
import 'pending_write.dart';
import 'profile_draft_store.dart';
import 'profile_photo_upload.dart';

class ProfileRegistrationRequest {
  ProfileRegistrationRequest(this.draft, this.write);
  final ProfileDraft draft;
  final PendingWrite write;
}

typedef ProfileWriter = Future<void> Function(
    ProfileDraft draft, List<String> urls, String fullName);
typedef ProfileUploader = Future<String> Function(String path, File file);

class ProfileRegistrationService {
  ProfileRegistrationService(
      {ProfileDraftStore? store,
      FirebaseFirestore? firestore,
      FirebaseAuth? auth,
      FirebaseStorage? storage,
      ProfileWriter? writer,
      ProfileUploader? uploader})
      : store = store ?? ProfileDraftStore(),
        _db = firestore ?? firebaseFirestore,
        _auth = auth ?? firebaseAuth,
        _storageOverride = storage,
        _writerOverride = writer,
        _uploaderOverride = uploader {
    ownerUid = _auth.currentUser?.uid;
  }
  final ProfileDraftStore store;
  final FirebaseFirestore _db;
  final FirebaseAuth _auth;
  final FirebaseStorage? _storageOverride;
  final ProfileWriter? _writerOverride;
  final ProfileUploader? _uploaderOverride;
  late final String? ownerUid;
  static final Map<String, ProfileRegistrationRequest> _requests = {};
  bool get isCurrentSession =>
      ownerUid != null && _auth.currentUser?.uid == ownerUid;
  ProfileRegistrationRequest? get pending => _requests[ownerUid];
  Future<String> initialName() {
    _checkSession();
    return AuthService.registrationName(_auth.currentUser!);
  }

  void _checkSession() {
    if (!isCurrentSession) throw StateError('Сеанс завершён. Войдите снова.');
  }

  Future<Map<String, dynamic>?> _profile() async {
    _checkSession();
    final document = await _db
        .collection('users')
        .doc(ownerUid)
        .get(const GetOptions(source: Source.server))
        .timeout(const Duration(seconds: 15));
    _checkSession();
    return document.data();
  }

  ProfileRegistrationRequest start(ProfileDraft draft) {
    _checkSession();
    if (draft.uid != ownerUid) throw StateError('Черновик другого аккаунта');
    final previous = _requests[ownerUid];
    if (previous != null && !previous.write.failed) return previous;
    final frozen = draft.copyWith(commitStarted: true);
    return _requests[ownerUid!] =
        ProfileRegistrationRequest(frozen, PendingWrite(() => _save(frozen)));
  }

  Future<void> _save(ProfileDraft original) async {
    var draft = original;
    try {
      // Persist intent before any upload or profile mutation. Recovery always
      // reconciles the server first, including a process killed after commit.
      await store.save(draft);
      var destination = accountDestination(await _profile());
      if (destination == AccountDestination.blocked ||
          destination == AccountDestination.deleted) {
        throw StateError('Профиль недоступен. Обратитесь в поддержку.');
      }
      if (destination == AccountDestination.registration) {
        final countries = await GeoCatalog.load();
        final geo = GeoCatalog.byCode(
            countries, draft.fields['countryCode']?.toString());
        if (geo == null || !geo.regions.contains(draft.fields['region'])) {
          throw ArgumentError('Выберите страну и регион из списка');
        }
        if (draft.photos.length < 3 ||
            !draft.photos.any((photo) => photo.id == draft.mainPhotoId)) {
          throw ArgumentError(
              'Добавьте минимум 3 фотографии и выберите главную');
        }
        // A queued draft can resume without passing through the form again.
        // Keep its content rules at the write boundary as well as in the UI.
        if ((draft.fields['interests']?.toString().trim().length ?? 0) < 20 ||
            (draft.fields['about']?.toString().trim().length ?? 0) < 50) {
          throw ArgumentError('Заполните интересы и «О себе» полностью');
        }
        var nextPhoto = 0;
        Future<void> uploadWorker() async {
          while (nextPhoto < draft.photos.length) {
            final i = nextPhoto++;
            _checkSession();
            if (draft.photos[i].uploadedUrl != null) continue;
            final photo = draft.photos[i];
            final local = await store.photoFile(draft.uid, photo);
            if (!await local.exists()) {
              throw StateError('Фотография недоступна. Выберите её заново.');
            }
            final path =
                'profile_images/${draft.uid}/registration/${draft.id}/${photo.id}.jpg';
            final result = _uploaderOverride == null
                ? await const ProfilePhotoUpload().upload(
                    file: local,
                    imageRef: (_storageOverride ?? FirebaseStorage.instance)
                        .ref()
                        .child(path),
                    thumbnailRef: (_storageOverride ?? FirebaseStorage.instance)
                        .ref()
                        .child('profile_images/${draft.uid}/registration/'
                            '${draft.id}/thumbs/${photo.id}.jpg'))
                : null;
            final url = result?.url ?? await _uploaderOverride!(path, local);
            _checkSession();
            final photos = draft.photos.toList();
            photos[i] = photo.uploaded(url, thumbnailUrl: result?.thumbnailUrl);
            draft = draft.copyWith(photos: photos);
            await store.save(draft);
          }
        }

        await Future.wait([
          for (var i = 0;
              i < draft.photos.length &&
                  i < (_uploaderOverride == null ? 2 : 1);
              i++)
            uploadWorker(),
        ]);
        _checkSession();
        final name = draft.fields['fullName']?.toString() ??
            await AuthService.registrationName(_auth.currentUser!);
        final urls = draft.photos.map((photo) => photo.uploadedUrl!).toList();
        final writeTimer = Stopwatch()..start();
        await (_writerOverride ?? _write)(draft, urls, name);
        profilePhotoMetric('profile_write', writeTimer.elapsed);
        _checkSession();
        destination = accountDestination(await _profile());
        if (destination == AccountDestination.registration) {
          throw StateError(
              'Сохранение анкеты не подтверждено. Проверьте результат.');
        }
        if (destination == AccountDestination.blocked ||
            destination == AccountDestination.deleted) {
          throw StateError('Профиль недоступен. Обратитесь в поддержку.');
        }
      }
      // Keep the draft/photos until the UI acknowledges server success. A
      // disposed route can restore the same operation without broken previews.
    } catch (_) {
      try {
        await store.save(draft.copyWith(commitStarted: false));
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> _write(
      ProfileDraft draft, List<String> urls, String fullName) async {
    _checkSession();
    final fields = draft.fields;
    final countries = await GeoCatalog.load();
    final country = GeoCatalog.byCode(countries, '${fields['countryCode']}')!;
    _checkSession();
    await DatabaseService().savingUserDataAfterRegister(
      fullName: fullName,
      email: _auth.currentUser?.email ?? '',
      profilePic:
          urls[draft.photos.indexWhere((p) => p.id == draft.mainPhotoId)],
      profilePicThumb: draft.photos
          .firstWhere((p) => p.id == draft.mainPhotoId)
          .thumbnailUrl,
      profileImages: urls,
      profileImageThumbs: draft.photos.map((p) => p.thumbnailUrl).toList(),
      age: int.parse('${fields['age']}'),
      rost: '${fields['height']}',
      country: country.name,
      countryCode: country.code,
      region: '${fields['region']}',
      deti: fields['children'] == 'да',
      hobbi: '${fields['interests']}',
      about: '${fields['about']}',
      pol: '${fields['gender']}',
      relationStatus: '${fields['relationStatus']}',
    );
  }

  Future<void> acknowledge(ProfileRegistrationRequest request) async {
    _checkSession();
    if (request.write.completed &&
        !request.write.failed &&
        identical(_requests[ownerUid], request)) {
      _requests.remove(ownerUid);
      try {
        await store.clear(request.draft.uid);
      } catch (_) {}
    }
  }
}
