import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/app/widgets/fullscreen_image_slider.dart';
import 'package:wbrs/core/utils/account_destination.dart'
    show savedAccountGroup;
import 'package:wbrs/core/utils/compatibility.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/presentation/screens/about_app/about_app.dart';
import 'package:wbrs/presentation/screens/chat_screen/chatscreen.dart';
import 'package:wbrs/presentation/screens/feed/profile_wall_page.dart';
import 'package:wbrs/presentation/screens/shop/shop.dart';
import 'package:wbrs/service/notifications.dart';
import 'package:wbrs/service/invisibility_state.dart';
import 'package:wbrs/service/pending_write.dart';
import 'package:wbrs/service/social_service.dart';
import 'package:wbrs/service/admin_private_directory.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/clrs_brand.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/shared/profile_composition.dart';

class SomebodyProfile extends StatefulWidget {
  const SomebodyProfile(
      {super.key,
      required this.uid,
      required this.photoUrl,
      required this.name,
      required this.userInfo,
      this.privateEmail = adminPrivateEmailEnabled});
  final bool privateEmail;
  final String uid, photoUrl, name;
  final Map userInfo;
  @override
  State<SomebodyProfile> createState() => _SomebodyProfileState();
}

class _SomebodyProfileState extends State<SomebodyProfile> {
  AdminPrivateDirectory? _privateDirectory;
  late final String? _owner = firebaseAuth.currentUser?.uid;
  late final SocialService _social = SocialService();
  late Stream<DocumentSnapshot<Map<String, dynamic>>> _profile;
  late Stream<QuerySnapshot<Map<String, dynamic>>> _photos;
  Future<String>? _chat;
  bool _chatToGift = false, _busy = false;
  PendingWrite? _friendRequest;
  bool _friendSent = false;
  String? _notice;
  bool get _sameSession =>
      _owner != null && firebaseAuth.currentUser?.uid == _owner;
  @override
  void initState() {
    super.initState();
    if (widget.privateEmail)
      _privateDirectory = AdminPrivateDirectory(enabled: true);
    _subscribe();
    unawaited(_recordVisit());
  }

  @override
  void dispose() {
    unawaited(_privateDirectory?.dispose());
    super.dispose();
  }

  void _subscribe() {
    final ref = firebaseFirestore.collection('users').doc(widget.uid);
    _profile = ref.snapshots();
    _photos = ref.collection('images').snapshots();
  }

