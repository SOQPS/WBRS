import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/app/helper/helper_function.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/presentation/screens/list_of_users/profiles_list.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/geo_catalog.dart';
import 'package:wbrs/shared/lrs_theme.dart';

class FilterPage extends StatelessWidget {
  const FilterPage({super.key});
  @override
  Widget build(BuildContext context) => ClrsScaffold(
      appBar: AppBar(title: Text(context.tr('Фильтр'))),
      body: const SingleChildScrollView(
          padding: EdgeInsets.all(14),
          child: Column(children: [
            ClrsBrandHeader(),
            FilterPage2(initiallyExpanded: true)
          ])));
}

class FilterPage2 extends StatefulWidget {
  const FilterPage2(
      {super.key,
      this.initiallyExpanded = false,
      this.loadGroup,
      this.onApplied});
  final bool initiallyExpanded;
  final Future<String> Function()? loadGroup;
  final ValueChanged<String>? onApplied;
  @override
  State<FilterPage2> createState() => _FilterPage2State();
}

class _FilterPage2State extends State<FilterPage2> {
  final _ageStart = TextEditingController(), _ageEnd = TextEditingController();
  late final String? _owner = firebaseAuth.currentUser?.uid;
  List<GeoCountry> _countries = const [];
  String? _countryCode, _region, _error;
  late String _gender = filtrPol;
  late bool _matches = filterByGroup, _expanded = widget.initiallyExpanded;
  bool _busy = false, _geoLoading = true, _geoFailed = false;
  GeoCountry? get _country => GeoCatalog.byCode(_countries, _countryCode);
  bool get _active =>
      mounted && _owner != null && firebaseAuth.currentUser?.uid == _owner;
  @override
  void initState() {
    super.initState();
    _ageStart.text = '$ageStart';
    _ageEnd.text = '$ageEnd';
    _loadGeo();
  }

  Future<void> _loadGeo() async {
    setState(() {
      _geoLoading = true;
      _geoFailed = false;
    });
    try {
      final countries =
          await GeoCatalog.load().timeout(const Duration(seconds: 15));
      if (!mounted) return;
      GeoCountry? selected;
      for (final item in countries) {
        if (item.name == filterCountry.text) {
          selected = item;
          break;
        }
      }
      setState(() {
        _countries = countries;
        _countryCode = selected?.code;
        _region = selected?.regions.contains(filterRegion.text) == true
            ? filterRegion.text
            : null;
      });
    } catch (_) {
      if (mounted) setState(() => _geoFailed = true);
    } finally {
      if (mounted) setState(() => _geoLoading = false);
    }
  }

