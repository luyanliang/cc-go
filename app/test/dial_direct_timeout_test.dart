import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:cc_go/state/app_link.dart';

/// 直连拨号上界超时（network-kicks 真机验收结论）：对"接受连接但不回应
/// 握手"的服务器拨号，必须在 _directDialTimeout 内以 TimeoutException 失败，
/// 而不是挂死到 OS 级 TCP 超时堵死 kick 锁存的消费。
void main() {
  test('dialDirect 对挂起的握手在 8s 上界内超时', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = <Socket>[];
    final sub = server.listen((socket) {
      accepted.add(socket); // 接受连接但永不回应：握手悬挂
    });

    final stopwatch = Stopwatch()..start();
    final outcome = await dialDirect(
      wsUri: Uri.parse('ws://127.0.0.1:${server.port}/ws'),
      token: 't',
      fingerprint: null,
    ).then<Object>((v) => v, onError: (Object e) => e);
    stopwatch.stop();

    expect(outcome, isA<TimeoutException>(),
        reason: '悬挂的握手必须以 TimeoutException 收场');
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 10)));
    expect(stopwatch.elapsed, greaterThanOrEqualTo(const Duration(seconds: 7)));

    for (final socket in accepted) {
      socket.destroy();
    }
    await sub.cancel();
    await server.close();
  });
}
