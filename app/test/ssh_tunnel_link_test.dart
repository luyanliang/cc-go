import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:cc_go/transport/ssh/ssh_host_key.dart';
import 'package:cc_go/transport/ssh/ssh_secrets.dart';
import 'package:cc_go/transport/host_link.dart';
import 'package:cc_go/transport/reconnecting_link.dart';
import 'package:cc_go/transport/ssh/ssh_tunnel_link.dart';

/// 端到端隧道验证（task 3.2）：dartssh2 → 本机 sshd → forwardLocal 回环
/// → 明文假 daemon 的 hello 握手。TLS+证书 TOFU 链路由
/// `host_link_connect_test.dart` 与 `tofu_test.dart` 覆盖。
///
/// 依赖本机 sshd（macOS「远程登录」）与授权的测试密钥
/// `/tmp/ccgo-ssh-test/key`；sshd 不在线时跳过，保证 CI 可跑。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer fakeDaemon;

  setUp(() async {
    fakeDaemon = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    fakeDaemon.listen((req) async {
      final socket = await WebSocketTransformer.upgrade(req);
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        if (frame['method'] == 'hello') {
          socket.add(jsonEncode({'id': frame['id'], 'ok': true, 'result': {'ok': true}}));
        } else {
          socket.add(jsonEncode({
            'id': frame['id'],
            'ok': true,
            'result': {'summary': {'id': 's1'}, 'snapshot': {'items': []}},
          }));
        }
      }
    });
  });

  tearDown(() async {
    await fakeDaemon.close(force: true);
  });

  Future<String?> probeSshKey() async {
    final file = File('/tmp/ccgo-ssh-test/key');
    if (!file.existsSync()) return null;
    return file.readAsString();
  }

  test('经本机 sshd 隧道完成 hello 与 RPC', () async {
    final pem = await probeSshKey();
    if (pem == null) {
      return; // 未生成测试密钥：跳过（CI / 其他机器）
    }
    var sshdUp = false;
    try {
      final probe = await Socket.connect('127.0.0.1', 22, timeout: const Duration(seconds: 2));
      probe.destroy();
      sshdUp = true;
    } on Object {
      sshdUp = false;
    }
    if (!sshdUp) {
      return; // sshd 未运行：跳过（真机验收阶段再验）
    }

    final endpoint = SshEndpoint(
      host: '127.0.0.1',
      port: 22,
      username: Platform.environment['USER'] ?? 'unknown',
      authMethod: SshAuthMethod.privateKey,
      daemonPort: fakeDaemon.port,
      daemonTls: false, // 假 daemon 是明文 WS；TLS 链路另有测试覆盖
      connectTimeout: const Duration(seconds: 10),
    );
    final secrets = SshSecrets(privateKeyPem: pem);

    final link = await SshTunnelLink.connect(
      endpoint,
      secrets,
      hostKeyStore: SshHostKeyMemoryStore(),
    );
    final result = await link.call('session.watch', {'sessionId': 's1'});
    expect((result['summary'] as Map)['id'], 's1');
    await link.close();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('SSH 认证失败被归类为 authFailed 而非网络错误', () async {
    final pem = await probeSshKey();
    if (pem == null) return;
    var sshdUp = false;
    try {
      final probe = await Socket.connect('127.0.0.1', 22, timeout: const Duration(seconds: 2));
      probe.destroy();
      sshdUp = true;
    } on Object {
      sshdUp = false;
    }
    if (!sshdUp) return;

    final endpoint = SshEndpoint(
      host: '127.0.0.1',
      port: 22,
      username: 'ccgo-no-such-user',
      authMethod: SshAuthMethod.privateKey,
      daemonPort: fakeDaemon.port,
      daemonTls: false,
      connectTimeout: const Duration(seconds: 10),
    );
    try {
      await SshTunnelLink.connect(
        endpoint,
        SshSecrets(privateKeyPem: pem),
        hostKeyStore: SshHostKeyMemoryStore(),
      );
      fail('expected SshLinkError');
    } on SshLinkError catch (error) {
      expect(error.kind, SshLinkErrorKind.authFailed);
    }
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('SSH 主机不可达被归类为 unreachable', () async {
    // 端口 1 没人监听：连接被拒 → unreachable（网络不通，非认证问题）。
    try {
      await SshTunnelLink.connect(
        SshEndpoint(
          host: '127.0.0.1',
          port: 1,
          username: 'x',
          authMethod: SshAuthMethod.password,
          daemonPort: fakeDaemon.port,
          daemonTls: false,
          connectTimeout: const Duration(seconds: 5),
        ),
        const SshSecrets(password: 'whatever'),
        hostKeyStore: SshHostKeyMemoryStore(),
      );
      fail('expected SshLinkError');
    } on SshLinkError catch (error) {
      expect(error.kind, SshLinkErrorKind.unreachable);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('daemon 未监听目标端口时被归类为 forwardRefused', () async {
    final pem = await probeSshKey();
    if (pem == null) return;
    var sshdUp = false;
    try {
      final probe = await Socket.connect('127.0.0.1', 22, timeout: const Duration(seconds: 2));
      probe.destroy();
      sshdUp = true;
    } on Object {
      sshdUp = false;
    }
    if (!sshdUp) return;

    // 1-1024 里挑一个大概率没人监听的端口做 daemonPort。
    var refusedPort = 1;
    for (final candidate in [1, 2, 3, 4]) {
      try {
        final probe = await Socket.connect('127.0.0.1', candidate, timeout: const Duration(milliseconds: 500));
        probe.destroy();
      } on Object {
        refusedPort = candidate;
        break;
      }
    }
    final endpoint = SshEndpoint(
      host: '127.0.0.1',
      port: 22,
      username: Platform.environment['USER'] ?? 'unknown',
      authMethod: SshAuthMethod.privateKey,
      daemonPort: refusedPort,
      daemonTls: false,
      connectTimeout: const Duration(seconds: 10),
    );
    try {
      await SshTunnelLink.connect(
        endpoint,
        SshSecrets(privateKeyPem: pem),
        hostKeyStore: SshHostKeyMemoryStore(),
      );
      fail('expected SshLinkError');
    } on SshLinkError catch (error) {
      expect(error.kind, SshLinkErrorKind.forwardRefused);
    }
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('隧道断线后走退避重连，恢复后快照补齐', () async {
    final pem = await probeSshKey();
    if (pem == null) return;
    var sshdUp = false;
    try {
      final probe = await Socket.connect('127.0.0.1', 22, timeout: const Duration(seconds: 2));
      probe.destroy();
      sshdUp = true;
    } on Object {
      sshdUp = false;
    }
    if (!sshdUp) return;

    // 固定端口的假 daemon：杀掉 → 重启，模拟 daemon 重启场景。
    final port = fakeDaemon.port + 1;
    final liveSockets = <WebSocket>[];
    Future<HttpServer> startDaemon() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      server.listen((req) async {
        final socket = await WebSocketTransformer.upgrade(req);
        liveSockets.add(socket);
        await for (final raw in socket) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          if (frame['method'] == 'hello') {
            socket.add(jsonEncode({'id': frame['id'], 'ok': true, 'result': {'ok': true}}));
          } else {
            socket.add(jsonEncode({
              'id': frame['id'],
              'ok': true,
              'result': {'summary': {'id': 's1'}, 'snapshot': {'items': []}},
            }));
          }
        }
      });
      return server;
    }

    final current = await startDaemon();
    final link = ReconnectingHostLink(
      connector: () => SshTunnelLink.connect(
        SshEndpoint(
          host: '127.0.0.1',
          port: 22,
          username: Platform.environment['USER'] ?? 'unknown',
          authMethod: SshAuthMethod.privateKey,
          daemonPort: port,
          daemonTls: false,
          connectTimeout: const Duration(seconds: 10),
        ),
        SshSecrets(privateKeyPem: pem),
        hostKeyStore: SshHostKeyMemoryStore(),
      ),
      baseDelay: const Duration(milliseconds: 300),
      maxDelay: const Duration(seconds: 2),
    );
    await link.start();
    await link.watch('s1');

    // 第一次连接的快照事件。
    final snapshots = <DaemonEvent>[];
    final states = <LinkState>[];
    final stateSub = link.states.listen(states.add);
    final sub = link.events.listen((e) {
      if (e.type == 'session' && (e.raw['event'] as Map?)?['ev'] == 'snapshot') {
        snapshots.add(e);
      }
    });
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(snapshots, isNotEmpty, reason: '首连应收到快照');

    // 杀 daemon → 隧道断 → 退避后重连；重启 daemon 后快照再次到达。
    for (final ws in liveSockets) {
      await ws.close();
    }
    await current.close(force: true);
    await Future<void>.delayed(const Duration(seconds: 2));
    final second = await startDaemon();
    await Future<void>.delayed(const Duration(seconds: 4));
    expect(snapshots.length, greaterThanOrEqualTo(2), reason: '重连成功后应补发快照');

    await stateSub.cancel();
    await sub.cancel();
    await link.stop();
    await second.close(force: true);
  }, timeout: const Timeout(Duration(seconds: 90)));
}
