// ignore_for_file: avoid_print
// Reconnect end-to-end check (task 3.3): assumes a TLS daemon on 8749 with
// HOME=/tmp/ccgo-verify. Then:
//   pair → connect wrapper → watch session (snapshot #1) → KILL daemon →
//   relaunch daemon → wrapper auto-reconnects (auto hello) → re-watch pulls
//   snapshot #2 → new RPC + live events flow through the same streams.
import 'dart:async';
import 'dart:io';

import 'package:cc_go/transport/host_link.dart';
import 'package:cc_go/transport/reconnecting_link.dart';
import 'package:cc_go/transport/tofu.dart';

const port = 8749;
const host = '127.0.0.1';

Future<void> main() async {
  await Directory('/tmp/ccgo-test').create(recursive: true);

  // 1) pair (TOFU learns the cert) — daemon must be up
  final paired = await pairWithDaemon(
    host: InternetAddress(host),
    port: port,
    code: '654321',
    policy: TofuPolicy(),
  );
  print('[rc] paired, fingerprint ${paired.fingerprint.substring(0, 23)}…');

  HttpClient pinnedClient() =>
      tofuHttpClient(policy: TofuPolicy(expectedFingerprint: paired.fingerprint));

  final wrapped = ReconnectingHostLink(
    connector: () => HostLink.connect(
      wsUri: Uri.parse('wss://$host:$port/ws'),
      token: paired.token,
      customClient: pinnedClient(),
    ),
    baseDelay: const Duration(milliseconds: 500),
    maxDelay: const Duration(seconds: 5),
  );

  final snapshots = <String>[];
  final broadcasts = <String>[];
  var sessionIdNow = '';
  final sub = wrapped.events.listen((event) {
    print('[rc] event: ${event.type}'
        '${event.sessionId != null ? " (${event.sessionId})" : ""}'
        '${event.sessionEvent != null ? " ev=${event.sessionEvent!['ev']}" : ""}');
    if (event.type == 'session' &&
        event.sessionId == sessionIdNow &&
        event.sessionEvent?['ev'] == 'snapshot') {
      snapshots.add(event.sessionId!);
      print('[rc] snapshot #${snapshots.length} for ${event.sessionId}');
    } else if (event.type == 'sessions.changed') {
      broadcasts.add('sessions.changed');
    }
  });

  final connectedTwice = wrapped.states
      .where((s) => s == LinkState.connected)
      .skip(1)
      .first
      .timeout(const Duration(seconds: 60));

  await wrapped.start();
  await wrapped.states.firstWhere((s) => s == LinkState.connected).timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TimeoutException('initial connect'),
      );
  print('[rc] connected #1');

  // 2) create + watch a session
  final created = await wrapped.call('session.create', {'cwd': '/tmp/ccgo-test'}) as Map;
  sessionIdNow = created['summary']['id'] as String;
  await wrapped.watch(sessionIdNow);
  await _until(() => snapshots.isNotEmpty, const Duration(seconds: 10));
  print('[rc] watched $sessionIdNow, snapshot received');

  // 3) kill the daemon
  await Process.run('pkill', ['-f', 'cc-go.mjs --port 8749']);
  print('[rc] daemon killed — waiting for auto-reconnect…');

  // 4) relaunch it (same HOME → same cert/token store)
  await Process.start(
    'node',
    ['bin/cc-go.mjs', '--port', '8749', '--localhost', '--code', '654321'],
    workingDirectory: '../daemon',
    environment: {...Platform.environment, 'HOME': '/tmp/ccgo-verify'},
    mode: ProcessStartMode.detached,
  );

  await connectedTwice;
  print('[rc] reconnected automatically ✓ (hello re-ran inside connect)');

  // 5) re-watch pulled a fresh snapshot for the same session
  await _until(() => snapshots.length >= 2, const Duration(seconds: 15));
  print('[rc] snapshot re-pulled after reconnect ✓ (转录补齐)');

  // 6) RPC + live events still flow through the same wrapper
  await wrapped.call('session.create', {'cwd': '/tmp/ccgo-test'});
  await _until(() => broadcasts.isNotEmpty, const Duration(seconds: 10));
  print('[rc] live broadcast through wrapper ✓');

  await sub.cancel();
  await wrapped.stop();
  await Process.run('pkill', ['-f', 'cc-go.mjs --port 8749']);
  print('[rc] ALL RECONNECT CHECKS PASSED');
  exit(0);
}

Future<void> _until(bool Function() test, Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  while (!test()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}
