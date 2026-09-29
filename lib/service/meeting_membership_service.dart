import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:wbrs/app/helper/global.dart';
import 'pending_write.dart';
import 'submission_journal.dart';

class MeetingMembershipRequest {
  MeetingMembershipRequest({required this.joined, required this.write});
  final bool joined;
  final PendingWrite write;
}

/// Desired membership, retained across routes and journaled before any write.
/// A receipt makes replay after a process restart idempotent, even if a later
/// action has changed membership again. Only the server transaction confirms it.
class MeetingMembershipService {
  MeetingMembershipService(
      {required this.meetingId,
      FirebaseFirestore? firestore,
      SubmissionJournal? journal,
      String? Function()? currentUid,
      String Function()? actorName})
      : _db = firestore ?? firebaseFirestore,
        _journal = journal ?? SubmissionJournal(),
        _currentUid = currentUid ?? (() => firebaseAuth.currentUser?.uid),
        _actorName =
            actorName ?? (() => firebaseAuth.currentUser?.displayName ?? '') {
    ownerUid = _currentUid();
  }
  final String meetingId;
  final FirebaseFirestore _db;
  final SubmissionJournal _journal;
  final String? Function() _currentUid;
  final String Function() _actorName;
  late final String? ownerUid;
  static final _requests = <String, MeetingMembershipRequest>{};
  String get _scope => 'membership/$meetingId';
  String get _key => '$ownerUid/$_scope';
  bool get isCurrentSession => ownerUid != null && _currentUid() == ownerUid;
  MeetingMembershipRequest? get pending => _requests[_key];
  void _check() {
    if (!isCurrentSession) throw StateError('Сеанс завершён. Войдите снова.');
  }

  Future<MeetingMembershipRequest?> restore() async {
    _check();
    if (pending != null) return pending;
    final saved = await _journal.load(ownerUid!, _scope);
    _check();
    return saved == null
        ? null
        : change(joined: saved['fields']['joined'] == true);
  }

  MeetingMembershipRequest change({required bool joined}) {
    _check();
    final previous = pending;
    if (previous != null && !previous.write.failed) return previous;
    final actor = _actorName();
    return _requests[_key] = MeetingMembershipRequest(
        joined: joined,
        write: PendingWrite(() async {
          final saved = await _journal.prepare(
              ownerUid!, _scope, {'joined': joined, 'actorName': actor}, null);
          _check();
          if (saved['fields']['joined'] != joined) {
            throw StateError('Сначала проверьте предыдущее изменение участия.');
          }
          await _apply(saved['id'] as String, joined,
              '${saved['fields']['actorName'] ?? ''}');
          // Server confirmation is authoritative; a local cleanup failure keeps
          // the same receipt available for harmless recovery on the next launch.
          try {
            await _journal.acknowledge(
                ownerUid!, _scope, saved['id'] as String);
          } catch (_) {}
        }));
  }

  Future<void> _apply(String requestId, bool joined, String actor) async {
    final ref = _db.collection('meets').doc(meetingId);
    final receipt = ref.collection('membership_requests').doc(requestId);
    // Copy to stable message IDs before leaving. Failure leaves membership
    // unchanged; replay can safely overwrite only the same archive documents.
    if (!joined) {
      final current = await ref.get();
      _check();
      if (current.exists &&
          (current.data()?['users'] as List? ?? []).contains(ownerUid)) {
        final messages = await ref.collection('messages').get();
        _check();
        for (var start = 0; start < messages.docs.length; start += 400) {
          final batch = _db.batch();
          for (final message in messages.docs.skip(start).take(400)) {
            batch.set(
                _db
                    .collection('users')
                    .doc(ownerUid)
                    .collection('removed_meets')
                    .doc(meetingId)
                    .collection('messages')
                    .doc(message.id),
                message.data());
          }
          _check();
          await batch.commit();
          _check();
        }
      }
    }
    await _db.runTransaction((tx) async {
      final applied = await tx.get(receipt);
      final meeting = await tx.get(ref);
      _check();
      if (applied.exists) return;
      final data = meeting.data();
      if (!meeting.exists || data == null) {
        throw StateError('Встреча недоступна');
      }
      if (joined && (data['kicked'] as List? ?? []).contains(ownerUid)) {
        throw StateError('Вы были исключены из встречи');
      }
      final invitedUid = data['invitedUid']?.toString() ?? '';
      if (joined &&
          invitedUid.isNotEmpty &&
          ownerUid != invitedUid &&
          ownerUid != data['admin']) {
        throw StateError('Встреча недоступна');
      }
      final members =
          (data['users'] as List? ?? []).whereType<String>().toSet();
      final changed =
          joined ? members.add(ownerUid!) : members.remove(ownerUid);
      if (changed) tx.update(ref, {'users': members.toList()});
      final organizer = '${data['admin'] ?? ''}';
      if (changed && joined && organizer.isNotEmpty && organizer != ownerUid) {
        tx.set(
            _db
                .collection('users')
                .doc(organizer)
                .collection('notifications')
                .doc('meeting_$requestId'),
            {
              'type': 'meeting',
              'entityId': meetingId,
              'actorName': actor,
              'title': 'Новый участник встречи',
              'body': '$actor присоединился к встрече «${data['name'] ?? ''}»',
              'read': false,
              'createdAt': FieldValue.serverTimestamp(),
            });
      }
      tx.set(receipt, {
        'uid': ownerUid,
        'joined': joined,
        'createdAt': FieldValue.serverTimestamp()
      });
    });
  }

  void acknowledge(MeetingMembershipRequest request) {
    _check();
    if (request.write.completed &&
        !request.write.failed &&
        identical(pending, request)) {
      _requests.remove(_key);
    }
  }
}
