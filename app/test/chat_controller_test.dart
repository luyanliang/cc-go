import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:cc_go/state/chat_controller.dart';
import 'package:cc_go/state/session_models.dart';
import 'package:cc_go/transport/host_link.dart';
import 'package:cc_go/transport/reconnecting_link.dart';

class FakeLink implements HostLinkBase {
  final eventsController = StreamController<DaemonEvent>.broadcast();
  final calls = <(String, Map<String, dynamic>)>[];

  @override
  Stream<DaemonEvent> get events => eventsController.stream;

  @override
  Future<dynamic> call(String method, [Map<String, dynamic> params = const {}]) async {
    calls.add((method, params));
    if (method == 'session.watch') {
      return {
        'snapshot': {'items': const <dynamic>[], 'phase': 'idle'},
        'summary': {'id': params['sessionId']},
      };
    }
    return {};
  }

  @override
  Future<void> close({String reason = ''}) async => eventsController.close();

  void emitSession(String sessionId, Map<String, dynamic> event) =>
      eventsController.add(DaemonEvent({
        'type': 'session',
        'sessionId': sessionId,
        'event': event,
      }));
}

void main() {
  late FakeLink fake;
  late ReconnectingHostLink wrapped;
  late ChatController controller;

  setUp(() async {
    fake = FakeLink();
    wrapped = ReconnectingHostLink(
      connector: () async => fake,
      baseDelay: const Duration(milliseconds: 1),
    );
    controller = ChatController(sessionId: 's1', link: wrapped);
    await wrapped.start();
    await wrapped.states.firstWhere((s) => s == LinkState.connected);
  });

  tearDown(() async {
    controller.dispose();
    await wrapped.stop();
  });

  test('打开即 watch，收到本会话快照', () async {
    fake.emitSession('s1', {
      'ev': 'snapshot',
      'items': [
        {'kind': 'user', 'id': 'u1', 'text': 'hi', 'createdAt': 1},
      ],
      'phase': 'idle',
      'pendingPermission': null,
    });
    await Future<void>.delayed(Duration.zero);
    expect(controller.transcript.loaded, isTrue);
    expect(controller.transcript.items.single.text, 'hi');
    expect(
      fake.calls.map((c) => c.$1),
      contains('session.watch'),
    );
  });

  test('别的会话的事件被忽略', () async {
    fake.emitSession('other', {
      'ev': 'snapshot',
      'items': [
        {'kind': 'user', 'id': 'x', 'text': '别人的', 'createdAt': 1},
      ],
      'phase': 'running',
    });
    fake.emitSession('other', {'ev': 'phase', 'phase': 'running'});
    await Future<void>.delayed(Duration.zero);
    expect(controller.transcript.phase, SessionPhase.idle,
        reason: '别的会话的 phase 不影响本会话');
    expect(controller.transcript.items.where((i) => i.text == '别人的'), isEmpty,
        reason: '别的会话的条目不进入本转录');
  });

  test('空闲发送 → session.prompt(queue)；运行中发送 → 仅排队，idle 边沿送出', () async {
    await controller.send('第一条');
    expect(
      fake.calls.where((c) => c.$1 == 'session.prompt').single.$2,
      {'sessionId': 's1', 'text': '第一条', 'mode': 'queue'},
    );
    expect(controller.queuedTexts, isEmpty);

    // 运行中连发两条：只入队，不发 RPC（打断即停，daemon 队列不掺和）
    fake.emitSession('s1', {'ev': 'phase', 'phase': 'running'});
    await Future<void>.delayed(Duration.zero);
    await controller.send('第二条');
    await controller.send('第三条');
    expect(controller.queuedTexts, ['第二条', '第三条']);
    expect(
      fake.calls.where((c) => c.$1 == 'session.prompt').length,
      1,
      reason: '运行中不发出排队消息',
    );

    // 轮次结束（running→idle）→ 自动送出第一条排队
    fake.emitSession('s1', {'ev': 'phase', 'phase': 'idle'});
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(controller.queuedTexts, ['第三条'], reason: '一次 idle 边沿只送一条');
    expect(
      fake.calls.where((c) => c.$1 == 'session.prompt').last.$2['text'],
      '第二条',
    );
  });

  test('打断 → session.cancel', () async {
    fake.emitSession('s1', {'ev': 'phase', 'phase': 'running'});
    await Future<void>.delayed(Duration.zero);

    await controller.cancel();
    controller.clearQueued();
    expect(
      fake.calls.map((c) => c.$1),
      contains('session.cancel'),
    );
    expect(controller.running, isTrue, reason: 'phase 由 daemon 事件驱动，不本地伪造');
  });

  test('流式 assistant 条目更新触发监听', () async {
    var notifications = 0;
    final sub = controller.changes.listen((_) => notifications++);
    fake.emitSession('s1', {
      'ev': 'item.added',
      'item': {'kind': 'assistant', 'id': 'a1', 'text': '半', 'status': 'streaming', 'createdAt': 1},
    });
    fake.emitSession('s1', {
      'ev': 'item.updated',
      'item': {'kind': 'assistant', 'id': 'a1', 'text': '完整', 'status': 'done', 'createdAt': 1},
    });
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(notifications, 2);
    expect(controller.transcript.items.single.text, '完整');
    expect(controller.transcript.phase, SessionPhase.idle);
  });
}
