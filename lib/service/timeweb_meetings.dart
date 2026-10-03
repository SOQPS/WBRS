part of 'timeweb_auth_client.dart';

final class TimewebMeetingCreateRequest {
  TimewebMeetingCreateRequest._(this._fields);
  final Map<String, dynamic> _fields;
  static Future<TimewebMeetingCreateRequest> fromCatalog({required String name,
    required String description, required String countryCode, required String region,
    required String datetime, required String type, String? invitedUid}) async {
    if (!_currentNullableText(name, 1000) || name.trim().isEmpty ||
        !_currentNullableText(description, 4096) || !_meetingLocalDatetime(datetime) ||
        !const ['групповая', 'индивидуальная'].contains(type) ||
        (type == 'индивидуальная' ? !_currentIdentifier(invitedUid) : invitedUid != null)) {
      throw ArgumentError('Invalid native meeting request.');
    }
    await TimewebGeographyChanges.fromCatalog(countryCode: countryCode, region: region);
    return TimewebMeetingCreateRequest._(Map.unmodifiable({'name': name, 'description': description,
      'countryCode': countryCode, 'region': region, 'datetime': datetime, 'type': type,
      if (invitedUid != null) 'invitedUid': invitedUid}));
  }
  Map<String, dynamic> get fields => _fields;
  @override
  String toString() => 'TimewebMeetingCreateRequest(<redacted>)';
}

bool _meetingLocalDatetime(Object? value) {
  if (value is! String || !RegExp(r'^[0-9]{2}\.[0-9]{2}\.[0-9]{4} [0-9]{2}:[0-9]{2}$').hasMatch(value)) return false;
  final day = int.parse(value.substring(0, 2)), month = int.parse(value.substring(3, 5));
  final year = int.parse(value.substring(6, 10)), hour = int.parse(value.substring(11, 13)), minute = int.parse(value.substring(14));
  final date = DateTime.utc(year, month, day, hour, minute);
  return year >= 1 && year <= 9999 && date.year == year && date.month == month && date.day == day && date.hour == hour && date.minute == minute;
}

final class TimewebMeetingCreateReceipt {
  TimewebMeetingCreateReceipt._(this._data, this._check);
  final Map<String, dynamic> _data;
  final void Function() _check;
  void requireCurrent() => _check();
  TimewebMeetingCreateReceipt bindSessionGuard(void Function() guard) =>
      TimewebMeetingCreateReceipt._(_data, () { requireCurrent(); guard(); });
  T _read<T>(String key) { _check(); return _data[key] as T; }
  String get meetingId => _read('meetingId');
  bool get created => _read('created');
  int get meetingRevision => _read('meetingRevision');
  String get localDatetime => _read('localDatetime');
  @override
  String toString() => 'TimewebMeetingCreateReceipt(<redacted>)';
}

final class TimewebMeetingJoinRequest {
  TimewebMeetingJoinRequest({required this.meetingId}) {
    if (!_meetingIdentifier(meetingId)) throw ArgumentError('Invalid native meeting.');
  }
  final String meetingId;
  @override
  String toString() => 'TimewebMeetingJoinRequest(<redacted>)';
}

final class TimewebMeetingJoinReceipt {
  TimewebMeetingJoinReceipt._(this._data, this._check);
  final Map<String, dynamic> _data;
  final void Function() _check;
  void requireCurrent() => _check();
  TimewebMeetingJoinReceipt bindSessionGuard(void Function() guard) =>
      TimewebMeetingJoinReceipt._(_data, () { requireCurrent(); guard(); });
  T _read<T>(String key) { _check(); return _data[key] as T; }
  String get meetingId => _read('meetingId');
  bool get joined => _read('joined');
  bool get alreadyMember => _read('alreadyMember');
  int get membershipRevision => _read('membershipRevision');
  @override
  String toString() => 'TimewebMeetingJoinReceipt(<redacted>)';
}

final class TimewebMeetingFilters {
  TimewebMeetingFilters._(this._query);
  final Map<String, String> _query;
  static Future<TimewebMeetingFilters> fromCatalog({String scope = 'group', int limit = 30,
    String? countryCode, String? region}) async {
    if (!const ['group', 'individual'].contains(scope)) throw ArgumentError('Invalid meeting scope.');
    await TimewebPeopleFilters.fromCatalog(limit: limit, countryCode: countryCode, region: region);
    return TimewebMeetingFilters._(Map.unmodifiable({'scope': scope, 'limit': '$limit',
      if (countryCode != null) 'countryCode': countryCode, if (region != null) 'region': region}));
  }
  String get scope => _query['scope']!;
  int get limit => int.parse(_query['limit']!);
  String? get countryCode => _query['countryCode'];
  String? get region => _query['region'];
  @override
  String toString() => 'TimewebMeetingFilters(<redacted>)';
}

