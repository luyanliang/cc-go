/// UI 风格令牌：语义状态色 / 状态视觉（图标+颜色）/ 等宽文本样式 /
/// 代码块调色板的单一来源。界面代码不直接写 `Colors.*` 或手拼
/// `TextStyle(fontFamily: …)` —— 从这里取。
///
/// 语义色取 dsh-Go 语义色板的亮色值（success #337250 / warning #936123 /
/// info #2971A7 系）；暗色适配走 `context.tokens.semantic`（theme 层），
/// 调用点迁移后这里的静态入口退役。等宽字体已换成打包的 JetBrainsMono
/// （禁连字），档位对齐 dsh-Go。
library;

import 'package:material_ui/material_ui.dart';

import '../../theme/typography.dart';

/// 语义状态色（会话阶段 / 工具状态 / todo / 连接状态共用）。
abstract final class AppColors {
  /// 完成 / 已连接。
  static const success = Color(0xFF337250);

  /// 运行中 / 进行中。
  static const active = Color(0xFF2971A7); // info 蓝

  /// 待权限（金色徽标置顶，task 5.3）。
  static const waiting = Color(0xFF936123);

  /// 连接中 / 重连 / 警告。
  static const warning = Color(0xFFB07A2A); // warning 提亮一档，与 waiting 区分

  /// 出错。
  static const error = Color(0xFFA54743); // danger 砖玫红

  /// 空闲 / 已拒绝 / 未知。
  static const neutral = Color(0xFF646974); // inkFaint

  /// 淡底/半透明底上的同系前景：notice 条（alpha ≈ 0.12）或 diff 行
  /// （alpha 0.5）上保证正文可读。diff 两侧颜色成对才协调。
  static const successOnTint = Color(0xFF1F613C);
  static const warningOnTint = Color(0xFF77521B);
  static const errorOnTint = Color(0xFF923A37);
  static const neutralOnTint = Color(0xFF4F5562);
}

/// 代码井（code well）调色板：随明暗各一套（数值取 dsh-Go NeutralTones
/// 的代码井组）。代码块、工具详情井共用 —— 亮色是浅灰蓝井，暗色是深井。
abstract final class CodeWell {
  static const lightBg = Color(0xFFEDF0F6);
  static const lightHeader = Color(0xFFE7EBF3);
  static const lightBorder = Color(0xFFDBDEE5);
  static const lightLineNumber = Color(0xFF7D8088);
  static const lightComment = Color(0xFF636975);
  static const lightText = Color(0xFF1E232E);

  static const darkBg = Color(0xFF14171E);
  static const darkHeader = Color(0xFF1A1E26);
  static const darkBorder = Color(0xFF2F333A);
  static const darkLineNumber = Color(0xFF71747D);
  static const darkComment = Color(0xFF868C97);
  static const darkText = Color(0xFFE6E9F0);

  static (Color, Color, Color, Color, Color, Color) of(Brightness b) =>
      b == Brightness.dark
          ? (darkBg, darkHeader, darkBorder, darkLineNumber, darkComment,
              darkText)
          : (lightBg, lightHeader, lightBorder, lightLineNumber, lightComment,
              lightText);
}

/// 状态语义：会话阶段（idle/running/awaitingPermission）、工具状态
/// （running/awaiting-permission/done/denied/error）、todo
/// （completed/in_progress/pending）、连接状态（connected/…）都先映射
/// 到这六个语义，再取统一视觉 —— 同一语义在任何页面同色。
enum AppStatus {
  /// 完成、已连接。
  success,

  /// 运行中、进行中。
  active,

  /// 待权限。
  waiting,

  /// 连接中 / 重连中 / 警告。
  warning,

  /// 出错。
  error,

  /// 空闲、已拒绝、未知。
  neutral,
}

