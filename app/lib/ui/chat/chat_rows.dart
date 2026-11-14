/// 转录行渲染：derive（chat_row_model.dart）出行列表后逐行装配 ——
/// 用户气泡 / 助手 Markdown / 工具折叠行 / 工具分组行 / notice 提示条 /
/// 权限卡 / 排队气泡。结构与分组决策都在 derive 层，这里只认行。
library;

import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../state/transcript.dart';
import 'chat_row_model.dart';
import 'image_viewer.dart';
import 'render/assistant_markdown.dart';
import 'render/copy_button.dart';
import 'tool_views.dart';
import '../theme/app_style.dart';
import '../widgets/mono_block.dart';

class TranscriptListView extends StatelessWidget {
  const TranscriptListView({
    super.key,
    required this.items,
    required this.queuedTexts,
    required this.loaded,
    required this.scrollController,
    this.onRespondPermission,
  });

  final List<TranscriptItem> items;
  final List<String> queuedTexts;
  final bool loaded;
  final ScrollController scrollController;
  final Future<void> Function(String itemId, bool allow, bool allowToolForSession)?
      onRespondPermission;

  @override
  Widget build(BuildContext context) {
    if (!loaded && items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (items.isEmpty && queuedTexts.isEmpty) {
      return const Center(
        child: Text('发送第一条消息开始', style: TextStyle(color: AppColors.neutral)),
      );
    }
    final rows = deriveChatRows(items: items, queuedTexts: queuedTexts);
    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: rows.length,
      // 行主键必须挂给 framework：历史分页向前插页、回合折叠把 N 行收成
      // 2 行时槽位会平移，无 key 的展开/复制状态会跳到别的条目上。
      itemBuilder: (context, index) => KeyedSubtree(
        key: ValueKey<String>(rows[index].key),
        child: _rowWidget(rows[index]),
      ),
    );
  }

  /// 行装配的唯一入口（折叠区内部也走这里，见 [insideFold]）。
  Widget _rowWidget(ChatRow row, {bool insideFold = false}) {
    return switch (row) {
      UserRow(:final item) => _UserBubble(item: item),
      AssistantRow(:final item) => _AssistantText(item: item),
      ToolRow(:final item) => _ToolRow(item: item),
      ToolGroupRow(:final tools) => _ToolGroupTile(tools: tools),
      // 回合折叠行（task 6.2）：展开后过程条目复用同一套行装配。
      TurnFoldRow() => insideFold
          ? const SizedBox.shrink()
          : _TurnFoldTile(
              row: row,
              rowBuilder: (inner) => _rowWidget(inner, insideFold: true),
            ),
      NoticeRow(:final item) => _NoticeBand(item: item),
      // 权限卡片内联在对话流中：应答后该条目状态翻转，derive 下一帧
      // 自动回到普通工具行。折叠资格判定排除了待授权工具，折叠区内
      // 按构造不可能出现。
      PermissionRow(:final item) => insideFold
          ? const SizedBox.shrink()
          : PermissionCard(item: item, onRespond: onRespondPermission),
      QueuedRow(:final text) => _QueuedBubble(text: text),
    };
  }
}

/// 内联权限卡片（task 7.1）：工具名 + 等宽参数 + 允许/拒绝 + 免问勾选。
class PermissionCard extends StatefulWidget {
  const PermissionCard({super.key, required this.item, this.onRespond});

  final TranscriptItem item;
  final Future<void> Function(String itemId, bool allow, bool allowToolForSession)?
      onRespond;

  @override
  State<PermissionCard> createState() => _PermissionCardState();
}

class _PermissionCardState extends State<PermissionCard> {
  bool _allowForSession = false;
  bool _busy = false;

