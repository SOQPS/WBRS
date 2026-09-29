import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:wbrs/firebase_options.dart';

/// The sandbox flavor uses a demo project with no live Firebase resources.
/// A mismatched flavor/define stops startup before any account data is read.
class AppBackend {
  static const useEmulators = bool.fromEnvironment('CLRS_USE_EMULATORS');
  static const emulatorHost = String.fromEnvironment(
    'CLRS_EMULATOR_HOST',
    defaultValue: '10.0.2.2',
  );
  static const demoProjectId = 'demo-clrs-local';
  static bool _emulatorsConfigured = false;
  static bool _firestoreConfigured = false;
  static bool _firestorePrepared = false;

  static const demoOptions = FirebaseOptions(
    apiKey: 'demo-clrs-local-api-key',
    appId: '1:123456789000:android:0000000000000000000000',
    messagingSenderId: '123456789000',
    projectId: demoProjectId,
    storageBucket: 'demo-clrs-local.appspot.com',
  );

  static void validateConfiguration({
    required bool emulatorMode,
    required String projectId,
    required String host,
  }) {
    if (emulatorMode != projectId.startsWith('demo-')) {
      throw StateError(
          'Firebase build configuration does not match its backend.');
    }
    if (emulatorMode &&
        (projectId != demoProjectId ||
            !const {'10.0.2.2', '127.0.0.1', 'localhost'}.contains(host))) {
      throw StateError('CLRS sandbox must use the local demo backend.');
    }
  }

  static Future<void> initialize() async {
    final app = Firebase.apps.isEmpty
        ? await Firebase.initializeApp(
            options: useEmulators
                ? demoOptions
                : DefaultFirebaseOptions.currentPlatform,
          )
        : Firebase.app();
    validateConfiguration(
      emulatorMode: useEmulators,
      projectId: app.options.projectId,
      host: emulatorHost,
    );
    final firestore = FirebaseFirestore.instance;
    if (!_firestoreConfigured) {
      // Settings must be applied before the first Firestore operation. In
      // particular, clearPersistence initializes the native client; putting
      // the emulator host after it would send sandbox reads to Google.
      firestore.settings = const Settings(persistenceEnabled: false);
      if (useEmulators) {
        firestore.useFirestoreEmulator(emulatorHost, 8080);
      }
      // A later startup retry must not apply settings to an initialized client.
      _firestoreConfigured = true;
    }
    if (!_firestorePrepared) {
      // A previous installation may contain documents belonging to another
      // account. Clear those documents before opening any Firestore stream.
      try {
        await firestore.clearPersistence();
      } on FirebaseException catch (error) {
        // A still-running native client cannot clear its old disk cache. Disk
        // persistence is disabled above, so no old document is served to the
        // app; do not make a transient startup retry permanently unusable.
        if (error.code != 'failed-precondition') rethrow;
      }
      _firestorePrepared = true;
    }
    if (!useEmulators || _emulatorsConfigured) return;
    await FirebaseAuth.instance.useAuthEmulator(emulatorHost, 9099);
    await FirebaseStorage.instance.useStorageEmulator(emulatorHost, 9199);
    _emulatorsConfigured = true;
  }
}
