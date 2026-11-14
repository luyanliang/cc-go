import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:cc_go/transport/host_link.dart';

/// Regression suite for the direct (plain `ws://`) path over a real
/// dart:io WebSocket server. Guards the `HostLink.connect` seam before and
/// after transport work (ssh-tunnel change, task 2.1): connect → hello,
/// request pairing, event pushes, and close behaviour must not drift.
void main() {
  late HttpServer server;

  Future<void> handle(WebSocket socket) async {
    await for (final raw in socket) {
      final frame = jsonDecode(raw as String) as Map<String, dynamic>;
      if (frame['method'] == 'hello') {
        final ok = (frame['params'] as Map)['token'] == 'good-token';
        socket.add(jsonEncode({'id': frame['id'], 'ok': ok, 'result': ok ? {'ok': true} : null}));
        if (!ok) {
          await socket.close(4003, 'unauthorized');
          return;
        }
      } else if (frame['method'] == 'host.info') {
        socket.add(jsonEncode({'id': frame['id'], 'ok': true, 'result': {'ok': true}}));
        socket.add(jsonEncode({
          'type': 'event',
          'event': {'type': 'sessions.changed', 'sessions': []},
        }));
      } else if (frame['method'] == 'session.watch') {
        socket.add(jsonEncode({
          'id': frame['id'],
          'ok': true,
          'result': {'summary': {'id': 's1'}, 'snapshot': {'items': []}},
        }));
      } else {
        socket.add(jsonEncode({
          'id': frame['id'],
          'ok': false,
          'error': {'code': 'not_found', 'message': 'no such method'},
        }));
      }
    }
  }

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final socket = await WebSocketTransformer.upgrade(req);
      await handle(socket);
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  Uri wsUri() => Uri.parse('ws://127.0.0.1:${server.port}/ws');

  test('connects, completes the hello handshake, and returns RPC results', () async {
    final link = await HostLink.connect(wsUri: wsUri(), token: 'good-token');
    final result = await link.call('session.watch', {'sessionId': 's1'});
    expect((result['summary'] as Map)['id'], 's1');
    expect((result['snapshot'] as Map)['items'], isEmpty);
    await link.close();
  });

  test('pushed events arrive on the event stream', () async {
    final link = await HostLink.connect(wsUri: wsUri(), token: 'good-token');
    // Subscribe before triggering the push (broadcast stream: no buffering).
    final done = Completer<DaemonEvent>();
    final sub = link.events.listen(
      done.complete,
      onError: done.completeError,
      onDone: () => done.completeError(StateError('events closed before push')),
    );
    // The server pushes `sessions.changed` right after answering `host.info`.
    unawaited(link.call('host.info'));
    final event = await done.future.timeout(const Duration(seconds: 5));
    expect(event.type, 'sessions.changed');
    await sub.cancel();
    await link.close();
  });

  test('rejected hello throws and closes the link', () async {
    await expectLater(
      HostLink.connect(wsUri: wsUri(), token: 'wrong-token'),
      throwsA(anyOf(isA<AuthRejectedByServer>(), isA<RpcException>())),
    );
  });

  test('RPC errors fail the matching call with RpcException', () async {
    final link = await HostLink.connect(wsUri: wsUri(), token: 'good-token');
    try {
      await link.call('no.such.method');
      fail('expected RpcException');
    } on RpcException catch (error) {
      expect(error.code, 'not_found');
    } finally {
      await link.close();
    }
  });
}