  @override
  void dispose() {
    _ageStart.dispose();
    _ageEnd.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: ClrsPanel(
          padding: EdgeInsets.zero,
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            InkWell(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.tune, color: LrsTheme.peach),
                          const SizedBox(width: 10),
                          Expanded(
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                Text(context.tr('Фильтры поиска'),
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w700)),
                                const SizedBox(height: 3),
                                Text(_summary(),
                                    style: const TextStyle(
                                        color: LrsTheme.muted, fontSize: 11)),
                              ])),
                          Icon(_expanded
                              ? Icons.expand_less
                              : Icons.expand_more),
                        ]))),
            if (_expanded)
              Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        AbsorbPointer(
                            absorbing: _busy,
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Wrap(spacing: 6, runSpacing: 6, children: [
                                    for (final item in [
                                      ('Все', ''),
                                      ('Мужчины', 'м'),
                                      ('Женщины', 'ж')
                                    ])
                                      ChoiceChip(
                                          backgroundColor:
                                              const Color(0x4431241D),
                                          selectedColor: item.$2.isEmpty
                                              ? const Color(0x8831241D)
                                              : LrsTheme.actionGlass,
                                          side: BorderSide(
                                              color: _gender == item.$2
                                                  ? LrsTheme.peachLight
                                                  : LrsTheme.actionBorder),
                                          label: Text(context.tr(item.$1)),
                                          labelStyle: TextStyle(
                                              color: _gender == item.$2
                                                  ? LrsTheme.peachLight
                                                  : LrsTheme.text,
                                              fontWeight: item.$2.isEmpty
                                                  ? FontWeight.w700
                                                  : FontWeight.w600),
                                          checkmarkColor: LrsTheme.peachLight,
                                          showCheckmark:
                                              item.$2.isEmpty ? false : null,
                                          selected: _gender == item.$2,
                                          onSelected: (_) =>
                                              setState(() => _gender = item.$2))
                                  ]),
                                  const SizedBox(height: 12),
                                  Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Expanded(
                                            child: _ageField(
                                                _ageStart, 'Возраст от')),
                                        const SizedBox(width: 10),
                                        Expanded(
                                            child: _ageField(
                                                _ageEnd, 'Возраст до'))
                                      ]),
                                  const SizedBox(height: 12),
                                  if (_geoLoading)
                                    const LinearProgressIndicator(),
                                  if (_geoFailed) ...[
                                    Text(context.tr(
                                        'Не удалось загрузить страны и регионы')),
                                    TextButton(
                                        onPressed: _loadGeo,
                                        child: Text(context.tr('Повторить')))
                                  ],
                                  _dropdown(
                                      'Страна',
                                      Icons.public,
                                      DropdownButtonFormField<String>(
                                          value: _countryCode,
                                          isExpanded: true,
                                          decoration: InputDecoration(
                                              hintText: context.tr('Любая')),
                                          items: [
                                            DropdownMenuItem(
                                                value: '',
                                                child:
                                                    Text(context.tr('Любая'))),
                                            ..._countries.map((c) =>
                                                DropdownMenuItem(
                                                    value: c.code,
                                                    child: Text(
                                                        context.tr(c.name),
                                                        overflow: TextOverflow
                                                            .ellipsis)))
                                          ],
                                          onChanged: _geoLoading || _geoFailed
                                              ? null
                                              : (v) => setState(() {
                                                    _countryCode =
                                                        v == null || v.isEmpty
                                                            ? null
                                                            : v;
                                                    _region = null;
                                                  }))),
                                  const SizedBox(height: 12),
                                  _dropdown(
                                      'Регион',
                                      Icons.map_outlined,
                                      DropdownButtonFormField<String>(
                                          value: _region,
                                          isExpanded: true,
                                          decoration: InputDecoration(
                                              hintText: context.tr('Любой')),
                                          items: [
                                            DropdownMenuItem(
                                                value: '',
                                                child:
                                                    Text(context.tr('Любой'))),
                                            ...(_country?.regions ??
                                                    const <String>[])
                                                .map((r) => DropdownMenuItem(
                                                    value: r,
                                                    child: Text(r,
                                                        overflow: TextOverflow
                                                            .ellipsis)))
                                          ],
                                          onChanged: _country == null
                                              ? null
                                              : (v) => setState(() => _region =
                                                  v == null || v.isEmpty
                                                      ? null
                                                      : v))),
                                  const SizedBox(height: 4),
                                  CheckboxListTile(
                                      contentPadding: EdgeInsets.zero,
                                      controlAffinity:
                                          ListTileControlAffinity.leading,
                                      value: _matches,
                                      title: Text(context
                                          .tr('Показывать подходящие группы')),
                                      onChanged: (v) => setState(
                                          () => _matches = v ?? false)),
                                ])),
                        if (_error != null)
                          Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Text(context.tr(_error!))),
                        if (_busy) const LinearProgressIndicator(),
                        Wrap(
                            spacing: 10,
                            runSpacing: 8,
                            alignment: WrapAlignment.end,
                            children: [
                              OutlinedButton(
                                  style: OutlinedButton.styleFrom(
                                      backgroundColor: LrsTheme.actionGlass),
                                  onPressed:
                                      _busy ? null : () => _apply(reset: true),
                                  child: Text(context.tr('Сбросить'))),
                              FilledButton(
                                  style: FilledButton.styleFrom(
                                      backgroundColor: LrsTheme.actionGlass,
                                      foregroundColor: LrsTheme.text,
                                      disabledBackgroundColor:
                                          LrsTheme.actionDisabled),
                                  onPressed: _busy || _geoLoading || _geoFailed
                                      ? null
                                      : () => _apply(),
                                  child: Text(context.tr('Применить'))),
                            ]),
                      ])),
          ])));
  String _summary() {
    final place = [context.tr(filterCountry.text), filterRegion.text]
        .where((v) => v.isNotEmpty)
        .join(' · ');
    final gender = context.tr(filtrPol == 'м'
        ? 'Мужчины'
        : filtrPol == 'ж'
            ? 'Женщины'
            : 'Все');
    return '${place.isEmpty ? context.tr('Все регионы') : place} · $gender · ${context.l10n.number(ageStart)}–${context.l10n.number(ageEnd)}';
  }

  Widget _ageField(TextEditingController controller, String label) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(context.tr(label),
            style: const TextStyle(fontSize: 12, color: LrsTheme.peachLight)),
        const SizedBox(height: 5),
        TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            maxLength: 3,
            decoration: const InputDecoration(counterText: '')),
      ]);
  Widget _dropdown(String label, IconData icon, Widget field) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(icon, size: 18),
          const SizedBox(width: 7),
          Expanded(child: Text(context.tr(label)))
        ]),
        const SizedBox(height: 5),
        field,
      ]);
  Future<void> _apply({bool reset = false}) async {
    if (_busy) return;
    if (!_active) {
      setState(() => _error = 'Сеанс завершён. Войдите снова.');
      return;
    }
    final start =
        reset ? 18 : (int.tryParse(_ageStart.text) ?? 18).clamp(18, 100);
    final end =
        reset ? 100 : (int.tryParse(_ageEnd.text) ?? 100).clamp(start, 100);
    final country = reset ? '' : _country?.name ?? '',
        region = reset ? '' : _region ?? '';
    final gender = reset ? '' : _gender, matches = reset ? false : _matches;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final userGroup = await (widget.loadGroup?.call() ??
              Future<String>.sync(() async => '${await getUserGroup()}'))
          .timeout(const Duration(seconds: 15));
      if (!_active) return;
      // Publish a complete filter only after the required read succeeds. A
      // failure preserves the draft and the active results; no partial globals.
      ageStart = start;
      ageEnd = end;
      filtrPol = gender;
      filterByGroup = matches;
      filterCountry.text = country;
      filterRegion.text = region;
      filterCity.text = region;
      if (widget.onApplied != null) {
        widget.onApplied!(userGroup);
      } else if (mounted) {
        Navigator.pushReplacement(
            context,
            MaterialPageRoute(
                builder: (_) =>
                    ProfilesList(startPosition: 0, group: userGroup)));
      }
    } catch (_) {
      if (_active) {
        setState(() => _error =
            'Не удалось загрузить профиль. Проверьте соединение и повторите попытку.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
