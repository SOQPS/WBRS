import 'dart:convert';

import 'timeweb_auth_client.dart';

/// Immutable imported-snapshot reads only. No UI, writes, media download,
/// Firebase fallback or automatic poll/cache is installed by this adapter.
class TimewebConversationClient {
  TimewebConversationClient({
    required TimewebAuthClient auth,
    this.enabled = false,
  }) : _auth = auth;
  final TimewebAuthClient _auth;
  final bool enabled;

  void _enabled() {
    if (!enabled)
      throw const TimewebAuthException(
        TimewebAuthOperation.conversation,
        TimewebAuthError.disabled,
      );
  }

  Future<TimewebConversationPage> readChats({
    int limit = 50,
    TimewebReadCursor? cursor,
  }) =>
      _page(TimewebConversationReadRequest.chats(limit: limit, cursor: cursor));
  Future<TimewebConversationPage> readChatMessages(
    String id, {
    int limit = 50,
    TimewebReadCursor? cursor,
  }) => _page(
    TimewebConversationReadRequest.chatMessages(
      id,
      limit: limit,
      cursor: cursor,
    ),
  );
  Future<TimewebConversationPage> readMeetings({
    int limit = 50,
    TimewebReadCursor? cursor,
  }) => _page(
    TimewebConversationReadRequest.meetings(limit: limit, cursor: cursor),
  );
  Future<TimewebConversationPage> readMeetingMessages(
    String id, {
    bool ownRemoved = false,
    int limit = 50,
    TimewebReadCursor? cursor,
  }) => _page(
    TimewebConversationReadRequest.meetingMessages(
      id,
      ownRemoved: ownRemoved,
      limit: limit,
      cursor: cursor,
    ),
  );
  Future<TimewebConversationPage> readMeetingParticipants(
    String id, {
    int limit = 50,
    TimewebReadCursor? cursor,
  }) => _page(
    TimewebConversationReadRequest.meetingParticipants(
      id,
      limit: limit,
      cursor: cursor,
    ),
  );

  Future<TimewebMeetingDetail> readMeeting(String id) async {
    _enabled();
    final request = TimewebConversationReadRequest.meeting(id);
    final reply = await _auth.readConversation(request);
    final body = reply.body;
    _keys(body, {
      'meeting',
      'sourceSnapshot',
      'membershipAuthority',
      'mediaReady',
      'readReceiptsWritten',
    });
    _snapshot(body, flags: true);
    final meeting = _map(body['meeting']);
    _meeting(meeting);
    if (meeting['id'] != id) _invalid();
    reply.requireCurrent();
    return TimewebMeetingDetail._(reply, meeting, _metadata(body, {'meeting'}));
  }

  Future<TimewebConversationPage> _page(
    TimewebConversationReadRequest request,
  ) async {
    _enabled();
    final reply = await _auth.readConversation(request);
    final body = reply.body;
    final resource = request.resource;
    final discovery = const [
      TimewebConversationResource.chats,
      TimewebConversationResource.meetings,
    ].contains(resource);
    final participants =
        resource == TimewebConversationResource.meetingParticipants;
    final base = {
      'items',
      'nextCursor',
      'sourceSnapshot',
      'membershipAuthority',
    };
    _keys(body, {
      ...base,
      if (discovery || participants) 'ordering',
      if (!participants) ...{'mediaReady', 'readReceiptsWritten'},
      if (!discovery && !participants) ...{'history', 'notificationsMuted'},
    });
    _snapshot(body, flags: !participants);
    if (discovery || participants) {
      final ordering = participants
          ? 'organizer_then_utf8_uid'
          : resource == TimewebConversationResource.chats
          ? 'last_message_milliseconds_desc_utf8_id_desc'
          : 'source_timestamp_desc_utf8_id_desc';
      if (body['ordering'] != ordering) _invalid();
    } else {
      if (body['history'] !=
          (request.ownRemoved
              ? 'own_removed_meeting'
              : 'current_import_snapshot'))
        _invalid();
      _bool(body['notificationsMuted'], nullable: true);
    }
    final raw = body['items'];
    if (raw is! List || raw.length > request.limit!) _invalid();
    final items = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final value in raw) {
      final item = _map(value);
      switch (resource) {
        case TimewebConversationResource.chats:
          _chat(item);
        case TimewebConversationResource.meetings:
          _meeting(item);
        case TimewebConversationResource.meetingParticipants:
          _participant(item);
        default:
          _message(
            item,
            meeting: resource == TimewebConversationResource.meetingMessages,
          );
      }
      final identity = item[participants ? 'uid' : 'id'] as String;
      if (!seen.add(identity)) _invalid();
      items.add(item);
    }
    final cursor = reply.paginationCursor(body['nextCursor']);
    reply.requireCurrent();
    return TimewebConversationPage._(
      reply,
      List.unmodifiable(items),
      cursor,
      _metadata(body, {'items', 'nextCursor'}),
    );
  }
}

