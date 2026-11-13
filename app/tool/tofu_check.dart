// ignore_for_file: avoid_print
// TLS/TOFU end-to-end check against a local daemon (TLS default):
//   node bin/cc-go.mjs --port 8749 --localhost --code 654321
// Exercises: learn on first pair → pin match → tampered pin rejects →
// wss hello through the pinned client.
import 'dart:async';
import 'dart:io';

import 'package:cc_go/transport/host_link.dart';
import 'package:cc_go/transport/tofu.dart';

Future<void> main() async {
  const port = 8749;
  const host = '127.0.0.1';

  // 1) first pairing: TOFU learns the cert fingerprint
  final paired = await pairWithDaemon(
    host: InternetAddress(host),
    port: port,
    code: '654321',
    policy: TofuPolicy(),
  );
  if (paired.fingerprint.isEmpty) throw StateError('no fingerprint learned');
  print('[tofu] learned fingerprint: ${paired.fingerprint}');
  print('[tofu] paired, device ${paired.deviceId}, host ${paired.hostName}');

  // 2) pinned client accepts the same cert
  final pinned = tofuHttpClient(policy: TofuPolicy(expectedFingerprint: paired.fingerprint));
  final health = await pinned
      .getUrl(Uri.parse('https://$host:$port/health'))
      .then((req) => req.close())
      .then((resp) => resp.statusCode);
  if (health != 200) throw StateError('pinned /health → $health');
  print('[tofu] pinned fingerprint accepted ✓');

  // 3) tampered pin must fail closed
  final tamperedFp = _tamperFirstByte(paired.fingerprint);
  var rejected = false;
  try {
    final badClient = tofuHttpClient(policy: TofuPolicy(expectedFingerprint: tamperedFp));
    await badClient
        .getUrl(Uri.parse('https://$host:$port/health'))
        .then((req) => req.close());
  } on HandshakeException catch (e) {
    rejected = !e.type.contains('cannot');
    print('[tofu] tampered fingerprint rejected ✓ ($e)');
  }
  if (!rejected) throw StateError('tampered fingerprint was NOT rejected');

  // 4) wss hello through the pinned client
  final link = await HostLink.connect(
    wsUri: Uri.parse('wss://$host:$port/ws'),
    token: paired.token,
    customClient: pinned,
  );
  final info = await link.call('host.info', {}) as Map<String, dynamic>;
  print('[tofu] wss hello + host.info through pinned client ✓ '
      '(${(info['host'] as Map)['name']})');
  await link.close();

  print('[tofu] ALL TOFU CHECKS PASSED');
  exit(0);
}

String _tamperFirstByte(String fingerprint) {
  final bytes = fingerprint.split(':');
  final first = bytes.first == 'FF' ? '00' : 'FF';
  return [first, ...bytes.sublist(1)].join(':');
}
