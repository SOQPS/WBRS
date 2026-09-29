import 'package:cloud_firestore/cloud_firestore.dart';

/// Older profiles and purchases used different spellings of the visibility
/// flag. Read both without changing the purchase or balance transaction.
bool isInvisibleActive(Map<String, dynamic> profile, {DateTime? now}) {
  if (profile['isUnVisible'] != true && profile['isUnvisible'] != true) {
    return false;
  }
  final end = invisiblePeriodEnd(profile);
  // Legacy paid periods have no expiration metadata; do not make them visible
  // merely because a newer field is absent.
  return end == null || end.isAfter(now ?? DateTime.now());
}

DateTime? invisiblePeriodEnd(Map<String, dynamic> profile) {
  return switch (profile['unvisibleEnd']) {
    Timestamp value => value.toDate(),
    DateTime value => value,
    String value => DateTime.tryParse(value),
    _ => null,
  };
}
