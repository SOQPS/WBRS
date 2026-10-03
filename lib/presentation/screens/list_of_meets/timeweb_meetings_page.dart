import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/presentation/screens/list_of_users/timeweb_people_page.dart';
import 'package:wbrs/presentation/screens/list_of_meets/meetings.dart';
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/service/timeweb_meeting_create_flow.dart';
import 'package:wbrs/service/timeweb_meeting_join_flow.dart';
import 'package:wbrs/shared/clrs_brand.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/geo_catalog.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/shared/meeting_form.dart';

const timewebMeetingsRoute = '/timeweb/meetings';

AppBar _bar(BuildContext context, String title, {Widget? scopeControl, Widget? action}) => AppBar(
  title: Row(
    children: [
      const Expanded(child: ClrsLogo(size: 34)),
      SizedBox(
        width: 112,
        height: 48,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: SizedBox(
            width: 112,
            child: DefaultTextStyle.merge(
              maxLines: 3,
              softWrap: true,
              overflow: TextOverflow.visible,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const ClrsMotto(size: 18),
                  const Icon(Icons.favorite_border, size: 12, color: LrsTheme.peach),
                ],
              ),
            ),
          ),
        ),
      ),
    ],
  ),
  toolbarHeight: 78 * MediaQuery.textScalerOf(context).scale(1).clamp(1, 2),
  bottom: PreferredSize(
    preferredSize: Size.fromHeight(48 * MediaQuery.textScalerOf(context).scale(1).clamp(1, 2)),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
        child: Row(
          children: [
            if (scopeControl != null) scopeControl,
            Expanded(
              child: Text(
                context.tr(title),
                maxLines: scopeControl == null ? 2 : 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            if (action != null) SizedBox(width: 138, child: action),
          ],
        ),
      ),
    ),
  ),
);

Widget _left(Widget child) => Align(
  alignment: Alignment.centerLeft,
  child: FractionallySizedBox(widthFactor: 2 / 3, child: child),
);

String _wallClock(DateTime date) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(date.day)}.${two(date.month)}.${date.year.toString().padLeft(4, '0')} ${two(date.hour)}:${two(date.minute)}';
}

Widget _choice(
  BuildContext context,
  String label,
  String? value,
  Iterable<(String, String)> values,
  ValueChanged<String?>? changed,
) => DropdownButtonFormField<String>(
  key: ValueKey('$label/$value'),
  value: value,
  isExpanded: true,
  decoration: InputDecoration(labelText: context.tr(label)),
  items: [
    for (final item in values)
      DropdownMenuItem(
        value: item.$1,
        child: Text(context.tr(item.$2), maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
  ],
  onChanged: changed,
);

Widget _locations(
  BuildContext context,
  List<GeoCountry> countries,
  String? country,
  String? region,
  void Function(String?, String?) changed, {
  bool filter = false,
  bool enabled = true,
}) => Row(
  children: [
    Expanded(
      child: _choice(context, 'Страна', country, [
        if (filter) ('', 'Все страны'),
        for (final item in countries) (item.code, item.name),
      ], enabled ? (value) => changed(value == '' ? null : value, null) : null),
    ),
    const SizedBox(width: 8),
    Expanded(
      child: _choice(context, 'Регион', region, [
        if (filter) ('', 'Все регионы'),
        for (final item in GeoCatalog.byCode(countries, country)?.regions ?? <String>[]) (item, item),
      ], enabled && country != null ? (value) => changed(country, value == '' ? null : value) : null),
    ),
  ],
);

Widget _meetingCard(BuildContext context, TimewebMeeting meeting, {VoidCallback? tap, bool full = false}) => Padding(
  padding: const EdgeInsets.only(bottom: 12),
  child: _left(
    ClrsPanel(
      child: InkWell(
        key: ValueKey('native-meeting-${meeting.meetingId}'),
        onTap: tap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              meeting.title,
              style: full ? Theme.of(context).textTheme.titleLarge : Theme.of(context).textTheme.titleMedium,
            ),
            Text(meeting.localDatetime),
            Text('${meeting.countryCode} · ${meeting.region}'),
            if (meeting.description.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(meeting.description, maxLines: full ? null : 3, overflow: full ? null : TextOverflow.ellipsis),
            ],
          ],
        ),
      ),
    ),
  ),
);

