/// 玻璃表面容器（移植自 dsh-Go 的 GlassSurface 解剖）：
/// **模糊背后的内容 → 叠半透明填充 → 发丝描边 + 顶边渐隐高光 → 外投影**。
///
/// 对外保留两个便捷入口：
/// - GlassPill：chrome 级胶囊（顶栏/输入条/浮动键），Stadium 全圆角，真模糊。
/// - GlassCard：card 级卡片（审批卡/提问卡/引用块），squircle 圆角，不模糊。
///
/// 性能约定：只有 chrome/sheet 真模糊，同屏 ≤3；同屏多个**互不重叠**的
/// chrome 玻璃件传 [GlassSurface.grouped] = true（配合根部的 BackdropGroup，
/// 引擎只采一次背景）。降级：主题 `blurEnabled == false` 或系统高对比度
/// 时不挂 BackdropFilter，改用近乎不透明的 fallbackFill。
///
/// 为什么阴影单独画：玻璃内部半透明，普通 BoxShadow 画在形状下方会透过
/// 玻璃、又被模糊一次，中间发灰。这里 even-odd 裁剪，只在形状**外部**画。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../theme/squircle.dart';
import '../../theme/tokens.dart';
import 'pressable.dart';

/// 玻璃材质层级。
enum GlassTier { chrome, sheet, card, pill }

/// 通用玻璃表面。
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    this.tier = GlassTier.card,
    this.radius,
    this.stadium = false,
    this.padding,
    this.blur,
    this.grouped = false,
    this.settled,
    this.onTap,
    this.onLongPress,
    this.child,
  });

  /// 材质层级，决定默认填充 / 模糊 / 阴影 / 圆角。
  final GlassTier tier;

  /// 连续圆角半径。缺省按层级：chrome/sheet 用 xl(28)、card 用 md(14)。
  final double? radius;

  /// 胶囊（半径永远等于高度一半）。
  final bool stadium;

  final EdgeInsetsGeometry? padding;

  /// 强制开 / 关模糊。null = 跟随层级默认值与主题总开关。
  final bool? blur;

  /// 与同一 BackdropGroup 下的其他玻璃共享一次背景采样。
  final bool grouped;

  /// 会动的玻璃（升起、被拖动的弹层）。0 = 在动：不采样背景，用不透明
  /// 填充。停稳后走向 1：模糊立刻开，填充渐变回玻璃，出现时不跳。null =
  /// 一直是玻璃。
  final double? settled;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget? child;

  double get _radius => radius ?? switch (tier) {
        GlassTier.chrome || GlassTier.sheet => 28,
        GlassTier.card || GlassTier.pill => 14,
      };

  bool get _isStadium => stadium || tier == GlassTier.pill;

  ShapeBorder get _shape {
    if (_isStadium) return const StadiumBorder();
    return Squircle.border(_radius);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final s = switch (tier) {
      GlassTier.chrome => tokens.glassChrome,
      GlassTier.sheet => tokens.glassSheet,
      GlassTier.card || GlassTier.pill => tokens.glassCard,
    };
    final highContrast = MediaQuery.maybeHighContrastOf(context) ?? false;
    final reduce = !tokens.blurEnabled || highContrast;
    final useBlur = !reduce && (blur ?? s.blurs);
    final fill = useBlur
        ? Color.lerp(s.fallbackFill, s.fill, settled ?? 1)!
        : (reduce && s.blurs ? s.fallbackFill : s.fill);
    final shape = _shape;

    Widget content = child ?? const SizedBox.shrink();
    if (padding != null) content = Padding(padding: padding!, child: content);
    if (onTap != null || onLongPress != null) {
      // 按压反馈加在内容上而不是玻璃上：玻璃缩放会每帧按新尺寸重采背景。
      content = Material(
        type: MaterialType.transparency,
        child: InkWell(
          customBorder: shape,
          onTap: onTap,
          onLongPress: onLongPress,
          child: Pressable(behavior: HitTestBehavior.translucent, child: content),
        ),
      );
    }

    content = CustomPaint(
      foregroundPainter: _GlassEdgePainter(
        shape: shape,
        hairline: s.hairline,
        hairlineWidth: s.hairlineWidth,
        rim: s.rim,
      ),
      child: DecoratedBox(
        decoration: ShapeDecoration(shape: shape, color: fill),
        child: content,
      ),
    );

    if (useBlur) {
      final config = _filterFor(s.blur, s.saturation);
      final sampling = settled != 0;
      content = grouped
          ? BackdropFilter.grouped(filterConfig: config, enabled: sampling, child: content)
          : BackdropFilter(filterConfig: config, enabled: sampling, child: content);
      content = _clip(content);
    }

    if (s.shadows.isNotEmpty) {
      content = CustomPaint(
        painter: _GlassShadowPainter(shape: shape, shadows: s.shadows),
        child: content,
      );
    }
    return content;
  }

  Widget _clip(Widget child) {
    if (_isStadium) {
      return ClipRRect(
          borderRadius: const BorderRadius.all(Radius.circular(999)),
          child: child);
    }
    return Squircle.clip(radius: _radius, child: child);
  }

  static ImageFilterConfig _filterFor(double sigma, double saturation) {
    final blur = ImageFilterConfig.blur(sigmaX: sigma, sigmaY: sigma, bounded: true);
    if (saturation == 1) return blur;
    return ImageFilterConfig.compose(
        outer: ImageFilterConfig(ColorFilter.matrix(_saturate(saturation))),
        inner: blur);
  }

  /// 保亮度的饱和度矩阵（Rec. 709 权重）。
  static List<double> _saturate(double s) {
    final r = 0.2126 * (1 - s);
    final g = 0.7152 * (1 - s);
    final b = 0.0722 * (1 - s);
    return <double>[
      r + s, g, b, 0, 0, //
      r, g + s, b, 0, 0, //
      r, g, b + s, 0, 0, //
      0, 0, 0, 1, 0, //
    ];
  }
}

