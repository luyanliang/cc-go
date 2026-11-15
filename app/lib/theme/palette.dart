/// 调色板：「雾蓝玻璃 Mist Glass」（数值移植自 dsh-Go）+ 手工 OKLCH 的
/// 雾蓝主色（cc-go 身份色，保留）。不用 ColorScheme.fromSeed —— M3
/// tonalSpot 会把彩度推高，压不出"雾"感。
///
/// 浅色 = 雾蓝五档面色 + 四级 ink 文字；深色 =「深海石板」五档 + 四级
/// paper 文字。语义色（success/warning/info/danger）与 diff 四色不随配色
/// 转换（明暗各一套，读起来都舒服）。阴影基色带蓝（#0B152D / #03060D），
/// 不用纯黑。
library;

import 'package:material_ui/material_ui.dart';

import 'oklch.dart';

/// 调色板接口：tokens.dart 只面向它取色，不感知明暗实现。
abstract interface class Palette {
  // ── 主色（cc-go 雾蓝，OKLCH 源坐标注释保留：换强调色 = 全表同 L 换 C/H）──
  Color get primary;
  Color get onPrimary;
  Color get primaryContainer;
  Color get onPrimaryContainer;
  Color get secondary;
  Color get onSecondary;
  Color get secondaryContainer;
  Color get onSecondaryContainer;

  // ── 面色：五档 + 基底 ──
  Color get surface;
  Color get surfaceLowest;
  Color get surfaceLow;
  Color get surfaceContainer;
  Color get surfaceHigh;
  Color get surfaceHighest;

  // ── 文字：四级 ink/paper ──
  Color get onSurface;
  Color get onSurfaceVariant;
  Color get textFaint;
  Color get textGhost;

  // ── 细线 ──
  Color get outline;
  Color get outlineVariant;

  // ── 页面竖向渐变与阴影基色 ──
  Color get pageTop;
  Color get pageBottom;
  Color get shadowBase;

  // ── 语义色（不随配色转）──
  Color get error;
  Color get onError;
  Color get errorContainer;
  Color get onErrorContainer;
  Color get success;
  Color get warning;
  Color get info;

  // ── diff 四色 ──
  Color get diffAddBg;
  Color get diffAddFg;
  Color get diffDelBg;
  Color get diffDelFg;

  // ── 深色玻璃底（chrome/sheet 填充基色）──
  Color get smoke;
}

/// 亮色套（雾蓝玻璃）。
final class LightPalette implements Palette {
  static final instance = LightPalette();

  @override
  final primary = oklch(0.50, 0.09, 255); // oklch(0.50 0.09 255)
  @override
  final onPrimary = oklch(0.985, 0.005, 255);
  @override
  final primaryContainer = oklch(0.92, 0.035, 255);
  @override
  final onPrimaryContainer = oklch(0.34, 0.07, 255);
  @override
  final secondary = oklch(0.52, 0.05, 255);
  @override
  final onSecondary = oklch(0.985, 0.005, 255);
  @override
  final secondaryContainer = oklch(0.90, 0.025, 255);
  @override
  final onSecondaryContainer = oklch(0.35, 0.05, 255);

  @override
  final surface = const Color(0xFFF6F9FE); // mistLow（基底，渐变盖在上面）
  @override
  final surfaceLowest = const Color(0xFFFBFCFF); // mistLowest
  @override
  final surfaceLow = const Color(0xFFF6F9FE); // mistLow
  @override
  final surfaceContainer = const Color(0xFFEEF1F9); // mistContainer
  @override
  final surfaceHigh = const Color(0xFFE7EBF4); // mistHigh
  @override
  final surfaceHighest = const Color(0xFFDFE4EE); // mistHighest

  @override
  final onSurface = const Color(0xFF1E232E); // ink
  @override
  final onSurfaceVariant = const Color(0xFF4F5562); // inkMuted
  @override
  final textFaint = const Color(0xFF646974); // inkFaint
  @override
  final textGhost = const Color(0xFFA1A5AC); // inkGhost

