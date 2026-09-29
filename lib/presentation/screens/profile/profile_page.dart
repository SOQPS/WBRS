import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/app/widgets/bottom_nav_bar.dart';
import 'package:wbrs/app/widgets/drawer.dart';
import 'package:wbrs/app/widgets/show_image.dart';
import 'package:wbrs/core/utils/account_destination.dart'
    show savedAccountGroup;
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/localization/language_picker.dart';
import 'package:wbrs/presentation/screens/auth/login_screen/login_page.dart';
import 'package:wbrs/presentation/screens/edit_profile/profile_edit_page.dart';
import 'package:wbrs/presentation/screens/feed/profile_wall_page.dart';
import 'package:wbrs/presentation/screens/list_of_users/profiles_list.dart';
import 'package:wbrs/presentation/screens/list_of_visiters/visiters.dart';
import 'package:wbrs/service/auth_service.dart';
import 'package:wbrs/service/pending_write.dart';
import 'package:wbrs/service/profile_photo_upload.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/clrs_brand.dart';
import 'package:wbrs/shared/group_badge.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/shared/profile_composition.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage(
      {super.key,
      required this.email,
      required this.userName,
      required this.about,
      required this.age,
      required this.pol,
      required this.group,
      required this.deti,
      required this.rost,
      required this.city,
      required this.hobbi});
  final String email, userName, about, age, pol, group, rost, city, hobbi;
  final bool deti;
  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  late final String? _owner = firebaseAuth.currentUser?.uid;
  late Stream<DocumentSnapshot<Map<String, dynamic>>> _profile;
  late Stream<QuerySnapshot<Map<String, dynamic>>> _photos;
  bool _working = false;
  PendingWrite? _pending;
  Future<void> Function()? _retryPhotoUpload;
  double? _photoProgress;
  String? _notice;
  bool get _sameSession =>
      _owner != null && firebaseAuth.currentUser?.uid == _owner;
  @override
  void initState() {
    super.initState();
    selectedIndex = 4;
    _subscribe();
  }

  void _subscribe() {
    if (!_sameSession) {
      _profile = Stream.error(StateError('Сеанс завершён'));
      _photos = const Stream.empty();
      return;
    }
    final ref = firebaseFirestore.collection('users').doc(_owner);
    _profile = ref.snapshots();
    _photos = ref.collection('images').snapshots();
  }

  void _open(Widget page) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  void _edit(Map<String, dynamic> d) {
    globalPol = '${d['pol'] ?? widget.pol}';
    _open(ProfilePageEdit(
        email: widget.email,
        userName: '${d['fullName'] ?? widget.userName}',
        about: '${d['about'] ?? widget.about}',
        age: '${d['age'] ?? widget.age}',
        deti: d['deti'] == true,
        rost: '${d['rost'] ?? widget.rost}',
        city: '${d['region'] ?? widget.city}',
        hobbi: '${d['hobbi'] ?? widget.hobbi}'));
  }

  Future<void> _waitForWrite(Future<void> Function()? start,
      {Duration timeout = const Duration(seconds: 15)}) async {
    if (_working || !_sameSession) return;
    setState(() {
      _working = true;
      _notice = null;
    });
    try {
      _pending ??= PendingWrite(start!);
      final confirmed = await _pending!.wait(timeout: timeout);
      if (!mounted || !_sameSession) return;
      setState(() {
        if (confirmed) {
          _pending = null;
          _retryPhotoUpload = null;
          _photoProgress = null;
        } else {
          _notice =
              'Подтверждение ещё не получено. Проверьте результат без повторной отправки.';
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _pending = null;
          _photoProgress = null;
          _notice = _retryPhotoUpload == null
              ? 'Не удалось сохранить изменения. Попробуйте ещё раз.'
              : 'Не удалось загрузить фотографии.';
        });
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _addPhotos() async {
    if (_working || _pending != null || !_sameSession) return;
    setState(() => _working = true);
    List<XFile> selected;
    final pickerTimer = Stopwatch()..start();
    try {
      selected = await ImagePicker()
          .pickMultiImage(imageQuality: 80, maxWidth: 1600, maxHeight: 1600);
      profilePhotoMetric('picker_return', pickerTimer.elapsed,
          count: selected.length);
    } catch (_) {
      if (mounted) {
        setState(() {
          _working = false;
          _notice = 'Не удалось открыть фотографии. Попробуйте ещё раз.';
        });
      }
      return;
    }
    if (!mounted || !_sameSession) return;
    setState(() => _working = false);
    if (selected.isEmpty) return;
    final owner = _owner!;
    final collection =
        firebaseFirestore.collection('users').doc(owner).collection('images');
    // Reserve each ID once. A pending check observes the same upload/write.
    final items = [for (final file in selected) (file, collection.doc())];
    final uploaded = <String, ProfilePhotoUploadResult>{};
    final saved = <String>{};
    final fractions = <String, double>{};
    Future<void> upload() async {
      var next = 0;
      Future<void> worker() async {
        while (next < items.length) {
          final item = items[next++];
          final id = item.$2.id;
          if (saved.contains(id)) continue;
          if (firebaseAuth.currentUser?.uid != owner) {
            throw StateError('Сеанс завершён');
          }
          final ref =
              FirebaseStorage.instance.ref('users/$owner/photos/$id.jpg');
          final result = uploaded[id] ??
              await const ProfilePhotoUpload().upload(
                  file: File(item.$1.path),
                  imageRef: ref,
                  thumbnailRef: FirebaseStorage.instance
                      .ref('users/$owner/photos/thumbs/$id.jpg'),
                  onProgress: (progress) {
                    fractions[id] = progress;
                    final overall = fractions.values.fold<double>(
                            0, (accumulated, value) => accumulated + value) /
                        items.length;
                    if (mounted &&
                        _sameSession &&
                        (_photoProgress == null ||
                            (overall - _photoProgress!).abs() >= .01 ||
                            overall == 1)) {
                      setState(() => _photoProgress = overall);
                    }
                  });
          uploaded[id] = result;
          if (firebaseAuth.currentUser?.uid != owner) {
            throw StateError('Сеанс завершён');
          }
          final writeTimer = Stopwatch()..start();
          await item.$2.set({
            'url': result.url,
            if (result.thumbnailUrl != null)
              'thumbnailUrl': result.thumbnailUrl,
          });
          profilePhotoMetric('profile_write', writeTimer.elapsed);
          saved.add(id);
        }
      }

      await Future.wait([
        for (var i = 0; i < items.length && i < 2; i++) worker(),
      ]);
    }

    _retryPhotoUpload = upload;
    await _waitForWrite(upload, timeout: const Duration(minutes: 3));
  }

  @override
  Widget build(BuildContext context) => ClrsScaffold(
      drawer: const MyDrawer(),
      bottomNavigationBar: const MyBottomNavigationBar(),
      extendBodyBehindAppBar: true,
      appBar: AppBar(
          backgroundColor: Colors.transparent, title: const ClrsLogo(size: 34)),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: _profile,
          builder: (context, snapshot) {
            if (snapshot.hasError || !_sameSession) return _error();
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            if (!snapshot.data!.exists) return _error();
            final d = snapshot.data!.data()!;
            final currentGroup = savedAccountGroup(d) ?? '';
            return ListView(
                padding: const EdgeInsets.only(bottom: 24),
                children: [
                  ProfilePortrait(
                      photo: '${d['profilePic'] ?? ''}',
                      name: '${d['fullName'] ?? widget.userName}',
                      age: '${d['age'] ?? widget.age}',
                      group: currentGroup,
                      own: true,
                      gender: '${d['pol'] ?? widget.pol}',
                      location: profileLocation(d, context: context),
                      online: d['online'] == true,
                      status: relationshipLabel(d['relationStatus'])),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(
                        child: _ProfileQuickAction(
                            icon: Icons.visibility_outlined,
                            label: context.tr('Гости'),
                            onTap: () => _open(MyVisitersPage(
                                visiters: firebaseFirestore
                                    .collection('users')
                                    .doc(_owner)
                                    .collection('visiters')
                                    .orderBy('lastVisitTs', descending: true)
                                    .snapshots())))),
                    const SizedBox(width: 6),
                    Expanded(
                        child: _ProfileQuickAction(
                            icon: Icons.edit_outlined,
                            label: context.tr('Редактировать'),
                            onTap: () => _edit(d))),
                    const SizedBox(width: 6),
                    Expanded(
                        child: _ProfileQuickAction(
                            icon: Icons.people_outline,
                            label: context.tr('Люди'),
                            onTap: () => _open(ProfilesList(
                                group: currentGroup, startPosition: 0)))),
                  ]),
                  PopupMenuButton<String>(
                      enabled: !_working && _pending == null,
                      tooltip: context.tr('Статус'),
                      onSelected: (value) => _waitForWrite(() =>
                          firebaseFirestore
                              .collection('users')
                              .doc(_owner)
                              .update({'relationStatus': value})),
                      itemBuilder: (_) => [
                            PopupMenuItem(
                                value: 'свободен',
                                child: Text(context.tr('Свободен'))),
                            PopupMenuItem(
                                value: 'занят',
                                child: Text(context.tr('Занят')))
                          ],
                      child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 7),
                          child: Text(context.tr('Изменить статус')))),
                  // Keep one stable list child for transient upload states.
                  // Adding/removing siblings used to recreate the photos'
                  // broadcast StreamBuilder and lose its current snapshot.
                  Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_working)
                          LinearProgressIndicator(value: _photoProgress),
                        if (_notice != null)
                          Padding(
                              padding: const EdgeInsets.only(top: 10),
                              child: Text(context.tr(_notice!))),
                        if (_pending != null && !_working)
                          TextButton(
                              onPressed: () => _waitForWrite(null,
                                  timeout: const Duration(minutes: 3)),
                              child: Text(context.tr('Проверить результат'))),
                        if (_pending == null &&
                            !_working &&
                            _retryPhotoUpload != null)
                          TextButton(
                              onPressed: () => _waitForWrite(_retryPhotoUpload,
                                  timeout: const Duration(minutes: 3)),
                              child: Text(context.tr('Повторить'))),
                      ]),
                  ProfileSection(
                      key: const ValueKey('profile-photos-section'),
                      title: context.tr('Фотографии'),
                      action: TextButton.icon(
                          icon: const Icon(Icons.add_photo_alternate_outlined,
                              size: 18),
                          label: Text(context.tr('Добавить')),
                          onPressed:
                              _working || _pending != null ? null : _addPhotos),
                      child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                          stream: _photos,
                          builder: (context, photos) {
                            if (photos.hasError) {
                              return Text(context
                                  .tr('Не удалось загрузить фотографии.'));
                            }
                            if (!photos.hasData) {
                              return const LinearProgressIndicator();
                            }
                            final original = photos.data!.docs
                                .map((x) => '${x.data()['url'] ?? ''}')
                                .toList();
                            final rows = photos.data!.docs
                                .where((x) =>
                                    '${x.data()['url'] ?? ''}'.isNotEmpty)
                                .toList()
                              ..sort(
                                  (a, b) => a.data()['url'] == d['profilePic']
                                      ? -1
                                      : b.data()['url'] == d['profilePic']
                                          ? 1
                                          : 0);
                            final urls =
                                rows.map((x) => '${x.data()['url']}').toList();
                            final thumbnails = rows
                                .map((x) =>
                                    '${x.data()['thumbnailUrl'] ?? x.data()['url']}')
                                .toList();
                            return ProfilePhotoStrip(
                                urls: urls,
                                thumbnailUrls: thumbnails,
                                onTap: (index) => _open(ShowImage(
                                    urls: urls,
                                    initList: original,
                                    index: index,
                                    snapshot: photos)));
                          })),
                  ProfileSection(
                      title: context.tr('Подарки'),
                      child: _gifts(d['presentedGifts'])),
                  ProfileSection(
                      title: context.tr('Обо мне'),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            ProfileFacts(data: d),
                            const SizedBox(height: 8),
                            Align(
                                alignment: Alignment.centerLeft,
                                child: ConstrainedBox(
                                    constraints:
                                        const BoxConstraints(maxWidth: 260),
                                    child: ElevatedButton.icon(
                                        key: const ValueKey(
                                            'profile-bottom-edit'),
                                        onPressed: () => _edit(d),
                                        icon: const Icon(Icons.edit_outlined),
                                        style: ElevatedButton.styleFrom(
                                            backgroundColor:
                                                LrsTheme.actionGlass,
                                            foregroundColor: LrsTheme.text,
                                            minimumSize: const Size(0, 38),
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 12, vertical: 7)),
                                        label: Text(context
                                            .tr('Редактировать профиль')))))
                          ])),
                  ProfileSection(
                      title: context.tr('Вам подходят'),
                      child: Wrap(spacing: 12, runSpacing: 12, children: [
                        for (final g in getListOfGroup(currentGroup))
                          GroupBadge(group: g, size: 24, showLabel: true)
                      ])),
                  // Financial display is read-only and retains its existing source.
                  Padding(
                      padding: const EdgeInsets.only(top: 14),
                      child: Text(
                          '${context.tr('Ваш баланс: ')}${context.l10n.number(globalBalance)}')),
                  ProfileSection(
                      title: context.tr('Стена'),
                      child: OutlinedButton.icon(
                          icon: const Icon(Icons.article_outlined, size: 18),
                          label: Text(context.tr('Стена')),
                          onPressed: () => _open(ProfileWallPage(
                              userUid: _owner!,
                              userName:
                                  '${d['fullName'] ?? widget.userName}')))),
                  const ClrsValuesFooter(),
                ]
                    .map((child) => child is ProfilePortrait
                        ? child
                        : Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            child: child))
                    .toList());
          }));

  Widget _error() => Center(
      child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: ClrsPanel(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(context.tr('Не удалось загрузить профиль.')),
            TextButton(
                onPressed: () => setState(_subscribe),
                child: Text(context.tr('Повторить')))
          ]))));

  Widget _gifts(Object? value) {
    final gifts = value is Map ? value : const {};
    if (gifts.isEmpty) {
      return Text(context.tr('Пока нет подарков'),
          style: const TextStyle(color: LrsTheme.muted));
    }
    final entries = gifts.entries.toList();
    return SizedBox(
        height: 96,
        child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: entries.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (_, index) => SizedBox(
                width: 88,
                child: Stack(children: [
                  Positioned.fill(
                      child: Image.asset('${entries[index].key}',
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) =>
                              const Icon(Icons.card_giftcard))),
                  Align(
                      alignment: Alignment.bottomRight,
                      child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                              color: const Color(0x995E3C2A),
                              borderRadius: BorderRadius.circular(12)),
                          child: Text('${entries[index].value}'))),
                ]))));
  }
}

