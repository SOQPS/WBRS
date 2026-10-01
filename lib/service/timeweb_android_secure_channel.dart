import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'timeweb_android_secure_token_store.dart';

TimewebAndroidSecureTokenStore? _androidTimewebTokenStore;

/// Explicit future wiring only. No startup singleton/auth/UI activation here.
TimewebAndroidSecureTokenStore createAndroidTimewebTokenStore() {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
    throw UnsupportedError('Native Timeweb token store is Android-only.');
  }
  const channel = MethodChannel('com.lrs/timeweb_token_store_v1');
  // One guard per Dart isolate, plus the native process singleton. Replacing
  // an auth client must reuse this store and await the old client's close().
  return _androidTimewebTokenStore ??= TimewebAndroidSecureTokenStore(
    invoke: (method, arguments) =>
        channel.invokeMethod<Object?>(method, arguments),
  );
}
