/// 会话列表状态（task 5.1/5.2）：host.info 拉全量 + sessions.changed 防抖
/// 刷新（该事件在流式期间高频广播）。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../transport/host_link.dart';
import '../transport/reconnecting_link.dart';
import 'app_link_provider.dart';
import 'session_models.dart';

final sessionsProvider =
    NotifierProvider<SessionsNotifier, AsyncValue<List<SessionSummary>>>(
  SessionsNotifier.new,
);

class SessionsNotifier extends Notifier<AsyncValue<List<SessionSummary>>> {
  StreamSubscription<DaemonEvent>? _eventsSub;
  StreamSubscription<LinkState>? _statesSub;
  Timer? _debounce;
  Timer? _connectDeadline;
  var _disposed = false;

  @override
  AsyncValue<List<SessionSummary>> build() {
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

  Future<void> refresh() async {
    final appLink = ref.read(appLinkProvider).value;
    if (appLink == null) return;
    state = await AsyncValue.guard(() async {
      final result = await appLink.link.call('host.info', {}) as Map<String, dynamic>;
      final rawSessions = result['sessions'] as List<dynamic>;
      final sessions = rawSessions
          .map((s) => SessionSummary.fromJson(s as Map<String, dynamic>))
          .toList();
      sessions.sort(compareForList);
      return sessions;
    });
  }

  /// 新建会话（daemon defaultCwd），返回新会话供导航（task 5.2）。
  Future<SessionSummary> create() async {
    final appLink = ref.read(appLinkProvider).value;
    if (appLink == null) {
      throw StateError('连接未就绪，无法新建会话');
    }
    final result =
        await appLink.link.call('session.create', {}) as Map<String, dynamic>;
    final summary = SessionSummary.fromJson(result['summary'] as Map<String, dynamic>);
    // sessions.changed 会到，但为导航即时性先行合入本地列表。
    final current = state.value ?? const <SessionSummary>[];
    state = AsyncValue.data(
      [...current, summary]..sort(compareForList),
    );
    return summary;
  }
}