final class TimewebMeetingCursor {
  TimewebMeetingCursor._(this._value, this._owner, this._scope, this._check, this._expiry);
  final String _value, _scope;
  final TimewebAuthClient _owner;
  final void Function() _check;
  final DateTime _expiry;
  void requireCurrent() { _check(); if (!_owner._clock().isBefore(_expiry)) throw const TimewebAuthException(TimewebAuthOperation.currentRead, TimewebAuthError.invalidRequest); }
  @override
  String toString() => 'TimewebMeetingCursor(<redacted>)';
}

final class TimewebMeetingPage<T> {
  TimewebMeetingPage._(this._items, this._cursor, this._check);
  final List<T> _items;
  final TimewebMeetingCursor? _cursor;
  final void Function() _check;
  void requireCurrent() => _check();
  List<T> get items { _check(); return _items; }
  TimewebMeetingCursor? get nextCursor { _check(); return _cursor; }
  bool get mediaReady { _check(); return false; }
  TimewebMeetingPage<T> bindSessionGuard(void Function() guard) {
    void check() { requireCurrent(); guard(); }
    final cursor = _cursor;
    return TimewebMeetingPage<T>._(List.unmodifiable(_items.map((item) =>
      (item is TimewebMeeting ? item.bindSessionGuard(guard) : (item as TimewebMeetingParticipant).bindSessionGuard(guard)) as T)),
      cursor == null ? null : TimewebMeetingCursor._(cursor._value, cursor._owner, cursor._scope,
        () { cursor.requireCurrent(); guard(); }, cursor._expiry), check);
  }
  @override
  String toString() => 'TimewebMeetingPage(<redacted>)';
}

final class TimewebMeeting {
  TimewebMeeting._(this._data, this._check);
  final Map<String, dynamic> _data;
  final void Function() _check;
  void requireCurrent() => _check();
  TimewebMeeting bindSessionGuard(void Function() guard) => TimewebMeeting._(_data, () { requireCurrent(); guard(); });
  T _read<T>(String key) { _check(); return _data[key] as T; }
  String get meetingId => _read('meetingId');
  String get organizerUid => _read('organizerUid');
  String? get invitedUid => _read('invitedUid');
  String get kind => _read('kind');
  String get title => _read('title');
  String get description => _read('description');
  String get countryCode => _read('countryCode');
  String get region => _read('region');
  String? get startsAt => _read('startsAt');
  String? get createdAt => _read('createdAt');
  String? get updatedAt => _read('updatedAt');
  int get revision => _read('revision');
  String get localDatetime => _read('localDatetime');
  Null get media { _check(); return null; }
  bool get mediaReady { _check(); return false; }
  @override
  String toString() => 'TimewebMeeting(<redacted>)';
}

final class TimewebMeetingParticipant {
  TimewebMeetingParticipant._(this._data, this._check);
  final Map<String, dynamic> _data;
  final void Function() _check;
  void requireCurrent() => _check();
  TimewebMeetingParticipant bindSessionGuard(void Function() guard) => TimewebMeetingParticipant._(_data, () { requireCurrent(); guard(); });
  T _read<T>(String key) { _check(); return _data[key] as T; }
  String get uid => _read('uid');
  String? get fullName => _read('fullName');
  String? get primaryGroup => _read('primaryGroup');
  String? get joinedAt => _read('joinedAt');
  int get membershipRevision => _read('membershipRevision');
  Null get avatar { _check(); return null; }
  bool get mediaReady { _check(); return false; }
  @override
  String toString() => 'TimewebMeetingParticipant(<redacted>)';
}

final class TimewebMeetingNotFound implements Exception {
  const TimewebMeetingNotFound();
  @override
  String toString() => 'TimewebMeetingNotFound';
}

