/// 过程行统一解剖（chat-transcript-rows，几何移植自 dsh-Go StreamRow）：
/// 思考/工具/notice 等过程行共用「左 24 图形列 + 8 间距 + 文字列」的两列
/// 几何，与正文左缘对齐；单行最小高 32、点按高亮向两侧溢出 8（Bleed）；
/// 详情视图长在行下方并带 1px 细线 rail（x=12）。一轮过程的所有行用同一
/// 几何，视觉上成一条连贯线程。
library;

import 'package:material_ui/material_ui.dart';

import '../../theme/squircle.dart';
import '../theme/app_style.dart';
import 'widgets/stream_row.dart';

/// 过程行单行：24dp 图形列 + 8 间距 + 文字列（标题行 + 可选副标题）。
/// [trailing] 给右侧状态小标；[onTap]/[expanded] 由调用方控制展开。
class ProcessLine extends StatelessWidget {
  const ProcessLine({
    required this.glyph,
    required this.glyphColor,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.expanded = false,
    this.titleMaxLines = 1,
    super.key,
  });

  final IconData glyph;
  final Color glyphColor;
  final String title;

  /// 一行概览（命令/路径/预览），超长省略。
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool expanded;

  /// 标题行数：默认 1（过程行一行概览）；notice 等正文型行传 null
  /// 全量换行（评审 #5：长通知不得被省略号截断）。
  final int? titleMaxLines;

  @override
  Widget build(BuildContext context) {
    final head = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // 图形列 = tinted 圆角底块 + 彩色字形（dsh ToolTone 容器样式）。
        StreamLead(
          child: Container(
            width: StreamRow.lead,
            height: StreamRow.lead,
            decoration: BoxDecoration(
              color: glyphColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(7),
            ),
            alignment: Alignment.center,
            child: Icon(glyph, size: 15, color: glyphColor),
          ),
        ),
        const SizedBox(width: StreamRow.gap),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: StreamRow.label(context),
                maxLines: titleMaxLines,
                overflow: titleMaxLines == null ? null : TextOverflow.ellipsis,
              ),
              if (subtitle != null)
                Text(
                  subtitle!,
                  style: StreamRow.detail(context),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 8),
          // FittedBox 缩放兜底：尾部状态标签在小宽度下不溢出。
          Flexible(
            child: FittedBox(fit: BoxFit.scaleDown, child: trailing!),
          ),
        ],
        if (onTap != null) StreamChevron(open: expanded),
      ],
    );
    return StreamRowFrame(onTap: onTap, child: head);
  }
}

/// 行下展开的详情容器：1px 细线 rail 在图形列中线（x=12）上，内容从
/// 文字列（32）起；铺在**代码井**里（codeWellBg + squircle md14 +
/// 0.5px 边，随明暗）。
class ProcessDetail extends StatelessWidget {
  const ProcessDetail({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final (bg, _, border, _, _, _) = CodeWell.of(brightness);
    return StreamThread(
      child: Container(
        margin: const EdgeInsets.only(top: 4, bottom: 6, right: 8),
        padding: const EdgeInsets.all(10),
        width: double.infinity,
        decoration: ShapeDecoration(
          color: bg,
          shape: Squircle.border(
            14,
            side: BorderSide(color: border, width: 0.5),
          ),
        ),
        child: child,
      ),
    );
  }
}

/// 过程行的统一外边距（水平随页面 gutter 16；垂直节奏归行间距阶梯）。
const kProcessRowPadding = EdgeInsets.fromLTRB(16, 0, 16, 0);
