// ignore_for_file: use_build_context_synchronously

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/presentation/screens/chat_screen/chatscreen.dart';
import 'package:wbrs/app/widgets/robokassa_webview.dart';
import 'package:wbrs/service/database_service.dart';
import 'package:wbrs/app/widgets/bottom_nav_bar.dart';
import 'package:wbrs/app/widgets/drawer.dart';
import 'package:wbrs/app/widgets/widgets.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/shared/clrs_brand.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:random_string/random_string.dart';

import '../../../service/notifications.dart';

class Podarok {
  String img;
  String name;
  int price;
  final String? description;
  final bool descriptionOnly;

  Podarok({
    required this.name,
    required this.price,
    required this.img,
    this.description,
    this.descriptionOnly = false,
  });
}

class ShopPage extends StatefulWidget {
  final int? tabIndex;
  const ShopPage({super.key, this.tabIndex});

  @override
  State<ShopPage> createState() => _ShopPageState();
}

class _ShopPageState extends State<ShopPage> with TickerProviderStateMixin {
  TabController? _controller;

  ValueNotifier<bool> threeDs = ValueNotifier<bool>(false);
  ValueNotifier<bool> threeDsV2 = ValueNotifier<bool>(false);
  ValueNotifier<String?> status = ValueNotifier<String?>('');
  ValueNotifier<String?> cardType = ValueNotifier<String?>('');

  FirebaseFirestore db = firebaseFirestore;
  FirebaseAuth auth = firebaseAuth;

  bool isUnvisible = false;
  bool _openingGiftRecipient = false;

  checkUnVisible() async {
    db.collection('users').doc(auth.currentUser!.uid).get().then((value) {
      isUnvisible = value.data()!['isUnVisible'];
    });
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    checkUnVisible();
    _controller = TabController(
      vsync: this,
      length: 2,
      initialIndex: widget.tabIndex ?? 0,
    );
  }

