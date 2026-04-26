import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_ui.dart';
import 'ios_tokens.dart';

class AppTheme {
  static String? get _iosFontFamily =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS ? '.SF Pro Text' : null;

  static ThemeData light() {
    final baseScheme = ColorScheme.fromSeed(
      seedColor: IosTokens.systemBlue,
      brightness: Brightness.light,
      primary: IosTokens.systemBlue,
      onPrimary: Colors.white,
      secondary: IosTokens.systemGreen,
      onSecondary: Colors.white,
      error: IosTokens.systemRed,
      onError: Colors.white,
      surface: IosTokens.groupedBackground,
      onSurface: IosTokens.labelPrimary,
      onSurfaceVariant: IosTokens.labelSecondary,
      outline: IosTokens.separatorOpaque,
      outlineVariant: IosTokens.systemGray5,
    );

    final colorScheme = baseScheme.copyWith(
      surfaceContainerLowest: IosTokens.groupedBackground,
      surfaceContainerLow: Colors.white,
      surfaceContainer: IosTokens.systemGray6,
      surfaceContainerHigh: Colors.white,
      surfaceContainerHighest: IosTokens.systemGray5,
    );

    final base = ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colorScheme.surface,
      brightness: Brightness.light,
    );

    final textTheme =
        _fontOnly(base.textTheme).apply(bodyColor: colorScheme.onSurface, displayColor: colorScheme.onSurface);
    final primaryTextTheme =
        _fontOnly(base.primaryTextTheme).apply(bodyColor: colorScheme.onPrimary, displayColor: colorScheme.onPrimary);

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colorScheme.surface,
      brightness: Brightness.light,
      textTheme: textTheme,
      primaryTextTheme: primaryTextTheme,
      splashFactory: defaultTargetPlatform == TargetPlatform.iOS ? NoSplash.splashFactory : InkSparkle.splashFactory,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        },
      ),
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.onSurface,
        titleTextStyle: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
      navigationBarTheme: NavigationBarThemeData(
        elevation: 0,
        backgroundColor: colorScheme.surface,
        indicatorColor: IosTokens.systemBlue.withValues(alpha: 0.12),
        labelTextStyle: WidgetStatePropertyAll(textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w500)),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.black.withValues(alpha: 0.06),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppUi.r22),
          side: BorderSide(color: IosTokens.systemGray5.withValues(alpha: 0.8)),
        ),
        margin: EdgeInsets.zero,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 50),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          elevation: 0,
          shadowColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppUi.r14)),
          textStyle: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.2),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 50),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppUi.r14)),
          side: BorderSide(color: IosTokens.systemBlue.withValues(alpha: 0.35)),
          textStyle: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: IosTokens.systemBlue,
          textStyle: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: IosTokens.systemGray6,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppUi.r12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppUi.r12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppUi.r12),
          borderSide: const BorderSide(color: IosTokens.systemBlue, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppUi.r12),
          borderSide: const BorderSide(color: IosTokens.systemRed),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        hintStyle: TextStyle(color: colorScheme.onSurfaceVariant, fontWeight: FontWeight.w400),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.selected)) return Colors.white;
          return Colors.white;
        }),
        trackColor: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.selected)) {
            return IosTokens.systemGreen.withValues(alpha: 0.95);
          }
          return IosTokens.systemGray4;
        }),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppUi.r14)),
        backgroundColor: IosTokens.darkElevated,
        contentTextStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
      ),
      dialogTheme: DialogThemeData(
        elevation: 0,
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppUi.r22)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        elevation: 0,
        backgroundColor: Colors.white,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(AppUi.r22)),
        ),
        dragHandleColor: IosTokens.systemGray3,
        dragHandleSize: const Size(36, 5),
        showDragHandle: true,
      ),
      dividerTheme: const DividerThemeData(color: IosTokens.separatorOpaque, thickness: 0.5),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppUi.r12)),
      ),
    );
  }

  static ThemeData dark() {
    final colorScheme = ColorScheme(
      brightness: Brightness.dark,
      primary: IosTokens.systemBlueDark,
      onPrimary: Colors.white,
      primaryContainer: IosTokens.darkElevated2,
      onPrimaryContainer: Colors.white,
      secondary: IosTokens.systemGreenDark,
      onSecondary: Colors.black,
      secondaryContainer: IosTokens.darkElevated2,
      onSecondaryContainer: Colors.white,
      tertiary: IosTokens.systemTeal,
      onTertiary: Colors.black,
      error: Color(0xFFFF453A),
      onError: Colors.white,
      surface: IosTokens.darkBackground,
      onSurface: Colors.white,
      onSurfaceVariant: IosTokens.systemGray2,
      outline: IosTokens.darkElevated2,
      outlineVariant: IosTokens.darkElevated2,
      shadow: Colors.black54,
      scrim: Colors.black54,
      inverseSurface: IosTokens.systemGray6,
      onInverseSurface: Colors.black,
      inversePrimary: IosTokens.systemBlue,
      surfaceTint: Colors.transparent,
      surfaceContainerHighest: IosTokens.darkElevated2,
      surfaceContainerHigh: IosTokens.darkElevated,
      surfaceContainer: IosTokens.darkElevated,
      surfaceContainerLow: IosTokens.darkElevated,
      surfaceContainerLowest: IosTokens.darkBackground,
    );

    final base = ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colorScheme.surface,
      brightness: Brightness.dark,
    );

    final textTheme =
        _fontOnly(base.textTheme).apply(bodyColor: colorScheme.onSurface, displayColor: colorScheme.onSurface);
    final primaryTextTheme =
        _fontOnly(base.primaryTextTheme).apply(bodyColor: colorScheme.onPrimary, displayColor: colorScheme.onPrimary);

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colorScheme.surface,
      brightness: Brightness.dark,
      textTheme: textTheme,
      primaryTextTheme: primaryTextTheme,
      splashFactory: defaultTargetPlatform == TargetPlatform.iOS ? NoSplash.splashFactory : InkSparkle.splashFactory,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        },
      ),
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.onSurface,
        titleTextStyle: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: IosTokens.darkElevated,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppUi.r22),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
        margin: EdgeInsets.zero,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 50),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppUi.r14)),
          textStyle: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.2),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 50),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppUi.r14)),
          side: BorderSide(color: IosTokens.systemBlueDark.withValues(alpha: 0.5)),
          textStyle: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: IosTokens.systemBlueDark,
          textStyle: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: IosTokens.darkElevated2,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppUi.r12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppUi.r12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppUi.r12),
          borderSide: const BorderSide(color: IosTokens.systemBlueDark, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.selected)) return Colors.white;
          return Colors.white;
        }),
        trackColor: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.selected)) {
            return IosTokens.systemGreenDark.withValues(alpha: 0.95);
          }
          return IosTokens.systemGray;
        }),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppUi.r14)),
        backgroundColor: IosTokens.darkElevated2,
        contentTextStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
      ),
      dialogTheme: DialogThemeData(
        elevation: 0,
        backgroundColor: IosTokens.darkElevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppUi.r22)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        elevation: 0,
        backgroundColor: IosTokens.darkElevated,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(AppUi.r22)),
        ),
        dragHandleColor: IosTokens.systemGray,
        dragHandleSize: const Size(36, 5),
        showDragHandle: true,
      ),
      dividerTheme: DividerThemeData(color: Colors.white.withValues(alpha: 0.12), thickness: 0.5),
    );
  }

  static TextTheme _fontOnly(TextTheme t) {
    final f = _iosFontFamily;
    TextStyle s(TextStyle? style, {FontWeight? weight, double letterSpacing = -0.24}) {
      var o = style ?? const TextStyle();
      o = o.copyWith(
        fontFamily: f ?? o.fontFamily,
        fontWeight: weight ?? o.fontWeight,
        letterSpacing: letterSpacing,
      );
      return o;
    }

    return TextTheme(
      displayLarge: s(t.displayLarge, weight: FontWeight.w600, letterSpacing: -0.5),
      displayMedium: s(t.displayMedium, weight: FontWeight.w600),
      displaySmall: s(t.displaySmall, weight: FontWeight.w600),
      headlineLarge: s(t.headlineLarge, weight: FontWeight.w600),
      headlineMedium: s(t.headlineMedium, weight: FontWeight.w600),
      headlineSmall: s(t.headlineSmall, weight: FontWeight.w600),
      titleLarge: s(t.titleLarge, weight: FontWeight.w600),
      titleMedium: s(t.titleMedium, weight: FontWeight.w600),
      titleSmall: s(t.titleSmall, weight: FontWeight.w600),
      bodyLarge: s(t.bodyLarge, weight: FontWeight.w400, letterSpacing: -0.24),
      bodyMedium: s(t.bodyMedium, weight: FontWeight.w400),
      bodySmall: s(t.bodySmall, weight: FontWeight.w400),
      labelLarge: s(t.labelLarge, weight: FontWeight.w600),
      labelMedium: s(t.labelMedium, weight: FontWeight.w500),
      labelSmall: s(t.labelSmall, weight: FontWeight.w500),
    );
  }
}
