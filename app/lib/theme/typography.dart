/// 字体体系：无衬线走系统默认（不打包中文字体，国产 ROM 只带 Regular，
/// 字重只用 400/600 两档）；等宽打包 JetBrainsMono（禁连字）。
///
/// 所有样式 `leadingDistribution: even` 并钉 `locale zh_CN`，保证中文内容
/// 永远落在中文字形上。M3 字阶表见 [buildTextTheme]。
library;

import 'package:material_ui/material_ui.dart';

/// 等宽字体出口：统一 fontFamily + 禁连字 + fallback 链。
abstract final class AppType {
  /// 打包的等宽字体（Regular/Italic/Medium w500/Bold w700）。
  static const monoFamily = 'JetBrainsMono';

  /// 等宽 fallback：系统等宽兜底，Noto 系列兜 CJK 等宽。
  static const monoFallback = <String>[
    'monospace',
    'Noto Sans Mono CJK SC',
    'Noto Sans CJK SC',
  ];

  /// 等宽一律禁连字（代码里的 => != 等不合并字形）。
  static const noLigatures = <FontFeature>[
    FontFeature.disable('calt'),
    FontFeature.disable('liga'),
  ];

  /// 等宽正文：代码块 13/1.55。
  static TextStyle mono({double size = 13, double height = 1.55}) =>
      TextStyle(
        fontFamily: monoFamily,
        fontFamilyFallback: monoFallback,
        fontFeatures: noLigatures,
        fontSize: size,
        height: height,
      );

  /// 聊天正文：bodyLarge 16/1.65（流式→完成不跳字号）。
  static TextStyle chatBody(BuildContext context) =>
      Theme.of(context).textTheme.bodyLarge!;

  /// 次级正文：0.9× 字号 + onSurfaceVariant（思考全文等）。
  static TextStyle chatBodySecondary(BuildContext context) =>
      chatBody(context).copyWith(
        fontSize: 16 * 0.9,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      );
}

/// M3 字阶表：displaySmall 28/1.25 w300、headlineMedium 22/1.3 w600、
/// titleLarge 18/1.4、titleMedium 16/1.45、titleSmall 14/1.45、
/// bodyLarge 16/1.65（聊天正文）、bodyMedium 14/1.55、bodySmall 12/1.5、
/// labelLarge 14 w600、labelMedium 12 w600、labelSmall 11。
TextTheme buildTextTheme({
  required Color onSurface,
  required Color onSurfaceVariant,
}) {
  TextStyle s(double size,
      {double? height, FontWeight? weight, Color? color, double? letterSpacing}) {
    return TextStyle(
      fontSize: size,
      height: height,
      fontWeight: weight,
      color: color ?? onSurface,
      letterSpacing: letterSpacing,
      locale: const Locale('zh', 'CN'),
      leadingDistribution: TextLeadingDistribution.even,
    );
  }

  return TextTheme(
    displaySmall: s(28, height: 1.25, weight: FontWeight.w300),
    headlineMedium: s(22, height: 1.3, weight: FontWeight.w600),
    titleLarge: s(18, height: 1.4),
    titleMedium: s(16, height: 1.45, weight: FontWeight.w600),
    titleSmall: s(14, height: 1.45, weight: FontWeight.w600),
    bodyLarge: s(16, height: 1.65),
    bodyMedium: s(14, height: 1.55),
    bodySmall: s(12, height: 1.5, color: onSurfaceVariant),
    labelLarge: s(14, weight: FontWeight.w600),
    labelMedium: s(12, weight: FontWeight.w600, color: onSurfaceVariant),
    labelSmall: s(11, weight: FontWeight.w600, color: onSurfaceVariant),
  );
}
