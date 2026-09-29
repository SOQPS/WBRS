import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:wbrs/app/helper/global.dart';
import 'pending_write.dart';
import 'submission_journal.dart';

class MeetingWrite {
  MeetingWrite(
      {required this.id,
      required this.requestId,
      required this.fields,
      required this.write,
      this.deleting = false});
  final String id, requestId;
  final Map<String, dynamic> fields;
  final PendingWrite write;
  final bool deleting;
  Future<void>? acknowledgement;
}

/// Shared by routes in one process; the journal restores it after process death.
class MeetingWriteRegistry {
  final Map<String, MeetingWrite> requests = {};
  final Map<String, Future<MeetingWrite?>> preparing = {};
}

class MeetingWriteService {
  MeetingWriteService(
      {FirebaseFirestore? firestore,
      String? Function()? currentUid,
      SubmissionJournal? journal,
      MeetingWriteRegistry? registry})
      : _db = firestore ?? firebaseFirestore,
        _currentUid = currentUid ?? (() => firebaseAuth.currentUser?.uid),
        _journal = journal ?? SubmissionJournal(),
        _registry = registry ?? _shared {
    ownerUid = _currentUid();
  }
  final FirebaseFirestore _db;
  final String? Function() _currentUid;
  final SubmissionJournal _journal;
  final MeetingWriteRegistry _registry;
  static final _shared = MeetingWriteRegistry();
  late final String? ownerUid;
  bool get isCurrentSession => ownerUid != null && _currentUid() == ownerUid;
  String get _uid {
    if (!isCurrentSession) throw StateError('Сеанс завершён. Войдите снова');
    return ownerUid!;
  }

  String _scope(String? id) =>
      id == null ? 'meeting-create' : 'meeting-edit/$id';
  String _key(String? id) => '$ownerUid/${_scope(id)}';
  MeetingWrite? get pendingCreate => _registry.requests[_key(null)];
  MeetingWrite? pendingEdit(String id) => _registry.requests[_key(id)];

  Future<MeetingWrite?> restore({String? meetingId}) =>
      _prepare(meetingId, null);

  Future<MeetingWrite> create(Map<String, dynamic> fields) async {
    final uid = _uid;
    final individual = fields['type'] == 'индивидуальная';
    final invitedUid = fields['invitedUid']?.toString() ?? '';
    if (individual && (invitedUid.isEmpty || invitedUid == uid)) {
      throw StateError('Выберите получателя');
    }
    return (await _prepare(null, {
      'operation': 'create',
      'data': {
        ...editableFields(fields),
        'timeStamp': DateTime.now().toIso8601String(),
        'admin': uid,
        'type': fields['type'] ?? 'групповая',
        if (individual) 'invitedUid': invitedUid,
        if (individual) 'invitedName': fields['invitedName']?.toString() ?? '',
        if (individual) 'inviterName': fields['inviterName']?.toString() ?? '',
        'users': [uid],
        'recentMessage': '',
        'recentMessageSender': '',
      }
    }))!;
  }

  Future<MeetingWrite> edit(
      String id, String adminUid, Map<String, dynamic> fields) async {
    if (adminUid != _uid) {
      throw StateError('Изменять встречу может организатор');
    }
    return (await _prepare(id, {
      'operation': 'edit',
      'meetingId': id,
      'data': editableFields(fields)
    }))!;
  }

  Future<MeetingWrite> delete(String id, String adminUid) async {
    if (adminUid != _uid) throw StateError('Удалять встречу может организатор');
    return (await _prepare(id, {
      'operation': 'delete',
      'meetingId': id,
      'data': <String, dynamic>{}
    }))!;
  }

