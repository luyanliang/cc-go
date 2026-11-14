/// 连接作用域的列表 Notifier 基类（multi-project-history 7.10 重构）：
/// 抽取 ProjectsNotifier / SessionsNotifier 共有的连接管道 ——
/// sessions.changed 防抖刷新、connected 边沿首拉/重连拉、连接超时兜底、
/// Riverpod 3 rebuild 的订阅复位。子类只实现 refresh()。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../transport/reconnecting_link.dart';
import 'app_link_provider.dart';

abstract class LinkScopedListNotifier<T> extends Notifier<AsyncValue<List<T>>> {
  StreamSubscription<dynamic>? _eventsSub;
  StreamSubscription<LinkState>? _statesSub;
  Timer? _debounce;
  Timer? _connectDeadline;
  var _disposed = false;

  @override
  AsyncValue<List<T>> build() {
    // Riverpod 3 在每次 rebuild 前也会跑 onDispose，这里必须复位。
    _disposed = false;
    ref.onDispose(() {
      _disposed = true;
      _debounce?.cancel();
      _eventsSub?.cancel();
      _statesSub?.cancel();
      _connectDeadline?.cancel();
    });

    final appLink = ref.watch(appLinkProvider).value;
    if (appLink == null) {
      return const AsyncValue.loading();
    }

    _eventsSub?.cancel();
    _eventsSub = appLink.link.events.listen((event) {
      if (event.type == 'sessions.changed') {
        _scheduleRefresh();
      }
    });

    // 首次加载与重连恢复都由 connected 边沿驱动（states 流对新订阅者
    // 会重放当前状态，已连接时立即触发一次）。
    _statesSub?.cancel();
    _statesSub = appLink.link.states.listen((state) {
      if (state == LinkState.connected && !_disposed && ref.mounted) {
        unawaited(refresh());
      }
    });

    // 兜底：daemon 一直连不上时给出可见错误，而不是无限转圈——
    // connected 边沿一旦到来，refresh() 会把错误态替换成数据。
    _connectDeadline?.cancel();
    if (appLink.link.state != LinkState.connected) {
      _connectDeadline = Timer(const Duration(seconds: 6), () {
        if (_disposed || !ref.mounted) return;
        if (appLink.link.state != LinkState.connected) {
          state = AsyncValue.error('无法连接主机（重试中…）', StackTrace.current);
        }
      });
    }

    return const AsyncValue.loading();
  }

  /// 防抖：流式期间 sessions.changed 会在每个条目更新时广播。
  void _scheduleRefresh() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (!_disposed && ref.mounted) unawaited(refresh());
    });
  }

  /// 子类实现：拉全量并写入 state。
  Future<void> refresh();
}
