import 'package:flutter/material.dart';

@immutable
class HeatWatchColors extends ThemeExtension<HeatWatchColors> {
  const HeatWatchColors({
    required this.skyTop,
    required this.skyMid,
    required this.skyBottom,
    required this.skyGlow,
    required this.heroStart,
    required this.heroMid,
    required this.heroEnd,
    required this.cardSurface,
    required this.subtleSurface,
    required this.cardBorder,
    required this.cardShadow,
    required this.ink,
    required this.muted,
    required this.blue,
    required this.turquoise,
    required this.safe,
    required this.caution,
    required this.danger,
    required this.offline,
    required this.chartGrid,
    required this.navSurface,
    required this.navIndicator,
  });

  final Color skyTop;
  final Color skyMid;
  final Color skyBottom;
  final Color skyGlow;
  final Color heroStart;
  final Color heroMid;
  final Color heroEnd;
  final Color cardSurface;
  final Color subtleSurface;
  final Color cardBorder;
  final Color cardShadow;
  final Color ink;
  final Color muted;
  final Color blue;
  final Color turquoise;
  final Color safe;
  final Color caution;
  final Color danger;
  final Color offline;
  final Color chartGrid;
  final Color navSurface;
  final Color navIndicator;

  static const light = HeatWatchColors(
    skyTop: Color(0xFFE3F1FE),
    skyMid: Color(0xFFEDF6FD),
    skyBottom: Color(0xFFEAF9F9),
    skyGlow: Color(0xCCFFFFFF),
    heroStart: Color(0xFF155EEF),
    heroMid: Color(0xFF0E7490),
    heroEnd: Color(0xFF0C356A),
    cardSurface: Color(0xFFFFFFFF),
    subtleSurface: Color(0xFFF3F8FE),
    cardBorder: Color(0xFFD6E6F6),
    cardShadow: Color(0x140F4C81),
    ink: Color(0xFF0F2942),
    muted: Color(0xFF5B7591),
    blue: Color(0xFF155EEF),
    turquoise: Color(0xFF0EA5A4),
    safe: Color(0xFF0D9488),
    caution: Color(0xFFD97706),
    danger: Color(0xFFDC2626),
    offline: Color(0xFF64748B),
    chartGrid: Color(0xFFE5EFF8),
    navSurface: Color(0xFFFFFFFF),
    navIndicator: Color(0xFFDCEBFF),
  );

  static const dark = HeatWatchColors(
    skyTop: Color(0xFF0B1221),
    skyMid: Color(0xFF0E1729),
    skyBottom: Color(0xFF0A1626),
    skyGlow: Color(0x3D0EA5A4),
    heroStart: Color(0xFF155EEF),
    heroMid: Color(0xFF0E84B5),
    heroEnd: Color(0xFF0EA5A4),
    cardSurface: Color(0xFF131D31),
    subtleSurface: Color(0xFF192640),
    cardBorder: Color(0xFF233352),
    cardShadow: Color(0x55000000),
    ink: Color(0xFFF3F7FD),
    muted: Color(0xFF93A8C3),
    blue: Color(0xFF3B82F6),
    turquoise: Color(0xFF2DD4BF),
    safe: Color(0xFF2DD4BF),
    caution: Color(0xFFFBBF24),
    danger: Color(0xFFFB7185),
    offline: Color(0xFF8B9DB5),
    chartGrid: Color(0xFF223454),
    navSurface: Color(0xFF0D1526),
    navIndicator: Color(0xFF182A48),
  );

  static HeatWatchColors of(BuildContext context) =>
      Theme.of(context).extension<HeatWatchColors>() ??
      (Theme.of(context).brightness == Brightness.dark ? dark : light);

  @override
  HeatWatchColors copyWith({
    Color? skyTop,
    Color? skyMid,
    Color? skyBottom,
    Color? skyGlow,
    Color? heroStart,
    Color? heroMid,
    Color? heroEnd,
    Color? cardSurface,
    Color? subtleSurface,
    Color? cardBorder,
    Color? cardShadow,
    Color? ink,
    Color? muted,
    Color? blue,
    Color? turquoise,
    Color? safe,
    Color? caution,
    Color? danger,
    Color? offline,
    Color? chartGrid,
    Color? navSurface,
    Color? navIndicator,
  }) => HeatWatchColors(
    skyTop: skyTop ?? this.skyTop,
    skyMid: skyMid ?? this.skyMid,
    skyBottom: skyBottom ?? this.skyBottom,
    skyGlow: skyGlow ?? this.skyGlow,
    heroStart: heroStart ?? this.heroStart,
    heroMid: heroMid ?? this.heroMid,
    heroEnd: heroEnd ?? this.heroEnd,
    cardSurface: cardSurface ?? this.cardSurface,
    subtleSurface: subtleSurface ?? this.subtleSurface,
    cardBorder: cardBorder ?? this.cardBorder,
    cardShadow: cardShadow ?? this.cardShadow,
    ink: ink ?? this.ink,
    muted: muted ?? this.muted,
    blue: blue ?? this.blue,
    turquoise: turquoise ?? this.turquoise,
    safe: safe ?? this.safe,
    caution: caution ?? this.caution,
    danger: danger ?? this.danger,
    offline: offline ?? this.offline,
    chartGrid: chartGrid ?? this.chartGrid,
    navSurface: navSurface ?? this.navSurface,
    navIndicator: navIndicator ?? this.navIndicator,
  );

