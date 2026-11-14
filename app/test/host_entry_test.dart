import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cc_go/state/host_entry.dart';
import 'package:cc_go/transport/ssh/ssh_tunnel_link.dart' show SshAuthMethod;

/// In-memory FlutterSecureStorage 桩（读/写/删都在 map 里）。
class _FakeSecureStorage extends FlutterSecureStorage {
  final _values = <String, String>{};

  @override
  Future<String?> read({
    AndroidOptions? aOptions,
    AppleOptions? iOptions,
    required String key,
    LinuxOptions? lOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
    WebOptions? webOptions,
  }) async =>
      _values[key];

  @override
  Future<void> write({
    AndroidOptions? aOptions,
    AppleOptions? iOptions,
    required String key,
    LinuxOptions? lOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
    required String? value,
    WebOptions? webOptions,
  }) async {
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
  }

  @override
  Future<bool> containsKey({
    AndroidOptions? aOptions,
    AppleOptions? iOptions,
    required String key,
    LinuxOptions? lOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
    WebOptions? webOptions,
  }) async =>
      _values.containsKey(key);

  @override
  Future<void> delete({
    AndroidOptions? aOptions,
    AppleOptions? iOptions,
    required String key,
    LinuxOptions? lOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
    WebOptions? webOptions,
  }) async {
    _values.remove(key);
  }
}

void main() {
  group('HostEntry JSON 往返', () {
    test('direct 条目', () {
      const entry = HostEntry(
        id: 'default',
        mode: ConnectionMode.direct,
        hostName: 'desk',
        host: '203.0.113.7',
        port: 8747,
        token: 'tok',
        fingerprint: 'AA:BB',
      );
      final decoded =
          HostEntry.fromJson(jsonDecode(jsonEncode(entry.toJson())) as Map<String, dynamic>);
      expect(decoded.id, entry.id);
      expect(decoded.mode, ConnectionMode.direct);
      expect(decoded.host, entry.host);
      expect(decoded.token, entry.token);
      expect(decoded.ssh, isNull);
    });

    test('ssh 条目（含传输配置）', () {
      const entry = HostEntry(
        id: 'host-1',
        mode: ConnectionMode.ssh,
        hostName: 'desk via ssh',
        host: '10.0.0.2',
        port: 22,
        token: 'tok',
        fingerprint: 'CC:DD',
        ssh: SshHostConfig(
          host: 'desk.example.com',
          port: 2022,
          username: 'luke',
          authMethod: SshAuthMethod.privateKey,
          daemonPort: 9000,
        ),
      );
      final decoded =
          HostEntry.fromJson(jsonDecode(jsonEncode(entry.toJson())) as Map<String, dynamic>);
      final ssh = decoded.ssh!;
      expect(ssh.host, 'desk.example.com');
      expect(ssh.port, 2022);
      expect(ssh.username, 'luke');
      expect(ssh.authMethod, SshAuthMethod.privateKey);
      expect(ssh.daemonPort, 9000);
    });
  });

  group('SecureHostEntryStore 迁移', () {
    test('旧格式 host_credentials_v1 → 回填为 id default 的直连主机', () async {
      final storage = _FakeSecureStorage();
      await storage.write(
        key: 'host_credentials_v1',
        value: jsonEncode({
          'host': '203.0.113.7',
          'port': 8747,
          'token': 'legacy-tok',
          'fingerprint': 'AA:BB',
          'hostName': 'desk',
        }),
      );
      final store = SecureHostEntryStore(storage);
      final entries = await store.readAll();
      expect(entries, hasLength(1));
      expect(entries.first.id, 'default');
      expect(entries.first.mode, ConnectionMode.direct);
      expect(entries.first.token, 'legacy-tok');
      // 迁移写入 v2，重启后不再依赖旧键。
      expect(await store.readAll(), hasLength(1));
      expect(
        await storage.read(key: 'host_entries_v2'),
        isNotNull,
        reason: '迁移结果已写入 v2 键',
      );
    });

    test('无任何存储 → 空列表', () async {
      final store = SecureHostEntryStore(_FakeSecureStorage());
      expect(await store.readAll(), isEmpty);
    });

    test('save/remove/clear 维护列表', () async {
      final store = SecureHostEntryStore(_FakeSecureStorage());
      const a = HostEntry(
        id: 'a',
        mode: ConnectionMode.direct,
        hostName: 'A',
        host: 'h',
        port: 1,
        token: 't',
        fingerprint: 'f',
      );
      final b = HostEntry(
        id: 'b',
        mode: ConnectionMode.ssh,
        hostName: 'B',
        host: 'h2',
        port: 2,
        token: 't2',
        fingerprint: 'f2',
        ssh: const SshHostConfig(
          host: 's',
          port: 22,
          username: 'u',
          authMethod: SshAuthMethod.password,
        ),
      );
      await store.save(a);
      await store.save(b);
      expect((await store.readAll()).map((e) => e.id), unorderedEquals(['a', 'b']));

      // 同 id 保存 = 更新，不产生重复。
      await store.save(a.copyWith(token: 't-new'));
      final all = await store.readAll();
      expect(all, hasLength(2));
      expect(all.firstWhere((e) => e.id == 'a').token, 't-new');

      await store.remove('b');
      expect((await store.readAll()).map((e) => e.id), ['a']);

      await store.clear();
      expect(await store.readAll(), isEmpty);
    });

    test('损坏的 v2 数据视同未配对', () async {
      final storage = _FakeSecureStorage();
      await storage.write(key: 'host_entries_v2', value: 'not json');
      final store = SecureHostEntryStore(storage);
      expect(await store.readAll(), isEmpty);
    });
  });
}
