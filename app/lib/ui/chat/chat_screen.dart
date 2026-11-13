/// 聊天页四件套（task 6.1）：header（标题+阶段）/list（快照+实时合并）/
/// rows（四种条目）/composer（发送/排队/打断）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../state/chat_controller.dart';
import '../../state/chat_controller_provider.dart';
import '../../state/session_models.dart';
import 'chat_rows.dart';
import 'composer.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.sessionId, required this.title});

  final String sessionId;
  final String title;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

/// 聊天主体（列表 + composer + 贴底滚动）。直接持有控制器——ChatScreen
/// 负责 provider 装配，测试直接构造 ChatBody。
class ChatBody extends StatefulWidget {
  const ChatBody({super.key, required this.controller});

  final ChatController controller;

  @override
  State<ChatBody> createState() => _ChatBodyState();
}

class _ChatBodyState extends State<ChatBody> {
  final _scrollController = ScrollController();
  bool _nearBottom = true;
  bool _scrollScheduled = false;

  @override
  void initState() {
    super.initState();
    // 内容增长本身不触发滚动事件，_nearBottom 只在像素移动时更新：
    // 用户上翻 → false；贴底动画落位 → true。
    _scrollController.addListener(() {
      final ScrollMetrics m = _scrollController.position;
      final near = m.pixels >= m.maxScrollExtent - 120;
      if (near != _nearBottom) _nearBottom = near;
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 流式期间每个变更帧后贴底（若用户仍在底部附近）。
  /// 必须由转录的 StreamBuilder 调用——外层 build 在流式更新时不会重跑，
  /// 这正是"输出很多时不滚动"那版 bug 的根源。
  void _autoScroll() {
    if (_scrollScheduled) return;
    _scrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollScheduled = false;
      if (!mounted || !_scrollController.hasClients || !_nearBottom) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Column(
      children: [
          Expanded(
            child: StreamBuilder<void>(
              stream: controller.changes,
              builder: (context, _) {
                _autoScroll();
                return TranscriptListView(
                  items: controller.transcript.items,
                  queuedTexts: controller.queuedTexts,
                  loaded: controller.transcript.loaded,
                  scrollController: _scrollController,
                  onRespondPermission: (itemId, allow, allowForSession) =>
                      controller.respondPermission(itemId, allow,
                          allowToolForSession: allowForSession),
                );
              },
            ),
          ),
          StreamBuilder<void>(
            stream: controller.changes,
            builder: (context, _) => Composer(
              running: controller.running,
              busy: controller.busy,
              onSend: (text) async {
                try {
                  await controller.send(text);
                } on Object catch (e) {
                  // 发送失败不让消息静默丢失：把原文带回提示里。
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('发送失败：$e\n消息：$text')),
                    );
                  }
                }
              },
              onCancel: () => controller.cancel(),
            ),
          ),
      ],
    );
  }
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(chatControllerProvider(widget.sessionId));
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title, style: const TextStyle(fontSize: 17)),
            Text(
              switch (controller.transcript.phase) {
                SessionPhase.idle => '空闲',
                SessionPhase.running => '运行中…',
                SessionPhase.awaitingPermission => '等待权限…',
              },
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
      ),
      body: ChatBody(controller: controller),
    );
  }
}
