/// 聊天视觉 token 层：玻璃表面分级（chrome/sheet/card，数值对齐 dsh-Go
/// 「雾蓝玻璃」）、动效、圆角五档、页面渐变、语义色 —— `CcTokens` 以
/// ThemeExtension 挂在 ThemeData 上，经 `context.tokens` 读取；另给出明暗
/// 两套 ThemeData 构建（`CcTheme.light/dark`，调色板见 palette.dart）。
///
/// 玻璃性能约定（移植自 dsh-Go）：只有 chrome/sheet 真模糊，同屏真模糊
/// 元素 ≤3；card 级不挂 BackdropFilter（近似：只铺填充，design D2）；
/// `blurEnabled` = false（"减少透明效果"/低端机）时降级为近乎不透明的
/// fallbackFill。玻璃渲染（描边/高光/外投影 painter、饱和度矩阵）见
/// ui/widgets/glass.dart。
///
/// 本层 MUST NOT 依赖任何 UI 屏幕（theme_tokens_test.dart 有源码扫描
/// 守卫，当前放宽）；语义状态色的静态入口仍在 ui/theme/app_style.dart。
library;

import 'package:material_ui/material_ui.dart';

import 'motion.dart';
import 'palette.dart';
import 'squircle.dart';
import 'typography.dart';

/// 玻璃表面规格：同一解剖，三级参数。填充是"真模糊时"的色；
/// [fallbackFill] 是降级（不模糊）时近乎不透明的色。
class GlassSpec {
  const GlassSpec({
    required this.fill,
    required this.fallbackFill,
    required this.blurs,
    required this.blur,
    required this.saturation,
    required this.hairline,
    required this.hairlineWidth,
    required this.rim,
    required this.shadows,
  });

  /// 真模糊时的半透明填充色。
  final Color fill;

  /// 不模糊（降级/settled=0）时的近乎不透明填充色。
  final Color fallbackFill;

  /// 该层级默认是否真模糊（chrome/sheet true，card false）。
  final bool blurs;

  /// BackdropFilter 模糊 sigma；0 = 近似玻璃（只铺填充不挂模糊）。
  final double blur;

  /// 模糊后叠加的饱和度（1 = 不调；chrome 1.3/1.2、sheet 1.4）。
  final double saturation;

  /// 发丝描边色（画在形状内侧）。
  final Color hairline;

  /// 发丝描边宽（0.5px 是骨架）。
  final double hairlineWidth;

  /// 顶边高光色（渐隐到透明，stops [0, 0.45]，由 painter 画）。
  final Color rim;

  /// 外投影（even-odd 只画在形状外部）。
  final List<BoxShadow> shadows;
}

/// 动效三档（汇总入口；完整时长表/弹簧/曲线在 motion.dart 的 AppMotion）。
class MotionTokens {
  const MotionTokens({
    required this.fast,
    required this.structure,
    required this.ambient,
    required this.curve,
  });

  /// 反馈（按压、chip 变色）。
  final Duration fast;

  /// 结构（弹层、展开收起、列表重排）。
  final Duration structure;

  /// 环境（周期性指示、scrim 渐隐）。
  final Duration ambient;

  /// fast/structure 共用缓动。
  final Curve curve;
}

/// 圆角五档（全部连续曲率 squircle，胶囊走 Stadium）：
/// xs 6（行内代码/角标）、sm 10（Chip/工具图标块/菜单项）、md 14（卡片/
/// 代码井/输入框/菜单）、lg 20（用户气泡/审批卡）、xl 28（composer/
/// 底部弹层/对话框）。
class ShapeTokens {
  const ShapeTokens({
    required this.xs,
    required this.sm,
    required this.md,
    required this.lg,
    required this.xl,
  });

  const ShapeTokens.standard()
      : this(xs: 6, sm: 10, md: 14, lg: 20, xl: 28);

  final double xs;
  final double sm;
  final double md;
  final double lg;
  final double xl;

  /// 兼容别名：卡片（审批卡/提问卡）= lg。
  double get card => lg;

  /// 兼容别名：弹层 = xl。
  double get sheet => xl;

  /// 兼容别名：小控件/输入框 = md。
  double get control => md;

  /// 连续曲率边框（引擎原生 RoundedSuperellipseBorder，见 squircle.dart）。
  ShapeBorder border([double? radius]) =>
      Squircle.border(radius ?? card);
}

/// 语义色集合（明暗各一套，取自 palette）。
class SemanticTokens {
  const SemanticTokens({
    required this.success,
    required this.warning,
    required this.info,
    required this.danger,
    required this.diffAddBg,
    required this.diffAddFg,
    required this.diffDelBg,
    required this.diffDelFg,
  });

  final Color success;
  final Color warning;
  final Color info;
  final Color danger;
  final Color diffAddBg;
  final Color diffAddFg;
  final Color diffDelBg;
  final Color diffDelFg;
}

/// 聊天视觉 token 集合。
class CcTokens extends ThemeExtension<CcTokens> {
  const CcTokens({
    required this.glassChrome,
    required this.glassSheet,
    required this.glassCard,
    required this.motion,
    required this.shape,
    required this.pageGradient,
    required this.semantic,
    required this.blurEnabled,
  });

