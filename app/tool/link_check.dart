// ignore_for_file: avoid_print
// End-to-end sanity check for HostLink against a local --no-tls daemon:
//   node bin/cc-go.mjs --port 8748 --localhost --no-tls --code 654321
// Pairs over HTTP, then exercises hello / host.info / event stream / close.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cc_go/transport/host_link.dart';

Future<void> main() async {
  const port = 8748;
  const code = '654321';

  final pairResp = await HttpClient()
      .postUrl(Uri.parse('http://127.0.0.1:$port/pair'))
      .then((req) => req
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'code': code, 'name': 'dart-link-check'})))
      .then((req) => req.close())
      .then((resp) async {
    final body = await resp.transform(utf8.decoder).join();
    if (resp.statusCode != 200) throw StateError('pair failed: ${resp.statusCode} $body');
    return jsonDecode(body) as Map<String, dynamic>;
  });
  final token = pairResp['token'] as String;
  final host = (pairResp['host'] as Map)['name'];
  print('[check] paired with host $host');

  final link = await HostLink.connect(
    wsUri: Uri.parse('ws://127.0.0.1:$port/ws'),
    token: token,
  );
  print('[check] hello ok');

  final info = await link.call('host.info', {}) as Map<String, dynamic>;
  print('[check] host.info → ${(info['host'] as Map)['name']}, '
      '${(info['sessions'] as List).length} sessions');

  final eventsSeen = <String>[];
  final sub = link.events.listen((e) => eventsSeen.add(e.type));
  // trigger a sessions.changed broadcast via a (failing, harmless) call
  try {
    await link.call('session.watch', {'sessionId': 'no-such-session'});
  } on RpcException catch (e) {
    print('[check] rpc error path ok → ${e.code}');
  }
  await Future<void>.delayed(const Duration(milliseconds: 300));
  print('[check] events seen: ${eventsSeen.isEmpty ? "(none)" : eventsSeen.join(", ")}');

  await sub.cancel();
  await link.close();
  print('[check] ALL LINK CHECKS PASSED');
  exit(0);
}