  Future<void> _respond(bool allow) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onRespond?.call(widget.item.id, allow, _allowForSession);
    } on Object {
      // 应答没送达（掉线/超时）——重新启用按钮允许重试；条目状态未变，
      // 卡片依旧是 awaiting-permission。
      if (mounted) setState(() => _busy = false);
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.lock_clock, color: AppColors.waiting, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '请求权限：${widget.item.toolName ?? "工具"}',
                  style: theme.textTheme.titleSmall,
                ),
              ),
            ],
          ),
          if (widget.item.toolInput != null && widget.item.toolInput!.isNotEmpty) ...[
            const SizedBox(height: 8),
            MonoBlock.text(
              const JsonEncoder.withIndent('  ').convert(widget.item.toolInput!),
            ),
          ],
          CheckboxListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _allowForSession,
            onChanged: _busy
                ? null
                : (v) => setState(() => _allowForSession = v ?? false),
            title: const Text('本次会话不再询问此类工具', style: TextStyle(fontSize: 13)),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _busy ? null : () => _respond(false),
                child: const Text('拒绝'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _busy ? null : () => _respond(true),
                child: const Text('允许'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 回合折叠摘要行（task 6.2）：已收起的过程条目一行概览，默认收起；
/// 展开后过程条目经 [rowBuilder] 走同一套行装配还原，最终回答始终在
/// 折叠行之外。
class _TurnFoldTile extends StatelessWidget {
  const _TurnFoldTile({required this.row, required this.rowBuilder});

  final TurnFoldRow row;
  final Widget Function(ChatRow row) rowBuilder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parts = [
      if (row.toolCount > 0) '${row.toolCount} 次工具调用',
      if (row.messageCount > 0) '${row.messageCount} 条消息',
    ];
    return ExpansionTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: Icon(Icons.unfold_more, size: 18, color: theme.colorScheme.outline),
      title: Text('已收起 · ${parts.join(' · ')}', style: theme.textTheme.labelMedium),
      childrenPadding: const EdgeInsets.only(left: 8),
      children: [
        for (final inner in deriveChatRows(items: row.process, foldTurns: false))
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: rowBuilder(inner),
          ),
      ],
    );
  }
}

/// 连续工具调用分组行（task 3.2）：折叠单行显示次数与工具名概览，
/// 展开列出组内每次调用（复用 _ToolRow）。
class _ToolGroupTile extends StatelessWidget {
  const _ToolGroupTile({required this.tools});

