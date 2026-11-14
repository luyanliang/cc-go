/// 项目会话历史页（multi-project-history 4.4a）：列出某项目目录下 Claude
/// Code 的全部会话（含终端创建的），按最后活动倒序；已托管会话带标记，
/// 点击进入正常聊天页，外部会话进入只读历史页。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../state/history_api.dart';
import '../../state/project_models.dart';
import '../../state/session_models.dart';
import '../chat/chat_screen.dart';
import 'history_chat_screen.dart';

class ProjectHistoryScreen extends ConsumerWidget {
  const ProjectHistoryScreen({super.key, required this.project});

  final ProjectInfo project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final discovered = ref.watch(discoveredSessionsProvider(project.path));
    return Scaffold(
      appBar: AppBar(title: Text('会话历史 · ${project.name}')),
      body: discovered.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('历史加载失败：$error', textAlign: TextAlign.center),
              const SizedBox(height: 8),
              FilledButton.tonal(
                onPressed: () => ref.invalidate(discoveredSessionsProvider(project.path)),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
        data: (sessions) {
          if (sessions.isEmpty) {
            return Center(
              child: Text(
                '该项目还没有 Claude Code 会话',
                style: TextStyle(color: Theme.of(context).hintColor),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () async =>
                ref.invalidate(discoveredSessionsProvider(project.path)),
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: sessions.length,
              separatorBuilder: (_, _) => const Divider(height: 1, indent: 56),
              itemBuilder: (context, index) =>
                  _DiscoveredTile(session: sessions[index], cwd: project.path),
            ),
          );
        },
      ),
    );
  }
}

class _DiscoveredTile extends StatelessWidget {
  const _DiscoveredTile({required this.session, required this.cwd});

  final DiscoveredSession session;
  final String cwd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final openChat = session.managed && session.ccGoSessionId != null;
    return ListTile(
      leading: Icon(
        openChat ? Icons.link : Icons.terminal,
        color: openChat ? theme.colorScheme.primary : theme.hintColor,
      ),
      title: Text(
        session.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${session.messageCount} 条消息 · ${relativeTime(session.lastActiveAt, DateTime.now())}',
      ),
      trailing: session.managed
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '已托管',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onPrimaryContainer),
              ),
            )
          : null,
      onTap: () {
        final navigator = Navigator.of(context);
        if (openChat) {
          // 已托管的直接进正常聊天页（历史已在其转录快照里）。
          navigator.push(MaterialPageRoute<void>(
            builder: (_) => ChatScreen(
              sessionId: session.ccGoSessionId!,
              title: session.title,
            ),
          ));
        } else {
          navigator.push(MaterialPageRoute<void>(
            builder: (_) => HistoryChatScreen(
              claudeSessionId: session.claudeSessionId,
              cwd: cwd,
              title: session.title,
            ),
          ));
        }
      },
    );
  }
}
