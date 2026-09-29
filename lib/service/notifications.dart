import 'dart:async';
import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:wbrs/service/app_backend.dart';

/// FCM admin credentials belong exclusively on a trusted server.
class NotificationsService {
  static const _endpoint = String.fromEnvironment('CLRS_PUSH_ENDPOINT');
  Future<void> sendPushMessage(String token, Map body, String title,
          dynamic unreadMsgCount, dynamic chatRoomId) =>
      _enqueue(body, chatRoomId.toString(), 'chat');
  Future<void> sendPushMessageGroup(String token, Map body, String title,
          dynamic unreadMsgCount, dynamic groupRoomId) =>
      _enqueue(body, groupRoomId.toString(), 'group');

  Future<void> _enqueue(Map body, String entityId, String kind) {
    // The message is already committed. Its server trigger owns delivery;
    // this optional, deduplicated hint must not hold the chat composer open.
    unawaited(_send(body, entityId, kind));
    return Future<void>.value();
  }

  Future<void> _send(Map body, String entityId, String kind) async {
    if (AppBackend.useEmulators || _endpoint.isEmpty) return;
    final messageId = body['messageId'];
    if (messageId is! String || messageId.isEmpty) return;
    final uri = Uri.tryParse(_endpoint);
    if (uri == null || uri.scheme != 'https') return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final idToken =
          await user.getIdToken().timeout(const Duration(seconds: 5));
      if (idToken == null || FirebaseAuth.instance.currentUser?.uid != user.uid) {
        return;
      }
      final response = await http
          .post(
            uri,
            headers: {
              'Authorization': 'Bearer $idToken',
              'Content-Type': 'application/json'
            },
            body: jsonEncode({
              'kind': kind,
              'entityId': entityId,
              'messageId': messageId
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint('CLRS: push request failed (${response.statusCode}).');
      }
    } catch (_) {
      debugPrint('CLRS: push server unavailable.');
    }
  }
}
