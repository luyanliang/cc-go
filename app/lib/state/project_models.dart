/// 项目与历史会话模型（multi-project-history 4.1）：对应 protocol.ts 的
/// ProjectInfo / DiscoveredSession / SessionHistoryResult。纯 Dart。
library;

import 'session_models.dart';
import 'transcript.dart';

/// 已注册项目目录（protocol.ts `ProjectInfo`）。
class ProjectInfo {
  const ProjectInfo({
    required this.path,
    required this.name,
    required this.available,
    required this.sessionCount,
  });

  factory ProjectInfo.fromJson(Map<String, dynamic> json) => ProjectInfo(
        path: json['path'] as String,
        name: json['name'] as String,
        available: json['available'] as bool? ?? true,
        sessionCount: (json['sessionCount'] as num?)?.toInt() ?? 0,
      );

  /// 规范化绝对路径（realpath 解析后）。
  final String path;

  /// 显示名——目录 basename。
  final String name;

  /// false = 目录在文件系统上已不存在（失效，仍展示但置灰）。
  final bool available;

  /// cwd 为该目录的 cc-go 会话数。
  final int sessionCount;
}

/// 发现的一个 Claude Code 会话（protocol.ts `DiscoveredSession`）——
/// 含终端创建的（未托管）与已被 cc-go 管理的。
class DiscoveredSession {
  const DiscoveredSession({
    required this.claudeSessionId,
    required this.title,
    required this.lastActiveAt,
    required this.messageCount,
    required this.managed,
    this.ccGoSessionId,
  });

  factory DiscoveredSession.fromJson(Map<String, dynamic> json) =>
      DiscoveredSession(
        claudeSessionId: json['claudeSessionId'] as String,
        title: json['title'] as String,
        lastActiveAt:
            DateTime.fromMillisecondsSinceEpoch((json['lastActiveAt'] as num).toInt()),
        messageCount: (json['messageCount'] as num?)?.toInt() ?? 0,
        managed: json['managed'] as bool? ?? false,
        ccGoSessionId: json['ccGoSessionId'] as String?,
      );

  /// Claude 自己的会话 id（.jsonl 文件名）。
  final String claudeSessionId;

  /// 首条用户消息摘要（缺失时为时间式标题，daemon 侧已回退）。
  final String title;

  final DateTime lastActiveAt;
  final int messageCount;

  /// 已被某个 cc-go 会话跟踪（创建或导入）。
  final bool managed;

  /// managed 时对应的 cc-go 会话 id。
  final String? ccGoSessionId;
}

/// `session.history` 的一页回放结果。
class HistoryPage {
  const HistoryPage({required this.items, required this.nextBeforeLine});

  factory HistoryPage.fromJson(Map<String, dynamic> json) => HistoryPage(
        items: (json['items'] as List<dynamic>? ?? const [])
            .map((raw) => TranscriptItem.fromJson(raw as Map<String, dynamic>))
            .toList(),
        // null = 更早历史已取尽。
        nextBeforeLine: (json['nextBeforeLine'] as num?)?.toInt(),
      );

  /// 页内按时间正序。
  final List<TranscriptItem> items;

  /// 取下一页（更早）的 cursor；null 表示已到头。
  final int? nextBeforeLine;

  bool get hasMore => nextBeforeLine != null;
}

// ---------------------------------------------------------------------------
// 按项目分组的归并（纯函数，供会话列表 UI 与单测使用）
// ---------------------------------------------------------------------------

/// 会话列表的一个分组：一个已注册项目（或未注册 cwd 的兜底组）。
class ProjectGroup {
  const ProjectGroup({
    required this.name,
    required this.available,
    required this.sessions,
    this.path,
  });

  /// 分组标题（项目显示名）。
  final String name;

  /// 未注册 cwd 的兜底组（路径不在 projects.list 结果里，按目录名展示）。
  final String? path;

  final bool available;
  final List<SessionSummary> sessions;

  bool get registered => path != null;
}

/// 目录 basename（避免仅为这一个函数引 path 包；仅 POSIX 语义）。
String dirBasename(String path) {
  var trimmed = path;
  while (trimmed.length > 1 && trimmed.endsWith('/')) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  final slash = trimmed.lastIndexOf('/');
  return slash < 0 ? trimmed : trimmed.substring(slash + 1);
}

/// 把会话按 cwd 归并进项目分组（task 4.2 的数据层）。
///
/// 规则：
///  - 每个已注册项目一组（即便组内无会话——空分组也要可见，spec
///    project-sessions "空项目呈现"）；available=false 的组照常保留由
///    UI 置灰。
///  - cwd 不在任何已注册项目里的会话进兜底组（组名取 cwd 的 basename，
///    每个不同 cwd 一个组），保证不丢会话。
///  - 组内排序沿用 [compareForList]（待权限置顶 + 最近更新）。
///  - 组间排序：有会话的组按组内最近更新倒序在前；空组与兜底组按名称
///    稳定垫后。
List<ProjectGroup> groupSessionsByProject(
  List<ProjectInfo> projects,
  List<SessionSummary> sessions,
) {
  final byPath = <String, List<SessionSummary>>{};
  final orphans = <String, List<SessionSummary>>{}; // 未注册 cwd → 原始路径
  for (final session in sessions) {
    final known = projects.any((p) => p.path == session.cwd);
    final bucket = known ? byPath : orphans;
    (bucket[session.cwd] ??= []).add(session);
  }

  final groups = <ProjectGroup>[];
  for (final project in projects) {
    final grouped = byPath[project.path] ?? const <SessionSummary>[];
    groups.add(ProjectGroup(
      name: project.name,
      path: project.path,
      available: project.available,
      sessions: [...grouped]..sort(compareForList),
    ));
  }
  for (final cwd in orphans.keys.toList()..sort()) {
    groups.add(ProjectGroup(
      name: dirBasename(cwd),
      path: null,
      available: true,
      sessions: [...orphans[cwd]!]..sort(compareForList),
    ));
  }

  // 组间排序：最近活动优先；空组垫后按名称（同名按路径稳定）。
  DateTime latest(ProjectGroup g) => g.sessions.isEmpty
      ? DateTime.fromMillisecondsSinceEpoch(0)
      : g.sessions
          .map((s) => s.updatedAt)
          .reduce((a, b) => a.isAfter(b) ? a : b);
  groups.sort((a, b) {
    final aEmpty = a.sessions.isEmpty;
    final bEmpty = b.sessions.isEmpty;
    if (aEmpty != bEmpty) return aEmpty ? 1 : -1;
    if (!aEmpty) return latest(b).compareTo(latest(a)); // 更新更晚的组在前
    return a.name == b.name ? (a.path ?? '').compareTo(b.path ?? '') : a.name.compareTo(b.name);
  });
  return groups;
}
