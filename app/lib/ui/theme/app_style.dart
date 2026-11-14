/// UI 风格令牌：语义状态色 / 状态视觉（图标+颜色）/ 等宽文本样式 /
/// 代码块调色板的单一来源。界面代码不直接写 `Colors.*` 或手拼
/// `TextStyle(fontFamily: 'monospace')` —— 从这里取。
///
/// 当前为亮色主题取值；将来做亮/暗双主题（ARCHITECTURE.md M4 项）时
/// 只改这里，调用点自动跟进。
library;

import 'package:material_ui/material_ui.dart';

/// 语义状态色（会话阶段 / 工具状态 / todo / 连接状态共用）。
abstract final class AppColors {
  /// 完成 / 已连接。
  static const success = Colors.green;

  /// 运行中 / 进行中。
  static const active = Colors.blue;

  /// 待权限（金色徽标置顶，task 5.3）。
  static const waiting = Colors.amber;

  /// 连接中 / 重连 / 警告。
  static const warning = Colors.orange;

  /// 出错。
  static const error = Colors.red;

  /// 空闲 / 已拒绝 / 未知。
  static const neutral = Colors.grey;

  /// 同色系 shade800 加深的前景色：铺淡底（notice 条 alpha ≈ 0.12）或
  /// 半透明 surface（diff 行 alpha 0.5）上保证正文可读。统一取 shade800
  /// —— 此前 notice 用 900/diff 用 800 混杂，diff 两侧颜色成对才协调。
  static final successOnTint = Colors.green.shade800;
  static final warningOnTint = Colors.orange.shade800;
  static final errorOnTint = Colors.red.shade800;
  static final neutralOnTint = Colors.grey.shade800;
}

/// 聊天代码块的深色底调色板（github-dark）：代码卡固定深色底，不随
/// 主题走；集中一处，将来换肤只改这里。
abstract final class CodePalette {
  static const background = Color(0xFF161B22);
  static const muted = Color(0xFF8B949E);
  static const text = Color(0xFFC9D1D9);
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

/// 等宽文本样式：此前 9 处手写 `fontFamily: 'monospace'`（字号 12/13
/// 混用），现统一为这三档。
abstract final class AppMono {
  static const family = 'monospace';

  /// 12px：工具内容块、调试帧等紧凑场合。
  static const dense = TextStyle(fontFamily: family, fontSize: 12);

  /// 12px + 1.4 行高：多行 ANSI 输出。
  static const denseLoose = TextStyle(
      fontFamily: family, fontSize: 12, height: 1.4);

  /// 13px + 1.45 行高：Markdown 代码块、斜杠指令名。
  static const code = TextStyle(fontFamily: family, fontSize: 13, height: 1.45);
}