  Future<MeetingWrite?> _prepare(
      String? meetingId, Map<String, dynamic>? payload) {
    final uid = _uid;
    final key = _key(meetingId);
    final pending = _registry.requests[key];
    if (pending != null && !pending.write.failed) return Future.value(pending);
    final preparing = _registry.preparing[key];
    if (preparing != null) {
      return preparing.then((value) =>
          value ?? (payload == null ? null : _prepare(meetingId, payload)));
    }
    late final Future<MeetingWrite?> future;
    future = (() async {
      final scope = _scope(meetingId);
      var record = await _journal.load(uid, scope);
      _uid;
      if (record == null && payload == null) return null;
      // A settled rejection can accept corrected fields; its meeting identity
      // stays stable. A UI timeout never reaches this branch or replaces data.
      if (payload != null &&
          (record == null || pending?.write.failed == true)) {
        final previous = record?['fields'] as Map?;
        final stableId = meetingId ??
            previous?['meetingId']?.toString() ??
            _db.collection('meets').doc().id;
        record = await _journal.prepare(
            uid, scope, {...payload, 'meetingId': stableId}, null,
            replaceRejected: pending?.write.failed == true);
      }
      _uid;
      final envelope = Map<String, dynamic>.from(record!['fields'] as Map);
      final operation = envelope['operation'];
      final id = envelope['meetingId'] as String;
      if (!['create', 'edit', 'delete'].contains(operation) ||
          id.isEmpty ||
          id.contains('/')) {
        throw const FormatException('Invalid meeting request');
      }
      final data = Map<String, dynamic>.from(envelope['data'] as Map);
      if (operation == 'create') {
        data['timeStamp'] = DateTime.parse(data['timeStamp'] as String);
      }
      final requestId = record['id'] as String;
      final request = MeetingWrite(
          id: id,
          requestId: requestId,
          fields: Map.unmodifiable(data),
          deleting: operation == 'delete',
          write: PendingWrite(
              () => _apply(operation as String, id, requestId, data)));
      _registry.requests[key] = request;
      return request;
    })()
        .whenComplete(() {
      if (identical(_registry.preparing[key], future)) {
        _registry.preparing.remove(key);
      }
    });
    _registry.preparing[key] = future;
    return future;
  }

  Future<void> _apply(String operation, String id, String requestId,
      Map<String, dynamic> data) async {
    final uid = _uid;
    final ref = _db.collection('meets').doc(id);
    await _db.runTransaction((transaction) async {
      final snapshot = await transaction.get(ref);
      _uid;
      final current = snapshot.data();
      if (operation == 'create') {
        if (snapshot.exists) {
          if (current?['admin'] != uid) throw StateError('Встреча недоступна');
          // A previous create may already have committed and gained members or
          // messages. Never overwrite any part of that existing document.
          return;
        }
        final invitee = data['invitedUid']?.toString() ?? '';
        if (data['type'] == 'индивидуальная' && invitee.isNotEmpty) {
          final recipient =
              await transaction.get(_db.collection('users').doc(invitee));
          _uid;
          if (!recipient.exists ||
              recipient.data()?['status'] == 'blocked' ||
              recipient.data()?['status'] == 'deleted') {
            throw StateError('Получатель недоступен');
          }
        }
        transaction.set(ref, {...data, 'creationRequestId': requestId});
        if (invitee.isNotEmpty) {
          transaction.set(
              _db
                  .collection('users')
                  .doc(invitee)
                  .collection('notifications')
                  .doc('meeting_invite_$id'),
              {
                'type': 'meeting',
                'kind': 'invitation',
                'entityId': id,
                'actorName': data['inviterName'] ?? '',
                'title': 'Приглашение на личную встречу',
                'read': false,
                'createdAt': FieldValue.serverTimestamp(),
              });
        }
        return;
      }
      if (!snapshot.exists) {
        if (operation == 'delete') return;
        throw StateError('Встреча удалена. Изменения не применены.');
      }
      if (current?['admin'] != uid) {
        throw StateError('Изменять встречу может организатор');
      }
      if (operation == 'delete') {
        transaction.delete(ref);
        return;
      }
      final raw = current?['clientWriteReceipts'];
      final receipts =
          raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
      if (receipts[requestId] == true) return;
      transaction.update(ref, {
        ...editableFields(data),
        'clientWriteReceipts': {...receipts, requestId: true}
      });
    });
  }

  Future<void> acknowledge(MeetingWrite request, {required bool creating}) {
    final uid = _uid;
    if (!request.write.completed || request.write.failed) return Future.value();
    if (request.acknowledgement != null) return request.acknowledgement!;
    final key = _key(creating ? null : request.id);
    final future = (() async {
      await _journal.acknowledge(
          uid, _scope(creating ? null : request.id), request.requestId);
      _uid;
      if (identical(_registry.requests[key], request)) {
        _registry.requests.remove(key);
      }
    })();
    request.acknowledgement = future;
    return future.whenComplete(() => request.acknowledgement = null);
  }

  /// Membership, organizer, type and chat metadata are never editable here.
  static Map<String, dynamic> editableFields(Map<String, dynamic> fields) => {
        for (final key in const [
          'name',
          'city',
          'country',
          'countryCode',
          'region',
          'description',
          'datetime'
        ])
          if (fields.containsKey(key)) key: fields[key],
      };
}
