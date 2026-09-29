import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:wbrs/localization/clrs_localizations.dart';

// Enable only after the server triggers and compatible owner-write rules are
// live. The same rollout controls friend notices and their language metadata.
const serverSocialNoticesEnabled = bool.fromEnvironment(
  'CLRS_SERVER_SOCIAL_NOTICES',
  defaultValue: false,
);

/// Best-effort language metadata for a ready profile. Local language selection
/// and authentication never depend on this write completing successfully.
class PushLanguageSync {
  PushLanguageSync({
    required FirebaseFirestore firestore,
    required String? Function() currentUid,
    required String? Function() readyUid,
    required bool Function() isMounted,
    bool enabled = serverSocialNoticesEnabled,
  })  : _db = firestore,
        _currentUid = currentUid,
        _readyUid = readyUid,
        _isMounted = isMounted,
        _enabled = enabled;

  final FirebaseFirestore _db;
  final String? Function() _currentUid;
  final String? Function() _readyUid;
  final bool Function() _isMounted;
  final bool _enabled;
  Future<void> _tail = Future<void>.value();
  int _revision = 0;
  bool _disposed = false;

  bool _canWrite(String uid) =>
      !_disposed && _isMounted() && _currentUid() == uid && _readyUid() == uid;

  Future<void> sync(String language) {
    final revision = ++_revision;
    if (!_enabled || _disposed) return Future<void>.value();
    final uid = _currentUid();
    if (uid == null || uid.isEmpty || !_canWrite(uid)) {
      return Future<void>.value();
    }
    final code = ClrsLocalizations.normalizeCode(language);
    if (!ClrsLocalizations.codes.contains(code)) return Future<void>.value();
    _tail = _tail.then((_) async {
      // Earlier writes are allowed to settle; a timeout would not cancel them.
      // Skip superseded choices and recheck the captured account after waiting.
      if (revision != _revision || !_canWrite(uid)) return;
      // Update only: never create a partial user profile or replace its fields.
      await _db.collection('users').doc(uid).update({'language': code});
    }).catchError((Object _) {
      // Offline/denied metadata must not fail login or the saved local choice.
      // A later explicit language/session event may retry; no automatic loop.
    });
    return _tail;
  }

  void invalidate() => _revision++;

  void dispose() {
    _disposed = true;
    invalidate();
  }
}
