import 'package:flutter/material.dart';

abstract final class MuseReaderTheme {
  static const _lightPrimary = Color(0xff9c402e);
  static const _lightSecondary = Color(0xff24665d);
  static const _lightSurface = Color(0xfffafbf8);
  static const _lightBackground = Color(0xfff1f3ef);

  static const _darkPrimary = Color(0xffffb4a1);
  static const _darkSecondary = Color(0xff86d5c8);
  static const _darkSurface = Color(0xff181b19);
  static const _darkBackground = Color(0xff101311);

  static ThemeData get light => _build(Brightness.light);

  static ThemeData get dark => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final primary = isDark ? _darkPrimary : _lightPrimary;
    final secondary = isDark ? _darkSecondary : _lightSecondary;
    final surface = isDark ? _darkSurface : _lightSurface;
    final background = isDark ? _darkBackground : _lightBackground;
    final baseScheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: brightness,
    );
    final scheme = baseScheme.copyWith(
      primary: primary,
      onPrimary: isDark ? const Color(0xff5d1609) : Colors.white,
      secondary: secondary,
      onSecondary: isDark ? const Color(0xff003731) : Colors.white,
      surface: surface,
      surfaceContainerLowest: background,
      surfaceContainerLow: isDark
          ? const Color(0xff1d211e)
          : const Color(0xfff6f7f4),
      surfaceContainer: isDark
          ? const Color(0xff232824)
          : const Color(0xffecefeb),
      surfaceContainerHigh: isDark
          ? const Color(0xff2a2f2b)
          : const Color(0xffe3e7e2),
      surfaceContainerHighest: isDark
          ? const Color(0xff323733)
          : const Color(0xffdce1dc),
      outline: isDark ? const Color(0xff8b938d) : const Color(0xff747b76),
      outlineVariant: isDark
          ? const Color(0xff3f4641)
          : const Color(0xffc8cec9),
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
    );
    final textTheme = base.textTheme.copyWith(
      headlineMedium: base.textTheme.headlineMedium?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
      ),
      titleLarge: base.textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
      ),
      titleMedium: base.textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
      bodyLarge: base.textTheme.bodyLarge?.copyWith(letterSpacing: 0),
      bodyMedium: base.textTheme.bodyMedium?.copyWith(letterSpacing: 0),
      bodySmall: base.textTheme.bodySmall?.copyWith(letterSpacing: 0),
      labelLarge: base.textTheme.labelLarge?.copyWith(
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
      labelMedium: base.textTheme.labelMedium?.copyWith(letterSpacing: 0),
      labelSmall: base.textTheme.labelSmall?.copyWith(letterSpacing: 0),
    );
    final border = BorderSide(color: scheme.outlineVariant);
    const radius = BorderRadius.all(Radius.circular(8));

    return base.copyWith(
      colorScheme: scheme,
      textTheme: textTheme,
      scaffoldBackgroundColor: background,
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: textTheme.titleLarge?.copyWith(color: scheme.onSurface),
      ),
      cardTheme: CardThemeData(
        margin: EdgeInsets.zero,
        color: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: radius, side: border),
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
      iconButtonTheme: const IconButtonThemeData(
        style: ButtonStyle(
          minimumSize: WidgetStatePropertyAll(Size.square(48)),
          tapTargetSize: MaterialTapTargetSize.padded,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 18),
          shape: const RoundedRectangleBorder(borderRadius: radius),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 18),
          shape: const RoundedRectangleBorder(borderRadius: radius),
          side: border,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: const RoundedRectangleBorder(borderRadius: radius),
        ),
      ),
      sliderTheme: base.sliderTheme.copyWith(
        activeTrackColor: primary,
        inactiveTrackColor: scheme.surfaceContainerHighest,
        trackHeight: 3,
        thumbColor: primary,
        overlayColor: primary.withValues(alpha: 0.12),
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 20),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
        shape: const RoundedRectangleBorder(borderRadius: radius),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 450),
        textStyle: textTheme.bodySmall?.copyWith(
          color: scheme.onInverseSurface,
        ),
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: BorderRadius.circular(6),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: primary),
    );
  }
}
