/// 会话列表页（task 5.1–5.3 + multi-project-history 4.2/4.3）：按项目分组
/// （标题=项目显示名，失效目录置灰，空分组提示），组内会话带来源标识与
/// 状态徽标；每组提供"会话历史"入口；新建会话——单可用项目直建，多项目
/// 先弹目录选择（bottom sheet）；待权限会话金色徽标置顶。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../state/host_entry.dart';
import '../voice/voice_controller.dart';
import '../voice/voice_settings_sheet.dart';
import '../state/project_models.dart';
import '../state/projects.dart';
import '../state/providers.dart';
import '../state/session_models.dart';
import '../state/sessions.dart';
import '../transport/reconnecting_link.dart';
import '../transport/ssh/ssh_host_key.dart';
import '../state/app_link.dart';
import '../state/history_api.dart';
import '../state/app_link_provider.dart';
import 'chat/chat_screen.dart';
import 'debug_events_screen.dart';
import 'history/project_history_screen.dart';
import 'host_list_screen.dart';
import 'theme/app_style.dart';
import 'widgets/pill_badge.dart';
import 'widgets/sheet_header.dart';

class SessionListScreen extends ConsumerStatefulWidget {
  const SessionListScreen({super.key});

  @override
  ConsumerState<SessionListScreen> createState() => _SessionListScreenState();
}

class _SessionListScreenState extends ConsumerState<SessionListScreen> {
  /// 折叠的分组键（路径 / 未注册兜底名）——纯视觉状态，不持久化。
  final Set<String> _collapsedGroups = {};