/// 玻璃胶囊：chrome 级，顶栏/输入条/浮动键共用。
class GlassPill extends StatelessWidget {
  const GlassPill({required this.child, super.key, this.padding});

  final Widget child;

  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      tier: GlassTier.chrome,
      stadium: true,
      padding: padding ?? const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: child,
    );
  }
}

/// 玻璃卡片：card 级近似玻璃（不模糊），squircle 圆角（默认 shape.card）。
class GlassCard extends StatelessWidget {
  const GlassCard({required this.child, super.key, this.padding, this.radius});

  final Widget child;

  final EdgeInsetsGeometry? padding;

  /// 覆写圆角（如紧凑变体）；null = shape.card。
  final double? radius;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      tier: GlassTier.card,
      radius: radius ?? context.tokens.shape.card,
      padding: padding ?? const EdgeInsets.all(12),
      child: child,
    );
  }
}

/// 发丝描边 + 顶边渐隐高光（stops [0, 0.45]）。描边画在形状内侧，裁剪时
/// 不会被切掉一半。
class _GlassEdgePainter extends CustomPainter {
  _GlassEdgePainter({
    required this.shape,
    required this.hairline,
    required this.hairlineWidth,
    required this.rim,
  });

  final ShapeBorder shape;
  final Color hairline;
  final double hairlineWidth;
  final Color rim;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final width = math.max(hairlineWidth, 0.5);
    final path = shape.getOuterPath(rect.deflate(width / 2));
    if (hairline.a > 0) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..color = hairline,
      );
    }
    if (rim.a > 0) {
      final highlight = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(width, 0.8)
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [rim, rim.withValues(alpha: 0)],
          stops: const [0, 0.45],
        ).createShader(rect);
      canvas.drawPath(path, highlight);
    }
  }

  @override
  bool shouldRepaint(_GlassEdgePainter old) =>
      old.shape != shape ||
      old.hairline != hairline ||
      old.hairlineWidth != hairlineWidth ||
      old.rim != rim;
}

/// 只在形状外部画的投影。
class _GlassShadowPainter extends CustomPainter {
  _GlassShadowPainter({required this.shape, required this.shadows});

  final ShapeBorder shape;
  final List<BoxShadow> shadows;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    var extent = 0.0;
    for (final s in shadows) {
      extent = math.max(
          extent, s.blurRadius * 2 + s.spreadRadius.abs() + s.offset.distance);
    }
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(rect.inflate(extent + 2))
      ..addPath(shape.getOuterPath(rect), Offset.zero);
    canvas.save();
    canvas.clipPath(outside);
    for (final s in shadows) {
      canvas.drawPath(
        shape.getOuterPath(rect.shift(s.offset).inflate(s.spreadRadius)),
        s.toPaint(),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GlassShadowPainter old) =>
      old.shape != shape || !_sameShadows(old.shadows, shadows);

  static bool _sameShadows(List<BoxShadow> a, List<BoxShadow> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
