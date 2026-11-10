import 'package:flutter/material.dart';

class AppColors {
  static const bg = Color(0xFF0E0F14);
  static const panel = Color(0xFF171922);
  static const panel2 = Color(0xFF1F2230);
  static const line = Color(0xFF2B2F40);
  static const accent = Color(0xFF7C5CFF);
  static const accent2 = Color(0xFFA78BFA);
  static const ok = Color(0xFF2ECC71);
  static const warn = Color(0xFFF5A623);
  static const bad = Color(0xFFFF4D5E);
  static const dim = Color(0xFF8D93A8);
  static const night = Color(0xFF2B3A67);
  static const day = Color(0xFF8A6F1C);
}

class AppTheme {
  static ThemeData dark() {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: AppColors.bg,
      colorScheme: base.colorScheme.copyWith(
        primary: AppColors.accent,
        secondary: AppColors.accent2,
        surface: AppColors.panel,
        error: AppColors.bad,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.panel,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.accent,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(50),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(48),
          side: const BorderSide(color: AppColors.line),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.panel2,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.accent),
        ),
        labelStyle: const TextStyle(color: AppColors.dim),
      ),
      dividerColor: AppColors.line,
    );
  }
}

/// Разбор цвета из hex-строки вида #RRGGBB.
Color colorFromHex(String hex) {
  var value = hex.replaceAll('#', '');
  if (value.length == 6) value = 'FF$value';
  final parsed = int.tryParse(value, radix: 16);
  return parsed == null ? AppColors.dim : Color(parsed);
}

String formatTime(int seconds) {
  if (seconds < 0) seconds = 0;
  final m = (seconds ~/ 60).toString().padLeft(2, '0');
  final s = (seconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}
