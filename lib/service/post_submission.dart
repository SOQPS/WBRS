import 'package:image_picker/image_picker.dart';
import 'package:wbrs/app/helper/global.dart';
import 'pending_write.dart';
import 'social_service.dart';
import 'submission_journal.dart';

class PostSubmission {
  PostSubmission(
      {required this.text, required this.image, required this.write});
  final String text;
  final XFile? image;
  final PendingWrite write;
}

class PostSubmissionService {
  PostSubmissionService(
      {required SocialService social,
      SubmissionJournal? journal,
      String? Function()? currentUid})
      : _social = social,
        _journal = journal ?? SubmissionJournal(),
        _currentUid = currentUid ?? (() => firebaseAuth.currentUser?.uid) {
    _ownerUid = _currentUid();
  }
  final SocialService _social;
  final SubmissionJournal _journal;
  final String? Function() _currentUid;
  late final String? _ownerUid;
  static final Map<String, PostSubmission> _pending = {};
  bool get isCurrentSession => _ownerUid != null && _currentUid() == _ownerUid;
  PostSubmission? get pending => _pending[_ownerUid];

  Future<PostSubmission?> restore() async {
    if (!isCurrentSession) return null;
    if (pending != null) return pending;
    final saved = await _journal.load(_ownerUid!, 'post');
    if (!isCurrentSession || saved == null) return null;
    return start(
        text: saved['fields']['text'] as String,
        image: saved['imagePath'] == null
            ? null
            : XFile(saved['imagePath'] as String));
  }

  PostSubmission start({required String text, XFile? image}) {
    if (!isCurrentSession) throw StateError('Сеанс завершён. Войдите снова.');
    final uid = _ownerUid!;
    final previous = pending;
    if (previous != null && !previous.write.failed) return previous;
    return _pending[uid] = PostSubmission(
        text: text,
        image: image,
        write: PendingWrite(() async {
          final prior = await _journal.load(uid, 'post');
          final replaceRejected = previous?.write.failed == true &&
              prior != null &&
              (prior['fields']['text'] != text ||
                  previous?.image?.path != image?.path);
          final saved = await _journal.prepare(
              uid, 'post', {'text': text}, image,
              replaceRejected: replaceRejected);
          if (!isCurrentSession)
            throw StateError('Сеанс завершён. Войдите снова.');
          await _social.createPost(
              text: saved['fields']['text'] as String,
              requestId: saved['id'] as String,
              image: saved['imagePath'] == null
                  ? null
                  : XFile(saved['imagePath'] as String));
          try {
            await _journal.acknowledge(uid, 'post', saved['id'] as String);
          } catch (_) {}
        }));
  }

  void acknowledge(PostSubmission request) {
    if (isCurrentSession &&
        request.write.completed &&
        !request.write.failed &&
        identical(pending, request)) _pending.remove(_ownerUid);
  }
}
