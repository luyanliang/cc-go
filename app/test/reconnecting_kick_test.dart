import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:cc_go/transport/host_link.dart';
import 'package:cc_go/transport/reconnecting_link.dart';

/// 带探测控制的 FakeLink：host.info 的成败/悬挂由测试驱动。
class ProbeFakeLink implements HostLinkBase {
  ProbeFakeLink(this.name);

  final String name;
  final eventsController = StreamController<DaemonEvent>.broadcast();

  /// 每次 host.info 调用挂起的 completer（测试决定何时成功/失败/永不完成）。
  final hostInfoCalls = <Completer<void>>[];
  int get hostInfoCount => hostInfoCalls.length;

  /// 非 null 时 host.info 直接抛出（探测立即失败）。
  Object? hostInfoError;

  bool closed = false;

  @override
  Stream<DaemonEvent> get events => eventsController.stream;

  @override
  Future<dynamic> call(String method, [Map<String, dynamic> params = const {}]) async {
    if (method == 'host.info') {
      final error = hostInfoError;
      if (error != null) throw error;
      final pending = Completer<void>();
      hostInfoCalls.add(pending);
      return pending.future.then((_) => {'link': name});
    }
    if (method == 'session.watch') {
      return {
        'snapshot': {'items': <dynamic>[], 'phase': 'idle'},
        'summary': {'id': params['sessionId']},
      };
    }
    return {'link': name, 'method': method};
  }

  @override
  Future<void> close({String reason = ''}) async {
    closed = true;
    await eventsController.close();
  }

  /// Simulates the daemon dying.
  void drop() => eventsController.close();
}

Future<void> untilConnected(ReconnectingHostLink link) {
  return link.states
      .firstWhere((s) => s == LinkState.connected)
      .timeout(const Duration(seconds: 5));
}

/// Resolves on the SECOND `connected` — i.e. after a drop + reconnect.
Future<void> untilReconnected(ReconnectingHostLink link) {
  return link.states
      .where((s) => s == LinkState.connected)
      .skip(1)
      .first
      .timeout(const Duration(seconds: 5));
}

