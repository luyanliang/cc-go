/// Riverpod 装配（设计 D4）。4.x 先立凭据与配对；会话级 controller
/// （autoDispose.family）随第 5/6 节加入。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'credentials.dart';
import 'secure_credential_store.dart';

final credentialStoreProvider = Provider<CredentialStore>((ref) {
  return SecureCredentialStore();
});

/// 已保存的凭据；null = 未配对 → 显示配对屏。
/// invalidate 让"忘记主机/重新配对"后的路由立即生效。
final credentialsProvider = FutureProvider<HostCredentials?>((ref) async {
  final store = ref.watch(credentialStoreProvider);
  return store.read();
});
