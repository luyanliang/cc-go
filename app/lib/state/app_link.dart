/// 应用级连接生命周期（task 4.3）：凭据 → 带重连的 HostLink；token 被
/// daemon 拒绝（unauthorized）时通过 [AppLink.tokenInvalid] 上报，由
/// provider 侧停止重试、清除凭据、把路由打回配对屏。
library;

import 'dart:async';

import 'package:cc_go/transport/host_link.dart';
import 'package:cc_go/transport/reconnecting_link.dart';
import 'package:cc_go/transport/tofu.dart';
import 'package:meta/meta.dart';

import 'credentials.dart';

/// hello 被拒时 connector 抛出，[AppLink] 把它转成一次性事件。
class TokenInvalidException implements Exception {
  const TokenInvalidException();

  @override
  String toString() => 'token rejected by daemon';
}

/// 把 daemon 拒绝 token 的事实暴露为流的 HostLink 集合。
class AppLink {
  AppLink._(this.credentials, this.link, StreamController<void> tokenInvalid)
      : _tokenInvalid = tokenInvalid;

  /// 生产路径：按凭据直连（TOFU 指纹锁定）。
  factory AppLink.fromCredentials(HostCredentials credentials) {
    return AppLink.custom(
      credentials,
      () async {
        try {
          return await HostLink.connect(
            wsUri: credentials.wsUri,
            token: credentials.token,
            customClient: tofuHttpClient(
              policy: TofuPolicy(expectedFingerprint: credentials.fingerprint),
            ),
          );
        } on RpcException catch (e) {
          if (e.code == 'unauthorized') throw const TokenInvalidException();
          rethrow;
        }
      },
    );
  }

  /// 测试路径：注入 dial（成功返回假链接；抛 [TokenInvalidException] 或
  /// [AuthRejectedByServer] 模拟 token 失效）。
  @visibleForTesting
  factory AppLink.custom(HostCredentials credentials, Future<HostLinkBase> Function() dial) {
    final tokenInvalid = StreamController<void>.broadcast();
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
    return AppLink._(credentials, link, tokenInvalid);
  }

  static void _reportTokenInvalid(StreamController<void> sink) {
    if (!sink.isClosed) {
      sink.add(null);
      unawaited(sink.close()); // 一次性事件：发完即关
    }
  }

  final HostCredentials credentials;
  final ReconnectingHostLink link;
  final StreamController<void> _tokenInvalid;

  /// Emits once when the daemon rejects our token (daemon reset / unpaired).
  Stream<void> get tokenInvalid => _tokenInvalid.stream;

  Future<void> start() => link.start();

  Future<void> stop() async {
    await link.stop();
    await _tokenInvalid.close();
  }
}

/// 生产工厂：按凭据直连。测试 override 这个 provider 注入假 AppLink。