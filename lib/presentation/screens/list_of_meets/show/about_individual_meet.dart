import 'package:wbrs/shared/translatable_text.dart';
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/presentation/screens/chat_screen/chatscreen.dart';
import 'package:wbrs/presentation/screens/edit_meet/edit_meet.dart';
import 'package:wbrs/presentation/screens/list_of_users/show/somebody_profile.dart';
import 'package:wbrs/service/meeting_membership_service.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/group_avatar.dart';
import 'package:wbrs/shared/profile_composition.dart';

class AboutIndividualMeet extends StatefulWidget {
  final AsyncSnapshot? snapshot;
  final int? index;
  final DocumentSnapshot<Map<String, dynamic>>? meetingDoc;
  final DocumentSnapshot doc;
  final MeetingMembershipService? membershipService;
  const AboutIndividualMeet(
      {super.key,
      this.snapshot,
      this.index,
      this.meetingDoc,
      required this.doc,
      this.membershipService})
      : assert(meetingDoc != null || (snapshot != null && index != null));
  @override
  State<AboutIndividualMeet> createState() => _AboutIndividualMeetState();
}

class _AboutIndividualMeetState extends State<AboutIndividualMeet> {
  late final String? _owner = firebaseAuth.currentUser?.uid;
  late final DocumentSnapshot _initial =
      widget.meetingDoc ?? widget.snapshot!.data.docs[widget.index!];
  late final MeetingMembershipService _membership = widget.membershipService ??
      MeetingMembershipService(meetingId: _initial.id);
  late Stream<DocumentSnapshot<Map<String, dynamic>>> _stream;
  MeetingMembershipRequest? _request;
  String? _notice;
  bool _busy = false, _restoring = true;
  Future<String>? _chat;
  bool get _active =>
      mounted && _owner != null && firebaseAuth.currentUser?.uid == _owner;
  @override
  void initState() {
    super.initState();
    _subscribe();
    _restore();
  }

  void _subscribe() {
    try {
      _stream =
          firebaseFirestore.collection('meets').doc(_initial.id).snapshots();
    } catch (error) {
      _stream = Stream.error(error);
    }
  }

  Future<void> _restore() async {
    try {
      final request = await _membership.restore();
      if (_active) setState(() => _request = request);
    } catch (_) {
      if (_active) {
        setState(() => _notice =
            'Не удалось восстановить изменение участия. Повторите проверку.');
      }
    } finally {
      if (_active) setState(() => _restoring = false);
    }
  }

