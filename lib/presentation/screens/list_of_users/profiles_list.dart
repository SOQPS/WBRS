import 'dart:async';
import 'package:wbrs/core/utils/compatibility.dart';
export 'package:wbrs/core/utils/compatibility.dart';
import 'package:wbrs/shared/group_avatar.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/app/pages/filter_pages/filter_page.dart';
import 'package:wbrs/app/widgets/bottom_nav_bar.dart';
import 'package:wbrs/app/widgets/drawer.dart';
import 'package:wbrs/app/widgets/widgets.dart';
import 'package:wbrs/presentation/screens/list_of_users/show/somebody_profile.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/shared/profile_composition.dart' show profileLocation;
import 'package:wbrs/service/invisibility_state.dart';

class ProfilesList extends StatefulWidget {
  final int startPosition;
  final String group;

  const ProfilesList({
    super.key,
    required this.group,
    required this.startPosition,
  });

  @override
  State<ProfilesList> createState() => _ProfilesListState();
}

class _ProfilesListState extends State<ProfilesList> {
  final List<_CachedPage> _pages = [];
  int _pageIndex = 0;
  bool _loading = true;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    group = widget.group;
    selectedIndex = 1;
    _loadFirstPage();
  }

  Query<Map<String, dynamic>> _baseQuery() {
    Query<Map<String, dynamic>> query = firebaseFirestore
        .collection('users')
        .where('status', isEqualTo: 'active');

    if (widget.group.isNotEmpty && filterByGroup) {
      final groups = getListOfGroup(widget.group).cast<String>();
      if (groups.isNotEmpty && groups.length <= 30) {
        query = query.where('группа', whereIn: groups);
      }
    }
    if (filterCountry.text.trim().isNotEmpty) {
      query = query.where('country', isEqualTo: filterCountry.text.trim());
    }
    if (filterRegion.text.trim().isNotEmpty) {
      query = query.where('region', isEqualTo: filterRegion.text.trim());
    }
    if (filtrPol.isNotEmpty) {
      query = query.where('pol', isEqualTo: filtrPol);
    }

    return query.orderBy('lastOnlineTS', descending: true);
  }

  Future<_CachedPage> _fetchPage(
      DocumentSnapshot<Map<String, dynamic>>? after) async {
    // Filter age locally so Firestore can retain activity-first ordering.
    final base = _baseQuery().limit(32);
    final currentUid = firebaseAuth.currentUser?.uid;
    final minAge = ageStart;
    final maxAge = ageEnd;
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    final visible = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    DocumentSnapshot<Map<String, dynamic>>? scanCursor = after;
    var exhausted = false;
    while (visible.length <= 30 && !exhausted) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        throw TimeoutException(
            'Загрузка заняла слишком много времени. Повторите попытку.');
      }
      final query =
          scanCursor == null ? base : base.startAfterDocument(scanCursor);
      final snapshot = await query.get().timeout(remaining);
      if (!mounted || firebaseAuth.currentUser?.uid != currentUid) {
        throw StateError('Загрузка отменена: сессия изменилась.');
      }
      for (final doc in snapshot.docs) {
        final data = doc.data();
        final rawAge = data['age'];
        final age = rawAge is num ? rawAge : num.tryParse('$rawAge');
        if (doc.id != currentUid &&
            data['uid'] != currentUid &&
            !isInvisibleActive(data) &&
            age != null &&
            age >= minAge &&
            age <= maxAge) {
          visible.add(doc);
          if (visible.length > 30) break;
        }
      }
      exhausted = snapshot.docs.length < 32;
      if (snapshot.docs.isNotEmpty) scanCursor = snapshot.docs.last;
    }
    final docs = visible.take(30).toList(growable: false);
    return _CachedPage(
      docs: docs,
      cursor: docs.isNotEmpty ? docs.last : scanCursor,
      hasMore: visible.length > 30,
    );
  }

  Future<void> _loadFirstPage() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      _pageIndex = 0;
      _pages.clear();
    });
    try {
      final page = await _fetchPage(null);
      if (!mounted || generation != _generation) return;
      setState(() {
        _pages.add(page);
        _loading = false;
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _nextPage() async {
    if (_loading || _pages.isEmpty || !_pages[_pageIndex].hasMore) return;
    if (_pageIndex + 1 < _pages.length) {
      setState(() => _pageIndex++);
      return;
    }
    setState(() => _loading = true);
    try {
      final page = await _fetchPage(_pages[_pageIndex].cursor);
      if (!mounted) return;
      setState(() {
        _pages.add(page);
        _pageIndex++;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final docs = _pages.isEmpty
        ? const <QueryDocumentSnapshot<Map<String, dynamic>>>[]
        : _pages[_pageIndex].docs;
    return ClrsScaffold(
        drawer: const MyDrawer(),
        bottomNavigationBar: const MyBottomNavigationBar(),
        appBar: AppBar(title: Text(context.tr('Люди')), actions: [
          IconButton(
              tooltip: context.tr('Обновить'),
              onPressed: _loading ? null : _loadFirstPage,
              icon: const Icon(Icons.refresh)),
        ]),
        body: LayoutBuilder(builder: (context, box) {
          final scale = MediaQuery.textScalerOf(context).scale(1);
          final columns = (box.maxWidth / (120 * scale)).floor().clamp(1, 4);
          return RefreshIndicator(
              onRefresh: _loadFirstPage,
              child: CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    SliverToBoxAdapter(
                        child: Padding(
                            padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                            child: Column(children: [
                              const ClrsBrandHeader(),
                              Text(
                                  context
                                      .tr('Хорошие люди находят друг друга ♡'),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                      color: LrsTheme.peachLight)),
                              const SizedBox(height: 10),
                              const ClrsPanel(
                                  padding: EdgeInsets.all(8),
                                  child: FilterPage2()),
                              if (_loading) const LinearProgressIndicator(),
                              if (_error != null)
                                Padding(
                                    padding: const EdgeInsets.only(top: 10),
                                    child: ClrsPanel(
                                        child: Column(children: [
                                      Text(context.tr(
                                          'Не удалось загрузить пользователей')),
                                      TextButton(
                                          onPressed:
                                              _loading ? null : _loadFirstPage,
                                          child: Text(context.tr('Повторить'))),
                                    ]))),
                            ]))),
                    if (!_loading && _error == null && docs.isEmpty)
                      SliverToBoxAdapter(
                          child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(
                                  context.tr(
                                      'По выбранным параметрам пока никого нет'),
                                  textAlign: TextAlign.center))),
                    SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        sliver: SliverGrid(
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: columns,
                                    crossAxisSpacing: 8,
                                    mainAxisSpacing: 8,
                                    mainAxisExtent: 106 + 100 * scale),
                            delegate: SliverChildBuilderDelegate(
                                (context, index) => _userCard({
                                      ...docs[index].data(),
                                      'uid': docs[index].data()['uid'] ??
                                          docs[index].id,
                                    }),
                                childCount: docs.length))),
                    if (docs.isNotEmpty)
                      SliverToBoxAdapter(child: _paginationBar()),
                    const SliverToBoxAdapter(child: SizedBox(height: 18)),
                  ]));
        }));
  }

  Widget _paginationBar() {
    final page = _pages[_pageIndex];
    return Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
        child: ClrsPanel(
            padding: const EdgeInsets.all(4),
            child: Row(children: [
              IconButton(
                  tooltip: context.tr('Предыдущая страница'),
                  onPressed: _pageIndex == 0 || _loading
                      ? null
                      : () => setState(() => _pageIndex--),
                  icon: const Icon(Icons.chevron_left)),
              Expanded(
                  child: Text(
                      context.tr('Страница {number} · до 30 профилей',
                          args: {'number': _pageIndex + 1}),
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 12))),
              IconButton(
                  tooltip: context.tr('Следующая страница'),
                  onPressed: !page.hasMore || _loading ? null : _nextPage,
                  icon: const Icon(Icons.chevron_right)),
            ])));
  }

  Widget _userCard(Map<String, dynamic> user) {
    final photo = '${user['profilePicThumb'] ?? user['profilePic'] ?? ''}';
    final userGroup = '${user['группа'] ?? ''}';
    final match = widget.group.isNotEmpty &&
        getListOfGroup(widget.group).contains(userGroup);
    final location = profileLocation(user, context: context);
    return ClrsPanel(
        padding: EdgeInsets.zero,
        child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => nextScreen(
                context,
                SomebodyProfile(
                    uid: '${user['uid'] ?? ''}',
                    name: '${user['fullName'] ?? ''}',
                    photoUrl: photo,
                    userInfo: user)),
            child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(children: [
                  Stack(children: [
                    GroupAvatar(url: photo, group: userGroup, size: 66),
                    if (user['online'] == true)
                      const Positioned(
                          right: 0,
                          top: 1,
                          child: Icon(Icons.circle,
                              size: 8, color: LrsTheme.success))
                  ]),
                  const SizedBox(height: 8),
                  Text(
                      [user['fullName'], user['age']]
                          .where((v) => v != null && '$v'.isNotEmpty)
                          .join(', '),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 13)),
                  const SizedBox(height: 4),
                  if (location.isNotEmpty)
                    Text(location,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 11, color: LrsTheme.peachLight)),
                  const Spacer(),
                  if (match)
                    Tooltip(
                        message: context.tr('Тип личности подходит вам'),
                        child: const Icon(Icons.favorite_outline,
                            size: 18, color: LrsTheme.peach)),
                ]))));
  }
}

class _CachedPage {
  const _CachedPage(
      {required this.docs, required this.cursor, required this.hasMore});

  final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs;
  final DocumentSnapshot<Map<String, dynamic>>? cursor;
  final bool hasMore;
}
