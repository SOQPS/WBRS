import 'package:wbrs/shared/translatable_text.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/shared/group_avatar.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:wbrs/app/widgets/widgets.dart';
import 'package:wbrs/service/social_service.dart';
import 'package:wbrs/service/comment_submission.dart';
import 'package:wbrs/service/pending_write.dart';
import 'package:wbrs/presentation/screens/feed/share_to_chat_sheet.dart';
import 'package:wbrs/shared/lrs_theme.dart';

class PostDetailPage extends StatefulWidget {
  const PostDetailPage(
      {super.key,
      required this.postId,
      required this.post,
      this.social,
      this.submissions,
      this.threadRootId});

  final String postId;
  final String? threadRootId;
  final Map<String, dynamic> post;
  final SocialService? social;
  final CommentSubmissionService? submissions;

  @override
  State<PostDetailPage> createState() => _PostDetailPageState();
}

class _PostDetailPageState extends State<PostDetailPage> {
  late SocialService _social;
  late Stream<QuerySnapshot<Map<String, dynamic>>> _comments;
  late final CommentSubmissionService _submissions;
  CommentSubmission? _submission;
  String? _sendNotice;
  bool _restoring = true;
  bool get _locked => _restoring || _submission != null;
  final TextEditingController _comment = TextEditingController();
  final ImagePicker _picker = ImagePicker();
  XFile? _image;
  String? _replyTo;
  String? _replyName;
  bool _sending = false;
  final Set<String> _expandedThreads = {};
  final Set<String> _liking = {};
  final Map<String, PendingWrite> _likeWrites = {};
  final Set<String> _sharing = {};
  final Map<String, PendingWrite> _shareWrites = {};

