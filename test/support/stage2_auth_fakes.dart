// Test-only controlled Firebase boundary; never connected to any project.
// ignore_for_file: subtype_of_sealed_class
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_test/flutter_test.dart';

class Stage2User extends Fake implements User {
  Stage2User(this.uid, this.email, {String name = ''}) : _name = name;
  @override
  final String uid;
  @override
  final String email;
  String _name;
  Object? nameError;
  int nameUpdates = 0;
  @override
  String get displayName => _name;
  @override
  Future<void> updateDisplayName(String? name) async {
    nameUpdates++;
    if (nameError != null) throw nameError!;
    _name = name ?? '';
  }
}

class Stage2Credential extends Fake implements UserCredential {
  Stage2Credential(this.user);
  @override
  final User user;
}

class Stage2Messaging extends Fake implements FirebaseMessaging {}

class Stage2Auth extends Fake implements FirebaseAuth {
  Stage2Auth({Map<String, Stage2User>? accounts}) : accounts = accounts ?? {};
  final Map<String, Stage2User> accounts;
  Stage2User? user;
  Completer<void>? loginGate, createGate;
  Object? nameError;
  int creates = 0, logins = 0, signOuts = 0;
  @override
  User? get currentUser => user;
  @override
  Future<UserCredential> signInWithEmailAndPassword(
      {required String email, required String password}) async {
    logins++;
    if (loginGate != null) await loginGate!.future;
    final found = accounts[email.toLowerCase()];
    if (found == null || password != 'correct-password') {
      throw FirebaseAuthException(code: 'invalid-credential');
    }
    user = found;
    return Stage2Credential(found);
  }

  @override
  Future<UserCredential> createUserWithEmailAndPassword(
      {required String email, required String password}) async {
    creates++;
    if (createGate != null) await createGate!.future;
    if (accounts.containsKey(email.toLowerCase())) {
      throw FirebaseAuthException(code: 'email-already-in-use');
    }
    final created = Stage2User('new-${accounts.length}', email)
      ..nameError = nameError;
    accounts[email.toLowerCase()] = created;
    user = created;
    return Stage2Credential(created);
  }

  @override
  Future<void> signOut() async {
    signOuts++;
    user = null;
  }
}

class Stage2Database extends Fake implements FirebaseFirestore {
  final documents = <String, Map<String, dynamic>>{};
  final reads = <String>[];
  final sources = <Source?>[];
  int commits = 0;
  Completer<void>? readGate, transactionGate;
  Object? transactionError, readError;
  void Function()? afterTransactionRead;
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      Stage2Collection(this, path);
  @override
  Future<T> runTransaction<T>(
    TransactionHandler<T> transactionHandler, {
    Duration timeout = const Duration(seconds: 30),
    int maxAttempts = 5,
  }) async {
    final transaction = Stage2Transaction(this);
    final result = await transactionHandler(transaction);
    if (transactionGate != null) await transactionGate!.future;
    if (transactionError != null) throw transactionError!;
    for (final operation in transaction.operations) {
      operation();
    }
    commits++;
    return result;
  }
}

class Stage2Collection extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  Stage2Collection(this.db, this.path);
  final Stage2Database db;
  @override
  final String path;
  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) =>
      Stage2Reference(db, '${this.path}/${path ?? 'auto'}');
}

class Stage2Reference extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  Stage2Reference(this.db, this.path);
  final Stage2Database db;
  @override
  final String path;
  @override
  String get id => path.split('/').last;
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      Stage2Collection(db, '${this.path}/$path');
  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get(
      [GetOptions? options]) async {
    db.reads.add(path);
    db.sources.add(options?.source);
    if (db.readGate != null) await db.readGate!.future;
    if (db.readError != null) throw db.readError!;
    return Stage2Snapshot(this, db.documents[path]);
  }
}

class Stage2Snapshot extends Fake
    implements DocumentSnapshot<Map<String, dynamic>> {
  Stage2Snapshot(this.reference, Map<String, dynamic>? data)
      : value = data == null ? null : Map.from(data);
  final Map<String, dynamic>? value;
  @override
  final DocumentReference<Map<String, dynamic>> reference;
  @override
  bool get exists => value != null;
  @override
  String get id => reference.id;
  @override
  Map<String, dynamic>? data() => value;
}

class Stage2Transaction extends Fake implements Transaction {
  Stage2Transaction(this.db);
  final Stage2Database db;
  final operations = <void Function()>[];
  @override
  Future<DocumentSnapshot<T>> get<T extends Object?>(
      DocumentReference<T> reference) async {
    final value = Stage2Snapshot(
        reference as DocumentReference<Map<String, dynamic>>,
        db.documents[reference.path]);
    db.afterTransactionRead?.call();
    return value as DocumentSnapshot<T>;
  }

  @override
  Transaction set<T>(DocumentReference<T> reference, T data,
      [SetOptions? options]) {
    operations.add(() =>
        db.documents[reference.path] = Map<String, dynamic>.from(data as Map));
    return this;
  }

  @override
  Transaction update(DocumentReference reference, Map<String, dynamic> data) {
    operations.add(() => db.documents[reference.path]!.addAll(data));
    return this;
  }
}
