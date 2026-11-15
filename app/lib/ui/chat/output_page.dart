/// 工具输出全文页（chat-transcript-rows）：ANSI 着色保留、全文可选复制、
/// 一键跳到末尾。从工具详情的头尾摘要进入 —— 超长输出不在消息流里铺开。
library;

import 'package:material_ui/material_ui.dart';

import '../theme/app_style.dart';
import 'render/ansi.dart';
import 'render/copy_button.dart';

class ToolOutputPage extends StatefulWidget {
  const ToolOutputPage({
    required this.title,
    required this.subtitle,
    required this.text,
    this.truncated = false,
    super.key,
  });

  final String title;
  final String subtitle;
  final String text;

  /// 数据侧本身被截断（daemon 下发时已去尾）时提示。
  final bool truncated;

  @override
  State<ToolOutputPage> createState() => _ToolOutputPageState();
}

class _ToolOutputPageState extends State<ToolOutputPage> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _jumpToEnd() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title, style: theme.textTheme.titleMedium),
            Text(widget.subtitle,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '跳到末尾',
            onPressed: _jumpToEnd,
            icon: const Icon(Icons.south),
          ),
          // 复制永远给全文（不受显示截断影响）。
          CopyIconButton(text: widget.text, tooltip: '复制全文'),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          controller: _scroll,
          padding: const EdgeInsets.all(12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: SelectableText.rich(
              TextSpan(
                style: AppMono.denseLoose,
                children: parseAnsiSpans(widget.text),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
