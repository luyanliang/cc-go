/// SSH 隧道传输（ssh-tunnel spec / design D1）：dartssh2 连接 SSH 主机后，
/// 手机本地开一个 127.0.0.1 临时端口，把进来的连接桥接到 `forwardLocal`
/// direct-tcpip 通道；`HostLink` 照常拨 `wss://127.0.0.1:<临时端口>/ws`，
/// TLS 与 daemon 证书 TOFU 栈原样复用。
///
/// [SshTunnelLink.openTunnel] 暴露 [TunnelHandle.localPort]，配对流程
/// （`runSshPairing`）经同一隧道走 HTTPS `/pair`；[SshTunnelLink.connect]
/// 在其上完成 WebSocket 握手，对外实现 `HostLinkBase`，因此
/// `ReconnectingHostLink` 的退避重连、重订阅、快照补齐零改动可用。
library;

import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:meta/meta.dart';

import '../host_link.dart';
import '../tofu.dart';
import 'ssh_host_key.dart';
import 'ssh_secrets.dart';

/// SSH 认证方式（design D4）。
enum SshAuthMethod { password, privateKey }

/// 隧道建立失败的分类（ssh-tunnel spec：认证失败 / 无法连接 SSH 主机 /
/// 端口转发失败必须可区分）。
enum SshLinkErrorKind { unreachable, authFailed, hostKeyRejected, forwardRefused }

class SshLinkError implements Exception {
  const SshLinkError(this.kind, this.message, [this.detail]);

  final SshLinkErrorKind kind;
  final String message;
  final String? detail;

  @override
  String toString() =>
      'SshLinkError(${kind.name}: $message${detail == null ? '' : ' — $detail'})';
}

/// 一次 SSH 隧道连接的全部参数。
@immutable
class SshEndpoint {
  const SshEndpoint({
    required this.host,
    required this.port,
    required this.username,
    required this.authMethod,
    required this.daemonPort,
    this.daemonHost = '127.0.0.1',
    this.daemonToken = '',
    this.daemonFingerprint,
    // 测试可关（对明文假 daemon 验证桥接）；生产恒为 TLS（spec 安全等价）。
    this.daemonTls = true,
    this.connectTimeout = const Duration(seconds: 12),
  });

  final String host;
  final int port;
  final String username;
  final SshAuthMethod authMethod;

  /// daemon 在 SSH 主机侧的回环地址与端口（通常 `--localhost` 模式）。
  final String daemonHost;
  final int daemonPort;
  final String daemonToken;

  /// daemon 证书指纹（TOFU 期望值）；`null` 表示首连学习。
  final String? daemonFingerprint;

  final bool daemonTls;
  final Duration connectTimeout;
}

/// 一条已建立的隧道：本地回环端口 + 拆除动作。WS 与配对共用。
class TunnelHandle {
  const TunnelHandle({required this.localPort, required this.teardown});

  /// 桥接到 daemon 回环端口的本地监听端口（127.0.0.1:[localPort]）。
  final int localPort;

  /// 关本地监听与 SSH 连接；幂等，可安全多次调用。
  final Future<void> Function() teardown;
}

class SshTunnelLink {
  SshTunnelLink._();