extension TimewebMeetingsClient on TimewebAuthClient {
  Future<TimewebMeetingPage<TimewebMeeting>> readMeetings(TimewebMeetingFilters filters, {TimewebMeetingCursor? cursor}) =>
      _meetingRead(this, filters._query, null, cursor).then((v) => v as TimewebMeetingPage<TimewebMeeting>);
  Future<TimewebMeeting> readMeeting(String meetingId) => _meetingRead(this, const {}, meetingId, null).then((v) => v as TimewebMeeting);
  Future<TimewebMeetingPage<TimewebMeetingParticipant>> readMeetingParticipants(String meetingId, {int limit = 30, TimewebMeetingCursor? cursor}) {
    if (limit < 1 || limit > 30) return Future.error(ArgumentError('Invalid participant limit.'));
    return _meetingRead(this, {'limit': '$limit'}, meetingId, cursor).then((v) => v as TimewebMeetingPage<TimewebMeetingParticipant>);
  }
}

Future<Object> _meetingRead(TimewebAuthClient owner, Map<String, String> query, String? id, TimewebMeetingCursor? cursor) {
  try {
    owner._checkEnabled(_peopleOperation);
    if (!owner.configuration.currentReadsEnabled || !owner.configuration.runtimeWritesEnabled) throw const TimewebAuthException(_peopleOperation, TimewebAuthError.disabled);
    final session = owner._session;
    if (session == null || owner._secureStoreUnsafe) throw const TimewebAuthException(_peopleOperation, TimewebAuthError.notAuthenticated);
    if (id != null && !_meetingIdentifier(id)) throw const TimewebAuthException(_peopleOperation, TimewebAuthError.invalidRequest);
    final scope = 'meetings:$id:${jsonEncode(query)}';
    if (cursor != null) {
      if (!identical(cursor._owner, owner) || cursor._scope != scope) throw const TimewebAuthException(_peopleOperation, TimewebAuthError.invalidRequest);
      cursor.requireCurrent();
    }
    final key = '${owner._epoch}\u0000$scope\u0000${cursor?._value ?? ''}';
    final existing = owner._peopleFlights[key];
    if (existing != null) return existing.result.future;
    if (owner._peopleFlights.length >= 4) throw const TimewebAuthException(_peopleOperation, TimewebAuthError.unavailable);
    final flight = _PeopleFlight(owner, null, null, null, owner._epoch, session.uid, key);
    owner._peopleFlights[key] = flight;
    unawaited(_executeMeetingRead(flight, query, id, cursor, scope));
    return flight.result.future;
  } catch (error) { return Future.error(error); }
}

Future<void> _executeMeetingRead(_PeopleFlight f, Map<String, String> query, String? id, TimewebMeetingCursor? cursor, String scope) async {
  final owner = f.owner;
  final uri = owner.configuration.endpoint.replace(pathSegments: ['v1', 'runtime', 'meetings',
    if (id != null) id, if (id != null && query.isNotEmpty) 'participants'],
    queryParameters: query.isEmpty ? null : {...query, if (cursor != null) 'cursor': cursor._value});
  try {
    f.check(); var session = owner._session!;
    if (!owner._clock().add(owner.accessExpirySkew).isBefore(session.accessExpiresAt)) { session = await owner.refresh(); f.check(); }
    var reply = await _meetingAttempt(f, uri, session.accessToken); f.check();
    if (reply.status == 401) {
      if (owner._session?.accessToken == session.accessToken) await owner.refresh();
      f.check(); session = owner._session!; reply = await _meetingAttempt(f, uri, session.accessToken); f.check();
    }
    if (reply.status != 200) {
      if (reply.status == 401 && owner._session?.accessToken == session.accessToken) await owner._invalidate(f.epoch);
      if (reply.status == 404 && id != null) throw const TimewebMeetingNotFound();
      throw owner._statusError(_peopleOperation, reply.status);
    }
    final catalog = await _pinnedGeographyCatalog(); f.check();
    final value = _decodeMeetingRead(f, reply.body!, query, id, cursor, scope, catalog); f.check();
    if (!f.result.isCompleted) f.result.complete(value);
  } catch (error) {
    if (!f.result.isCompleted) {
      try { f.check(); f.result.completeError(error is TimewebAuthException || error is TimewebMeetingNotFound ? error : const TimewebAuthException(_peopleOperation, TimewebAuthError.network)); }
      on TimewebAuthException catch (stale) { if (!f.result.isCompleted) f.result.completeError(stale); }
    }
  } finally {
    f.timer.cancel(); if (identical(owner._peopleFlights[f.key], f)) owner._peopleFlights.remove(f.key); f.settled.complete();
  }
}

