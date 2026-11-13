import 'package:flutter_test/flutter_test.dart';
import 'package:cc_go/notify/notification_policy.dart';
import 'package:cc_go/state/session_models.dart';
import 'package:cc_go/transport/host_link.dart';

SessionSummary session(String id, SessionPhase phase, [String title = '会话']) =>
    SessionSummary(
      id: id, title: title, cwd: '/w', phase: phase,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(1),
    );

void main() {
  group('NotificationPolicy', () {
    test('后台收到 permission.request → 高优通知意图（8.2）', () {
      final policy = NotificationPolicy()..setBackground(true);
      final intents = policy.onDaemonEvent(DaemonEvent({
        'type': 'permission.request',
        'sessionId': 's1',
        'itemId': 'i1',
        'name': 'Write',
      }));
      expect(intents.single.kind, NotifyKind.permissionRequest);
      expect(intents.single.sessionId, 's1');
      expect(intents.single.toolName, 'Write');
      expect(intents.single.title, '会话', reason: '标题回退');
    });

    test('前台收到 permission.request → 抑制（前台 UI 直接呈现）', () {
      final policy = NotificationPolicy()..setBackground(false);
      expect(
        policy.onDaemonEvent(DaemonEvent({
          'type': 'permission.request', 'sessionId': 's1', 'itemId': 'i1', 'name': 'Bash',
        })),
        isEmpty,
      );
    });

    test('running→idle 边沿 → 轮次结束通知；idle→idle 不触发（8.3）', () {
      final policy = NotificationPolicy()..setBackground(true);
      policy.onSessions([session('s1', SessionPhase.running, '跑测试')]);
      final intents = policy.onSessions([session('s1', SessionPhase.idle, '跑测试')]);
      expect(intents.single.kind, NotifyKind.turnDone);
      expect(intents.single.title, '跑测试');

      expect(policy.onSessions([session('s1', SessionPhase.idle)]), isEmpty);
    });

    test('前台时边沿不通知，回后台后新边沿恢复', () {
      final policy = NotificationPolicy();
      policy.onSessions([session('s1', SessionPhase.running)]);
      policy.setBackground(false);
      expect(policy.onSessions([session('s1', SessionPhase.idle)]), isEmpty);
      policy.setBackground(true);
      policy.onSessions([session('s1', SessionPhase.running)]);
      expect(policy.onSessions([session('s1', SessionPhase.idle)]), isNotEmpty);
    });

    test('awaiting-permission→idle 不算轮次结束', () {
      final policy = NotificationPolicy()..setBackground(true);
      policy.onSessions([session('s1', SessionPhase.awaitingPermission)]);
      expect(policy.onSessions([session('s1', SessionPhase.idle)]), isEmpty);
    });

    test('标题缓存供通知文案与点按导航使用', () {
      final policy = NotificationPolicy()..setBackground(true);
      policy.onSessions([session('s1', SessionPhase.idle, '修 bug 的会话')]);
      expect(policy.titleOf('s1'), '修 bug 的会话');
    });
  });
}
