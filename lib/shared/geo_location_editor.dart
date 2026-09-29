import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'geo_catalog.dart';

class GeoLocationEditor extends StatefulWidget {
  const GeoLocationEditor(
      {super.key, required this.uid, required this.onChanged});
  final String uid;
  final void Function(GeoCountry?, String?) onChanged;
  @override
  State<GeoLocationEditor> createState() => _GeoLocationEditorState();
}

class _GeoLocationEditorState extends State<GeoLocationEditor> {
  List<GeoCountry> _countries = [];
  GeoCountry? _country;
  String? _region;
  bool _loading = true;
  bool _failed = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final countries = await GeoCatalog.load();
      final profile = await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.uid)
          .get()
          .timeout(const Duration(seconds: 15));
      if (!mounted) return;
      final data = profile.data() ?? {};
      final country =
          GeoCatalog.byCode(countries, data['countryCode']?.toString());
      final region = (data['region'] ?? data['city'])?.toString();
      setState(() {
        _countries = countries;
        _country = country;
        _region = country?.regions.contains(region) == true ? region : null;
        _loading = false;
      });
      widget.onChanged(_country, _region);
    } catch (_) {
      if (mounted)
        setState(() {
          _loading = false;
          _failed = true;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading)
      return const Padding(
          padding: EdgeInsets.all(12), child: LinearProgressIndicator());
    if (_failed)
      return TextButton(
          onPressed: _load,
          child: Text(
              context.tr('Не удалось загрузить страну и регион. Повторить')));
    return Column(children: [
      DropdownButtonFormField<String>(
          value: _country?.code,
          isExpanded: true,
          decoration: InputDecoration(labelText: context.tr('Страна')),
          items: _countries
              .map((c) => DropdownMenuItem(
                  value: c.code,
                  child: Text(context.tr(c.name),
                      overflow: TextOverflow.ellipsis)))
              .toList(),
          onChanged: (code) {
            setState(() {
              _country = GeoCatalog.byCode(_countries, code);
              _region = null;
            });
            widget.onChanged(_country, _region);
          }),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
          key: ValueKey(_country?.code),
          value: _region,
          isExpanded: true,
          decoration: InputDecoration(labelText: context.tr('Регион')),
          items: (_country?.regions ?? [])
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