  /// chrome 级：顶栏胶囊 / 输入条 / 浮动键（真模糊）。
  final GlassSpec glassChrome;

  /// sheet 级：底部弹层（真模糊）。
  final GlassSpec glassSheet;

  /// card 级：审批卡/提问卡/引用块等（近似，blur=0）。
  final GlassSpec glassCard;

  final MotionTokens motion;
  final ShapeTokens shape;

  /// 页面竖向渐变（mistTop → mistBottom）。
  final Gradient pageGradient;

  final SemanticTokens semantic;

  /// 玻璃模糊总开关（"减少透明效果"/低端机降级）。
  final bool blurEnabled;

  @override
  CcTokens copyWith({
    GlassSpec? glassChrome,
    GlassSpec? glassSheet,
    GlassSpec? glassCard,
    MotionTokens? motion,
    ShapeTokens? shape,
    Gradient? pageGradient,
    SemanticTokens? semantic,
    bool? blurEnabled,
  }) =>
      CcTokens(
        glassChrome: glassChrome ?? this.glassChrome,
        glassSheet: glassSheet ?? this.glassSheet,
        glassCard: glassCard ?? this.glassCard,
        motion: motion ?? this.motion,
        shape: shape ?? this.shape,
        pageGradient: pageGradient ?? this.pageGradient,
        semantic: semantic ?? this.semantic,
        blurEnabled: blurEnabled ?? this.blurEnabled,
      );

  @override
  CcTokens lerp(CcTokens? other, double t) {
    if (other == null) return this;
    // 玻璃与形状规格不逐帧插值（主题切换为一次性跳变）；动效时长线性
    // 插值保持过渡连续。
    return CcTokens(
      glassChrome: t < 0.5 ? glassChrome : other.glassChrome,
      glassSheet: t < 0.5 ? glassSheet : other.glassSheet,
      glassCard: t < 0.5 ? glassCard : other.glassCard,
      motion: MotionTokens(
        fast: _lerpDuration(motion.fast, other.motion.fast, t),
        structure: _lerpDuration(motion.structure, other.motion.structure, t),
        ambient: _lerpDuration(motion.ambient, other.motion.ambient, t),
        curve: t < 0.5 ? motion.curve : other.motion.curve,
      ),
      shape: t < 0.5 ? shape : other.shape,
      pageGradient: t < 0.5 ? pageGradient : other.pageGradient,
      semantic: t < 0.5 ? semantic : other.semantic,
      blurEnabled: t < 0.5 ? blurEnabled : other.blurEnabled,
    );
  }

  static Duration _lerpDuration(Duration a, Duration b, double t) => Duration(
      milliseconds:
          (a.inMilliseconds + (b.inMilliseconds - a.inMilliseconds) * t)
              .round());
}

/// 标准.token 兜底：主题未挂 CcTokens（如测试的裸 MaterialApp）时用
/// 亮色标准套，玻璃件不炸。
final _standardTokens = _buildTokens(light: true);

/// 读取入口：`context.tokens.glassChrome`。
extension CcTokensContext on BuildContext {
  CcTokens get tokens =>
      Theme.of(this).extension<CcTokens>() ?? _standardTokens;
}

/// 主题构建：手工 ColorScheme（调色板）+ M3 字阶 + CcTokens 扩展 + 组件
/// 主题（层次靠材质不靠阴影：elevation 全 0；细线是骨架）。
abstract final class CcTheme {
  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final light = brightness == Brightness.light;
    final p = light ? LightPalette.instance : DarkPalette.instance;
    final scheme = ColorScheme(
      brightness: brightness,
      primary: p.primary,
      onPrimary: p.onPrimary,
      primaryContainer: p.primaryContainer,
      onPrimaryContainer: p.onPrimaryContainer,
      secondary: p.secondary,
      onSecondary: p.onSecondary,
      secondaryContainer: p.secondaryContainer,
      onSecondaryContainer: p.onSecondaryContainer,
      surface: p.surface,
      onSurface: p.onSurface,
      surfaceContainerLowest: p.surfaceLowest,
      surfaceContainerLow: p.surfaceLow,
      surfaceContainer: p.surfaceContainer,
      surfaceContainerHigh: p.surfaceHigh,
      surfaceContainerHighest: p.surfaceHighest,
      onSurfaceVariant: p.onSurfaceVariant,
      outline: p.outline,
      outlineVariant: p.outlineVariant,
      error: p.error,
      onError: p.onError,
      errorContainer: p.errorContainer,
      onErrorContainer: p.onErrorContainer,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      // 页面底色 = 竖向渐变（pageGradient，由 MaterialApp.builder 的
      // DecoratedBox 全局铺）；scaffold 透明让渐变透出。
      scaffoldBackgroundColor: Colors.transparent,
      textTheme: buildTextTheme(
        onSurface: p.onSurface,
        onSurfaceVariant: p.onSurfaceVariant,
      ),
      splashFactory: InkSparkle.splashFactory,
      textSelectionTheme: TextSelectionThemeData(
        selectionColor: p.primary.withValues(alpha: light ? 0.24 : 0.28),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 400),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 50),
          padding: const EdgeInsets.symmetric(horizontal: 24),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        dragHandleColor: null,
        dragHandleSize: Size(36, 4),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStatePropertyAll(
            light ? Colors.white : p.onSurface),
        trackOutlineWidth: const WidgetStatePropertyAll(0),
      ),
      extensions: [light ? _lightTokens : _darkTokens],
    );
  }
}