/// One current page, then an explicit next page. No imported meeting/media fallback.
class TimewebMeetingsPageView extends StatefulWidget {
  const TimewebMeetingsPageView({super.key, required this.runtime, this.meetingId});
  final TimewebAppRuntime runtime;
  final String? meetingId;
  @override
  State<TimewebMeetingsPageView> createState() => _TimewebMeetingsPageViewState();
}

class _TimewebMeetingsPageViewState extends State<TimewebMeetingsPageView> {
  final _fieldsNavigator = GlobalKey<NavigatorState>();
  late final TimewebAppRuntime _runtime = widget.runtime;
  late final int _epoch = _runtime.session.state.epoch;
  late final String? _owner = _runtime.session.state.identity?.uid;
  StreamSubscription<AppSessionState>? _subscription;
  List<GeoCountry>? _countries;
  String? _country, _region;
  String _scope = 'group';
  TimewebMeetingFilters? _filters;
  TimewebMeetingPage<TimewebMeeting>? _page;
  TimewebMeetingPage<TimewebMeetingParticipant>? _participants;
  TimewebMeeting? _meeting;
  TimewebMeetingJoinFlow? _joinFlow;
  bool _joining = false, _joinUnavailable = false;
  String? _joinNotice;
  bool _loading = false, _error = false, _invalidated = false;
  int _generation = 0;

  bool get _current {
    if (!mounted ||
        _invalidated ||
        !identical(widget.runtime, _runtime) ||
        !_runtime.session.state.authenticated ||
        _runtime.session.state.epoch != _epoch ||
        _runtime.session.state.identity?.uid != _owner) {
      return false;
    }
    try {
      _page?.requireCurrent();
      _meeting?.requireCurrent();
      _participants?.requireCurrent();
      _joinFlow?.requireCurrent();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  void initState() {
    super.initState();
    _subscription = _runtime.session.states.listen((_) {
      if (!_current) _invalidate();
    });
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant TimewebMeetingsPageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.runtime, oldWidget.runtime) || widget.meetingId != oldWidget.meetingId) _invalidate();
  }

