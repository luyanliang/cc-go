/// 项目列表状态（multi-project-history 4.1）：projects.list 拉全量；
/// connected 边沿（首连/重连）与 sessions.changed 防抖刷新（每目录的
/// sessionCount 随会话增删变化）。与 sessionsProvider 同一套驱动方式。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../transport/reconnecting_link.dart';
import 'app_link_provider.dart';
import 'history_api.dart';
import 'project_models.dart';
import 'sessions.dart';

final projectsProvider =
    NotifierProvider<ProjectsNotifier, AsyncValue<List<ProjectInfo>>>(
  ProjectsNotifier.new,
);

/// 会话列表的数据视图（multi-project-history 4.2）：项目 × 会话 → 分组。
/// 任一在加载中即 loading；任一出错即错误（错误优先 projects——
/// 项目枚举是分组的前提）。
final sessionGroupsProvider = Provider<AsyncValue<List<ProjectGroup>>>((ref) {
  final projects = ref.watch(projectsProvider);
  final sessions = ref.watch(sessionsProvider);
  if (projects.isLoading || sessions.isLoading) {
    return const AsyncValue.loading();
  }
  if (projects.hasError) {
    return AsyncValue.error(projects.error!, projects.stackTrace ?? StackTrace.current);
  }
  if (sessions.hasError) {
    return AsyncValue.error(sessions.error!, sessions.stackTrace ?? StackTrace.current);
  }
  return AsyncValue.data(groupSessionsByProject(projects.value!, sessions.value!));
});

class ProjectsNotifier extends Notifier<AsyncValue<List<ProjectInfo>>> {
  StreamSubscription<dynamic>? _eventsSub;
  StreamSubscription<LinkState>? _statesSub;
  Timer? _debounce;
  Timer? _connectDeadline;
  var _disposed = false;

  @override
  AsyncValue<List<ProjectInfo>> build() {
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

    _statesSub?.cancel();
    _statesSub = appLink.link.states.listen((state) {
      if (state == LinkState.connected && !_disposed && ref.mounted) {
        unawaited(refresh());
      }
    });

    // 兜底：一直连不上时给出可见错误（sessionsProvider 同款）。
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

  void _scheduleRefresh() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (!_disposed && ref.mounted) unawaited(refresh());
    });
  }

  Future<void> refresh() async {
    final api = ref.read(historyApiProvider);
    if (api == null) return;
    state = await AsyncValue.guard(api.listProjects);
  }
}
