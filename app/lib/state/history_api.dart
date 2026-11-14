/// 项目与历史会话的 RPC 封装（multi-project-history 4.1）：
/// projects.list / projects.register / sessions.discover / session.history /
/// session.import —— 全部走现有 request/response 通道，参数与响应形状
/// 逐字对应 daemon/src/protocol.ts。纯 Dart、headless 可测。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_link_provider.dart';
import 'project_models.dart';
import 'session_models.dart';

/// 底层 call：ReconnectingHostLink.call 的 tear-off（测试注入假链接）。
typedef LinkCaller = Future<dynamic> Function(
  String method, [
  Map<String, dynamic> params,
]);

class HistoryApi {
  const HistoryApi(this._call);

  final LinkCaller _call;

  /// 枚举已注册项目（含失效目录标记与每目录会话计数）。
  Future<List<ProjectInfo>> listProjects() async {
    final result = await _call('projects.list', {}) as Map<String, dynamic>;
    final raw = result['projects'] as List<dynamic>? ?? const [];
    return raw.map((p) => ProjectInfo.fromJson(p as Map<String, dynamic>)).toList();
  }

  /// 注册一个项目目录（手机端"添加项目"用；本变更 UI 暂不暴露入口）。
  Future<ProjectInfo> registerProject(String path) async {
    final result =
        await _call('projects.register', {'path': path}) as Map<String, dynamic>;
    return ProjectInfo.fromJson(result['project'] as Map<String, dynamic>);
  }

  /// 扫描某项目目录的 Claude Code 会话（含终端创建的），按最后活动倒序。
  Future<List<DiscoveredSession>> discoverSessions(String cwd) async {
    final result =
        await _call('sessions.discover', {'cwd': cwd}) as Map<String, dynamic>;
    final raw = result['sessions'] as List<dynamic>? ?? const [];
    return raw
        .map((s) => DiscoveredSession.fromJson(s as Map<String, dynamic>))
        .toList();
  }

  /// 回放某 Claude 会话的转录（只读，分页从新到旧）。
  Future<HistoryPage> sessionHistory({
    required String claudeSessionId,
    required String cwd,
    int? beforeLine,
    int? limit,
  }) async {
    final params = <String, dynamic>{
      'claudeSessionId': claudeSessionId,
      'cwd': cwd,
      'beforeLine': ?beforeLine,
      'limit': ?limit,
    };
    final result = await _call('session.history', params) as Map<String, dynamic>;
    return HistoryPage.fromJson(result);
  }

  /// 把历史会话接管为 cc-go 会话（幂等：同 claudeSessionId 返回既有会话）。
  Future<SessionSummary> importSession({
    required String claudeSessionId,
    required String cwd,
    String? title,
  }) async {
    final result = await _call('session.import', {
      'claudeSessionId': claudeSessionId,
      'cwd': cwd,
      'title': ?title,
    }) as Map<String, dynamic>;
    return SessionSummary.fromJson(result['summary'] as Map<String, dynamic>);
  }
}

/// 主连接上的 HistoryApi（未配对时 appLink 本就无值，UI 不会到达）。
final historyApiProvider = Provider<HistoryApi?>((ref) {
  final appLink = ref.watch(appLinkProvider).value;
  return appLink == null ? null : HistoryApi(appLink.link.call);
});

/// 某项目目录的历史会话发现结果（autoDispose：离开历史页即弃）。
/// 刷新 = invalidate（历史页下拉刷新用）。
final discoveredSessionsProvider =
    FutureProvider.autoDispose.family<List<DiscoveredSession>, String>((ref, cwd) async {
  final api = ref.watch(historyApiProvider);
  if (api == null) {
    throw StateError('连接未就绪，无法发现会话');
  }
  return api.discoverSessions(cwd);
});