void main() {
  group('ReconnectingHostLink.kick', () {
    test('退避等待中的 kick 打断等待，且梯子不重置（连续 kick 不钉死在 1s）', () async {
      final attempts = <DateTime>[];
      final wrapped = ReconnectingHostLink(
        connector: () async {
          attempts.add(DateTime.now());
          throw const HostLinkClosed('refused');
        },
        baseDelay: const Duration(milliseconds: 50),
        maxDelay: const Duration(milliseconds: 200),
      );
      await wrapped.start();
      // 时序：失败(50ms) --kick@+15ms--> 立即失败(100ms) --kick@+25ms--> 立即
      // 失败(200ms) --无 kick--> 等满 200ms 后第 4 次尝试。
      Future<void>.delayed(const Duration(milliseconds: 15), wrapped.kick);
      Future<void>.delayed(const Duration(milliseconds: 25), wrapped.kick);
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (attempts.length < 4 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(attempts.length, greaterThanOrEqualTo(4));

      final gaps = [
        for (var i = 1; i < attempts.length; i++)
          attempts[i].difference(attempts[i - 1]),
      ];
      expect(gaps[0], lessThan(const Duration(milliseconds: 40)),
          reason: '第一次 kick 打断了 50ms 退避');
      expect(gaps[1], lessThan(const Duration(milliseconds: 40)),
          reason: '第二次 kick 打断了 100ms 退避');
      expect(gaps[2], greaterThanOrEqualTo(const Duration(milliseconds: 180)),
          reason: '两次 kick 后梯子已爬到 200ms——未被打归零');
      await wrapped.stop();
    });

    test('退避自然到期后再 kick 不抛 StateError（走探测路径）', () async {
      var failures = 0;
      final links = <ProbeFakeLink>[];
      final wrapped = ReconnectingHostLink(
        connector: () async {
          if (failures++ < 1) throw const HostLinkClosed('refused');
          final link = ProbeFakeLink('l${links.length}');
          links.add(link);
          return link;
        },
        baseDelay: const Duration(milliseconds: 20),
      );
      final ready = untilConnected(wrapped);
      await wrapped.start();
      await ready; // 一次自然退避到期后重连成功
      await Future<void>.delayed(const Duration(milliseconds: 30));
      // 此刻 _backoffWait 仍是已完成的旧 Completer：kick 必须安全走到探测分支。
      links.last.hostInfoCalls.clear();
      wrapped.kick();
      expect(links.last.hostInfoCount, 1);
      links.last.hostInfoCalls.last.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(links, hasLength(1), reason: '探测成功，连接不动');
      await wrapped.stop();
    });

    test('探测成功：连接不中断、不重建', () async {
      final links = <ProbeFakeLink>[];
      final wrapped = ReconnectingHostLink(
        connector: () async {
          final link = ProbeFakeLink('l${links.length}');
          links.add(link);
          return link;
        },
        baseDelay: const Duration(milliseconds: 1),
      );
      final ready = untilConnected(wrapped);
      await wrapped.start();
      await ready;

      wrapped.kick();
      links.last.hostInfoCalls.last.complete();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(links, hasLength(1));
      expect(links.last.closed, isFalse);
      await wrapped.stop();
    });

    test('探测失败触发重连（旧链路关闭）', () async {
      final links = <ProbeFakeLink>[];
      final wrapped = ReconnectingHostLink(
        connector: () async {
          final link = ProbeFakeLink('l${links.length}');
          links.add(link);
          return link;
        },
        baseDelay: const Duration(milliseconds: 1),
      );
      final ready = untilConnected(wrapped);
      final reconnected = untilReconnected(wrapped);
      await wrapped.start();
      await ready;

      links.first.hostInfoError = const HostLinkClosed('probe failed');
      wrapped.kick();
      await reconnected;
      expect(links.first.closed, isTrue);
      expect(links, hasLength(2));
      await wrapped.stop();
    });

    test('探测超时触发重连', () async {
      final links = <ProbeFakeLink>[];
      final wrapped = ReconnectingHostLink(
        connector: () async {
          final link = ProbeFakeLink('l${links.length}');
          links.add(link);
          return link;
        },
        baseDelay: const Duration(milliseconds: 1),
        probeTimeout: const Duration(milliseconds: 30),
      );
      final ready = untilConnected(wrapped);
      final reconnected = untilReconnected(wrapped);
      await wrapped.start();
      await ready;

      wrapped.kick(); // host.info 永不完成 → 30ms 超时判死
      await reconnected;
      expect(links.first.closed, isTrue);
      await wrapped.stop();
    });

    test('并发 kick 只有一个在途探针', () async {
      final links = <ProbeFakeLink>[];
      final wrapped = ReconnectingHostLink(
        connector: () async {
          final link = ProbeFakeLink('l${links.length}');
          links.add(link);
          return link;
        },
        baseDelay: const Duration(milliseconds: 1),
      );
      final ready = untilConnected(wrapped);
      await wrapped.start();
      await ready;

      wrapped.kick();
      wrapped.kick(); // 探测在途：锁存，不并发第二个探针
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(links.last.hostInfoCount, 1);
      links.last.hostInfoCalls.last.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(links, hasLength(1), reason: '探测成功，锁存被吸收，无重连');
      await wrapped.stop();
    });

    test('探测期间旧链路自然断开、新链路已建时不误杀新链路（身份闸）', () async {
      final links = <ProbeFakeLink>[];
      final wrapped = ReconnectingHostLink(
        connector: () async {
          final link = ProbeFakeLink('l${links.length}');
          links.add(link);
          return link;
        },
        baseDelay: const Duration(milliseconds: 1),
      );
      final ready = untilConnected(wrapped);
      final reconnected = untilReconnected(wrapped);
      await wrapped.start();
      await ready;

      // 探测挂起中 → 旧链路自然断开 → 重连出新链路 → 探测以失败收场。
      wrapped.kick();
      final pendingProbe = links.last.hostInfoCalls.last;
      links.last.drop();
      await reconnected;
      final newLink = links.last;
      expect(newLink, isNot(same(links.first)));
      pendingProbe.completeError(const HostLinkClosed('probe failed'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(newLink.closed, isFalse, reason: '身份闸：探测失败不得关闭新链路');
      expect(links, hasLength(2), reason: '新链路保持在线，不再额外重连');
      await wrapped.stop();
    });

    test('stop() 后的 kick 被安全忽略', () async {
      final links = <ProbeFakeLink>[];
      final wrapped = ReconnectingHostLink(
        connector: () async {
          final link = ProbeFakeLink('l${links.length}');
          links.add(link);
          return link;
        },
        baseDelay: const Duration(milliseconds: 1),
      );
      final ready = untilConnected(wrapped);
      await wrapped.start();
      await ready;
      await wrapped.stop();

      links.last.hostInfoCalls.clear();
      wrapped.kick(); // 不得抛错、不得触发探针或重连
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(links.last.hostInfoCount, 0);
      expect(links, hasLength(1));
    });

    test('拨号挂起期间到达的 kick 在拨号失败后立即触发下一次尝试', () async {
      final attempts = <DateTime>[];
      final hang = Completer<void>(); // 第一次拨号挂起在这里
      final links = <ProbeFakeLink>[];
      final wrapped = ReconnectingHostLink(
        connector: () async {
          attempts.add(DateTime.now());
          if (!hang.isCompleted) {
            await hang.future;
            throw const HostLinkClosed('refused');
          }
          final link = ProbeFakeLink('l${links.length}');
          links.add(link);
          return link;
        },
        baseDelay: const Duration(seconds: 1), // 若锁存失效将等满 1s
        maxDelay: const Duration(seconds: 1),
      );
      final ready = untilConnected(wrapped);
      await wrapped.start();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      wrapped.kick(); // 拨号挂起中：锁存
      hang.complete();
      final started = DateTime.now();
      await ready.timeout(const Duration(seconds: 3));
      expect(DateTime.now().difference(started),
          lessThan(const Duration(milliseconds: 500)),
          reason: '锁存消费：跳过 1s 退避立即重试');
      await wrapped.stop();
    });
  });
}
