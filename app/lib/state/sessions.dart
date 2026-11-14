/// 会话列表状态（task 5.1/5.2）：host.info 拉全量 + sessions.changed 防抖
/// 刷新（该事件在流式期间高频广播）。连接管道来自
/// LinkScopedListNotifier（7.10 重构）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_link_provider.dart';
import 'link_scoped_list_notifier.dart';
import 'session_models.dart';

final sessionsProvider =
    NotifierProvider<SessionsNotifier, AsyncValue<List<SessionSummary>>>(
  SessionsNotifier.new,
);

class SessionsNotifier extends LinkScopedListNotifier<SessionSummary> {
  @override
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

  /// 新建会话，返回新会话供导航（task 5.2）。`cwd` 缺省时 daemon 用
  /// defaultCwd；多项目下由 UI 选定后传入（multi-project-history 4.3）。
  Future<SessionSummary> create({String? cwd}) async {
    final appLink = ref.read(appLinkProvider).value;
    if (appLink == null) {
      throw StateError('连接未就绪，无法新建会话');
    }
    final result = await appLink.link.call('session.create', {
      'cwd': ?cwd,
    }) as Map<String, dynamic>;
    final summary = SessionSummary.fromJson(result['summary'] as Map<String, dynamic>);
    // sessions.changed 会到，但为导航即时性先行合入本地列表。
    final current = state.value ?? const <SessionSummary>[];
    state = AsyncValue.data(
      [...current, summary]..sort(compareForList),
    );
    return summary;
  }
}
