/// 扫码配对（host-discovery spec「扫码配对」/ task 5.2）：daemon 启动横幅
/// 二维码的载荷 `ccgo://pair?host=…&port=…&code=…&fingerprint=…`。
library;

import 'package:meta/meta.dart';

/// 解析后的配对二维码。
@immutable
class PairQrPayload {
  const PairQrPayload({
    required this.host,
    required this.port,
    required this.code,
    this.fingerprint,
  });

  final String host;
  final int port;
  final String code;

  /// daemon 证书指纹；`--no-tls` 模式的二维码没有这个字段。
  final String? fingerprint;
}

/// 非配对二维码返回 null（UI 提示无效且不改表单，spec 要求）。
PairQrPayload? parsePairQr(String content) {
  final uri = Uri.tryParse(content.trim());
  if (uri == null || uri.scheme != 'ccgo' || uri.host != 'pair') {
    return null;
  }
  final host = uri.queryParameters['host'];
  final portText = uri.queryParameters['port'];
  final code = uri.queryParameters['code'];
  if (host == null || host.isEmpty) return null;
  final port = int.tryParse(portText ?? '');
  if (port == null || port <= 0 || port > 65535) return null;
  if (code == null || code.isEmpty) return null;
  final fingerprint = uri.queryParameters['fingerprint'];
  return PairQrPayload(
    host: host,
    port: port,
    code: code,
    fingerprint: (fingerprint == null || fingerprint.isEmpty) ? null : fingerprint,
  );
}
