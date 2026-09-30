import 'package:wbrs/shared/translatable_text.dart';
import 'package:wbrs/shared/group_avatar.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'notification_destination_page.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:wbrs/service/social_service.dart';
import 'package:wbrs/service/pending_write.dart';
import 'package:wbrs/service/session_service.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/lrs_theme.dart';

class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});
  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  final SocialService _social = SocialService();
  late final Stream<QuerySnapshot<Map<String, dynamic>>> _notifications;
  String _filter = 'Все';
  bool _marking = false;
  PendingWrite? _pendingRead;
  String? _notice;
  bool _opening = false;

  Future<void> _open(QueryDocumentSnapshot<Map<String, dynamic>> doc) async {
    if (_opening || !_social.isCurrentSession) return;
    _opening = true;
    if (doc.data()['read'] != true && !_marking && _pendingRead == null)
      _read([doc]);
    try {
      await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) =>
              NotificationDestinationPage(notification: doc.data())));
    } finally {
      _opening = false;
    }
  }

  @override
  void initState() {
    super.initState();
    try {
      _notifications = _social.notifications();
    } catch (error) {
      _notifications = Stream.error(error);
    }
  }

  bool _matches(String type) {
    switch (_filter) {
      case 'Ответы':
        return type == 'post_comment' || type == 'comment_reply';
      case 'Реакции':
        return type == 'comment_like' || type == 'post_like';
      case 'Встречи':
        return type == 'meeting';
      default:
        return true;
    }
  }

  Future<void> _read(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) async {
    if (_marking) return;
    setState(() => _marking = true);
    try {
      if (!_social.isCurrentSession) throw StateError('Сеанс завершён');
      _pendingRead ??= PendingWrite(() => _social.markNotificationsRead(docs
          .where((doc) => doc.data()['read'] != true)
          .map((doc) => doc.id)));
      final confirmed =
          await _pendingRead!.wait(timeout: Duration(seconds: 10));
      if (!mounted) return;
      if (!_social.isCurrentSession) {
        setState(() => _notice =
            'Сеанс изменился. Войдите снова, чтобы проверить уведомления.');
        return;
      }
      setState(() {
        if (confirmed) {
          _pendingRead = null;
          _notice = null;
        } else {
          _notice =
              'Подтверждение ещё не получено. Операция может завершиться при восстановлении связи. '
              'Проверка результата не отправляет запрос повторно.';
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _pendingRead = null;
          _notice =
              'Не удалось отметить уведомления. Проверьте сеанс и повторите попытку.';
        });
      }
    } finally {
      if (mounted) setState(() => _marking = false);
    }
  }

  @override
  Widget build(BuildContext context) => ClrsScaffold(
        appBar: AppBar(title: Text(context.tr('Уведомления'))),
        body: AnimatedBuilder(
            animation: SessionService.readyUserId,
            builder: (context, _) {
              if (!_social.isCurrentSession) {
                return Center(
                    child: Text(context.tr('Сеанс завершён. Войдите снова')));
              }
              return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: _notifications,
                  builder: (context, snapshot) {
                    final all = snapshot.data?.docs ??
                        <QueryDocumentSnapshot<Map<String, dynamic>>>[];
                    final docs = all
                        .where((d) => _matches('${d.data()['type'] ?? ''}'))
                        .toList();
                    // The header and filters scroll with the list at large text/short heights.
                    return ListView(padding: EdgeInsets.all(16), children: [
                      ClrsBrandHeader(),
                      Wrap(spacing: 4, runSpacing: 4, children: [
                        for (final filter in [
                          'Все',
                          'Ответы',
                          'Реакции',
                          'Встречи'
                        ])
                          ChoiceChip(
                              label: Text(context.tr(filter)),
                              labelPadding:
                                  const EdgeInsets.symmetric(horizontal: 3),
                              visualDensity: VisualDensity.compact,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.padded,
                              selected: _filter == filter,
                              showCheckmark: false,
                              labelStyle: TextStyle(
                                  color: _filter == filter
                                      ? LrsTheme.peachLight
                                      : LrsTheme.text,
                                  fontWeight: _filter == filter
                                      ? FontWeight.w700
                                      : FontWeight.w400),
                              side: BorderSide(
                                  color: _filter == filter
                                      ? LrsTheme.peachLight
                                      : const Color(0x66E7B092),
                                  width: _filter == filter ? 2 : 0.8),
                              selectedColor: Color(0x775E3C2A),
                              backgroundColor: Color(0x5531241D),
                              onSelected: (_) =>
                                  setState(() => _filter = filter)),
                      ]),
                      if (_notice != null)
                        Padding(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            child:
                                ClrsPanel(child: Text(context.tr(_notice!)))),
                      if (snapshot.hasError)
                        ClrsPanel(
                            child: Text(
                                context.tr('Уведомления временно недоступны.')))
                      else if (!snapshot.hasData)
                        Padding(
                            padding: EdgeInsets.all(32),
                            child: Center(child: CircularProgressIndicator()))
                      else ...[
                        Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                                onPressed: _marking ||
                                        (_pendingRead == null &&
                                            !all.any((d) =>
                                                d.data()['read'] != true))
                                    ? null
                                    : () => _read(all),
                                child: Text(context.tr(_marking
                                    ? 'Сохранение…'
                                    : _pendingRead != null
                                        ? 'Проверить результат'
                                        : 'Прочитать все')))),
                        if (docs.isEmpty)
                          ClrsPanel(
                              child: Text(context
                                  .tr('Здесь появятся важные уведомления'))),
                        for (final doc in docs)
                          Padding(
                              padding: EdgeInsets.only(bottom: 12),
                              child: ClrsPanel(
                                  padding: EdgeInsets.zero,
                                  child: ListTile(
                                    contentPadding: EdgeInsets.all(12),
                                    leading: (doc
                                                    .data()['actorPhoto']
                                                    ?.toString() ??
                                                '')
                                            .isNotEmpty
                                        ? GroupAvatar(
                                            url: doc
                                                .data()['actorPhoto']
                                                .toString(),
                                            group: '',
                                            size: 40)
                                        : CircleAvatar(
                                            backgroundColor:
                                                const Color(0x665E3C2A),
                                            child: Icon(
                                                _iconFor(
                                                    '${doc.data()['type'] ?? ''}'),
                                                color: LrsTheme.peach)),
                                    title: _contentTitle(doc.data()),
                                    subtitle: Padding(
                                        padding: const EdgeInsets.only(top: 7),
                                        child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              _contentBody(doc.data()),
                                              if (doc.data()['createdAt']
                                                  is Timestamp) ...[
                                                const SizedBox(height: 6),
                                                Text(
                                                    context.l10n.dateTime(
                                                        (doc.data()['createdAt']
                                                                as Timestamp)
                                                            .toDate()),
                                                    style: const TextStyle(
                                                        fontSize: 11,
                                                        color: LrsTheme.muted)),
                                              ],
                                            ])),
                                    trailing: doc.data()['read'] != true
                                        ? Icon(Icons.circle,
                                            color: LrsTheme.peach, size: 8)
                                        : null,
                                    onTap: () => _open(doc),
                                  ))),
                      ],
                      ClrsValuesFooter(),
                    ]);
                  });
            }),
      );
  static const _localizedTypes = {
    'post_comment',
    'comment_reply',
    'friend_request',
    'friend_accepted',
    'post_like',
    'comment_like',
    'meeting',
    'gift',
  };

  Widget _contentTitle(Map<String, dynamic> data) {
    final style = TextStyle(
        fontWeight: data['read'] != true ? FontWeight.w700 : FontWeight.w400);
    if (_hasLegacyGiftText(data, 'title')) {
      return TranslatableText(data['title'].toString(),
          showAction: false, style: style);
    }
    if (_localizedTypes.contains(data['type']) ||
        (data['title']?.toString() ?? '').trim().isEmpty) {
      return Text(_title(data), style: style);
    }
    return TranslatableText(data['title'].toString(),
        showAction: false, style: style);
  }

  Widget _contentBody(Map<String, dynamic> data) {
    const style = TextStyle(color: LrsTheme.peachLight, height: 1.4);
    if (_hasLegacyGiftText(data, 'body')) {
      return TranslatableText(data['body'].toString(),
          showAction: false, style: style);
    }
    if (_localizedTypes.contains(data['type'])) {
      if (data['type'] == 'gift') {
        final gift = data['giftName']?.toString() ?? '';
        return Text(gift.isEmpty ? context.tr('Подарок') : context.tr(gift),
            style: style);
      }
      return Text(_body(data), style: style);
    }
    return TranslatableText(data['body']?.toString() ?? '',
        showAction: false, style: style);
  }

  bool _hasLegacyGiftText(Map<String, dynamic> data, String field) =>
      data['type'] == 'gift' &&
      (data['giftName']?.toString() ?? '').trim().isEmpty &&
      (data[field]?.toString() ?? '').trim().isNotEmpty;

  String _title(Map<String, dynamic> data) {
    final key = switch (data['type']) {
      'post_comment' => 'Новый комментарий',
      'comment_reply' => 'Ответ на комментарий',
      'friend_request' => 'Заявка в друзья',
      'friend_accepted' => 'Заявка принята',
      'post_like' || 'comment_like' => 'Новая реакция',
      'meeting' => 'Встреча',
      'gift' => 'Подарок',
      _ => data['title']?.toString() ?? 'Уведомление',
    };
    return context.tr(key);
  }

  String _body(Map<String, dynamic> data) {
    final name = data['actorName']?.toString() ?? '';
    final key = switch (data['type']) {
      'post_comment' => '{name} прокомментировал(а) публикацию',
      'comment_reply' => '{name} ответил(а) на комментарий',
      'friend_request' => '{name} хочет добавить вас в друзья',
      'friend_accepted' => '{name} теперь у вас в друзьях',
      'post_like' || 'comment_like' => 'Новая реакция',
      'meeting' => data['kind'] == 'invitation'
          ? 'Приглашение на личную встречу'
          : 'Новое событие во встрече',
      _ => null,
    };
    if (key == null) return data['body']?.toString() ?? '';
    if (key.contains('{name}') && name.isEmpty)
      return context.tr('У вас новое уведомление');
    return context.tr(key, args: {'name': name});
  }

  IconData _iconFor(String type) {
    switch (type) {
      case 'friend_request':
      case 'friend_accepted':
        return Icons.people_outline;
      case 'post_comment':
      case 'comment_reply':
        return Icons.mode_comment_outlined;
      case 'comment_like':
      case 'post_like':
        return Icons.favorite_border;
      case 'meeting':
        return Icons.event_outlined;
      case 'gift':
        return Icons.card_giftcard;
      default:
        return Icons.notifications_none;
    }
  }
}