  /// dartssh2 连接 → 预开首条 direct-tcpip → 本地回环端口桥接。
  ///
  /// 首条通道预先打开：daemon 没在目标端口监听时立刻以 forwardRefused
  /// 失败（错误能抛回调用方，而不是丢在 listener 回调里）。
  static Future<TunnelHandle> openTunnel(
    SshEndpoint endpoint,
    SshSecrets secrets, {
    FingerprintStore? hostKeyStore,
    /// 用户已在 UI 确认「信任新主机指纹」→ 覆写已存指纹并继续连接。
    bool trustNewHostKey = false,
  }) async {
    final keys = endpoint.authMethod == SshAuthMethod.privateKey
        ? _decodePrivateKey(secrets.privateKeyPem)
        : null;
    if (endpoint.authMethod == SshAuthMethod.password &&
        (secrets.password ?? '').isEmpty) {
      throw const SshLinkError(
          SshLinkErrorKind.authFailed, 'SSH 密码未配置');
    }

    // 1. SSH 连接（主机指纹 TOFU 在 onVerifyHostKey 里同步判定）。
    final keyStore = hostKeyStore ?? SshHostKeyMemoryStore();
    final verifier = SshHostKeyVerifier(store: keyStore);
    SSHClient? client;
    Object? hostKeyVerdict;
    final SSHSocket socket;
    try {
      socket = await SSHSocket.connect(
        endpoint.host,
        endpoint.port,
        timeout: endpoint.connectTimeout,
      );
    } on SocketException catch (error) {
      throw SshLinkError(
        SshLinkErrorKind.unreachable,
        '无法连接 SSH 主机 ${endpoint.host}:${endpoint.port}',
        '$error',
      );
    } on TimeoutException {
      throw SshLinkError(
        SshLinkErrorKind.unreachable,
        'SSH 主机 ${endpoint.host}:${endpoint.port} 无响应',
      );
    }

    try {
      client = SSHClient(
        socket,
        username: endpoint.username,
        identities: keys,
        onPasswordRequest: endpoint.authMethod == SshAuthMethod.password
            ? () => secrets.password
            : null,
        onVerifyHostKey: (type, fingerprint) async {
          final presented = String.fromCharCodes(fingerprint);
          final decision = await verifier.verify(
            endpoint.host,
            endpoint.port,
            presented,
            userConfirmedReplacement: trustNewHostKey,
          );
          if (decision == SshHostKeyDecision.reject) {
            hostKeyVerdict = SshLinkError(
              SshLinkErrorKind.hostKeyRejected,
              'SSH 主机指纹变化，可能被中间人替换',
              'got $presented',
            );
            return false;
          }
          return true;
        },
      );
      await client.authenticated;
    } on Object catch (error) {
      client?.close();
      if (hostKeyVerdict != null) throw hostKeyVerdict!;
      if (error is SSHAuthError) {
        throw SshLinkError(
          SshLinkErrorKind.authFailed,
          endpoint.authMethod == SshAuthMethod.password
              ? 'SSH 用户名或密码被拒绝'
              : 'SSH 私钥被拒绝',
          '$error',
        );
      }
      throw SshLinkError(
        SshLinkErrorKind.unreachable,
        'SSH 握手失败',
        '$error',
      );
    }
    final ssh = client;

    // 2. 预开首条 direct-tcpip 通道。
    SSHForwardChannel firstChannel;
    try {
      firstChannel = await ssh.forwardLocal(endpoint.daemonHost, endpoint.daemonPort);
    } on SSHChannelOpenError catch (error) {
      // 2 = SSH_OPEN_CONNECT_FAILED：对端拒绝连接（没有进程在监听）。
      ssh.close();
      if (error.code == 2) {
        throw SshLinkError(
          SshLinkErrorKind.forwardRefused,
          'daemon 未在 ${endpoint.daemonHost}:${endpoint.daemonPort} 监听',
          '$error',
        );
      }
      throw SshLinkError(
        SshLinkErrorKind.unreachable,
        'SSH 转发通道打开失败',
        '$error',
      );
    } on Object {
      ssh.close();
      rethrow;
    }
    late final ServerSocket local;
    try {
      local = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    } on Object {
      ssh.close();
      rethrow;
    }
    final subscriptions = <StreamSubscription<void>>[];
    var bridged = false;
    local.listen((socket) {
      // 每条隧道只服务一个下游连接（一个 WebSocket 或一次配对请求）；
      // 重连/重配对走全新的 openTunnel。多余连接直接拒绝。
      if (bridged) {
        socket.destroy();
        return;
      }
      bridged = true;
      final channel = firstChannel;
      subscriptions.add(channel.stream.cast<List<int>>().listen(
            socket.add,
            onDone: socket.destroy,
            onError: (_) => socket.destroy(),
          ));
      subscriptions.add(socket.listen(
        channel.sink.add,
        onDone: channel.sink.close,
        onError: (_) => channel.sink.close(),
      ));
    });

    var tornDown = false;
    Future<void> teardown() async {
      if (tornDown) return;
      tornDown = true;
      for (final s in subscriptions) {
        await s.cancel();
      }
      await local.close();
      ssh.close();
    }

    return TunnelHandle(localPort: local.port, teardown: teardown);
  }

  /// 在隧道上完成 WebSocket 握手，返回 [HostLinkBase]。
  static Future<HostLinkBase> connect(
    SshEndpoint endpoint,
    SshSecrets secrets, {
    FingerprintStore? hostKeyStore,
    void Function(String learnedFingerprint)? onDaemonFingerprintLearned,
    bool trustNewHostKey = false,
  }) async {
    final tunnel = await openTunnel(
      endpoint,
      secrets,
      hostKeyStore: hostKeyStore,
      trustNewHostKey: trustNewHostKey,
    );

    // 在回环端口上按直连方式拨 wss（TLS + 证书 TOFU 全部复用）。
    final pinnedClient = endpoint.daemonTls
        ? tofuHttpClient(
            policy: TofuPolicy(expectedFingerprint: endpoint.daemonFingerprint),
            onFingerprintLearned: onDaemonFingerprintLearned,
          )
        : null;

    final wsUri = Uri(
      scheme: endpoint.daemonTls ? 'wss' : 'ws',
      host: '127.0.0.1',
      port: tunnel.localPort,
      path: '/ws',
    );
    HostLinkBase link;
    try {
      link = await HostLink.connect(
        wsUri: wsUri,
        token: endpoint.daemonToken,
        customClient: pinnedClient,
      );
    } on Object {
      await tunnel.teardown();
      rethrow;
    }

    // WS 一断就拆除隧道：ReconnectingHostLink 断线时并不 close 旧 link，
    // 直连场景无所谓，隧道场景不拆就每次重连漏一条 SSH 连接。
    // close() 与 events 的 onDone 都会触发，teardown 幂等。
    unawaited(
      link.events.listen((_) {}, onDone: tunnel.teardown, onError: (_) {})
          .asFuture<void>(),
    );
    return _TunnelLink(link, tunnel.teardown);
  }

  static List<SSHKeyPair> _decodePrivateKey(String? pem) {
    final text = pem?.trim() ?? '';
    if (text.isEmpty) {
      throw const SshLinkError(SshLinkErrorKind.authFailed, 'SSH 私钥未配置');
    }
    try {
      return SSHKeyPair.fromPem(text, null);
    } on Object catch (error) {
      throw SshLinkError(SshLinkErrorKind.authFailed, 'SSH 私钥无法解析', '$error');
    }
  }
}

/// [HostLinkBase] 委托 + 关联隧道的生命周期（close 触发隧道拆除）。
class _TunnelLink implements HostLinkBase {
  _TunnelLink(this._link, this._teardown);

  final HostLinkBase _link;
  final Future<void> Function() _teardown;

  @override
  Stream<DaemonEvent> get events => _link.events;

  @override
  Future<dynamic> call(String method, [Map<String, dynamic> params = const {}]) =>
      _link.call(method, params);

  @override
  Future<void> close({String reason = 'closed locally'}) async {
    await _link.close(reason: reason);
    await _teardown();
  }
}
