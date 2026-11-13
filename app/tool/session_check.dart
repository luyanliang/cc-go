// ignore_for_file: avoid_print
// 会话列表端到端（task 5.1/5.2/5.3）：AppLink 连接 → 另一个客户端模拟
// "电脑侧"建会话+触发权限 → 验证 sessions.changed 广播到达、host.info
// 刷新、待权限会话按 compareForList 置顶。
//   前置：daemon 已在 8749 (TLS, HOME=/tmp/ccgo-verify) 运行。
import 'dart:async';
import 'dart:io';

import 'package:cc_go/state/app_link.dart';
import 'package:cc_go/state/credentials.dart';
import 'package:cc_go/state/session_models.dart';
import 'package:cc_go/transport/host_link.dart';
import 'package:cc_go/transport/reconnecting_link.dart';
import 'package:cc_go/transport/tofu.dart';

const port = 8749;
const host = '127.0.0.1';

Future<void> main() async {
  await Directory('/tmp/ccgo-test').create(recursive: true);

  final paired = await pairWithDaemon(
    host: InternetAddress(host),
    port: port,
    code: '654321',
    policy: TofuPolicy(),
  );
  HttpClient pinned() => tofuHttpClient(
        policy: TofuPolicy(expectedFingerprint: paired.fingerprint),
      );

  // "手机"：AppLink
  final appLink = AppLink.fromCredentials(HostCredentials(
    host: host, port: port,
    token: paired.token, fingerprint: paired.fingerprint,
    hostName: paired.hostName,
  ));
  final events = <String>[];
  String? permissionSessionId;
  final permissionSeen = Completer<String>();
  final sub = appLink.link.events.listen((e) {
    events.add(e.type);
    if (e.type == 'permission.request' && !permissionSeen.isCompleted) {
      permissionSessionId = e.sessionId;
      permissionSeen.complete(e.sessionId!);
    }
  });
  await appLink.start();
  await appLink.link.states.firstWhere((s) => s == LinkState.connected).timeout(
        const Duration(seconds: 10),
      );

  // "电脑侧"：第二个连接建会话、发任务（会触发文件写权限）
  final pc = await HostLink.connect(
    wsUri: Uri(scheme: 'wss', host: host, port: port, path: '/ws'),
    token: paired.token,
    customClient: pinned(),
  );
  final initial = await pc.call('host.info', {}) as Map<String, dynamic>;
  final initialCount = (initial['sessions'] as List).length;
  final created = await pc.call('session.create', {'cwd': '/tmp/ccgo-test'}) as Map;
  final sessionId = created['summary']['id'] as String;
  print('[sc] 电脑侧新建会话 $sessionId（此前 $initialCount 个）');

  await _until(
      () => events.contains('sessions.changed'), const Duration(seconds: 10));
  print('[sc] sessions.changed 广播到达 ✓（列表会防抖刷新）');

  await pc.call('session.prompt', {
    'sessionId': sessionId,
    'text': 'Create a file named perm-test.txt in the current directory containing "x". Then say DONE.',
    'mode': 'queue',
  });
  final permSession = await permissionSeen.future.timeout(const Duration(seconds: 180));
  print('[sc] permission.request 广播到达 ✓（会话 $permSession 工具待授权）');

  // 不应答 → 会话停留 awaiting-permission；拉列表验证排序
  final refreshed = await appLink.link.call('host.info', {}) as Map<String, dynamic>;
  final sessions = (refreshed['sessions'] as List)
      .map((s) => SessionSummary.fromJson(s as Map<String, dynamic>))
      .toList();
  final target = sessions.firstWhere((s) => s.id == sessionId);
  if (target.phase != SessionPhase.awaitingPermission) {
    throw StateError('期望 awaiting-permission，实际 ${target.phase}');
  }
  sessions.sort(compareForList);
  if (sessions.first.id != sessionId) {
    throw StateError('待权限会话未置顶');
  }
  print('[sc] 待权限会话置顶+金色徽标（compareForList）✓');

  // 收尾：拒绝权限并取消，让 daemon 回到整洁状态
  final perm = (permissionSessionId != null)
      ? await _pendingItemId(appLink, sessionId)
      : null;
  if (perm != null) {
    await pc.call('permission.respond', {
      'sessionId': sessionId, 'itemId': perm, 'allow': false, 'allowToolForSession': false,
    });
    await pc.call('session.cancel', {'sessionId': sessionId});
  }

  await sub.cancel();
  await appLink.stop();
  await pc.close();
  print('[sc] ALL SESSION CHECKS PASSED');
  exit(0);
}

/// 从最近快照里拿 pendingPermission 的 itemId（拒权收尾用）。
Future<String?> _pendingItemId(AppLink appLink2, String sessionId) async {
  final result = await appLink2.link.call('session.watch', {'sessionId': sessionId});
  final snapshot = (result as Map)['snapshot'] as Map;
  final pending = snapshot['pendingPermission'] as Map?;
  return pending?['itemId'] as String?;
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