  Future<void> _recordVisit() async {
    if (!_sameSession || _owner == widget.uid) return;
    final user = firebaseAuth.currentUser!;
    try {
      final me = await firebaseFirestore
          .collection('users')
          .doc(user.uid)
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 15));
      if (!_sameSession || !me.exists ||
          isInvisibleActive(me.data() ?? const <String, dynamic>{})) {
        return;
      }
      // Visit recording cannot activate, buy or change a paid period.
      await firebaseFirestore
          .collection('users')
          .doc(widget.uid)
          .collection('visiters')
          .doc(user.uid)
          .set({
        'uid': user.uid,
        'photoUrl': user.photoURL,
        'fullName': user.displayName,
        'lastVisitTs': DateTime.now(),
        'age': me.data()?['age'],
        'group': me.data()?['группа'],
        'city': me.data()?['city'],
        'country': me.data()?['country'],
        'region': me.data()?['region'],
      }, SetOptions(merge: true));
      if (!_sameSession) return;
      // Preserve the existing optional push integration, with no token logging.
      final token = await firebaseFirestore
          .collection('TOKENS')
          .doc(widget.uid)
          .get()
          .timeout(const Duration(seconds: 10));
      final value = token.data()?['token'];
      if (value is String && value.isNotEmpty && _sameSession) {
        await NotificationsService().sendPushMessageGroup(
            value,
            {
              'isChat': false,
              'chatId': user.uid,
              'message': '${user.displayName ?? ''} посетил/а ваш профиль',
            },
            '${me.data()?['fullName'] ?? ''}',
            1,
            user.uid);
      }
    } catch (_) {
      // Visit telemetry/push must not prevent viewing a permitted profile.
    }
  }

  Future<String> _findOrCreateChat(Map<String, dynamic> profile) async {
    if (!_sameSession || _owner == widget.uid) {
      throw StateError('Сеанс завершён');
    }
    final owner = _owner!;
    final user = firebaseAuth.currentUser!;
    final chats = firebaseFirestore.collection('chats');
    for (final pair in [(owner, widget.uid), (widget.uid, owner)]) {
      final found = await chats
          .where('user1', isEqualTo: pair.$1)
          .where('user2', isEqualTo: pair.$2)
          .limit(1)
          .get();
      if (!_sameSession) throw StateError('Сеанс завершён');
      if (found.docs.isNotEmpty) return found.docs.first.id;
    }
    final ids = [owner, widget.uid]..sort();
    // Stable UID identity avoids collisions of equal/changed display names.
    final id = 'direct_${ids[0].length}_${ids[0]}_${ids[1]}';
    final ref = chats.doc(id);
    await firebaseFirestore.runTransaction((transaction) async {
      if (!_sameSession) throw StateError('Сеанс завершён');
      final existing = await transaction.get(ref);
      if (existing.exists) return;
      transaction.set(ref, {
        'user1': owner,
        'user2': widget.uid,
        'user1Nickname': user.displayName ?? '',
        'user2Nickname': profile['fullName'] ?? widget.name,
        'user1_image': user.photoURL ?? '',
        'user2_image': profile['profilePic'] ?? widget.photoUrl,
        'lastMessage': '',
        'lastMessageSendBy': '',
        'lastMessageSendTs': DateTime.now(),
        'unreadMessage': 0,
        'chatId': id,
      });
    });
    // Chat lists query participants directly; no write into the other user's
    // profile is needed to open the chat (and would require broader rights).
    return id;
  }

  Future<void> _openChat(Map<String, dynamic> profile,
      {bool gift = false}) async {
    if (_busy || !_sameSession) return;
    // Choosing a gift does not require a chat write. Show the shop at once;
    // the recipient sheet loads chats in pages after it is visible.
    if (gift) {
      await Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => const ShopPage()));
      return;
    }
    setState(() {
      _busy = true;
      _notice = null;
    });
    if (_chat == null) {
      _chatToGift = false;
      _chat = _findOrCreateChat(profile);
      _chat!.ignore();
    }
    try {
      final id = await _chat!.timeout(const Duration(seconds: 15));
      if (!mounted || !_sameSession) return;
      final toGift = _chatToGift;
      _chat = null;
      await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => toGift
              ? const ShopPage()
              : ChatScreen(
                  chatWithUsername: '${profile['fullName'] ?? widget.name}',
                  photoUrl:
                      '${profile['profilePicThumb'] ?? profile['profilePic'] ?? widget.photoUrl}',
                  id: widget.uid,
                  chatId: id)));
    } on TimeoutException {
      if (mounted) {
        setState(() => _notice =
            'Подтверждение ещё не получено. Проверьте результат без повторной отправки.');
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _chat = null;
          _notice = 'Не удалось открыть чат. Попробуйте ещё раз.';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addFriend() async {
    if (_busy || !_sameSession || _friendSent) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      _friendRequest ??=
          PendingWrite(() => _social.sendFriendRequest(widget.uid));
      final confirmed =
          await _friendRequest!.wait(timeout: const Duration(seconds: 15));
      if (!mounted || !_sameSession) return;
      setState(() {
        if (confirmed) {
          _friendRequest = null;
          _friendSent = true;
          _notice = 'Заявка отправлена';
        } else {
          _notice =
              'Подтверждение ещё не получено. Проверьте результат без повторной отправки.';
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _friendRequest = null;
          _notice = 'Не удалось сохранить изменения. Попробуйте ещё раз.';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _report() async {
    final proceed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
                title: Text(context.tr('Пожаловаться')),
                content: Text(context.tr(
                    'Напишите в поддержку и укажите имя профиля и причину жалобы.')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: Text(context.tr('Отмена'))),
                  TextButton(
                      onPressed: () => Navigator.pop(dialogContext, true),
                      child: Text(context.tr('Написать в поддержку')))
                ]));
    if (proceed == true && mounted) await openSupportEmail(context);
  }

  @override
  Widget build(BuildContext context) => ClrsScaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
          backgroundColor: Colors.transparent,
          title: const ClrsLogo(size: 34),
          actions: [
            IconButton(
                tooltip: context.tr('Пожаловаться'),
                onPressed: _report,
                icon: const Icon(Icons.flag_outlined))
          ]),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: _profile,
          builder: (context, snapshot) {
            if (snapshot.hasError || !_sameSession) return _error();
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            if (!snapshot.data!.exists ||
                snapshot.data!.data()?['status'] == 'deleted') {
              return Center(child: Text(context.tr('Профиль недоступен')));
            }
            final d = snapshot.data!.data()!;
            final g = savedAccountGroup(d) ?? '';
            final matches =
                group.isNotEmpty && getListOfGroup(group).contains(g);
            final admin = const [
              'T4zb6OLzDgMh0qrfp3eEahNKmNl1',
              'lyNcv2xr33Ms6G9fI0bhBEcDKFj2',
              'vLeB8v4b1pUL8h5dtxJSkifF2v72'
            ].contains(_owner);
            return ListView(
                padding: const EdgeInsets.only(bottom: 24),
                children: [
                  ProfilePortrait(
                      photo: '${d['profilePic'] ?? widget.photoUrl}',
                      name: '${d['fullName'] ?? widget.name}',
                      age: '${d['age'] ?? ''}',
                      group: g,
                      gender: '${d['pol'] ?? ''}',
                      online: d['online'] == true,
                      location: profileLocation(d, context: context),
                      status: relationshipLabel(d['relationStatus'])),
                  if (matches)
                    Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(context.tr('Тип личности подходит вам'),
                            style:
                                const TextStyle(color: LrsTheme.peachLight))),
                  const SizedBox(height: 12),
                  Text(context.tr('Хорошие люди находят друг друга ♡'),
                      style: const TextStyle(color: LrsTheme.peachLight)),
                  const SizedBox(height: 12),
                  Wrap(spacing: 8, runSpacing: 4, children: [
                    OutlinedButton.icon(
                        onPressed:
                            _busy || _chat != null || _friendRequest != null
                                ? null
                                : () => _openChat(d, gift: true),
                        icon:
                            const Icon(Icons.card_giftcard_outlined, size: 18),
                        label: Text(context.tr('Подарить подарок'))),
                    OutlinedButton.icon(
                        onPressed: _busy || _friendRequest != null
                            ? null
                            : () => _openChat(d),
                        icon: const Icon(Icons.chat_bubble_outline, size: 18),
                        label: Text(context.tr(_chat != null
                            ? 'Проверить результат'
                            : 'Написать'))),
                    StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                        stream: firebaseFirestore.collection('users')
                            .doc(_owner).collection('friends')
                            .doc(widget.uid).snapshots(),
                        builder: (context, friend) =>
                            StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                                stream: firebaseFirestore.collection('users')
                                    .doc(_owner)
                                    .collection('friend_requests_sent')
                                    .doc(widget.uid).snapshots(),
                                builder: (context, sent) {
                                  final isFriend = friend.data?.exists == true;
                                  final wasSent = sent.data?.exists == true || _friendSent;
                                  return OutlinedButton.icon(
                                      onPressed: _busy || _chat != null ||
                                              isFriend || wasSent ||
                                              friend.hasError || sent.hasError ||
                                              !friend.hasData || !sent.hasData
                                          ? null
                                          : _addFriend,
                                      icon: const Icon(Icons.person_add_alt, size: 18),
                                      label: Text(context.tr(isFriend
                                          ? 'Уже в друзьях'
                                          : _friendRequest != null
                                              ? 'Проверить результат'
                                              : wasSent
                                                  ? 'Заявка отправлена'
                                                  : 'Добавить в друзья')));
                                })),
                  ]),
                  if (_busy) const LinearProgressIndicator(),
                  if (_notice != null)
                    Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(context.tr(_notice!))),
                  ProfileSection(
                      title: context.tr('Фотографии'),
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
                            final urls = <String>{
                              if ('${d['profilePic'] ?? ''}'.isNotEmpty)
                                '${d['profilePic']}',
                              ...photos.data!.docs
                                  .map((doc) => '${doc.data()['url'] ?? ''}')
                                  .where((s) => s.isNotEmpty)
                            }.toList();
                            final thumbnails = [
                              for (final url in urls)
                                if (url == '${d['profilePic'] ?? ''}' &&
                                    '${d['profilePicThumb'] ?? ''}'.isNotEmpty)
                                  '${d['profilePicThumb']}'
                                else
                                  photos.data!.docs
                                          .where(
                                              (doc) => doc.data()['url'] == url)
                                          .map((doc) =>
                                              '${doc.data()['thumbnailUrl'] ?? url}')
                                          .firstOrNull ??
                                      url,
                            ];
                            return ProfilePhotoStrip(
                                urls: urls,
                                thumbnailUrls: thumbnails,
                                onTap: (index) => Navigator.of(context).push(
                                    MaterialPageRoute(
                                        builder: (_) => FullscreenSliderDemo(
                                            imgList: urls,
                                            initialPage: index))));
                          })),
                  ProfileSection(
                      title: context.tr('Обо мне'),
                      child: ProfileFacts(data: d)),
                  if (widget.privateEmail)
                    AdminPrivateEmail(
                        directory: _privateDirectory!,
                        uid: widget.uid,
                        builder: (email) => ProfileSection(
                            title: context.tr('Электронная почта'),
                            child: SelectableText(email)))
                  else if (admin && d['email'] != null)
                    ProfileSection(
                        title: context.tr('Электронная почта'),
                        child: SelectableText('${d['email']}')),
                  ProfileSection(
                      title: context.tr('Стена'),
                      child: OutlinedButton.icon(
                          onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => ProfileWallPage(
                                      userUid: widget.uid,
                                      userName: widget.name))),
                          icon: const Icon(Icons.article_outlined, size: 18),
                          label: Text(context.tr('Стена')))),
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
          child: ClrsPanel(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(context.tr('Не удалось загрузить профиль.')),
        TextButton(
            onPressed: () => setState(_subscribe),
            child: Text(context.tr('Повторить'))),
      ])));
}
