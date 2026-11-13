/// 通知策略（task 8.2/8.3）：事件与会话状态变化 → 通知意图 的纯映射。
/// 前台抑制、running→idle 边沿检测、会话标题缓存都在这里，可单测。
library;

import '../state/session_models.dart';
import '../transport/host_link.dart';

enum NotifyKind { permissionRequest, turnDone }

class NotifyIntent {
  const NotifyIntent({
    required this.kind,
    required this.sessionId,
    required this.title,
    this.toolName,
  });

  final NotifyKind kind;
  final String sessionId;
  final String title;
  final String? toolName;
}

class NotificationPolicy {
  final Map<String, SessionPhase> _lastPhases = {};
  final Map<String, String> _titles = {};
  var _background = false;

  bool get isBackground => _background;

  /// App 前后台切换（resumed 之外都算后台）。
  void setBackground(bool background) => _background = background;

  /// daemon 事件 → 通知意图。仅后台时产出（前台由 UI 直接呈现，8.2/8.3）。
  List<NotifyIntent> onDaemonEvent(DaemonEvent event) {
    if (!_background || event.type != 'permission.request') return const [];
    final sessionId = event.sessionId;
    if (sessionId == null) return const [];
    return [
      NotifyIntent(
        kind: NotifyKind.permissionRequest,
        sessionId: sessionId,
        title: _titles[sessionId] ?? '会话',
        toolName: event.toolName,
      ),
    ];
  }

  /// 会话列表刷新 → 关注会话 running→idle 边沿 → 轮次结束通知（仅后台）。
  /// 同时维护标题缓存与各会话的最新 phase。
  List<NotifyIntent> onSessions(List<SessionSummary> sessions) {
    final intents = <NotifyIntent>[];
    for (final session in sessions) {
      _titles[session.id] = session.title;
      final last = _lastPhases[session.id];
      if (last == SessionPhase.running && session.phase == SessionPhase.idle) {
        intents.add(NotifyIntent(
          kind: NotifyKind.turnDone,
          sessionId: session.id,
          title: session.title,
        ));
      }
      _lastPhases[session.id] = session.phase;
    }
    return _background ? intents : const [];
  }

  /// 通知点按回查标题（导航用）。
  String? titleOf(String sessionId) => _titles[sessionId];
}
