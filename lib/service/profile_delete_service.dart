import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:wbrs/app/helper/global.dart';

class ProfileDeletionIncomplete implements Exception {
  const ProfileDeletionIncomplete(this.cause);
  final Object cause;
}

/// Auth and Firestore cannot be deleted in a client-side atomic transaction.
/// Confirm eligibility first, then retain a tombstone if Auth deletion fails.
/// SessionGate treats `deleted` before onboarding, so a partial deletion cannot
/// recreate an empty account or expose the profile in active-user searches.
class ProfileDeleteService {
  ProfileDeleteService({FirebaseAuth? auth, FirebaseFirestore? firestore})
      : _auth = auth ?? firebaseAuth,
        _db = firestore ?? firebaseFirestore;
  final FirebaseAuth _auth;
  final FirebaseFirestore _db;
  Future<void> delete(String password) async {
    final user = _auth.currentUser;
    if (user == null || user.email == null || password.isEmpty) {
      throw StateError('Сеанс завершён');
    }
    await user.reauthenticateWithCredential(
        EmailAuthProvider.credential(email: user.email!, password: password));
    if (_auth.currentUser?.uid != user.uid) throw StateError('Сеанс изменился');
    final ref = _db.collection('users').doc(user.uid);
    await ref.update({
      'status': 'deleted',
      'deletionRequestedAt': FieldValue.serverTimestamp()
    });
    try {
      if (_auth.currentUser?.uid != user.uid) {
        throw StateError('Сеанс изменился');
      }
      await user.delete();
    } catch (error) {
      throw ProfileDeletionIncomplete(error);
    }
    // Storage/subcollections need trusted cleanup after Auth deletion. Client
    // deletion must not erase recoverable photos before Auth confirms success.
  }
}
