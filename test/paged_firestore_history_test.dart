import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/shared/paged_firestore_history.dart';
import 'support/layout_firebase_fakes.dart';

void main() {
  late LayoutFirestore db;
  setUp(() => db = LayoutFirestore());
  tearDown(() => db.close());

  List<QueryDocumentSnapshot<Map<String, dynamic>>> docs(
          Iterable<String> ids) =>
      [
        for (final id in ids) LayoutSnapshot(db, 'history/$id', {'id': id})
      ];
  QuerySnapshot<Map<String, dynamic>> page(Iterable<String> ids) =>
      LayoutQuerySnapshot(docs(ids));

  test('cursor pages stay ordered, unique and gap-free as new items arrive',
      () {
    final history = PagedFirestoreHistory(3);
    history.receiveLive(page(['3', '2', '1', '0']));
    expect(history.documents.map((doc) => doc.id), ['3', '2', '1']);
    expect(history.cursor?.id, '1');
    expect(history.hasMore, isTrue);

    history.appendOlder(page(['0', '-1', '-2', '-3']));
    expect(history.documents.map((doc) => doc.id),
        ['3', '2', '1', '0', '-1', '-2']);
    expect(history.cursor?.id, '-2');

    history.receiveLive(page(['new', '3', '2', '1']));
    expect(history.documents.map((doc) => doc.id),
        ['new', '3', '2', '1', '0', '-1', '-2']);
    history.receiveLive(page(['newer', 'new', '3', '2']));
    expect(history.documents.map((doc) => doc.id),
        ['newer', 'new', '3', '2', '1', '0', '-1', '-2']);

    history.appendOlder(page(['-2', '-3']));
    expect(history.documents.map((doc) => doc.id),
        ['newer', 'new', '3', '2', '1', '0', '-1', '-2', '-3']);
    expect(history.hasMore, isFalse);
  });

  test('a deleted live item is not retained as a displaced message', () {
    final history = PagedFirestoreHistory(3);
    history.receiveLive(page(['3', '2', '1', '0']));
    history.receiveLive(page(['3', '1', '0']));
    expect(history.documents.map((doc) => doc.id), ['3', '1', '0']);
  });

  test('1000 document fake: cursor avoids repeated full-prefix reads',
      () async {
    db.serveEmittedQueries = true;
    db.emit('history', [
      for (var i = 0; i < 1000; i++) {'position': i}
    ]);
    final collection = db.collection('history');
    var expandedReads = 0;
    for (var limit = 61; limit < 1061; limit += 60) {
      final snapshot = await collection.limit(limit).get();
      expandedReads += snapshot.docs.length;
    }
    db.fetchedDocuments = 0;
    db.fetchedQueries = 0;

    DocumentSnapshot<Map<String, dynamic>>? cursor;
    var shown = 0;
    while (shown < 1000) {
      final query = cursor == null
          ? collection.limit(61)
          : collection.startAfterDocument(cursor).limit(61);
      final snapshot = await query.get();
      final visible = snapshot.docs.take(60).toList();
      shown += visible.length;
      cursor = visible.last;
    }
    expect(shown, 1000);
    expect(expandedReads, 9176);
    expect(db.fetchedDocuments, 1016);
    expect(db.fetchedQueries, 17);
    expect(expandedReads / db.fetchedDocuments, greaterThan(9));
  });
}
