import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/service/chat_submission.dart';
import 'package:wbrs/service/social_service.dart';
import 'package:wbrs/shared/lrs_theme.dart';

Future<bool?> showShareToChatSheet(BuildContext context,
        {required String postId, String? commentId, SocialService? social}) =>
    showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: LrsTheme.surface,
      builder: (_) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .68,
        child: ShareToChatSheet(
            postId: postId, commentId: commentId, social: social),
      ),
    );

class ShareToChatSheet extends StatefulWidget {
  const ShareToChatSheet(
      {super.key, required this.postId, this.commentId, this.social});
  final String postId;
  final String? commentId;
  final SocialService? social;

  @override
  State<ShareToChatSheet> createState() => _ShareToChatSheetState();
}

class _ShareToChatSheetState extends State<ShareToChatSheet> {
  late final String? _ownerUid = firebaseAuth.currentUser?.uid;
  late final SocialService _social = widget.social ?? SocialService();
  late final ChatSubmissionService _submissions = ChatSubmissionService();
  late final Future<Map<String, String>> _content =
      _social.shareableContent(widget.postId, commentId: widget.commentId);
  String? _selectedChat, _notice;
  ChatSubmission? _request;
  bool _sending = false;

  bool get _current =>
      mounted &&
      _ownerUid != null &&
      firebaseAuth.currentUser?.uid == _ownerUid &&
      _submissions.isCurrentSession;

  Future<void> _send(String chatId, String recipientUid) async {
    if (!_current ||
        _sending ||
        (_selectedChat != null && _selectedChat != chatId)) return;
    setState(() {
      _selectedChat = chatId;
      _sending = true;
      _notice = null;
    });
    try {
      final content = await _content.timeout(const Duration(seconds: 15));
      if (!_current) return;
      final label =
          content['kind'] == 'comment' ? 'Комментарий CLRS' : 'Публикация CLRS';
      _request ??= _submissions.start(
          chatId: chatId,
          text: label,
          recipientId: recipientUid,
          sharedContent: content);
      if (_request!.text != label ||
          _request!.sharedContent?['postId'] != content['postId'] ||
          _request!.sharedContent?['commentId'] != content['commentId']) {
        setState(() => _notice =
            'Предыдущая отправка ожидает подтверждения. Проверьте результат.');
        return;
      }
      final confirmed = await _request!.write.wait();
      if (!_current) return;
      if (!confirmed) {
        setState(() => _notice =
            'Подтверждение ещё не получено. Нажмите «Проверить отправку».');
        return;
      }
      _submissions.acknowledge(chatId, _request!);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (_) {
      if (_current) {
        setState(() {
          _notice = 'Не удалось отправить сообщение. Попробуйте ещё раз.';
          if (_request?.write.failed == true) {
            _request = null;
            _selectedChat = null;
          }
        });
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = _ownerUid;
    if (uid == null || firebaseAuth.currentUser?.uid != uid) {
      return Center(child: Text(context.tr('Сеанс завершён. Войдите снова.')));
    }
    final chats = firebaseFirestore.collection('chats').where(Filter.or(
        Filter('user1', isEqualTo: uid), Filter('user2', isEqualTo: uid)));
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(context.tr('Отправить в чат'),
              style:
                  const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          if (_notice != null)
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(context.tr(_notice!),
                    style: const TextStyle(color: LrsTheme.peachLight))),
          Flexible(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: chats.snapshots(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(
                      child: Text(context.tr('Не удалось загрузить чаты.')));
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final rows = snapshot.data!.docs;
                if (rows.isEmpty) {
                  return Center(
                      child: Text(context.tr('Здесь появятся ваши диалоги')));
                }
                return ListView.builder(
                  shrinkWrap: true,
                  itemCount: rows.length,
                  itemBuilder: (context, index) {
                    final chat = rows[index];
                    final data = chat.data();
                    final mineIsFirst = data['user1'] == uid;
                    final otherUid =
                        (mineIsFirst ? data['user2'] : data['user1'])
                                ?.toString() ??
                            '';
                    final otherName = (mineIsFirst
                                ? data['user2Nickname']
                                : data['user1Nickname'])
                            ?.toString() ??
                        '';
                    final enabled = otherUid.isNotEmpty &&
                        (_selectedChat == null || _selectedChat == chat.id) &&
                        !_sending;
                    return ListTile(
                      leading: const Icon(Icons.chat_bubble_outline,
                          color: LrsTheme.peachLight),
                      title: Text(otherName.isEmpty ? otherUid : otherName,
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                      trailing: _selectedChat == chat.id && _sending
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.send_outlined),
                      onTap: enabled ? () => _send(chat.id, otherUid) : null,
                    );
                  },
                );
              },
            ),
          ),
        ]),
      ),
    );
  }
}