class TimewebConversationPage {
  TimewebConversationPage._(
    this._proof,
    this._items,
    this._cursor,
    this._metadata,
  );
  final TimewebAuthorizedRead _proof;
  final List<Map<String, dynamic>> _items;
  final TimewebReadCursor? _cursor;
  final Map<String, dynamic> _metadata;
  void requireCurrent() => _proof.requireCurrent();
  List<Map<String, dynamic>> get items {
    requireCurrent();
    return _items;
  }

  TimewebReadCursor? get nextCursor {
    requireCurrent();
    return _cursor;
  }

  Map<String, dynamic> get metadata {
    requireCurrent();
    return _metadata;
  }

  @override
  String toString() => 'TimewebConversationPage(<redacted>)';
}

class TimewebMeetingDetail {
  TimewebMeetingDetail._(this._proof, this._meeting, this._metadata);
  final TimewebAuthorizedRead _proof;
  final Map<String, dynamic> _meeting;
  final Map<String, dynamic> _metadata;
  void requireCurrent() => _proof.requireCurrent();
  Map<String, dynamic> get meeting {
    requireCurrent();
    return _meeting;
  }

  Map<String, dynamic> get metadata {
    requireCurrent();
    return _metadata;
  }

  @override
  String toString() => 'TimewebMeetingDetail(<redacted>)';
}

Never _invalid() => throw const TimewebAuthException(
  TimewebAuthOperation.conversation,
  TimewebAuthError.invalidResponse,
);
Map<String, dynamic> _map(Object? value) {
  if (value is! Map<String, dynamic>) _invalid();
  return value;
}

void _keys(
  Map<String, dynamic> value,
  Set<String> required, {
  Set<String> optional = const {},
}) {
  if (!required.every(value.containsKey) ||
      value.keys.any(
        (key) => !required.contains(key) && !optional.contains(key),
      ))
    _invalid();
}

void _string(Object? value, {int maximum = 1000, bool nullable = false}) {
  if (value == null && nullable) return;
  if (value is! String ||
      value.runes.length > maximum ||
      utf8.decode(utf8.encode(value)) != value)
    _invalid();
}

void _identifier(Object? value, {bool uid = false}) {
  _string(value, maximum: uid ? 191 : 1500);
  final id = value as String;
  if (id.isEmpty ||
      id == '.' ||
      id == '..' ||
      id.contains('/') ||
      id.contains('\u0000') ||
      utf8.encode(id).length > (uid ? 764 : 1500))
    _invalid();
}

void _bool(Object? value, {bool nullable = false}) {
  if (value is! bool && !(nullable && value == null)) _invalid();
}

void _integer(Object? value, int maximum, {bool nullable = false}) {
  if (value == null && nullable) return;
  if (value is! int || value < 0 || value > maximum) _invalid();
}

void _timestamp(Object? value, {bool nullable = false}) {
  if (value == null && nullable) return;
  _string(value, maximum: 30);
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?Z$',
  ).firstMatch(value as String);
  if (match == null) _invalid();
  final parts = [
    for (var index = 1; index <= 6; index++) int.parse(match.group(index)!),
  ];
  if (parts[0] < 1) _invalid();
  final date = DateTime.utc(
    parts[0],
    parts[1],
    parts[2],
    parts[3],
    parts[4],
    parts[5],
  );
  if (date.year != parts[0] ||
      date.month != parts[1] ||
      date.day != parts[2] ||
      date.hour != parts[3] ||
      date.minute != parts[4] ||
      date.second != parts[5])
    _invalid();
}

