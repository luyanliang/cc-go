// ignore_for_file: avoid_print
// 探针：一轮问答后 phase 事件序列与时间线（排查 idle 迟迟不到）。
import 'dart:async';
import 'dart:io';

import 'package:cc_go/state/app_link.dart';
import 'package:cc_go/state/credentials.dart';
import 'package:cc_go/transport/reconnecting_link.dart';
import 'package:cc_go/transport/tofu.dart';

Future<void> main() async {
  final paired = await pairWithDaemon(
    host: InternetAddress('127.0.0.1'), port: 8749, code: '654321', policy: TofuPolicy(),
  );
  final appLink = AppLink.fromCredentials(HostCredentials(
    host: '127.0.0.1', port: 8749,
    token: paired.token, fingerprint: paired.fingerprint, hostName: 'x',
  ));
  final t0 = DateTime.now();
  String ts() => '+${DateTime.now().difference(t0).inMilliseconds}ms';
  appLink.link.events.listen((e) {
    if (e.type == 'session') {
      final ev = e.sessionEvent!;
      print('[probe] ${ts()} ${e.sessionId!.substring(0, 8)} ${ev['ev']}'
          '${ev['phase'] != null ? " phase=${ev['phase']}" : ""}'
          '${ev['item'] != null ? " item=${(ev['item'] as Map)['kind']}/${(ev['item'] as Map)['status']}" : ""}');
    } else {
      print('[probe] ${ts()} ${e.type}');
    }
  });
  await appLink.start();
  await appLink.link.states.firstWhere((s) => s == LinkState.connected);

  final created = await appLink.link
      .call('session.create', {'cwd': '/tmp/ccgo-test'}) as Map;
  final sid = created['summary']['id'] as String;
  print('[probe] ${ts()} created $sid');
  await appLink.link.watch(sid);
  await appLink.link.call('session.prompt', {
    'sessionId': sid,
    'text': 'Reply with exactly the word PONG and nothing else.',
    'mode': 'queue',
  });
  print('[probe] ${ts()} prompt sent, observing 45s…');
  await Future<void>.delayed(const Duration(seconds: 45));
  final info = await appLink.link.call('host.info', {}) as Map;
  print('[probe] ${ts()} final phases: '
      '${(info['sessions'] as List).map((s) => (s as Map)['phase']).join(",")}');
  await appLink.stop();
  exit(0);
}
