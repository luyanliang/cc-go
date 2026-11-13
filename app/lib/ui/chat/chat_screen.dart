/// 聊天页四件套（task 6.1）：header（标题+阶段）/list（快照+实时合并）/
/// rows（四种条目）/composer（发送/排队/打断）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

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

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _scrollController = ScrollController();
  bool _nearBottom = true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(() {
      final ScrollMetrics m = _scrollController.position;
      final near = m.pixels >= m.maxScrollExtent - 80;
      if (near != _nearBottom) _nearBottom = near;
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _autoScroll(int itemCount) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients || !_nearBottom) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(chatControllerProvider(widget.sessionId));
    final transcript = controller.transcript;
    _autoScroll(transcript.items.length);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title, style: const TextStyle(fontSize: 17)),
            Text(
              switch (transcript.phase) {
                SessionPhase.idle => '空闲',
                SessionPhase.running => '运行中…',
                SessionPhase.awaitingPermission => '等待权限…',
              },
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<void>(
              stream: controller.changes,
              builder: (context, _) => TranscriptListView(
                items: controller.transcript.items,
                queuedTexts: controller.queuedTexts,
                loaded: controller.transcript.loaded,
                scrollController: _scrollController,
                onRespondPermission: (itemId, allow, allowForSession) =>
                    controller.respondPermission(itemId, allow,
                        allowToolForSession: allowForSession),
              ),
            ),
          ),
          StreamBuilder<void>(
            stream: controller.changes,
            builder: (context, _) => Composer(
              running: controller.running,
              busy: controller.busy,
              onSend: (text) => controller.send(text),
              onCancel: () async {
                await controller.cancel();
                controller.clearQueued();
              },
            ),
          ),
        ],
      ),
    );
  }
}
