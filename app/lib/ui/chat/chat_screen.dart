/// 聊天页四件套（task 6.1）：header（标题+阶段）/list（快照+实时合并）/
/// rows（四种条目）/composer（发送/排队/打断）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../state/chat_controller.dart';
import '../../state/chat_controller_provider.dart';
import '../../state/session_models.dart';
import '../../state/sessions.dart';
import 'attachment_pick.dart';
import 'chat_rows.dart';
import 'composer.dart';
import 'model_sheet.dart';
import 'usage_chip.dart';

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
              pickAttachment: () => pickAttachmentWithSheet(context),
              slashCommands: controller.slashCommands,
              onSend: (text, attachments) async {
                try {
                  await controller.send(text, attachments: attachments);
                } on Object catch (e) {
                  // 发送失败不让消息静默丢失：把原文带回提示里。
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('发送失败：$e\n消息：$text')),
                    );
                  }
                  // 向 Composer 重新抛出：文本与附件保留在输入区。
                  rethrow;
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
  /// 已为其拉取过指令目录的 controller 实例。重连后 provider 会重建出
  /// 新 controller（旧的 slashCommands 丢失）——按身份识别并重拉。
  ChatController? _commandsLoadedFor;

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(chatControllerProvider(widget.sessionId));
    if (!identical(_commandsLoadedFor, controller)) {
      _commandsLoadedFor = controller;
      Future.microtask(() => controller.loadSlashCommands());
    }
    // 用量/成本来自会话摘要（task 3.5）：sessions.changed 驱动列表刷新，
    // 这里从会话列表 provider 里按 id 取最新摘要。
    SessionSummary? summary;
    final sessions = ref.watch(sessionsProvider).value;
    if (sessions != null) {
      for (final s in sessions) {
        if (s.id == widget.sessionId) {
          summary = s;
          break;
        }
      }
    }
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(child: Text(widget.title, style: const TextStyle(fontSize: 17))),
                if (summary case final s?) ...[
                  const SizedBox(width: 6),
                  // 模型 chip（task 4.3）：点开选择面板；当前模型为空时显示占位。
                  InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => showModelSheet(
                      context,
                      loader: () async {
                        final raw = await controller.models();
                        final entries = <ModelEntry>[];
                        for (final m in (raw['models'] as List<dynamic>? ?? <dynamic>[])) {
                          if (m is! Map<String, dynamic>) continue;
                          entries.add(ModelEntry(
                            id: m['id'] as String? ?? '',
                            displayName: m['displayName'] as String? ?? '',
                          ));
                        }
                        return ModelCatalog(models: entries, current: raw['current'] as String?);
                      },
                      currentModel: s.model,
                      onApply: (model) => controller.configureModel(model),
                    ),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            s.model ?? '模型',
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                          const Icon(Icons.arrow_drop_down, size: 16),
                        ],
                      ),
                    ),
                  ),
                  if (s.usage case final usage?) ...[
                    const SizedBox(width: 6),
                    UsageChip(usage: usage),
                  ],
                ],
              ],
            ),
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