  @override
  Widget build(BuildContext context) {
    final groups = ref.watch(sessionGroupsProvider);
    final appLink = ref.watch(appLinkProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('会话'),
        actions: [
          _ConnectionChip(appLink: appLink),
          PopupMenuButton<String>(
            onSelected: (value) async {
              switch (value) {
                case 'voice':
                  final selected = await showVoiceSettingsSheet(context);
                  if (selected != null) {
                    await VoiceInputController.saveMode(selected);
                  }
                case 'debug':
                  Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => const DebugEventsScreen(),
                  ));
                case 'hosts':
                  Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => const HostListScreen(),
                  ));
                case 'forget':
                  final entries = await ref.read(hostEntriesProvider.future);
                  if (entries.isNotEmpty) {
                    final entry = entries.first;
                    await ref.read(hostEntryStoreProvider).remove(entry.id);
                    await ref.read(sshSecretsStoreProvider).remove(entry.id);
                    final ssh = entry.ssh;
                    if (entry.mode == ConnectionMode.ssh && ssh != null) {
                      // 忘记 SSH 主机指纹 → 下次连接重新 TOFU。
                      await ref
                          .read(sshHostKeyStoreProvider)
                          .remove(sshHostKeyStoreKey(ssh.host, ssh.port));
                    }
                  }
                  ref.invalidate(hostEntriesProvider);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'voice', child: Text('语音输入')),
              PopupMenuItem(value: 'hosts', child: Text('主机管理')),
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
      body: Column(
        children: [
          // 断线状态明示（task 8.4）：重连期间横幅常驻，恢复即消失。
          if (appLink.hasValue)
            StreamBuilder<LinkState>(
              stream: (appLink.value as AppLink).link.states,
              builder: (context, snapshot) {
                if (snapshot.data == LinkState.connected) {
                  return const SizedBox.shrink();
                }
                return Container(
                  width: double.infinity,
                  color: AppColors.warning.withValues(alpha: 0.15),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: const Row(
                    children: [
                      Icon(Icons.cloud_off_outlined, size: 16, color: AppColors.warning),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '未连接电脑，正在重试…',
                          style: TextStyle(color: AppColors.warning, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          Expanded(
            child: groups.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Center(child: Text('会话列表加载失败：$error')),
              data: (list) {
                return RefreshIndicator(
                  onRefresh: () => _refreshAll(ref),
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      for (final group in list) ..._groupTiles(context, group),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 长按分组行注销项目（session-group-interactions 2.4）：确认对话框
  /// 说明"重启 daemon 若以 --project 启动会重新注册"，确认后调
  /// projects.unregister 并刷新列表。仅已注册组有此入口。
  Future<void> _confirmUnregister(ProjectGroup group) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('注销项目 ${group.name}？'),
        content: const Text('注销后该目录不能再新建或发现会话；组内已有会话仍会保留。'
            '注意：如果 daemon 重启时仍以 --project 参数注册该目录，它会重新出现。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('注销'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      final api = ref.read(historyApiProvider);
      if (api == null) {
        throw StateError('连接未就绪');
      }
      final removed = await api.unregisterProject(group.path!);
      await _refreshAll(ref);
      messenger.showSnackBar(SnackBar(
        content: Text(removed ? '已注销项目 ${group.name}' : '该项目本就未注册'),
      ));
    } on Object catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('注销失败：$error')));
    }
  }

  Future<void> _refreshAll(WidgetRef ref) async {
    await Future.wait([
      ref.read(sessionsProvider.notifier).refresh(),
      ref.read(projectsProvider.notifier).refresh(),
    ]);
  }

  /// 一个分组 = 组头 + 会话行（或空分组提示）。
  List<Widget> _groupTiles(BuildContext context, ProjectGroup group) {
    return [
      _GroupHeader(
        group: group,
        collapsed: _collapsedGroups.contains(group.path ?? group.name),
        onToggle: () => setState(() {
          final key = group.path ?? group.name;
          if (!_collapsedGroups.remove(key)) _collapsedGroups.add(key);
        }),
        onLongPress: group.registered
            ? () => _confirmUnregister(group)
            : null,
      ),
      if (group.sessions.isEmpty ||
          !_collapsedGroups.contains(group.path ?? group.name)) ...[
        if (group.sessions.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              group.available
                  ? '该项目还没有会话，点右下角新建'
                  : '目录已不存在，无法新建或发现会话',
              style: TextStyle(
                color: Theme.of(context).hintColor,
                fontSize: 13,
              ),
            ),
          )
        else
          for (final session in group.sessions) _SessionTile(session: session),
      ],
      const Divider(height: 1, indent: 16, endIndent: 16),
    ];
  }

  /// 新建会话（multi-project-history 4.3）：仅一个可用项目 → 直接创建；
  /// 多个 → bottom sheet 先选目录。不可用项目不进入选择。
  Future<void> _createAndOpen(BuildContext context, WidgetRef ref) async {
    // 跨 async gap 使用前先抓取（选择目录是异步的）。
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final projects = (ref.read(projectsProvider).value ?? const <ProjectInfo>[])
        .where((p) => p.available)
        .toList();

    String? cwd;
    if (projects.length > 1) {
      cwd = await _pickProject(context, projects);
      if (cwd == null) return; // 用户取消
    } else if (projects.length == 1) {
      cwd = projects.single.path;
    }
    await _createIn(messenger, navigator, ref, cwd);
  }

  Future<String?> _pickProject(
      BuildContext context, List<ProjectInfo> projects) {
    return showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SheetHeader('选择项目目录'),
            for (final project in projects)
              ListTile(
                key: ValueKey('pick-project-${project.path}'),
                leading: const Icon(Icons.folder_outlined),
                title: Text(project.name),
                subtitle: Text(project.path),
                onTap: () => Navigator.of(sheetContext).pop(project.path),
              ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }

  Future<void> _createIn(
    ScaffoldMessengerState messenger,
    NavigatorState navigator,
    WidgetRef ref,
    String? cwd,
  ) async {
    try {
      final summary = await ref.read(sessionsProvider.notifier).create(cwd: cwd);
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
          color: snapshot.data == LinkState.connected
              ? AppColors.success
              : AppColors.warning,
        ),
      ),
    );
  }
}

/// 分组头：项目显示名 + 路径 + 失效标记（置灰）+ 会话历史入口。
/// 点击折叠/展开该组；长按（已注册项目）注销项目。
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.group,
    required this.collapsed,
    this.onToggle,
    this.onLongPress,
  });

  final ProjectGroup group;
  final bool collapsed;
  final VoidCallback? onToggle;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleStyle = group.available
        ? theme.textTheme.titleSmall
        : theme.textTheme.titleSmall?.copyWith(color: theme.disabledColor);
    final subStyle = theme.textTheme.bodySmall?.copyWith(
      color: group.available ? theme.hintColor : theme.disabledColor,
    );
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
      onTap: onToggle,
      onLongPress: onLongPress,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            collapsed ? Icons.expand_more : Icons.expand_less,
            size: 20,
            color: theme.hintColor,
          ),
          _historyEntry(context, group),
        ],
      ),
      leading: Icon(
        group.available ? Icons.folder_outlined : Icons.folder_off_outlined,
        size: 22,
        color: group.available ? theme.colorScheme.primary : theme.disabledColor,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(group.name,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: titleStyle),
          ),
          if (!group.available) ...[
            const SizedBox(width: 6),
            PillBadge.tinted(
              '目录不存在',
              color: theme.disabledColor.withValues(alpha: 0.15),
              onColor: theme.disabledColor,
            ),
          ],
        ],
      ),
      subtitle: Text(group.path ?? '未注册目录', maxLines: 1, style: subStyle),
    );
  }

  /// 历史导入入口：注册且存在的目录可用；未注册/失效目录禁用但可见。
  Widget _historyEntry(BuildContext context, ProjectGroup group) {
    return (group.available && group.registered)
        ? IconButton(
            key: ValueKey('project-history-${group.path}'),
            tooltip: '会话历史',
            onPressed: () => _openHistory(context),
            icon: const Icon(Icons.history),
          )
        : IconButton(
            key: ValueKey('project-history-disabled-${group.name}'),
            tooltip: group.available ? '未注册目录，历史不可用' : '目录不存在，历史不可用',
            onPressed: null,
            icon: Icon(Icons.history, color: Theme.of(context).disabledColor),
          );
  }

  void _openHistory(BuildContext context) {
    final project = ProjectInfo(
      path: group.path!,
      name: group.name,
      available: group.available,
      sessionCount: group.sessions.length,
    );
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ProjectHistoryScreen(project: project),
    ));
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
      title: Row(
        children: [
          Flexible(
            child: Text(
              session.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: pending
                  ? TextStyle(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.bold)
                  : null,
            ),
          ),
          if (session.imported) ...[
            const SizedBox(width: 6),
            const PillBadge('导入'),
          ],
        ],
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
    final status = switch (phase) {
      SessionPhase.idle => AppStatus.neutral,
      SessionPhase.running => AppStatus.active,
      SessionPhase.awaitingPermission => AppStatus.waiting,
    };
    return Icon(status.icon, color: status.color);
  }
}
