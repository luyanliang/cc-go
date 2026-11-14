/// 助手消息 Markdown 渲染（task 1.2）：gpt_markdown + 自定义代码块。
/// 表格、列表、链接等由 gpt_markdown 默认构建器渲染。
library;

import 'package:material_ui/material_ui.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import 'code_block.dart';
import 'stream_repair.dart';

/// 助手正文 Markdown 视图。空文本显示占位（流式起笔阶段）。
///
/// 流式期间渲染补全后的文本（围栏/表格容错，见 [repairStreamingMarkdown]）；
/// 完成后以原始全文整体替换 —— 上一帧的补全痕迹不会残留。
class AssistantMarkdown extends StatelessWidget {
  const AssistantMarkdown({
    super.key,
    required this.text,
    this.streaming = false,
    this.onLinkTap,
  });

  final String text;

  /// 流式期间为 true：渲染前做残缺 Markdown 补全。
  final bool streaming;

  /// 链接点击回调（测试与后续导航用）。
  final void Function(String url)? onLinkTap;

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) {
      return Text(streaming ? '…' : '', style: Theme.of(context).textTheme.bodyMedium);
    }
    final source = streaming ? repairStreamingMarkdown(text) : text;
    return GptMarkdown(
      source,
      style: Theme.of(context).textTheme.bodyMedium,
      onLinkTap: onLinkTap == null ? null : (url, title) => onLinkTap!(url),
      // 流式期间跳过语法高亮（每帧重解析长代码会卡顿），完成后整体
      // 替换的那一帧再高亮。closed 参数在此不可靠：流式补全会先闭合
      // 围栏，gpt_markdown 看到的 closed 恒为 true。
      codeBuilder: (context, name, code, closed) => CodeBlockView(
        code: code,
        language: name,
        closed: closed,
        highlight: !streaming,
      ),
    );
  }
}
