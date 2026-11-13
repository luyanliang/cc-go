/// 会话列表页（task 5.1–5.3）：标题/目录/状态徽标/更新时间，
/// sessions.changed 防抖自动刷新；待权限会话金色徽标置顶；FAB 新建并
/// 直达聊天页。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../state/providers.dart';
import '../state/session_models.dart';
import '../state/sessions.dart';
import '../transport/reconnecting_link.dart';
import '../state/app_link_provider.dart';
import 'chat/chat_screen.dart';
import 'debug_events_screen.dart';

class SessionListScreen extends ConsumerWidget {
  const SessionListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(sessionsProvider);
    final appLink = ref.watch(appLinkProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('会话'),
        actions: [
          _ConnectionChip(appLink: appLink),
          PopupMenuButton<String>(
            onSelected: (value) async {
              switch (value) {
                case 'debug':
                  Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => const DebugEventsScreen(),
                  ));
                case 'forget':
                  await ref.read(credentialStoreProvider).clear();
                  ref.invalidate(credentialsProvider);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'debug', child: Text('原始事件调试')),
              PopupMenuItem(value: 'forget', child: Text('忘记主机')),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: appLink.hasValue
            ? () => _createAndOpen(context, ref)
            : null,
        icon: const Icon(Icons.add),
        label: const Text('新建会话'),
      ),
      body: sessions.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('会话列表加载失败：$error')),
        data: (list) {
          if (list.isEmpty) {
            return const Center(child: Text('还没有会话\n点右下角新建', textAlign: TextAlign.center));
          }
          return RefreshIndicator(
            onRefresh: () => ref.read(sessionsProvider.notifier).refresh(),
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: list.length,
              separatorBuilder: (_, _) => const Divider(height: 1, indent: 56),
              itemBuilder: (context, index) =>
                  _SessionTile(session: list[index]),
            ),
          );
        },
      ),
    );
  }

  Future<void> _createAndOpen(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      final summary = await ref.read(sessionsProvider.notifier).create();
      navigator.push(MaterialPageRoute<void>(
        builder: (_) => ChatScreen(sessionId: summary.id, title: summary.title),
      ));
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('新建失败：$e')));
    }
  }
}

class _ConnectionChip extends ConsumerWidget {
  const _ConnectionChip({required this.appLink});

  final AsyncValue<dynamic> appLink;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!appLink.hasValue) {
      return const Padding(
        padding: EdgeInsets.only(right: 4),
        child: Icon(Icons.cloud_off_outlined, size: 18),
      );
    }
    return StreamBuilder<LinkState>(
      stream: (appLink.value as dynamic).link.states as Stream<LinkState>,
      initialData: LinkState.connecting,
      builder: (context, snapshot) => Padding(
        padding: const EdgeInsets.only(right: 4),
        child: Icon(
          snapshot.data == LinkState.connected
              ? Icons.cloud_done_outlined
              : Icons.cloud_sync_outlined,
          size: 18,
          color: snapshot.data == LinkState.connected ? Colors.green : Colors.orange,
        ),
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({required this.session});

  final SessionSummary session;

  @override
  Widget build(BuildContext context) {
    final pending = session.phase == SessionPhase.awaitingPermission;
    final theme = Theme.of(context);
    return ListTile(
      leading: _PhaseBadge(phase: session.phase),
      title: Text(
        session.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: pending
            ? TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.bold)
            : null,
      ),
      subtitle: Text(
        session.cwd,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      trailing: Text(
        relativeTime(session.updatedAt, DateTime.now()),
        style: theme.textTheme.bodySmall,
      ),
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ChatScreen(sessionId: session.id, title: session.title),
      )),
    );
  }
}

/// 状态徽标：待权限金色（task 5.3）。
class _PhaseBadge extends StatelessWidget {
  const _PhaseBadge({required this.phase});

  final SessionPhase phase;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (phase) {
      SessionPhase.idle => (Icons.check_circle_outline, Colors.grey),
      SessionPhase.running => (Icons.play_circle_outline, Colors.blue),
      SessionPhase.awaitingPermission => (Icons.lock_clock, Colors.amber),
    };
    return Icon(icon, color: color);
  }
}
