import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/app/widgets/bottom_nav_bar.dart';
import 'package:wbrs/app/widgets/chat_room_list.dart';
import 'package:wbrs/app/widgets/drawer.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/service/app_backend.dart';
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
  bool get _current =>
      mounted && _uid != null && firebaseAuth.currentUser?.uid == _uid;
  @override
  void initState() {
    super.initState();
    _uid = firebaseAuth.currentUser?.uid;
    _setStream();
    if (_uid != null) {
      firebaseFirestore.collection('users').doc(_uid).update({
        'online': true,
        'lastOnlineTS': FieldValue.serverTimestamp(),
      }).catchError((_) {});
      if (!AppBackend.useEmulators) _initializePush();
    }
  }

  void _setStream() {
    if (_uid == null) return;
    _chats = firebaseFirestore
        .collection('chats')
        .where(Filter.or(
            Filter('user1', isEqualTo: _uid), Filter('user2', isEqualTo: _uid)))
        .snapshots();
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
      if (_current)
        setState(() => _notice = 'Не удалось включить уведомления.');
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
  Widget build(BuildContext context) => ClrsScaffold(
      bottomNavigationBar: const MyBottomNavigationBar(),
      drawer: const MyDrawer(),
      appBar: AppBar(title: Text(context.tr('Чаты')), actions: [
        Padding(
            padding: const EdgeInsets.only(right: 14),
            child: Center(
                child: Text('${context.l10n.number(globalBalance)} Ag',
                    style: const TextStyle(
                        color: LrsTheme.peachLight,
                        fontWeight: FontWeight.w700))))
      ]),
      body: !_current
          ? _empty('Сеанс завершён. Войдите снова.')
          : Column(children: [
              if (_notice != null)
                Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(context.tr(_notice!))),
              Expanded(
                  child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      stream: _chats,
                      builder: (context, snapshot) {
                        if (snapshot.hasError)
                          return _empty(
                              'Не удалось загрузить чаты. Проверьте подключение.',
                              retry: true);
                        if (!snapshot.hasData)
                          return const Center(
                              child: CircularProgressIndicator());
                        if (snapshot.data!.docs.isEmpty)
                          return _empty('Здесь появятся ваши диалоги',
                              body:
                                  'Начните общение с человеком, который вам подходит.');
                        final documents = [...snapshot.data!.docs]
                          ..sort((a, b) {
                            final aStamp = a.data()['lastMessageSendTs'];
                            final bStamp = b.data()['lastMessageSendTs'];
                            return (bStamp is Timestamp
                                    ? bStamp.millisecondsSinceEpoch
                                    : 0)
                                .compareTo(aStamp is Timestamp
                                    ? aStamp.millisecondsSinceEpoch
                                    : 0);
                          });
                        return ListView.separated(
                            padding: const EdgeInsets.fromLTRB(14, 10, 14, 24),
                            itemCount: documents.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 10),
                            itemBuilder: (context, index) => ClrsPanel(
                                padding: EdgeInsets.zero,
                                child: ChatRoomList(
                                    key: ValueKey(documents[index].id),
                                    snapshot: documents[index])));
                      })),
            ]));
}
