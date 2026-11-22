// 主题 token 校验：深浅色与 UI_DESIGN_SYSTEM §2 精确值一致（铁律 4：深浅同构）
import 'package:bubble/presentation/theme/bubble_colors.dart';
import 'package:bubble/presentation/theme/bubble_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('浅色 token（§2.1）', () {
    final theme = BubbleTheme.light();
    final semantic = theme.extension<BubbleSemanticColors>()!;

    test('页面底/卡片/主色/文字', () {
      expect(theme.scaffoldBackgroundColor, const Color(0xFFF2F8FC));
      expect(theme.colorScheme.primary, const Color(0xFF58AEF0));
      expect(theme.colorScheme.surface, const Color(0xFFFFFFFF));
      expect(theme.textTheme.bodyLarge!.color, const Color(0xFF29405A));
      expect(theme.textTheme.bodySmall!.color, const Color(0xFF7A8FA6));
    });

    test('语义色', () {
      expect(semantic.lavender, const Color(0xFFB7A6E8));
      expect(semantic.lavenderDeep, const Color(0xFF7C6BC4));
      expect(semantic.pink, const Color(0xFFF2B8CD));
      expect(semantic.danger, const Color(0xFFE2837F));
      expect(semantic.stroke, const Color(0xFFDCE9F4));
      expect(semantic.surfaceAlt, const Color(0xFFE9F2FA));
    });

    test('用户气泡渐变', () {
      expect(semantic.bubbleUserA, const Color(0xFF58AEF0));
      expect(semantic.bubbleUserB, const Color(0xFF7CC3F5));
    });
  });

  group('深色 token（§2.2）', () {
    final theme = BubbleTheme.dark();
    final semantic = theme.extension<BubbleSemanticColors>()!;

    test('夜空蓝黑（非纯黑）', () {
      expect(theme.scaffoldBackgroundColor, const Color(0xFF0F1722));
      expect(theme.colorScheme.surface, const Color(0xFF1A2532));
      expect(theme.colorScheme.primary, const Color(0xFF6FB9F2));
      expect(theme.textTheme.bodyLarge!.color, const Color(0xFFE6EDF4));
    });

    test('语义色提亮一档', () {
      expect(semantic.lavender, const Color(0xFF9C8BD4));
      expect(semantic.lavenderDeep, const Color(0xFFB7A8E6));
      expect(semantic.bubbleUserA, const Color(0xFF3E88C4));
      expect(semantic.bubbleUserB, const Color(0xFF5BA6D9));
      expect(semantic.stroke, const Color(0xFF2C3D52));
    });

    test('深浅两套同构（字段数量一致，铁律 4）', () {
      expect(BubbleSemanticColors.dark.mist, isNot(BubbleSemanticColors.light.mist));
      expect(
        BubbleSemanticColors.dark.surfaceAlt,
        isNot(BubbleSemanticColors.light.surfaceAlt),
      );
    });
  });

  group('圆角/字号 Token（§3/§4）', () {
    test('卡片圆角 20 / 按钮 14 / 气泡 22', () {
      expect(BubbleRadius.card, 20);
      expect(BubbleRadius.button, 14);
      expect(BubbleRadius.bubble, 22);
      expect(BubbleRadius.bubbleTail, 6);
    });

    test('排印字号', () {
      expect(BubbleFontSize.pageTitle, 24);
      expect(BubbleFontSize.cardTitle, 15);
      expect(BubbleFontSize.body, 14.5);
      expect(BubbleFontSize.secondary, 12.5);
    });

    test('主题组件圆角应用', () {
      final theme = BubbleTheme.light();
      final cardShape = theme.cardTheme.shape as RoundedRectangleBorder;
      expect(cardShape.borderRadius, BorderRadius.circular(20));
      final btn = theme.filledButtonTheme.style!;
      expect(
        btn.shape!.resolve({}) as RoundedRectangleBorder,
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      );
    });
  });
}