  void _invalidate() {
    if (!mounted || _invalidated) return;
    _invalidated = true;
    _generation++;
    _joinFlow?.close();
    _joinFlow = null;
    _joining = false;
    _joinUnavailable = false;
    _joinNotice = null;
    _page = null;
    _participants = null;
    _meeting = null;
    _filters = null;
    _countries = null;
    _country = _region = null;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route != null && route.isActive && !route.isFirst) Navigator.of(context).removeRoute(route);
    });
  }

  Future<void> _load({bool next = false, bool roster = false}) async {
    if (!_current || _loading) return;
    final cursor = next ? (roster ? _participants?.nextCursor : _page?.nextCursor) : null;
    if (next && cursor == null) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = false;
      if (!next) {
        if (roster) {
          _participants = null;
        } else {
          _page = null;
          _meeting = null;
          _participants = null;
        }
      }
    });
    try {
      if (roster) {
        final page = await _runtime.readMeetingParticipants(widget.meetingId!, cursor: cursor);
        if (!_current || generation != _generation) return;
        page.requireCurrent();
        setState(() => _participants = page);
      } else if (widget.meetingId != null) {
        final meeting = await _runtime.readMeeting(widget.meetingId!);
        if (!_current || generation != _generation) return;
        meeting.requireCurrent();
        setState(() => _meeting = meeting);
        if (_joinFlow == null && !_joinUnavailable && _runtime.meetingsEnabled) {
          final flow = await _runtime.openMeetingJoin(meeting.meetingId);
          if (!_current || generation != _generation) {
            flow.close();
            return;
          }
          flow.requireCurrent();
          setState(() => _joinFlow = flow);
        }
      } else {
        final countries = _countries ?? await GeoCatalog.load();
        if (!_current || generation != _generation) return;
        final filters = next
            ? _filters!
            : await TimewebMeetingFilters.fromCatalog(scope: _scope, countryCode: _country, region: _region);
        if (!_current || generation != _generation) return;
        final page = await _runtime.readMeetings(filters, cursor: cursor);
        if (!_current || generation != _generation) return;
        page.requireCurrent();
        setState(() {
          _countries = countries;
          _filters = filters;
          _page = page;
        });
      }
    } catch (_) {
      if (_current && generation == _generation) {
        setState(() {
          _error = true;
          if (_meeting != null && _joinFlow == null) _joinUnavailable = true;
        });
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _loading = false);
    }
  }

  Future<void> _open(String id) async {
    if (!_current || _loading) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        settings: const RouteSettings(name: timewebMeetingsRoute),
        builder: (_) => TimewebMeetingsPageView(runtime: _runtime, meetingId: id),
      ),
    );
  }

  Future<void> _join() async {
    final flow = _joinFlow;
    if (!_current || _loading || _joining || flow == null || flow.rejected || flow.receipt != null) return;
    setState(() {
      _joining = true;
      _joinNotice = null;
    });
    try {
      final outcome = flow.needsCheck ? await flow.check() : await flow.submit();
      if (!_current) return;
      flow.requireCurrent();
      if (outcome == TimewebMeetingJoinOutcome.confirmed) {
        final receipt = flow.receipt;
        if (receipt == null || receipt.meetingId != widget.meetingId) throw StateError('Missing join confirmation');
        receipt.requireCurrent();
        setState(
          () => _joinNotice = receipt.alreadyMember ? 'Вы уже участник этой встречи' : 'Вы присоединились к встрече',
        );
        // The flow returns confirmed only after durable original-intent ACK.
        await _load(roster: true);
      } else {
        setState(
          () => _joinNotice = outcome == TimewebMeetingJoinOutcome.rejected
              ? 'Присоединение отклонено.'
              : 'Подтверждение ещё не получено. Проверьте исходную операцию.',
        );
      }
    } catch (_) {
      if (_current) {
        setState(
          () => _joinNotice = flow.needsCheck
              ? 'Не удалось подтвердить присоединение. Проверьте исходную операцию.'
              : 'Присоединение пока недоступно.',
        );
      }
    } finally {
      if (_current) setState(() => _joining = false);
    }
  }

  Future<void> _selectScope() async {
    if (!_current || _loading) return;
    final overlay = _fieldsNavigator.currentState?.overlay;
    if (overlay == null) return;
    final value = await showMenu<String>(
      context: overlay.context,
      useRootNavigator: false,
      position: const RelativeRect.fromLTRB(16, 0, 160, 0),
      initialValue: _scope,
      items: [
        for (final scope in const ['group', 'individual'])
          PopupMenuItem(value: scope, child: Text(context.tr(scope == 'group' ? 'Групповые' : 'Индивидуальные'))),
      ],
    );
    if (!_current || _loading || value == null) return;
    setState(() => _scope = value);
    await _load();
  }

  @override
  void dispose() {
    _generation++;
    _joinFlow?.close();
    _joinFlow = null;
    _joining = false;
    _joinUnavailable = false;
    _joinNotice = null;
    _page = null;
    _meeting = null;
    _participants = null;
    _filters = null;
    _countries = null;
    _country = _region = null;
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClrsScaffold(
    backgroundAsset: 'assets/final_design/family_front.png',
    appBar: _bar(
      context,
      widget.meetingId == null ? 'Встречи' : 'О встрече',
      scopeControl: widget.meetingId == null
          ? IconButton(
              key: const ValueKey('native-meeting-scope'),
              tooltip: context.tr('Тип встречи'),
              onPressed: _current && !_loading ? _selectScope : null,
              icon: const Icon(Icons.menu),
            )
          : null,
      action: widget.meetingId == null
          ? OutlinedButton.icon(
              key: const ValueKey('native-meeting-create'),
              style: OutlinedButton.styleFrom(backgroundColor: const Color(0x4031241D)),
              onPressed: !_current || !_runtime.meetingCreationEnabled || _loading
                  ? null
                  : () => Navigator.of(
                      context,
                    ).push<void>(MaterialPageRoute(builder: (_) => MeetingForm(nativeRuntime: _runtime))),
              icon: const Icon(Icons.add),
              label: Text(context.tr('Создать'), maxLines: 2, overflow: TextOverflow.ellipsis),
            )
          : null,
    ),
    body: !_current
        ? Center(child: Text(context.tr('Сеанс завершён')))
        : NavigatorPopHandler<void>(
            onPopWithResult: (_) => _fieldsNavigator.currentState?.pop(),
            child: Navigator(
              key: _fieldsNavigator,
              pages: [MaterialPage<void>(child: _body())],
              onDidRemovePage: (_) {},
            ),
          ),
  );
  Widget _body() => ListView(
    key: const ValueKey('native-meetings-scroll'),
    padding: const EdgeInsets.all(16),
    children: [
      if (widget.meetingId == null) ...[
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('native-meeting-help'),
            icon: const Icon(Icons.help_outline),
            label: Text(context.tr('Как создать встречу')),
            onPressed: () => _fieldsNavigator.currentState?.push<void>(
              MaterialPageRoute(builder: (_) => const MeetingGuidePage(showLegacyNavigation: false)),
            ),
          ),
        ),
        SizedBox(height: (MediaQuery.sizeOf(context).height * .12).clamp(64, 112)),
        if (_countries != null)
          _locations(
            context,
            _countries!,
            _country,
            _region,
            (country, region) {
              setState(() {
                _country = country;
                _region = region;
              });
              unawaited(_load());
            },
            filter: true,
            enabled: !_loading,
          ),
        const SizedBox(height: 16),
        for (final meeting in _page?.items ?? <TimewebMeeting>[])
          _meetingCard(
            context,
            meeting,
            tap: () {
              meeting.requireCurrent();
              unawaited(_open(meeting.meetingId));
            },
          ),
        if (_page?.items.isEmpty == true)
          Text(
            context.tr(
              _page?.nextCursor == null
                  ? 'По выбранным параметрам встреч пока нет'
                  : 'На этой странице нет доступных встреч',
            ),
          ),
        if (_page?.nextCursor != null)
          TextButton(
            key: const ValueKey('native-meetings-next'),
            onPressed: _loading ? null : () => _load(next: true),
            child: Text(context.tr('Следующая страница')),
          ),
      ] else if (_meeting != null) ...[
        _meetingCard(context, _meeting!, full: true),
        _left(
          TextButton(
            key: const ValueKey('native-meeting-join'),
            onPressed: _loading || _joining || _joinFlow == null || _joinFlow!.rejected || _joinFlow!.receipt != null
                ? null
                : _join,
            child: Text(
              context.tr(
                _joinFlow?.receipt != null
                    ? (_joinFlow!.receipt!.alreadyMember ? 'Вы уже участник' : 'Вы участник')
                    : (_joinFlow?.needsCheck == true ? 'Проверить присоединение' : 'Присоединиться'),
              ),
            ),
          ),
        ),
        if (_joinNotice != null) _left(ClrsPanel(child: Text(context.tr(_joinNotice!)))),
        if (_joinUnavailable) _left(Text(context.tr('Присоединение пока недоступно.'))),
        if (_joining) const Center(child: CircularProgressIndicator()),
        TextButton(
          key: const ValueKey('native-meeting-participants'),
          onPressed: _loading || _joining ? null : () => _load(roster: true),
          child: Text(context.tr('Участники встречи')),
        ),
        for (final person in _participants?.items ?? <TimewebMeetingParticipant>[])
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _left(ClrsPanel(child: Text(person.fullName ?? context.tr('Имя не указано')))),
          ),
        if (_participants?.items.isEmpty == true)
          Text(
            context.tr(
              _participants?.nextCursor == null ? 'Участников пока нет' : 'На этой странице нет доступных участников',
            ),
          ),
        if (_participants?.nextCursor != null)
          TextButton(
            key: const ValueKey('native-participants-next'),
            onPressed: _loading || _joining ? null : () => _load(roster: true, next: true),
            child: Text(context.tr('Следующая страница')),
          ),
      ],
      if (_error) Text(context.tr('Не удалось загрузить данные. Обновите страницу.')),
      if (_loading) const Center(child: CircularProgressIndicator()),
      TextButton(
        key: const ValueKey('native-meetings-refresh'),
        onPressed: _loading || _joining ? null : () => _load(),
        child: Text(context.tr('Обновить')),
      ),
    ],
  );
}