  Future<void> _change(bool joined) async {
    if (!_active || _busy || _restoring) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      _request ??= await _membership.restore();
      if (!_active) return;
      _request ??= _membership.change(joined: joined);
      final confirmed = await _request!.write.wait();
      if (!_active) return;
      if (!confirmed) {
        setState(() => _notice =
            'Результат изменения участия пока неизвестен. Проверьте его перед повтором.');
        return;
      }
      _membership.acknowledge(_request!);
      setState(() {
        _request = null;
        _subscribe();
      });
    } catch (_) {
      if (_request?.write.failed ?? false) _request = null;
      if (_active) {
        setState(() =>
            _notice = 'Не удалось изменить участие. Проверьте соединение.');
      }
    } finally {
      if (_active) setState(() => _busy = false);
    }
  }

  Future<String> _findChat(String organizer, Map profile) async {
    final owner = _owner;
    if (owner == null || !_active) throw StateError('Сеанс завершён');
    final chats = firebaseFirestore.collection('chats');
    for (final pair in [(owner, organizer), (organizer, owner)]) {
      final found = await chats
          .where('user1', isEqualTo: pair.$1)
          .where('user2', isEqualTo: pair.$2)
          .limit(1)
          .get();
      if (!_active) throw StateError('Сеанс завершён');
      if (found.docs.isNotEmpty) return found.docs.first.id;
    }
    final ids = [owner, organizer]..sort();
    final id = 'direct_${ids[0].length}_${ids[0]}_${ids[1]}';
    final ref = chats.doc(id);
    final me = firebaseAuth.currentUser!;
    await firebaseFirestore.runTransaction((tx) async {
      final existing = await tx.get(ref);
      if (!_active) throw StateError('Сеанс завершён');
      if (existing.exists) return;
      tx.set(ref, {
        'user1': _owner,
        'user2': organizer,
        'user1Nickname': me.displayName ?? '',
        'user2Nickname': profile['fullName'] ?? '',
        'user1_image': me.photoURL ?? '',
        'user2_image': profile['profilePic'] ?? '',
        'chatId': id,
        'lastMessage': '',
        'lastMessageSendBy': '',
        'lastMessageSendTs': DateTime.now(),
        'unreadMessage': 0
      });
    });
    return id;
  }

  Future<void> _openChat(String organizer, Map profile) async {
    if (!_active || _busy || organizer.isEmpty || organizer == _owner) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    _chat ??= _findChat(organizer, profile)..ignore();
    try {
      final id = await _chat!.timeout(const Duration(seconds: 15));
      if (!mounted || !_active) return;
      _chat = null;
      await Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => ChatScreen(
                  chatId: id,
                  chatWithUsername: '${profile['fullName'] ?? ''}',
                  id: _owner!,
                  photoUrl: '${profile['profilePic'] ?? ''}')));
    } on TimeoutException {
      if (_active) {
        setState(() => _notice =
            'Результат открытия чата пока неизвестен. Проверьте результат.');
      }
    } catch (_) {
      _chat = null;
      if (_active) {
        setState(() => _notice = 'Не удалось открыть чат. Попробуйте ещё раз.');
      }
    } finally {
      if (_active) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ClrsScaffold(
      appBar: AppBar(title: Text(context.tr('Индивидуальная встреча'))),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: _stream,
          builder: (context, snapshot) {
            if (snapshot.hasError) return _error();
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final meeting = snapshot.data!;
            final data = meeting.data();
            if (!meeting.exists || data == null) {
              return Center(child: Text(context.tr('Встреча недоступна')));
            }
            final organizer = '${data['admin'] ?? ''}';
            final invitedUid = '${data['invitedUid'] ?? ''}';
            if (invitedUid.isNotEmpty &&
                _owner != organizer &&
                _owner != invitedUid) {
              return Center(child: Text(context.tr('Встреча недоступна')));
            }
            final profile =
                widget.doc.data() is Map ? widget.doc.data() as Map : const {};
            final isAdmin = organizer == _owner;
            final joined = (data['users'] as List? ?? []).contains(_owner);
            final kicked = (data['kicked'] as List? ?? []).contains(_owner);
            final date = data['datetime'];
            final dateText = date is Timestamp
                ? context.l10n.dateTime(date.toDate())
                : date is DateTime
                    ? context.l10n.dateTime(date)
                    : '${date ?? ''}';
            return ListView(padding: const EdgeInsets.all(16), children: [
              const ClrsBrandHeader(),
              TranslatableText('${data['name'] ?? ''}',
                  style: Theme.of(context).textTheme.headlineSmall),
              if (isAdmin && invitedUid.isNotEmpty)
                Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                        '${context.tr('Получатель')}: ${data['invitedName'] ?? ''} · ${context.tr((data['users'] as List? ?? []).contains(invitedUid) ? 'Приглашение принято' : 'Ожидает ответа')}')),
              const SizedBox(height: 12),
              if (widget.doc.exists)
                ClrsPanel(
                    child: InkWell(
                        onTap: isAdmin
                            ? null
                            : () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => SomebodyProfile(
                                        uid: organizer,
                                        photoUrl:
                                            '${profile['profilePic'] ?? ''}',
                                        name: '${profile['fullName'] ?? ''}',
                                        userInfo: profile))),
                        child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              GroupAvatar(
                                  url: '${profile['profilePic'] ?? ''}',
                                  group: '${profile['группа'] ?? ''}'),
                              const SizedBox(width: 12),
                              Expanded(
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                    Text('${profile['fullName'] ?? ''}'),
                                    Text(context.tr('Организатор')),
                                    Text(profileLocation(profile,
                                        context: context)),
                                  ])),
                              const Icon(Icons.chevron_right),
                            ]))),
              ProfileSection(
                  title: context.tr('Детали встречи'),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(dateText),
                        const SizedBox(height: 8),
                        Text(profileLocation(data, context: context)),
                        const Divider(),
                        Text(context.tr('Описание встречи'),
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 8),
                        TranslatableText('${data['description'] ?? ''}'),
                      ])),
              const SizedBox(height: 16),
              if (_notice != null)
                Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(context.tr(_notice!))),
              if (_busy || _restoring) const LinearProgressIndicator(),
              if (_request != null)
                ElevatedButton(
                    onPressed: _busy ? null : () => _change(_request!.joined),
                    child: Text(context.tr('Проверить результат')))
              else if (isAdmin)
                OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => EditMeet(meet: meeting))),
                    icon: const Icon(Icons.edit_calendar_outlined),
                    label: Text(context.tr('Редактировать встречу')))
              else if (kicked)
                Text(context.tr('Вы были исключены из встречи'))
              else if (joined) ...[
                Text(context.tr('Вы приняли приглашение на встречу')),
                ElevatedButton.icon(
                    onPressed:
                        _busy ? null : () => _openChat(organizer, profile),
                    icon: const Icon(Icons.chat_bubble_outline),
                    label: Text(context.tr(_chat == null
                        ? 'Написать организатору'
                        : 'Проверить результат'))),
                TextButton(
                    onPressed:
                        _busy || _restoring ? null : () => _change(false),
                    child: Text(context.tr('Выйти из встречи'))),
              ] else
                ElevatedButton(
                    onPressed: _busy || _restoring ? null : () => _change(true),
                    child: Text(context.tr('Принять приглашение на встречу'))),
            ]);
          }));
  Widget _error() => Center(
          child: ClrsPanel(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(
            context.tr('Не удалось загрузить встречу. Проверьте подключение.')),
        TextButton(
            onPressed: () => setState(_subscribe),
            child: Text(context.tr('Повторить'))),
      ])));
}
