import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:cc_go/transport/host_link.dart';
import 'package:cc_go/transport/reconnecting_link.dart';

/// Scriptable stand-in for a live HostLink.
class FakeLink implements HostLinkBase {
  FakeLink(this.name);

  final String name;
  final eventsController = StreamController<DaemonEvent>.broadcast();
  final calls = <(String, Map<String, dynamic>)>[];
  bool closed = false;

  @override
  Stream<DaemonEvent> get events => eventsController.stream;

  @override
  Future<dynamic> call(String method, [Map<String, dynamic> params = const {}]) async {
    calls.add((method, params));
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

DaemonEvent fakeEvent(String type) => DaemonEvent({'type': type});

/// Broadcast streams drop events with no listener — subscribe before
/// starting the link so the first `connected` can't be missed.
Future<void> untilConnected(ReconnectingHostLink link) {
  final ready = link.states.firstWhere((s) => s == LinkState.connected);
  return ready.timeout(const Duration(seconds: 5));
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
  group('ReconnectingHostLink', () {
    test('reconnects and re-watches every session after a drop', () async {
      final links = <FakeLink>[];
      FakeLink makeLink() {
        final link = FakeLink('l${links.length}');
        links.add(link);
        return link;
      }

      final wrapped = ReconnectingHostLink(
        connector: () async => makeLink(),
        baseDelay: const Duration(milliseconds: 1),
        maxDelay: const Duration(milliseconds: 10),
      );
      final ready = untilConnected(wrapped);
      final reconnected = untilReconnected(wrapped);
      final snapshotEvents = <String>[];
      final sub = wrapped.events.listen((e) {
        if (e.type == 'session' && e.sessionEvent?['ev'] == 'snapshot') {
          snapshotEvents.add(e.sessionId!);
        }
      });

      await wrapped.start();
      await ready;
      await wrapped.watch('session-1');
      await wrapped.watch('session-2');
      final first = links.single;
      expect(
        first.calls.where((c) => c.$1 == 'session.watch').map((c) => c.$2['sessionId']),
        ['session-1', 'session-2'],
      );
      await Future<void>.delayed(Duration.zero); // broadcast delivery is async
      expect(snapshotEvents, containsAll(['session-1', 'session-2']),
          reason: 'watch responses re-emitted as snapshot events');

      first.drop(); // daemon dies
      await reconnected;
      final second = links.last;
      expect(second, isNot(same(first)));
      expect(
        second.calls.where((c) => c.$1 == 'session.watch').map((c) => c.$2['sessionId']),
        containsAll(['session-1', 'session-2']),
        reason: 'snapshots re-pulled for every watched session',
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        snapshotEvents.where((id) => id == 'session-1').length,
        2,
        reason: 'session-1 snapshot re-emitted after reconnect (转录补齐)',
      );
      await sub.cancel();
      await wrapped.stop();
    });

    test('retries with backoff until connect succeeds', () async {
      var failures = 0;
      var attempts = 0;
      final links = <FakeLink>[];
      final wrapped = ReconnectingHostLink(
        connector: () async {
          attempts++;
          if (failures++ < 2) {
            throw const HostLinkClosed('refused');
          }
          final link = FakeLink('ok');
          links.add(link);
          return link;
        },
        baseDelay: const Duration(milliseconds: 5),
        maxDelay: const Duration(milliseconds: 40),
      );
      final timer = Stopwatch()..start();
      final ready = untilConnected(wrapped);
      await wrapped.start();
      await ready;
      timer.stop();

      expect(attempts, 3);
      expect(timer.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 15)),
          reason: 'two backoff waits (5ms + 10ms) must elapse');
      expect(
        wrapped.call('host.info'),
        completion({'link': 'ok', 'method': 'host.info'}),
      );
      await wrapped.stop();
    });

    test('events merge across reconnects into one stream', () async {
      final links = <FakeLink>[];
      final wrapped = ReconnectingHostLink(
        connector: () async {
          final link = FakeLink('l${links.length}');
          links.add(link);
          return link;
        },
        baseDelay: const Duration(milliseconds: 1),
      );
      final received = <String>[];
      final sub = wrapped.events.listen((e) => received.add(e.type));
      final ready = untilConnected(wrapped);
      final reconnected = untilReconnected(wrapped);

      await wrapped.start();
      await ready;

      links.first.eventsController.add(fakeEvent('before-drop'));
      links.first.drop();
      await reconnected;
      links.last.eventsController.add(fakeEvent('after-reconnect'));

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(received, ['before-drop', 'after-reconnect']);
      await sub.cancel();
      await wrapped.stop();
    });

    test('call waits for connect, then fails with HostLinkClosed', () async {
      final wrapped = ReconnectingHostLink(
        connector: () async => throw const HostLinkClosed('refused'),
        baseDelay: const Duration(milliseconds: 5),
      );
      await wrapped.start();
      // 连接建立前调用：等待窗口内仍未连上 → HostLinkClosed（不悬挂）
      final outcome = await wrapped
          .call('host.info', const {}, const Duration(milliseconds: 200))
          .then<Object>((v) => v, onError: (Object e) => e);
      expect(outcome, isA<HostLinkClosed>());
      await wrapped.stop();
    });

    test('call issued while connecting rides the first connection', () async {
      final links = <FakeLink>[];
      final wrapped = ReconnectingHostLink(
        connector: () async {
          final link = FakeLink('l${links.length}');
          links.add(link);
          return link;
        },
        baseDelay: const Duration(milliseconds: 1),
      );
      await wrapped.start();
      final result = await wrapped.call('host.info', const {}, const Duration(seconds: 2))
          as Map<String, dynamic>;
      expect(result['method'], 'host.info');
      await wrapped.stop();
    });

    test('stop prevents further reconnects', () async {
      var connects = 0;
      final links = <FakeLink>[];
      final wrapped = ReconnectingHostLink(
        connector: () async {
          connects++;
          final link = FakeLink('l$connects');
          links.add(link);
          return link;
        },
        baseDelay: const Duration(milliseconds: 1),
      );
      final ready = untilConnected(wrapped);
      await wrapped.start();
      await ready;
      await wrapped.stop();

      links.first.drop();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(connects, 1, reason: 'no redial after stop()');
      expect(links.first.closed, isTrue);
    });

    test('backoff doubles and caps at maxDelay', () {
      final wrapped = ReconnectingHostLink(
        connector: () async => throw UnimplementedError(),
        baseDelay: const Duration(seconds: 1),
        maxDelay: const Duration(seconds: 30),
      );
      expect(wrapped.backoffFor(0), const Duration(seconds: 1));
      expect(wrapped.backoffFor(1), const Duration(seconds: 2));
      expect(wrapped.backoffFor(3), const Duration(seconds: 8));
      expect(wrapped.backoffFor(5), const Duration(seconds: 30));
      expect(wrapped.backoffFor(99), const Duration(seconds: 30));
    });
  });
}
