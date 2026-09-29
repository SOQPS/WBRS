import 'dart:async';

/// Tracks the original SDK future. A UI timeout never starts another write or
/// pretends to cancel a Firestore operation that may still reach the server.
class PendingWrite {
  PendingWrite(Future<void> Function() write) {
    _completion = Future<void>.sync(write).then((_) {
      completed = true;
    }, onError: (Object error, StackTrace stack) {
      completed = true;
      _error = error;
      _stack = stack;
    });
  }

  late final Future<void> _completion;
  bool completed = false;
  Object? _error;
  StackTrace? _stack;
  bool get failed => completed && _error != null;

  /// False means the outcome is still unknown; the original write stays alive.
  Future<bool> wait({Duration timeout = const Duration(seconds: 15)}) async {
    try {
      await _completion.timeout(timeout);
    } on TimeoutException {
      return false;
    }
    if (_error != null) Error.throwWithStackTrace(_error!, _stack!);
    return true;
  }
}
