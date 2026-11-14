/// 会话模型（对应 protocol.ts 的 SessionSummary）。纯 Dart。
library;

enum SessionPhase { idle, running, awaitingPermission }

/// 会话用量与成本（transcript-data-protocol D3）：来自最近一次完成的
/// 回合，成本为会话累计。
class SessionUsage {
  const SessionUsage({
    required this.inputTokens,
    required this.outputTokens,
    required this.cacheReadTokens,
    required this.cacheCreationTokens,
    required this.contextTokens,
    required this.costUsd,
  });

  factory SessionUsage.fromJson(Map<String, dynamic> json) => SessionUsage(
        inputTokens: (json['inputTokens'] as num).toInt(),
        outputTokens: (json['outputTokens'] as num).toInt(),
        cacheReadTokens: (json['cacheReadTokens'] as num).toInt(),
        cacheCreationTokens: (json['cacheCreationTokens'] as num).toInt(),
        contextTokens: (json['contextTokens'] as num).toInt(),
        costUsd: (json['costUsd'] as num).toDouble(),
      );

  final int inputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheCreationTokens;

  /// 下一轮要重发的上下文量级（input + cache read + cache creation）。
  final int contextTokens;

  /// 会话累计成本（美元，Claude Code 估算值）。
  final double costUsd;
}

class SessionSummary {
  const SessionSummary({
    required this.id,
    required this.title,
    required this.cwd,
    required this.phase,
    required this.createdAt,
    required this.updatedAt,
    this.claudeSessionId,
    this.model,
    this.permissionMode = 'default',
    this.origin = 'created',
    this.usage,
  });

  factory SessionSummary.fromJson(Map<String, dynamic> json) {
    return SessionSummary(
      id: json['id'] as String,
      title: (json['title'] as String?)?.trim().isEmpty == true ? '未命名会话' : (json['title'] as String? ?? '未命名会话'),
      cwd: json['cwd'] as String,
      phase: switch (json['phase']) {
        'running' => SessionPhase.running,
        'awaiting-permission' => SessionPhase.awaitingPermission,
        _ => SessionPhase.idle,
      },
      createdAt: DateTime.fromMillisecondsSinceEpoch((json['createdAt'] as num).toInt()),
      updatedAt: DateTime.fromMillisecondsSinceEpoch((json['updatedAt'] as num).toInt()),
      claudeSessionId: json['claudeSessionId'] as String?,
      model: json['model'] as String?,
      permissionMode: json['permissionMode'] as String? ?? 'default',
      origin: json['origin'] as String? ?? 'created',
      usage: json['usage'] is Map<String, dynamic>
          ? SessionUsage.fromJson(json['usage'] as Map<String, dynamic>)
          : null,
    );
  }

  final String id;
  final String title;
  final String cwd;
  final SessionPhase phase;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? claudeSessionId;
  final String? model;
  final String permissionMode;

  /// 会话来源（protocol.ts `origin`）：手机/daemon 创建，或从 Claude Code
  /// 历史会话导入接管。
  final String origin;

  /// 用量与成本；首回合完成前为 null。
  final SessionUsage? usage;

  bool get imported => origin == 'imported';

  String get phaseLabel => switch (phase) {
        SessionPhase.idle => '空闲',
        SessionPhase.running => '运行中',
        SessionPhase.awaitingPermission => '待权限',
      };
}

/// 列表排序：待权限置顶（task 5.3），其余按更新时间倒序。
int compareForList(SessionSummary a, SessionSummary b) {
  final aPending = a.phase == SessionPhase.awaitingPermission;
  final bPending = b.phase == SessionPhase.awaitingPermission;
  if (aPending != bPending) return aPending ? -1 : 1;
  return b.updatedAt.compareTo(a.updatedAt);
}

/// 简洁相对时间（列表行用）。
String relativeTime(DateTime time, DateTime now) {
  final diff = now.difference(time);
  if (diff.inSeconds < 60) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  if (diff.inDays < 7) return '${diff.inDays} 天前';
  final y = time.year == now.year ? '' : '${time.year}/';
  return '$y${time.month}/${time.day}';
}
