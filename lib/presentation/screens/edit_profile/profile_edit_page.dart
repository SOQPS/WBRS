import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/presentation/screens/auth/login_screen/login_page.dart';
import 'package:wbrs/service/auth_service.dart';
import 'package:wbrs/service/database_service.dart';
import 'package:wbrs/service/pending_write.dart';
import 'package:wbrs/service/profile_delete_service.dart';
import 'package:wbrs/service/profile_photo_upload.dart';
import 'package:wbrs/service/session_service.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/geo_catalog.dart';
import 'package:wbrs/shared/group_avatar.dart';
import 'package:wbrs/shared/meeting_location_fields.dart';
import 'package:wbrs/shared/profile_composition.dart';

class ProfilePageEdit extends StatefulWidget {
  const ProfilePageEdit(
      {super.key,
      required this.email,
      required this.userName,
      required this.about,
      required this.age,
      required this.deti,
      required this.rost,
      required this.city,
      required this.hobbi});
  final String userName, email, about, age, rost, city, hobbi;
  final bool deti;
  @override
  State<ProfilePageEdit> createState() => _ProfilePageEditState();
}

class _ProfilePageEditState extends State<ProfilePageEdit> {
  late final String? _owner = firebaseAuth.currentUser?.uid;
  late final bool _readyAtOpen;
  bool _sessionInvalidated = false;
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.userName);
  late final _age = TextEditingController(text: widget.age);
  late final _height = TextEditingController(text: widget.rost);
  late final _about = TextEditingController(text: widget.about);
  late final _interests = TextEditingController(text: widget.hobbi);
  late bool _children = widget.deti;
  late Future<DocumentSnapshot<Map<String, dynamic>>> _loaded = _load();
  GeoCountry? _country;
  String? _region;
  XFile? _image;
  String? _reservedPhotoPath;
  DocumentReference<Map<String, dynamic>>? _reservedPhotoDoc;
  ({
    String path,
    DocumentReference<Map<String, dynamic>> document,
    ProfilePhotoUploadResult result
  })? _stagedPhoto;
  bool _working = false, _deleting = false;
  bool _locationOnly = false;
  PendingWrite? _pending;
  String? _notice;
  double? _photoProgress;
  bool get _sameSession =>
      !_sessionInvalidated &&
      _owner != null &&
      firebaseAuth.currentUser?.uid == _owner;

  @override
  void initState() {
    super.initState();
    _readyAtOpen = SessionService.readyUserId.value == _owner && _owner != null;
    SessionService.readyUserId.addListener(_readyChanged);
  }

  void _readyChanged() {
    if (_readyAtOpen &&
        !_sessionInvalidated &&
        SessionService.readyUserId.value != _owner) {
      _sessionInvalidated = true;
      if (mounted) setState(() {});
    }
  }

  Future<DocumentSnapshot<Map<String, dynamic>>> _load() {
    final future = firebaseFirestore
        .collection('users')
        .doc(_owner)
        .get()
        .timeout(const Duration(seconds: 15));
    future.ignore();
    return future;
  }

  @override
  void dispose() {
    SessionService.readyUserId.removeListener(_readyChanged);
    for (final c in [_name, _age, _height, _about, _interests]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _choosePhoto() async {
    if (_working || _pending != null) return;
    try {
      final pickerTimer = Stopwatch()..start();
      final photo = await ImagePicker().pickImage(
          source: ImageSource.gallery,
          imageQuality: 76,
          maxWidth: 1440,
          maxHeight: 1440);
      profilePhotoMetric('picker_return', pickerTimer.elapsed,
          count: photo == null ? 0 : 1);
      if (mounted && _sameSession && photo != null) {
        setState(() {
          _image = photo;
          _stagedPhoto = null;
          _reservedPhotoPath = null;
          _reservedPhotoDoc = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() =>
            _notice = 'Не удалось открыть фотографии. Попробуйте ещё раз.');
      }
    }
  }

  Future<void> _save() async {
    if (_working || !_sameSession) return;
    if (_pending == null) {
      _locationOnly = false;
      if (!_form.currentState!.validate()) return;
      if (_country == null || (_region ?? '').isEmpty) {
        setState(() => _notice = 'Выберите страну и регион.');
        return;
      }
      final user = firebaseAuth.currentUser!;
      final owner = _owner!;
      final country = _country!;
      final profile = firebaseFirestore.collection('users').doc(owner);
      final photo = _image;
      final imageDoc = photo == null
          ? null
          : _reservedPhotoPath == photo.path
              ? _reservedPhotoDoc
              : profile.collection('images').doc();
      if (photo != null) {
        _reservedPhotoPath = photo.path;
        _reservedPhotoDoc = imageDoc;
      }
      final updates = <String, dynamic>{
        'fullName': _name.text.trim(),
        'age': int.parse(_age.text.trim()),
        'rost': _height.text.trim(),
        'about': _about.text.trim(),
        'hobbi': _interests.text.trim(),
        'deti': _children,
        'country': country.name,
        'countryCode': country.code,
        'languageGroup': country.languageGroup,
        'countrySegment': country.segment,
        'region': _region,
        'city': _region,
      };
      _deleting = false;
      _pending = PendingWrite(() async {
        ProfilePhotoUploadResult? uploaded =
            _stagedPhoto?.path == photo?.path ? _stagedPhoto?.result : null;
        if (photo != null) {
          if (uploaded == null) {
            final ref = FirebaseStorage.instance
                .ref('users/$owner/photos/${imageDoc!.id}.jpg');
            uploaded = await const ProfilePhotoUpload().upload(
                file: File(photo.path),
                imageRef: ref,
                thumbnailRef: FirebaseStorage.instance
                    .ref('users/$owner/photos/thumbs/${imageDoc.id}.jpg'),
                onProgress: (value) {
                  if (mounted &&
                      _sameSession &&
                      (_photoProgress == null ||
                          (value - _photoProgress!).abs() >= .01 ||
                          value == 1)) {
                    setState(() => _photoProgress = value);
                  }
                });
            _stagedPhoto =
                (path: photo.path, document: imageDoc, result: uploaded);
          }
        }
        if (firebaseAuth.currentUser?.uid != owner) {
          throw StateError('Сеанс завершён');
        }
        final batch = firebaseFirestore.batch();
        batch.update(profile, {
          ...updates,
          if (uploaded != null) 'profilePic': uploaded.url,
          if (uploaded != null)
            'profilePicThumb': uploaded.thumbnailUrl ?? FieldValue.delete(),
        });
        if (uploaded != null) {
          batch.set(imageDoc!, {
            'url': uploaded.url,
            if (uploaded.thumbnailUrl != null)
              'thumbnailUrl': uploaded.thumbnailUrl,
          });
        }
        final writeTimer = Stopwatch()..start();
        await batch.commit();
        profilePhotoMetric('profile_write', writeTimer.elapsed);
        if (firebaseAuth.currentUser?.uid != owner) {
          throw StateError('Сеанс завершён');
        }
        // Keep the primary Firestore profile atomic. A later Auth synchronization
        // error is reported as partial success, never as loss of saved fields.
        final metadataTimer = Stopwatch()..start();
        try {
          await Future.wait([
            user.updateDisplayName(updates['fullName'] as String),
            if (uploaded != null) user.updatePhotoURL(uploaded.url),
          ]).timeout(const Duration(seconds: 10));
        } catch (_) {
          throw const _ProfileMetadataIncomplete();
        } finally {
          profilePhotoMetric('auth_metadata', metadataTimer.elapsed);
        }
      });
    }
    await _wait();
  }

  Future<void> _saveLocation() async {
    if (_working || _pending != null || !_sameSession) return;
    final country = _country;
    final region = _region;
    if (country == null || region == null || region.isEmpty) {
      setState(() => _notice = 'Выберите страну и регион.');
      return;
    }
    _locationOnly = true;
    _deleting = false;
    _pending = PendingWrite(() => DatabaseService(uid: _owner)
        .updateUserLocation(country: country, region: region));
    await _wait();
  }

  Future<void> _delete() async {
    if (_working || _pending != null || !_sameSession) return;
    final password = await showDialog<String>(
        context: context, builder: (_) => const _DeleteProfileDialog());
    if (!mounted || password == null || !_sameSession) return;
    _locationOnly = false;
    _deleting = true;
    _pending = PendingWrite(() => ProfileDeleteService().delete(password));
    await _wait();
  }

  Future<void> _wait() async {
    if (_working || _pending == null) return;
    setState(() {
      _working = true;
      _notice = null;
    });
    try {
      final known = await _pending!.wait(
          timeout: _locationOnly || _image == null
              ? const Duration(seconds: 15)
              : const Duration(minutes: 3));
      if (!mounted) return;
      if (!known) {
        setState(() => _notice =
            'Подтверждение ещё не получено. Проверьте результат без повторной отправки.');
        return;
      }
      _pending = null;
      if (!_locationOnly) {
        _stagedPhoto = null;
        _reservedPhotoPath = null;
        _reservedPhotoDoc = null;
      }
      if (_deleting) {
        await AuthService().signOut();
        if (!mounted) return;
        Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => const LoginPage()), (_) => false);
      } else if (_sameSession) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.tr('Профиль сохранён'))));
        if (_locationOnly) {
          // Keep the form and any unsaved text/photo selection intact.
          setState(() => _loaded = _load());
        } else {
          Navigator.of(context).pop();
        }
      }
    } on ProfileDeletionIncomplete {
      if (mounted) {
        setState(() {
          _pending = null;
          _notice =
              'Профиль скрыт, но удаление аккаунта не завершено. Повторите попытку или обратитесь в поддержку.';
        });
      }
    } on _ProfileMetadataIncomplete {
      if (mounted) {
        setState(() {
          _pending = null;
          _notice =
              'Профиль сохранён, но данные входа не обновились. Войдите снова.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _pending = null;
          _notice = _deleting
              ? 'Не удалось удалить профиль. Проверьте пароль и подключение.'
              : !_locationOnly && _image != null && _stagedPhoto == null
                  ? 'Не удалось загрузить фотографии.'
                  : 'Не удалось сохранить изменения. Попробуйте ещё раз.';
        });
      }
    } finally {
      if (mounted)
        setState(() {
          _working = false;
          _photoProgress = null;
        });
    }
  }

  @override
  Widget build(BuildContext context) => ClrsScaffold(
      appBar: AppBar(title: Text(context.tr('Редактировать профиль'))),
      body: FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          future: _loaded,
          builder: (context, snapshot) {
            if (snapshot.hasError || !_sameSession) {
              return Center(
                  child: ClrsPanel(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(context.tr('Не удалось загрузить профиль.')),
                TextButton(
                    onPressed: () => setState(() {
                          _loaded = _load();
                        }),
                    child: Text(context.tr('Повторить')))
              ])));
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final data = snapshot.data!.data() ?? <String, dynamic>{};
            final disabled = _working || _pending != null;
            return ListView(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 24),
                children: [
                  const ClrsBrandHeader(),
                  Center(
                      child: _image == null
                          ? GroupAvatar(
                              url:
                                  '${data['profilePicThumb'] ?? data['profilePic'] ?? ''}',
                              group: '${data['группа'] ?? ''}',
                              size: 100)
                          : ClipOval(
                              child: Image.file(File(_image!.path),
                                  width: 100,
                                  height: 100,
                                  cacheWidth: 320,
                                  fit: BoxFit.cover))),
                  Align(
                      child: TextButton.icon(
                          onPressed: disabled ? null : _choosePhoto,
                          icon: const Icon(Icons.add_a_photo_outlined),
                          label: Text(context.tr('Изменить главное фото')))),
                  ProfileSection(
                      title: context.tr('Обо мне'),
                      child: Form(
                          key: _form,
                          child: Column(children: [
                            _field(_name, 'Имя', disabled,
                                validator: (s) => (s ?? '').trim().isEmpty
                                    ? context.tr('Введите имя')
                                    : null),
                            _field(_age, 'Возраст', disabled, number: true,
                                validator: (s) {
                              final age = int.tryParse(s ?? '');
                              return age == null || age < 18 || age > 100
                                  ? context.tr(
                                      'Возраст должен быть от 18 до 100 лет')
                                  : null;
                            }),
                            _field(_height, 'Рост', disabled,
                                number: true,
                                validator: (s) => (s ?? '').trim().isEmpty
                                    ? context.tr('Укажите рост')
                                    : null),
                            AbsorbPointer(
                                absorbing: disabled,
                                child: MeetingLocationFields(
                                    countryCode:
                                        data['countryCode']?.toString(),
                                    region: data['region']?.toString(),
                                    onChanged: (country, region) {
                                      _country = country;
                                      _region = region;
                                    })),
                            if ((data['countryCode']?.toString().trim() ?? '')
                                    .isEmpty ||
                                (data['region']?.toString().trim() ?? '')
                                    .isEmpty)
                              Align(
                                  alignment: Alignment.centerLeft,
                                  child: TextButton.icon(
                                      key: const ValueKey(
                                          'profile-location-save'),
                                      onPressed:
                                          disabled ? null : _saveLocation,
                                      icon: const Icon(
                                          Icons.location_on_outlined),
                                      label: Text(context.tr('Сохранить')))),
                            const SizedBox(height: 12),
                            SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text(context.tr('Есть дети')),
                                value: _children,
                                onChanged: disabled
                                    ? null
                                    : (value) =>
                                        setState(() => _children = value)),
                            _field(_interests, 'Интересы и увлечения', disabled,
                                multiline: true,
                                validator: (s) => (s ?? '').trim().length < 20
                                    ? context.tr('Минимум 20 символов')
                                    : null),
                            _field(_about, 'О себе', disabled,
                                multiline: true,
                                validator: (s) => (s ?? '').trim().length < 20
                                    ? context.tr('Минимум 20 символов')
                                    : null),
                          ]))),
                  if (_working) LinearProgressIndicator(value: _photoProgress),
                  if (_notice != null)
                    Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(context.tr(_notice!))),
                  const SizedBox(height: 14),
                  Align(
                      child: ElevatedButton(
                          onPressed: _working
                              ? null
                              : _pending != null
                                  ? _wait
                                  : _save,
                          child: Text(context.tr(_pending != null
                              ? 'Проверить результат'
                              : 'Сохранить')))),
                  const SizedBox(height: 20),
                  TextButton.icon(
                      onPressed: disabled ? null : _delete,
                      icon: const Icon(Icons.delete_outline),
                      label: Text(context.tr('Удалить профиль'))),
                ]);
          }));

  Widget _field(TextEditingController controller, String label, bool disabled,
          {bool number = false,
          bool multiline = false,
          FormFieldValidator<String>? validator}) =>
      Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextFormField(
              controller: controller,
              enabled: !disabled,
              keyboardType: number
                  ? TextInputType.number
                  : multiline
                      ? TextInputType.multiline
                      : TextInputType.text,
              minLines: multiline ? 3 : 1,
              maxLines: multiline ? null : 1,
              scrollPhysics:
                  multiline ? const NeverScrollableScrollPhysics() : null,
              decoration: InputDecoration(
                  labelText: context.tr(label), alignLabelWithHint: multiline),
              validator: validator));
}

class _ProfileMetadataIncomplete implements Exception {
  const _ProfileMetadataIncomplete();
}

class _DeleteProfileDialog extends StatefulWidget {
  const _DeleteProfileDialog();
  @override
  State<_DeleteProfileDialog> createState() => _DeleteProfileDialogState();
}

class _DeleteProfileDialogState extends State<_DeleteProfileDialog> {
  String _password = '';
  @override
  Widget build(BuildContext context) => AlertDialog(
          title: Text(context.tr('Удалить профиль?')),
          content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(context.tr(
                'Профиль станет недоступен другим пользователям. Для подтверждения введите пароль.')),
            const SizedBox(height: 12),
            TextField(
                obscureText: true,
                decoration: InputDecoration(labelText: context.tr('Пароль')),
                onChanged: (value) => setState(() => _password = value)),
          ])),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(context.tr('Отмена'))),
            TextButton(
                onPressed: _password.isEmpty
                    ? null
                    : () => Navigator.pop(context, _password),
                child: Text(context.tr('Удалить профиль')))
          ]);
}
