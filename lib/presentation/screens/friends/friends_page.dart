import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/presentation/screens/list_of_users/show/somebody_profile.dart';
import 'package:wbrs/service/pending_write.dart';
import 'package:wbrs/service/social_service.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/group_avatar.dart';

class FriendsPage extends StatefulWidget {
  const FriendsPage({super.key, this.social});
  final SocialService? social;
  @override
  State<FriendsPage> createState() => _FriendsPageState();
}

class _FriendsPageState extends State<FriendsPage> {
  late final SocialService _social = widget.social ?? SocialService();
  late Stream<QuerySnapshot<Map<String, dynamic>>> _friends, _requests, _sent;
  final _sentProfiles = <String, Future<DocumentSnapshot<Map<String, dynamic>>>>{};
  final _search = TextEditingController();
  String _query = '';
  String? _notice;
  bool _busy = false, _opening = false;
  PendingWrite? _pending;
  StreamSubscription<User?>? _authSubscription;
  @override
  void initState() {
    super.initState();
    _subscribe();
    try {
      _authSubscription = firebaseAuth.authStateChanges().listen((_) {
        if (mounted) setState(() {});
      });
    } catch (_) {
      // FirebaseAuth test doubles may not expose this production stream.
    }
  }

  void _subscribe() {
    try {
      _friends = _social.friends();
    } catch (e) {
      _friends = Stream.error(e);
    }
    try {
      _requests = _social.friendRequests();
    } catch (e) {
      _requests = Stream.error(e);
    }
    try {
      _sent = _social.sentFriendRequests();
    } catch (e) {
      _sent = Stream.error(e);
    }
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _act(Future<void> Function()? operation) async {
    if (_busy || !_social.isCurrentSession) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      _pending ??= PendingWrite(operation!);
      final known = await _pending!.wait(timeout: const Duration(seconds: 15));
      if (!mounted) return;
      if (!_social.isCurrentSession) throw StateError('Сеанс завершён');
      setState(() {
        if (known) {
          _pending = null;
        } else {
          _notice =
              'Подтверждение ещё не получено. Проверьте результат без повторной отправки.';
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _pending = null;
          _notice = 'Не удалось сохранить изменения. Попробуйте ещё раз.';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(String uid) async {
    if (_opening || uid.isEmpty || !_social.isCurrentSession) return;
    setState(() => _opening = true);
    try {
      final doc = await firebaseFirestore
          .collection('users')
          .doc(uid)
          .get()
          .timeout(const Duration(seconds: 15));
      if (!mounted || !_social.isCurrentSession) return;
      if (!doc.exists || doc.data()?['status'] == 'deleted') {
        throw StateError('Профиль недоступен');
      }
      final d = doc.data()!;
      await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => SomebodyProfile(
              uid: uid,
              photoUrl: '${d['profilePic'] ?? ''}',
              name: _displayName(d, 0),
              userInfo: d)));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(context
                .tr('Не удалось открыть профиль. Попробуйте ещё раз.'))));
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  String _displayName(Map<String, dynamic> data, int kind) {
    final nickKey = kind == 0 ? 'nickName' : kind == 1 ? 'fromNickName' : 'toNickName';
    final legacyKey = kind == 0 ? 'fullName' : kind == 1 ? 'fromName' : 'toName';
    final nickname = data[nickKey]?.toString().trim() ?? '';
    return nickname.isNotEmpty
        ? nickname
        : data[legacyKey]?.toString().trim() ?? '';
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
      length: 3,
      child: ClrsScaffold(
          appBar: AppBar(
              title: Text(context.tr('Друзья')),
              bottom: TabBar(tabs: [
                Tab(text: context.tr('Друзья')),
                Tab(text: context.tr('Входящие')),
                Tab(text: context.tr('Исходящие')),
              ])),
          body: !_social.isCurrentSession
              ? Center(child: Text(context.tr('Сеанс завершён. Войдите снова')))
              : Column(children: [
            if (_busy || _opening) const LinearProgressIndicator(),
            if (_notice != null)
              Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(context.tr(_notice!))),
            if (_pending != null && !_busy)
              TextButton(
                  onPressed: () => _act(null),
                  child: Text(context.tr('Проверить результат'))),
            Expanded(child: TabBarView(children: [_list(0), _list(1), _list(2)])),
          ])));

  Widget _list(int kind) =>
      StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: kind == 0 ? _friends : kind == 1 ? _requests : _sent,
          builder: (context, snapshot) {
            if (!_social.isCurrentSession) {
              return Center(child: Text(context.tr('Сеанс завершён. Войдите снова')));
            }
            final rows = [...?snapshot.data?.docs];
            rows.sort((a, b) =>
                _displayName(a.data(), kind).toLowerCase()
                    .compareTo(_displayName(b.data(), kind).toLowerCase()));
            final visible = rows
                .where((d) =>
                    kind != 0 ||
                    _displayName(d.data(), kind).toLowerCase().contains(_query))
                .toList();
            return ListView(padding: const EdgeInsets.all(14), children: [
              if (kind == 0)
                Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: TextField(
                        controller: _search,
                        decoration: InputDecoration(
                            prefixIcon: const Icon(Icons.search),
                            hintText: context.tr('Поиск по никнейму')),
                        onChanged: (s) =>
                            setState(() => _query = s.trim().toLowerCase()))),
              if (snapshot.hasError)
                ClrsPanel(
                    child: Column(children: [
                  Text(context.tr('Не удалось загрузить список.')),
                  TextButton(
                      onPressed: () => setState(_subscribe),
                      child: Text(context.tr('Повторить')))
                ]))
              else if (!snapshot.hasData)
                const Center(child: CircularProgressIndicator())
              else if (visible.isEmpty)
                ClrsPanel(
                    child: Text(context.tr(kind == 0
                        ? 'Список друзей пока пуст'
                        : kind == 1
                            ? 'Новых заявок нет'
                            : 'Отправленных заявок нет')))
              else
                for (final doc in visible) _tile(doc, kind),
            ]);
          });