void _snapshot(Map<String, dynamic> value, {required bool flags}) {
  if (value['sourceSnapshot'] is! String ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(value['sourceSnapshot']) ||
      value['membershipAuthority'] != 'immutable-reviewed-snapshot' ||
      (flags &&
          (value['mediaReady'] != false ||
              value['readReceiptsWritten'] != false)))
    _invalid();
}

Map<String, dynamic> _metadata(
  Map<String, dynamic> body,
  Set<String> omitted,
) => Map.unmodifiable(
  Map.fromEntries(body.entries.where((entry) => !omitted.contains(entry.key))),
);

void _media(Object? value) {
  if (value == null) return;
  final data = _map(value);
  switch (data['kind']) {
    case 'bundled_gift':
      _keys(data, {'kind', 'asset'});
      _string(data['asset'], maximum: 4096);
      final asset = data['asset'] as String;
      if (asset.contains('..') ||
          !RegExp(
            r'^assets/gifts/[A-Za-z0-9 _().-]+\.(?:png|webp|jpg|jpeg|gif)$',
            caseSensitive: false,
          ).hasMatch(asset))
        _invalid();
    case 'legacy_storage':
      _keys(data, {'kind', 'status', 'reference'});
      if (data['status'] != 'quarantined' ||
          data['reference'] is! String ||
          !(data['reference'] as String).isNotEmpty ||
          (data['reference'] as String).length > 4096 ||
          !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(data['reference']))
        _invalid();
    case 'unavailable':
      _keys(data, {'kind', 'reason'});
      _string(data['reason'], maximum: 191);
    default:
      _invalid();
  }
}

void _message(Map<String, dynamic> value, {required bool meeting}) {
  _keys(
    value,
    {
      'id',
      'sentAt',
      'timestampBasis',
      'senderUid',
      'senderName',
      'text',
      'unavailableFields',
      'legacyIsRead',
    },
    optional: {'giftNoticeName', 'image', 'giftName', 'quote', 'sharedContent'},
  );
  _identifier(value['id']);
  _timestamp(value['sentAt']);
  if (!{
    meeting ? 'time' : 'ts',
    meeting ? 'time_legacy_milliseconds' : 'ts_legacy_milliseconds',
    'document_create_time',
  }.contains(value['timestampBasis']))
    _invalid();
  _string(value['senderUid'], maximum: 191, nullable: true);
  _string(value['senderName'], maximum: 191, nullable: true);
  _string(value['text'], maximum: 131072, nullable: true);
  _bool(value['legacyIsRead'], nullable: true);
  final unavailable = value['unavailableFields'];
  if (unavailable is! List || unavailable.length > 20) _invalid();
  for (final field in unavailable) {
    _string(field, maximum: 191);
  }
  for (final field in ['giftNoticeName', 'giftName']) {
    if (value.containsKey(field)) _string(value[field], nullable: true);
  }
  if (value.containsKey('image')) _media(value['image']);
  if (value.containsKey('quote')) {
    final quote = _map(value['quote']);
    _keys(
      quote,
      {'messageId'},
      optional: {'message', 'name', 'sendBy', 'sender', 'sendByID'},
    );
    if (quote['messageId'] != null) _invalid();
    for (final field in quote.keys.where((field) => field != 'messageId')) {
      _string(
        quote[field],
        maximum: field == 'message' ? 131072 : 191,
        nullable: true,
      );
    }
  }
  if (value.containsKey('sharedContent')) {
    final shared = _map(value['sharedContent']);
    _keys(
      shared,
      {'linkAvailable'},
      optional: {
        'kind',
        'postId',
        'commentId',
        'text',
        'authorName',
        'group',
        'image',
      },
    );
    if (shared['linkAvailable'] != false) _invalid();
    for (final field in shared.keys.where(
      (field) => field != 'image' && field != 'linkAvailable',
    )) {
      _string(
        shared[field],
        maximum: field == 'text' ? 131072 : 1000,
        nullable: true,
      );
    }
    if (shared.containsKey('image')) _media(shared['image']);
  }
}

