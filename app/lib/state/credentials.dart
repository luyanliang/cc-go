/// 配对凭据（task 4.2）：设备 token + 证书指纹 + 主机地址，持久化到
/// 设备安全存储；App 重启后凭它免配对直达会话列表。
library;



class HostCredentials {
  const HostCredentials({
    required this.host,
    required this.port,
    required this.token,
    required this.fingerprint,
    required this.hostName,
  });

  final String host;
  final int port;
  final String token;
  final String fingerprint;
  final String hostName;

  Uri get wsUri => Uri(scheme: 'wss', host: host, port: port, path: '/ws');
  String get displayHost => '$host:$port';

  HostCredentials copyWith({String? token, String? fingerprint, String? hostName}) =>
      HostCredentials(
        host: host,
        port: port,
        token: token ?? this.token,
        fingerprint: fingerprint ?? this.fingerprint,
        hostName: hostName ?? this.hostName,
      );
}

/// "忘记主机"/重新配对（task 4.3、secure-transport spec）都走 [clear]。
abstract class CredentialStore {
  Future<HostCredentials?> read();
  Future<void> write(HostCredentials credentials);
  Future<void> clear();
}

class MemoryCredentialStore implements CredentialStore {
  HostCredentials? _value;

  @override
  Future<HostCredentials?> read() async => _value;

  @override
  Future<void> write(HostCredentials credentials) async => _value = credentials;

  @override
  Future<void> clear() async => _value = null;
}