  final List<TranscriptItem> tools;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = tools.map((t) => t.toolName ?? '工具').toSet().join(' · ');
    return ExpansionTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: const Icon(Icons.build_circle_outlined, size: 20),
      title: Text(
        '工具调用 × ${tools.length}',
        style: theme.textTheme.bodyMedium,
      ),
      subtitle: names.isEmpty
          ? null
          : Text(names, maxLines: 1, overflow: TextOverflow.ellipsis),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      children: [for (final tool in tools) _ToolRow(item: tool)],
    );
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.item});

  final TranscriptItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.fromLTRB(48, 4, 12, 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 可选中文本：长按拖选后经系统选择菜单复制（task 1.3）。
            SelectableText(item.text),
            // 附件缩略图（task 2.4）：点开全屏查看。
            if (item.attachments.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                alignment: WrapAlignment.end,
                children: [
                  for (final attachment in item.attachments)
                    GestureDetector(
                      onTap: () => showAttachmentFullScreen(context, attachment),
                      child: Container(
                        width: 96,
                        height: 96,
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          color: scheme.surfaceContainerHighest,
                        ),
                        child: Image.memory(
                          base64Decode(attachment.dataBase64),
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AssistantText extends StatelessWidget {
  const _AssistantText({required this.item});

  final TranscriptItem item;

  @override
  Widget build(BuildContext context) {
    final streaming = item.isStreamingAssistant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 48, 4),
      child: Opacity(
        // 流式期间整体降不透明度示意"未完成"；完成后恢复。
        opacity: streaming ? 0.85 : 1.0,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // thinking 数据一直在协议里流动（task 5.1 补展示）：
            // 默认收起，点开可读全文。
            if (item.thinking.isNotEmpty) _ThinkingSection(thinking: item.thinking),
            // 链接点击用系统浏览器打开（gpt_markdown 只在回调非空时
            // 才挂点击处理器，不传就是死链）。
            AssistantMarkdown(
              text: item.text,
              streaming: streaming,
              onLinkTap: (url) => launchUrl(Uri.parse(url)),
            ),
            // 完成且非空才提供整条复制（复制的是 Markdown 原文）。
            if (!streaming && item.text.isNotEmpty)
              CopyIconButton(text: item.text, tooltip: '复制消息'),
          ],
        ),
      ),
    );
  }
}

/// 助手思考段：折叠单行（默认收起），展开显示全文。
class _ThinkingSection extends StatelessWidget {
  const _ThinkingSection({required this.thinking});

  final String thinking;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExpansionTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      tilePadding: EdgeInsets.zero,
      leading: Icon(Icons.psychology_outlined, size: 18, color: theme.colorScheme.outline),
      title: Text('思考过程', style: theme.textTheme.labelMedium),
      childrenPadding: const EdgeInsets.only(bottom: 8),
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(8),
          ),
          child: SelectableText(
            thinking,
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

class _ToolRow extends StatelessWidget {
  const _ToolRow({required this.item});

  final TranscriptItem item;

  /// 副标题：定制一行概览（命令/路径/模式）优先，否则结果摘要。
  Text? _subtitle() {
    final text = toolSubtitleFor(item) ?? item.summary;
    if (text == null || text.isEmpty) return null;
    return Text(text, maxLines: 1, overflow: TextOverflow.ellipsis);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 一张表：状态 → (标签, 语义, 字形)。新增状态只改这里；语义色一律
    // 走 AppStatus，避免标签/语义/字形三处 switch 各自漂移。
    final (label, status, icon) = switch (item.status) {
      'running' => ('运行中', AppStatus.active, Icons.sync),
      'awaiting-permission' => ('待授权', AppStatus.waiting, Icons.lock_clock),
      'done' => ('完成', AppStatus.success, Icons.check_circle),
      'denied' => ('已拒绝', AppStatus.neutral, Icons.block),
      'error' => ('出错', AppStatus.error, Icons.error_outline),
      _ => (item.status, AppStatus.neutral, Icons.build_circle_outlined),
    };
    return ExpansionTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: Icon(icon, color: status.color, size: 20),
      title: Text(
        '${item.toolName ?? "工具"} · $label',
        style: theme.textTheme.bodyMedium,
      ),
      subtitle: _subtitle(),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      children: [
        // 定制视图优先（task 4.2/4.3）；未知工具回退通用 JSON 输入 + 摘要。
        if (toolDetailFor(item) case final detail?)
          detail
        else ...[
          if (item.toolInput != null && item.toolInput!.isNotEmpty) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: Text('输入', style: theme.textTheme.labelSmall),
            ),
            MonoBlock.text(
              const JsonEncoder.withIndent('  ').convert(item.toolInput!),
            ),
          ],
          if (item.summary != null && item.summary!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: Text('结果', style: theme.textTheme.labelSmall),
            ),
            Text(item.summary!, style: theme.textTheme.bodySmall),
          ],
        ],
        // 结果图片（task 3.4）：所有工具类型统一在展开区尾部展示。
        if (item.resultImages.isNotEmpty) ...[
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final image in item.resultImages)
                GestureDetector(
                  onTap: () => showAttachmentFullScreen(context, image),
                  child: Container(
                    width: 128,
                    height: 128,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      color: theme.colorScheme.surfaceContainerHighest,
                    ),
                    child: Image.memory(base64Decode(image.dataBase64), fit: BoxFit.cover),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _NoticeBand extends StatelessWidget {
  const _NoticeBand({required this.item});

  final TranscriptItem item;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (item.level) {
      'warn' => (AppColors.warning.withValues(alpha: 0.12), AppColors.warningOnTint),
      'error' => (AppColors.error.withValues(alpha: 0.12), AppColors.errorOnTint),
      _ => (AppColors.neutral.withValues(alpha: 0.12), AppColors.neutralOnTint),
    };
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: Text(item.text, style: TextStyle(color: fg, fontSize: 13)),
    );
  }
}

class _QueuedBubble extends StatelessWidget {
  const _QueuedBubble({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.fromLTRB(48, 4, 12, 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(text),
            const SizedBox(height: 2),
            Text('已排队', style: theme.textTheme.labelSmall),
          ],
        ),
      ),
    );
  }
}
