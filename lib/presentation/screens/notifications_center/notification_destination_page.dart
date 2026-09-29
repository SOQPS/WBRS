import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/presentation/screens/chat_screen/chatscreen.dart';
import 'package:wbrs/presentation/screens/feed/post_detail_page.dart';
import 'package:wbrs/presentation/screens/friends/friends_page.dart';
import 'package:wbrs/presentation/screens/list_of_meets/show/about_meet.dart';
import 'package:wbrs/presentation/screens/list_of_meets/show/about_individual_meet.dart';
import 'package:wbrs/shared/clrs_screen.dart';

/// Resolves the current resource rather than trusting stale notification data.
class NotificationDestinationPage extends StatefulWidget {
  const NotificationDestinationPage({super.key, required this.notification});
  final Map<String, dynamic> notification;
  @override
  State<NotificationDestinationPage> createState() =>
      _NotificationDestinationPageState();
}

class _NotificationDestinationPageState
    extends State<NotificationDestinationPage> {
  late Future<Widget?> _destination = _load();

  Future<Widget?> _load() async {
    final uid = firebaseAuth.currentUser?.uid;
    if (uid == null) throw StateError('session');
    final data = widget.notification;
    final type = data['type']?.toString() ?? '';
    final id = data['entityId']?.toString() ?? '';
    if (id.isEmpty || id.contains('/')) return null;
    Widget? result;
    if (type == 'friend_request' || type == 'friend_accepted') {
      result = const FriendsPage();
    } else if (type == 'gift') {
      final chat = await firebaseFirestore
          .collection('chats')
          .doc(id)
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 15));
      if (!chat.exists) return null;
      final users = chat.data()!;
      if (users['user1'] != uid && users['user2'] != uid) return null;
      final otherUid =
          (users['user1'] == uid ? users['user2'] : users['user1'])?.toString();
      if (otherUid == null || otherUid.isEmpty || otherUid.contains('/')) {
        return null;
      }
      final other = await firebaseFirestore
          .collection('users')
          .doc(otherUid)
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 15));
      if (!other.exists) return null;
      result = ChatScreen(
          chatWithUsername: other.data()?['fullName']?.toString() ?? '',
          photoUrl: other.data()?['profilePic']?.toString() ?? '',
          id: otherUid,
          chatId: id);
    } else if (const {
      'post_comment',
      'comment_reply',
      'comment_like',
      'post_like',
      'post'
    }.contains(type)) {
      final post = await firebaseFirestore
          .collection('posts')
          .doc(id)
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 15));
      if (!post.exists || post.data()?['status'] != 'published') return null;
      final rootId = data['rootCommentId']?.toString();
      result = PostDetailPage(
          postId: id,
          post: post.data()!,
          threadRootId:
              rootId != null && rootId.isNotEmpty && !rootId.contains('/')
                  ? rootId
                  : null);
    } else if (type == 'meeting') {
      final query = await firebaseFirestore
          .collection('meets')
          .where(FieldPath.documentId, isEqualTo: id)
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 15));
      if (query.docs.isEmpty) return null;
      final meet = query.docs.first.data();
      final users = meet['users'] is List ? meet['users'] as List : const [];
      if (meet['type'] == 'групповая') {
        result = AboutMeet(
            id: id,
            users: users,
            name: meet['name']?.toString() ?? '',
            is_user_join: users.contains(uid));
      } else {
        final admin = await firebaseFirestore
            .collection('users')
            .doc(meet['admin']?.toString() ?? '')
            .get(const GetOptions(source: Source.server))
            .timeout(const Duration(seconds: 15));
        if (!admin.exists) return null;
        result = AboutIndividualMeet(
            snapshot: AsyncSnapshot.withData(ConnectionState.done, query),
            index: 0,
            doc: admin);
      }
    }
    if (firebaseAuth.currentUser?.uid != uid) throw StateError('session');
    return result;
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Widget?>(
      future: _destination,
      builder: (context, snapshot) {
        if (snapshot.hasData) return snapshot.data!;
        return ClrsScaffold(
            appBar: AppBar(title: Text(context.tr('Уведомление'))),
            body: Center(
                child: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: snapshot.connectionState != ConnectionState.done
                        ? const CircularProgressIndicator()
                        : ClrsPanel(
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                Text(
                                    context.tr(snapshot.hasError
                                        ? 'Не удалось открыть уведомление. Проверьте подключение.'
                                        : 'Материал удалён или больше недоступен.'),
                                    textAlign: TextAlign.center),
                                if (snapshot.hasError)
                                  TextButton(
                                      onPressed: () => setState(() {
                                            _destination = _load();
                                          }),
                                      child: Text(context.tr('Повторить'))),
                              ])))));
      });
}
