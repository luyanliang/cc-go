/// 只读历史回放控制器（multi-project-history 4.4）：session.history 分页
/// 拉取 → 合并为转录条目（复用现有 Item 渲染）；显式"接管"调用
/// session.import。纯 Dart，无 Flutter 依赖。
library;

import 'dart:async';

import 'history_api.dart';
import 'project_models.dart';
import 'session_models.dart';
import 'transcript.dart';

/// 单个历史会话的回放状态机。
///
/// 条目 id 规则 `hist-<claudeSessionId>-<uuid>`（daemon 侧稳定生成），
/// 分页按 id 去重后前插，重放/并发拉取都幂等。
class HistoryController {
  HistoryController({
    required this.claudeSessionId,
    required this.cwd,
    required this.api,
  }) {
    unawaited(loadInitial());
  }

  final String claudeSessionId;
  final String cwd;
  final HistoryApi api;

  final _changes = StreamController<void>.broadcast();

  /// 每次状态变化后发出一个信号（UI 经 StreamBuilder 重建）。
  Stream<void> get changes => _changes.stream;

  List<TranscriptItem> _items = const [];
  List<TranscriptItem> get items => _items;

  int? _nextBeforeLine;

  /// 还有更早的历史可拉（cursor 未取尽）。
  bool get hasMore => _nextBeforeLine != null;

  bool _loading = false;

  /// 首页加载中（区别于"加载更早"）。
  bool get loading => _loading;

  bool _loadingOlder = false;
  bool get loadingOlder => _loadingOlder;

  Object? _error;
  Object? get error => _error;

  bool _importing = false;
  bool get importing => _importing;

  void dispose() {
    unawaited(_changes.close());
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> loadInitial() async {
    if (_loading || _items.isNotEmpty) return;
    _loading = true;
    _error = null;
    _notify();
    try {
      final page = await api.sessionHistory(
        claudeSessionId: claudeSessionId,
        cwd: cwd,
      );
      _items = List.unmodifiable(page.items);
      _nextBeforeLine = page.nextBeforeLine;
    } on Object catch (e) {
      _error = e;
    } finally {
      _loading = false;
      _notify();
    }
  }

  /// 拉取更早的一页（游标 beforeLine = 当前 nextBeforeLine）。
  /// 返回是否真的发起（无更多/进行中/首页失败时为 no-op）。
  Future<bool> loadOlder() async {
    final cursor = _nextBeforeLine;
    if (cursor == null || _loadingOlder || _loading) return false;
    _loadingOlder = true;
    _notify();
    try {
      final page = await api.sessionHistory(
        claudeSessionId: claudeSessionId,
        cwd: cwd,
        beforeLine: cursor,
      );
      _mergeOlder(page);
      return true;
    } on Object catch (e) {
      // 分页失败保留既有条目，UI 可重试（错误随 changes 通知出去）。
      _error = e;
      return false;
    } finally {
      _loadingOlder = false;
      _notify();
    }
  }

  /// 更早一页前插：按 id 去重（daemon 幂等，重放页也安全）。
  void _mergeOlder(HistoryPage page) {
    final known = _items.map((i) => i.id).toSet();
    final fresh = page.items.where((i) => !known.contains(i.id)).toList();
    if (fresh.isNotEmpty) {
      _items = List.unmodifiable([...fresh, ..._items]);
    }
    _nextBeforeLine = page.nextBeforeLine;
  }

  /// 接管：session.import → cc-go 会话（幂等）。`title` 通常传发现结果里的
  /// 会话标题，让接管后的会话标题与历史一致。成功后 UI 导航进正常聊天页。
  Future<SessionSummary> importSession({String? title}) async {
    if (_importing) throw StateError('接管进行中');
    _importing = true;
    _notify();
    try {
      return await api.importSession(
        claudeSessionId: claudeSessionId,
        cwd: cwd,
        title: title,
      );
    } finally {
      _importing = false;
      _notify();
    }
  }
}
