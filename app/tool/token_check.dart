// ignore_for_file: avoid_print
// token 失效端到端（task 4.3）：配对 → 连接成功 → 抹掉 daemon 端设备记录并
// 重启 → AppLink 应收到 tokenInvalid（而非无限重试）。
//   前置：daemon 已在 8749 (TLS, HOME=/tmp/ccgo-verify) 运行。
import 'dart:async';
import 'dart:io';

import 'package:cc_go/state/app_link.dart';
import 'package:cc_go/state/credentials.dart';
import 'package:cc_go/transport/reconnecting_link.dart';
import 'package:cc_go/transport/tofu.dart';

Future<void> main() async {
  const port = 8749;
  const host = '127.0.0.1';

  final paired = await pairWithDaemon(
    host: InternetAddress(host),
    port: port,
    code: '654321',
    policy: TofuPolicy(),
  );
  print('[tk] paired (device ${paired.deviceId})');

  final appLink = AppLink.fromCredentials(HostCredentials(
    host: host,
    port: port,
    token: paired.token,
    fingerprint: paired.fingerprint,
    hostName: paired.hostName,
  ));
  final invalid = appLink.tokenInvalid.first.timeout(const Duration(seconds: 30));
  await appLink.start();
  await appLink.link.states
      .firstWhere((s) => s == LinkState.connected)
      .timeout(const Duration(seconds: 10));
  print('[tk] connected with fresh token ✓');

  // daemon 侧"解绑"：抹掉 store（含设备 token 表）并重启
  await Process.run('pkill', ['-f', 'cc-go.mjs --port 8749']);
  await Future<void>.delayed(const Duration(milliseconds: 500));
  final store = File('/tmp/ccgo-verify/.cc-go/store.json');
  if (store.existsSync()) store.deleteSync();
  await Process.start(
    'node',
    ['bin/cc-go.mjs', '--port', '8749', '--localhost', '--code', '654321'],
    workingDirectory: '../daemon',
    environment: {...Platform.environment, 'HOME': '/tmp/ccgo-verify'},
    mode: ProcessStartMode.detached,
  );
  print('[tk] daemon store wiped + restarted — expecting token rejection…');

  await invalid;
  print('[tk] tokenInvalid fired ✓ (App 会停链并引导重新配对，而非死循环)');

  await Process.run('pkill', ['-f', 'cc-go.mjs --port 8749']);
  print('[tk] ALL TOKEN CHECKS PASSED');
  exit(0);
}
