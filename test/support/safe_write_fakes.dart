// Test doubles only: Firestore marks its concrete SDK boundaries sealed.
// ignore_for_file: subtype_of_sealed_class
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class SafeWriteStorage extends Fake implements FirebaseStorage {}

/// A controlled SDK boundary: no Firebase project, network, rules or real data.
class SafeWriteFirestore extends Fake implements FirebaseFirestore {
  final documents = <String, Map<String, dynamic>>{};
  final writes = <String>[];
  final batches = <List<String>>[];
  final streams =
      <String, StreamController<QuerySnapshot<Map<String, dynamic>>>>{};
  Completer<void>? gate;
  Object? error;
  int nextId = 0;

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      SafeCollection(this, path);
  @override
  WriteBatch batch() => SafeBatch(this);

  @override
  Future<T> runTransaction<T>(TransactionHandler<T> handler,
      {Duration timeout = const Duration(seconds: 30),
      int maxAttempts = 5}) async {
    final transaction = SafeTransaction(this);
    final result = await handler(transaction);
    writes.addAll(transaction.mutations.keys);
    if (transaction.mutations.isNotEmpty && gate != null) await gate!.future;
    if (error != null) throw error!;
    for (final action in transaction.mutations.values) {
      action();
    }
    return result;
  }

  Future<void> apply(String path, void Function() mutation) async {
    writes.add(path);
    if (gate != null) await gate!.future;
    if (error != null) throw error!;
    mutation();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> watch(String path) => streams
      .putIfAbsent(
          path,
          () =>
              StreamController<QuerySnapshot<Map<String, dynamic>>>.broadcast())
      .stream;
  void emit(String path) => streams[path]?.add(SafeQuerySnapshot([
        for (final entry in documents.entries
            .where((entry) => entry.key.startsWith('$path/')))
          SafeSnapshot(this, entry.key, entry.value),
      ]));
  Future<void> close() async {
    for (final stream in streams.values) {
      await stream.close();
    }
  }
}

class SafeCollection extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  SafeCollection(this.db, this.path);
  final SafeWriteFirestore db;
  @override
  final String path;
  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) =>
      SafeReference(db, '${this.path}/${path ?? 'auto-${db.nextId++}'}');
  @override
  Query<Map<String, dynamic>> orderBy(Object field,
          {bool descending = false}) =>
      this;
  @override
  Query<Map<String, dynamic>> limit(int limit) => this;
  @override
  Stream<QuerySnapshot<Map<String, dynamic>>> snapshots(
          {bool includeMetadataChanges = false,
          ListenSource source = ListenSource.defaultSource}) =>
      db.watch(path);
}

class SafeReference extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  SafeReference(this.db, this.path);
  final SafeWriteFirestore db;
  @override
  final String path;
  @override
  String get id => path.split('/').last;
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      SafeCollection(db, '${this.path}/$path');
  @override
  Future<void> set(Map<String, dynamic> data, [SetOptions? options]) =>
      db.apply(path, () => db.documents[path] = Map.from(data));
  @override
  Future<void> update(Map<Object, Object?> data) => db.apply(path, () {
        if (!db.documents.containsKey(path)) throw StateError('not-found');
        db.documents[path]!.addAll(data.cast<String, dynamic>());
      });
  @override
  Future<void> delete() => db.apply(path, () => db.documents.remove(path));
}

class SafeBatch extends Fake implements WriteBatch {
  SafeBatch(this.db);
  final SafeWriteFirestore db;
  final changes = <String, Map<String, dynamic>>{};
  @override
  void update(DocumentReference document, Map<String, dynamic> data) =>
      changes[document.path] = data;
  @override
  Future<void> commit() async {
    db.batches.add(changes.keys.toList());
    if (db.gate != null) await db.gate!.future;
    if (db.error != null) throw db.error!;
    if (changes.keys.any((path) => !db.documents.containsKey(path))) {
      throw StateError('not-found');
    }
    for (final entry in changes.entries) {
      db.documents[entry.key]!.addAll(entry.value);
    }
  }
}

class SafeSnapshot extends Fake
    implements QueryDocumentSnapshot<Map<String, dynamic>> {
  SafeSnapshot(this.db, this.path, this.value);
  final SafeWriteFirestore db;
  final String path;
  final Map<String, dynamic> value;
  @override
  String get id => path.split('/').last;
  @override
  Map<String, dynamic> data() => value;
  @override
  dynamic get(Object field) => value[field];
  @override
  DocumentReference<Map<String, dynamic>> get reference =>
      SafeReference(db, path);
}

class SafeQuerySnapshot extends Fake
    implements QuerySnapshot<Map<String, dynamic>> {
  SafeQuerySnapshot(this.docs);
  @override
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs;
}

class SafeDocumentSnapshot extends Fake
    implements DocumentSnapshot<Map<String, dynamic>> {
  SafeDocumentSnapshot(this.reference, this.value);
  @override
  final DocumentReference<Map<String, dynamic>> reference;
  final Map<String, dynamic>? value;
  @override
  bool get exists => value != null;
  @override
  Map<String, dynamic>? data() => value == null ? null : Map.from(value!);
}

class SafeTransaction extends Fake implements Transaction {
  SafeTransaction(this.db);
  final SafeWriteFirestore db;
  final mutations = <String, void Function()>{};
  @override
  Future<DocumentSnapshot<T>> get<T extends Object?>(
          DocumentReference<T> reference) async =>
      SafeDocumentSnapshot(reference as DocumentReference<Map<String, dynamic>>,
          db.documents[reference.path]) as DocumentSnapshot<T>;
  @override
  Transaction set<T>(DocumentReference<T> reference, T data,
      [SetOptions? options]) {
    mutations[reference.path] = () =>
        db.documents[reference.path] = Map<String, dynamic>.from(data as Map);
    return this;
  }

  @override
  Transaction update(DocumentReference reference, Map<String, dynamic> data) {
    mutations[reference.path] =
        () => db.documents[reference.path]!.addAll(data);
    return this;
  }

  @override
  Transaction delete(DocumentReference reference) {
    mutations[reference.path] = () => db.documents.remove(reference.path);
    return this;
  }
}
