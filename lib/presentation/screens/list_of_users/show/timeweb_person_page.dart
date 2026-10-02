import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/service/timeweb_auth_client.dart';
import 'package:wbrs/shared/clrs_brand.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/group_avatar.dart';
import 'package:wbrs/shared/lrs_theme.dart';

const timewebPersonRoute = '/timeweb/person';

/// Public current fields only. No presence badge, private source map, gallery,
/// financial/admin controls or Firebase conversation creation is inferred.
class TimewebPersonPage extends StatefulWidget {
  const TimewebPersonPage({
    super.key,
    required this.runtime,
    required this.uid,
  });
  final TimewebAppRuntime runtime;
  final String uid;
  @override
  State<TimewebPersonPage> createState() => _TimewebPersonPageState();
}

class _TimewebPersonPageState extends State<TimewebPersonPage> {
  StreamSubscription<AppSessionState>? _subscription;
  late final int _epoch;
  TimewebPublicPerson? _person;
  String? _target;
  int _generation = 0;
  bool _loading = false, _error = false, _missing = false, _invalidated = false;
  @override
  void initState() {
    super.initState();
    _epoch = widget.runtime.session.state.epoch;
    _target = widget.uid;
    _subscription = widget.runtime.session.states.listen((_) {
      if (!_current) _invalidate();
    });
    unawaited(_reload());
  }

  bool get _current {
    final state = widget.runtime.session.state;
    if (!mounted ||
        _invalidated ||
        !state.authenticated ||
        state.epoch != _epoch) {
      return false;
    }
    try {
      _person?.requireCurrent();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _invalidate() {
    if (!mounted || _invalidated) {
      return;
    }
    _invalidated = true;
    _generation++;
    _person = null;
    _target = null;
    _loading = _error = _missing = false;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route != null && route.isActive && !route.isFirst) {
        Navigator.of(context).removeRoute(route);
      }
    });
  }

  Future<void> _reload() async {
    if (!_current || _loading || _target == null) {
      return;
    }
    final generation = ++_generation, uid = _target!;
    setState(() {
      _person = null;
      _loading = true;
      _error = _missing = false;
    });
    try {
      final person = await widget.runtime.readPerson(uid);
      if (!_current || generation != _generation) return;
      person.requireCurrent();
      setState(() => _person = person);
    } on TimewebPersonNotFound {
      if (_current && generation == _generation) {
        setState(() => _missing = true);
      }
    } catch (_) {
      if (_current && generation == _generation) {
        setState(() => _error = true);
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    _person = null;
    _target = null;
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  String _text(Object? value) =>
      value == null || value == '' ? context.tr('Не указано') : '$value';
  @override
  Widget build(BuildContext context) {
    final person = _current ? _person : null;
    return ClrsScaffold(
      key: const ValueKey('timeweb-public-profile'),
      appBar: AppBar(
        title: const ClrsLogo(size: 34),
        actions: [
          IconButton(
            key: const ValueKey('timeweb-person-refresh'),
            tooltip: context.tr('Обновить'),
            onPressed: _current && !_loading ? _reload : null,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
        children: [
          const Align(
            alignment: Alignment.centerRight,
            child: ClrsMotto(size: 18),
          ),
          if (_loading) const LinearProgressIndicator(),
          if (!_current) Text(context.tr('Сеанс завершён')),
          if (_missing || _error)
            ClrsPanel(
              child: Column(
                children: [
                  Text(
                    context.tr(
                      _missing
                          ? 'Профиль недоступен'
                          : 'Не удалось загрузить пользователей',
                    ),
                  ),
                  if (_error)
                    TextButton(
                      key: const ValueKey('timeweb-person-retry'),
                      onPressed: _reload,
                      child: Text(context.tr('Повторить')),
                    ),
                ],
              ),
            ),
          if (person != null) ...[
            SizedBox(
              height: (MediaQuery.sizeOf(context).width * .62).clamp(190, 300),
              child: Center(
                child: GroupAvatar(
                  url: '',
                  group: person.primaryGroup ?? '',
                  size: 90,
                ),
              ),
            ),
            Text(
              context.tr('Фото профиля'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: LrsTheme.muted),
            ),
            const SizedBox(height: 10),
            Text(
              _text(person.fullName),
              key: const ValueKey('timeweb-public-name'),
              style: const TextStyle(fontSize: 27, fontWeight: FontWeight.w700),
            ),
            _section(
              'Обо мне',
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final fact in <(String, Object?)>[
                    ('Возраст', person.age),
                    ('Рост', person.rost),
                    ('Пол', person.pol),
                    ('Статус', person.relationStatus),
                    (
                      'Дети',
                      person.deti == null
                          ? null
                          : context.tr(person.deti! ? 'Есть' : 'Нет'),
                    ),
                    ('Страна', person.country),
                    ('Регион', person.region),
                    ('Город', person.city),
                    ('Группа', person.primaryGroup),
                    ('Дополнительная группа', person.secondaryGroup),
                  ])
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            context.tr(fact.$1),
                            style: const TextStyle(
                              fontSize: 11,
                              color: LrsTheme.peachLight,
                            ),
                          ),
                          Text(_text(fact.$2)),
                        ],
                      ),
                    ),
                  Text(
                    context.tr(
                      'Последнее посещение: {date}',
                      args: {'date': _text(person.lastOnlineAt)},
                    ),
                  ),
                ],
              ),
            ),
            _section(
              'Фотографии',
              Text(context.tr('Сервис пока недоступен. Попробуйте позднее.')),
            ),
            _section('Интересы и увлечения', Text(_text(person.hobbi))),
            _section('О себе', Text(_text(person.about))),
            const ClrsValuesFooter(),
          ],
        ],
      ),
    );
  }

  Widget _section(String title, Widget child) => Padding(
    padding: const EdgeInsets.only(top: 14),
    child: Container(
      decoration: BoxDecoration(
        color: const Color(0xCC302110),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0x66E7B092), width: .8),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            context.tr(title),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    ),
  );
}
