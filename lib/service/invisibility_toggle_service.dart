import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:wbrs/app/helper/global.dart';
import 'invisibility_state.dart';

/// Pauses/resumes an already purchased invisibility period. It never changes
/// balance or extends the paid deadline.
class InvisibilityToggleService {
  InvisibilityToggleService({
    FirebaseFirestore? firestore,
    String? Function()? currentUid,
    DateTime Function()? now,
  })  : _db = firestore ?? firebaseFirestore,
        _currentUid = currentUid ?? (() => firebaseAuth.currentUser?.uid),
        _now = now ?? DateTime.now;

  final FirebaseFirestore _db;
  final String? Function() _currentUid;
  final DateTime Function() _now;

  Future<void> setActive(bool active) async {
    final uid = _currentUid();
    if (uid == null) throw StateError('Сеанс завершён. Войдите снова.');
    final ref = _db.collection('users').doc(uid);
    await _db.runTransaction((tx) async {
      final snapshot = await tx.get(ref);
      if (_currentUid() != uid) {
        throw StateError('Сеанс завершён. Войдите снова.');
      }
      final profile = snapshot.data() ?? const <String, dynamic>{};
      final end = invisiblePeriodEnd(profile);
      if (end == null || !end.isAfter(_now())) {
        throw StateError('Срок режима невидимки истёк.');
      }
      if (profile['isUnVisible'] == active &&
          profile['isUnvisible'] == active) {
        return;
      }
      tx.update(ref, {
        // The older UI and purchase code read/write both spellings.
        'isUnVisible': active,
        'isUnvisible': active,
      });
    });
  }
}
