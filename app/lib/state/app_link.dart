/// 应用级连接生命周期（task 4.3）：凭据 → 带重连的 HostLink；token 被
/// daemon 拒绝（unauthorized）时通过 [AppLink.tokenInvalid] 上报，由
/// provider 侧停止重试、清除凭据、把路由打回配对屏。
library;

import 'dart:async';

import 'package:cc_go/transport/host_link.dart';
import 'package:cc_go/transport/network_kicks.dart';
import 'package:cc_go/transport/reconnecting_link.dart';
import 'package:cc_go/transport/ssh/ssh_secrets.dart';
import 'package:cc_go/transport/ssh/ssh_tunnel_link.dart';
import 'package:cc_go/transport/tofu.dart';
import 'package:meta/meta.dart';

import 'credentials.dart';
import 'host_entry.dart';

/// hello 被拒时 connector 抛出，[AppLink] 把它转成一次性事件。
class TokenInvalidException implements Exception {
  const TokenInvalidException();

  @override
  String toString() => 'token rejected by daemon';
}

/// 直连拨号的上界超时（network-kicks 真机验收结论）：直连模式的 TCP 拨号
/// 没有内建超时，网络切换后打到不可达地址（如流量路径访问局域网 IP）会
/// SYN 黑洞挂死分钟级，堵死 kick 锁存的消费。LAN 正常拨号亚秒级，8s 上界
/// 足够宽松；SSH 模式已有 SshEndpoint.connectTimeout（12s）。
const _directDialTimeout = Duration(seconds: 8);

/// 直连拨号（生产 connector 核心）：`HostLink.connect` + TOFU + 上界超时。
/// 独立导出以便单测（挂起的 TCP 握手 → [TimeoutException]）。
@visibleForTesting
Future<HostLinkBase> dialDirect({
  required Uri wsUri,
  required String token,
  required String? fingerprint,
}) async {
  try {
    return await HostLink.connect(
      wsUri: wsUri,
      token: token,
      customClient: tofuHttpClient(
        policy: TofuPolicy(expectedFingerprint: fingerprint),
      ),
    ).timeout(_directDialTimeout);
  } on RpcException catch (e) {
    if (e.code == 'unauthorized') throw const TokenInvalidException();
    rethrow;
  }
}

/// 把 daemon 拒绝 token 的事实暴露为流的 HostLink 集合。
class AppLink {
  AppLink._(this.entry, this.link, StreamController<void> tokenInvalid,
      NetworkKicks kicks)
      : _tokenInvalid = tokenInvalid,
        kicks = kicks {
    // kick 订阅与 tokenInvalid 同模式收在 AppLink（network-kicks design D3）：
    // transport 信号的消费点不进 UI 层，lifecycle_host 只递回前台事件。
    _kickSub = kicks.stream.listen((_) => link.kick());
  }

  /// 网络切换 / 回前台的 kick 事件源；`resume()` 由 lifecycle_host 调用。
  final NetworkKicks kicks;
  StreamSubscription<void>? _kickSub;

  /// 生产路径：按凭据直连（TOFU 指纹锁定）。
  factory AppLink.fromCredentials(HostCredentials credentials) {
    return AppLink.custom(
      _asCredentialsEntry(credentials),
      () => dialDirect(
        wsUri: credentials.wsUri,
        token: credentials.token,
        fingerprint: credentials.fingerprint,
      ),
    );
  }

  /// 生产路径：按主机条目连接——direct 走直连，ssh 走隧道（TLS/TOFU 等价）。
  /// SSH 模式的密码/私钥从 [sshSecrets] 按条目 id 取；token 被拒的分类与
  /// 直连一致（daemon 在 hello 时回 unauthorized / close code 4003）。
  factory AppLink.fromEntry(
    HostEntry entry, {
    required SshSecretsStore sshSecrets,
    required FingerprintStore sshHostKeyStore,
  }) {
    if (entry.mode == ConnectionMode.direct) {
      return AppLink.custom(
        entry,
        () => dialDirect(
          wsUri: entry.wsUri,
          token: entry.token,
          fingerprint: entry.fingerprint,
        ),
      );
    }
    final ssh = entry.ssh;
    if (ssh == null) {
      throw ArgumentError.value(entry, 'entry', 'ssh 模式缺少传输配置');
    }
    return AppLink.custom(
      entry,
      () async {
        final secrets = await sshSecrets.read(entry.id) ?? const SshSecrets();
        try {
          return await SshTunnelLink.connect(
            SshEndpoint(
              host: ssh.host,
              port: ssh.port,
              username: ssh.username,
              authMethod: ssh.authMethod,
              daemonPort: ssh.daemonPort,
              daemonToken: entry.token,
              daemonFingerprint: entry.fingerprint,
            ),
            secrets,
            hostKeyStore: sshHostKeyStore,
          );
        } on RpcException catch (e) {
          if (e.code == 'unauthorized') throw const TokenInvalidException();
          rethrow;
        }
      },
    );
  }

  static HostEntry _asCredentialsEntry(HostCredentials credentials) => HostEntry(
        id: 'default',
        mode: ConnectionMode.direct,
        hostName: credentials.hostName,
        host: credentials.host,
        port: credentials.port,
        token: credentials.token,
        fingerprint: credentials.fingerprint,
      );

  /// 测试路径：注入 dial（成功返回假链接；抛 [TokenInvalidException] 或
  /// [AuthRejectedByServer] 模拟 token 失效）。[kicks] 可注入替代真实
  /// connectivity 插件（widget 测试环境没有插件 mock，EventChannel 的
  /// 取消会悬挂）。
  @visibleForTesting
  factory AppLink.custom(
    HostEntry entry,
    Future<HostLinkBase> Function() dial, {
    NetworkKicks? kicks,
  }) {
    final tokenInvalid = StreamController<void>.broadcast();
    final effectiveKicks = kicks ?? NetworkKicks();
    final link = ReconnectingHostLink(
      connector: () async {
        try {
          return await dial();
        } on TokenInvalidException {
          _reportTokenInvalid(tokenInvalid);
          rethrow;
        } on AuthRejectedByServer {
          // daemon 以 close code 4003 掐断无效 token 的连接（server.ts）
          _reportTokenInvalid(tokenInvalid);
          throw const TokenInvalidException();
        }
      },
    );
    return AppLink._(entry, link, tokenInvalid, effectiveKicks);
  }

  static void _reportTokenInvalid(StreamController<void> sink) {
    if (!sink.isClosed) {
      sink.add(null);
      unawaited(sink.close()); // 一次性事件：发完即关
    }
  }

  final HostEntry entry;
  final ReconnectingHostLink link;
  final StreamController<void> _tokenInvalid;

  /// Emits once when the daemon rejects our token (daemon reset / unpaired).
  Stream<void> get tokenInvalid => _tokenInvalid.stream;

  Future<void> start() => link.start();

  Future<void> stop() async {
    await link.stop();
    // kick 订阅与事件源的收尾是 teardown 卫生操作（链接已停，不会再有
    // 事件），不 await：避免在 token 失效的关键路径上多排微任务边界。
    unawaited(_kickSub?.cancel());
    _kickSub = null;
    unawaited(kicks.dispose());
    await _tokenInvalid.close();
  }
}

/// 生产工厂：按凭据直连。测试 override 这个 provider 注入假 AppLink。