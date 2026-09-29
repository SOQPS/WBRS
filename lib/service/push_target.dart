import 'dart:convert';

/// A push may outlive the account that received it. Resolve its destination
/// against current server data before displaying or opening it.
class PushTarget {
  const PushTarget._();

  static Map<String, dynamic>? parse(Object? raw) {
    if (raw is! String) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
  }

  static bool recipientMatches(Map<String, dynamic> payload, String uid) {
    final recipient = payload['recipientUid']?.toString();
    return recipient == null || recipient == uid;
  }

  static String? socialNotificationId(
      Map<String, dynamic> payload, String uid) {
    // Unlike legacy chat pushes, social pushes always address one account.
    if (payload['kind'] != 'social' || payload['recipientUid'] != uid)
      return null;
    final id = payload['notificationId'];
    return id is String && id.isNotEmpty && !id.contains('/') ? id : null;
  }

  static bool chatMatches(Map<String, dynamic> chat, String uid) =>
      chat['user1'] == uid || chat['user2'] == uid;

  static bool meetingMatches(Map<String, dynamic> meeting,
      Map<String, dynamic> profile, Map<String, dynamic> payload, String uid) {
    final members = meeting['users'];
    if (meeting['admin'] == uid ||
        meeting['invitedUid'] == uid ||
        (members is List && members.contains(uid))) {
      return true;
    }
    // A new public meeting can alert a user in the same country and region,
    // but only when the server explicitly addressed this notification to them.
    if (payload['kind'] != 'new_meeting' ||
        payload['recipientUid'] != uid ||
        meeting['type'] != 'групповая') {
      return false;
    }
    final country = meeting['country']?.toString() ?? '';
    final region = meeting['region']?.toString() ?? '';
    return country.isNotEmpty &&
        region.isNotEmpty &&
        country == profile['country']?.toString() &&
        region == profile['region']?.toString();
  }
}
