// Material 3 泡泡主题（T1.5）：浅色（云朵白）+ 深色（夜空），token 与
// UI_DESIGN_SYSTEM §2 一致。深浅色同构审查（铁律 4）。
import 'package:flutter/material.dart';

import 'bubble_colors.dart';

class BubbleTheme {
  /// 浅色主题（§2.1）
  static ThemeData light() => _build(
        brightness: Brightness.light,
        bg: const Color(0xFFF2F8FC),
        surface: const Color(0xFFFFFFFF),
        primary: const Color(0xFF58AEF0),
        primaryDeep: const Color(0xFF2E7FC2),
        text: const Color(0xFF29405A),
        textSub: const Color(0xFF7A8FA6),
        semantic: BubbleSemanticColors.light,
      );

  /// 深色主题（§2.2）：夜空蓝黑（非纯黑）
  static ThemeData dark() => _build(
        brightness: Brightness.dark,
        bg: const Color(0xFF0F1722),
        surface: const Color(0xFF1A2532),
        primary: const Color(0xFF6FB9F2),
        primaryDeep: const Color(0xFF8FCBF2),
        text: const Color(0xFFE6EDF4),
        textSub: const Color(0xFF8FA3B8),
        semantic: BubbleSemanticColors.dark,
      );

  static ThemeData _build({
    required Brightness brightness,
    required Color bg,
    required Color surface,
    required Color primary,
    required Color primaryDeep,
    required Color text,
    required Color textSub,
    required BubbleSemanticColors semantic,
  }) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: brightness,
      primary: primary,
      surface: surface,
    ).copyWith(
      onPrimary: Colors.white,
      onSurface: text,
      surfaceContainerHighest: semantic.surfaceAlt,
      outline: semantic.stroke,
      outlineVariant: semantic.mist,
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: bg,
      extensions: <ThemeExtension<dynamic>>[semantic],
    );

    return base.copyWith(
      // 排印（§3：PingFang SC 系统默认栈；正文 14.5 / t2 12.5）
      textTheme: base.textTheme.copyWith(
        titleLarge: TextStyle(
            fontSize: BubbleFontSize.pageTitle,
            fontWeight: FontWeight.w700,
            color: text),
        titleMedium: TextStyle(
            fontSize: BubbleFontSize.cardTitle,
            fontWeight: FontWeight.w600,
            color: text),
        bodyLarge: TextStyle(
            fontSize: BubbleFontSize.body, height: 1.6, color: text),
        bodyMedium: TextStyle(
            fontSize: BubbleFontSize.bodySmall, height: 1.5, color: text),
        bodySmall: TextStyle(
            fontSize: BubbleFontSize.secondary, color: textSub),
      ),
      // 卡片（§4：圆角 20 + 柔投影带品牌色相 §5）
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(BubbleRadius.card),
          side: BorderSide(color: semantic.stroke, width: 1),
        ),
        shadowColor: const Color(0x1A58AEF0),
      ),
      // 按钮（圆角 14）
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(BubbleRadius.button)),
          minimumSize: const Size(44, 44), // §9 最小点击区
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primaryDeep,
          side: BorderSide(color: semantic.mist),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(BubbleRadius.button)),
          minimumSize: const Size(44, 44),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: primaryDeep),
      ),
      // 输入条（圆角 16）
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(BubbleRadius.inputBar),
          borderSide: BorderSide(color: semantic.stroke),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(BubbleRadius.inputBar),
          borderSide: BorderSide(color: semantic.stroke),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(BubbleRadius.inputBar),
          borderSide: BorderSide(color: primary, width: 1.5),
        ),
      ),
      // 分隔线
      dividerTheme: DividerThemeData(color: semantic.mist, thickness: 1, space: 1),
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        foregroundColor: text,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        indicatorColor: semantic.surfaceAlt,
        height: 64,
      ),
    );
  }
}
