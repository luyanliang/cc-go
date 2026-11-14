/// 配对编排（task 4.1）：TLS + TOFU 配对 → 凭据落库。纯逻辑、可注入，
/// 屏幕只负责表单与错误呈现。
library;

import 'dart:async';
import 'dart:io';

import 'package:cc_go/transport/ssh/ssh_secrets.dart';
import 'package:cc_go/transport/ssh/ssh_tunnel_link.dart';
import 'package:cc_go/transport/tofu.dart';

import 'host_entry.dart';

/// 用户可读的配对失败（码错/网络不通/指纹不符…），保留原始异常给调试页。
class PairingError implements Exception {
  const PairingError(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

/// Injectable seam — tests substitute this instead of hitting the network.
typedef PairFn = Future<PairSuccess> Function();

PairFn defaultPairFn(String host, int port, String code) {
  return () => pairWithDaemon(
        host: InternetAddress(host),
        port: port,
        code: code,
        policy: TofuPolicy(),
      );
}

/// 校验输入 → 配对 → 持久化直连主机条目。任何失败都以 [PairingError]
/// 抛出，不落任何凭据（spec：配对码错误时不保存任何凭据）。
/// [expectedFingerprint] 来自 mDNS 发现/扫码预填——给 TOFU 一个期望值。
Future<HostEntry> runPairing({
  required HostEntryStore store,
  required String host,
  required String portText,
  required String code,
  String? expectedFingerprint,
  PairFn? pair,
}) async {
  final normalizedHost = host.trim();
  var port = 0;
  if (normalizedHost.isEmpty) {
    throw const PairingError('请输入服务器地址');
  }
  try {
    port = int.parse(portText.trim());
  } on FormatException {
    throw const PairingError('端口格式不正确');
  }
  final normalizedCode = code.trim();
  if (normalizedCode.length != 6) {
    throw const PairingError('配对码为 6 位数字');
  }

  final pairFn = pair ??
      () => pairWithDaemon(
            host: InternetAddress(normalizedHost),
            port: port,
            code: normalizedCode,
            policy: TofuPolicy(expectedFingerprint: expectedFingerprint),
          );
  final PairSuccess success;
  try {
    success = await pairFn();
  } on PairingFailedException catch (e) {
    throw PairingError(e.message, e);
  } on TofuRejectedException catch (e) {
    throw PairingError('服务器证书指纹与记录不一致，若服务器重装过，请先"忘记主机"', e);
  } on SocketException catch (e) {
    throw PairingError('无法连接 $normalizedHost:$port，请检查地址端口与网络', e);
  } on TimeoutException catch (e) {
    throw PairingError('连接超时，请检查网络', e);
  } on HandshakeException catch (e) {
    throw PairingError('TLS 握手失败，请确认端口对应 cc-go daemon', e);
  }

  final entry = HostEntry(
    id: 'host-${DateTime.now().microsecondsSinceEpoch}',
    mode: ConnectionMode.direct,
    hostName: success.hostName,
    host: normalizedHost,
    port: port,
    token: success.token,
    fingerprint: success.fingerprint,
  );
  await store.save(entry);
  return entry;
}

/// SSH 模式配对（ssh-tunnel spec）：先建隧道 → 经隧道对 daemon 走 TLS
/// `/pair`（证书 TOFU 首连学习）→ SSH 密钥指纹落库 → 主机条目落库。
/// 任何失败都以 [PairingError] 抛出且不落条目。
Future<HostEntry> runSshPairing({
  required HostEntryStore store,
  required SshSecretsStore secretsStore,
  required FingerprintStore hostKeyStore,
  required SshHostConfig ssh,
  required int daemonPort,
  required String code,
  required SshSecrets secrets,
  Future<PairSuccess> Function(TunnelHandle tunnel)? pair,
  /// 用户确认信任新 SSH 主机指纹后重试时置 true。
  bool trustNewHostKey = false,
}) async {
  final normalizedCode = code.trim();
  if (normalizedCode.length != 6) {
    throw const PairingError('配对码为 6 位数字');
  }

  final endpoint = SshEndpoint(
    host: ssh.host,
    port: ssh.port,
    username: ssh.username,
    authMethod: ssh.authMethod,
    daemonPort: daemonPort,
  );
  final TunnelHandle tunnel;
  try {
    tunnel = await SshTunnelLink.openTunnel(
      endpoint,
      secrets,
      hostKeyStore: hostKeyStore,
      trustNewHostKey: trustNewHostKey,
    );
  } on SshLinkError catch (e) {
    switch (e.kind) {
      case SshLinkErrorKind.authFailed:
        throw PairingError(e.message, e);
      case SshLinkErrorKind.hostKeyRejected:
        throw PairingError('SSH 主机指纹变化，可能被中间人替换；如确认无误请删除主机后重试', e);
      case SshLinkErrorKind.forwardRefused:
        throw PairingError(
            'SSH 已连通，但 daemon 未在电脑本机 $daemonPort 端口监听（需要 --localhost 启动）', e);
      case SshLinkErrorKind.unreachable:
        throw PairingError('无法连接 SSH 主机 ${ssh.host}:${ssh.port}，请检查地址与网络', e);
    }
  }

  try {
    final pairFn = pair ??
        (t) => pairWithDaemon(
              host: InternetAddress.loopbackIPv4,
              port: t.localPort,
              code: normalizedCode,
              policy: TofuPolicy(),
            );
    final PairSuccess success;
    try {
      success = await pairFn(tunnel);
    } on PairingFailedException catch (e) {
      throw PairingError(e.message, e);
    } on TofuRejectedException catch (e) {
      throw PairingError('daemon 证书指纹与记录不一致，若服务器重装过，请先"忘记主机"', e);
    } on HandshakeException catch (e) {
      throw PairingError('TLS 握手失败，请确认端口对应 cc-go daemon', e);
    } on SocketException catch (e) {
      throw PairingError('隧道已建立但无法访问 daemon，请确认 daemon 在运行', e);
    } on TimeoutException catch (e) {
      throw PairingError('连接超时，请检查网络', e);
    }

    final entry = HostEntry(
      id: 'host-${DateTime.now().microsecondsSinceEpoch}',
      mode: ConnectionMode.ssh,
      hostName: success.hostName,
      host: ssh.host,
      port: daemonPort,
      token: success.token,
      fingerprint: success.fingerprint,
      ssh: ssh,
    );
    await secretsStore.write(entry.id, secrets);
    await store.save(entry);
    return entry;
  } finally {
    await tunnel.teardown();
  }
}