Future<_Reply> _meetingAttempt(_PeopleFlight f, Uri uri, String bearer) async {
  f.check(); final owner = f.owner;
  if (owner._inflightRequests >= 4) throw const TimewebAuthException(_peopleOperation, TimewebAuthError.unavailable);
  final abort = Completer<void>();
  final request = http.AbortableRequest('GET', uri, abortTrigger: abort.future)..followRedirects = false
    ..headers['Accept'] = 'application/json'..headers['Authorization'] = 'Bearer $bearer'..headers['Cache-Control'] = 'no-store';
  StreamIterator<List<int>>? reader; Future<void>? cancellation;
  Future<void> cancel() => reader == null ? Future.value() : cancellation ??= reader.cancel();
  f.aborts.add(abort); f.cancellations.add(cancel); owner._inflightRequests++;
  try {
    final response = await owner._http.send(request); reader = StreamIterator(response.stream);
    var moving = reader.moveNext(); unawaited(moving.then<void>((_) {}, onError: (Object _, StackTrace __) {})); f.check();
    if (response.isRedirect || response.statusCode >= 300 && response.statusCode < 400) _peopleInvalid();
    if (response.statusCode != 200) return _Reply(response.statusCode, null);
    final mime = response.headers['content-type']?.toLowerCase() ?? '';
    final cache = (response.headers['cache-control'] ?? '').toLowerCase().split(',').map((v) => v.trim());
    final encoding = response.headers['content-encoding']?.toLowerCase();
    if (mime.split(';').first.trim() != 'application/json' || !cache.contains('no-store') || cache.contains('public') ||
        encoding != null && encoding != 'identity' || response.contentLength != null && response.contentLength! > 65536) _peopleInvalid();
    final bytes = <int>[];
    while (await moving) { f.check(); if (bytes.length + reader.current.length > 65536) _peopleInvalid(); bytes.addAll(reader.current); moving = reader.moveNext(); }
    f.check(); if (response.contentLength != null && response.contentLength != bytes.length) _peopleInvalid();
    final decoded = jsonDecode(utf8.decode(bytes)); if (decoded is! Map<String, dynamic>) _peopleInvalid();
    return _Reply(200, decoded);
  } on FormatException { _peopleInvalid(); }
  finally { try { if (!abort.isCompleted) abort.complete(); await cancel(); }
    finally { f.aborts.remove(abort); f.cancellations.remove(cancel); owner._inflightRequests--; } }
}

bool _meetingIdentifier(Object? value) => _currentIdentifier(value) && !(value as String).contains(RegExp(r'[/\\%?#]'));

TimewebMeeting _decodeMeeting(_PeopleFlight f, Object? value, Map<String, dynamic> catalog) {
  if (value is! Map<String, dynamic> || !_mutationExact(value, {'meetingId','organizerUid','invitedUid','kind','title','description','countryCode','region',
      'startsAt','localDatetime','createdAt','updatedAt','revision','media','mediaReady'}) ||
      !_meetingIdentifier(value['meetingId']) || !_currentIdentifier(value['organizerUid']) ||
      !((value['kind'] == 'group' && value['invitedUid'] == null) || (value['kind'] == 'individual' && _currentIdentifier(value['invitedUid']) && value['invitedUid'] != value['organizerUid'] && [value['organizerUid'], value['invitedUid']].contains(f.uid))) ||
      value['startsAt'] != null || !_meetingLocalDatetime(value['localDatetime']) || value['media'] != null || value['mediaReady'] != false ||
      !_mutationInteger(value['revision']) || !_currentNullableStamp(value['createdAt']) || !_currentNullableStamp(value['updatedAt'])) _peopleInvalid();
  if (value['title'] is! String || (value['title'] as String).trim().isEmpty || value['description'] is! String ||
      !_currentNullableText(value['title'], 1000) || !_currentNullableText(value['description'], 4096) ||
      !(catalog['countries'] as List).any((row) => row['code'] == value['countryCode'] && (row['regions'] as List).contains(value['region']))) _peopleInvalid();
  return TimewebMeeting._(Map.unmodifiable(value), f.checkSession);
}

