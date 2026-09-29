import 'package:image_picker/image_picker.dart';
import 'package:wbrs/app/helper/global.dart';
import 'pending_write.dart';
import 'social_service.dart';
import 'submission_journal.dart';

class CommentSubmission {
  CommentSubmission(
      {required this.text,
      this.parentId,
      this.replyName,
      this.image,
      required this.write});
  final String text;
  final String? parentId, replyName;
  final XFile? image;
  final PendingWrite write;
}

class CommentSubmissionService {
  CommentSubmissionService(
      {required SocialService social,
      String? Function()? currentUid,
      SubmissionJournal? journal})
      : _social = social,
        _journal = journal ?? SubmissionJournal(),
        _currentUid = currentUid ?? (() => firebaseAuth.currentUser?.uid) {
    _ownerUid = _currentUid();
  }
  final SocialService _social;
  final SubmissionJournal _journal;
  final String? Function() _currentUid;
  late final String? _ownerUid;
  static final Map<String, CommentSubmission> _pending = {};
  bool get isCurrentSession => _ownerUid != null && _currentUid() == _ownerUid;
  String _key(String postId) => '$_ownerUid/$postId';
  String _scope(String postId) => 'comment/$postId';
  CommentSubmission? pending(String postId) => _pending[_key(postId)];

  Future<CommentSubmission?> restore(String postId) async {
    if (!isCurrentSession) return null;
    if (pending(postId) != null) return pending(postId);
    final saved = await _journal.load(_ownerUid!, _scope(postId));
    if (!isCurrentSession || saved == null) return null;
    final fields = Map<String, dynamic>.from(saved['fields'] as Map);
    return start(
        postId: postId,
        text: fields['text'] as String,
        parentId: fields['parentId'] as String?,
        replyName: fields['replyName'] as String?,
        image: saved['imagePath'] == null
            ? null
            : XFile(saved['imagePath'] as String));
  }

  CommentSubmission start(
      {required String postId,
      required String text,
      String? parentId,
      String? replyName,
      XFile? image}) {
    if (!isCurrentSession) throw StateError('Сеанс завершён. Войдите снова.');
    final uid = _ownerUid!;
    final key = _key(postId);
    final previous = _pending[key];
    if (previous != null && !previous.write.failed) return previous;
    return _pending[key] = CommentSubmission(
        text: text,
        parentId: parentId,
        replyName: replyName,
        image: image,
        write: PendingWrite(() async {
          final scope = _scope(postId);
          final prior = await _journal.load(uid, scope);
          // A completed SDK failure is definitive; a UI timeout is not. Only the
          // former permits editing a rejected request and replacing its journal.
          final replaceRejected = previous?.write.failed == true &&
              prior != null &&
              (prior['fields']['text'] != text ||
                  prior['fields']['parentId'] != parentId ||
                  previous?.image?.path != image?.path);
          final saved = await _journal.prepare(
              uid,
              scope,
              {'text': text, 'parentId': parentId, 'replyName': replyName},
              image,
              replaceRejected: replaceRejected);
          if (!isCurrentSession)
            throw StateError('Сеанс завершён. Войдите снова.');
          final fields = saved['fields'] as Map;
          await _social.addComment(
              postId: postId,
              text: fields['text'] as String,
              parentId: fields['parentId'] as String?,
              requestId: saved['id'] as String,
              image: saved['imagePath'] == null
                  ? null
                  : XFile(saved['imagePath'] as String));
          // An inability to clean up a local record cannot undo a server commit.
          // On reopening, the same ID is reconciled without a duplicate comment.
          try {
            await _journal.acknowledge(uid, scope, saved['id'] as String);
          } catch (_) {}
        }));
  }

  void acknowledge(String postId, CommentSubmission request) {
    if (!isCurrentSession || !request.write.completed || request.write.failed)
      return;
    final key = _key(postId);
    if (identical(_pending[key], request)) _pending.remove(key);
  }
}
