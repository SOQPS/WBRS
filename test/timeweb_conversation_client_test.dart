import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import '../lib/service/timeweb_auth_client.dart';
import '../lib/service/timeweb_conversation_client.dart';

final _now = DateTime.utc(2026, 10, 1);
const _stamp = '2026-09-30T12:34:56.123456789Z';
const _opaque = 'Synthetic_cursor-012';

class _Store implements TimewebSecureTokenStore {
  TimewebSession? value = _session('A');
  int reads = 0, writes = 0, clears = 0;
  @override
  Future<TimewebSession?> read() async {
    reads++;
    return value;
  }

  @override
  Future<void> write(TimewebSession session) async {
    writes++;
    value = session;
  }

  @override
  Future<void> clear() async {
    clears++;
    value = null;
  }
}

class _Wire extends http.BaseClient {
  _Wire(this.action);
  final Future<http.StreamedResponse> Function(http.BaseRequest) action;
  final calls = <http.BaseRequest>[];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    calls.add(request);
    return action(request);
  }
}

TimewebSession _session(String uid, {bool expired = false}) => TimewebSession(
  uid: uid,
  emailVerified: true,
  accessToken: 'na1.$uid.first',
  refreshToken: 'nr1.$uid.first',
  accessExpiresAt: expired
      ? _now.subtract(const Duration(seconds: 1))
      : _now.add(const Duration(minutes: 15)),
  refreshExpiresAt: _now.add(const Duration(days: 14)),
);
Map<String, dynamic> _tokens(String uid) => {
  'uid': uid,
  'emailVerified': true,
  'accessToken': 'na1.$uid.rotated',
  'refreshToken': 'nr1.$uid.rotated',
  'expiresIn': 900,
  'refreshExpiresIn': 1209600,
};
TimewebAuthClient _auth(
  _Store store,
  _Wire wire, {
  bool enabled = true,
  Duration deadline = const Duration(seconds: 1),
}) => TimewebAuthClient(
  configuration: TimewebAuthConfiguration(
    endpoint: Uri.parse('https://clrs-api.example.invalid'),
    enabled: enabled,
  ),
  secureStore: store,
  transport: wire,
  clock: () => _now,
  requestDeadline: deadline,
);
http.StreamedResponse _reply(
  Object value, {
  int status = 200,
  bool noStore = true,
}) => http.StreamedResponse(
  Stream.value(utf8.encode(jsonEncode(value))),
  status,
  headers: {
    'content-type': 'application/json; charset=utf-8',
    if (noStore) 'cache-control': 'no-store',
  },
);
Matcher _error(TimewebAuthError value) => isA<TimewebAuthException>().having(
  (error) => error.error,
  'safe error',
  value,
);
Map<String, dynamic> _snapshot({bool flags = true}) => {
  'sourceSnapshot': 'a' * 64,
  'membershipAuthority': 'immutable-reviewed-snapshot',
  if (flags) 'mediaReady': false,
  if (flags) 'readReceiptsWritten': false,
};
Map<String, dynamic> _peer(String uid, {String state = 'active'}) => {
  'uid': uid,
  'name': 'Synthetic name',
  'age': 28,
  'status': null,
  'online': null,
  'group': null,
  'profileState': state,
  'interactive': state == 'active',
  'avatar': null,
};
Map<String, dynamic> _chat(String id) => {
  'id': id,
  'peer': _peer('peer'),
  'lastMessage': 'Synthetic text',
  'lastMessageSendBy': 'Synthetic name',
  'lastMessageSendByUID': 'peer',
  'lastActivityAt': _stamp,
  'unreadCount': 2,
  'lastSharedKind': null,
};
Map<String, dynamic> _meeting(String id) => {
  'id': id,
  'name': 'Synthetic meeting',
  'description': null,
  'type': null,
  'scheduledLocal': '30.09.2026 17:00',
  'country': null,
  'countryCode': null,
  'region': null,
  'city': null,
  'createdAt': _stamp,
  'scheduledTimezone': null,
  'organizer': _peer('organizer'),
  'participantsCount': 2,
  'membership': {'isOrganizer': false, 'isMember': true, 'kicked': false},
  'image': null,
  'canReadMessages': true,
  'canReadParticipants': true,
};
Map<String, dynamic> _message(String id, {bool meeting = false}) => {
  'id': id,
  'sentAt': _stamp,
  'timestampBasis': meeting ? 'time' : 'ts',
  'senderUid': 'historical/sender',
  'senderName': 'Synthetic name',
  'text': 'Synthetic text',
  'unavailableFields': [],
  'legacyIsRead': null,
};
Map<String, dynamic> _participant(String uid, {String state = 'active'}) => {
  'uid': uid,
  'name': null,
  'deleted': false,
  'profileState': state,
  'organizer': false,
  'member': true,
  'interactive': state == 'active',
  'avatar': null,
};
Map<String, dynamic> _page(
  String type, {
  List<Map<String, dynamic>> items = const [],
  Object? cursor,
  bool removed = false,
}) => {
  ..._snapshot(flags: type != 'participants'),
  'items': items,
  'nextCursor': cursor,
  if (type == 'chats')
    'ordering': 'last_message_milliseconds_desc_utf8_id_desc',
  if (type == 'meetings') 'ordering': 'source_timestamp_desc_utf8_id_desc',
  if (type == 'participants') 'ordering': 'organizer_then_utf8_uid',
  if (type == 'messages')
    'history': removed ? 'own_removed_meeting' : 'current_import_snapshot',
  if (type == 'messages') 'notificationsMuted': null,
};