extension AppStatusVisual on AppStatus {
  /// 默认图标。个别场景需要更贴切的字形（工具行的 sync、denied 的
  /// block、todo 未开始的 radio_button_unchecked）时，调用方覆写图标，
  /// 颜色仍取 [color] —— 色彩不允许各处自定。
  IconData get icon => switch (this) {
        AppStatus.success => Icons.check_circle,
        AppStatus.active => Icons.play_circle_outline,
        AppStatus.waiting => Icons.lock_clock,
        // 通用警示字形；连接场景自带上云字形（cloud_sync 等）由调用方覆写。
        AppStatus.warning => Icons.warning_amber_outlined,
        AppStatus.error => Icons.error_outline,
        AppStatus.neutral => Icons.check_circle_outline,
      };

  /// 语义色。
  Color get color => switch (this) {
        AppStatus.success => AppColors.success,
        AppStatus.active => AppColors.active,
        AppStatus.waiting => AppColors.waiting,
        AppStatus.warning => AppColors.warning,
        AppStatus.error => AppColors.error,
        AppStatus.neutral => AppColors.neutral,
      };

  /// (图标, 颜色) 二元组，便于 switch 表达式直接解构。
  (IconData, Color) get visual => (icon, color);
}

/// 工具名 → 视觉类别图形映射：同类工具同字形（terminal/search/文档
/// 编辑/checklist/通用），工具行的单行摘要用 —— 名称各异时观感仍成族。
abstract final class AppToolGlyph {
  /// 映射到类别字形；未知工具回退通用字形。
  static IconData forTool(String tool) {
    final name = tool.toLowerCase();
    if (name == 'bash' || name == 'shell' || name.endsWith('bash')) {
      return Icons.terminal_outlined;
    }
    if (name == 'grep' || name == 'glob' || name == 'search') {
      return Icons.search_outlined;
    }
    if (name == 'read' || name == 'view' || name == 'notebookread') {
      return Icons.description_outlined;
    }
    if (name == 'edit' || name == 'write' || name == 'multiedit' ||
        name == 'notebookedit') {
      return Icons.edit_outlined;
    }
    if (name.toLowerCase() == 'todowrite' || name == 'task') {
      return Icons.checklist_outlined;
    }
    return Icons.extension_outlined; // 未知工具：通用扩展字形
  }
}

/// 等宽文本样式（JetBrainsMono，禁连字）：五档对齐 dsh-Go ——
/// code 13/1.55（代码块）、denseLoose 12/1.5（ANSI 输出）、dense 12
/// （紧凑块）、label 12/1.35（语言标签等）、summary 12.5（工具行摘要）。
abstract final class AppMono {
  static const family = AppType.monoFamily;

  /// 12px：工具内容块、调试帧等紧凑场合。
  static const dense = TextStyle(
      fontFamily: family,
      fontFamilyFallback: AppType.monoFallback,
      fontFeatures: AppType.noLigatures,
      fontSize: 12);

  /// 12px + 1.5 行高：多行 ANSI 输出。
  static const denseLoose = TextStyle(
      fontFamily: family,
      fontFamilyFallback: AppType.monoFallback,
      fontFeatures: AppType.noLigatures,
      fontSize: 12,
      height: 1.5);

  /// 13px + 1.55 行高：Markdown 代码块、斜杠指令名。
  static const code = TextStyle(
      fontFamily: family,
      fontFamilyFallback: AppType.monoFallback,
      fontFeatures: AppType.noLigatures,
      fontSize: 13,
      height: 1.55);

  /// 12px + 1.35 行高：代码块语言标签等小标签。
  static const label = TextStyle(
      fontFamily: family,
      fontFamilyFallback: AppType.monoFallback,
      fontFeatures: AppType.noLigatures,
      fontSize: 12,
      height: 1.35);

  /// 12.5px：工具行摘要（命令/路径）。
  static const summary = TextStyle(
      fontFamily: family,
      fontFamilyFallback: AppType.monoFallback,
      fontFeatures: AppType.noLigatures,
      fontSize: 12.5,
      height: 1.4);
}