  Widget _tile(QueryDocumentSnapshot<Map<String, dynamic>> doc, int kind) {
    final d = doc.data();
    final uid = '${d[kind == 0 ? 'uid' : kind == 1 ? 'fromUid' : 'toUid'] ?? doc.id}';
    if (kind == 2 && _displayName(d, kind).isEmpty) {
      return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          future: _sentProfiles.putIfAbsent(uid, () => firebaseFirestore
              .collection('users').doc(uid).get()),
          builder: (context, profile) {
            final current = profile.data?.data();
            return _tileBody(uid, kind,
                name: _displayName(current ?? const <String, dynamic>{}, 0),
                photo: '${current?['profilePicThumb'] ?? current?['profilePic'] ?? ''}',
                group: '${current?['группа'] ?? ''}');
          });
    }
    return _tileBody(uid, kind,
        name: _displayName(d, kind),
        photo: '${d[kind == 0 ? 'profilePicThumb' : kind == 1 ? 'fromPhoto' : 'toPhoto'] ?? d['profilePic'] ?? ''}',
        group: '${d['группа'] ?? d['group'] ?? ''}');
  }

  Widget _tileBody(String uid, int kind,
      {required String name, required String photo, required String group}) {
    final disabled = _busy || _pending != null;
    return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: ClrsPanel(
            padding: const EdgeInsets.all(10),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  InkWell(
                      onTap: _opening ? null : () => _open(uid),
                      child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(children: [
                            GroupAvatar(url: photo, group: group),
                            const SizedBox(width: 10),
                            Expanded(
                                child: Text(name.isEmpty
                                    ? context.tr('Пользователь')
                                    : name)),
                            const Icon(Icons.chevron_right, size: 20)
                          ]))),
                  Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 6,
                      children: kind == 1
                          ? [
                              TextButton.icon(
                                  onPressed: disabled
                                      ? null
                                      : () => _act(() =>
                                          _social.declineFriendRequest(uid)),
                                  icon: const Icon(Icons.close, size: 18),
                                  label: Text(context.tr('Отклонить'))),
                              TextButton.icon(
                                  onPressed: disabled
                                      ? null
                                      : () => _act(() =>
                                          _social.acceptFriendRequest(uid)),
                                  icon: const Icon(Icons.check, size: 18),
                                  label: Text(context.tr('Принять'))),
                            ]
                          : kind == 2
                              ? [
                                  TextButton.icon(
                                      onPressed: disabled
                                          ? null
                                          : () => _act(() =>
                                              _social.cancelFriendRequest(uid)),
                                      icon: const Icon(Icons.close, size: 18),
                                      label: Text(context.tr('Отозвать заявку')))
                                ]
                          : [
                              TextButton.icon(
                                  onPressed: disabled
                                      ? null
                                      : () =>
                                          _act(() => _social.removeFriend(uid)),
                                  icon: const Icon(Icons.person_remove_outlined,
                                      size: 18),
                                  label: Text(context.tr('Удалить из друзей')))
                            ]),
                ])));
  }
}
