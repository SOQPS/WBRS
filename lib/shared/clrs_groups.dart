import 'package:flutter/material.dart';
Color clrsGroupColor(String group) {
  final value = group.toLowerCase();
  if (value.contains('крас')) return const Color(0xFFD75247);
  if (value.contains('син')) return const Color(0xFF3E7FD8);
  if (value.contains('бел')) return const Color(0xFFF2EEE7);
  if (value.contains('корич')) return const Color(0xFF9A6A43);
  return const Color(0xFFE7B092);
}

