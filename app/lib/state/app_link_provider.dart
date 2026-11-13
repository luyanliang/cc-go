/// appLinkProvider 的 Riverpod 接线（task 4.3）：凭据 → AppLink 生命周期；
/// token 失效 → 清凭据回配对屏。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_link.dart';
import 'credentials.dart';
import 'providers.dart';

final appLinkFactoryProvider =
    Provider<AppLink Function(HostCredentials)>((ref) => AppLink.fromCredentials);

/// 主连接：已配对时创建并启动；token 失效 → 停止重试、清凭据、路由回
/// 配对屏（task 4.3）。凭据变化（重新配对/忘记主机）时自动重建。
final appLinkProvider = FutureProvider<AppLink>((ref) async {
  final credentials = await ref.watch(credentialsProvider.future);
  if (credentials == null) {
    throw StateError('appLinkProvider requires paired credentials');
  }

  final appLink = ref.watch(appLinkFactoryProvider)(credentials);

  // token 失效：停止重试、清凭据、路由回配对屏（task 4.3）。
  final sub = appLink.tokenInvalid.listen((_) async {
    await appLink.stop();
    await ref.read(credentialStoreProvider).clear();
    ref.invalidate(credentialsProvider);
  });
  ref.onDispose(() {
    unawaited(sub.cancel());
    unawaited(appLink.stop());
  });

  await appLink.start();
  return appLink;
});
