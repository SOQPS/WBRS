import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/app/helper/helper_function.dart';
import 'package:wbrs/app/widgets/widgets.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/presentation/screens/chat_screen/chatscreen.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/shared/translatable_text.dart';

class ChatRoomList extends StatefulWidget {
  const ChatRoomList({super.key, required this.snapshot});
  final QueryDocumentSnapshot snapshot;
  @override
  State<ChatRoomList> createState() => _ChatRoomListState();
}

class _ChatRoomListState extends State<ChatRoomList> {
  late String? _uid;
  late String _otherId;
  bool _belongs = false;
  late Future<DocumentSnapshot<Map<String, dynamic>>> _other;
  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _uid = firebaseAuth.currentUser?.uid;
    final data = widget.snapshot.data() as Map<String, dynamic>;
    _belongs = _uid != null && (data['user1'] == _uid || data['user2'] == _uid);
    if (!_belongs) return;
    _otherId = '${data['user1'] == _uid ? data['user2'] : data['user1']}';
    _other = firebaseFirestore.collection('users').doc(_otherId).get();
  }

  @override
  void didUpdateWidget(covariant ChatRoomList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.snapshot.id != widget.snapshot.id ||
        _uid != firebaseAuth.currentUser?.uid) _load();
  }

  @override
  Widget build(BuildContext context) =>
      !_belongs || firebaseAuth.currentUser?.uid != _uid
          ? const SizedBox.shrink()
          : FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              future: _other,
              builder: (context, snapshot) {
                if (snapshot.hasError)
                  return ListTile(
                      title: Text(context.tr('Не удалось загрузить профиль.')),
                      trailing: IconButton(
                          tooltip: context.tr('Повторить'),
                          onPressed: () => setState(_load),
                          icon: const Icon(Icons.refresh)));
                if (!snapshot.hasData)
                  return const Padding(
                      padding: EdgeInsets.all(20),
                      child: Center(child: CircularProgressIndicator()));
                final profile = snapshot.data!.data();
                final available = snapshot.data!.exists &&
                    profile != null &&
                    profile['deleted'] != true &&
                    profile['status'] != 'deleted' &&
                    profile['registrationStatus'] != 'deleted';
                final name = available
                    ? '${profile['fullName'] ?? ''}'
                    : context.tr('Удаленный пользователь');
                final photo = available
                    ? '${profile['profilePicThumb'] ?? profile['profilePic'] ?? ''}'
                    : '';
                final data = widget.snapshot.data() as Map<String, dynamic>;
                final text = '${data['lastMessage'] ?? ''}';
                final sharedKind = data['lastSharedKind']?.toString();
                final unread = data['lastMessageSendByID'] != _uid
                    ? (data['unreadMessage'] as num? ?? 0)
                    : 0;
                return InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: _uid == null
                        ? null
                        : () => nextScreen(
                            context,
                            ChatScreen(
                                chatWithUsername: name,
                                photoUrl: photo,
                                id: _otherId,
                                chatId: widget.snapshot.id)),
                    child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              userImageWithCircle(
                                  photo,
                                  available ? '${profile['группа'] ?? ''}' : '',
                                  available && profile['online'] == true,
                                  46,
                                  46),
                              const SizedBox(width: 12),
                              Expanded(
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                    Text(name,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w700)),
                                    const SizedBox(height: 4),
                                    if (text.isEmpty)
                                      Text(context.tr('Сообщений пока нет'),
                                          style: const TextStyle(
                                              color: LrsTheme.muted))
                                    else ...[
                                      Text(
                                          '${data['lastMessageSendByID'] == _uid ? context.tr('Вы') : data['lastMessageSendBy'] ?? ''}:',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              color: LrsTheme.muted)),
                                      sharedKind == 'post' ||
                                              sharedKind == 'comment'
                                          ? Text(
                                              context.tr(sharedKind == 'post'
                                                  ? 'Публикация'
                                                  : 'Комментарий'),
                                              style: const TextStyle(
                                                  color: LrsTheme.muted))
                                          : TranslatableText(text,
                                              autoTranslate: true,
                                              showAction: false,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                  color: LrsTheme.muted)),
                                    ],
                                  ])),
                              if (unread > 0)
                                Padding(
                                    padding: const EdgeInsets.only(left: 6),
                                    child: Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 6, vertical: 3),
                                        decoration: BoxDecoration(
                                            color: LrsTheme.peach,
                                            borderRadius:
                                                BorderRadius.circular(20)),
                                        child: Text(context.l10n.number(unread),
                                            style: const TextStyle(
                                                color: LrsTheme.background,
                                                fontSize: 12)))),
                            ])));
              });
}
