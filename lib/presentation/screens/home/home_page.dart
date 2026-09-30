import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/app/widgets/bottom_nav_bar.dart';
import 'package:wbrs/app/widgets/chat_room_list.dart';
import 'package:wbrs/app/widgets/drawer.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/service/app_backend.dart';
import 'package:wbrs/shared/clrs_brand.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/lrs_theme.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final String? _uid;
  Stream<QuerySnapshot<Map<String, dynamic>>>? _chats;
  String? _notice;
  String _filter = 'Все';
  String _search = '';
  bool _searchOpen = false;
  Set<String> _favorites = {};
  Set<String> _archived = {};
  final Map<String, String> _peerSearchNames = {};
  final Set<String> _loadingPeerSearchNames = {};
  int _peerSearchGeneration = 0;
  bool get _current =>
      mounted && _uid != null && firebaseAuth.currentUser?.uid == _uid;
  @override
  void initState() {
    super.initState();
    _uid = firebaseAuth.currentUser?.uid;
    _setStream();
    if (_uid != null) {
      _loadChatPreferences();
      firebaseFirestore.collection('users').doc(_uid).update({
        'online': true,
        'lastOnlineTS': FieldValue.serverTimestamp(),
      }).catchError((_) {});
      if (!AppBackend.useEmulators) _initializePush();
    }
  }

  Future<void> _loadChatPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    if (!_current) return;
    setState(() {
      _favorites = (prefs.getStringList('chat_favorites_$_uid') ?? []).toSet();
      _archived = (prefs.getStringList('chat_archived_$_uid') ?? []).toSet();
    });
  }

  Future<void> _toggleChatPreference(
    String chatId, {
    required bool archive,
  }) async {
    final uid = _uid;
    if (!_current || uid == null) return;
    final target = archive ? _archived : _favorites;
    final updated = {...target};
    if (!updated.add(chatId)) updated.remove(chatId);
    setState(() {
      if (archive) {
        _archived = updated;
      } else {
        _favorites = updated;
      }
    });
    final prefs = await SharedPreferences.getInstance();
    if (firebaseAuth.currentUser?.uid != uid) return;
    await prefs.setStringList(
      '${archive ? 'chat_archived' : 'chat_favorites'}_$uid',
      updated.toList(),
    );
  }

  void _setStream() {
    if (_uid == null) return;
    _peerSearchGeneration++;
    _peerSearchNames.clear();
    _loadingPeerSearchNames.clear();
    _chats = firebaseFirestore
        .collection('chats')
        .where(Filter.or(
            Filter('user1', isEqualTo: _uid), Filter('user2', isEqualTo: _uid)))
        .snapshots();
  }

  String? _otherUid(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    if (data['user1'] != _uid && data['user2'] != _uid) return null;
    final value = data['user1'] == _uid ? data['user2'] : data['user1'];
    return value is String && value.isNotEmpty && !value.contains('/')
        ? value
        : null;
  }

  void _loadPeerSearchName(String peerUid, String fallback) {
    if (!_current || _peerSearchNames.containsKey(peerUid) ||
        !_loadingPeerSearchNames.add(peerUid)) {
      return;
    }
    final generation = _peerSearchGeneration;
    final ownerUid = _uid;
    firebaseFirestore.collection('users').doc(peerUid).get().then((doc) {
      if (generation != _peerSearchGeneration) {
        return;
      }
      if (!_current || _uid != ownerUid) {
        _loadingPeerSearchNames.remove(peerUid);
        return;
      }
      final profile = doc.data();
      final available = doc.exists && profile != null &&
          profile['deleted'] != true && profile['status'] != 'deleted' &&
          profile['registrationStatus'] != 'deleted';
      setState(() {
        _loadingPeerSearchNames.remove(peerUid);
        _peerSearchNames[peerUid] = available
            ? '${profile['fullName'] ?? ''}'
            : context.tr('Удаленный пользователь');
      });
    }).catchError((_) {
      if (generation != _peerSearchGeneration) {
        return;
      }
      if (!_current || _uid != ownerUid) {
        _loadingPeerSearchNames.remove(peerUid);
        return;
      }
      setState(() {
        _loadingPeerSearchNames.remove(peerUid);
        _peerSearchNames[peerUid] = fallback;
      });
    });
  }

  Future<void> _initializePush() async {
    if (AppBackend.useEmulators || !_current) return;
    try {
      await firebaseMessaging.requestPermission(
          alert: true, badge: true, sound: true);
      if (!_current) return;
      final token = await firebaseMessaging.getToken();
      if (!_current || token == null) return;
      await firebaseFirestore
          .collection('TOKENS')
          .doc(_uid)
          .set({'token': token});
    } catch (_) {
      if (_current) {
        setState(() => _notice = 'Не удалось включить уведомления.');
      }
    }
  }

  Widget _empty(String title, {String? body, bool retry = false}) => Center(
      child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ClrsPanel(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.forum_outlined, color: LrsTheme.peach, size: 42),
            const SizedBox(height: 12),
            Text(context.tr(title),
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            if (body != null) ...[
              const SizedBox(height: 8),
              Text(context.tr(body), textAlign: TextAlign.center)
            ],
            if (retry)
              TextButton(
                  onPressed: () => setState(_setStream),
                  child: Text(context.tr('Повторить'))),
          ]))));
  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.textScalerOf(context).scale(1) > 1.5 ||
        MediaQuery.sizeOf(context).height < 520;
    return ClrsScaffold(
    bottomNavigationBar: const MyBottomNavigationBar(),
    drawer: const MyDrawer(),
    appBar: AppBar(
      title: const ClrsLogo(size: 33),
      actions: [
        IconButton(
          tooltip: context.tr('Поиск'),
          onPressed: () => setState(() {
            _searchOpen = !_searchOpen;
            if (!_searchOpen) _search = '';
          }),
          icon: Icon(_searchOpen ? Icons.close : Icons.search),
        ),
      ],
    ),
    body: !_current
        ? _empty('Сеанс завершён. Войдите снова.')
        : Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            context.tr('Чаты'),
                            style: const TextStyle(
                              color: LrsTheme.text,
                              fontSize: 28,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      if (!compact)
                        const SizedBox(
                          width: 130,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: ClrsMotto(size: 16),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    if (!compact)
                      Text(
                        context.tr('Значимые разговоры с настоящими людьми'),
                        style: const TextStyle(
                          color: LrsTheme.text,
                          fontSize: 14,
                        ),
                      ),
                    if (_searchOpen) ...[
                      const SizedBox(height: 8),
                      TextField(
                        autofocus: true,
                        onChanged: (value) => setState(() => _search = value),
                        decoration: InputDecoration(
                          hintText: context.tr('Поиск по имени'),
                          prefixIcon: const Icon(Icons.search),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              SizedBox(
                height: 52,
                child: ListView(
                  key: const ValueKey('chat-filters'),
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 4,
                  ),
                  children: [
                    _filterButton('Все', Icons.chat_bubble_outline),
                    _filterButton('Новые', Icons.people_outline),
                    _filterButton('Избранные', Icons.favorite_border),
                    _filterButton('Архив', Icons.archive_outlined),
                  ],
                ),
              ),
              if (_notice != null)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(context.tr(_notice!)),
                ),
              Expanded(
                child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: _chats,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return _empty(
                        'Не удалось загрузить чаты. Проверьте подключение.',
                        retry: true,
                      );
                    }
                    if (!snapshot.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.data!.docs.isEmpty) {
                      return _empty(
                        'Здесь появятся ваши диалоги',
                        body:
                            'Начните общение с человеком, который вам подходит.',
                      );
                    }
                    final documents =
                        snapshot.data!.docs.where((doc) {
                          final archived = _archived.contains(doc.id);
                          if (_filter == 'Архив') return archived;
                          if (archived) return false;
                          if (_filter == 'Избранные' &&
                              !_favorites.contains(doc.id)) {
                            return false;
                          }
                          if (_filter == 'Новые' &&
                              (doc.data()['lastMessageSendByID'] == _uid ||
                                  ((doc.data()['unreadMessage'] as num?) ?? 0) <=
                                      0)) {
                            return false;
                          }
                          return true;
                        }).toList()..sort((a, b) {
                          final aStamp = a.data()['lastMessageSendTs'];
                          final bStamp = b.data()['lastMessageSendTs'];
                          return (bStamp is Timestamp
                                  ? bStamp.millisecondsSinceEpoch
                                  : 0)
                              .compareTo(
                                aStamp is Timestamp
                                    ? aStamp.millisecondsSinceEpoch
                                    : 0,
                              );
                        });
                    final search = _search.trim().toLowerCase();
                    if (search.isNotEmpty) {
                      final loading = <String>{};
                      documents.removeWhere((doc) {
                        final data = doc.data();
                        final fallback = data['user1'] == _uid
                            ? data['user2Nickname']
                            : data['user1Nickname'];
                        final peerUid = _otherUid(doc);
                        if (peerUid != null) {
                          _loadPeerSearchName(peerUid, '${fallback ?? ''}');
                          if (_loadingPeerSearchNames.contains(peerUid)) {
                            loading.add(peerUid);
                          }
                        }
                        final otherName = peerUid == null
                            ? '${fallback ?? ''}'
                            : _peerSearchNames[peerUid] ?? '${fallback ?? ''}';
                        return !otherName.toLowerCase().contains(
                          search,
                        );
                      });
                      if (documents.isEmpty && loading.isNotEmpty) {
                        return const Center(child: CircularProgressIndicator());
                      }
                    }
                    if (documents.isEmpty) {
                      return _empty('Здесь нет подходящих чатов');
                    }
                    return ListView.separated(
                      padding: const EdgeInsets.fromLTRB(14, 10, 14, 24),
                      itemCount: documents.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, index) => ClrsPanel(
                        padding: EdgeInsets.zero,
                        child: Row(
                          children: [
                            Expanded(
                              child: ChatRoomList(
                                key: ValueKey(documents[index].id),
                                snapshot: documents[index],
                              ),
                            ),
                            PopupMenuButton<String>(
                              tooltip: context.tr('Действия с чатом'),
                              icon: const Icon(Icons.more_vert, size: 20),
                              onSelected: (choice) => _toggleChatPreference(
                                documents[index].id,
                                archive: choice == 'archive',
                              ),
                              itemBuilder: (_) => [
                                PopupMenuItem(
                                  value: 'favorite',
                                  child: Text(
                                    context.tr(
                                      _favorites.contains(documents[index].id)
                                          ? 'Убрать из избранного'
                                          : 'В избранное',
                                    ),
                                  ),
                                ),
                                PopupMenuItem(
                                  value: 'archive',
                                  child: Text(
                                    context.tr(
                                      _archived.contains(documents[index].id)
                                          ? 'Вернуть из архива'
                                          : 'В архив',
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
    );
  }

  Widget _filterButton(String label, IconData icon) {
    final active = _filter == label;
    return Padding(
      padding: const EdgeInsets.only(right: 7),
      child: OutlinedButton.icon(
        onPressed: () => setState(() => _filter = label),
        icon: Icon(icon, size: 18),
        label: Text(context.tr(label)),
        style: OutlinedButton.styleFrom(
          foregroundColor: LrsTheme.text,
          backgroundColor: active
              ? const Color(0x995D3828)
              : LrsTheme.actionGlass,
          side: BorderSide(
            color: active ? LrsTheme.peach : LrsTheme.actionBorder,
            width: active ? 1.3 : 1,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          shape: const StadiumBorder(),
        ),
      ),
    );
  }
}
