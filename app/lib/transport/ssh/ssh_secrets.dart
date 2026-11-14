/// SSH 凭据存储（ssh-tunnel spec「SSH 隧道建立」/ design D3、D4）。
///
/// 密码与私钥 PEM 只进设备安全存储，永不进日志；私钥口令（passphrase）
/// 不持久化——加密私钥在每次连接时由用户现场输入（design「口令不存」）。
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// One SSH host's auth secrets. `null` 字段表示未设置（如只用私钥认证）。
class SshSecrets {
  const SshSecrets({this.password, this.privateKeyPem});

  final String? password;
  final String? privateKeyPem;

  bool get isEmpty => password == null && privateKeyPem == null;

  Map<String, dynamic> toJson() => {
        if (password != null) 'password': password,
        if (privateKeyPem != null) 'privateKeyPem': privateKeyPem,
      };

  static SshSecrets fromJson(Map<String, dynamic> json) => SshSecrets(
        password: json['password'] as String?,
        privateKeyPem: json['privateKeyPem'] as String?,
      );
}

abstract class SshSecretsStore {
  Future<SshSecrets?> read(String hostId);
  Future<void> write(String hostId, SshSecrets secrets);
  Future<void> remove(String hostId);
}

class MemorySshSecretsStore implements SshSecretsStore {
  final _byId = <String, SshSecrets>{};

  @override
  Future<SshSecrets?> read(String hostId) async => _byId[hostId];

  @override
  Future<void> write(String hostId, SshSecrets secrets) async =>
      _byId[hostId] = secrets;

  @override
  Future<void> remove(String hostId) async => _byId.remove(hostId);
}

class SecureSshSecretsStore implements SshSecretsStore {
  SecureSshSecretsStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  static const _prefix = 'ssh_secrets_v1:';

  final FlutterSecureStorage _storage;

  String _key(String hostId) => '$_prefix$hostId';

  @override
  Future<SshSecrets?> read(String hostId) async {
    final raw = await _storage.read(key: _key(hostId));
    if (raw == null) return null;
    try {
      return SshSecrets.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      return null; // 损坏条目视同未配置
    }
  }

  @override
  Future<void> write(String hostId, SshSecrets secrets) {
    return _storage.write(key: _key(hostId), value: jsonEncode(secrets.toJson()));
  }

  @override
  Future<void> remove(String hostId) => _storage.delete(key: _key(hostId));
}