void main() {
  test(
    'conversation and auth configurations are independently default-off',
    () async {
      final store = _Store(), wire = _Wire((_) async => _reply(_page('chats')));
      final auth = _auth(store, wire);
      await expectLater(
        TimewebConversationClient(auth: auth).readChats(),
        throwsA(_error(TimewebAuthError.disabled)),
      );
      final disabled = _auth(store, wire, enabled: false);
      await expectLater(
        TimewebConversationClient(auth: disabled, enabled: true).readChats(),
        throwsA(_error(TimewebAuthError.disabled)),
      );
      expect(wire.calls, isEmpty);
      expect(store.reads, 0);
    },
  );

  test(
    'six exact GET routes encode IDs once, bearer only in header, own_removed explicit',
    () async {
      final store = _Store();
      const id = 'комната ?#%';
      final wire = _Wire((request) async {
        final parts = request.url.pathSegments;
        if (parts.length == 2)
          return _reply(_page(parts[1] == 'chats' ? 'chats' : 'meetings'));
        if (parts.length == 3)
          return _reply({'meeting': _meeting(id), ..._snapshot()});
        if (parts.last == 'participants') return _reply(_page('participants'));
        return _reply(
          _page(
            'messages',
            removed: request.url.queryParameters['own_removed'] == '1',
          ),
        );
      });
      final auth = _auth(store, wire);
      await auth.restore();
      final client = TimewebConversationClient(auth: auth, enabled: true);
      await client.readChats();
      await client.readChatMessages(id);
      await client.readMeetings();
      await client.readMeeting(id);
      await client.readMeetingMessages(id);
      await client.readMeetingMessages(id, ownRemoved: true);
      await client.readMeetingParticipants(id);
      expect(
        wire.calls.map((request) => request.url.pathSegments.toList()).toList(),
        [
          ['v1', 'chats'],
          ['v1', 'chats', id, 'messages'],
          ['v1', 'meetings'],
          ['v1', 'meetings', id],
          ['v1', 'meetings', id, 'messages'],
          ['v1', 'meetings', id, 'messages'],
          ['v1', 'meetings', id, 'participants'],
        ],
      );
      for (final request in wire.calls) {
        expect(request.method, 'GET');
        expect(request.followRedirects, isFalse);
        expect(request.url.scheme, 'https');
        expect(request.url.host, 'clrs-api.example.invalid');
        expect(request.headers['Authorization'], 'Bearer na1.A.first');
        expect(request.url.toString(), isNot(contains('na1.')));
        expect(
          request.url.queryParameters.keys.toSet().difference({
            'limit',
            'own_removed',
          }),
          isEmpty,
        );
        expect((request as http.Request).body, isEmpty);
      }
      expect(
        wire.calls[4].url.queryParameters.containsKey('own_removed'),
        isFalse,
      );
      expect(wire.calls[5].url.queryParameters['own_removed'], '1');
      expect(store.writes, 0);
      expect(store.clears, 0);
    },
  );

  test('invalid path IDs and page limits never reach transport', () async {
    final store = _Store(),
        wire = _Wire((_) async => _reply(_page('messages')));
    final auth = _auth(store, wire);
    await auth.restore();
    final client = TimewebConversationClient(auth: auth, enabled: true);
    for (final id in [
      '',
      '.',
      '..',
      'a/b',
      '\u0000',
      '\ud800',
      'x' * 1501,
      'Я' * 751,
    ]) {
      expect(() => client.readChatMessages(id), throwsArgumentError);
    }
    for (final limit in [0, 51]) {
      expect(() => client.readChats(limit: limit), throwsArgumentError);
    }
    expect(wire.calls, isEmpty);
    await client.readChatMessages('Я' * 750);
    expect(wire.calls.single.url.pathSegments[2], 'Я' * 750);
  });

  test(
    'preserves nanosecond history/quotes/assets/quarantined descriptors without media fetch or fabricated link',
    () async {
      final value = _message('message')
        ..addAll({
          'giftNoticeName': 'Synthetic gift notice',
          'giftName': 'Synthetic gift',
          'image': {
            'kind': 'bundled_gift',
            'asset': 'assets/gifts/Synthetic gift.png',
          },
          'quote': {
            'messageId': null,
            'message': 'Synthetic quote',
            'sender': 'legacy',
          },
          'sharedContent': {
            'kind': 'post',
            'text': 'Synthetic shared text',
            'linkAvailable': false,
            'image': {
              'kind': 'legacy_storage',
              'status': 'quarantined',
              'reference': 'Synthetic_media-012',
            },
          },
        });
      final store = _Store(),
          wire = _Wire(
            (_) async =>
                _reply(_page('messages', items: [value], cursor: _opaque)),
          );
      final auth = _auth(store, wire);
      await auth.restore();
      final page = await TimewebConversationClient(
        auth: auth,
        enabled: true,
      ).readChatMessages('room');
      expect(page.items.single['sentAt'], _stamp);
      expect(page.items.single['senderUid'], 'historical/sender');
      expect(page.items.single['quote']['messageId'], isNull);
      expect(
        page.items.single['sharedContent']['image']['status'],
        'quarantined',
      );
      expect(page.metadata['mediaReady'], isFalse);
      expect(page.nextCursor.toString(), 'TimewebReadCursor(<redacted>)');
      expect(wire.calls, hasLength(1));
      expect(store.writes, 0);
      expect(
        () => page.items.single['quote']['messageId'] = 'invented',
        throwsUnsupportedError,
      );
      expect(() => page.items.add(value), throwsUnsupportedError);
    },
  );

  test(
    'empty visible page can continue; cursor bound to route/client and never decoded',
    () async {
      final store = _Store(),
          wire = _Wire(
            (request) async => _reply(
              _page(
                'messages',
                cursor: request.url.queryParameters.containsKey('cursor')
                    ? null
                    : _opaque,
              ),
            ),
          );
      final auth = _auth(store, wire);
      await auth.restore();
      final client = TimewebConversationClient(auth: auth, enabled: true);
      final first = await client.readChatMessages('room');
      expect(first.items, isEmpty);
      final cursor = first.nextCursor!;
      final second = await client.readChatMessages(
        'room',
        limit: 1,
        cursor: cursor,
      );
      expect(second.nextCursor, isNull);
      expect(wire.calls.last.url.queryParameters['cursor'], _opaque);
      final count = wire.calls.length;
      await expectLater(
        client.readMeetingMessages('room', cursor: cursor),
        throwsA(_error(TimewebAuthError.invalidRequest)),
      );
      final otherAuth = _auth(_Store(), wire);
      await otherAuth.restore();
      await expectLater(
        TimewebConversationClient(
          auth: otherAuth,
          enabled: true,
        ).readChatMessages('room', cursor: cursor),
        throwsA(_error(TimewebAuthError.invalidRequest)),
      );
      expect(wire.calls.length, count);
    },
  );

  test(
    'returned page and cursor from A become stale after B; late A success is rejected',
    () async {
      final late = Completer<http.StreamedResponse>();
      var wait = false;
      final store = _Store(),
          wire = _Wire((request) async {
            if (request.method == 'POST') return _reply(_tokens('B'));
            if (wait) return late.future;
            return _reply(_page('messages', cursor: _opaque));
          });
      final auth = _auth(store, wire);
      await auth.restore();
      final client = TimewebConversationClient(auth: auth, enabled: true);
      final page = await client.readChatMessages('room');
      final cursor = page.nextCursor!;
      wait = true;
      final pending = client.readChatMessages('room');
      final rejected = expectLater(
        pending,
        throwsA(_error(TimewebAuthError.staleSession)),
      );
      await auth.login(
        email: 'B@example.invalid',
        password: 'synthetic',
        deviceId: 'synthetic-device',
      );
      late.complete(_reply(_page('messages', items: [_message('late-A')])));
      await rejected;
      expect(() => page.items, throwsA(_error(TimewebAuthError.staleSession)));
      expect(
        () => page.nextCursor,
        throwsA(_error(TimewebAuthError.staleSession)),
      );
      final count = wire.calls.length;
      await expectLater(
        client.readChatMessages('room', cursor: cursor),
        throwsA(_error(TimewebAuthError.staleSession)),
      );
      expect(wire.calls.length, count);
      expect(auth.currentUid, 'B');
    },
  );

  test(
    'parallel401 reads share one refresh and each retry GET once using rotated header',
    () async {
      final rotation = Completer<http.StreamedResponse>();
      final started = Completer<void>();
      var refreshes = 0;
      final store = _Store(),
          wire = _Wire((request) async {
            if (request.url.path == '/v1/auth/refresh') {
              refreshes++;
              if (!started.isCompleted) started.complete();
              return rotation.future;
            }
            if (request.headers['Authorization'] == 'Bearer na1.A.first')
              return _reply({}, status: 401);
            return _reply(_page('messages'));
          });
      final auth = _auth(store, wire);
      await auth.restore();
      final client = TimewebConversationClient(auth: auth, enabled: true);
      final one = client.readChatMessages('room'),
          two = client.readMeetingMessages('meeting');
      await started.future;
      expect(refreshes, 1);
      rotation.complete(_reply(_tokens('A')));
      expect((await one).items, isEmpty);
      expect((await two).items, isEmpty);
      expect(refreshes, 1);
      expect(
        wire.calls.where((request) => request.method == 'GET'),
        hasLength(4),
      );
      expect(
        wire.calls.where(
          (request) =>
              request.method == 'GET' &&
              request.headers['Authorization'] == 'Bearer na1.A.rotated',
        ),
        hasLength(2),
      );
      expect(store.writes, 1);
    },
  );

  test('GET401 never retries or refreshes into a changed account', () async {
    final old = Completer<http.StreamedResponse>();
    var posts = 0;
    final store = _Store(),
        wire = _Wire((request) async {
          if (request.method == 'POST') {
            posts++;
            return _reply(_tokens('B'));
          }
          return old.future;
        });
    final auth = _auth(store, wire);
    await auth.restore();
    final client = TimewebConversationClient(auth: auth, enabled: true);
    final pending = client.readChats();
    final rejected = expectLater(
      pending,
      throwsA(_error(TimewebAuthError.staleSession)),
    );
    await auth.login(
      email: 'B@example.invalid',
      password: 'synthetic',
      deviceId: 'synthetic-device',
    );
    old.complete(_reply({}, status: 401));
    await rejected;
    expect(posts, 1);
    expect(
      wire.calls.where((request) => request.method == 'GET'),
      hasLength(1),
    );
  });

  test('secondGET401 invalidates A; no third GET or second rotation', () async {
    final store = _Store(),
        wire = _Wire(
          (request) async => request.method == 'POST'
              ? _reply(_tokens('A'))
              : _reply({}, status: 401),
        );
    final auth = _auth(store, wire);
    await auth.restore();
    await expectLater(
      TimewebConversationClient(auth: auth, enabled: true).readChats(),
      throwsA(_error(TimewebAuthError.unauthorized)),
    );
    expect(
      wire.calls.where((request) => request.method == 'GET'),
      hasLength(2),
    );
    expect(
      wire.calls.where((request) => request.method == 'POST'),
      hasLength(1),
    );
    expect(auth.hasSession, isFalse);
    expect(store.value, isNull);
  });

  test(
    'body deadline cancels active stream; response budget cancels oversized body',
    () async {
      var cancelled = 0;
      final controllers = <StreamController<List<int>>>[];
      final store = _Store(),
          wire = _Wire((_) async {
            final stream = StreamController<List<int>>(
              onCancel: () {
                cancelled++;
              },
            );
            controllers.add(stream);
            return http.StreamedResponse(
              stream.stream,
              200,
              headers: {
                'content-type': 'application/json',
                'cache-control': 'no-store',
              },
            );
          });
      final auth = _auth(
        store,
        wire,
        deadline: const Duration(milliseconds: 20),
      );
      await auth.restore();
      final client = TimewebConversationClient(auth: auth, enabled: true);
      final timeout = client.readChats();
      await expectLater(timeout, throwsA(_error(TimewebAuthError.deadline)));
      expect(cancelled, 1);
      final big = client.readChats();
      final rejected = expectLater(
        big,
        throwsA(_error(TimewebAuthError.invalidResponse)),
      );
      await Future<void>.delayed(Duration.zero);
      controllers.last.add(List.filled(262145, 120));
      await rejected;
      expect(cancelled, 2);
      expect(auth.currentUid, 'A');
      expect(store.clears, 0);
    },
  );

  test(
    'hung header requests are bounded at four; late headers cancelled then release capacity',
    () async {
      final pending = <Completer<http.StreamedResponse>>[];
      final store = _Store(),
          wire = _Wire((_) {
            final value = Completer<http.StreamedResponse>();
            pending.add(value);
            return value.future;
          });
      final auth = _auth(
        store,
        wire,
        deadline: const Duration(milliseconds: 10),
      );
      await auth.restore();
      final client = TimewebConversationClient(auth: auth, enabled: true);
      for (var index = 0; index < 4; index++) {
        await expectLater(
          client.readChats(),
          throwsA(_error(TimewebAuthError.deadline)),
        );
      }
      await expectLater(
        client.readChats(),
        throwsA(_error(TimewebAuthError.unavailable)),
      );
      expect(wire.calls, hasLength(4));
      pending.first.complete(_reply(_page('chats')));
      await Future<void>.delayed(Duration.zero);
      final next = client.readChats();
      final rejected = expectLater(
        next,
        throwsA(_error(TimewebAuthError.deadline)),
      );
      await rejected;
      expect(wire.calls, hasLength(5));
      for (final value in pending.skip(1)) {
        value.complete(_reply(_page('chats')));
      }
      await Future<void>.delayed(Duration.zero);
      expect(store.writes, 0);
    },
  );

  for (final status in [302, 404, 429, 503]) {
    test(
      'GET$status returns safe error without retry, error-body exposure or account invalidation',
      () async {
        final store = _Store(),
            wire = _Wire(
              (_) async => _reply({
                'token': 'Synthetic private na1.secret',
              }, status: status),
            );
        final auth = _auth(store, wire);
        await auth.restore();
        try {
          await TimewebConversationClient(
            auth: auth,
            enabled: true,
          ).readChats();
          fail('reject');
        } on TimewebAuthException catch (error) {
          expect(error is TimewebUnknownOutcome, isFalse);
          expect(error.toString(), isNot(contains('secret')));
          expect(
            error.error,
            status == 429
                ? TimewebAuthError.rateLimited
                : TimewebAuthError.unavailable,
          );
        }
        expect(wire.calls, hasLength(1));
        expect(auth.currentUid, 'A');
        expect(store.clears, 0);
      },
    );
  }

  for (final invalid in [
    'unknown-field',
    'fake-quote-link',
    'raw-media-url',
    'snapshot',
    'history',
    'cursor',
    'duplicates',
    'too-many',
    'calendar',
  ]) {
    test(
      'strict message response rejects $invalid and leaks no raw error',
      () async {
        final body = _page('messages', items: [_message('one')]);
        final item = (body['items'] as List).first as Map<String, dynamic>;
        switch (invalid) {
          case 'unknown-field':
            item['email'] = 'Synthetic@example.invalid';
          case 'fake-quote-link':
            item['quote'] = {'messageId': 'invented'};
          case 'raw-media-url':
            item['image'] = 'https://storage.example.invalid/private';
          case 'snapshot':
            body['sourceSnapshot'] = 'not-pinned';
          case 'history':
            body['history'] = 'other-owner';
          case 'cursor':
            body['nextCursor'] = 'https://cursor.example.invalid';
          case 'duplicates':
            body['items'] = [item, item];
          case 'too-many':
            body['items'] = [item, _message('two')];
          default:
            item['sentAt'] = '2026-02-31T12:00:00Z';
        }
        final store = _Store(), wire = _Wire((_) async => _reply(body));
        final auth = _auth(store, wire);
        await auth.restore();
        await expectLater(
          TimewebConversationClient(
            auth: auth,
            enabled: true,
          ).readChatMessages('room', limit: invalid == 'duplicates' ? 2 : 1),
          throwsA(_error(TimewebAuthError.invalidResponse)),
        );
        expect(auth.currentUid, 'A');
        expect(store.writes, 0);
      },
    );
  }

  test(
    'discovery exact DTO and noninteractive legacy/deleted profiles preserve truthful absence',
    () async {
      final chat = _chat('room');
      (chat['peer'] as Map)['profileState'] = 'deleted';
      (chat['peer'] as Map)['interactive'] = false;
      var calls = 0;
      final store = _Store(),
          wire = _Wire((request) async {
            calls++;
            if (request.url.path == '/v1/chats')
              return _reply(_page('chats', items: [chat]));
            if (request.url.path == '/v1/meetings')
              return _reply(_page('meetings', items: [_meeting('meeting')]));
            if (request.url.path.endsWith('/participants'))
              return _reply(
                _page(
                  'participants',
                  items: [_participant('legacy', state: 'missing_profile')],
                ),
              );
            return _reply({'meeting': _meeting('meeting'), ..._snapshot()});
          });
      final auth = _auth(store, wire);
      await auth.restore();
      final client = TimewebConversationClient(auth: auth, enabled: true);
      final chats = await client.readChats();
      expect(chats.items.single['peer']['interactive'], isFalse);
      expect(
        (await client.readMeetings()).items.single['scheduledTimezone'],
        isNull,
      );
      expect(
        (await client.readMeeting('meeting')).meeting['scheduledLocal'],
        '30.09.2026 17:00',
      );
      expect(
        (await client.readMeetingParticipants(
          'meeting',
        )).items.single.containsKey('age'),
        isFalse,
      );
      await client.readChats();
      expect(calls, 5); // No value cache.
    },
  );

  test(
    'incorrect detail ID, interactive deleted peer and cacheable response fail closed',
    () async {
      for (final variant in ['detail', 'peer', 'cache']) {
        final store = _Store(),
            wire = _Wire((_) async {
              if (variant == 'detail')
                return _reply({'meeting': _meeting('other'), ..._snapshot()});
              final chat = _chat('room');
              if (variant == 'peer') {
                (chat['peer'] as Map)['profileState'] = 'deleted';
              }
              return _reply(
                _page('chats', items: [chat]),
                noStore: variant != 'cache',
              );
            });
        final auth = _auth(store, wire);
        await auth.restore();
        final client = TimewebConversationClient(auth: auth, enabled: true);
        await expectLater(
          variant == 'detail'
              ? client.readMeeting('meeting')
              : client.readChats(),
          throwsA(_error(TimewebAuthError.invalidResponse)),
        );
      }
    },
  );

  test('request deadline cannot be unbounded', () {
    expect(
      () => _auth(
        _Store(),
        _Wire((_) async => _reply({})),
        deadline: const Duration(seconds: 31),
      ),
      throwsArgumentError,
    );
  });

  test(
    'explicit own_removed cursor cannot be replayed into current meeting history',
    () async {
      final store = _Store(),
          wire = _Wire(
            (_) async =>
                _reply(_page('messages', removed: true, cursor: _opaque)),
          );
      final auth = _auth(store, wire);
      await auth.restore();
      final client = TimewebConversationClient(auth: auth, enabled: true);
      final page = await client.readMeetingMessages('old', ownRemoved: true);
      await expectLater(
        client.readMeetingMessages('old', cursor: page.nextCursor),
        throwsA(_error(TimewebAuthError.invalidRequest)),
      );
      expect(wire.calls, hasLength(1));
    },
  );

  test(
    'deleted active participant and unrelated participant cannot become interactive',
    () async {
      for (final variant in ['deleted', 'unrelated']) {
        final participant = _participant('legacy');
        participant[variant == 'deleted' ? 'deleted' : 'member'] =
            variant == 'deleted';
        final store = _Store(),
            wire = _Wire(
              (_) async => _reply(_page('participants', items: [participant])),
            );
        final auth = _auth(store, wire);
        await auth.restore();
        await expectLater(
          TimewebConversationClient(
            auth: auth,
            enabled: true,
          ).readMeetingParticipants('meeting'),
          throwsA(_error(TimewebAuthError.invalidResponse)),
        );
      }
    },
  );

  test(
    'expired read shares refresh; unknown rotation never retries or sends GET with old credential',
    () async {
      final store = _Store()..value = _session('A', expired: true);
      final pending = Completer<http.StreamedResponse>();
      final wire = _Wire((_) => pending.future);
      final auth = _auth(
        store,
        wire,
        deadline: const Duration(milliseconds: 15),
      );
      await auth.restore();
      final client = TimewebConversationClient(auth: auth, enabled: true);
      final one = expectLater(
        client.readChats(),
        throwsA(isA<TimewebUnknownOutcome>()),
      );
      final two = expectLater(
        client.readMeetings(),
        throwsA(isA<TimewebUnknownOutcome>()),
      );
      await Future.wait([one, two]);
      expect(wire.calls, hasLength(1));
      expect(wire.calls.single.url.path, '/v1/auth/refresh');
      expect(auth.hasSession, isFalse);
      expect(store.value, isNull);
      pending.complete(_reply(_tokens('A')));
      await Future<void>.delayed(Duration.zero);
      expect(auth.hasSession, isFalse);
      expect(store.writes, 0);
    },
  );

  test(
    'enabled read without a restored session does not make a request',
    () async {
      final store = _Store(), wire = _Wire((_) async => _reply(_page('chats')));
      await expectLater(
        TimewebConversationClient(
          auth: _auth(store, wire),
          enabled: true,
        ).readChats(),
        throwsA(_error(TimewebAuthError.notAuthenticated)),
      );
      expect(wire.calls, isEmpty);
      expect(store.reads, 0);
    },
  );

  test(
    'discovery rejects impossible membership and server-incompatible preview length',
    () async {
      for (final variant in ['membership', 'preview']) {
        final meeting = _meeting('meeting');
        meeting['membership'] = {
          'isOrganizer': false,
          'isMember': false,
          'kicked': false,
        };
        final chat = _chat('room')..['lastMessage'] = 'x' * 4097;
        final store = _Store(),
            wire = _Wire(
              (_) async => variant == 'membership'
                  ? _reply({'meeting': meeting, ..._snapshot()})
                  : _reply(_page('chats', items: [chat])),
            );
        final auth = _auth(store, wire);
        await auth.restore();
        final client = TimewebConversationClient(auth: auth, enabled: true);
        await expectLater(
          variant == 'membership'
              ? client.readMeeting('meeting')
              : client.readChats(),
          throwsA(_error(TimewebAuthError.invalidResponse)),
        );
      }
    },
  );
}