void _participant(Map<String, dynamic> value) {
  _keys(
    value,
    {
      'uid',
      'name',
      'deleted',
      'profileState',
      'organizer',
      'member',
      'interactive',
      'avatar',
    },
    optional: {'age', 'city', 'group'},
  );
  _identifier(value['uid'], uid: true);
  _string(value['name'], nullable: true);
  for (final field in ['deleted', 'organizer', 'member', 'interactive']) {
    _bool(value[field]);
  }
  if (!{
        'active',
        'deleted',
        'legacy_only',
        'missing_profile',
      }.contains(value['profileState']) ||
      (value['profileState'] != 'active' && value['interactive'] != false) ||
      (value['deleted'] == true && value['profileState'] == 'active') ||
      (value['member'] != true && value['organizer'] != true))
    _invalid();
  if (value.containsKey('age')) _integer(value['age'], 150, nullable: true);
  for (final field in ['city', 'group']) {
    if (value.containsKey(field)) _string(value[field], nullable: true);
  }
  _media(value['avatar']);
}

void _peer(Map<String, dynamic> value) {
  _keys(value, {
    'uid',
    'name',
    'age',
    'status',
    'online',
    'group',
    'profileState',
    'interactive',
    'avatar',
  });
  _identifier(value['uid'], uid: true);
  _integer(value['age'], 150, nullable: true);
  for (final field in ['name', 'status', 'group']) {
    _string(
      value[field],
      maximum: field == 'status' ? 191 : 1000,
      nullable: true,
    );
  }
  _bool(value['online'], nullable: true);
  _bool(value['interactive']);
  _media(value['avatar']);
  if (!{
        'active',
        'deleted',
        'disabled',
        'legacy_only',
        'missing_profile',
        'unavailable',
      }.contains(value['profileState']) ||
      (value['profileState'] != 'active' && value['interactive'] != false))
    _invalid();
}

void _chat(Map<String, dynamic> value) {
  _keys(value, {
    'id',
    'peer',
    'lastMessage',
    'lastMessageSendBy',
    'lastMessageSendByUID',
    'lastActivityAt',
    'unreadCount',
    'lastSharedKind',
  });
  _identifier(value['id']);
  _peer(_map(value['peer']));
  for (final field in [
    'lastMessage',
    'lastMessageSendBy',
    'lastMessageSendByUID',
    'lastSharedKind',
  ]) {
    _string(
      value[field],
      maximum: field == 'lastMessage'
          ? 4096
          : field == 'lastMessageSendBy'
          ? 1000
          : 191,
      nullable: true,
    );
  }
  _timestamp(value['lastActivityAt'], nullable: true);
  _integer(value['unreadCount'], 2147483647, nullable: true);
}

void _meeting(Map<String, dynamic> value) {
  _keys(value, {
    'id',
    'name',
    'description',
    'type',
    'scheduledLocal',
    'country',
    'countryCode',
    'region',
    'city',
    'createdAt',
    'scheduledTimezone',
    'organizer',
    'participantsCount',
    'membership',
    'image',
    'canReadMessages',
    'canReadParticipants',
  });
  _identifier(value['id']);
  for (final field in [
    'name',
    'description',
    'type',
    'scheduledLocal',
    'country',
    'countryCode',
    'region',
    'city',
  ]) {
    _string(
      value[field],
      maximum: switch (field) {
        'description' => 4096,
        'type' => 191,
        'scheduledLocal' => 100,
        'countryCode' => 20,
        _ => 1000,
      },
      nullable: true,
    );
  }
  _timestamp(value['createdAt'], nullable: true);
  _peer(_map(value['organizer']));
  _integer(value['participantsCount'], 1000);
  _media(value['image']);
  _bool(value['canReadMessages']);
  final membership = _map(value['membership']);
  _keys(membership, {'isOrganizer', 'isMember', 'kicked'});
  _bool(membership['isOrganizer']);
  _bool(membership['isMember']);
  if (value['scheduledTimezone'] != null ||
      membership['kicked'] != false ||
      value['canReadParticipants'] != true ||
      (membership['isOrganizer'] != true && membership['isMember'] != true) ||
      (value['canReadMessages'] == true && membership['isMember'] != true))
    _invalid();
}