class _ProfileQuickAction extends StatelessWidget {
  const _ProfileQuickAction(
      {required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
      button: true,
      label: label,
      child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: ClrsPanel(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 54),
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(icon, size: 22, color: LrsTheme.peachLight),
                        const SizedBox(height: 4),
                        SizedBox(
                            width: double.infinity,
                            child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(label,
                                    maxLines: 1,
                                    softWrap: false,
                                    style: const TextStyle(fontSize: 12))))
                      ])))));
}

class ProfileSettingsPage extends StatefulWidget {
  const ProfileSettingsPage({super.key});
  @override
  State<ProfileSettingsPage> createState() => _ProfileSettingsState();
}

class _ProfileSettingsState extends State<ProfileSettingsPage> {
  final _form = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _saving = false;
  late final String? _owner = firebaseAuth.currentUser?.uid;
  PendingWrite? _pending;
  String? _error;
  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || (_pending == null && !_form.currentState!.validate())) {
      return;
    }
    final user = firebaseAuth.currentUser;
    if (user == null || user.uid != _owner) return;
    final password = _password.text;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      _pending ??= PendingWrite(() => user.updatePassword(password));
      final confirmed =
          await _pending!.wait(timeout: const Duration(seconds: 15));
      if (!mounted || firebaseAuth.currentUser?.uid != user.uid) return;
      if (!confirmed) {
        setState(() => _error =
            'Подтверждение ещё не получено. Проверьте результат без повторной отправки.');
        return;
      }
      _pending = null;
      await AuthService().signOut();
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const LoginPage()), (_) => false);
    } catch (_) {
      if (mounted) {
        setState(() {
          _pending = null;
          _error =
              'Не удалось сменить пароль. Для этого может потребоваться повторный вход.';
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => ClrsScaffold(
      appBar: AppBar(title: Text(context.tr('Настройки'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const ClrsBrandHeader(),
        ProfileSection(
            title: context.tr('Язык'),
            child: const Align(
                alignment: Alignment.centerLeft,
                child: LanguagePickerButton())),
        ProfileSection(
            title: context.tr('Сменить пароль'),
            child: Form(
                key: _form,
                child: Column(children: [
                  TextFormField(
                      controller: _password,
                      enabled: !_saving && _pending == null,
                      obscureText: true,
                      decoration: InputDecoration(
                          labelText: context.tr('Новый пароль')),
                      validator: (s) => (s?.length ?? 0) < 6
                          ? context
                              .tr('Пароль должен содержать не менее 6 символов')
                          : null),
                  const SizedBox(height: 12),
                  TextFormField(
                      controller: _confirm,
                      enabled: !_saving && _pending == null,
                      obscureText: true,
                      decoration: InputDecoration(
                          labelText: context.tr('Повторите пароль')),
                      validator: (s) => s != _password.text
                          ? context.tr('Пароли не совпадают!')
                          : null),
                  if (_error != null)
                    Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(context.tr(_error!))),
                  const SizedBox(height: 12),
                  ElevatedButton(
                      onPressed: _saving ? null : _save,
                      child: Text(context.tr(_saving
                          ? 'Сохранение…'
                          : _pending != null
                              ? 'Проверить результат'
                              : 'Сменить пароль'))),
                ]))),
        const ClrsValuesFooter(),
      ]));
}
