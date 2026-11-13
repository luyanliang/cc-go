/// 配对编排（task 4.1）：TLS + TOFU 配对 → 凭据落库。纯逻辑、可注入，
/// 屏幕只负责表单与错误呈现。
library;

import 'dart:async';
import 'dart:io';

import 'package:cc_go/transport/tofu.dart';

import 'credentials.dart';

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

/// 校验输入 → 配对 → 持久化。任何失败都以 [PairingError] 抛出，不落任何
/// 凭据（spec：配对码错误时不保存任何凭据）。
Future<HostCredentials> runPairing({
  required CredentialStore store,
  required String host,
  required String portText,
  required String code,
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

  final pairFn = pair ?? defaultPairFn(normalizedHost, port, normalizedCode);
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

  final credentials = HostCredentials(
    host: normalizedHost,
    port: port,
    token: success.token,
    fingerprint: success.fingerprint,
    hostName: success.hostName,
  );
  await store.write(credentials);
  return credentials;
}
