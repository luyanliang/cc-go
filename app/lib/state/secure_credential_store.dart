/// SecureCredentialStore：凭据的设备安全存储实现（task 4.2）。
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'credentials.dart';

class SecureCredentialStore implements CredentialStore {
  SecureCredentialStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'host_credentials_v1';

  final FlutterSecureStorage _storage;

  @override
  Future<HostCredentials?> read() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return HostCredentials(
        host: map['host'] as String,
        port: map['port'] as int,
        token: map['token'] as String,
        fingerprint: map['fingerprint'] as String,
        hostName: map['hostName'] as String,
      );
    } on Object {
      return null; // 损坏条目视同未配对
    }
  }

  @override
  Future<void> write(HostCredentials credentials) {
    return _storage.write(
      key: _key,
      value: jsonEncode({
        'host': credentials.host,
        'port': credentials.port,
        'token': credentials.token,
        'fingerprint': credentials.fingerprint,
        'hostName': credentials.hostName,
      }),
    );
  }

  @override
  Future<void> clear() => _storage.delete(key: _key);
}