  Future<void> _shareComment(String commentId) async {
    if (_sharing.contains(commentId)) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: LrsTheme.surface,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: Text(context.tr('На моей странице')),
            onTap: () => Navigator.pop(context, 'wall'),
          ),
          ListTile(
            leading: const Icon(Icons.chat_bubble_outline),
            title: Text(context.tr('Отправить в чат')),
            onTap: () => Navigator.pop(context, 'chat'),
          ),
        ]),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'chat') {
      await showShareToChatSheet(context,
          postId: widget.postId, commentId: commentId, social: _social);
      return;
    }
    await _shareCommentToWall(commentId);
  }

  Future<void> _shareCommentToWall(String commentId) async {
    if (!_sharing.add(commentId)) return;
    setState(() {});
    try {
      final operation = _shareWrites.putIfAbsent(commentId,
          () => PendingWrite(() => _social.shareComment(widget.postId, commentId)));
      final confirmed = await operation.wait();
      if (!mounted) return;
      if (confirmed) {
        _shareWrites.remove(commentId);
        showSnackbar(context, LrsTheme.surface,
            context.tr('Комментарий добавлен на вашу страницу'));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(context.tr(
              'Подтверждение ещё не получено. Проверьте результат без повторной отправки.')),
          action: SnackBarAction(
              label: context.tr('Проверить отправку'),
              onPressed: () => _shareCommentToWall(commentId)),
        ));
      }
    } catch (_) {
      _shareWrites.remove(commentId);
      if (mounted) {
        showSnackbar(context, LrsTheme.danger,
            context.tr('Не удалось поделиться публикацией. Попробуйте ещё раз.'));
      }
    } finally {
      if (mounted) setState(() => _sharing.remove(commentId));
    }
  }

  @override
  void initState() {
    super.initState();
    _social = widget.social ?? SocialService();
    _comments = _loadComments();
    _submissions =
        widget.submissions ?? CommentSubmissionService(social: _social);
    _replyTo = widget.threadRootId;
    if (widget.threadRootId != null) _expandedThreads.add(widget.threadRootId!);
    _submission = _submissions.pending(widget.postId);
    _restoreSubmission();
    if (_submission?.write.failed == true) _submission = null;
    if (_submission != null) {
      _comment.text = _submission!.text;
      _replyTo = _submission!.parentId;
      _replyName = _submission!.replyName;
      _image = _submission!.image;
      _sendNotice =
          'Предыдущая отправка ожидает подтверждения. Проверьте результат.';
    }
  }

  Future<void> _restoreSubmission() async {
    try {
      final restored = await _submissions.restore(widget.postId);
      if (!mounted || !_submissions.isCurrentSession) return;
      if (restored != null)
        setState(() {
          _submission = restored;
          _comment.text = restored.text;
          _replyTo = restored.parentId;
          _replyName = restored.replyName;
          _image = restored.image;
          _sendNotice =
              'Предыдущая отправка ожидает подтверждения. Проверьте результат.';
        });
    } catch (_) {
      if (mounted)
        setState(() => _sendNotice =
            'Не удалось восстановить отправку. Попробуйте ещё раз.');
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _loadComments() {
    try {
      return _social.comments(widget.postId);
    } catch (error, stack) {
      return Stream.error(error, stack);
    }
  }

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClrsScaffold(
      backgroundColor: LrsTheme.background,
      appBar: AppBar(
          title: Text(context.tr(widget.threadRootId == null
              ? 'Комментарии'
              : 'Ветка комментариев'))),
      body: LayoutBuilder(
          builder: (context, constraints) => Column(
                children: [
                  Expanded(
                    child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      stream: _comments,
                      builder: (context, snapshot) {
                        if (snapshot.connectionState ==
                            ConnectionState.waiting) {
                          return Center(child: CircularProgressIndicator());
                        }
                        if (snapshot.hasError)
                          return Center(
                              child: SingleChildScrollView(
                                  padding: EdgeInsets.all(16),
                                  child: ClrsPanel(
                                      child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                        Text(context.tr(
                                            'Не удалось загрузить комментарии.')),
                                        TextButton(
                                            onPressed: () => setState(() {
                                                  _comments = _loadComments();
                                                }),
                                            child:
                                                Text(context.tr('Повторить'))),
                                      ]))));
                        final docs = snapshot.data?.docs ?? [];
                        final roots = docs.where((doc) {
                          final parent = doc.data()['parentId'];
                          return widget.threadRootId != null
                              ? doc.id == widget.threadRootId
                              : parent == null || parent.toString().isEmpty;
                        }).toList();
                        return ListView(
                          padding: EdgeInsets.fromLTRB(12, 12, 12, 18),
                          children: [
                            ClrsBrandHeader(),
                            if (widget.threadRootId == null) _postHeader(),
                            SizedBox(height: 14),
                            Text(
                              context.tr('Обсуждение'),
                              style: TextStyle(
                                color: LrsTheme.text,
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            SizedBox(height: 8),
                            if (roots.isEmpty)
                              Padding(
                                padding: EdgeInsets.all(18),
                                child: Text(
                                  context.tr(
                                      'Пока нет комментариев. Начните обсуждение.'),
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: LrsTheme.muted),
                                ),
                              ),
                            for (final root in roots) ...[
                              _commentTile(root, isReply: false),
                              if (widget.threadRootId == null)
                                Align(
                                    alignment: Alignment.centerLeft,
                                    child: TextButton.icon(
                                        icon: Icon(Icons.forum_outlined,
                                            size: 18),
                                        label:
                                            Text(context.tr('Открыть ветку')),
                                        onPressed: () => Navigator.of(context)
                                            .push(MaterialPageRoute(
                                                builder: (_) => PostDetailPage(
                                                    postId: widget.postId,
                                                    post: widget.post,
                                                    social: _social,
                                                    submissions: _submissions,
                                                    threadRootId: root.id))))),
                              if (docs.any((doc) =>
                                  doc.data()['parentId']?.toString() ==
                                  root.id))
                                Align(
                                    alignment: Alignment.centerLeft,
                                    child: TextButton.icon(
                                        icon: Icon(
                                            _expandedThreads.contains(root.id)
                                                ? Icons.expand_less
                                                : Icons.expand_more),
                                        label: Text(context.tr(
                                            _expandedThreads.contains(root.id)
                                                ? 'Скрыть ответы'
                                                : 'Показать ответы')),
                                        onPressed: () => setState(() {
                                              if (!_expandedThreads
                                                  .add(root.id))
                                                _expandedThreads
                                                    .remove(root.id);
                                            }))),
                              if (_expandedThreads.contains(root.id))
                                for (final reply in docs.where(
                                  (doc) =>
                                      doc.data()['parentId']?.toString() ==
                                      root.id,
                                ))
                                  Padding(
                                    padding: EdgeInsets.only(left: 18),
                                    child: _commentTile(reply, isReply: true),
                                  ),
                            ],
                          ],
                        );
                      },
                    ),
                  ),
                  ConstrainedBox(
                      constraints: BoxConstraints(
                          maxHeight: constraints.maxHeight * .55),
                      child: SingleChildScrollView(child: _composer())),
                ],
              )),
    );
  }

  Widget _postHeader() {
    final image = widget.post['imageUrl']?.toString() ?? '';
    final text = widget.post['text']?.toString() ?? '';
    return Container(
      padding: EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Color(0x8031241D),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.post['authorName']?.toString() ?? 'CLRS',
            style: TextStyle(
                color: LrsTheme.peachLight, fontWeight: FontWeight.w800),
          ),
          if (text.isNotEmpty) ...[
            SizedBox(height: 8),
            TranslatableText(text,
                style: TextStyle(color: LrsTheme.text, height: 1.35)),
          ],
          if (image.isNotEmpty) ...[
            SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: CachedNetworkImage(imageUrl: image, fit: BoxFit.cover),
            ),
          ],
        ],
      ),
    );
  }

  Widget _commentTile(
    QueryDocumentSnapshot<Map<String, dynamic>> doc, {
    required bool isReply,
  }) {
    final data = doc.data();
    final image = data['imageUrl']?.toString() ?? '';
    final photo = data['authorPhoto']?.toString() ?? '';
    return Container(
      margin: EdgeInsets.only(bottom: 8),
      padding: EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Color(0x8031241D),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Color(0x22E7B092)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GroupAvatar(
              url: photo,
              group: data['authorGroup']?.toString() ?? '',
              size: 38),
          SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  data['authorName']?.toString() ?? context.tr('Пользователь'),
                  style: TextStyle(
                      color: LrsTheme.peachLight, fontWeight: FontWeight.w700),
                ),
                if ((data['text']?.toString() ?? '').isNotEmpty)
                  TranslatableText(data['text'].toString(),
                      style: TextStyle(color: LrsTheme.text)),
                if (image.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: CachedNetworkImage(
                        imageUrl: image,
                        height: 150,
                        width: 190,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                Wrap(
                  children: [
                    TextButton.icon(
                      onPressed: _liking.contains(doc.id)
                          ? null
                          : () => _toggleLike(doc.id),
                      icon: Icon(Icons.favorite_border, size: 16),
                      label: Text('${data['likeCount'] ?? 0}'),
                    ),
                    TextButton(
                      onPressed: _locked
                          ? null
                          : () {
                              setState(() {
                                _replyTo = isReply
                                    ? data['parentId']?.toString()
                                    : doc.id;
                                _replyName = data['authorName']?.toString();
                              });
                            },
                      child: Text(context.tr('Ответить')),
                    ),
                    TextButton.icon(
                      onPressed: _sharing.contains(doc.id)
                          ? null
                          : () => _shareComment(doc.id),
                      icon: const Icon(Icons.share_outlined, size: 16),
                      label: Text(context.tr('Поделиться')),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _composer() {
    return SafeArea(
      top: false,
      child: Container(
        padding: EdgeInsets.fromLTRB(10, 7, 10, 8),
        decoration: BoxDecoration(
          color: LrsTheme.surface,
          border: Border(top: BorderSide(color: Color(0x22FFFFFF))),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_replyTo != null && widget.threadRootId == null)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      context.tr('Ответ для {name}', args: {
                        'name': _replyName ?? context.tr('Пользователь')
                      }),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(color: LrsTheme.peachLight, fontSize: 11),
                    ),
                  ),
                  IconButton(
                    tooltip: context.tr('Отменить ответ'),
                    visualDensity: VisualDensity.compact,
                    onPressed: _locked
                        ? null
                        : () => setState(() {
                              _replyTo = null;
                              _replyName = null;
                            }),
                    icon: Icon(Icons.close, size: 18),
                  ),
                ],
              ),
            if (_image != null)
              Row(
                children: [
                  Icon(Icons.image, color: LrsTheme.peach, size: 18),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _image!.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: LrsTheme.muted, fontSize: 11),
                    ),
                  ),
                  IconButton(
                    tooltip: context.tr('Убрать изображение'),
                    visualDensity: VisualDensity.compact,
                    onPressed:
                        _locked ? null : () => setState(() => _image = null),
                    icon: Icon(Icons.close, size: 18),
                  ),
                ],
              ),
            Row(
              children: [
                IconButton(
                  tooltip: context.tr('Добавить изображение'),
                  onPressed: _locked
                      ? null
                      : () async {
                          try {
                            final image = await _picker.pickImage(
                              source: ImageSource.gallery,
                              imageQuality: 68,
                              maxWidth: 1400,
                              maxHeight: 1400,
                            );
                            if (mounted && image != null)
                              setState(() => _image = image);
                          } catch (_) {
                            if (mounted)
                              showSnackbar(
                                  context,
                                  LrsTheme.danger,
                                  context.tr(
                                      'Не удалось открыть изображение. Попробуйте ещё раз.'));
                          }
                        },
                  icon: Icon(Icons.add_photo_alternate_outlined,
                      color: LrsTheme.peach),
                ),
                Expanded(
                  child: TextField(
                    controller: _comment,
                    readOnly: _locked,
                    maxLines: 4,
                    minLines: 1,
                    style: TextStyle(color: LrsTheme.text),
                    decoration:
                        InputDecoration(hintText: context.tr('Комментарий')),
                  ),
                ),
                IconButton(
                  tooltip: context.tr(
                      _locked ? 'Проверить отправку' : 'Отправить комментарий'),
                  onPressed: _sending ? null : _send,
                  icon: _sending
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(_locked ? Icons.refresh : Icons.send,
                          color: LrsTheme.peach),
                ),
              ],
            ),
            if (_restoring) LinearProgressIndicator(),
            if (_sendNotice != null)
              Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(context.tr(_sendNotice!),
                      style: TextStyle(color: LrsTheme.peachLight))),
          ],
        ),
      ),
    );
  }

  Future<void> _send() async {
    if (_restoring ||
        _sending ||
        (_comment.text.trim().isEmpty && _image == null)) return;
    setState(() {
      _sending = true;
      _sendNotice = null;
    });
    try {
      if (_submission?.write.failed == true) _submission = null;
      _submission ??= _submissions.start(
        postId: widget.postId,
        text: _comment.text,
        parentId: _replyTo,
        replyName: _replyName,
        image: _image,
      );
      final confirmed = await _submission!.write.wait();
      if (mounted) {
        if (!_submissions.isCurrentSession) {
          setState(() => _sendNotice =
              'Сеанс изменился. Проверьте отправку после входа в исходный аккаунт.');
          return;
        }
        if (!confirmed) {
          setState(() => _sendNotice =
              'Подтверждение ещё не получено. Комментарий может быть отправлен. Нажмите «Проверить отправку».');
          return;
        }
        final parentId = _submission!.parentId;
        _submissions.acknowledge(widget.postId, _submission!);
        _comment.clear();
        setState(() {
          _submission = null;
          if (parentId != null) _expandedThreads.add(parentId);
          _image = null;
          _replyTo = widget.threadRootId;
          _replyName = null;
        });
        showSnackbar(
            context,
            LrsTheme.surface,
            context.tr(parentId == null
                ? 'Комментарий отправлен'
                : 'Ответ отправлен. Ветка ответов раскрыта.'));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _submission = null);
        showSnackbar(
            context,
            LrsTheme.danger,
            context
                .tr('Не удалось отправить комментарий. Попробуйте ещё раз.'));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _toggleLike(String commentId) async {
    if (!_social.isCurrentSession) return;
    if (!_liking.add(commentId)) return;
    setState(() {});
    try {
      final operation = _likeWrites.putIfAbsent(commentId,
          () => PendingWrite(() => _social.toggleCommentLike(widget.postId, commentId)));
      final confirmed = await operation.wait();
      if (!mounted || !_social.isCurrentSession) return;
      if (confirmed) {
        _likeWrites.remove(commentId);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(context.tr(
              'Подтверждение ещё не получено. Проверьте результат без повторной отправки.')),
          action: SnackBarAction(
              label: context.tr('Проверить результат'),
              onPressed: () => _toggleLike(commentId)),
        ));
      }
    } catch (_) {
      _likeWrites.remove(commentId);
      if (mounted && _social.isCurrentSession)
        showSnackbar(context, LrsTheme.danger,
            context.tr('Не удалось сохранить реакцию. Попробуйте ещё раз.'));
    } finally {
      if (mounted) setState(() => _liking.remove(commentId));
    }
  }
}
