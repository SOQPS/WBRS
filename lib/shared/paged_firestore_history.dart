import 'package:cloud_firestore/cloud_firestore.dart';

/// Keeps the live newest page and one-time older pages in Firestore order.
/// New items can displace the tail of the live query; retain that tail so a
/// cursor fetch never leaves a gap between the live and older pages.
class PagedFirestoreHistory {
  PagedFirestoreHistory(this.pageSize);

  final int pageSize;
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _live = [];
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> _older = [];
  bool _fetchedOlder = false;
  bool _hasMore = false;

  bool get hasMore => _hasMore;

  DocumentSnapshot<Map<String, dynamic>>? get cursor =>
      _older.isNotEmpty ? _older.last : (_live.isNotEmpty ? _live.last : null);

  List<QueryDocumentSnapshot<Map<String, dynamic>>> get documents {
    final ids = <String>{};
    return [
      for (final doc in [..._live, ..._older])
        if (ids.add(doc.id)) doc,
    ];
  }

  void reset() {
    _live = [];
    _older.clear();
    _fetchedOlder = false;
    _hasMore = false;
  }

  void receiveLive(QuerySnapshot<Map<String, dynamic>> snapshot) {
    final next = snapshot.docs.take(pageSize).toList(growable: false);
    if (_live.isNotEmpty) {
      final priorIds = _live.map((doc) => doc.id).toSet();
      final nextIds = next.map((doc) => doc.id).toSet();
      final firstNew = next.indexWhere((doc) => !priorIds.contains(doc.id));
      final lastDropped =
          _live.lastIndexWhere((doc) => !nextIds.contains(doc.id));
      // A new item before the dropped tail shifted old messages out of the
      // live window. A deletion instead fills from the end and is not kept.
      if (firstNew >= 0 && firstNew < lastDropped) {
        final olderIds = _older.map((doc) => doc.id).toSet();
        _older.insertAll(0, [
          for (final doc in _live)
            if (!nextIds.contains(doc.id) && olderIds.add(doc.id)) doc,
        ]);
      }
    }
    _live = next;
    if (!_fetchedOlder) _hasMore = snapshot.docs.length > pageSize;
  }

  void appendOlder(QuerySnapshot<Map<String, dynamic>> snapshot) {
    final ids = documents.map((doc) => doc.id).toSet();
    _older.addAll([
      for (final doc in snapshot.docs.take(pageSize))
        if (ids.add(doc.id)) doc,
    ]);
    _fetchedOlder = true;
    _hasMore = snapshot.docs.length > pageSize;
  }
}
