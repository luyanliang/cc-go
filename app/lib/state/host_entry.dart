/// 多主机凭据模型（task 4.1 / design D4）：每台已配对的电脑一条
/// [HostEntry]。直连与 SSH 隧道两种连接方式共用 daemon 侧字段
/// （token + 证书指纹在配对成功后才有）；SSH 传输配置随条目保存，
/// 但 SSH 密码/私钥不在这里——它们走 [SshSecretsStore]（按条目 id
/// 键控的独立 secure storage 通道）。
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../transport/ssh/ssh_tunnel_link.dart';

/// 连接方式。
enum ConnectionMode { direct, ssh }

/// SSH 传输配置（不含凭据密钥）。
class SshHostConfig {
  const SshHostConfig({
    required this.host,
    required this.port,
    required this.username,
    required this.authMethod,
    this.daemonPort = 8747,
  });

  final String host;
  final int port;
  final String username;
  final SshAuthMethod authMethod;

  /// daemon 在电脑侧的回环端口（`--localhost` 模式，默认 8747）。
  final int daemonPort;

  Map<String, dynamic> toJson() => {
        'host': host,
        'port': port,
        'username': username,
        'authMethod': authMethod.name,
        'daemonPort': daemonPort,
      };

  static SshHostConfig fromJson(Map<String, dynamic> json) => SshHostConfig(
        host: json['host'] as String,
        port: json['port'] as int,
        username: json['username'] as String,
        authMethod: SshAuthMethod.values.byName(json['authMethod'] as String),
        daemonPort: json['daemonPort'] as int? ?? 8747,
      );
}

/// 一台已配对主机的全部持久化状态（SSH 密钥材料与 SSH 主机指纹除外：
/// 前者在 [SshSecretsStore]，后者在 SSH 的 `FingerprintStore`，均按
/// 条目/主机键控的独立 secure storage 通道，避免双写分叉）。
class HostEntry {
  const HostEntry({
    required this.id,
    required this.mode,
    required this.hostName,
    required this.host,
    required this.port,
    required this.token,
    required this.fingerprint,
    this.ssh,
  });

  /// 稳定标识（迁移的旧单主机固定为 `default`）。
  final String id;

  /// 展示名：daemon 名称或用户标签。
  final String hostName;

  final ConnectionMode mode;

  /// daemon 直连地址（SSH 模式下是经隧道配对时记录的值，仅作展示）。
  final String host;
  final int port;

  /// daemon 设备 token（配对换发）。
  final String token;

  /// daemon 证书指纹（TOFU，openssl 冒号十六进制形）。
  final String fingerprint;

  /// SSH 传输配置；`mode == ssh` 时非空。
  final SshHostConfig? ssh;

  Uri get wsUri => Uri(scheme: 'wss', host: host, port: port, path: '/ws');
  String get displayHost => '$host:$port';

  HostEntry copyWith({
    String? token,
    String? fingerprint,
    String? hostName,
  }) =>
      HostEntry(
        id: id,
        mode: mode,
        hostName: hostName ?? this.hostName,
        host: host,
        port: port,
        token: token ?? this.token,
        fingerprint: fingerprint ?? this.fingerprint,
        ssh: ssh,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'mode': mode.name,
        'hostName': hostName,
        'host': host,
        'port': port,
        'token': token,
        'fingerprint': fingerprint,
        if (ssh != null) 'ssh': ssh!.toJson(),
      };

  static HostEntry fromJson(Map<String, dynamic> json) {
    final modeName = json['mode'] as String? ?? 'direct';
    final sshJson = json['ssh'] as Map<String, dynamic>?;
    return HostEntry(
      id: json['id'] as String,
      mode: ConnectionMode.values.byName(modeName),
      hostName: json['hostName'] as String,
      host: json['host'] as String,
      port: json['port'] as int,
      token: json['token'] as String,
      fingerprint: json['fingerprint'] as String,
      ssh: sshJson == null ? null : SshHostConfig.fromJson(sshJson),
    );
  }
}

/// 主机列表的持久化接口。
abstract class HostEntryStore {
  Future<List<HostEntry>> readAll();
  Future<void> save(HostEntry entry);
  Future<void> remove(String id);
  Future<void> clear();
}

class MemoryHostEntryStore implements HostEntryStore {
  final _entries = <String, HostEntry>{};

  @override
  Future<List<HostEntry>> readAll() async => _entries.values.toList();

  @override
  Future<void> save(HostEntry entry) async => _entries[entry.id] = entry;

  @override
  Future<void> remove(String id) async => _entries.remove(id);

  @override
  Future<void> clear() async => _entries.clear();
}

/// secure storage 实现。v2 格式是 `host_entries_v2` 下的 JSON 列表；
/// 读不到时回退旧单主机键 `host_credentials_v1`（4.2 之前的格式），
/// 回填为 id `default` 的直连主机。
class SecureHostEntryStore implements HostEntryStore {
  SecureHostEntryStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'host_entries_v2';
  static const _legacyKey = 'host_credentials_v1';

  final FlutterSecureStorage _storage;

  @override
  Future<List<HostEntry>> readAll() async {
    // v2 键存在即权威（哪怕是空列表——否则迁移后 remove 到 0 条会复活旧键）。
    if (await _storage.containsKey(key: _key)) return _readV2();
    return _readLegacy();
  }

  /// 旧单主机格式（host_credentials_v1）→ 一条 id `default` 的直连主机。
  Future<List<HostEntry>> _readLegacy() async {
    final raw = await _storage.read(key: _legacyKey);
    if (raw == null) return const [];
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final entry = HostEntry(
        id: 'default',
        mode: ConnectionMode.direct,
        hostName: map['hostName'] as String,
        host: map['host'] as String,
        port: map['port'] as int,
        token: map['token'] as String,
        fingerprint: map['fingerprint'] as String,
      );
      await save(entry); // 迁移写入 v2；旧键保留无害，clear 时一并删
      return [entry];
    } on Object {
      return const [];
    }
  }

  @override
  Future<void> save(HostEntry entry) async {
    final entries = await _readV2();
    final others = entries.where((e) => e.id != entry.id).toList();
    others.add(entry);
    await _storage.write(key: _key, value: jsonEncode([for (final e in others) e.toJson()]));
  }

  @override
  Future<void> remove(String id) async {
    final entries = await _readV2();
    await _storage.write(
      key: _key,
      value: jsonEncode([for (final e in entries) if (e.id != id) e.toJson()]),
    );
  }

  /// 只读 v2 键（不触发旧格式迁移——迁移写回 [save] 时不能递归 readAll）。
  Future<List<HostEntry>> _readV2() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return [
        for (final item in list) HostEntry.fromJson(item as Map<String, dynamic>),
      ];
    } on Object {
      return const [];
    }
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: _key);
    await _storage.delete(key: _legacyKey);
  }
}
