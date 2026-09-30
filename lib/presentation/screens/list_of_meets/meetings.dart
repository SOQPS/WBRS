import 'package:wbrs/shared/translatable_text.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/shared/meeting_form.dart' show parseMeetingDateTime;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/app/widgets/bottom_nav_bar.dart';
import 'package:wbrs/app/widgets/drawer.dart';
import 'package:wbrs/presentation/screens/create_meet/create_meet.dart';
import 'package:wbrs/shared/clrs_brand.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/geo_catalog.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'show/about_meet.dart';
import 'show/about_individual_meet.dart';

class MeetingPage extends StatefulWidget {
  const MeetingPage({super.key});
  @override
  State<MeetingPage> createState() => _MeetingPageState();
}

class _MeetingPageState extends State<MeetingPage> {
  static const _pageSize = 30;
  late Stream<QuerySnapshot<Map<String, dynamic>>> _meets;
  late final Query<Map<String, dynamic>> _meetQuery;
  late final String? _ownerUid;
  late final Future<List<GeoCountry>> _catalog;
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> _olderMeets = [];
  QueryDocumentSnapshot<Map<String, dynamic>>? _olderCursor;
  bool _olderLoaded = false, _hasMoreOlder = true, _loadingMore = false;
  bool _olderError = false;
  GeoCountry? _country;
  String? _region;
  bool _opening = false;
  @override
  void initState() {
    super.initState();
    selectedIndex = 3;
    _ownerUid = firebaseAuth.currentUser?.uid;
    _catalog = GeoCatalog.load();
    _meetQuery = firebaseFirestore
        .collection('meets')
        .orderBy('timeStamp', descending: true);
    _meets = _meetQuery.limit(_pageSize + 1).snapshots();
  }

