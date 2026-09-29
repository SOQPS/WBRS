import 'dart:convert';

import 'package:flutter/services.dart';

class GeoCountry {
  const GeoCountry({
    required this.code,
    required this.name,
    required this.englishName,
    required this.regionLabel,
    required this.regions,
    required this.languageGroup,
    required this.segment,
  });

  final String languageGroup;
  final String segment;
  final String code;
  final String name;
  final String englishName;
  final String regionLabel;
  final List<String> regions;

  factory GeoCountry.fromJson(Map<String, dynamic> json) {
    return GeoCountry(
      languageGroup: json['languageGroup']?.toString() ?? 'ru',
      segment: json['segment']?.toString() ?? '',
      code: json['code']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      englishName: json['englishName']?.toString() ?? '',
      regionLabel: json['regionLabel']?.toString() ?? 'Регион',
      regions: orderedRegions(
          json['code']?.toString(),
          (json['regions'] as List<dynamic>? ?? const <dynamic>[])
              .map((value) => value.toString())
              .where((value) => value.trim().isNotEmpty)
              .toList(growable: false)),
    );
  }

  static List<String> orderedRegions(
      String? countryCode, List<String> regions) {
    if (countryCode != 'RU') return regions;
    bool republic(String value) => value.toLowerCase().contains('республика');
    return [
      ...regions.where((r) => !republic(r)),
      ...regions.where((r) => republic(r) && r != 'Республика Дагестан'),
      if (regions.contains('Республика Дагестан')) 'Республика Дагестан',
    ];
  }
}

class GeoCatalog {
  GeoCatalog._();

  static List<GeoCountry>? _cache;

  static Future<List<GeoCountry>> load() async {
    if (_cache != null) return _cache!;
    final raw = await rootBundle.loadString('assets/geo_catalog.json');
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final countries = (decoded['countries'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(GeoCountry.fromJson)
        .toList(growable: false)
      ..sort((a, b) => a.name.compareTo(b.name));
    _cache = countries;
    return countries;
  }

  static GeoCountry? byCode(List<GeoCountry> countries, String? code) {
    if (code == null) return null;
    for (final country in countries) {
      if (country.code == code) return country;
    }
    return null;
  }
}