Object _decodeMeetingRead(_PeopleFlight f, Map<String, dynamic> body, Map<String, String> query, String? id, TimewebMeetingCursor? cursor, String scope, Map<String, dynamic> catalog) {
  if (body['kind'] != 'canonical-current' || body['mediaReady'] != false) _peopleInvalid();
  if (id != null && query.isEmpty) {
    if (!_mutationExact(body, {'kind','meeting','mediaReady'})) _peopleInvalid();
    final item = _decodeMeeting(f, body['meeting'], catalog); if (item.meetingId != id) _peopleInvalid(); return item;
  }
  final participants = id != null, limit = int.parse(query['limit']!);
  if (!_mutationExact(body, {'kind','ordering','items','nextCursor','mediaReady',participants ? 'meetingId' : 'scope'}) ||
      body['ordering'] != (participants ? 'uid_binary_asc' : 'starts_at_asc_meeting_id_asc_null_first') ||
      (participants ? body['meetingId'] != id : body['scope'] != query['scope']) || body['items'] is! List || (body['items'] as List).length > limit) _peopleInvalid();
  final next = body['nextCursor'];
  if (next != null && (!_validReadCursor(next is String ? next : '') || next == cursor?._value)) _peopleInvalid();
  final continuation = next == null ? null : TimewebMeetingCursor._(next, f.owner, scope, f.checkSession, cursor?._expiry ?? f.startedAt.add(const Duration(seconds: 300)));
  String? previous;
  if (participants) {
    final items = <TimewebMeetingParticipant>[];
    for (final value in body['items'] as List) {
      if (value is! Map<String, dynamic> || !_mutationExact(value, {'uid','fullName','primaryGroup','joinedAt','membershipRevision','avatar','mediaReady'}) ||
          !_currentIdentifier(value['uid']) || !_currentNullableText(value['fullName'], 1000) || !_currentNullableText(value['primaryGroup'], 191) ||
          !_currentNullableStamp(value['joinedAt']) || !_mutationInteger(value['membershipRevision']) || value['avatar'] != null || value['mediaReady'] != false ||
          previous != null && _currentCompareIds(previous, value['uid']) >= 0) _peopleInvalid();
      previous = value['uid']; items.add(TimewebMeetingParticipant._(Map.unmodifiable(value), f.checkSession));
    }
    return TimewebMeetingPage<TimewebMeetingParticipant>._(List.unmodifiable(items), continuation, f.checkSession);
  }
  final items = <TimewebMeeting>[];
  for (final value in body['items'] as List) {
    final item = _decodeMeeting(f, value, catalog);
    if (item.kind != query['scope'] || query['countryCode'] != null && item.countryCode != query['countryCode'] ||
        query['region'] != null && item.region != query['region'] || previous != null && _currentCompareIds(previous, item.meetingId) >= 0 ||
        item.kind == 'individual' && ![item.organizerUid, item.invitedUid].contains(f.uid)) _peopleInvalid();
    previous = item.meetingId; items.add(item);
  }
  return TimewebMeetingPage<TimewebMeeting>._(List.unmodifiable(items), continuation, f.checkSession);
}

TimewebMutationResult _decodeCreatedMeeting(TimewebMutationReference ref, int status, Map<String, dynamic> result, int? revision, bool replayed) {
  final expected = 'tw-meeting-${crypto.sha256.convert([...utf8.encode('clrs-native-meeting-v1\u0000'), ...utf8.encode(_mutationCanonical([ref._uid, ref._request.operationId]))])}';
  if (!_mutationExact(result, {'meetingId','created','meetingRevision','localDatetime'}) || result['meetingId'] != expected ||
      result['created'] != true || result['meetingRevision'] is! int || result['meetingRevision'] != 0 || revision != 0 || result['localDatetime'] != ref._request._payload['datetime']) _mutationInvalidReply();
  return TimewebMutationResult._(ref, TimewebMutationState.confirmed, status, replayed: replayed, revision: revision,
    meeting: TimewebMeetingCreateReceipt._(result, ref.requireCurrent), receiptConfirmed: true);
}

TimewebMutationResult _decodeJoinedMeeting(TimewebMutationReference ref, int status, Map<String, dynamic> result, int? revision, bool replayed) {
  if (status != 200 || !_mutationExact(result, {'meetingId','joined','alreadyMember','membershipRevision'}) ||
      result['meetingId'] != ref._request._payload['meetingId'] || result['joined'] != true ||
      result['alreadyMember'] is! bool || !_mutationInteger(result['membershipRevision']) || revision != result['membershipRevision']) _mutationInvalidReply();
  return TimewebMutationResult._(ref, TimewebMutationState.confirmed, status, replayed: replayed, revision: revision,
    joinedMeeting: TimewebMeetingJoinReceipt._(result, ref.requireCurrent), receiptConfirmed: true);
}
