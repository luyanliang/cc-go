/// 转录条目渲染（task 6.2）：用户气泡 / 助手流式文本 / 工具折叠行 /
/// notice 提示条；外加本地排队气泡（task 6.3）。
library;

import 'package:material_ui/material_ui.dart';

import '../../state/transcript.dart';

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
        child: Text('发送第一条消息开始', style: TextStyle(color: Colors.grey)),
      );
    }
    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: items.length + queuedTexts.length,
      itemBuilder: (context, index) {
        if (index < items.length) {
          final item = items[index];
          // 权限卡片内联在对话流中（task 7.1）：应答后该条目状态翻转，
          // 自动回到普通工具行（task 7.2）。
          if (item.kind == ItemKind.tool && item.status == 'awaiting-permission') {
            return PermissionCard(
              item: item,
              onRespond: onRespondPermission,
            );
          }
          return TranscriptRow(item: item);
        }
        return _QueuedBubble(text: queuedTexts[index - items.length]);
      },
    );
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
              const Icon(Icons.lock_clock, color: Colors.amber, size: 18),
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
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                const JsonEncoderLite().convert(widget.item.toolInput!),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
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

class TranscriptRow extends StatelessWidget {
  const TranscriptRow({super.key, required this.item});

  final TranscriptItem item;

  @override
  Widget build(BuildContext context) {
    return switch (item.kind) {
      ItemKind.user => _UserBubble(item: item),
      ItemKind.assistant => _AssistantText(item: item),
      ItemKind.tool => _ToolRow(item: item),
      ItemKind.notice => _NoticeBand(item: item),
    };
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
        child: Text(item.text),
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
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 48, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            item.text.isEmpty && streaming ? '…' : item.text,
            style: streaming
                ? TextStyle(color: theme.colorScheme.onSurface.withValues(alpha: 0.7))
                : null,
          ),
        ],
      ),
    );
  }
}

class _ToolRow extends StatelessWidget {
  const _ToolRow({required this.item});

  final TranscriptItem item;

  static const _statusLabel = {
    'running': '运行中',
    'awaiting-permission': '待授权',
    'done': '完成',
    'error': '出错',
    'denied': '已拒绝',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, color) = switch (item.status) {
      'running' => (Icons.sync, Colors.blue),
      'awaiting-permission' => (Icons.lock_clock, Colors.amber),
      'done' => (Icons.check, Colors.green),
      'denied' => (Icons.block, Colors.grey),
      'error' => (Icons.error_outline, Colors.red),
      _ => (Icons.build_circle_outlined, Colors.grey),
    };
    return ExpansionTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: Icon(icon, color: color, size: 20),
      title: Text(
        '${item.toolName ?? "工具"} · ${_statusLabel[item.status] ?? item.status}',
        style: theme.textTheme.bodyMedium,
      ),
      subtitle: item.summary != null && item.summary!.isNotEmpty
          ? Text(item.summary!, maxLines: 1, overflow: TextOverflow.ellipsis)
          : null,
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      children: [
        if (item.toolInput != null && item.toolInput!.isNotEmpty) ...[
          Align(
            alignment: Alignment.centerLeft,
            child: Text('输入', style: theme.textTheme.labelSmall),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              const JsonEncoderLite().convert(item.toolInput!),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
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
    );
  }
}

class _NoticeBand extends StatelessWidget {
  const _NoticeBand({required this.item});

  final TranscriptItem item;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (item.level) {
      'warn' => (Colors.orange.withValues(alpha: 0.12), Colors.orange.shade900),
      'error' => (Colors.red.withValues(alpha: 0.12), Colors.red.shade900),
      _ => (Colors.grey.withValues(alpha: 0.12), Colors.grey.shade800),
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

/// 轻量 JSON 缩进（避免仅为格式化引依赖）。
class JsonEncoderLite {
  const JsonEncoderLite();

  String convert(Map<String, dynamic> map) {
    final buf = StringBuffer();
    _write(map, buf, 0);
    return buf.toString();
  }

  void _write(Object? value, StringBuffer out, int indent) {
    const pad = '  ';
    switch (value) {
      case Map():
        if (value.isEmpty) {
          out.write('{}');
          return;
        }
        out.write('{\n');
        value.forEach((k, v) {
          out.write(pad * (indent + 1));
          out.write('"$k": ');
          _write(v, out, indent + 1);
          out.write(',\n');
        });
        // 去掉最后的 ",\n" 换成 "\n"
        final s = out.toString();
        out
          ..clear()
          ..write(s.substring(0, s.length - 2))
          ..write('\n')
          ..write(pad * indent)
          ..write('}');
      case List():
        out.write('[${value.join(", ")}]');
      case String():
        out.write('"$value"');
      case num():
      case bool():
        out.write('$value');
      case null:
        out.write('null');
      default:
        out.write('"$value"');
    }
  }
}
