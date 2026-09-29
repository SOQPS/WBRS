import 'package:wbrs/shared/translatable_text.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/service/social_service.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/group_avatar.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'post_detail_page.dart';

class ProfileWallPage extends StatefulWidget {
  const ProfileWallPage({super.key, required this.userUid, this.userName});
  final String userUid;
  final String? userName;
  @override
  State<ProfileWallPage> createState() => _ProfileWallPageState();
}

class _ProfileWallPageState extends State<ProfileWallPage> {
  late Stream<QuerySnapshot<Map<String, dynamic>>> _wall = _load();
  Stream<QuerySnapshot<Map<String, dynamic>>> _load() => firebaseFirestore
      .collection('users')
      .doc(widget.userUid)
      .collection('wall')
      .orderBy('createdAt', descending: true)
      .snapshots();

  @override
  Widget build(BuildContext context) => ClrsScaffold(
        appBar: AppBar(title: Text(context.tr('Стена'))),
        body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: _wall,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                  child: SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: ClrsPanel(
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
                        Text(context.tr('Не удалось загрузить публикации.')),
                        TextButton(
                            onPressed: () => setState(() => _wall = _load()),
                            child: Text(context.tr('Повторить'))),
                      ]))));
            }
            if (!snapshot.hasData)
              return const Center(child: CircularProgressIndicator());
            final docs = snapshot.data!.docs;
            return ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: docs.isEmpty ? 1 : docs.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                if (docs.isEmpty)
                  return ClrsPanel(
                      child: Text(context.tr(
                          'Здесь появятся публикации, которыми вы поделились.')));
                final id = docs[index].data()['sharedPostId']?.toString() ??
                    docs[index].id;
                final commentId =
                    docs[index].data()['sharedCommentId']?.toString();
                return _WallPost(
                    key: ValueKey(docs[index].id),
                    postId: id,
                    commentId: commentId,
                    owner: widget.userUid == firebaseAuth.currentUser?.uid);
              },
            );
          },
        ),
      );
}

class _WallPost extends StatefulWidget {
  const _WallPost(
      {super.key, required this.postId, this.commentId, required this.owner});
  final String postId;
  final String? commentId;
  final bool owner;
  @override
  State<_WallPost> createState() => _WallPostState();
}

class _WallPostState extends State<_WallPost> {
  late final _post =
      firebaseFirestore.collection('posts').doc(widget.postId).snapshots();
  bool _removing = false;
  Future<void> _remove() async {
    if (_removing) return;
    setState(() => _removing = true);
    try {
      final social = SocialService();
      await (widget.commentId == null
              ? social.removeShare(widget.postId)
              : social.removeCommentShare(widget.postId, widget.commentId!))
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(context.tr(
                'Не удалось подтвердить удаление. Проверьте стену перед повтором.'))));
    } finally {
      if (mounted) setState(() => _removing = false);
    }
  }

  Widget _sharedComment(Map<String, dynamic> post) =>
      StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: firebaseFirestore
            .collection('posts')
            .doc(widget.postId)
            .collection('comments')
            .doc(widget.commentId)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Text(context.tr('Не удалось загрузить комментарии.'));
          }
          if (!snapshot.hasData) return const LinearProgressIndicator();
          final comment = snapshot.data!.data();
          if (comment == null) {
            return Text(context.tr('Комментарий недоступен'));
          }
          final parent = comment['parentId']?.toString() ?? '';
          final root = parent.isEmpty ? widget.commentId! : parent;
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(comment['authorName']?.toString() ?? '',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            if ((comment['text']?.toString() ?? '').isNotEmpty)
              TranslatableText(comment['text'].toString()),
            if ((comment['imageUrl']?.toString() ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: CachedNetworkImage(
                    imageUrl: comment['imageUrl'].toString(),
                    height: 180,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            TextButton.icon(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => PostDetailPage(
                      postId: widget.postId,
                      post: post,
                      threadRootId: root))),
              icon: const Icon(Icons.chat_bubble_outline, size: 18),
              label: Text(context.tr('Открыть ветку')),
            ),
          ]);
        },
      );

  @override
  Widget build(BuildContext context) =>
      StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: _post,
        builder: (context, snapshot) {
          final post = snapshot.data?.data();
          final available = post != null && post['status'] == 'published';
          return ClrsPanel(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Row(children: [
                  Expanded(
                      child: Text(context.tr(widget.commentId == null
                              ? 'Репост'
                              : 'Репост комментария'),
                          style: const TextStyle(
                              color: LrsTheme.peachLight, fontSize: 12))),
                  if (widget.owner)
                    IconButton(
                        tooltip: context.tr('Убрать со стены'),
                        onPressed: _removing ? null : _remove,
                        icon: _removing
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.close, size: 20)),
                ]),
                if (snapshot.hasError)
                  Text(context.tr('Не удалось загрузить публикацию.'))
                else if (!snapshot.hasData)
                  const LinearProgressIndicator()
                else if (!available)
                  Text(context.tr('Публикация удалена или недоступна.'))
                else ...[
                  Row(children: [
                    GroupAvatar(
                        url: post['authorPhoto']?.toString() ?? '',
                        group: post['authorGroup']?.toString() ?? '',
                        size: 36),
                    const SizedBox(width: 10),
                    Expanded(
                        child: Text(post['authorName']?.toString() ?? '',
                            style:
                                const TextStyle(fontWeight: FontWeight.w600))),
                  ]),
                  const SizedBox(height: 10),
                  if (widget.commentId != null)
                    _sharedComment(post),
                  if (widget.commentId == null &&
                      (post['text']?.toString() ?? '').isNotEmpty)
                    TranslatableText(post['text'].toString(),
                        showAction: false),
                  if (widget.commentId == null &&
                      (post['imageUrl']?.toString() ?? '').isNotEmpty)
                    Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: CachedNetworkImage(
                                imageUrl: post['imageUrl'].toString(),
                                errorWidget: (_, __, ___) =>
                                    const Icon(Icons.broken_image_outlined)))),
                  if (widget.commentId == null) TextButton.icon(
                      onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => PostDetailPage(
                                  postId: widget.postId, post: post))),
                      icon: const Icon(Icons.chat_bubble_outline, size: 18),
                      label: Text(context.tr('Комментарии'))),
                ],
              ]));
        },
      );
}
