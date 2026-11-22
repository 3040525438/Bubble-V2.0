// 泡泡设计系统色彩 Token（UI_DESIGN_SYSTEM §2，以 UI_PROTOTYPE.html 为唯一真源）
import 'package:flutter/material.dart';

/// 语义扩展色（lavender=思考/记忆，pink=说说/情感，success/warn/danger 状态色）
@immutable
class BubbleSemanticColors extends ThemeExtension<BubbleSemanticColors> {
  const BubbleSemanticColors({
    required this.lavender,
    required this.lavenderDeep,
    required this.pink,
    required this.pinkDeep,
    required this.success,
    required this.successDeep,
    required this.warn,
    required this.warnDeep,
    required this.danger,
    required this.dangerDeep,
    required this.mist,
    required this.stroke,
    required this.surfaceAlt,
    required this.bubbleUserA,
    required this.bubbleUserB,
  });

  final Color lavender;
  final Color lavenderDeep;
  final Color pink;
  final Color pinkDeep;
  final Color success;
  final Color successDeep;
  final Color warn;
  final Color warnDeep;
  final Color danger;
  final Color dangerDeep;
  final Color mist; // 分隔线/禁用
  final Color stroke; // 描边
  final Color surfaceAlt; // 次级底
  final Color bubbleUserA; // 用户气泡渐变起
  final Color bubbleUserB; // 用户气泡渐变终

  /// 浅色（云朵白 · 日间）§2.1
  static const light = BubbleSemanticColors(
    lavender: Color(0xFFB7A6E8),
    lavenderDeep: Color(0xFF7C6BC4),
    pink: Color(0xFFF2B8CD),
    pinkDeep: Color(0xFFC4708F),
    success: Color(0xFF6FBF8F),
    successDeep: Color(0xFF4E9E72),
    warn: Color(0xFFE8B96A),
    warnDeep: Color(0xFFB98A3A),
    danger: Color(0xFFE2837F),
    dangerDeep: Color(0xFFC05B57),
    mist: Color(0xFFA9CFE8),
    stroke: Color(0xFFDCE9F4),
    surfaceAlt: Color(0xFFE9F2FA),
    bubbleUserA: Color(0xFF58AEF0),
    bubbleUserB: Color(0xFF7CC3F5),
  );

  /// 深色（夜空 · 夜间）§2.2
  static const dark = BubbleSemanticColors(
    lavender: Color(0xFF9C8BD4),
    lavenderDeep: Color(0xFFB7A8E6),
    pink: Color(0xFFD99BB4),
    pinkDeep: Color(0xFFE9B7CB),
    success: Color(0xFF6FBF8F),
    successDeep: Color(0xFF8FCFA8),
    warn: Color(0xFFE8B96A),
    warnDeep: Color(0xFFF0CD8E),
    danger: Color(0xFFE2837F),
    dangerDeep: Color(0xFFEFA8A4),
    mist: Color(0xFF31506B),
    stroke: Color(0xFF2C3D52),
    surfaceAlt: Color(0xFF223144),
    bubbleUserA: Color(0xFF3E88C4),
    bubbleUserB: Color(0xFF5BA6D9),
  );

  @override
  BubbleSemanticColors copyWith(
      {Color? lavender,
      Color? lavenderDeep,
      Color? pink,
      Color? pinkDeep,
      Color? success,
      Color? successDeep,
      Color? warn,
      Color? warnDeep,
      Color? danger,
      Color? dangerDeep,
      Color? mist,
      Color? stroke,
      Color? surfaceAlt,
      Color? bubbleUserA,
      Color? bubbleUserB}) {
    return BubbleSemanticColors(
      lavender: lavender ?? this.lavender,
      lavenderDeep: lavenderDeep ?? this.lavenderDeep,
      pink: pink ?? this.pink,
      pinkDeep: pinkDeep ?? this.pinkDeep,
      success: success ?? this.success,
      successDeep: successDeep ?? this.successDeep,
      warn: warn ?? this.warn,
      warnDeep: warnDeep ?? this.warnDeep,
      danger: danger ?? this.danger,
      dangerDeep: dangerDeep ?? this.dangerDeep,
      mist: mist ?? this.mist,
      stroke: stroke ?? this.stroke,
      surfaceAlt: surfaceAlt ?? this.surfaceAlt,
      bubbleUserA: bubbleUserA ?? this.bubbleUserA,
      bubbleUserB: bubbleUserB ?? this.bubbleUserB,
    );
  }

  @override
  BubbleSemanticColors lerp(BubbleSemanticColors? other, double t) {
    if (other == null) return this;
    return BubbleSemanticColors(
      lavender: Color.lerp(lavender, other.lavender, t)!,
      lavenderDeep: Color.lerp(lavenderDeep, other.lavenderDeep, t)!,
      pink: Color.lerp(pink, other.pink, t)!,
      pinkDeep: Color.lerp(pinkDeep, other.pinkDeep, t)!,
      success: Color.lerp(success, other.success, t)!,
      successDeep: Color.lerp(successDeep, other.successDeep, t)!,
      warn: Color.lerp(warn, other.warn, t)!,
      warnDeep: Color.lerp(warnDeep, other.warnDeep, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      dangerDeep: Color.lerp(dangerDeep, other.dangerDeep, t)!,
      mist: Color.lerp(mist, other.mist, t)!,
      stroke: Color.lerp(stroke, other.stroke, t)!,
      surfaceAlt: Color.lerp(surfaceAlt, other.surfaceAlt, t)!,
      bubbleUserA: Color.lerp(bubbleUserA, other.bubbleUserA, t)!,
      bubbleUserB: Color.lerp(bubbleUserB, other.bubbleUserB, t)!,
    );
  }
}

/// 圆角 Token（§4）
class BubbleRadius {
  static const double bubble = 22; // 气泡（收口角 6 由气泡组件处理）
  static const double bubbleTail = 6;
  static const double card = 20;
  static const double button = 14;
  static const double inputBar = 16;
  static const double navPill = 24;
  static const double badge = 12;
}

/// 字体排印字号（§3）
class BubbleFontSize {
  static const double pageTitle = 24; // h-title 700
  static const double cardTitle = 15; // t1 600
  static const double body = 14.5;
  static const double bodySmall = 13.5;
  static const double secondary = 12.5; // t2
  static const double badge = 11;
  static const double profileName = 20; // 头部昵称 800
}

/// 读取语义色的便捷扩展
extension BubbleSemanticContext on BuildContext {
  BubbleSemanticColors get bubbleColors =>
      Theme.of(this).extension<BubbleSemanticColors>() ?? BubbleSemanticColors.light;
}