  @override
  void dispose() {
    _controller!.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClrsScaffold(
        drawer: const MyDrawer(),
        bottomNavigationBar: const MyBottomNavigationBar(),
        body: NestedScrollView(
          headerSliverBuilder: (context, innerBoxIsScrolled) => [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: ClrsBrandHeader()),
                        Padding(
                          padding: EdgeInsets.only(top: 15),
                          child: ClrsMotto(size: 16),
                        ),
                      ],
                    ),
                    Text(
                      context.tr('Магазин подарков'),
                      style: const TextStyle(
                        color: LrsTheme.text,
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      context
                          .tr('Дарить внимание. Создавать особенные моменты.'),
                      style: const TextStyle(
                        color: LrsTheme.text,
                        fontSize: 15,
                        height: 1.25,
                      ),
                    ),
                    const SizedBox(height: 12),
                    StreamBuilder(
                      stream: db
                          .collection('users')
                          .doc(auth.currentUser!.uid)
                          .snapshots(),
                      builder: (context, snapshot) {
                        if (snapshot.hasData) {
                          globalBalance = snapshot.data!['balance'];
                        }
                        final shownBalance =
                            snapshot.hasData ? globalBalance : 0;
                        return ClrsPanel(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 11,
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.monetization_on_outlined,
                                color: LrsTheme.peach,
                                size: 25,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text.rich(
                                  TextSpan(
                                    children: [
                                      TextSpan(
                                          text: context.tr('Ваш баланс: ')),
                                      TextSpan(
                                        text: '$shownBalance Ag',
                                        style: const TextStyle(
                                          color: LrsTheme.peach,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                  ),
                                  style: const TextStyle(
                                    color: LrsTheme.text,
                                    fontSize: 16,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 8),
                    _shopActions(context),
                    const SizedBox(height: 10),
                  ],
                ),
              ),
            ),
            SliverAppBar(
              forceElevated: innerBoxIsScrolled,
              backgroundColor: const Color(0xB3211813),
              pinned: true,
              foregroundColor: LrsTheme.text,
              toolbarHeight: 0,
              bottom: TabBar(
                unselectedLabelColor: LrsTheme.muted,
                indicatorColor: LrsTheme.peach,
                indicatorSize: TabBarIndicatorSize.label,
                labelColor: LrsTheme.text,
                controller: _controller,
                tabs: [
                  Tab(text: context.tr('Выбрать подарки')),
                  Tab(text: context.tr('Выбранные подарки')),
                ],
                isScrollable: true,
              ),
            ),
          ],
          body: StreamBuilder(
            stream:
                db.collection('users').doc(auth.currentUser!.uid).snapshots(),
            builder: (context, snapshot) => TabBarView(
              controller: _controller,
              children: [first(context), second(snapshot.data, context)],
            ),
          ),
        ),
      );

  Future<void> _showGiftRecipientSheet(
    BuildContext context,
    String name,
    String imagePath,
  ) async {
    final ownerUid = auth.currentUser?.uid;
    if (_openingGiftRecipient || ownerUid == null) return;
    _openingGiftRecipient = true;
    try {
      final recipient = await showModalBottomSheet<_GiftRecipient>(
        context: context,
        isScrollControlled: true,
        backgroundColor: LrsTheme.surface,
        builder: (_) => SizedBox(
          height: MediaQuery.sizeOf(context).height * .7,
          child: _GiftRecipientSheet(
            db: db,
            auth: auth,
            ownerUid: ownerUid,
            onSend: (recipient) =>
                _sendGift(ownerUid, name, imagePath, recipient),
          ),
        ),
      );
      if (!mounted || auth.currentUser?.uid != ownerUid || recipient == null) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xA3124725),
          content: Text(
            context.tr(
              'Подарок {name} подарен!',
              args: {'name': context.tr(name)},
            ),
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      );
      nextScreenReplace(
        context,
        ChatScreen(
          chatWithUsername: recipient.name,
          photoUrl: recipient.imageUrl,
          id: ownerUid,
          chatId: recipient.chatId,
        ),
      );
    } finally {
      _openingGiftRecipient = false;
    }
  }

  Future<void> _sendGift(
    String ownerUid,
    String name,
    String imagePath,
    _GiftRecipient recipient,
  ) async {
    if (!mounted || auth.currentUser?.uid != ownerUid) {
      throw StateError('Gift session changed');
    }
    final coll = db.collection('users').doc(ownerUid);
    final ownerDoc = await coll.get();
    final userInfo = ownerDoc.data() as Map;
    final Map<String, dynamic> initGifts =
        userInfo.containsKey('gifts') ? userInfo['gifts'] : {};
    final recipientSnapshot =
        await db.collection('users').doc(recipient.uid).get();
    if (!mounted || auth.currentUser?.uid != ownerUid) {
      throw StateError('Gift session changed');
    }
    if (!recipientSnapshot.exists) {
      throw StateError('Gift recipient unavailable');
    }
    final chatWith = recipientSnapshot.data()?['chatWithId'];
    final isUserInChat = chatWith == ownerUid;
    final senderName = auth.currentUser!.displayName;
    final giftMessage = {
      'image': imagePath,
      'name': name,
      'sendBy': senderName,
      'sendByID': FirebaseAuth.instance.currentUser!.uid,
      'ts': DateTime.now(),
      'isRead': isUserInChat,
    };
    DatabaseService().addMessage(
      recipient.chatId,
      randomAlphaNumeric(12),
      giftMessage,
    );
    final noticeMessage = {
      'image': imagePath,
      'message': '$senderName подарил вам подарок $name! ❤️',
      'sendBy': senderName,
      'sendByID': FirebaseAuth.instance.currentUser!.uid,
      'ts': DateTime.now(),
      'isRead': isUserInChat,
    };
    DatabaseService().addMessage(
      recipient.chatId,
      randomAlphaNumeric(12),
      noticeMessage,
    );
    initGifts[imagePath] -= 1;
    if (initGifts[imagePath] == 0) initGifts.remove(imagePath);
    coll.update({'gifts': initGifts});
    unawaited(
      _recordRecipientGiftAndNotify(
        senderName,
        name,
        imagePath,
        recipient,
      ).catchError((_) {}),
    );
  }

  Future<void> _recordRecipientGiftAndNotify(
    String? senderName,
    String name,
    String imagePath,
    _GiftRecipient recipient,
  ) async {
    final recipientDoc = await db.collection('users').doc(recipient.uid).get();
    Map<String, dynamic> presentedGifts =
        recipientDoc.data() as Map<String, dynamic>;
    if (presentedGifts.containsKey('presentedGifts')) {
      presentedGifts = presentedGifts['presentedGifts'];
    } else {
      presentedGifts = {};
    }
    if (presentedGifts.containsKey(imagePath)) {
      presentedGifts[imagePath] += 1;
    } else {
      presentedGifts.addAll({imagePath: 1});
    }
    db.collection('users').doc(recipient.uid).update({
      'presentedGifts': presentedGifts,
    });
    final tokenDoc =
        await firebaseFirestore.collection('TOKENS').doc(recipient.uid).get();
    final notificationBody = {
      'message': '$senderName подарил вам подарок $name ❤️',
    };
    NotificationsService().sendPushMessage(
      tokenDoc.get('token'),
      notificationBody,
      recipient.name,
      1,
      recipient.chatId,
    );
  }

  kartochkaTovara(
    String name,
    String url,
    int price,
    bool sold,
    BuildContext context, {
    String? description,
    bool descriptionOnly = false,
  }) {
    return Card(
      color: LrsTheme.surfaceGlass,
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Image.asset(
                url,
                width: double.infinity,
                fit: BoxFit.contain,
                excludeFromSemantics: true,
              ),
            ),
            const SizedBox(height: 4),
            if (!descriptionOnly)
              Text(
                context.tr(name),
                softWrap: true,
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.1,
                  color: LrsTheme.text,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.start,
              ),
            if (!sold)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  '$price Ag',
                  style: const TextStyle(
                    fontSize: 12,
                    color: LrsTheme.peachLight,
                  ),
                ),
              ),
            if (description != null || descriptionOnly)
              Text(
                context.tr(description ?? name),
                softWrap: true,
                style: const TextStyle(
                  fontSize: 11,
                  height: 1.15,
                  color: LrsTheme.text,
                ),
                textAlign: TextAlign.start,
              ),
            sold
                ? Text(
                    'Количество: $price',
                    style: const TextStyle(fontSize: 12, color: LrsTheme.text),
                  )
                : const SizedBox.shrink(),
            const SizedBox(height: 5),
            Row(
              children: [
                Expanded(
                    child: ElevatedButton(
                  onPressed: () async {
                    if (sold) {
                      await _showGiftRecipientSheet(context, name, url);
                      return;
                    }
                    DocumentReference coll =
                        db.collection('users').doc(auth.currentUser!.uid);
                    DocumentSnapshot data = await coll.get();
                    Map userInfo = data.data() as Map;
                    Map<String, dynamic> initGifts =
                        userInfo.containsKey('gifts') ? userInfo['gifts'] : {};

                    if (!sold) {
                      if (globalBalance < price) {
                        showSnackbar(
                          context,
                          Colors.redAccent,
                          'Недостаточно серебра',
                        );
                        return;
                      }

                      setState(() {
                        globalBalance -= price;
                      });

                      coll.update({'balance': globalBalance});

                      if (initGifts.containsKey(url)) {
                        initGifts[url] += 1;
                      } else {
                        initGifts.addAll({url: 1});
                      }
                      coll.update({'gifts': initGifts});
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          behavior: SnackBarBehavior.floating,
                          backgroundColor: const Color(0xA3124725),
                          content: Text(
                            context.tr(
                              'Подарок {name} добавлен',
                              args: {'name': context.tr(name)},
                            ),
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      );
                    }
                  },
                  style: const ButtonStyle(
                    shape: WidgetStatePropertyAll(
                      RoundedRectangleBorder(
                        borderRadius: BorderRadius.all(Radius.circular(10)),
                      ),
                    ),
                    padding: WidgetStatePropertyAll(EdgeInsets.all(7)),
                    backgroundColor: WidgetStatePropertyAll(LrsTheme.peachDark),
                  ),
                  child: sold
                      ? const Text(
                          'Подарить',
                          style: TextStyle(color: Colors.white, fontSize: 14),
                        )
                      : const Text(
                          'Забрать',
                          style: TextStyle(color: Colors.white, fontSize: 14),
                        ),
                )),
              ],
            ),
          ],
        ),
      ),
    );
  }

  final podarki = <Podarok>[
    Podarok(name: 'Фольксваген Туарег', price: 12, img: 'assets/gifts/1.png'),
    Podarok(name: 'Кофе и круассан', price: 12, img: 'assets/gifts/2.png'),
    Podarok(name: 'Большой красивый дом', price: 12, img: 'assets/gifts/3.png'),
    Podarok(name: 'Тесла', price: 12, img: 'assets/gifts/4.png'),
    Podarok(name: 'Гелендваген', price: 12, img: 'assets/gifts/5.png'),
    Podarok(name: 'Вино, сыр, виноград', price: 12, img: 'assets/gifts/6.png'),
    Podarok(name: 'Модная киса в шляпе', price: 12, img: 'assets/gifts/7.png'),
    Podarok(name: 'Киса в банте', price: 12, img: 'assets/gifts/8.png'),
    Podarok(name: 'Ты милая, как зайка', price: 12, img: 'assets/gifts/9.png'),
    Podarok(name: 'Букет красные розы', price: 12, img: 'assets/gifts/10.png'),
    Podarok(name: 'Пойдем поедим', price: 12, img: 'assets/gifts/11.png'),
    Podarok(name: 'Маленький щенок', price: 12, img: 'assets/gifts/12.png'),
    Podarok(
      name: 'Киса упакована в коробку',
      price: 12,
      img: 'assets/gifts/13.png',
    ),
    Podarok(name: 'Серый красивый дом', price: 12, img: 'assets/gifts/14.png'),
    Podarok(name: 'Мне б такую как ты', price: 12, img: 'assets/gifts/15.png'),
    Podarok(
      name: 'Ты - самая прекрасная',
      price: 12,
      img: 'assets/gifts/16.png',
    ),
    Podarok(name: 'Букет розовые розы', price: 12, img: 'assets/gifts/17.png'),
    Podarok(
      name: 'Истосковался по такой как ты',
      price: 12,
      img: 'assets/gifts/18.png',
    ),
    Podarok(name: 'Диадема с рубинами', price: 12, img: 'assets/gifts/19.png'),
    Podarok(name: 'Жду встречи', price: 12, img: 'assets/gifts/20.png'),
    Podarok(
      name: 'Береги себя, ты мне нужна!',
      price: 12,
      img: 'assets/gifts/21.png',
    ),
    Podarok(name: 'Яхта олигарха', price: 12, img: 'assets/gifts/22.png'),
    Podarok(
      name: 'Водочка с селедочкой',
      price: 12,
      img: 'assets/gifts/23.png',
    ),
    Podarok(name: 'Диадема в алмазах', price: 12, img: 'assets/gifts/24.png'),
    Podarok(name: 'Додж челленджер', price: 12, img: 'assets/gifts/25.png'),
    Podarok(
      name: 'Классический красивый дом',
      price: 12,
      img: 'assets/gifts/26.png',
    ),
    Podarok(
      name: 'Семейный красивый дом',
      price: 12,
      img: 'assets/gifts/27.png',
    ),
    Podarok(
      name: 'Современный красивый дом',
      price: 12,
      img: 'assets/gifts/28.png',
    ),
    Podarok(
      name: 'Мое почтение женщине со вкусом',
      price: 12,
      img: 'assets/gifts/29.png',
    ),
    Podarok(
      name: 'Для такой зайки у меня хватит капусты и не только',
      price: 12,
      img: 'assets/gifts/30.png',
      descriptionOnly: true,
    ),
    Podarok(name: 'Инфинити', price: 12, img: 'assets/gifts/31.png'),
    Podarok(name: 'Самой искрометной', price: 12, img: 'assets/gifts/32.png'),
    Podarok(name: 'Кадиллак', price: 12, img: 'assets/gifts/33.png'),
    Podarok(name: 'Кофе корица', price: 12, img: 'assets/gifts/34.png'),
    Podarok(name: 'Кофе и круасан', price: 12, img: 'assets/gifts/35.png'),
    Podarok(name: 'Линкольн', price: 12, img: 'assets/gifts/36.png'),
    Podarok(
      name: 'Мадам, без вас убого',
      price: 12,
      img: 'assets/gifts/37.png',
    ),
    Podarok(name: 'Милый мишка', price: 12, img: 'assets/gifts/38.png'),
    Podarok(name: 'Самой мудрой', price: 12, img: 'assets/gifts/39.png'),
    Podarok(name: 'Мужчине со вкусом', price: 12, img: 'assets/gifts/40.png'),
    Podarok(
      name: 'Настоящему джентельмену',
      price: 12,
      img: 'assets/gifts/41.png',
    ),
    Podarok(
      name: 'Серьезному джентельмену',
      price: 12,
      img: 'assets/gifts/42.png',
    ),
    Podarok(name: 'Настоящему ковбою', price: 12, img: 'assets/gifts/43.png'),
    Podarok(
      name: 'Настоящему полковнику',
      price: 12,
      img: 'assets/gifts/44.png',
    ),
    Podarok(name: 'Настоящему рыцарю', price: 12, img: 'assets/gifts/45.png'),
    Podarok(name: 'Ниссан Скайлайн', price: 12, img: 'assets/gifts/46.png'),
    Podarok(name: 'Ты меня покорила', price: 12, img: 'assets/gifts/47.png'),
    Podarok(
      name: 'Претендуешь - соответствуй',
      price: 12,
      img: 'assets/gifts/48.png',
    ),
    Podarok(
      name: 'Не разменивайся по пустякам',
      price: 12,
      img: 'assets/gifts/49.png',
    ),
    Podarok(name: 'Букет белые розы', price: 12, img: 'assets/gifts/50.png'),
    Podarok(name: 'Букет белых роз', price: 12, img: 'assets/gifts/51.png'),
    Podarok(name: 'Букет черные розы', price: 12, img: 'assets/gifts/52.png'),
    Podarok(name: 'Роковой женщине', price: 12, img: 'assets/gifts/53.png'),
    Podarok(name: 'Самой мудрой', price: 12, img: 'assets/gifts/54.png'),
    Podarok(name: 'Самой опасной', price: 12, img: 'assets/gifts/55.png'),
    Podarok(
      name: 'Самой притягательной',
      price: 12,
      img: 'assets/gifts/56.png',
    ),
    Podarok(name: 'Серьезному мужчине', price: 12, img: 'assets/gifts/57.png'),
    Podarok(name: 'Коньяк и сигары', price: 12, img: 'assets/gifts/58.png'),
    Podarok(name: 'Королю', price: 12, img: 'assets/gifts/59.png'),
    Podarok(name: 'Текила и лимончик', price: 12, img: 'assets/gifts/60.png'),
    Podarok(name: 'Форд Мустанг', price: 12, img: 'assets/gifts/61.png'),
    Podarok(name: 'Хаммер', price: 12, img: 'assets/gifts/62.png'),
    Podarok(name: 'Чаек с вареньем', price: 12, img: 'assets/gifts/63.png'),
    Podarok(
      name: 'Чудесного настроения',
      price: 12,
      img: 'assets/gifts/64.png',
    ),
  ];

  Widget _shopActions(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final scale = MediaQuery.textScalerOf(context).scale(1);
          final columns = constraints.maxWidth < 330 || scale > 1.3 ? 2 : 3;
          final width = (constraints.maxWidth - (columns - 1) * 8) / columns;
          return Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _shopAction(
                context,
                width,
                Icons.add,
                context.tr('Пополнить баланс'),
                () => _showTopUp(context),
              ),
              _shopAction(
                context,
                width,
                Icons.block_outlined,
                context.tr('Отключить рекламу'),
                () {},
              ),
              _shopAction(
                context,
                width,
                Icons.visibility_off_outlined,
                context.tr('Режим невидимки'),
                () => _showInvisibleMode(context),
              ),
            ],
          );
        },
      );

  Widget _shopAction(
    BuildContext context,
    double width,
    IconData icon,
    String label,
    VoidCallback onPressed,
  ) =>
      SizedBox(
        width: width,
        child: OutlinedButton(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            backgroundColor: LrsTheme.actionGlass,
            foregroundColor: LrsTheme.text,
            side: const BorderSide(color: LrsTheme.actionBorder),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 8),
            minimumSize: const Size(0, 70),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 23, color: LrsTheme.peachLight),
              const SizedBox(height: 3),
              Text(
                label,
                textAlign: TextAlign.center,
                softWrap: true,
                style: const TextStyle(
                  color: LrsTheme.text,
                  fontSize: 12,
                  height: 1.15,
                ),
              ),
            ],
          ),
        ),
      );

  void _showTopUp(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .82,
      ),
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Container(
          width: double.infinity,
          decoration: const BoxDecoration(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            color: LrsTheme.surfaceSoft,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  sheetContext.tr('Пополнение баланса'),
                  style: const TextStyle(
                    color: LrsTheme.text,
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                for (int i = 0; i < 6; i++) buyButton(i),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showInvisibleMode(BuildContext context) {
    if (!isUnvisible) {
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .82,
        ),
        builder: (sheetContext) => SafeArea(
          top: false,
          child: Container(
            width: double.infinity,
            decoration: const BoxDecoration(
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              color: LrsTheme.surfaceSoft,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    sheetContext.tr('Режим невидимки'),
                    style: const TextStyle(
                      color: LrsTheme.text,
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  for (int i = 0; i < 4; i++) buyButtonInvisible(i),
                ],
              ),
            ),
          ),
        ),
      ).then((_) {
        if (mounted) setState(() {});
      });
    } else {
      showDialog(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: LrsTheme.surface,
          title: Text(dialogContext.tr('Режим невидимки')),
          content: Text(
            dialogContext.tr(
              'Вы уверены, что хотите выключить режим невидимки?',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(dialogContext.tr('Нет')),
            ),
            TextButton(
              onPressed: () {
                setState(() => isUnvisible = false);
                Navigator.pop(dialogContext);
              },
              child: Text(dialogContext.tr('Да')),
            ),
          ],
        ),
      );
    }
  }

  first(context) {
    final scale = MediaQuery.textScalerOf(context).scale(1);
    final columns =
        MediaQuery.sizeOf(context).width < 340 || scale > 1.3 ? 2 : 3;
    final giftExtent = 245.0 * scale.clamp(1, 2);
    final giftRows = (podarki.length + columns - 1) ~/ columns;
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: giftRows * giftExtent + (giftRows - 1) * 8,
            width: double.infinity,
            child: GridView.builder(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                mainAxisExtent: giftExtent,
                crossAxisCount: columns,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
              ),
              itemCount: podarki.length,
              physics: const NeverScrollableScrollPhysics(),
              itemBuilder: (context, int index) {
                return kartochkaTovara(
                  podarki[index].name,
                  podarki[index].img,
                  podarki[index].price,
                  false,
                  context,
                  description: podarki[index].description,
                  descriptionOnly: podarki[index].descriptionOnly,
                );
              },
            ),
          ),
          const SizedBox(height: 15),
        ],
      ),
    );
  }

  Widget buyButtonInvisible(index) {
    List prices = ['3 дня = ', '7 дней = ', '15 дней = ', '30 дней = '];
    List bonuses = [
      '',
      ' (экономим 17серебра)',
      ' (экономим 51серебра)',
      ' (экономим 112серебра) ',
    ];
    List<int> pricesInt = [24, 39, 69, 128];
    List<int> days = [3, 7, 15, 30];
    List lineThrough = [0, 56, 120, 240];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton(
          onPressed: () {
            if (globalBalance >= pricesInt[index]) {
              setState(() {
                globalBalance -= pricesInt[index];
                isUnvisible = true;
              });
              db.collection('users').doc(firebaseAuth.currentUser!.uid).update({
                'balance': globalBalance,
                'isUnvisible': isUnvisible,
                'unvisibleEnd': DateTime.now().add(Duration(days: days[index])),
              });
              Navigator.pop(context);
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Недостаточно средств')),
              );
            }
          },
          style: _purchaseOptionStyle(),
          child: Row(
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: prices[index],
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      if (index > 0)
                        TextSpan(
                          text: '${lineThrough[index]}Ag ',
                          style: const TextStyle(
                            color: LrsTheme.muted,
                            decoration: TextDecoration.lineThrough,
                          ),
                        ),
                      TextSpan(
                        text: '${pricesInt[index]}Ag',
                        style: const TextStyle(
                          color: LrsTheme.peachLight,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      TextSpan(text: bonuses[index]),
                    ],
                  ),
                  softWrap: true,
                  style: const TextStyle(
                    color: LrsTheme.text,
                    fontSize: 14,
                    height: 1.25,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              const Icon(
                Icons.chevron_right,
                color: LrsTheme.peachLight,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget buyButton(index) {
    List prices = [
      '150 р = ',
      '299 р = ',
      '490 р = ',
      '990 р = ',
      '1490 р = ',
      '2880 р = ',
    ];
    List bonuses = [
      ' 36Ag+3Ag бонуса ',
      ' 76Ag+10Ag бонусов ',
      ' 120Ag+25Ag бонусов ',
      ' 240Ag+65Ag бонусов ',
      ' 360Ag+130Ag бонусов ',
      ' 720Ag+300Ag бонусов ',
    ];
    List pricesInt = [30, 60, 98, 198, 298, 576];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton(
          onPressed: () async {
            String sum = '';
            switch (index) {
              case 0:
                sum = '150';
                break;
              case 1:
                sum = '299';
                break;
              case 2:
                sum = '490';
                break;
              case 3:
                sum = '990';
                break;
              case 4:
                sum = '1490';
                break;
              case 5:
                sum = '2880';
                break;
            }
            int count = 0;
            await firebaseFirestore.collection('transaction').get().then((
              value,
            ) {
              setState(() {
                count = value.docs.length + 1;
              });
            });
            await firebaseFirestore
                .collection('transaction')
                .doc(count.toString())
                .set({
              'id': count.toString(),
              'sum': sum,
              'user_email': firebaseAuth.currentUser!.email,
              'user_id': firebaseAuth.currentUser!.uid,
              'time': DateTime.now().toString(),
            });
            if (context.mounted) {
              nextScreen(context, RobokassaWebview(sum: sum, count: count));
            }
          },
          style: _purchaseOptionStyle(),
          child: Row(
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: prices[index],
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      TextSpan(
                        text: '${pricesInt[index]}Ag ',
                        style: const TextStyle(
                          color: LrsTheme.muted,
                          decoration: TextDecoration.lineThrough,
                        ),
                      ),
                      TextSpan(
                        text: bonuses[index],
                        style: const TextStyle(color: LrsTheme.peachLight),
                      ),
                    ],
                  ),
                  softWrap: true,
                  style: const TextStyle(
                    color: LrsTheme.text,
                    fontSize: 14,
                    height: 1.25,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              const Icon(
                Icons.chevron_right,
                color: LrsTheme.peachLight,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }

  ButtonStyle _purchaseOptionStyle() => OutlinedButton.styleFrom(
        backgroundColor: LrsTheme.actionGlass,
        foregroundColor: LrsTheme.text,
        side: const BorderSide(color: LrsTheme.actionBorder),
        minimumSize: const Size(0, 56),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      );

  second(data, context) {
    if (data != null) {
      final scale = MediaQuery.textScalerOf(context).scale(1);
      final columns =
          MediaQuery.sizeOf(context).width < 340 || scale > 1.3 ? 2 : 3;
      final giftExtent = 245.0 * scale.clamp(1, 2);
      Map initGifts = data.data()!['gifts'] ?? {};
      List urls = initGifts.keys.toList();
      List counts = initGifts.values.toList();
      var indexInPodarki = [];
      for (int i = 0; i < urls.length; i++) {
        indexInPodarki.add(
          podarki.indexWhere((element) => element.img == urls[i]),
        );
      }

      return initGifts.isEmpty
          ? const Center(
              child: Text(
                'У вас нет подарков',
                style: TextStyle(color: Colors.white),
              ),
            )
          : SafeArea(
              child: SizedBox(
                height: (MediaQuery.of(context).size.height * 1) - 100,
                width: double.infinity,
                child: GridView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    mainAxisExtent: giftExtent,
                    crossAxisCount: columns,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                  ),
                  itemCount: initGifts.length,
                  itemBuilder: (context, int index) {
                    return kartochkaTovara(
                      podarki[indexInPodarki[index]].name,
                      urls[index],
                      counts[index]!,
                      true,
                      context,
                      description: podarki[indexInPodarki[index]].description,
                      descriptionOnly:
                          podarki[indexInPodarki[index]].descriptionOnly,
                    );
                  },
                ),
              ),
            );
    } else {
      return const Center(
        child: Text(
          'У вас нет подарков',
          style: TextStyle(color: Colors.white),
        ),
      );
    }
  }
}

class _GiftRecipient {
  const _GiftRecipient({
    required this.chatId,
    required this.uid,
    required this.name,
    required this.imageUrl,
  });

  final String chatId;
  final String uid;
  final String name;
  final String imageUrl;

  static _GiftRecipient? fromChat(
    QueryDocumentSnapshot<Map<String, dynamic>> chat,
    String ownerUid,
  ) {
    final data = chat.data();
    final first = data['user1'] == ownerUid;
    if (!first && data['user2'] != ownerUid) return null;
    final uid = '${first ? data['user2'] ?? '' : data['user1'] ?? ''}';
    if (uid.isEmpty || uid == ownerUid) return null;
    return _GiftRecipient(
      chatId: '${data['chatId'] ?? chat.id}',
      uid: uid,
      name:
          '${first ? data['user2Nickname'] ?? '' : data['user1Nickname'] ?? ''}',
      imageUrl:
          '${first ? data['user2_image'] ?? '' : data['user1_image'] ?? ''}',
    );
  }
}

class _GiftRecipientSheet extends StatefulWidget {
  const _GiftRecipientSheet({
    required this.db,
    required this.auth,
    required this.ownerUid,
    required this.onSend,
  });
  final FirebaseFirestore db;
  final FirebaseAuth auth;
  final String ownerUid;
  final Future<void> Function(_GiftRecipient recipient) onSend;

  @override
  State<_GiftRecipientSheet> createState() => _GiftRecipientSheetState();
}

class _GiftRecipientSheetState extends State<_GiftRecipientSheet> {
  late Future<List<_GiftRecipient>> _recipients;
  _GiftRecipient? _selected;
  bool _sending = false;
  bool _sendAttempted = false;
  bool _sendUnconfirmed = false;

  @override
  void initState() {
    super.initState();
    _recipients = _loadRecipients();
  }

  Future<List<_GiftRecipient>> _loadRecipients() async {
    final snapshot = await widget.db
        .collection('chats')
        .where(
          Filter.or(
            Filter('user1', isEqualTo: widget.ownerUid),
            Filter('user2', isEqualTo: widget.ownerUid),
          ),
        )
        .get()
        .timeout(const Duration(seconds: 20));
    return snapshot.docs
        .map((chat) => _GiftRecipient.fromChat(chat, widget.ownerUid))
        .whereType<_GiftRecipient>()
        .toList();
  }

  Future<void> _send() async {
    final recipient = _selected;
    if (_sending ||
        _sendAttempted ||
        recipient == null ||
        widget.auth.currentUser?.uid != widget.ownerUid) {
      return;
    }
    setState(() {
      _sending = true;
      _sendAttempted = true;
    });
    try {
      await widget.onSend(recipient);
      if (!mounted) return;
      setState(() => _sending = false);
      Navigator.pop(context, recipient);
    } catch (_) {
      if (mounted) {
        setState(() {
          _sending = false;
          _sendUnconfirmed = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !_sending,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Column(
              children: [
                Text(
                  context.tr('Отправить в чат'),
                  style: const TextStyle(
                    color: LrsTheme.text,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                if (_sendUnconfirmed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      context.tr(
                        'Предыдущая отправка ожидает подтверждения. Проверьте результат.',
                      ),
                      style: const TextStyle(color: LrsTheme.peachLight),
                    ),
                  ),
                Expanded(
                  child: widget.auth.currentUser?.uid != widget.ownerUid
                      ? Center(
                          child: Text(
                              context.tr('Сеанс завершён. Войдите снова.')),
                        )
                      : FutureBuilder<List<_GiftRecipient>>(
                          future: _recipients,
                          builder: (context, snapshot) {
                            if (snapshot.hasError) {
                              return Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(context
                                        .tr('Не удалось загрузить чаты.')),
                                    TextButton(
                                      onPressed: () => setState(
                                        () => _recipients = _loadRecipients(),
                                      ),
                                      child: Text(context.tr('Повторить')),
                                    ),
                                  ],
                                ),
                              );
                            }
                            if (!snapshot.hasData) {
                              return const Center(
                                child: CircularProgressIndicator(),
                              );
                            }
                            final recipients = snapshot.data!;
                            if (recipients.isEmpty) {
                              return Center(
                                child: Text(
                                  context.tr('Здесь появятся ваши диалоги'),
                                ),
                              );
                            }
                            return ListView.builder(
                              itemCount: recipients.length,
                              itemBuilder: (context, index) {
                                final recipient = recipients[index];
                                return ListTile(
                                  selected:
                                      _selected?.chatId == recipient.chatId,
                                  leading: CircleAvatar(
                                    backgroundImage: recipient.imageUrl.isEmpty
                                        ? null
                                        : NetworkImage(recipient.imageUrl),
                                    child: recipient.imageUrl.isEmpty
                                        ? const Icon(Icons.person)
                                        : null,
                                  ),
                                  title: Text(
                                    recipient.name.isEmpty
                                        ? recipient.uid
                                        : recipient.name,
                                  ),
                                  onTap: _sending || _sendAttempted
                                      ? null
                                      : () =>
                                          setState(() => _selected = recipient),
                                );
                              },
                            );
                          },
                        ),
                ),
                if (_selected != null)
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _sending || _sendAttempted ? null : _send,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: LrsTheme.peachDark,
                        foregroundColor: LrsTheme.background,
                      ),
                      child: _sending
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(context.tr('Подарить')),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
}
