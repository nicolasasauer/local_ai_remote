import 'package:flutter/material.dart';

/// Farben tragen hier Bedeutung, nicht Dekoration:
/// Bernstein = etwas liegt im Speicher, Tuerkis = laufende Messung,
/// Rot = Fehler, Grau = kalt oder unbekannt.
class Tone {
  static const base = Color(0xFF0F1418);
  static const surface = Color(0xFF161C21);
  static const raised = Color(0xFF1D252B);
  static const hairline = Color(0xFF232B32);

  static const ink = Color(0xFFE4EAED);
  static const muted = Color(0xFF7D8B94);
  static const faint = Color(0xFF4A565E);

  static const amber = Color(0xFFE9A13B);
  static const teal = Color(0xFF4FC3B0);
  static const alert = Color(0xFFE2574C);
  static const violet = Color(0xFF9A8CD8);
}

/// Monospace nur fuer Live-Zahlen: bei 1 Hz Aktualisierung springt eine
/// Proportionalschrift bei jeder Ziffernaenderung in der Breite.
const kMono = TextStyle(
  fontFamily: 'monospace',
  fontFamilyFallback: ['Consolas', 'DejaVu Sans Mono', 'Menlo', 'monospace'],
  fontFeatures: [FontFeature.tabularFigures()],
);

ThemeData buildTheme() {
  const scheme = ColorScheme.dark(
    primary: Tone.teal,
    onPrimary: Tone.base,
    secondary: Tone.amber,
    onSecondary: Tone.base,
    surface: Tone.surface,
    onSurface: Tone.ink,
    error: Tone.alert,
    onError: Tone.ink,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: Tone.base,
    canvasColor: Tone.base,
    dividerColor: Tone.hairline,
    dividerTheme: const DividerThemeData(
      color: Tone.hairline,
      thickness: 1,
      space: 1,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Tone.base,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: Tone.ink,
        fontSize: 17,
        fontWeight: FontWeight.w600,
      ),
    ),
    textTheme: const TextTheme(
      titleMedium: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      bodyMedium: TextStyle(fontSize: 14, height: 1.45),
      bodySmall: TextStyle(fontSize: 12.5, color: Tone.muted, height: 1.4),
      labelSmall: TextStyle(fontSize: 11.5, color: Tone.muted),
    ),
    listTileTheme: const ListTileThemeData(
      textColor: Tone.ink,
      iconColor: Tone.muted,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Tone.raised,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Tone.hairline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Tone.hairline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Tone.teal, width: 1.5),
      ),
      isDense: true,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Tone.surface,
      indicatorColor: Tone.teal.withValues(alpha: 0.16),
      surfaceTintColor: Colors.transparent,
      height: 62,
      labelTextStyle: const WidgetStatePropertyAll(
        TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: Tone.surface,
      indicatorColor: Tone.teal.withValues(alpha: 0.16),
      selectedIconTheme: const IconThemeData(color: Tone.teal),
      unselectedIconTheme: const IconThemeData(color: Tone.muted),
      selectedLabelTextStyle: const TextStyle(color: Tone.ink, fontSize: 12),
      unselectedLabelTextStyle: const TextStyle(color: Tone.muted, fontSize: 12),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: Tone.raised,
      contentTextStyle: const TextStyle(color: Tone.ink),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: Tone.raised,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: Tone.hairline),
      ),
      textStyle: const TextStyle(fontSize: 13.5, color: Tone.ink),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Tone.raised,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Tone.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: Tone.faint,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: Tone.raised,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Tone.hairline),
      ),
      textStyle: const TextStyle(fontSize: 12, color: Tone.ink),
      waitDuration: const Duration(milliseconds: 500),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(Tone.faint.withValues(alpha: 0.6)),
      radius: const Radius.circular(4),
      thickness: const WidgetStatePropertyAll(6),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        side: const BorderSide(color: Tone.hairline),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
      ),
    ),
    drawerTheme: const DrawerThemeData(
      backgroundColor: Tone.surface,
      surfaceTintColor: Colors.transparent,
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
      },
    ),
  );
}