  @override
  HeatWatchColors lerp(ThemeExtension<HeatWatchColors>? other, double t) {
    if (other is! HeatWatchColors) return this;
    return HeatWatchColors(
      skyTop: Color.lerp(skyTop, other.skyTop, t)!,
      skyMid: Color.lerp(skyMid, other.skyMid, t)!,
      skyBottom: Color.lerp(skyBottom, other.skyBottom, t)!,
      skyGlow: Color.lerp(skyGlow, other.skyGlow, t)!,
      heroStart: Color.lerp(heroStart, other.heroStart, t)!,
      heroMid: Color.lerp(heroMid, other.heroMid, t)!,
      heroEnd: Color.lerp(heroEnd, other.heroEnd, t)!,
      cardSurface: Color.lerp(cardSurface, other.cardSurface, t)!,
      subtleSurface: Color.lerp(subtleSurface, other.subtleSurface, t)!,
      cardBorder: Color.lerp(cardBorder, other.cardBorder, t)!,
      cardShadow: Color.lerp(cardShadow, other.cardShadow, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      blue: Color.lerp(blue, other.blue, t)!,
      turquoise: Color.lerp(turquoise, other.turquoise, t)!,
      safe: Color.lerp(safe, other.safe, t)!,
      caution: Color.lerp(caution, other.caution, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      offline: Color.lerp(offline, other.offline, t)!,
      chartGrid: Color.lerp(chartGrid, other.chartGrid, t)!,
      navSurface: Color.lerp(navSurface, other.navSurface, t)!,
      navIndicator: Color.lerp(navIndicator, other.navIndicator, t)!,
    );
  }
}

class AppTheme {
  static ThemeData light() => _build(Brightness.light, HeatWatchColors.light);

  static ThemeData dark() => _build(Brightness.dark, HeatWatchColors.dark);

  static ThemeData _build(Brightness brightness, HeatWatchColors hw) {
    final isDark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF155EEF),
      brightness: brightness,
      primary: hw.blue,
      secondary: hw.turquoise,
      surface: hw.cardSurface,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: hw.skyMid,
      extensions: [hw],
      appBarTheme: AppBarTheme(
        backgroundColor: hw.skyTop,
        foregroundColor: hw.ink,
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      textTheme: TextTheme(
        headlineMedium: TextStyle(
          color: hw.ink,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.5,
        ),
        titleLarge: TextStyle(color: hw.ink, fontWeight: FontWeight.w700),
        titleMedium: TextStyle(color: hw.ink, fontWeight: FontWeight.w700),
        bodyMedium: TextStyle(color: hw.muted),
        bodySmall: TextStyle(color: hw.muted),
      ),
      inputDecorationTheme: InputDecorationTheme(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        filled: true,
        fillColor: hw.subtleSurface,
        labelStyle: TextStyle(color: hw.muted),
        hintStyle: TextStyle(color: hw.muted.withValues(alpha: 0.75)),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: hw.cardBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: hw.cardBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: hw.blue, width: 1.6),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: hw.navSurface,
        indicatorColor: hw.navIndicator,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            color: selected ? hw.blue : hw.muted,
            size: 23,
          );
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
            color: selected ? hw.blue : hw.muted,
          );
        }),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: hw.blue,
          foregroundColor: isDark ? const Color(0xFF091423) : Colors.white,
          minimumSize: const Size(0, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: hw.blue,
          side: BorderSide(color: hw.cardBorder),
          minimumSize: const Size(0, 44),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: hw.blue,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: hw.cardSurface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: hw.cardSurface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: hw.cardSurface,
        side: BorderSide(color: hw.cardBorder),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        labelStyle: TextStyle(
          color: hw.ink,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
      dividerTheme: DividerThemeData(color: hw.cardBorder, thickness: 1),
      cardTheme: CardThemeData(
        color: hw.cardSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: hw.cardBorder),
        ),
      ),
    );
  }
}
