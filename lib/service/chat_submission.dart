import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:wbrs/app/helper/global.dart';
import 'pending_write.dart';
import 'notifications.dart';
import 'submission_journal.dart';

class ChatSubmission {
  ChatSubmission({required this.text, required this.write, this.sharedContent});
  final String text;
  final PendingWrite write;
  final Map<String, String>? sharedContent;
}

/// A stable message ID and its body are durable before contacting Firestore.
/// The same transaction reconciles an uncertain commit after reopening the app.
class ChatSubmissionService {
  ChatSubmissionService(
      {FirebaseFirestore? firestore,
      FirebaseAuth? auth,
      SubmissionJournal? journal})
      : _db = firestore ?? firebaseFirestore,
        _auth = auth ?? firebaseAuth,
        _journal = journal ?? SubmissionJournal() {
    _uid = _auth.currentUser?.uid;
  }
  final FirebaseFirestore _db;
  final FirebaseAuth _auth;
  final SubmissionJournal _journal;
  late final String? _uid;
  static final Map<String, ChatSubmission> _pending = {};
  bool get isCurrentSession => _uid != null && _auth.currentUser?.uid == _uid;
  String _scope(String chatId, bool group, String? replyId) =>
      '${group ? 'meetingMessage' : 'chatMessage'}/$chatId${replyId == null ? '' : '/reply/$replyId'}';
  String _key(String scope) => '$_uid/$scope';

  Future<ChatSubmission?> restore(String chatId,
      {bool group = false, String? replyId}) async {
    if (!isCurrentSession) return null;
    final scope = _scope(chatId, group, replyId);
    final memory = _pending[_key(scope)];
    if (memory != null) return memory;
    final saved = await _journal.load(_uid!, scope);
    if (!isCurrentSession || saved == null) return null;
    final fields = Map<String, dynamic>.from(saved['fields'] as Map);
    return start(
        chatId: chatId,
        text: fields['text'] as String,
        recipientId: fields['recipientId'] as String?,
        sharedContent:
            (fields['sharedContent'] as Map?)?.cast<String, String>(),
        group: group,
        replyId: replyId,
        reply: (fields['reply'] as Map?)?.cast<String, dynamic>());
  }

  ChatSubmission start(
      {required String chatId,
      required String text,
      String? recipientId,
      Map<String, String>? sharedContent,
      bool group = false,
      String? replyId,
      Map<String, dynamic>? reply}) {
    if (!isCurrentSession) throw StateError('Сеанс завершён. Войдите снова.');
    final scope = _scope(chatId, group, replyId);
    final key = _key(scope);
    final previous = _pending[key];
    if (previous != null && !previous.write.failed) return previous;
    return _pending[key] = ChatSubmission(
        text: text,
        sharedContent: sharedContent,
        write: PendingWrite(() async {
          // Only confirmed failures permit a different draft. A timeout never does.
          final saved = await _journal.prepare(
              _uid!,
              scope,
              {
                'text': text,
                'recipientId': recipientId,
                if (sharedContent != null) 'sharedContent': sharedContent,
                'reply': reply,
                'timestamp': DateTime.now().toIso8601String(),
              },
              null,
              replaceRejected: previous?.write.failed == true);
          if (!isCurrentSession)
            throw StateError('Сеанс завершён. Войдите снова.');
          final fields = saved['fields'] as Map;
          final user = _auth.currentUser!;
          final room = _db.collection(group ? 'meets' : 'chats').doc(chatId);
          final message = room
              .collection(group ? 'messages' : 'chats')
              .doc(saved['id'] as String);
          var notifyRecipient = false;
          var notifyGroup = false;
          await _db.runTransaction((transaction) async {
            notifyRecipient = false;
            notifyGroup = false;
            final roomSnapshot = await transaction.get(room);
            final existing = await transaction.get(message);
            if (!isCurrentSession)
              throw StateError('Сеанс завершён. Войдите снова.');
            if (existing.exists) return;
            final roomData = roomSnapshot.data() ?? <String, dynamic>{};
            final member = group
                ? (roomData['users'] as List? ?? const []).contains(_uid)
                : roomData['user1'] == _uid || roomData['user2'] == _uid;
            if (!roomSnapshot.exists || !member)
              throw StateError('Чат недоступен');
            final stamp = Timestamp.fromDate(
                DateTime.parse(fields['timestamp'] as String));
            var read = false;
            var senderName = user.displayName ?? '';
            var senderGroup = '';
            if (group) {
              final profile =
                  await transaction.get(_db.collection('users').doc(_uid));
              if (!isCurrentSession)
                throw StateError('Сеанс завершён. Войдите снова.');
              senderName = profile.data()?['fullName'] as String? ?? senderName;
              senderGroup = profile.data()?['группа'] as String? ?? '';
              notifyGroup = true;
            }
            if (!group) {
              final recipientId = fields['recipientId'] ??
                  (roomData['user1'] == _uid
                      ? roomData['user2']
                      : roomData['user1']);
              final recipient = await transaction
                  .get(_db.collection('users').doc(recipientId as String));
              if (!isCurrentSession)
                throw StateError('Сеанс завершён. Войдите снова.');
              if (!recipient.exists ||
                  recipient.data()?['deleted'] == true ||
                  recipient.data()?['status'] == 'deleted' ||
                  recipient.data()?['registrationStatus'] == 'deleted')
                throw StateError('Чат недоступен');
              read = recipient.data()?['chatWithId'] == _uid;
              notifyRecipient =
                  !(roomData['usersWOutNotifications'] as List? ?? const [])
                      .contains(recipientId);
            }
            transaction.set(message, {
              'type': 'text',
              'message': fields['text'],
              'sendBy': user.displayName ?? '',
              'sendByID': _uid,
              'sender': _uid,
              'name': senderName,
              if (group) 'group': senderGroup,
              'avatar': user.photoURL,
              'isRead': read,
              group ? 'time' : 'ts': stamp,
              if (fields['reply'] != null) 'replyMessage': fields['reply'],
              if (fields['sharedContent'] != null)
                'sharedContent': fields['sharedContent'],
            });
            transaction.update(
                room,
                group
                    ? {
                        'recentMessage': fields['text'],
                        'recentMessageSender': senderName,
                        'recentMessageTime':
                            DateTime.parse(fields['timestamp'] as String)
                                .toString(),
                      }
                    : {
                        'lastMessage': fields['text'],
                        'lastSharedKind': fields['sharedContent'] == null
                            ? FieldValue.delete()
                            : (fields['sharedContent'] as Map)['kind'],
                        'lastMessageSendTs': stamp,
                        'lastMessageSendBy': user.displayName ?? '',
                        'lastMessageSendByID': _uid,
                        if (!read) 'unreadMessage': FieldValue.increment(1),
                      });
          });
          if (notifyRecipient && isCurrentSession) {
            await NotificationsService()
                .sendPushMessage('', {'messageId': saved['id']}, '', 1, chatId);
          }
          if (notifyGroup && isCurrentSession) {
            await NotificationsService().sendPushMessageGroup(
                '', {'messageId': saved['id']}, '', 1, chatId);
          }
          try {
            await _journal.acknowledge(_uid, scope, saved['id'] as String);
          } catch (_) {}
        }));
  }

  void acknowledge(String chatId, ChatSubmission request,
      {bool group = false, String? replyId}) {
    if (!isCurrentSession || !request.write.completed || request.write.failed)
      return;
    final key = _key(_scope(chatId, group, replyId));
    if (identical(_pending[key], request)) _pending.remove(key);
  }
}
