/// 会话模型（对应 protocol.ts 的 SessionSummary）。纯 Dart。
library;

enum SessionPhase { idle, running, awaitingPermission }

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
