import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/service/push_target.dart';

void main() {
  test('social push must address this account and a single inbox document', () {
    const payload = {
      'kind': 'social',
      'recipientUid': 'current',
      'notificationId': 'comment-123'
    };
    expect(PushTarget.socialNotificationId(payload, 'current'), 'comment-123');
    expect(PushTarget.socialNotificationId(payload, 'previous'), isNull);
    expect(
        PushTarget.socialNotificationId(
            {'kind': 'social', 'notificationId': 'comment-123'}, 'current'),
        isNull);
    for (final invalid in ['', 'other/inbox', 123, null]) {
      expect(
          PushTarget.socialNotificationId(
              {...payload, 'notificationId': invalid}, 'current'),
          isNull);
    }
  });
  test('rejects malformed and cross-account notification payloads', () {
    expect(PushTarget.parse('{bad'), isNull);
    expect(PushTarget.parse('[]'), isNull);
    expect(
        PushTarget.recipientMatches(
            {'recipientUid': 'old-account'}, 'new-account'),
        isFalse);
    expect(
        PushTarget.chatMatches(
            {'user1': 'old-account', 'user2': 'friend'}, 'new-account'),
        isFalse);
  });

  test('allows a current chat member, never a stale third-party chat', () {
    const chat = {'user1': 'current', 'user2': 'friend'};
    expect(PushTarget.chatMatches(chat, 'current'), isTrue);
    expect(PushTarget.chatMatches(chat, 'previous'), isFalse);
  });

  test('regional public meeting requires addressed recipient and exact region',
      () {
    const meet = {
      'type': 'групповая',
      'country': 'Россия',
      'region': 'Московская область',
      'users': ['organizer']
    };
    const profile = {'country': 'Россия', 'region': 'Московская область'};
    const addressed = {'kind': 'new_meeting', 'recipientUid': 'current'};
    expect(
        PushTarget.meetingMatches(meet, profile, addressed, 'current'), isTrue);
    expect(
        PushTarget.meetingMatches(
            meet, profile, {'kind': 'new_meeting'}, 'current'),
        isFalse);
    expect(
        PushTarget.meetingMatches(meet,
            {'country': 'Россия', 'region': 'Дагестан'}, addressed, 'current'),
        isFalse);
    expect(
        PushTarget.meetingMatches(
            {...meet, 'type': 'индивидуальная'}, profile, addressed, 'current'),
        isFalse);
  });

  test('private meeting only opens for organizer, invitee or member', () {
    const meet = {
      'type': 'индивидуальная',
      'admin': 'organizer',
      'invitedUid': 'guest',
      'users': ['organizer']
    };
    expect(
        PushTarget.meetingMatches(meet, const {}, const {}, 'guest'), isTrue);
    expect(PushTarget.meetingMatches(meet, const {}, const {}, 'previous'),
        isFalse);
  });
}
