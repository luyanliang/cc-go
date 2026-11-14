/// Riverpod 装配（设计 D4）。4.x 先立凭据与配对；会话级 controller
/// （autoDispose.family）随第 5/6 节加入。4.1 起凭据模型是多主机列表
/// （HostEntry），credentialsProvider 保留为「当前主机」的派生视图，
/// 既有消费者（路由/生命周期/UI）无感。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../transport/ssh/ssh_host_key.dart';
import '../transport/ssh/ssh_secrets.dart';
import '../transport/tofu.dart';
import 'credentials.dart';
import 'host_entry.dart';
import 'secure_credential_store.dart';

final credentialStoreProvider = Provider<CredentialStore>((ref) {
  return SecureCredentialStore();
});

final hostEntryStoreProvider = Provider<HostEntryStore>((ref) {
  return SecureHostEntryStore();
});

final sshSecretsStoreProvider = Provider<SshSecretsStore>((ref) {
  return SecureSshSecretsStore();
});

/// SSH 主机公钥指纹（TOFU）的存储：与 daemon 证书指纹分开、独立键空间。
final sshHostKeyStoreProvider = Provider<FingerprintStore>((ref) {
  return SecureSshHostKeyStore();
});

/// 已保存的主机列表；空 = 未配对 → 显示配对屏。
/// invalidate 让"忘记主机/重新配对/主机增删"后的路由立即生效。
final hostEntriesProvider = FutureProvider<List<HostEntry>>((ref) async {
  final store = ref.watch(hostEntryStoreProvider);
  return store.readAll();
});

/// 用户显式选择的当前主机 id；null = 取列表第一条。在主机管理屏切换。
class ActiveEntryId extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? id) => state = id;
}

final activeEntryIdProvider =
    NotifierProvider<ActiveEntryId, String?>(ActiveEntryId.new);

/// 当前主机：显式选择优先，否则列表第一条。
final activeEntryProvider = FutureProvider<HostEntry?>((ref) async {
  final entries = await ref.watch(hostEntriesProvider.future);
  if (entries.isEmpty) return null;
  final activeId = ref.watch(activeEntryIdProvider);
  for (final entry in entries) {
    if (entry.id == activeId) return entry;
  }
  return entries.first;
});

/// 「当前主机」的直连凭据视图（旧消费者兼容；SSH 模式返回的凭据只含
/// daemon 侧字段，连接方式由 appLinkProvider 按条目 mode 决定）。
final credentialsProvider = FutureProvider<HostCredentials?>((ref) async {
  final entry = await ref.watch(activeEntryProvider.future);
  if (entry == null) return null;
  return HostCredentials(
    host: entry.host,
    port: entry.port,
    token: entry.token,
    fingerprint: entry.fingerprint,
    hostName: entry.hostName,
  );
});
