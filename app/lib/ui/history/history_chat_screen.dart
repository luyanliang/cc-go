/// 只读历史聊天页（multi-project-history 4.4b）：session.history 回放条目
/// 复用现有 chat 渲染；composer 禁用 + 显式"接管续聊"（session.import 成功
/// 后替换为正常聊天页）；滚到顶部或点按"加载更早"翻上一页。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../state/history_controller_provider.dart';
import '../../state/history_controller.dart';
import '../../state/sessions.dart';
import '../chat/chat_rows.dart';
import '../chat/chat_screen.dart';

class HistoryChatScreen extends ConsumerStatefulWidget {
  const HistoryChatScreen({
    super.key,
    required this.claudeSessionId,
    required this.cwd,
    required this.title,
  });

  final String claudeSessionId;
  final String cwd;
  final String title;

  @override
  ConsumerState<HistoryChatScreen> createState() => _HistoryChatScreenState();
}

class _HistoryChatScreenState extends ConsumerState<HistoryChatScreen> {
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    // 贴近顶部时自动翻上一页（按钮是保底入口）。
    _scrollController.addListener(() {
      if (!_scrollController.hasClients) return;
      final controller = _controller;
      if (_scrollController.position.pixels < 120 &&
          controller.hasMore &&
          !controller.loadingOlder &&
          !controller.loading) {
        unawaited(_loadOlder());
      }
    });
  }

  HistoryController get _controller =>
      ref.read(historyControllerProvider((widget.claudeSessionId, widget.cwd)));

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 翻上一页后把滚动位置下移新增高度，视口锚在旧条目上不跳动。
  Future<void> _loadOlder() async {
    final controller = _controller;
    final oldMaxExtent = _scrollController.hasClients
        ? _scrollController.position.maxScrollExtent
        : null;
    final started = await controller.loadOlder();
    if (!started || oldMaxExtent == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final delta = _scrollController.position.maxScrollExtent - oldMaxExtent;
      if (delta > 0) {
        _scrollController.jumpTo(_scrollController.position.pixels + delta);
      }
    });
  }

  Future<void> _takeOver() async {
    final controller = _controller;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      final summary = await controller.importSession(title: widget.title);
      // 即时刷新列表（daemon 也会广播 sessions.changed，这里是兜底）。
      unawaited(ref.read(sessionsProvider.notifier).refresh());
      navigator.pushReplacement(MaterialPageRoute<void>(
        builder: (_) => ChatScreen(sessionId: summary.id, title: summary.title),
      ));
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('接管失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller =
        ref.watch(historyControllerProvider((widget.claudeSessionId, widget.cwd)));
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 17)),
            Text('只读历史', style: theme.textTheme.labelSmall),
          ],
        ),
      ),
      // 整个 body 订阅 changes：顶部分页条与底部接管条也随回放状态重建。
      body: StreamBuilder<void>(
        stream: controller.changes,
        builder: (context, _) => Column(
          children: [
            _OlderBar(controller: controller, onLoadOlder: _loadOlder),
            Expanded(
              child: () {
                if (controller.loading) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (controller.error != null && controller.items.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('历史加载失败：${controller.error}'),
                        const SizedBox(height: 8),
                        FilledButton.tonal(
                          onPressed: () => unawaited(controller.loadInitial()),
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  );
                }
                if (controller.items.isEmpty) {
                  return Center(
                    child: Text('该会话没有可显示的历史',
                        style: TextStyle(color: theme.hintColor)),
                  );
                }
                return TranscriptListView(
                  items: controller.items,
                  queuedTexts: const [],
                  loaded: true,
                  scrollController: _scrollController,
                );
              }(),
            ),
            _ReadOnlyBar(controller: controller, onTakeOver: _takeOver),
          ],
        ),
      ),
    );
  }
}

/// 顶部翻页条：有更早 → 按钮/加载中；取尽 → 灰字提示。
class _OlderBar extends StatelessWidget {
  const _OlderBar({required this.controller, required this.onLoadOlder});

  final HistoryController controller;
  final Future<void> Function() onLoadOlder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!controller.hasMore && !controller.loadingOlder) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text('已是最早消息',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.hintColor)),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: controller.loadingOlder
          ? const SizedBox(
              height: 28,
              width: 28,
              child: Center(
                  child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))),
            )
          : TextButton.icon(
              onPressed: onLoadOlder,
              icon: const Icon(Icons.arrow_upward, size: 16),
              label: const Text('加载更早'),
            ),
    );
  }
}

/// 底部只读条：禁用输入样式 + 接管按钮。
class _ReadOnlyBar extends StatelessWidget {
  const _ReadOnlyBar({required this.controller, required this.onTakeOver});

  final HistoryController controller;
  final Future<void> Function() onTakeOver;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                alignment: Alignment.centerLeft,
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Row(
                  children: [
                    Icon(Icons.lock_outline,
                        size: 16, color: theme.hintColor),
                    const SizedBox(width: 8),
                    Text('只读历史，接管后可继续对话',
                        style: TextStyle(color: theme.hintColor, fontSize: 13)),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: controller.importing ? null : onTakeOver,
              icon: controller.importing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download_for_offline_outlined, size: 18),
              label: const Text('接管续聊'),
            ),
          ],
        ),
      ),
    );
  }
}