  Future<void> _loadMore(
      QueryDocumentSnapshot<Map<String, dynamic>> cursor) async {
    if (_loadingMore || firebaseAuth.currentUser?.uid != _ownerUid) return;
    setState(() {
      _loadingMore = true;
      _olderError = false;
    });
    try {
      final page = await _meetQuery
          .startAfterDocument(_olderCursor ?? cursor)
          .limit(_pageSize + 1)
          .get()
          .timeout(const Duration(seconds: 20));
      if (!mounted || firebaseAuth.currentUser?.uid != _ownerUid) return;
      final next = page.docs.take(_pageSize).toList();
      setState(() {
        _olderMeets.addAll(next);
        if (next.isNotEmpty) _olderCursor = next.last;
        _olderLoaded = true;
        _hasMoreOlder = page.docs.length > _pageSize;
      });
    } catch (_) {
      if (mounted && firebaseAuth.currentUser?.uid == _ownerUid) {
        setState(() => _olderError = true);
      }
    } finally {
      if (mounted && firebaseAuth.currentUser?.uid == _ownerUid) {
        setState(() => _loadingMore = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => ClrsScaffold(
      drawer: MyDrawer(),
      bottomNavigationBar: MyBottomNavigationBar(),
      appBar: AppBar(
          automaticallyImplyLeading: false,
          title: const ClrsLogo(size: 32)),
      body: CustomScrollView(slivers: [
        SliverToBoxAdapter(
            child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Column(children: [
                  const Align(
                      alignment: Alignment.centerRight,
                      child: ClrsMotto(size: 18)),
                  Row(children: [
                    Builder(
                        builder: (menuContext) => IconButton(
                            tooltip: MaterialLocalizations.of(menuContext)
                                .openAppDrawerTooltip,
                            icon: const Icon(Icons.menu),
                            onPressed: () =>
                                Scaffold.of(menuContext).openDrawer())),
                    Expanded(
                        child: Text(context.tr('Встречи'),
                            style: Theme.of(context).textTheme.headlineSmall)),
                    SizedBox(
                        width: 138,
                        child: OutlinedButton.icon(
                            key: const ValueKey('meeting-create-action'),
                            style: OutlinedButton.styleFrom(
                                foregroundColor: LrsTheme.text,
                                backgroundColor: const Color(0x4031241D),
                                side: const BorderSide(
                                    color: LrsTheme.actionBorder),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12)),
                            icon: const Icon(Icons.add),
                            label: Text(context.tr('Создать встречу'),
                                maxLines: 2, overflow: TextOverflow.ellipsis),
                            onPressed: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                    builder: (_) => CreateMeetPage())))),
                  ]),
                  Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                          icon: Icon(Icons.help_outline),
                          label: Text(context.tr('Как создать встречу')),
                          onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => MeetingGuidePage())))),
                  FutureBuilder<List<GeoCountry>>(
                      future: _catalog,
                      builder: (context, snapshot) {
                        if (!snapshot.hasData) return SizedBox.shrink();
                        return ClrsPanel(
                            padding: EdgeInsets.all(10),
                            child: Row(children: [
                              Expanded(child: DropdownButtonFormField<String>(
                                  value: _country?.code,
                                  isExpanded: true,
                                  itemHeight: null,
                                  decoration: InputDecoration(
                                      labelText: context.tr('Страна'),
                                      isDense: true),
                                  items: [
                                    DropdownMenuItem<String>(
                                        value: '',
                                        child: Text(context.tr('Все страны'))),
                                    ...snapshot.data!.map((c) =>
                                        DropdownMenuItem(
                                            value: c.code,
                                            child: Text(context.tr(c.name),
                                                maxLines: 2,
                                                overflow:
                                                    TextOverflow.ellipsis)))
                                  ],
                                  onChanged: (value) => setState(() {
                                        _country = GeoCatalog.byCode(
                                            snapshot.data!, value);
                                        _region = null;
                                      }))),
                              const SizedBox(width: 8),
                              Expanded(child: DropdownButtonFormField<String>(
                                  key: ValueKey(_country?.code),
                                  value: _region,
                                  isExpanded: true,
                                  itemHeight: null,
                                  decoration: InputDecoration(
                                      labelText: context.tr(
                                          _country?.regionLabel ?? 'Регион'),
                                      isDense: true),
                                  items: [
                                    DropdownMenuItem<String>(
                                        value: '',
                                        child: Text(context.tr('Все регионы'))),
                                    ...(_country?.regions ?? <String>[]).map(
                                        (r) => DropdownMenuItem(
                                            value: r,
                                            child: Text(r,
                                                overflow:
                                                    TextOverflow.ellipsis)))
                                  ],
                                  onChanged: _country == null
                                      ? null
                                      : (value) =>
                                          setState(() => _region = value))),
                            ]));
                      }),
                ]))),
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _meets,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                        child: ClrsPanel(
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                          Text(context.tr(
                              'Не удалось загрузить встречи. Проверьте подключение.')),
                          TextButton(
                              onPressed: () => setState(() => _meets =
                                  _meetQuery.limit(_pageSize + 1).snapshots()),
                              child: Text(context.tr('Повторить'))),
                        ]))));
              }
              if (!snapshot.hasData) {
                return SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(child: CircularProgressIndicator()));
              }
              if (firebaseAuth.currentUser?.uid != _ownerUid) {
                return const SliverToBoxAdapter(child: SizedBox.shrink());
              }
              final firstPage = snapshot.data!.docs.take(_pageSize).toList();
              final byId =
                  <String, QueryDocumentSnapshot<Map<String, dynamic>>>{
                for (final doc in firstPage) doc.id: doc,
                for (final doc in _olderMeets) doc.id: doc,
              };
              final docs = byId.values.toList();
              final hasMore = _olderLoaded
                  ? _hasMoreOlder
                  : snapshot.data!.docs.length > _pageSize;
              final cursor = firstPage.isEmpty ? null : firstPage.last;
              final indices = <int>[];
              for (var i = 0; i < docs.length; i++) {
                final d = docs[i].data();
                final uid = firebaseAuth.currentUser?.uid;
                final invitee = '${d['invitedUid'] ?? ''}';
                if (invitee.isNotEmpty && d['admin'] != uid && invitee != uid) {
                  continue;
                }
                if (_country != null &&
                    d['countryCode'] != _country!.code &&
                    d['country'] != _country!.name) {
                  continue;
                }
                if ((_region ?? '').isNotEmpty && d['region'] != _region) {
                  continue;
                }
                indices.add(i);
              }
              if (indices.isEmpty && !hasMore) {
                return SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                        child: ClrsPanel(
                            child: Text(context
                                .tr('В этом регионе пока нет встреч.')))));
              }
              if (indices.isEmpty) {
                return SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(child: _moreButton(cursor)));
              }
              return SliverPadding(
                  padding: EdgeInsets.all(16),
                  sliver: SliverList(
                      delegate:
                          SliverChildBuilderDelegate((context, itemIndex) {
                    if (hasMore && itemIndex == indices.length * 2 - 1) {
                      return _moreButton(cursor);
                    }
                    if (itemIndex.isOdd) return SizedBox(height: 12);
                    final position = itemIndex ~/ 2;
                    final index = indices[position];
                    final d = docs[index].data();
                    final imageUrl = _meetingImageUrl(d);
                    final fallbackAsset = _meetingThumbnailAsset(
                        '${d['name'] ?? ''}', '${d['description'] ?? ''}');
                    final users = d['users'] is List ? d['users'] as List : [];
                    final location = [
                      if (d['country'] != null) context.tr('${d['country']}'),
                      d['region']
                    ].where((x) => x != null && '$x'.isNotEmpty).join(' · ');
                    return ClrsPanel(
                        padding: EdgeInsets.zero,
                        child: InkWell(
                            borderRadius: BorderRadius.circular(20),
                            onTap: _opening ? null : () => _open(docs[index]),
                            child: Padding(
                                padding: EdgeInsets.all(16),
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            ClipRRect(
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                                child: SizedBox(
                                                    width: 96,
                                                    height: 112,
                                                    child: imageUrl == null
                                                        ? Image.asset(
                                                            fallbackAsset,
                                                            fit: BoxFit.cover)
                                                        : CachedNetworkImage(
                                                            imageUrl: imageUrl,
                                                            fit: BoxFit.cover,
                                                            memCacheWidth: 320,
                                                            maxWidthDiskCache:
                                                                640,
                                                            placeholder:
                                                                (_, __) =>
                                                                    Image.asset(
                                                                      fallbackAsset,
                                                                      fit: BoxFit
                                                                          .cover,
                                                                    ),
                                                            errorWidget:
                                                                (_, __, ___) =>
                                                                    Image.asset(
                                                                      fallbackAsset,
                                                                      fit: BoxFit
                                                                          .cover,
                                                                    )))),
                                            const SizedBox(width: 12),
                                            Expanded(
                                                child: Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                  Row(children: [
                                                    Expanded(
                                                        child: TranslatableText(
                                                            '${d['name'] ?? context.tr('Встреча')}',
                                                            showAction: false,
                                                            style: const TextStyle(
                                                                fontSize: 17,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w700))),
                                                    const Icon(
                                                        Icons.chevron_right)
                                                  ]),
                                                  const SizedBox(height: 8),
                                                  Text(
                                                      parseMeetingDateTime(
                                                                  '${d['datetime'] ?? ''}') ==
                                                              null
                                                          ? '${d['datetime'] ?? ''}'
                                                          : context.l10n.dateTime(
                                                              parseMeetingDateTime(
                                                                  '${d['datetime']}')!),
                                                      style: const TextStyle(
                                                          color: LrsTheme
                                                              .peachLight)),
                                                  const SizedBox(height: 6),
                                                  Text(location.isEmpty
                                                      ? context.tr(
                                                          'Регион не указан')
                                                      : location),
                                                ])),
                                          ]),
                                      const SizedBox(height: 10),
                                      SizedBox(
                                          width: double.infinity,
                                          child: TranslatableText(
                                              '${d['description'] ?? ''}',
                                              showAction: false)),
                                      SizedBox(height: 10),
                                      Wrap(
                                          spacing: 16,
                                          runSpacing: 6,
                                          children: [
                                            Text(context.tr(
                                                'Участников: {count}',
                                                args: {
                                                  'count': context.l10n
                                                      .number(users.length)
                                                },
                                                count: users.length)),
                                            if (d['admin'] ==
                                                firebaseAuth.currentUser?.uid)
                                              Text(context.tr('Вы организатор'))
                                            else if (users.contains(
                                                firebaseAuth.currentUser?.uid))
                                              Text(context.tr('Вы участник')),
                                          ]),
                                    ]))));
                  }, childCount: indices.length * 2 - 1 + (hasMore ? 1 : 0))));
            }),
      ]));

  Widget _moreButton(
          QueryDocumentSnapshot<Map<String, dynamic>>? cursor) =>
      Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Center(
              child: _loadingMore
                  ? const CircularProgressIndicator()
                  : OutlinedButton(
                      onPressed:
                          cursor == null ? null : () => _loadMore(cursor),
                      child: Text(context
                          .tr(_olderError ? 'Повторить' : 'Загрузить ещё')))));

  String? _meetingImageUrl(Map<String, dynamic> data) {
    for (final key in const ['imageUrl', 'meetingImageUrl']) {
      final value = data[key];
      if (value is! String) continue;
      final url = value.trim();
      final uri = Uri.tryParse(url);
      if (uri != null &&
          (uri.scheme == 'https' || uri.scheme == 'http') &&
          uri.host.isNotEmpty) {
        return url;
      }
    }
    return null;
  }

  String _meetingThumbnailAsset(String title, String description) {
    String? themedAsset(String text) {
      final normalized = text.toLowerCase();
      // Prefer the activity to a location: a picnic in a park is a picnic.
      if (RegExp(r'пикник|picnic|пікнік|шашлык|барбекю|barbecue|grill')
          .hasMatch(normalized)) {
        return 'assets/final_design/meeting_picnic.jpg';
      }
      if (RegExp(r'бар|паб|пив|pub|beer|крылышк|chicken wings')
          .hasMatch(normalized)) {
        return 'assets/final_design/meeting_bar.jpg';
      }
      if (RegExp(r'кофе|coffee|café|cafe|кафе|чаепит|завтрак')
          .hasMatch(normalized)) {
        return 'assets/final_design/meeting_coffee.jpg';
      }
      if (RegExp(r'парк|park|прогул|walk|поход|hiking|набережн')
          .hasMatch(normalized)) {
        return 'assets/final_design/meeting_park.jpg';
      }
      return null;
    }

    final themed = themedAsset(title) ?? themedAsset(description);
    if (themed != null) return themed;
    return 'assets/final_design/house.png';
  }

  Future<void> _open(QueryDocumentSnapshot<Map<String, dynamic>> doc) async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      final d = doc.data();
      final users = d['users'] is List ? d['users'] as List : [];
      if (d['type'] == 'групповая') {
        await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => AboutMeet(
                id: doc.id,
                users: users,
                name: '${d['name'] ?? ''}',
                is_user_join: users.contains(firebaseAuth.currentUser?.uid))));
      } else {
        final admin = await firebaseFirestore
            .collection('users')
            .doc('${d['admin']}')
            .get()
            .timeout(Duration(seconds: 15));
        if (!mounted) return;
        await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => AboutIndividualMeet(meetingDoc: doc, doc: admin)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(context
                .tr('Не удалось открыть встречу. Попробуйте ещё раз.'))));
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }
}

