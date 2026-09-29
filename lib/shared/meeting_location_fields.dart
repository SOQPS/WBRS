import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:flutter/material.dart';
import 'geo_catalog.dart';

class MeetingLocationFields extends StatefulWidget {
  const MeetingLocationFields(
      {super.key, this.countryCode, this.region, required this.onChanged});
  final String? countryCode, region;
  final void Function(GeoCountry?, String?) onChanged;
  @override
  State<MeetingLocationFields> createState() => _MeetingLocationFieldsState();
}

class _MeetingLocationFieldsState extends State<MeetingLocationFields> {
  List<GeoCountry>? _countries;
  GeoCountry? _country;
  String? _region;
  bool _failed = false;
  bool _loading = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final countries = await GeoCatalog.load();
      if (!mounted) return;
      setState(() {
        _countries = countries;
        _country = GeoCatalog.byCode(countries, widget.countryCode);
        _region = _country?.regions.contains(widget.region) == true
            ? widget.region
            : null;
        _failed = false;
        _loading = false;
      });
      widget.onChanged(_country, _region);
    } catch (_) {
      if (mounted)
        setState(() {
          _failed = true;
          _loading = false;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_failed)
      return TextButton(
          onPressed: _load,
          child: Text(context.tr('Повторить загрузку стран')));
    if (_countries == null) return const LinearProgressIndicator();
    return Column(children: [
      DropdownButtonFormField<String>(
          value: _country?.code,
          isExpanded: true,
          decoration: InputDecoration(labelText: context.tr('Страна')),
          items: _countries!
              .map((c) => DropdownMenuItem(
                  value: c.code,
                  child: Text(context.tr(c.name),
                      maxLines: 1, overflow: TextOverflow.ellipsis)))
              .toList(),
          onChanged: (code) {
            setState(() {
              _country = GeoCatalog.byCode(_countries!, code);
              _region = null;
            });
            widget.onChanged(_country, _region);
          }),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
          key: ValueKey(_country?.code),
          value: _region,
          isExpanded: true,
          decoration: InputDecoration(
              labelText: context.tr(_country?.regionLabel ?? 'Регион')),
          items: (_country?.regions ?? <String>[])
              .map((r) => DropdownMenuItem(
                  value: r, child: Text(r, overflow: TextOverflow.ellipsis)))
              .toList(),
          onChanged: _country == null
              ? null
              : (region) {
                  setState(() => _region = region);
                  widget.onChanged(_country, _region);
                }),
    ]);
  }
}