/// Original durable intent is owned by the flow; widget errors never clear it.
class TimewebMeetingCreationView extends StatefulWidget {
  const TimewebMeetingCreationView({super.key, required this.runtime});
  final TimewebAppRuntime runtime;
  @override
  State<TimewebMeetingCreationView> createState() => _TimewebMeetingCreationViewState();
}

class _TimewebMeetingCreationViewState extends State<TimewebMeetingCreationView> {
  final _fieldsNavigator = GlobalKey<NavigatorState>();
  final _name = TextEditingController(), _description = TextEditingController();
  late final TimewebAppRuntime _runtime = widget.runtime;
  late final int _epoch = _runtime.session.state.epoch;
  late final String? _owner = _runtime.session.state.identity?.uid;
  StreamSubscription<AppSessionState>? _subscription;
  TimewebMeetingCreateFlow? _flow;
  BuildContext? _formContext;
  List<GeoCountry>? _countries;
  String? _country, _region, _invitee, _inviteeName, _notice;
  String _type = 'групповая', _date = _wallClock(DateTime.now());
  bool _busy = true, _invalidated = false;
  bool get _current {
    if (!mounted ||
        _invalidated ||
        !identical(widget.runtime, _runtime) ||
        !_runtime.session.state.authenticated ||
        _runtime.session.state.epoch != _epoch ||
        _runtime.session.state.identity?.uid != _owner) {
      return false;
    }
    try {
      _flow?.requireCurrent();
      return true;
    } catch (_) {
      return false;
    }
  }