final _lightTokens = _buildTokens(light: true);
final _darkTokens = _buildTokens(light: false);

CcTokens _buildTokens({required bool light}) {
  final motion = MotionTokens(
    fast: AppMotion.quick,
    structure: AppMotion.collapse,
    ambient: AppMotion.breath,
    curve: AppMotion.std,
  );
  return CcTokens(
    glassChrome: _glass(_GlassLevel.chrome, light),
    glassSheet: _glass(_GlassLevel.sheet, light),
    glassCard: _glass(_GlassLevel.card, light),
    motion: motion,
    shape: const ShapeTokens.standard(),
    pageGradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: light
          ? [const Color(0xFFEBF1FE), const Color(0xFFF6F7FC)] // mistTop→Bottom
          : [const Color(0xFF1D222C), const Color(0xFF1B1C23)], // nightTop→Bottom
    ),
    semantic: _semantic(light),
    blurEnabled: true,
  );
}

enum _GlassLevel { chrome, sheet, card }

GlassSpec _glass(_GlassLevel level, bool light) {
  final p = light ? LightPalette.instance : DarkPalette.instance;
  final ink = p.shadowBase; // 带蓝的阴影基色，不用纯黑
  final white = Colors.white;
  return switch (level) {
    // chrome：顶栏胶囊/输入条/浮动键。真模糊，同屏 ≤3。
    _GlassLevel.chrome => GlassSpec(
        fill: light ? white.withValues(alpha: 0.70) : p.smoke.withValues(alpha: 0.72),
        fallbackFill: light
            ? p.surfaceLowest.withValues(alpha: 0.96)
            : p.smoke.withValues(alpha: 0.96),
        blurs: true,
        blur: 18,
        saturation: light ? 1.3 : 1.2,
        hairline: light ? ink.withValues(alpha: 0.08) : white.withValues(alpha: 0.10),
        hairlineWidth: 0.5,
        rim: light ? white.withValues(alpha: 0.85) : white.withValues(alpha: 0.08),
        shadows: [
          BoxShadow(
            color: light
                ? ink.withValues(alpha: 0.08)
                : Colors.black.withValues(alpha: 0.35),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
          if (light)
            BoxShadow(
              color: ink.withValues(alpha: 0.05),
              blurRadius: 3,
              offset: const Offset(0, 1),
            ),
        ],
      ),
    // sheet：底部弹层。真模糊。
    _GlassLevel.sheet => GlassSpec(
        fill: light ? white.withValues(alpha: 0.80) : p.smoke.withValues(alpha: 0.80),
        fallbackFill: light
            ? p.surfaceLowest.withValues(alpha: 0.97)
            : p.smoke.withValues(alpha: 0.97),
        blurs: true,
        blur: 24,
        saturation: 1.4,
        hairline: light ? ink.withValues(alpha: 0.10) : white.withValues(alpha: 0.12),
        hairlineWidth: 0.5,
        rim: light ? white.withValues(alpha: 0.85) : white.withValues(alpha: 0.10),
        shadows: [
          BoxShadow(
            color: light
                ? ink.withValues(alpha: 0.10)
                : Colors.black.withValues(alpha: 0.40),
            blurRadius: 32,
            offset: const Offset(0, 8),
          ),
        ],
      ),
    // card：审批卡/提问卡/引用块。不模糊（design D2：列表区不挂实时模糊）。
    _GlassLevel.card => GlassSpec(
        fill: light ? white.withValues(alpha: 0.62) : white.withValues(alpha: 0.05),
        fallbackFill: light
            ? white.withValues(alpha: 0.92)
            : p.smoke.withValues(alpha: 0.92),
        blurs: false,
        blur: 0,
        saturation: 1,
        hairline: light ? ink.withValues(alpha: 0.06) : white.withValues(alpha: 0.10),
        hairlineWidth: 0.5,
        rim: light ? white.withValues(alpha: 0.60) : white.withValues(alpha: 0.05),
        shadows: [
          BoxShadow(
            color: ink.withValues(alpha: light ? 0.06 : 0.24),
            blurRadius: 8,
            offset: const Offset(0, 1),
          ),
        ],
      ),
  };
}

SemanticTokens _semantic(bool light) {
  final p = light ? LightPalette.instance : DarkPalette.instance;
  return SemanticTokens(
    success: p.success,
    warning: p.warning,
    info: p.info,
    danger: p.error,
    diffAddBg: p.diffAddBg,
    diffAddFg: p.diffAddFg,
    diffDelBg: p.diffDelBg,
    diffDelFg: p.diffDelFg,
  );
}
