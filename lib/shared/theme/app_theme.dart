import 'package:flutter/material.dart';

class LatchColors {
  static const background = Color(0xFFF5F3EF);
  static const ink = Color(0xFF2A2723);
  static const muted = Color(0xFF6B665D);
  static const subtle = Color(0xFF6F6A61);
  static const border = Color(0xFFD8D2C6);
  static const safe = Color(0xFF2D6B54);
  static const safeLight = Color(0xFFEAF5F0);
  static const safeBorder = Color(0xFFBFE0D2);
  static const caution = Color(0xFF8B5A0E);
  static const cautionLight = Color(0xFFFBF3E4);
  static const danger = Color(0xFFC13B2F);
  static const dangerLight = Color(0xFFFBEEEC);
  static const accent = Color(0xFF2A2723);
  static const cardSurface = Color(0xFFFFFFFF);
}

ThemeData buildTheme() {
  return ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: LatchColors.ink,
      brightness: Brightness.light,
      surface: LatchColors.background,
    ),
    scaffoldBackgroundColor: LatchColors.background,
    fontFamily: 'sans-serif',
    textTheme: const TextTheme(
      displayLarge: TextStyle(
        fontSize: 32,
        fontWeight: FontWeight.w700,
        color: LatchColors.ink,
        height: 1.1,
      ),
      displayMedium: TextStyle(
        fontSize: 26,
        fontWeight: FontWeight.w700,
        color: LatchColors.ink,
        height: 1.15,
      ),
      headlineMedium: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        color: LatchColors.ink,
      ),
      titleLarge: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: LatchColors.ink,
      ),
      bodyLarge: TextStyle(fontSize: 16, color: LatchColors.ink, height: 1.45),
      bodyMedium: TextStyle(fontSize: 14, color: LatchColors.muted, height: 1.4),
      bodySmall: TextStyle(fontSize: 13, color: LatchColors.subtle),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: LatchColors.background,
      foregroundColor: LatchColors.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(
        fontWeight: FontWeight.w700,
        fontSize: 20,
        color: LatchColors.ink,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: LatchColors.ink,
        foregroundColor: Colors.white,
        minimumSize: const Size(double.infinity, 54),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        elevation: 0,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: LatchColors.ink,
        minimumSize: const Size(double.infinity, 54),
        side: const BorderSide(color: LatchColors.ink, width: 2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: false,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: LatchColors.ink, width: 2),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: LatchColors.ink, width: 2),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: LatchColors.ink, width: 2),
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      side: const BorderSide(color: LatchColors.danger, width: 2),
      fillColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return LatchColors.danger;
        return Colors.transparent;
      }),
    ),
  );
}