class MeetingGuidePage extends StatelessWidget {
  const MeetingGuidePage({super.key});
  static const _steps = [
    'Вы один(одна) и хотите пригласить кого-то. Создавайте индивидуальную встречу, укажите в описании куда идёте, что будете делать.',
    'Вас, например, двое. Один создаёт коллективную встречу и пишет: ждём двух девушек, и что вы предлагаете. (К примеру, пьём кофе на набережной и т.п.)',
    'Вы — компания и хотите устроить что-то масштабное. Один пусть создаёт коллективную встречу, опишите кратко предложение.',
    'Когда кто-нибудь вступит, придёт уведомление как создателю.',
  ];
  @override
  Widget build(BuildContext context) => ClrsScaffold(
        appBar: AppBar(title: Text(context.tr('Аннотация на встречу:'))),
        body: SafeArea(
            top: false,
            child: ListView(
                key: const ValueKey('meeting-guide-scroll'),
                padding: const EdgeInsets.all(16),
                children: [
                  const ClrsBrandHeader(),
                  Text(context.tr('Как создать встречу'),
                      style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 12),
                  for (int i = 0; i < _steps.length; i++)
                    Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: ClrsPanel(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  CircleAvatar(
                                      radius: 15,
                                      backgroundColor: const Color(0xBBA76843),
                                      child: Text(context.l10n.number(i + 1),
                                          style: const TextStyle(
                                              color: LrsTheme.text))),
                                  const SizedBox(width: 10),
                                  Expanded(
                                      child: Text(context.tr(_steps[i]),
                                          style: const TextStyle(
                                              fontSize: 16, height: 1.3))),
                                ]))),
                  const ClrsValuesFooter(),
                  ElevatedButton(
                      style: ElevatedButton.styleFrom(
                          backgroundColor: LrsTheme.peach,
                          foregroundColor: LrsTheme.background,
                          minimumSize: const Size.fromHeight(48)),
                      onPressed: () => Navigator.pop(context),
                      child: Text(context.tr('Понятно'))),
                ])),
      );
}
