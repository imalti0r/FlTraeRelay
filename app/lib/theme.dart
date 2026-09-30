// theme.dart - Material 3 主题：以 Trae 品牌青绿为种子色，含亮/暗两套。

import 'package:flutter/material.dart';

const seedColor = Color(0xFF0B9E83);

ThemeData buildLightTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: seedColor);
  return _base(scheme, Brightness.light);
}

ThemeData buildDarkTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: seedColor, brightness: Brightness.dark);
  return _base(scheme, Brightness.dark);
}

ThemeData _base(ColorScheme scheme, Brightness brightness) {
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: brightness,
    cardTheme: CardThemeData(
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      color: scheme.surfaceContainerLow,
      margin: const EdgeInsets.symmetric(vertical: 8),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      isDense: true,
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}
