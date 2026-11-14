/// appLinkProvider 的 Riverpod 接线（task 4.3）：凭据 → AppLink 生命周期；
/// token 失效 → 清凭据回配对屏。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_link.dart';
import 'host_entry.dart';
import 'providers.dart';

final appLinkFactoryProvider = Provider<AppLink Function(HostEntry)>((ref) {
  return (entry) => AppLink.fromEntry(
        entry,
        sshSecrets: ref.read(sshSecretsStoreProvider),
        sshHostKeyStore: ref.read(sshHostKeyStoreProvider),
      );
});

/// 主连接：已配对时创建并启动；token 失效 → 停止重试、清凭据、路由回
/// 配对屏（task 4.3）。主机变化（重新配对/忘记主机/增删主机）时自动重建。
final appLinkProvider = FutureProvider<AppLink>((ref) async {
  final entry = await ref.watch(activeEntryProvider.future);
  if (entry == null) {
    throw StateError('appLinkProvider requires a paired host entry');
  }

  final appLink = ref.watch(appLinkFactoryProvider)(entry);

  // token 失效：停止重试、清凭据、路由回配对屏（task 4.3）。
  final sub = appLink.tokenInvalid.listen((_) async {
    await appLink.stop();
    await ref.read(hostEntryStoreProvider).remove(entry.id);
    await ref.read(sshSecretsStoreProvider).remove(entry.id);
    ref.invalidate(hostEntriesProvider);
  });
  ref.onDispose(() {
    unawaited(sub.cancel());
    unawaited(appLink.stop());
  });

  await appLink.start();
  return appLink;
});
