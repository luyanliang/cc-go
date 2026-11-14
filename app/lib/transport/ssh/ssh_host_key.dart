/// SSH 主机公钥指纹 TOFU（ssh-tunnel spec「SSH 主机指纹 TOFU」/ design D3）。
///
/// 与 daemon 证书指纹（tofu.dart）互不替代、分开存储：键为
/// `host:port`，指纹为 dartssh2 上报的 `SHA256:<base64>`（与
/// `ssh-keygen -lf` 同形）。首次连接 learn，之后比对；不一致 reject，
/// 只有用户显式确认后才更新已存指纹。
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../tofu.dart' show FingerprintStore;

/// 纯 TOFU 判定逻辑 — 单元测试覆盖三态。
enum SshHostKeyDecision { trust, learn, reject }

class SshHostKeyPolicy {
  SshHostKeyPolicy({String? knownFingerprint}) : _known = knownFingerprint;

  final String? _known;

  /// dartssh2 的 fingerprint 参数是 `SHA256:<base64>` 字节串（utf8）。
  SshHostKeyDecision decide(String presentedFingerprint) {
    if (_known == null) return SshHostKeyDecision.learn;
    return normalizeHostKeyFingerprint(presentedFingerprint) ==
            normalizeHostKeyFingerprint(_known)
        ? SshHostKeyDecision.trust
        : SshHostKeyDecision.reject;
  }
}

/// 归一化：统一去掉 `SHA256:` 前缀与 padding 差异敏感的空白，留 base64 本体。
String normalizeHostKeyFingerprint(String fingerprint) =>
    fingerprint.trim().replaceFirst(RegExp(r'^SHA256:', caseSensitive: false), '').trim();

/// `host:port` → 存储键，加前缀与 daemon 证书指纹空间隔离。
String sshHostKeyStoreKey(String host, int port) => 'ssh-hostkey:$host:$port';

/// TOFU 组合件：按 `host:port` 读写指纹并给出判定。
class SshHostKeyVerifier {
  // ignore: prefer_initializing_formals — named 参数 `store` 对外，字段私有。
  SshHostKeyVerifier({required FingerprintStore store}) : _store = store;

  final FingerprintStore _store;

  /// 返回判定；`learn` 时把 [presented] 写入存储。用户在 UI 显式确认
  /// 「信任新指纹」后 [userConfirmedReplacement] 为 true → 覆写并放行。
  Future<SshHostKeyDecision> verify(
    String host,
    int port,
    String presented, {
    bool userConfirmedReplacement = false,
  }) async {
    final known = await _store.read(sshHostKeyStoreKey(host, port));
    final decision =
        SshHostKeyPolicy(knownFingerprint: known).decide(presented);
    if (decision == SshHostKeyDecision.learn) {
      await _store.write(sshHostKeyStoreKey(host, port), presented);
    }
    if (decision == SshHostKeyDecision.reject && userConfirmedReplacement) {
      await _store.write(sshHostKeyStoreKey(host, port), presented);
      return SshHostKeyDecision.learn;
    }
    return decision;
  }

  /// 「忘记主机」：清除已存指纹，下次连接重新 learn。
  Future<void> forget(String host, int port) =>
      _store.remove(sshHostKeyStoreKey(host, port));
}

/// 指纹存储必须逐字节保留：SSH 主机指纹是大小写敏感的 base64
/// （tofu.dart 的 `MemoryFingerprintStore` 按 TLS 指纹惯例归一化，不通用）。
class SshHostKeyMemoryStore implements FingerprintStore {
  final _byKey = <String, String>{};

  @override
  Future<String?> read(String key) async => _byKey[key];

  @override
  Future<void> write(String key, String fingerprint) async =>
      _byKey[key] = fingerprint;

  @override
  Future<void> remove(String key) async => _byKey.remove(key);
}

/// secure storage 实现（生产路径；键为 [sshHostKeyStoreKey]）。
class SecureSshHostKeyStore implements FingerprintStore {
  SecureSshHostKeyStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String fingerprint) =>
      _storage.write(key: key, value: fingerprint);

  @override
  Future<void> remove(String key) => _storage.delete(key: key);
}