  bool get _locked => _busy || _flow == null || _flow!.needsCheck || _flow!.rejected;
  @override
  void initState() {
    super.initState();
    _subscription = _runtime.session.states.listen((_) {
      if (!_current) _invalidate();
    });
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    try {
      final countries = await GeoCatalog.load();
      if (!_current) return;
      final flow = await _runtime.openMeetingCreation();
      if (!_current) {
        flow.close();
        return;
      }
      flow.requireCurrent();
      final pending = flow.pendingRequest?.fields;
      setState(() {
        _flow = flow;
        _countries = countries;
        _busy = false;
        if (pending != null) {
          _name.text = pending['name'] as String;
          _description.text = pending['description'] as String;
          _country = pending['countryCode'] as String;
          _region = pending['region'] as String;
          _date = pending['datetime'] as String;
          _type = pending['type'] as String;
          _invitee = pending['invitedUid'] as String?;
          _notice = 'Проверьте результат исходной операции без повторной отправки.';
        }
      });
    } catch (_) {
      if (_current) {
        setState(() {
          _busy = false;
          _notice = 'Не удалось восстановить создание встречи. Закройте форму и откройте снова.';
        });
      }
    }
  }

  void _invalidate() {
    if (!mounted || _invalidated) return;
    _invalidated = true;
    _flow?.close();
    _flow = null;
    _countries = null;
    _formContext = null;
    _name.clear();
    _description.clear();
    _country = _region = _invitee = _inviteeName = _notice = null;
    _date = '';
    _type = 'групповая';
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route != null && route.isActive && !route.isFirst) Navigator.of(context).removeRoute(route);
    });
  }

  @override
  void didUpdateWidget(covariant TimewebMeetingCreationView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.runtime, oldWidget.runtime)) _invalidate();
  }

  Future<void> _dateTime() async {
    final selected = parseMeetingDateTime(_date) ?? DateTime.now();
    final date = await showDatePicker(
      context: _formContext!,
      useRootNavigator: false,
      initialDate: selected,
      firstDate: DateTime(1),
      lastDate: DateTime(9999, 12, 31),
    );
    if (!_current || date == null) return;
    final time = await showTimePicker(
      context: _formContext!,
      useRootNavigator: false,
      initialTime: TimeOfDay.fromDateTime(selected),
    );
    if (!_current || time == null) return;
    setState(() => _date = _wallClock(DateTime(date.year, date.month, date.day, time.hour, time.minute)));
  }

  Future<void> _pickInvitee() async {
    final person = await Navigator.of(_formContext!).push<TimewebPublicPerson>(
      MaterialPageRoute(
        builder: (pickerContext) => TimewebPeoplePageView(
          runtime: _runtime,
          onSelected: (person) {
            person.requireCurrent();
            Navigator.of(pickerContext).pop(person);
          },
        ),
      ),
    );
    if (!_current || person == null) return;
    person.requireCurrent();
    if (person.uid == _owner) return;
    setState(() {
      _invitee = person.uid;
      _inviteeName = person.fullName;
    });
  }

  Future<void> _submit() async {
    if (!_current || _busy || _flow == null || _flow!.rejected) return;
    final flow = _flow!;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      final outcome = flow.needsCheck
          ? await flow.check()
          : await flow.submit(
              await TimewebMeetingCreateRequest.fromCatalog(
                name: _name.text,
                description: _description.text,
                countryCode: _country ?? '',
                region: _region ?? '',
                datetime: _date,
                type: _type,
                invitedUid: _type == 'индивидуальная' ? _invitee : null,
              ),
            );
      if (!mounted || !_current) return;
      flow.requireCurrent();
      if (outcome == TimewebMeetingCreateOutcome.confirmed) {
        final receipt = flow.receipt;
        if (receipt == null) throw StateError('Missing confirmation');
        receipt.requireCurrent();
        await Navigator.of(context).pushReplacement<void, void>(
          MaterialPageRoute(
            settings: const RouteSettings(name: timewebMeetingsRoute),
            builder: (_) => TimewebMeetingsPageView(runtime: _runtime, meetingId: receipt.meetingId),
          ),
        );
      } else {
        setState(
          () => _notice = outcome == TimewebMeetingCreateOutcome.rejected
              ? 'Создание встречи отклонено.'
              : 'Подтверждение ещё не получено. Проверьте исходную операцию.',
        );
      }
    } catch (_) {
      if (_current) {
        setState(
          () => _notice = flow.needsCheck
              ? 'Подтверждение ещё не получено. Проверьте исходную операцию.'
              : 'Проверьте название, страну, регион и получателя.',
        );
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _flow?.close();
    _flow = null;
    _countries = null;
    _formContext = null;
    _country = _region = _invitee = _inviteeName = _notice = null;
    _name.dispose();
    _description.dispose();
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClrsScaffold(
    backgroundAsset: 'assets/final_design/family_front.png',
    appBar: _bar(context, 'Создать встречу'),
    body: !_current
        ? Center(child: Text(context.tr('Сеанс завершён')))
        : NavigatorPopHandler<void>(
            onPopWithResult: (_) => _fieldsNavigator.currentState?.pop(),
            child: Navigator(
              key: _fieldsNavigator,
              pages: [
                MaterialPage<void>(
                  child: Builder(
                    builder: (context) {
                      _formContext = context;
                      return _body();
                    },
                  ),
                ),
              ],
              onDidRemovePage: (_) {},
            ),
          ),
  );
  Widget _body() => ListView(
    key: const ValueKey('native-meeting-form-scroll'),
    padding: const EdgeInsets.all(16),
    children: [
      AbsorbPointer(
        absorbing: _locked,
        child: Column(
          children: [
            TextField(
              key: const ValueKey('native-meeting-name'),
              controller: _name,
              maxLength: 1000,
              decoration: InputDecoration(labelText: context.tr('Название встречи')),
            ),
            if (_countries != null)
              _locations(
                context,
                _countries!,
                _country,
                _region,
                (country, region) => setState(() {
                  _country = country;
                  _region = region;
                }),
              ),
            TextField(
              key: const ValueKey('native-meeting-description'),
              controller: _description,
              maxLength: 4096,
              minLines: 2,
              maxLines: 6,
              decoration: InputDecoration(labelText: context.tr('Краткое описание встречи')),
            ),
            Text(_date),
            TextButton(onPressed: _dateTime, child: Text(context.tr('Выбрать дату и время'))),
            DropdownButtonFormField<String>(
              value: _type,
              decoration: InputDecoration(labelText: context.tr('Тип встречи')),
              isExpanded: true,
              items: [
                for (final type in const ['групповая', 'индивидуальная'])
                  DropdownMenuItem(
                    value: type,
                    child: Text(context.tr(type == 'групповая' ? 'Групповая' : 'Индивидуальная')),
                  ),
              ],
              onChanged: (value) => setState(() => _type = value!),
            ),
            if (_type == 'индивидуальная')
              TextButton(
                key: const ValueKey('native-meeting-invitee'),
                onPressed: _pickInvitee,
                child: Text(
                  _invitee == null
                      ? context.tr('Выберите получателя')
                      : (_inviteeName ?? context.tr('Получатель выбран')),
                ),
              ),
          ],
        ),
      ),
      if (_notice != null) ClrsPanel(child: Text(context.tr(_notice!))),
      if (_busy) const Center(child: CircularProgressIndicator()),
      TextButton(
        key: const ValueKey('native-meeting-submit'),
        onPressed: _busy || _flow == null || _flow!.rejected ? null : _submit,
        child: Text(context.tr(_flow?.needsCheck == true ? 'Проверить исходную операцию' : 'Создать')),
      ),
    ],
  );
}