  @override
  final outline = const Color(0xFF7E838D); // outlineLight
  @override
  final outlineVariant = const Color(0xFFDCE0E8); // ruleLight

  @override
  final pageTop = const Color(0xFFEBF1FE); // mistTop
  @override
  final pageBottom = const Color(0xFFF6F7FC); // mistBottom
  @override
  final shadowBase = const Color(0xFF0B152D); // shadowInk（带蓝）

  @override
  final error = const Color(0xFFA54743); // danger 砖玫红
  @override
  final onError = const Color(0xFFFFF6F5);
  @override
  final errorContainer = const Color(0xFFF3DDDB);
  @override
  final onErrorContainer = const Color(0xFF632825);
  @override
  final success = const Color(0xFF337250);
  @override
  final warning = const Color(0xFF936123);
  @override
  final info = const Color(0xFF2971A7);

  @override
  final diffAddBg = const Color(0xFFDCF4E3);
  @override
  final diffAddFg = const Color(0xFF1F613C);
  @override
  final diffDelBg = const Color(0xFFFFE4E2);
  @override
  final diffDelFg = const Color(0xFF923A37);

  @override
  final smoke = const Color(0xFF292E39); // 亮色下不使用
}

/// 暗色套（深海石板）。
final class DarkPalette implements Palette {
  static final instance = DarkPalette();

  @override
  final primary = oklch(0.78, 0.08, 255);
  @override
  final onPrimary = oklch(0.25, 0.05, 255);
  @override
  final primaryContainer = oklch(0.38, 0.07, 255);
  @override
  final onPrimaryContainer = oklch(0.90, 0.03, 255);
  @override
  final secondary = oklch(0.75, 0.04, 255);
  @override
  final onSecondary = oklch(0.25, 0.05, 255);
  @override
  final secondaryContainer = oklch(0.32, 0.03, 255);
  @override
  final onSecondaryContainer = oklch(0.90, 0.02, 255);

  @override
  final surface = const Color(0xFF1C1F28); // night
  @override
  final surfaceLowest = const Color(0xFF14171E);
  @override
  final surfaceLow = const Color(0xFF232730);
  @override
  final surfaceContainer = const Color(0xFF272C36);
  @override
  final surfaceHigh = const Color(0xFF2D323C);
  @override
  final surfaceHighest = const Color(0xFF343944);

  @override
  final onSurface = const Color(0xFFE6E9F0); // paper
  @override
  final onSurfaceVariant = const Color(0xFFB6BBC5); // paperMuted
  @override
  final textFaint = const Color(0xFF9A9EA9); // paperFaint
  @override
  final textGhost = const Color(0xFF656971); // paperGhost

  @override
  final outline = const Color(0xFF656971); // paperGhost 档
  @override
  final outlineVariant = const Color(0xFF343841); // ruleDark

  @override
  final pageTop = const Color(0xFF1D222C); // nightTop
  @override
  final pageBottom = const Color(0xFF1B1C23); // nightBottom
  @override
  final shadowBase = const Color(0xFF03060D); // shadowNight

  @override
  final error = const Color(0xFFE2938E);
  @override
  final onError = const Color(0xFF3A1512);
  @override
  final errorContainer = const Color(0xFF42201D);
  @override
  final onErrorContainer = const Color(0xFFF2C4C0);
  @override
  final success = const Color(0xFF8BCCA6);
  @override
  final warning = const Color(0xFFE6BD7C);
  @override
  final info = const Color(0xFF8CBDE8);

  @override
  final diffAddBg = const Color(0xFF1C3424);
  @override
  final diffAddFg = const Color(0xFF98D5AC);
  @override
  final diffDelBg = const Color(0xFF422423);
  @override
  final diffDelFg = const Color(0xFFF2A7A1);

  @override
  final smoke = const Color(0xFF292E39); // smoke（深色玻璃填充基色）
}
