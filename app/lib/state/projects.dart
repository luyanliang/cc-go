/// 项目列表状态（multi-project-history 4.1）：projects.list 拉全量；
/// connected 边沿（首连/重连）与 sessions.changed 防抖刷新（每目录的
/// sessionCount 随会话增删变化）。与 sessionsProvider 共用
/// LinkScopedListNotifier 的连接管道（7.10 重构）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'history_api.dart';
import 'link_scoped_list_notifier.dart';
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

class ProjectsNotifier extends LinkScopedListNotifier<ProjectInfo> {
  @override
  Future<void> refresh() async {
    final api = ref.read(historyApiProvider);
    if (api == null) return;
    state = await AsyncValue.guard(api.listProjects);
  }
}
